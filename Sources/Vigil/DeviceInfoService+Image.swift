//
//  DeviceInfoService+Image.swift
//  Vigil
//
//  The camera's picture controls: reading them, writing them without flooding the device, and
//  resetting them on firmware that has no reset command.
//  macOS-only. Split from DeviceInfoService.swift, which docs/API_CONTRACT.md §7.2 caps at 600 lines.
//

#if os(macOS)

import Foundation

import VigilCore
import VigilISAPI
import VigilProtocols
import VigilUI

// MARK: - Picture settings

/// Every ISAPI write in this app that a slider can drive lives here, behind one coalescing writer.
///
/// ⚠️ Members are `internal` rather than `private`: `private` reaches a type's extensions only
/// within one file, so anything split out and left `private` becomes invisible to the class it
/// belongs to. Nothing outside this target can reach `DeviceInfoService` regardless.
extension DeviceInfoService {

    /// Reads the camera's picture controls into ``image``.
    ///
    /// Silent on failure, like the poster: a firmware that does not expose a control leaves that row
    /// at its default rather than failing the whole panel. `ImageSettings` is `Optional` field by
    /// field for the same reason.
    func loadImageSettings(channel: ChannelID, force: Bool = false) async {
        guard let session else { return }
        do {
            var settings = Self.inspectorImage(
                from: try await session.imageSettings(channel: channel, force: force))
            settings.isLocalPreviewOnly = image?.isLocalPreviewOnly ?? false
            confirmedImage = settings
            // A read that lands while the user is dragging must not move the control under their
            // pointer. The baseline is still updated, so the write that follows diffs correctly.
            if pendingImage == nil { image = settings }
        } catch {
            logger.debug(.isapi, "image settings unavailable: \(String(describing: error))")
        }
    }

    /// Takes the panel's whole picture set as the value the user wants, and schedules the write.
    ///
    /// **Published first, written later.** The panel's sliders are computed `Binding`s whose getter
    /// reads ``image``, so until it changes the control snaps back to where it was. Publishing the
    /// requested value here, synchronously, is what lets the knob follow the pointer at all.
    ///
    /// **Nothing is sent while the control is still moving** (UX.md §15.4). A drag emits a change
    /// per pixel and each one is a read-modify-write — `GET`, `PUT`, `GET` — so writing them all
    /// meant roughly a hundred and fifty round trips for one gesture, at a device that answers a
    /// handful per second. ``drainImageWrites(channel:)`` waits for the value to hold still for
    /// ``imageSettleTime`` and then writes only what it has settled on.
    ///
    /// **Everything here is the camera's own setting.** There is no local image processing anywhere
    /// in Vigil — the decode path is passthrough, straight from the network into
    /// `AVSampleBufferDisplayLayer` — so every control on this tab is an ISAPI write to
    /// `/Image/channels/{ch}/…` and the picture changes at the sensor, for everyone watching.
    /// ⚠️ That is also why "Adjust my view only" only *withholds* the write: honouring it properly
    /// needs a render-path adjustment stage that does not exist. Reported in ЧТО-НЕ-СДЕЛАНО.md.
    func writeImage(channel: ChannelID, _ wanted: InspectorImageSettings) {
        image = wanted
        pendingImage = wanted
        // One writer, ever. Starting a second would put two read-modify-write cycles on the same
        // sub-resource at once, and the loser's `GET` would read the winner's half-applied state.
        guard imageWriter == nil else { return }
        imageWriter = Task { [weak self] in
            await self?.drainImageWrites(channel: channel)
        }
    }

    /// How long a control has to hold still before its value is sent. UX.md §15.4.
    ///
    /// Trailing rather than leading: the interesting value is the one the user let go on, not the
    /// one they passed through on the way. 250 ms is short enough that releasing the mouse and
    /// seeing the picture change reads as immediate.
    static let imageSettleTime = Duration.milliseconds(250)

