//
//  VideoTileView+VideoSink.swift
//  VigilRender
//
//  The conformance that lets `VigilVideo`'s decode pipeline hand frames to the tile: one line of
//  code and a page of reasons it is safe.
//  Implements docs/API_CONTRACT.md §2 R-51 and §4.9, and docs/spec-video-pipeline.md §2.4.
//
//  NONE OF THIS HAS BEEN COMPILED. The container is Linux; `#if os(macOS)` compiles it to nothing.
//  What has been checked by hand, member by member, is that the two spellings match — see below.
//
//  `CoreMedia` and `VigilProtocols` are imported although no name from either is written here:
//  Swift imports are file-scoped, and the requirements this conformance is checked against mention
//  `CMSampleBuffer`, `VideoFormatInfo` and `MediaInstant`. Importing them costs nothing and removes
//  the one way a four-line file could fail to build on a machine this agent cannot reach.
//

#if os(macOS)

import CoreMedia
import VigilProtocols
import VigilVideo

// MARK: - VideoSink

/// `VideoTileView` is the one implementer of `VigilVideo.VideoSink` (docs/API_CONTRACT.md §2 R-51).
///
/// **Why the body is empty.** Both members the slice needs are already declared on the view itself,
/// with the exact spellings the protocol asks for — checked declaration against declaration:
///
///     // VideoSink, VigilVideo/Support/VideoSink.swift
///     nonisolated func enqueue(_ sampleBuffer: CMSampleBuffer, format: VideoFormatInfo,
///                              generation: UInt32)
///     nonisolated func streamDidReset()
///
///     // VideoTileView, VigilRender/Tile/VideoTileView.swift
///     public nonisolated func enqueue(_ sampleBuffer: CMSampleBuffer, format: VideoFormatInfo,
///                                     generation: UInt32)
///     public nonisolated func streamDidReset()
///
/// Every other member — `willChangeFormat`, `didChangeFormat`, `streamDidEnd`, `didDropFrames`,
/// `didStall`, `didRecover` — takes the no-op default from `VigilVideo`'s protocol extension, which
/// is what the slice wants: the tile learns about a stall from its own layer, and it must do
/// nothing at all on a format change, because "keep showing the current image" is the
/// no-black-flash rule.
///
/// **Why a `@MainActor` class may conform to an `AnyObject, Sendable` protocol.** A class isolated
/// to a global actor is implicitly `Sendable`, and `NSView` is itself `@MainActor` in the SDK, so
/// the superclass does not block that inference. Both members are `nonisolated`, so the pipeline
/// actor calls them synchronously, without hopping to the main actor and without crossing an
/// isolation boundary — which is why the non-`Sendable` `CMSampleBuffer` needs no box (R-51).
/// `impl:video` type-checked this exact shape on Linux before landing the protocol.
///
/// **Why this is a separate file.** `VideoTileView.swift` imports no `VigilVideo`: the view is
/// written against AppKit, AVFoundation and `VigilProtocols` alone, and keeping the dependency in
/// one small file makes it plain that the conformance costs the render layer nothing but an import.
extension VideoTileView: VideoSink {}

#endif  // os(macOS)
