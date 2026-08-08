//
//  DecodeBudget+Machine.swift
//  VigilCore
//
//  Where the decode budget's total number comes from: the machine, or the user overriding it.
//  macOS-only, and that is the whole reason this is not in `VigilProtocols` beside the policy —
//  a rule that reads `sysctl` can only be tested on the machine it read.
//
//  Implements docs/FEATURES.md F-DEC-06 acceptance 2.
//

#if os(macOS)

import Foundation

import VigilProtocols

// MARK: - Detecting the budget

public extension DecodeBudget {

    /// The budget for this Mac: the user's override if there is one, otherwise what the hardware
    /// suggests.
    ///
    /// - Parameter defaults: where the override lives. Injected so a test can pass a scratch suite
    ///   rather than the user's own preferences.
    static func detected(defaults: UserDefaults = .standard) -> DecodeBudget {
        if let override = overrideUnits(in: defaults) {
            return DecodeBudget(total: DecodeCost(units: override))
        }
        return DecodeBudget(total: DecodeCost(units: suggestedUnits()))
    }

    /// The user's "Maximum concurrent decodes", or `nil` when they have not set one.
    ///
    /// ⚠️ Read by presence, not by value. `UserDefaults.double(forKey:)` answers `0` for a missing
    /// key, and zero is a legal-looking budget that would pause every camera on a machine whose
    /// owner never opened Settings.
    ///
    /// A stored value of zero or less is treated as absent for the same reason: the honest reading
    /// of "0 decodes" from a preferences file is that something wrote nonsense, and the remedy is
    /// the machine's own number rather than a black window.
    static func overrideUnits(in defaults: UserDefaults) -> Double? {
        guard defaults.object(forKey: overrideKey) != nil else { return nil }
        let stored = defaults.double(forKey: overrideKey)
        return stored > 0 ? stored : nil
    }

    /// Records the user's choice, or clears it when `units` is `nil`.
    static func setOverrideUnits(_ units: Double?, in defaults: UserDefaults) {
        guard let units, units > 0 else {
            defaults.removeObject(forKey: overrideKey)
            return
        }
        defaults.set(units, forKey: overrideKey)
    }

    /// What this machine is assumed to manage, in decode units.
    ///
    /// ⚠️ **Assumed, not measured, and the difference is stated rather than hidden.** F-DEC-06 names
    /// two numbers — 24 DU on Apple silicon, 10 DU on Intel — and they are estimates from the
    /// hardware decoders those machines carry, not from anything this process has watched. A
    /// measured budget needs a decoder that reports its own headroom under load, which no public
    /// VideoToolbox API offers; what the code *can* do honestly is start from the estimate, let the
    /// user override it, and count demotions in the health stats so a wrong estimate is visible in
    /// the field rather than merely suspected.
    ///
    /// The core count scales it: an 8-core M1 and a 24-core M2 Ultra are both "Apple silicon" and
    /// are not the same machine. The base figure is the one F-DEC-06 names for the eight-core case,
    /// and each core beyond that adds an eighth of it — linear, because the constraint is the media
    /// engine count and those scale with the part.
    static func suggestedUnits() -> Double {
        let isAppleSilicon = sysctlFlag("hw.optional.arm64")
        let base = isAppleSilicon ? appleSiliconUnits : intelUnits
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let scale = Double(cores) / Double(referenceCores)
        return (base * max(1, scale)).rounded()
    }

    /// The `UserDefaults` key behind Settings ➝ Streams ➝ "Maximum concurrent decodes".
    ///
    /// ⚠️ The key exists and is honoured; the Settings control that writes it does not exist yet.
    /// That is deliberate rather than forgotten — the pane is `F-PLT-04` — and it means an operator
    /// who needs a different budget today can set it with `defaults write` and be obeyed, which is
    /// strictly better than a number nobody can change.
    static var overrideKey: String { "vigil.streams.maximumConcurrentDecodes" }

    /// F-DEC-06's figure for Apple silicon.
    static var appleSiliconUnits: Double { 24 }

    /// F-DEC-06's figure for Intel.
    static var intelUnits: Double { 10 }

    /// The core count the two figures above are quoted for.
    static var referenceCores: Int { 8 }
}

// MARK: - Private helpers

private func sysctlFlag(_ name: String) -> Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    // A machine that does not have the key answers non-zero and leaves `value` alone, which is the
    // Intel case and reads as `false` — the safe direction, since it picks the smaller budget.
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return false }
    return value != 0
}

#endif  // os(macOS)