    /// Writes settled values until there are none left, one at a time.
    ///
    /// The loop is what coalesces a drag: it waits out a settle window, and if the wanted value
    /// moved during that window it waits again rather than writing an intermediate position. So a
    /// two-second drag across the whole track is one write, not two hundred.
    ///
    /// ⛔ Never cancelled. Cancelling would abort whatever HTTP request is in flight, and a `PUT`
    /// cut off half-way is exactly how a camera is left with a partly-applied `<Color>` element.
    /// Newer intent arrives through ``pendingImage`` instead, which this loop re-reads every pass.
    func drainImageWrites(channel: ChannelID) async {
        defer { imageWriter = nil }
        while let wanted = pendingImage {
            try? await Task.sleep(for: Self.imageSettleTime)
            guard let latest = pendingImage else { return }
            // Still moving. Wait for the next lull rather than writing a position the user has
            // already dragged past — this is the whole point of the loop.
            guard latest == wanted else { continue }
            pendingImage = nil
            await flushImage(channel: channel, wanted: latest)
        }
    }

    /// Sends the nodes that differ from what the device last confirmed.
    ///
    /// Diffed against ``confirmedImage``, never against ``image``. `image` is the *user's* value and
    /// moves with the pointer, so diffing against it compared each drag position with the previous
    /// one — which made every control look changed on every tick, and wrote all six sub-resources
    /// for a gesture that touched one.
    ///
    /// - Returns: `false` when the device refused at least one node.
    @discardableResult
    func flushImage(channel: ChannelID,
                            wanted: InspectorImageSettings) async -> Bool {
        guard let session else { return false }
        guard !wanted.isLocalPreviewOnly else {
            logger.info(.isapi, "image write withheld: adjust-my-view-only is on")
            return true
        }
        let previous = confirmedImage ?? InspectorImageSettings()
        var accepted = true

        if wanted.brightness != previous.brightness || wanted.contrast != previous.contrast
            || wanted.saturation != previous.saturation {
            let ok = await apply(channel: channel) {
                try await session.setImageColor(channel: channel,
                                                brightness: wanted.brightness,
                                                contrast: wanted.contrast,
                                                saturation: wanted.saturation)
            }
            accepted = accepted && ok
        }
        if wanted.sharpness != previous.sharpness {
            let ok = await apply(channel: channel) {
                try await session.setSharpness(channel: channel, wanted.sharpness)
            }
            accepted = accepted && ok
        }
        if wanted.wdrMode != previous.wdrMode || wanted.wdrLevel != previous.wdrLevel {
            let mode: WDRSetting.Mode = switch wanted.wdrMode {
            case .on:   .open
            case .off:  .close
            case .auto: .auto
            }
            let ok = await apply(channel: channel) {
                try await session.setWDR(channel: channel,
                                         WDRSetting(mode: mode, level: wanted.wdrLevel))
            }
            accepted = accepted && ok
        }
        // `schedule` is deliberately not sent. `ISAPIDeviceSession.setIRCut` refuses it, because the
        // mode carries a switching schedule Vigil does not model and writing the mode alone would
        // discard the user's own times. The segment stays selectable so a camera already in that
        // mode reports it honestly; choosing it here simply changes nothing on the device.
        if wanted.dayNightMode != previous.dayNightMode, wanted.dayNightMode != .schedule {
            let mode: IRCutSetting.Mode = switch wanted.dayNightMode {
            case .day:      .day
            case .night:    .night
            case .auto:     .auto
            case .schedule: .auto       // unreachable: excluded by the guard above
            }
            let ok = await apply(channel: channel) {
                // The two thresholds are `nil` on purpose. Every image write is a read-modify-write,
                // so an omitted element keeps whatever the device already had — passing a guess here
                // would overwrite the user's own night-to-day tuning with one.
                try await session.setIRCut(channel: channel,
                                           IRCutSetting(mode: mode,
                                                        nightToDayLevel: nil,
                                                        nightToDaySeconds: nil))
            }
            accepted = accepted && ok
        }
        if wanted.irMode != previous.irMode || wanted.irLevel != previous.irLevel {
            // The panel's tri-state is two device fields. `off` closes the lamp; `auto` and `on`
            // both leave it emitting and differ only in who picks the brightness — which is exactly
            // what `mixedLightBrightnessRegulatMode` says.
            let lamp = SupplementLightSetting(
                mode: wanted.irMode == .off ? .close : .irLight,
                regulation: wanted.irMode == .on ? .manual : .auto,
                brightness: wanted.irLevel)
            let ok = await apply(channel: channel) {
                try await session.setSupplementLight(channel: channel, lamp)
            }
            accepted = accepted && ok
        }
        if wanted.flip != previous.flip {
            let style: FlipSetting.Style? = switch wanted.flip {
            case .off:        nil
            case .centre:     .centre
            case .horizontal: .horizontal
            case .vertical:   .vertical
            }
            let ok = await apply(channel: channel) {
                // Switching off keeps the previous axis rather than clearing it, so turning the
                // flip back on restores what the user chose instead of reverting to `CENTER`.
                try await session.setFlip(channel: channel,
                                          FlipSetting(isEnabled: style != nil, style: style))
            }
            accepted = accepted && ok
        }
        return accepted
    }

