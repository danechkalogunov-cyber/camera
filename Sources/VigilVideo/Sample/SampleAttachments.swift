//
//  SampleAttachments.swift
//  VigilVideo
//
//  The per-sample attachment dictionary: `NotSync`, `DependsOnOthers`, `DisplayImmediately`,
//  `DoNotDisplay`.
//  Implements docs/spec-video-pipeline.md §5.3.
//
//  **This code has never been compiled.** There is no CoreMedia on Linux.
//

#if os(macOS)

import CoreMedia
import VigilProtocols

// MARK: - SampleAttachments

/// Sets the attachments that tell `AVSampleBufferDisplayLayer` and VideoToolbox what a sample is.
///
/// **The flags read inverted from their names, and getting one wrong is silent.** `NotSync = true`
/// means "this is *not* a random-access point" — it goes on every **non**-keyframe, and on a
/// keyframe it is *omitted* rather than set to `false`. A stream where every sample is marked
/// `NotSync` never starts; a stream where none is loses the layer's licence to drop.
package enum SampleAttachments {

    // MARK: - Constants

    /// `kCMSampleBufferError_RequiredParameterMissing`, written as a literal so this file does not
    /// depend on that symbol's exact spelling in the SDK. Reported when the attachments array comes
    /// back empty or absent, which cannot happen for a sample buffer CoreMedia has just created —
    /// but a swallowed failure here is exactly the "no video, no error" outcome we refuse to ship.
    private static let attachmentsMissingStatus: OSStatus = -12_731

    // MARK: - Public API

    /// Applies the attachments for one sample.
    ///
    /// Signatures this is written against:
    /// ```
    /// func CMSampleBufferGetSampleAttachmentsArray(
    ///     _ sbuf: CMSampleBuffer, createIfNecessary: Bool) -> CFArray?
    /// func CFArrayGetCount(_ theArray: CFArray!) -> CFIndex
    /// func CFArrayGetValueAtIndex(_ theArray: CFArray!, _ idx: CFIndex) -> UnsafeRawPointer!
    /// func CFDictionarySetValue(
    ///     _ theDict: CFMutableDictionary!, _ key: UnsafeRawPointer!, _ value: UnsafeRawPointer!)
    /// ```
    ///
    /// - Parameters:
    ///   - sample: The buffer to annotate. Its attachments array is created if it has none.
    ///   - isKeyframe: True for an IDR (H.264 type 5) or IRAP (H.265 types 16–23). When false,
    ///     `NotSync` and `DependsOnOthers` are both set.
    ///   - displayImmediately: True on the live path only. Sets
    ///     `kCMSampleAttachmentKey_DisplayImmediately`, which makes the layer show the frame as soon
    ///     as it decodes and ignore the timebase. **Never set it in recorded mode** — it breaks rate
    ///     control, seek and reverse.
    ///   - doNotDisplay: True for fine-seek pre-roll frames, which are decoded for reference and
    ///     never shown. Always false on the live path.
    /// - Throws: `DecodeError.sampleBufferFailed(status:)` when the attachments array is missing,
    ///   carrying the numeric status.
    package static func apply(to sample: CMSampleBuffer, isKeyframe: Bool,
                              displayImmediately: Bool,
                              doNotDisplay: Bool = false) throws(DecodeError) {

        // `createIfNecessary: true` is what makes this work on a freshly created sample buffer:
        // with `false` the array is nil until something else has already made one.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,
                                                                        createIfNecessary: true),
              CFArrayGetCount(attachments) > 0,
              let entry = CFArrayGetValueAtIndex(attachments, 0) else {
            throw DecodeError.sampleBufferFailed(status: attachmentsMissingStatus)
        }

        // One entry per sample, and we never batch, so index 0 is the only entry there is.
        // The array's elements are `CMMutableDictionaryRef`s owned by the sample buffer; the cast
        // does not transfer ownership and the dictionary must not be released.
        let dictionary = unsafeBitCast(entry, to: CFMutableDictionary.self)

        // `kCFBooleanTrue` imports as an implicitly-unwrapped optional. Binding it to a
        // non-optional local once keeps the call sites below readable and keeps the implicit
        // unwrap in one reviewable place; it is a CF singleton and is never nil.
        let cfTrue: CFBoolean = kCFBooleanTrue

        if !isKeyframe {
            // NOT a sync sample. Omitted entirely on keyframes — setting it `false` there is not
            // the same thing and confuses some VT decoders.
            set(key: kCMSampleAttachmentKey_NotSync, to: cfTrue, in: dictionary)
            // Safe for the layer to drop when it is behind.
            set(key: kCMSampleAttachmentKey_DependsOnOthers, to: cfTrue, in: dictionary)
        }

        if displayImmediately {
            // The low-latency switch: decode and show, do not wait for a timebase.
            set(key: kCMSampleAttachmentKey_DisplayImmediately, to: cfTrue, in: dictionary)
        }

        if doNotDisplay {
            set(key: kCMSampleAttachmentKey_DoNotDisplay, to: cfTrue, in: dictionary)
        }

        // Never set: `EarlierDisplayTimesAllowed` (we do not reorder in the layer). `PartialSync`
        // for H.265 CRA/BLA and `IsDependedOnByOthers` for droppable frames are spec §5.3 rows the
        // slice does not need and are deliberately absent rather than guessed at.
    }

    // MARK: - Private Helpers

    /// One `CFDictionarySetValue`, with the two `Unmanaged` conversions written out.
    ///
    /// `passUnretained` is correct for both: the keys are CoreMedia's own global `CFString`
    /// constants and the values are the CF boolean singletons, so neither can be deallocated, and
    /// `CFDictionarySetValue` retains what it stores.
    private static func set(key: CFString, to value: CFBoolean, in dictionary: CFMutableDictionary) {
        let keyPointer = Unmanaged.passUnretained(key).toOpaque()
        let valuePointer = Unmanaged.passUnretained(value).toOpaque()
        CFDictionarySetValue(dictionary, keyPointer, valuePointer)
    }
}

#endif
