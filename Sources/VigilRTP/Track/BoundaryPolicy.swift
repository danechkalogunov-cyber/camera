//
//  BoundaryPolicy.swift
//  VigilRTP
//
//  Learned access-unit boundary policy. The marker bit is never a correctness input; it is promoted
//  to a latency optimisation only after it has agreed with the slice header for long enough, and it
//  is demoted permanently on the second disagreement.
//  See docs/spec-rtp.md §7.4 and docs/API_CONTRACT.md §4.4.
//

// MARK: - SliceProfile

/// How many slices this encoder puts in a picture, as observed so far.
///
/// `singleSlicePerPicture` is what every Hikvision live profile we have seen does, and it is what
/// lets an access unit close the instant its last fragment arrives instead of waiting for the first
/// packet of the next picture. It is never assumed, only learned.
public enum SliceProfile: Sendable, Equatable {
    /// Not enough access units have closed to tell. Only the always-correct close rules apply.
    case unknown
    /// Every recent access unit held exactly one VCL NAL.
    case singleSlicePerPicture
    /// At least one access unit held two or more VCL NALs.
    case multiSlice
}

// MARK: - MarkerTrust

/// How much the RTP marker bit has earned.
///
/// The names say "learned" because there is no state in which the marker bit is trusted without
/// evidence: `untrusted` is where every stream starts and where it returns after any reset.
public enum MarkerTrust: Sendable, Equatable {
    /// The default. The marker bit is recorded but never used to close an access unit.
    case untrusted
    /// The marker has landed on exactly the last packet of enough consecutive access units that it
    /// may be used as a zero-latency close hint.
    case learnedReliable
    /// The marker disagreed with the slice header. It is ignored until a long clean run.
    case learnedUnreliable
}

// MARK: - BoundaryPolicy

/// The learning state machine behind access-unit boundary detection.
///
/// It never *decides* a boundary — `AccessUnitAssembler` does that from the RTP timestamp and the
/// slice header, which are always correct. This type only decides whether the two zero-latency
/// shortcuts (a trusted marker bit, and a known single-slice encoder) are currently allowed.
///
/// Malformed input cannot corrupt it: every counter is bounded and every transition is monotone in
/// the evidence it has seen.
public struct BoundaryPolicy: Sendable, Equatable {

    // MARK: - Nested Types

    /// Thresholds, named so the transitions below read as prose. Values from docs/spec-rtp.md §7.4.
    private enum Threshold {
        /// Consecutive single-VCL access units before `singleSlicePerPicture` is believed.
        static let singleSliceRun = 32
        /// Consecutive single-VCL access units needed to leave `multiSlice`.
        static let multiSliceRecoveryRun = 64
        /// Consecutive clean-marker access units before the marker is trusted.
        static let markerTrustRun = 32
        /// Marker disagreements that permanently demote it.
        static let markerViolationLimit = 2
        /// Consecutive clean-marker access units needed to leave `learnedUnreliable`.
        static let markerRecoveryRun = 128
    }

    // MARK: - Stored Properties

    /// The configured ceiling on marker trust. `.never` pins `learnedUnreliable`, `.always` pins
    /// `learnedReliable`, `.adaptive` lets the transitions below run.
    private let policy: DepacketizerConfiguration.MarkerBitTrust

    /// What we currently believe about slice count per picture.
    public private(set) var sliceProfile: SliceProfile

    /// What we currently believe about the marker bit.
    public private(set) var markerTrust: MarkerTrust

    /// Consecutive closed access units that held exactly one VCL NAL.
    private var singleVCLRun: Int

    /// Consecutive closed access units whose marker landed on exactly the last packet.
    private var cleanMarkerRun: Int

    /// Total marker disagreements since the last reset, saturating at the demotion limit.
    private var markerViolations: Int

    // MARK: - Initialisation

    /// Creates a policy for one track.
    ///
    /// - Parameter policy: the configured trust ceiling. Anything other than `.adaptive` disables
    ///   learning and pins `markerTrust` for the lifetime of the stream.
    public init(policy: DepacketizerConfiguration.MarkerBitTrust = .adaptive) {
        self.policy = policy
        self.sliceProfile = .unknown
        self.markerTrust = policy == .always ? .learnedReliable : .untrusted
        self.singleVCLRun = 0
        self.cleanMarkerRun = 0
        self.markerViolations = policy == .never ? Threshold.markerViolationLimit : 0
        if policy == .never { self.markerTrust = .learnedUnreliable }
    }

    // MARK: - Computed Properties