    /// Restores the camera's factory picture settings and re-reads them.
    ///
    /// **Reports what happened, and never nothing.** This used to swallow every outcome into a log
    /// line, so a device that refused the endpoint outright and a device that reset perfectly looked
    /// identical from the panel: the button appeared to do nothing either way. The three answers are
    /// now distinguishable by the caller, which is what lets the window say which one it was.
    ///
    /// The second read is not belt-and-braces. `PUT …/defaultConfiguration` returns as soon as the
    /// camera has accepted it, and several firmwares apply the values a moment later — so a single
    /// confirming read can legitimately still hold the old panel and make a successful reset look
    /// like a no-op.
    ///
    /// **The fallback, and why it is not cheating.** Plenty of firmwares answer this endpoint with
    /// `statusCode 4 / invalidOperation` — the resource is documented (spec-isapi.md §17.2 row
    /// "Defaults") but not implemented on that model. When that happens Vigil writes the documented
    /// default values through the sub-resources that *do* work, which is what the button was asked
    /// to achieve. It is announced as such rather than reported as a device reset, because the two
    /// are not the same thing: a device reset also restores the controls Vigil does not model.
    @discardableResult
    func resetImage(channel: ChannelID) async -> ImageResetOutcome {
        guard let session else {
            logger.error(.isapi, "image reset ignored: no ISAPI session for this camera")
            return .unavailable
        }
        // A slider let go of a moment before the button was pressed still has a write queued, and
        // letting it land after the reset would put that one value straight back.
        pendingImage = nil
        let before = image
        do {
            try await session.resetImageDefaults(channel: channel)
        } catch {
            let reason = String(describing: error)
            logger.error(.isapi, "image reset refused by the device: \(reason)")
            return await applyDocumentedDefaults(channel: channel, after: reason)
        }
        await loadImageSettings(channel: channel, force: true)
        if image != before {
            logger.info(.isapi, "image reset applied")
            return .reset
        }
        try? await Task.sleep(for: .milliseconds(900))
        await loadImageSettings(channel: channel, force: true)
        if image != before {
            logger.info(.isapi, "image reset applied after a settling delay")
            return .reset
        }
        logger.info(.isapi, "image reset accepted but nothing changed")
        return .unchanged
    }

