//
//  ISAPIResource.swift
//  VigilISAPI
//
//  Every ISAPI resource path Vigil issues, in one place, built from the typed identifiers so a
//  video-input channel can never be interpolated where a streaming channel belongs.
//  Implements docs/spec-isapi.md Appendix A (endpoints 1–56).
//
//  Paths are written **without** the `/ISAPI` prefix: `ISAPIEndpoint.pathPrefix` supplies it, so a
//  device behind a reverse proxy at `/cam1/ISAPI` works with no string surgery here. Casing is
//  copied from the device: `/Streaming/Channels` is capitalised because `/streaming/channels`
//  404s on 5.2.x, while `/ContentMgmt` uses its own older conventions.
//

import VigilProtocols

// MARK: - ISAPIResource

/// The resource-path vocabulary. Pure string building; no I/O.
public enum ISAPIResource {

    // MARK: Identity and capability (docs/spec-isapi.md §10)

    /// `GET` — device model, serial and firmware. The identity anchor.
    public static let deviceInfo = "/System/deviceInfo"
    /// `GET` — the cheapest authenticated call, and the only one reporting lock-out state.
    public static let userCheck = "/Security/userCheck"
    /// `GET` — health poll: uptime, CPU, memory, temperature.
    public static let systemStatus = "/System/status"
    /// `GET` — device clock and its POSIX-inverted zone string.
    public static let systemTime = "/System/time"
    /// `GET` — `<DeviceCap>`; allowed to 404 on 5.1.x, which is not an error.
    public static let capabilities = "/System/capabilities"
    /// `GET` — link speed, MAC and MTU. Read-only; Vigil never writes network configuration.
    public static let networkInterfaces = "/System/Network/interfaces"
    /// `GET` — user list, read for permission diagnostics only.
    public static let users = "/Security/users"
    /// `PUT` — reboot, empty body. A lost connection after this counts as success.
    public static let reboot = "/System/reboot"
    /// `PUT` — sets the first administrator password on an unactivated device.
    public static let activate = "/System/activate"

    // MARK: Channel inventory (docs/spec-isapi.md §11)

    /// `GET` — an NVR's proxied IP channels, with the names the operator typed into the NVR.
    public static let inputProxyChannels = "/ContentMgmt/InputProxy/channels"
    /// `GET` — every proxied channel's online flag in one request. Always prefer this list form.
    public static let inputProxyStatusList = "/ContentMgmt/InputProxy/channels/status"
    /// `GET` — one proxied channel's status; the fallback when the list form 404s.
    public static func inputProxyStatus(_ channel: ChannelID) -> String {
        "/ContentMgmt/InputProxy/channels/\(channel.value)/status"
    }
    /// `GET` — local video inputs. Also the index space for `/Image` and motion detection.
    public static let videoInputChannels = "/System/Video/inputs/channels"

    // MARK: Streaming (docs/spec-isapi.md §12)

    /// `GET` — every stream of every channel; the single most valuable request Vigil makes.
    public static let streamingChannels = "/Streaming/channels"
    /// `GET`/`PUT` — one stream's configuration, addressed by `channel * 100 + quality`.
    public static func streamingChannel(_ id: StreamingChannelID) -> String {
        "/Streaming/channels/\(id.value)"
    }
    /// `GET`/`PUT` — the single-digit form some 5.1.x firmware requires (main stream only).
    public static func streamingChannelSingleDigit(_ channel: ChannelID) -> String {
        "/Streaming/channels/\(channel.value)"
    }
    /// `GET` — JPEG snapshot for one stream. Always request the substream for thumbnails.
    public static func picture(_ id: StreamingChannelID) -> String {
        "/Streaming/channels/\(id.value)/picture"
    }

    // MARK: PTZ (docs/spec-isapi.md §13)