    /// True when a set marker bit may close an access unit immediately.
    ///
    /// This is close rule C2. It is false for every stream until the marker has been observed
    /// landing on exactly the last packet of 32 consecutive access units, which is why a camera
    /// that never sets the marker, or sets it on every packet, still produces correct boundaries.
    @inlinable public var allowsMarkerFastPath: Bool { markerTrust == .learnedReliable }

    /// True when completing a VCL NAL may close an access unit immediately.
    ///
    /// This is close rule C3, and it is how the common Hikvision configuration reaches zero added
    /// latency without the marker bit being involved at all.
    @inlinable public var allowsSingleSliceFastPath: Bool { sliceProfile == .singleSlicePerPicture }

    // MARK: - Public API

    /// Folds one closed access unit into the learned policy.
    ///
    /// - Parameters:
    ///   - vclCount: how many VCL NAL units the access unit contained.
    ///   - markerWasClean: true when the marker bit was set on the last packet that contributed to
    ///     the access unit and on no earlier packet of it.
    /// - Returns: true when `sliceProfile` or `markerTrust` changed, so the caller can emit
    ///   `DepacketizerEvent.boundaryPolicyChanged`.
    public mutating func noteClosedAccessUnit(vclCount: Int, markerWasClean: Bool) -> Bool {
        let before = (sliceProfile, markerTrust)
        updateSliceProfile(vclCount: vclCount)
        if policy == .adaptive { updateMarkerTrust(markerWasClean: markerWasClean) }
        return before != (sliceProfile, markerTrust)
    }

    /// Records that an access unit was closed too early: a slice of the same picture arrived after
    /// it had already been emitted.
    ///
    /// Forces both shortcuts off. This is the self-correction path for firmware that sets the
    /// marker one packet early on I-frames (docs/spec-rtp.md §7.5).
    ///
    /// - Returns: true when the policy changed.
    public mutating func notePrematureClose() -> Bool {
        let before = (sliceProfile, markerTrust)
        sliceProfile = .multiSlice
        singleVCLRun = 0
        cleanMarkerRun = 0
        if policy == .adaptive {
            markerViolations = Threshold.markerViolationLimit
            markerTrust = .learnedUnreliable
        }
        return before != (sliceProfile, markerTrust)
    }

    /// Returns the policy to its initial state. Called on SSRC change, reconnect, decoder reset and
    /// any parameter-set change, because all of those can change the encoder's slice structure.
    public mutating func reset() {
        sliceProfile = .unknown
        singleVCLRun = 0
        cleanMarkerRun = 0
        switch policy {
        case .never:
            markerViolations = Threshold.markerViolationLimit
            markerTrust = .learnedUnreliable
        case .always:
            markerViolations = 0
            markerTrust = .learnedReliable
        case .adaptive:
            markerViolations = 0
            markerTrust = .untrusted
        }
    }

    // MARK: - Private Helpers

    /// One access unit's worth of evidence about slice structure.
    private mutating func updateSliceProfile(vclCount: Int) {
        guard vclCount > 0 else { return }        // parameter-set-only units carry no evidence
        if vclCount >= 2 {
            sliceProfile = .multiSlice
            singleVCLRun = 0
            return
        }
        singleVCLRun = min(singleVCLRun + 1, Threshold.multiSliceRecoveryRun)
        switch sliceProfile {
        case .singleSlicePerPicture:
            break
        case .unknown:
            if singleVCLRun >= Threshold.singleSliceRun { sliceProfile = .singleSlicePerPicture }
        case .multiSlice:
            // A stream that genuinely became single-slice (a quality switch, a re-PLAY) has to
            // prove it for twice as long as one that never claimed otherwise.
            if singleVCLRun >= Threshold.multiSliceRecoveryRun { sliceProfile = .singleSlicePerPicture }
        }
    }

    /// One access unit's worth of evidence about the marker bit.
    private mutating func updateMarkerTrust(markerWasClean: Bool) {
        guard markerWasClean else {
            cleanMarkerRun = 0
            markerViolations = min(markerViolations + 1, Threshold.markerViolationLimit)
            if markerViolations >= Threshold.markerViolationLimit { markerTrust = .learnedUnreliable }
            return
        }
        cleanMarkerRun = min(cleanMarkerRun + 1, Threshold.markerRecoveryRun)
        switch markerTrust {
        case .learnedReliable:
            break
        case .untrusted:
            if cleanMarkerRun >= Threshold.markerTrustRun { markerTrust = .learnedReliable }
        case .learnedUnreliable:
            if cleanMarkerRun >= Threshold.markerRecoveryRun {
                markerTrust = .learnedReliable
                markerViolations = 0
            }
        }
    }
}
