//
//  MachineDecodeBudget.swift
//  VigilCore
//
//  Where the decode budget's total comes from: the machine, or the user overriding it.
//  macOS-only, which is the whole reason it is not in `VigilProtocols` beside the planner — a rule
//  that reads `sysctl` can only be tested on the machine it read, and `DecodeAdmissionPlanner` is
//  deliberately testable anywhere.
//
//  Implements docs/FEATURES.md F-DEC-06 acceptance 2.
//

#if os(macOS)

import Foundation

import VigilProtocols

// MARK: - MachineDecodeBudget

/// How much decoding this Mac will do at once.
public enum MachineDecodeBudget {

    /// The budget to plan against: the user's override if there is one, otherwise the machine's own
    /// figure.
    ///
    /// - Parameter defaults: where the override lives. Injected so a test can pass a scratch suite
    ///   rather than reading the preferences of whoever is running it.
    public static func detected(defaults: UserDefaults = .standard) -> DecodeCost {
        DecodeCost(units: overrideUnits(in: defaults) ?? suggestedUnits())
    }

    /// The user's "Maximum concurrent decodes", or `nil` when they have not set one.
    ///
    /// ⚠️ Read by presence, not by value. `UserDefaults.double(forKey:)` answers `0` for a missing
    /// key, and zero is a legal-looking budget that would put every camera on a JPEG poll for a user
    /// who never opened Settings. A stored value of zero or less is treated as absent for the same
    /// reason: the honest reading of "0 decodes" in a preferences file is that something wrote
    /// nonsense, and the remedy is the machine's own number.
    public static func overrideUnits(in defaults: UserDefaults) -> Double? {
        guard defaults.object(forKey: overrideKey) != nil else { return nil }
        let stored = defaults.double(forKey: overrideKey)
        return stored > 0 ? stored : nil
    }

    /// Records the user's choice, or clears it when `units` is `nil`.
    public static func setOverrideUnits(_ units: Double?, in defaults: UserDefaults) {
        guard let units, units > 0 else {
            defaults.removeObject(forKey: overrideKey)
            return
        }
        defaults.set(units, forKey: overrideKey)
    }

    /// What this machine is assumed to manage, in decode units.
    ///
    /// ⚠️ **Assumed, not measured, and saying so is the point.** F-DEC-06 names two figures — 24 DU
    /// on Apple silicon, 10 on Intel — and they come from the hardware decoders those machines
    /// carry, not from anything this process has watched. A *measured* budget needs a decoder that
    /// reports its own headroom under load, which no public VideoToolbox API offers. What the code
    /// can honestly do is start from the estimate, let the user override it, and count demotions in
    /// the health stats so a wrong estimate becomes visible in the field rather than merely
    /// suspected.
    ///
    /// The core count scales it, because an 8-core M1 and a 24-core M2 Ultra are both "Apple
    /// silicon" and are not the same machine. The quoted figures are for the eight-core case, and
    /// the scale is linear in cores — the constraint is the media-engine count, and those scale with
    /// the part. Never scaled *down*: a four-core Mac gets the base figure and its owner can lower
    /// it, which is the safe direction for a number nobody has measured.
    public static func suggestedUnits() -> Double {
        let base = isAppleSilicon() ? appleSiliconUnits : intelUnits
        let cores = Swift.max(1, ProcessInfo.processInfo.activeProcessorCount)
        return (base * Swift.max(1, Double(cores) / Double(referenceCores))).rounded()
    }

    /// Whether this is an arm64 Mac.
    ///
    /// A machine without the key answers non-zero and leaves the value alone, which reads as
    /// `false` — the Intel case, and the smaller budget, which is the safe direction.
    public static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else { return false }
        return value != 0
    }

    /// The `UserDefaults` key behind Settings ➝ Streams ➝ "Maximum concurrent decodes".
    public static let overrideKey = "vigil.streams.maximumConcurrentDecodes"

    /// F-DEC-06's figure for Apple silicon, at ``referenceCores``.
    public static let appleSiliconUnits = 24.0

    /// F-DEC-06's figure for Intel, at ``referenceCores``.
    public static let intelUnits = 10.0

    /// The core count the two figures above are quoted for.
    public static let referenceCores = 8

    /// The ceiling on simultaneous decompression sessions.
    ///
    /// ⚠️ A guess, and flagged as one. VideoToolbox exhausts sessions long before the decode-unit
    /// budget does on small streams — that is why `DecodeAdmitting` declares the two separately —
    /// but it publishes no way to ask how many are left. Sixteen is the widest layout Vigil offers,
    /// so a ceiling at sixteen refuses nothing the user can currently arrange, and it exists so that
    /// the planner's session rule is exercised rather than dead.
    public static let maximumSessions = 16
}

#endif  // os(macOS)