    /// `GET` — the NVR's list of PTZ-capable channels; often 404 on a camera.
    public static let ptzChannels = "/PTZCtrl/channels"
    /// `PUT` — velocity control. Runs until stopped; see `PTZController` for the stop discipline.
    public static func ptzContinuous(_ ch: ChannelID) -> String {
        "/PTZCtrl/channels/\(ch.value)/continuous"
    }
    /// `PUT` — a self-terminating nudge; needs no stop command.
    public static func ptzMomentary(_ ch: ChannelID) -> String {
        "/PTZCtrl/channels/\(ch.value)/momentary"
    }
    /// `PUT` — absolute pan/tilt/zoom in 0.1° and zoom-step units.
    public static func ptzAbsolute(_ ch: ChannelID) -> String {
        "/PTZCtrl/channels/\(ch.value)/absolute"
    }
    /// `PUT` — relative move in device steps.
    public static func ptzRelative(_ ch: ChannelID) -> String {
        "/PTZCtrl/channels/\(ch.value)/relative"
    }
    /// `PUT` — drag-to-zoom. 0…255 space with a lower-left origin.
    public static func ptzPosition3D(_ ch: ChannelID) -> String {
        "/PTZCtrl/channels/\(ch.value)/position3D"
    }
    /// `GET` — the preset list.
    public static func ptzPresets(_ ch: ChannelID) -> String {
        "/PTZCtrl/channels/\(ch.value)/presets"
    }
    /// `PUT`/`DELETE` — one preset slot.
    public static func ptzPreset(_ ch: ChannelID, _ n: Int) -> String {
        "/PTZCtrl/channels/\(ch.value)/presets/\(n)"
    }
    /// `PUT` — recall a preset; empty body.
    public static func ptzPresetGoto(_ ch: ChannelID, _ n: Int) -> String {
        "/PTZCtrl/channels/\(ch.value)/presets/\(n)/goto"
    }
    /// `GET` — the patrol list.
    public static func ptzPatrols(_ ch: ChannelID) -> String {
        "/PTZCtrl/channels/\(ch.value)/patrols"
    }
    /// `PUT` — start a patrol; empty body.
    public static func ptzPatrolStart(_ ch: ChannelID, _ n: Int) -> String {
        "/PTZCtrl/channels/\(ch.value)/patrols/\(n)/start"
    }
    /// `PUT` — stop a patrol; empty body.
    public static func ptzPatrolStop(_ ch: ChannelID, _ n: Int) -> String {
        "/PTZCtrl/channels/\(ch.value)/patrols/\(n)/stop"
    }
    /// `PUT` — recall the home position; empty body.
    public static func ptzHomeGoto(_ ch: ChannelID) -> String {
        "/PTZCtrl/channels/\(ch.value)/homeposition/goto"
    }
    /// `GET` — current absolute position. Polled at 2 Hz only while the PTZ panel is open.
    public static func ptzStatus(_ ch: ChannelID) -> String {
        "/PTZCtrl/channels/\(ch.value)/status"
    }
    /// `GET` — per-channel PTZ capability. Root element is `PTZChanelCap` (Hikvision's typo).
    public static func ptzCapabilities(_ ch: ChannelID) -> String {
        "/PTZCtrl/channels/\(ch.value)/capabilities"
    }
    /// `PUT` — auxiliary output such as a light or wiper.
    public static func ptzAux(_ ch: ChannelID) -> String {
        "/PTZCtrl/channels/\(ch.value)/auxcommand"
    }
    /// `PUT` — continuous focus. Note the path: focus lives under the video input, not `/PTZCtrl`.
    public static func focus(_ ch: ChannelID) -> String {
        "/System/Video/inputs/channels/\(ch.value)/focus"
    }
    /// `PUT` — continuous iris, same unusual path as focus.
    public static func iris(_ ch: ChannelID) -> String {
        "/System/Video/inputs/channels/\(ch.value)/iris"
    }

    // MARK: Events (docs/spec-isapi.md §14)

