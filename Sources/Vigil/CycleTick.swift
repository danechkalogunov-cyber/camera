//
//  CycleTick.swift
//  Vigil
//

#if os(macOS)

import Foundation
import VigilUI

/// What a change to restarts the cycle timer.
///
/// A value rather than a `Bool` so `.task(id:)` re-runs when the interval or the layout changes, not
/// only when the cycle is switched on and off — otherwise a new interval would not take effect until
/// the old sleep had finished.
struct CycleTick: Equatable {

    /// Whether the cycle should be advancing at all.
    let isTicking: Bool

    /// Seconds between advances.
    let interval: TimeInterval

    /// The layout, which decides how many pages there are to advance through.
    let layout: VGridLayout
}

#endif  // os(macOS)
