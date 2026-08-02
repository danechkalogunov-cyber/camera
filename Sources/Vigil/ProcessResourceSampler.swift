//
//  ProcessResourceSampler.swift
//  Vigil
//
//  What this process costs the Mac: CPU and memory, sampled from the kernel.
//  macOS-only. Feeds the status bar and the field log; see docs/API_CONTRACT.md §19.
//
//  ⛔ MEASUREMENT, NOT OPTIMISATION. Nothing here makes anything faster, and that is the point of
//  writing it first. `StreamStatistics` has twenty fields about the *stream* — frames, packets,
//  jitter, decode percentiles — and not one about the process, so every question of the form "is
//  Vigil heavy?" has so far been answered by looking at Activity Monitor and guessing which part
//  of the app was responsible. This session has already produced two changes that were reverted
//  because they optimised something that turned out not to be the cost. Numbers first.
//
//  ⚠️ `ri_phys_footprint`, not `ri_resident_size`. Footprint is what Activity Monitor's "Memory"
//  column shows and what macOS actually holds a process to under pressure; resident size omits
//  compressed pages and IOKit allocations, which for a video app — every decoded frame is an
//  IOSurface — is most of the interesting memory.
//

#if os(macOS)

import Darwin
import Foundation

// MARK: - ProcessResourceSample

/// One reading of what this process is using.
struct ProcessResourceSample: Sendable, Hashable {

    /// Share of one core, as a fraction: `1.0` is a fully busy core, `4.0` is four of them. Not
    /// normalised by core count, because the number that matters for a video app is "how many
    /// cores' worth", and dividing by the machine's width hides the difference between an M1 and
    /// an M3 Max running the same load.
    var cpuCores: Double

    /// Physical footprint in bytes — the number Activity Monitor calls Memory.
    var footprintBytes: UInt64

    /// Nothing measured yet.
    static let unmeasured = ProcessResourceSample(cpuCores: 0, footprintBytes: 0)

    /// `1.4 cores · 412 MB`, for a log line or a tooltip.
    var label: String {
        let megabytes = Double(footprintBytes) / 1_048_576
        return String(format: "%.2f cores · %.0f MB", cpuCores, megabytes)
    }
}

// MARK: - ProcessResourceSampler

/// Reads this process's CPU and memory from the kernel, and turns CPU into a rate.
///
/// CPU has to be differenced: the kernel reports cumulative time used since launch, so a single
/// reading says how much work the process has *ever* done and nothing about now. The first sample
/// therefore reports zero cores — it has nothing to difference against — which is correct and not a
/// missing measurement.
struct ProcessResourceSampler {

    /// Cumulative CPU nanoseconds at the previous sample, and when that was taken.
    private var previous: (cpuNanoseconds: UInt64, at: Date)?

    init() {}

    /// Takes a reading, or `nil` when the kernel refused — which is not an error worth surfacing:
    /// a missing number renders as an em dash and the app is unaffected.
    mutating func sample(now: Date = Date()) -> ProcessResourceSample? {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard status == 0 else { return nil }

        let cpuNanoseconds = info.ri_user_time + info.ri_system_time
        let footprint = info.ri_phys_footprint

        guard let last = previous else {
            previous = (cpuNanoseconds, now)
            return ProcessResourceSample(cpuCores: 0, footprintBytes: footprint)
        }
        previous = (cpuNanoseconds, now)

        let elapsed = now.timeIntervalSince(last.at)
        // A zero or backwards interval means two samples landed in the same instant, or the wall
        // clock stepped. Report the memory and no rate rather than dividing by it.
        guard elapsed > 0 else {
            return ProcessResourceSample(cpuCores: 0, footprintBytes: footprint)
        }
        // Unsigned subtraction, guarded: cumulative CPU cannot go backwards, but a counter that
        // did would wrap to something enormous and print a machine with four billion cores.
        guard cpuNanoseconds >= last.cpuNanoseconds else {
            return ProcessResourceSample(cpuCores: 0, footprintBytes: footprint)
        }
        let usedNanoseconds = Double(cpuNanoseconds - last.cpuNanoseconds)
        return ProcessResourceSample(cpuCores: usedNanoseconds / 1e9 / elapsed,
                                     footprintBytes: footprint)
    }
}

// MARK: - ProcessResourceMonitor

/// Holds the sampler's state between ticks, and the latest reading for anything that shows it.
///
/// A class, and it has to be: ``ProcessResourceSampler`` differences each CPU reading against the
/// previous one, so it must be *the same* sampler every second. Held as a `@State` struct it would
/// be mutated on a copy and every reading would difference against nothing, reporting zero cores
/// forever — which looks exactly like an idle app.
@MainActor
final class ProcessResourceMonitor {

    /// The most recent reading.
    var latest: ProcessResourceSample = .unmeasured

    /// How many samples have been taken, so the log line can be rarer than the sample.
    var ticks: UInt64 = 0

    var sampler = ProcessResourceSampler()

    init() {}
}

#endif  // os(macOS)