    /// `GET` — the long-lived `multipart/mixed` alert stream. One per device, never per channel.
    public static let alertStream = "/Event/notification/alertStream"
    /// `GET` — which event types the device has configured.
    public static let eventTriggers = "/Event/triggers"
    /// `GET` — an arming schedule; best-effort, 403/404 means "unknown", never an error.
    public static func eventSchedule(_ triggerID: String) -> String {
        "/Event/schedules/\(triggerID)"
    }
    /// `GET` — the schedule list form, tried when the per-trigger path 404s.
    public static let eventSchedules = "/Event/schedules"
    /// `GET`/`PUT` — motion configuration, including the grid map.
    public static func motionDetection(_ ch: ChannelID) -> String {
        "/System/Video/inputs/channels/\(ch.value)/motionDetection"
    }

    // MARK: Recorded video (docs/spec-isapi.md §15)

    /// `GET` — the recording tracks. A track is not a streaming channel, even when the numbers
    /// coincide.
    public static let recordTracks = "/ContentMgmt/record/tracks"
    /// `POST` — the universal recording search, and the only source of the playback timeline.
    public static let contentSearch = "/ContentMgmt/search"
    /// `POST` — month calendar accelerator, first of the two spellings to probe.
    public static let dailyDistributionTracks = "/ContentMgmt/record/tracks/dailyDistribution"
    /// `POST` — month calendar accelerator, second spelling (some 6.x NVRs).
    public static let dailyDistributionSearch = "/ContentMgmt/search/dailyDistribution"
    /// `GET` — volumes, capacity and health.
    public static let storage = "/ContentMgmt/Storage"
    /// `GET` — quota, meaningful only when `workMode == quota`. 404s on many devices.
    public static let storageQuota = "/ContentMgmt/Storage/quota"

    // MARK: Two-way audio (docs/spec-isapi.md §16)

    /// `GET` — talk-back channels and their codecs.
    public static let twoWayAudioChannels = "/System/TwoWayAudio/channels"
    /// `GET`/`PUT` — one talk-back channel; the `PUT` is read-modify-write.
    public static func twoWayAudioChannel(_ id: Int) -> String {
        "/System/TwoWayAudio/channels/\(id)"
    }
    /// `GET` — the channel's codec menu, carried in an `opt` attribute.
    public static func twoWayAudioCapabilities(_ id: Int) -> String {
        "/System/TwoWayAudio/channels/\(id)/capabilities"
    }
    /// `PUT` — claim the talk channel; empty body. The device allows exactly one open session.
    public static func twoWayAudioOpen(_ id: Int) -> String {
        "/System/TwoWayAudio/channels/\(id)/open"
    }
    /// `POST` (upload) / `GET` (listen) — raw codec bytes, no framing.
    public static func twoWayAudioData(_ id: Int) -> String {
        "/System/TwoWayAudio/channels/\(id)/audioData"
    }
    /// `PUT` — release the talk channel; empty body. Always sent, including on error paths.
    public static func twoWayAudioClose(_ id: Int) -> String {
        "/System/TwoWayAudio/channels/\(id)/close"
    }

    // MARK: Image (docs/spec-isapi.md §17.2)

    /// `GET`/`PUT` — one image sub-resource of a video input channel.
    public static func image(_ ch: ChannelID, _ control: ImageControl) -> String {
        "/Image/channels/\(ch.value)/\(control.resourceName)"
    }
    /// `PUT` — reset image settings; empty body.
    public static func imageDefaults(_ ch: ChannelID) -> String {
        "/Image/channels/\(ch.value)/defaultConfiguration"
    }

    // MARK: Templates

    /// The negative-capability cache key for a resource: channel and stream numbers collapsed to
    /// `{n}` so one 403 on channel 3 suppresses the pointless request on channels 1…64
    /// (docs/spec-isapi.md §18.3).
    ///
    /// Only whole path components made entirely of digits are replaced, so a literal such as
    /// `position3D` survives.
    public static func template(of resource: String) -> String {
        let parts = resource.split(separator: "/", omittingEmptySubsequences: false)
        let collapsed = parts.map { part -> Substring in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return part }
            return "{n}"
        }
        return collapsed.joined(separator: "/")
    }
}