    /// Writes the picture values the ISAPI specification gives as defaults.
    ///
    /// The set is `InspectorImageSettings()`'s own defaults, which are the documented ones:
    /// brightness, contrast, saturation and sharpness at 50 (spec-isapi.md §17.2), WDR closed,
    /// day/night automatic, the supplement lamp on automatic and no flip. `flushImage` sends only
    /// the nodes that differ and reconciles each with the device's answer, so a camera that clamps
    /// a value still ends up showing what it actually kept.
    ///
    /// Goes straight to the writer rather than through ``writeImage(channel:_:)``: a button press is
    /// already a settled intent, and putting it through the 250 ms coalescer would make the reset
    /// feel late for no benefit.
    func applyDocumentedDefaults(channel: ChannelID,
                                         after reason: String) async -> ImageResetOutcome {
        let before = image
        logger.info(.isapi, "writing the documented image defaults instead")
        let defaults = InspectorImageSettings()
        image = defaults
        guard await flushImage(channel: channel, wanted: defaults) else {
            return .refused(reason)
        }
        return image == before ? .unchanged : .documentedDefaults(reason)
    }

    /// Runs one image write and takes the device's answer as the new baseline.
    ///
    /// **The answer only reaches the panel when the user is not mid-gesture.** Each write is three
    /// round trips, so its reply describes a moment that has already passed; publishing it while a
    /// slider is still being dragged is what yanked the knob back to a stale position. A pending
    /// edit means the user has moved on and their value wins until it is written in turn.
    ///
    /// ``confirmedImage`` is updated either way — it is the diff baseline, and it has to hold what
    /// the device actually kept even when the panel is showing something newer.
    ///
    /// On refusal the panel is put back to what the camera last reported, so a control cannot be
    /// left showing a value the device never accepted.
    func apply(channel: ChannelID,
                       _ write: () async throws -> ImageSettings) async -> Bool {
        do {
            var answered = Self.inspectorImage(from: try await write())
            // The device has no opinion about this one — it is Vigil's own switch, and rebuilding
            // the panel from the device's answer would silently turn it off after every write.
            answered.isLocalPreviewOnly = image?.isLocalPreviewOnly ?? false
            confirmedImage = answered
            if pendingImage == nil { image = answered }
            return true
        } catch {
            logger.error(.isapi, "image write refused: \(String(describing: error))")
            await loadImageSettings(channel: channel, force: true)
            return false
        }
    }

    /// Restates the device's picture controls in the panel's vocabulary.
    ///
    /// Every field the device omits keeps the panel's default, which is what `InspectorImageSettings`
    /// renders as unavailable — never a fabricated midpoint.
    static func inspectorImage(from settings: ImageSettings) -> InspectorImageSettings {
        var out = InspectorImageSettings()
        if let value = settings.brightness { out.brightness = value }
        if let value = settings.contrast { out.contrast = value }
        if let value = settings.saturation { out.saturation = value }
        if let value = settings.sharpness { out.sharpness = value }
        if let wdr = settings.wdr {
            switch wdr.mode {
            case .open:  out.wdrMode = .on
            case .close: out.wdrMode = .off
            case .auto:  out.wdrMode = .auto
            }
            if let level = wdr.level { out.wdrLevel = level }
        }
        if let ir = settings.irCut {
            switch ir.mode {
            case .day:      out.dayNightMode = .day
            case .night:    out.dayNightMode = .night
            case .auto:     out.dayNightMode = .auto
            case .schedule: out.dayNightMode = .schedule
            default:        break
            }
        }
        if let lamp = settings.supplementLight {
            // `on` means the user is choosing the brightness, `auto` means the camera is. A device
            // that reports no regulation element at all is choosing it itself, so it reads as auto.
            out.irMode = lamp.mode == .close ? .off : (lamp.regulation == .manual ? .on : .auto)
            if let brightness = lamp.brightness { out.irLevel = brightness }
        }
        if let flip = settings.flip {
            switch flip.style {
            case .centre?:     out.flip = flip.isEnabled ? .centre : .off
            case .horizontal?: out.flip = flip.isEnabled ? .horizontal : .off
            case .vertical?:   out.flip = flip.isEnabled ? .vertical : .off
            case nil:          out.flip = .off
            }
        }
        return out
    }
}

#endif  // os(macOS)
