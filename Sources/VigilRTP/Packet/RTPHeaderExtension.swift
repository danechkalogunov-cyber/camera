//
//  RTPHeaderExtension.swift
//  VigilRTP
//
//  RFC 3550 §5.3.1 header extensions, including the RFC 8285 one-byte (0xBEDE) and two-byte
//  (0x1000 | appBits) element forms.
//  Implements docs/spec-rtp.md §3.3 and docs/API_CONTRACT.md §5.5
//  (`Packet/RTPHeaderExtension.swift`).
//

import Foundation

/// A parsed RTP header extension: its profile identifier and its opaque body.
///
/// An unknown profile is **never** an error. The parser skips exactly `length * 4` bytes and
/// carries the body verbatim, because getting this wrong shifts the payload and produces the
/// "works on cameras A and B but not C" class of bug. Some Hikvision firmware emits a private
/// `0xABAC` extension carrying a BCD wall clock; Vigil exposes it and does not interpret it.
public struct RTPHeaderExtension: Sendable, Hashable {

    // MARK: - Stored Properties

    /// The profile identifier from the first two bytes of the extension header.
    public var profile: UInt16

    /// The extension body: exactly `length * 4` bytes, excluding the 4-byte extension header.
    public var data: Data

    // MARK: - Initialisation

    /// Wraps a profile and an already-bounds-checked body. `RTPPacket.parse` is the only producer
    /// on the network path; tests and fixtures use it directly.
    public init(profile: UInt16, data: Data) {
        self.profile = profile
        self.data = data
    }

    // MARK: - Computed Properties

    /// True for the RFC 8285 one-byte element form.
    @inlinable public var isOneByteForm: Bool { profile == 0xBEDE }

    /// True for the RFC 8285 two-byte element form, whose low nibble carries `appBits`.
    @inlinable public var isTwoByteForm: Bool { profile & 0xFFF0 == 0x1000 }

    /// The four application bits of the two-byte form, or 0 for any other profile.
    @inlinable public var appBits: UInt8 { isTwoByteForm ? UInt8(profile & 0x0F) : 0 }

    // MARK: - Elements

    /// One RFC 8285 extension element.
    public struct Element: Sendable, Hashable {
        /// The element identifier, 1…14 in the one-byte form and 1…255 in the two-byte form.
        public var id: UInt8
        /// The element value. May be empty in the two-byte form, where a zero length is legal.
        public var value: Data

        /// Creates an element. Used by tests and by `elements()`.
        public init(id: UInt8, value: Data) {
            self.id = id
            self.value = value
        }
    }

    /// Decodes the RFC 8285 elements, if this extension uses one of the two element forms.
    ///
    /// Never throws and never traps. A body that runs out mid-element yields the elements decoded so
    /// far with `truncated == true`; the caller counts `MalformedReason.malformedExtension` and
    /// keeps the packet, because a bad extension says nothing about the payload. A profile that is
    /// neither element form yields no elements and `truncated == false` — it is opaque, not broken.
    ///
    /// One-byte form: `id == 0` is a single padding byte, `id == 15` stops parsing (the remainder is
    /// padding), otherwise the low nibble is `length - 1`.
    /// Two-byte form: `id == 0` is a single padding byte, otherwise a full length byte follows.
    public func elements() -> (elements: [Element], truncated: Bool) {
        guard isOneByteForm || isTwoByteForm else { return ([], false) }
        let b = RTPBytes(data)
        var out: [Element] = []
        var offset = 0
        let oneByte = isOneByteForm

        while offset < b.count {
            let first = b[offset]
            if first == 0 {                                   // padding byte in both forms
                offset += 1
                continue
            }
            if oneByte {
                let id = first >> 4
                if id == 15 { break }                         // reserved "stop" marker
                let length = Int(first & 0x0F) + 1
                guard offset + 1 + length <= b.count else { return (out, true) }
                out.append(Element(id: id, value: b.slice((offset + 1)..<(offset + 1 + length))))
                offset += 1 + length
            } else {
                guard offset + 2 <= b.count else { return (out, true) }
                let length = Int(b[offset + 1])
                guard offset + 2 + length <= b.count else { return (out, true) }
                out.append(Element(id: first, value: b.slice((offset + 2)..<(offset + 2 + length))))
                offset += 2 + length
            }
        }
        return (out, false)
    }
}
