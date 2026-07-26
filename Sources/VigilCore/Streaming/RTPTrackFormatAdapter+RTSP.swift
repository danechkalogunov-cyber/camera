//
//  RTPTrackFormatAdapter+RTSP.swift
//  VigilCore
//
//  The RTSP-typed half of `RTPTrackFormatAdapter`: `SDPMediaDescription` and `RTSPTrack` in,
//  `RTPTrackFormat` and `RTSPTrackTimingSeed` out. Every line of judgement is in `VigilRTP`'s
//  `RTPTrackFormatAdapter`, which is pure and Linux-tested; this file only unpacks two RTSP value
//  types into its arguments.
//  Implements docs/API_CONTRACT.md §4.7 (`RTPTrackFormatAdapter`).
//
//  WHY THIS IS NOT IN `VigilTransport`, where API_CONTRACT §5.9 puts the file: the manifest row
//  lists `VigilRTP` as its dependency, but `Package.swift` gives `VigilTransport` only
//  `VigilProtocols`, `VigilRTSP` and `VigilDiscovery`. An `import VigilRTP` there would compile on
//  Linux — the whole file is inside `#if os(macOS)`, so the Linux build never reads it — and fail
//  on the customer's Mac, which is the exact failure mode this project has a lint rule about.
//  `VigilCore` is the only shipping target that already imports both, and it is the only consumer:
//  `StreamController` is what turns a negotiated track into a receiver. Closing the manifest gap
//  properly means adding the `VigilRTP` edge to `VigilTransport`, which this agent may not do.
//

#if os(macOS)

import Foundation

import VigilProtocols
import VigilRTP
import VigilRTSP

// MARK: - SDP and RTSP inputs

extension RTPTrackFormatAdapter {

    /// Builds the RTP track format for one parsed SDP media section.
    ///
    /// The SDP parser has already lower-cased the `a=fmtp` keys and decoded the `sprop-*` values, so
    /// they are passed straight through; the adapter re-normalises the keys anyway, because a
    /// `nil` `parameterSets` here means "this codec has none", not "nobody looked".
    ///
    /// - Parameter media: one `m=` section, with its payload type already selected by the parser.
    /// - Throws: `RTPError.unsupportedEncoding` when the section offers a codec Vigil cannot
    ///   depacketize — including the `application` sections a Hikvision NVR adds for metadata —
    ///   and `RTPError.invalidClockRate` for a negative `a=rtpmap` rate.
    public static func make(from media: SDPMediaDescription) throws(RTPError) -> RTPTrackFormat {
        try make(payloadType: media.payloadType,
                 encodingName: media.encodingName,
                 clockRate: media.clockRate,
                 channels: media.channels,
                 fmtp: media.fmtp,
                 parameterSets: media.parameterSets)
    }

    /// Builds the RTP track format for a track the session machine has finished negotiating.
    ///
    /// This is the path the running app takes: `RTSPConnection` emits `.track(RTSPTrack)` after
    /// each `SETUP`, and `StreamController` turns it into an `RTPTrackReceiver`.
    ///
    /// `RTSPTrack.clockRate` is a `UInt32` and `RTPTrackFormat.clockRate` an `Int32`; the
    /// conversion clamps rather than trapping, because the value came off the wire. A rate above
    /// `Int32.max` clamps to `Int32.max` and is then merely wrong rather than fatal —
    /// `RTPTrackFormat.hasUnexpectedVideoClockRate` reports it.
    ///
    /// - Parameter track: one negotiated track.
    /// - Throws: as `make(from: SDPMediaDescription)`.
    public static func make(from track: RTSPTrack) throws(RTPError) -> RTPTrackFormat {
        try make(payloadType: track.payloadType,
                 encodingName: track.encodingName,
                 clockRate: Int32(clamping: track.clockRate),
                 channels: track.channelCount.map { Int32(clamping: $0) },
                 fmtp: track.fmtpParameters,
                 parameterSets: track.parameterSets)
    }

    /// Converts the session machine's presentation-time seed into the receiver's.
    ///
    /// The two types carry the same seven fields and deliberately do not share a declaration:
    /// `RTSPTrackTiming` also carries the track id, which routes it, and `VigilRTP` has no concept
    /// of a track id. Nothing is computed on the way across — `VigilRTSP` performs no modular
    /// arithmetic on RTP timestamps and neither does this (API_CONTRACT §2 R-26).
    ///
    /// - Parameter timing: the seed emitted after `PLAY`.
    public static func seed(from timing: RTSPTrackTiming) -> RTSPTrackTimingSeed {
        RTSPTrackTimingSeed(clockRate: timing.clockRate,
                            initialSequence: timing.initialSequence,
                            initialRTPTimestamp: timing.initialRTPTimestamp,
                            absoluteStart: timing.absoluteStart,
                            scale: timing.scale,
                            isRateControlDisabled: timing.isRateControlDisabled,
                            playResponseInstant: timing.playResponseInstant)
    }
}

#endif  // os(macOS)
