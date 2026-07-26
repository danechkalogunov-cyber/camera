//
//  CryptoTests.swift
//  VigilProtocolsTests
//
//  Published test vectors for the hash primitives in Sources/VigilProtocols/Crypto: RFC 1321 MD5,
//  RFC 3174 / FIPS 180-4 SHA-1, FIPS 180-4 SHA-256 and the hex codec. Every expected digest below is
//  either quoted from the specification named in the comment above it or, where a boundary length has
//  no published vector, generated with an independent implementation (Python `hashlib`) and labelled
//  as such — no value here is claimed to come from real hardware.
//
//  Covers docs/spec-rtsp.md §6.3–6.5 and docs/spec-isapi.md §5.2.
//

import Foundation
import Testing

import VigilProtocols

// MARK: - Shared fixtures

/// Reference digests of the ASCII input whose byte *i* is `0x61 + (i % 26)` (`"abcdefghij…"`),
/// truncated to `length`.
///
/// The lengths are the ones where a hand-written digest goes wrong: 55/56/57 straddle the point where
/// the 8-byte length field no longer fits in the final block, 63/64/65 straddle the block boundary
/// itself, and 119/120/121 repeat both one block later. Synthesised with Python `hashlib`, which is an
/// implementation independent of the code under test — these are not published vectors.
struct CryptoBoundaryVector: Sendable, CustomStringConvertible {
    let length: Int
    let md5: String
    let sha1: String
    let sha256: String

    var description: String { "length \(length)" }

    /// The input bytes this vector describes.
    var input: [UInt8] { (0 ..< length).map { UInt8(0x61 + ($0 % 26)) } }
}

let cryptoBoundaryVectors: [CryptoBoundaryVector] = [
    CryptoBoundaryVector(length: 0,
                         md5: "d41d8cd98f00b204e9800998ecf8427e",
                         sha1: "da39a3ee5e6b4b0d3255bfef95601890afd80709",
                         sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
    CryptoBoundaryVector(length: 1,
                         md5: "0cc175b9c0f1b6a831c399e269772661",
                         sha1: "86f7e437faa5a7fce15d1ddcb9eaeaea377667b8",
                         sha256: "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"),
    CryptoBoundaryVector(length: 55,
                         md5: "0d7ae056b2f015cd7dc67494efd658f1",
                         sha1: "a617d006d1ca12671785098a19a87fe58443bde9",
                         sha256: "595615dbe4f0f407ae397d08b4c2cb870cb9b0e11937416f950c5160acf9c005"),
    CryptoBoundaryVector(length: 56,
                         md5: "31fcfb5165169eb55898e7e4cf34d19a",
                         sha1: "4ad5bb7ae3c4024768d364b77c52128ea3cffebe",
                         sha256: "784f623b787495078e93ff28a25b581df0584055a7e71d8cd90c454716b92f51"),
    CryptoBoundaryVector(length: 57,
                         md5: "fd62afaf3aa1e2a52882cb464f5ccc4d",
                         sha1: "e1b3b34da0f7b299090824d9aa81fff6711a79ad",
                         sha256: "808f0738aa4401bdee842e5a15a7baad5809f976d8eb6f9bd2683cebd2e8d671"),
    CryptoBoundaryVector(length: 63,
                         md5: "1b30c0670c15e7da3c2ba7bce77ebe99",
                         sha1: "fc8a5ab77259625085ead3ec96515b3b8d933fad",
                         sha256: "5ca3e1ef5207490eac01a795e5cc94d59582a5118bf9534665c8668d87aa647c"),
    CryptoBoundaryVector(length: 64,
                         md5: "a2eaf6295c32adc403865fd96a2f182b",
                         sha1: "93249d4c2f8903ebf41ac358473148ae6ddd7042",
                         sha256: "2fcd5a0d60e4c941381fcc4e00a4bf8be422c3ddfafb93c809e8d1e2bfffae8e"),
    CryptoBoundaryVector(length: 65,
                         md5: "eba2cce0ca8df47e62414a736b3105a2",
                         sha1: "cf2a63cc308225cf07b498d2309a01dd0df52f67",
                         sha256: "1b3cd1877ab2f2f19f7be001722554f336cb799df0329de0bb4c118dc6abc06d"),
    CryptoBoundaryVector(length: 119,
                         md5: "b05187e08da41fa3ef16bd56afaafd99",
                         sha1: "edd0f1133d0e4ca5f3e98bb7e0295f31d20d2cdb",
                         sha256: "faef67da856d6fd9c8d12f9ed0a4fefd3cf0ce085ab43e2907418d457e3c354b"),
    CryptoBoundaryVector(length: 120,
                         md5: "62af9b597a9f55e16ab2b897387fc052",
                         sha1: "23a58eee587aa1f50d19a969ab36a3fe3e88c393",
                         sha256: "c9512b08619c19fbb503c7da6b46ef20301e5f7a7a5f43989182398536f5c5c8"),
    CryptoBoundaryVector(length: 121,
                         md5: "ac6fa3571578e922ab77f3d08a1ed8c0",
                         sha1: "9b1ce2490012a9e55bbf22fb701dac21e9c29f88",
                         sha256: "6ce395ba6c616565668116ef1d4ab2894dd21b9c3e11e42ec5f57f77417fd623"),
]

/// Chunk sizes used by the streaming-equivalence tests. 1/3 are the pathological small cases, 63/64/65
/// straddle the block boundary, and 7/13/25/26 are the sizes docs/spec-rtsp.md §6.3 asks for.
let cryptoStreamingChunkSizes = [1, 2, 3, 7, 13, 25, 26, 63, 64, 65, 127, 128]

/// Input lengths used by the streaming-equivalence tests.
let cryptoStreamingInputLengths = [0, 1, 2, 55, 56, 57, 63, 64, 65, 119, 120, 121, 200, 1000]

/// `count` bytes of the `"abcdefghij…"` pattern.
func cryptoPatternBytes(_ count: Int) -> [UInt8] {
    (0 ..< count).map { UInt8(0x61 + ($0 % 26)) }
}

// MARK: - MD5

/// RFC 1321 MD5 — the primitive RFC 2617 / RFC 2069 Digest authentication is built on.
@Suite("MD5 (RFC 1321)")
struct MD5Tests {

    /// RFC 1321 appendix A.5 "Test suite" — all seven vectors, verbatim, in the order the RFC lists
    /// them. Also reproduced in docs/spec-rtsp.md §6.3.
    @Test("RFC 1321 §A.5 test suite", arguments: [
        ("", "d41d8cd98f00b204e9800998ecf8427e"),
        ("a", "0cc175b9c0f1b6a831c399e269772661"),
        ("abc", "900150983cd24fb0d6963f7d28e17f72"),
        ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
        ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
        ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
         "d174ab98d277d9f5a5611c2c9f419d9f"),
        ("12345678901234567890123456789012345678901234567890123456789012345678901234567890",
         "57edf4a22be3c955ac49da2e2107b67a"),
    ])
    func rfc1321TestSuite(input: String, expected: String) {
        #expect(MD5.hexDigest(input) == expected)
        // The same value through the incremental API and the byte-array entry points.
        #expect(MD5.hex(MD5.digest(Array(input.utf8))) == expected)
        #expect(Hex.lowercase(MD5.digest(Data(input.utf8))) == expected)
    }

    @Test("Digest of the empty message is 16 bytes and matches RFC 1321")
    func emptyMessage() {
        let digest = MD5.digest([])
        #expect(digest.count == MD5.digestByteCount)
        #expect(MD5.digestByteCount == 16)
        #expect(Hex.lowercase(digest) == "d41d8cd98f00b204e9800998ecf8427e")
        // A context that is finalized without any update at all, and one fed only empty chunks.
        #expect(Hex.lowercase(MD5().finalize()) == "d41d8cd98f00b204e9800998ecf8427e")
        var context = MD5()
        context.update([])
        context.update(Data())
        context.update("")
        #expect(Hex.lowercase(context.finalize()) == "d41d8cd98f00b204e9800998ecf8427e")
    }

    /// RFC 2617 §3.5 "Example" — the worked Digest exchange, end to end. This is the vector that
    /// proves the primitive is usable for real authentication and not merely that it hashes:
    /// `Mufasa` / `Circle Of Life` / `testrealm@host.com`, `GET /dir/index.html`,
    /// nonce `dcd98b7102dd2f0e8b11d0f600bfb0c093`, cnonce `0a4f113b`, `nc=00000001`, `qop=auth`.
    /// Restated as vector (a) in docs/spec-rtsp.md §6.5.
    @Test("RFC 2617 §3.5 worked Digest example: A1, A2 and response")
    func rfc2617WorkedExample() {
        let nonce = "dcd98b7102dd2f0e8b11d0f600bfb0c093"
        let cnonce = "0a4f113b"

        let ha1 = MD5.hexDigest("Mufasa:testrealm@host.com:Circle Of Life")
        #expect(ha1 == "939e7578ed9e3c518a452acee763bce9")

        let ha2 = MD5.hexDigest("GET:/dir/index.html")
        #expect(ha2 == "39aff3a2bab6126f332b942af96d3366")

        let response = MD5.hexDigest("\(ha1):\(nonce):00000001:\(cnonce):auth:\(ha2)")
        #expect(response == "6629fae49393a05397450978507c4ef1")

        // The same response assembled incrementally, the way RTSPAuthenticator will build it: one
        // `update` per field, no intermediate concatenated string.
        var context = MD5()
        context.update(ha1)
        context.update(":")
        context.update(nonce)
        context.update(":")
        context.update("00000001")
        context.update(":")
        context.update(cnonce)
        context.update(":")
        context.update("auth")
        context.update(":")
        context.update(ha2)
        #expect(Hex.lowercase(context.finalize()) == "6629fae49393a05397450978507c4ef1")
    }

    /// Golden no-`qop` (RFC 2069) vectors from docs/spec-rtsp.md §6.5(b) — `admin` / `Hik12345`,
    /// realm `IP Camera(52491)`, nonce `3a2f5c8e1b7d4906f2e5a8c1d4b70e93`. The RFC 2069 shape is the
    /// common case on Hikvision 5.2–5.5 firmware (docs/spec-isapi.md §5.1), so it is pinned here as
    /// well as in the RTSP layer's own tests.
    @Test("RFC 2069 no-qop responses, docs/spec-rtsp.md §6.5(b)", arguments: [
        ("OPTIONS", "rtsp://192.168.1.64:554/Streaming/Channels/101",
         "430442026acf176cb1cd78f7bdd97904", "7a71d2670d28b6741cd8311d5c2faa39"),
        ("DESCRIBE", "rtsp://192.168.1.64:554/Streaming/Channels/101",
         "b5032047f3acc3227e88a91732cc21a9", "33439787cead5b387dab032b929cd5aa"),
        ("SETUP", "rtsp://192.168.1.64:554/Streaming/Channels/101/trackID=1",
         "86636168ed1619b40ab33a3e55c3439f", "cc40451c686fe00f49dab7ead43cf51e"),
        ("TEARDOWN", "rtsp://192.168.1.64:554/Streaming/Channels/101",
         "aec2fa393b8980483d7a253d0950f1c2", "6c562c1ab1c2a7b664e7303d52167fcc"),
    ])
    func hikvisionNoQopVectors(method: String, uri: String, expectedHA2: String, expectedResponse: String) {
        let ha1 = MD5.hexDigest("admin:IP Camera(52491):Hik12345")
        #expect(ha1 == "b77ebbd873cb0b706fec7d517a8bd70e")

        let ha2 = MD5.hexDigest("\(method):\(uri)")
        #expect(ha2 == expectedHA2)

        let response = MD5.hexDigest("\(ha1):3a2f5c8e1b7d4906f2e5a8c1d4b70e93:\(ha2)")
        #expect(response == expectedResponse)
    }

    /// `qop=auth` against an NVR — docs/spec-rtsp.md §6.5(c), first row.
    @Test("qop=auth response, docs/spec-rtsp.md §6.5(c)")
    func nvrQopAuthVector() {
        let ha1 = MD5.hexDigest("admin:DS-7608NI-K2(24680):Nvr#2024")
        #expect(ha1 == "992d115501e817da1a9b5886c47de657")

        let ha2 = MD5.hexDigest("DESCRIBE:rtsp://192.168.1.200:554/Streaming/Channels/301")
        #expect(ha2 == "c8a2ad16043ed9fd8276ea879db655a3")

        let response = MD5.hexDigest(
            "\(ha1):b7c41e0a9d3f625814ae7c0b6d29f4e1:00000001:1c8f4a09be23d7f5:auth:\(ha2)"
        )
        #expect(response == "7a525b747736353ecd4833fd99cbc565")
    }

    /// `MD5-sess` HA1 — docs/spec-rtsp.md §6.5(d): `MD5hex(MD5hex(A1) ":" nonce ":" cnonce)`.
    @Test("MD5-sess HA1, docs/spec-rtsp.md §6.5(d)")
    func md5SessionHA1() {
        let inner = MD5.hexDigest("admin:IP Camera(52491):Hik12345")
        let sessionHA1 = MD5.hexDigest("\(inner):3a2f5c8e1b7d4906f2e5a8c1d4b70e93:1c8f4a09be23d7f5")
        #expect(sessionHA1 == "8e02847dbbf1e8b0643c4dc284808c30")
    }

    @Test("Digests at block and length-field boundaries", arguments: cryptoBoundaryVectors)
    func boundaryLengths(vector: CryptoBoundaryVector) {
        #expect(Hex.lowercase(MD5.digest(vector.input)) == vector.md5)
    }

    @Test("Chunked updates equal the one-shot digest", arguments: cryptoStreamingChunkSizes)
    func streamingEquivalence(chunkSize: Int) {
        for length in cryptoStreamingInputLengths {
            let input = cryptoPatternBytes(length)
            let oneShot = Hex.lowercase(MD5.digest(input))
            var context = MD5()
            var offset = 0
            while offset < input.count {
                let end = min(offset + chunkSize, input.count)
                context.update(input[offset ..< end])
                offset = end
            }
            #expect(Hex.lowercase(context.finalize()) == oneShot,
                    "chunk size \(chunkSize), input length \(length)")
        }
    }

    @Test("Every update entry point yields the same digest")
    func updateOverloadsAgree() {
        let input = cryptoPatternBytes(200)
        let expected = Hex.lowercase(MD5.digest(input))

        var viaData = MD5()
        viaData.update(Data(input))
        #expect(Hex.lowercase(viaData.finalize()) == expected)

        var viaRaw = MD5()
        input.withUnsafeBytes { viaRaw.update($0) }
        #expect(Hex.lowercase(viaRaw.finalize()) == expected)

        var viaSlice = MD5()
        viaSlice.update(input[0 ..< 100])
        viaSlice.update(input[100 ..< 200])
        #expect(Hex.lowercase(viaSlice.finalize()) == expected)

        // A collection with no contiguous storage takes the stack-scratch path in `update`.
        var viaNonContiguous = MD5()
        viaNonContiguous.update(input.reversed())
        #expect(Hex.lowercase(viaNonContiguous.finalize())
            == Hex.lowercase(MD5.digest(Array(input.reversed()))))

        #expect(MD5.hexDigest(input) == expected)
    }
}

// MARK: - SHA-1

/// RFC 3174 / FIPS 180-4 SHA-1 — needed by the ONVIF WS-Security UsernameToken.
@Suite("SHA-1 (RFC 3174 / FIPS 180-4)")
struct SHA1Tests {

    /// RFC 3174 §7.3 test data TEST1–TEST4, plus the empty message (FIPS 180-4 / NIST example).
    /// TEST3 is 1,000,000 repetitions of `"a"`; TEST4 is 10 repetitions of the 64-character block
    /// `"0123456701234567012345670123456701234567012345670123456701234567"`.
    @Test("RFC 3174 §7.3 test vectors", arguments: [
        ("", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
        ("abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "84983e441c3bd26ebaae4aa1f95129e5e54670f1"),
        (String(repeating: "0123456701234567012345670123456701234567012345670123456701234567", count: 10),
         "dea356a2cddd90c7a7ecedc5ebb563934f460452"),
    ])
    func rfc3174TestVectors(input: String, expected: String) {
        #expect(SHA1.hexDigest(input) == expected)
    }

    /// RFC 3174 §7.3 TEST3: one million `"a"` characters. Fed in 1,000-byte chunks so the streaming
    /// path, not just the one-shot path, is what produces the published value.
    @Test("RFC 3174 TEST3: one million 'a'")
    func oneMillionCharacters() {
        let chunk = [UInt8](repeating: 0x61, count: 1000)
        var context = SHA1()
        for _ in 0 ..< 1000 {
            context.update(chunk)
        }
        #expect(Hex.lowercase(context.finalize()) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    @Test("Digest of the empty message is 20 bytes and matches FIPS 180-4")
    func emptyMessage() {
        let digest = SHA1.digest([])
        #expect(digest.count == SHA1.digestByteCount)
        #expect(SHA1.digestByteCount == 20)
        #expect(Hex.lowercase(digest) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(Hex.lowercase(SHA1().finalize()) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    @Test("Digests at block and length-field boundaries", arguments: cryptoBoundaryVectors)
    func boundaryLengths(vector: CryptoBoundaryVector) {
        #expect(Hex.lowercase(SHA1.digest(vector.input)) == vector.sha1)
    }

    @Test("Chunked updates equal the one-shot digest", arguments: cryptoStreamingChunkSizes)
    func streamingEquivalence(chunkSize: Int) {
        for length in cryptoStreamingInputLengths {
            let input = cryptoPatternBytes(length)
            let oneShot = Hex.lowercase(SHA1.digest(input))
            var context = SHA1()
            var offset = 0
            while offset < input.count {
                let end = min(offset + chunkSize, input.count)
                context.update(input[offset ..< end])
                offset = end
            }
            #expect(Hex.lowercase(context.finalize()) == oneShot,
                    "chunk size \(chunkSize), input length \(length)")
        }
    }

    /// The ONVIF WS-Security `PasswordDigest` shape: `SHA1(nonce || created || password)`, fed as
    /// three separate updates the way the SOAP builder will. Cross-checked against the one-shot
    /// digest of the concatenation, so this pins composition rather than a magic constant.
    @Test("WS-UsernameToken shape: SHA1(nonce || created || password)")
    func usernameTokenComposition() {
        let nonce: [UInt8] = [0x2f, 0x8a, 0x1b, 0x00, 0xff, 0x40, 0x9c, 0x71,
                              0x13, 0x5e, 0xa2, 0x60, 0x0d, 0xcc, 0x84, 0x39]
        let created = "2024-01-15T09:00:00Z"
        let password = "Hik12345"

        var context = SHA1()
        context.update(nonce)
        context.update(created)
        context.update(password)
        let streamed = context.finalize()

        var concatenated = nonce
        concatenated.append(contentsOf: Array(created.utf8))
        concatenated.append(contentsOf: Array(password.utf8))
        #expect(streamed == SHA1.digest(concatenated))
        #expect(streamed.count == 20)
    }
}

// MARK: - SHA-256

/// FIPS 180-4 SHA-256 — used for certificate/SPKI fingerprints and the encrypted config export.
@Suite("SHA-256 (FIPS 180-4)")
struct SHA256Tests {

    /// FIPS 180-4 appendix B examples B.1 (`"abc"`, one block) and B.2 (the 448-bit message, two
    /// blocks), plus the empty message (NIST example vector).
    @Test("FIPS 180-4 appendix B examples", arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
    ])
    func fips180Examples(input: String, expected: String) {
        #expect(SHA256.hexDigest(input) == expected)
    }

    /// FIPS 180-4 appendix B.3: one million `"a"` characters. Fed in 1,000-byte chunks so the
    /// streaming path produces the published value.
    @Test("FIPS 180-4 §B.3: one million 'a'")
    func oneMillionCharacters() {
        let chunk = [UInt8](repeating: 0x61, count: 1000)
        var context = SHA256()
        for _ in 0 ..< 1000 {
            context.update(chunk)
        }
        #expect(Hex.lowercase(context.finalize())
            == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test("Digest of the empty message is 32 bytes and matches FIPS 180-4")
    func emptyMessage() {
        let digest = SHA256.digest([])
        #expect(digest.count == SHA256.digestByteCount)
        #expect(SHA256.digestByteCount == 32)
        #expect(Hex.lowercase(digest)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(Hex.lowercase(SHA256().finalize())
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("Digests at block and length-field boundaries", arguments: cryptoBoundaryVectors)
    func boundaryLengths(vector: CryptoBoundaryVector) {
        #expect(Hex.lowercase(SHA256.digest(vector.input)) == vector.sha256)
    }

    @Test("Chunked updates equal the one-shot digest", arguments: cryptoStreamingChunkSizes)
    func streamingEquivalence(chunkSize: Int) {
        for length in cryptoStreamingInputLengths {
            let input = cryptoPatternBytes(length)
            let oneShot = Hex.lowercase(SHA256.digest(input))
            var context = SHA256()
            var offset = 0
            while offset < input.count {
                let end = min(offset + chunkSize, input.count)
                context.update(input[offset ..< end])
                offset = end
            }
            #expect(Hex.lowercase(context.finalize()) == oneShot,
                    "chunk size \(chunkSize), input length \(length)")
        }
    }

    @Test("Every update entry point yields the same digest")
    func updateOverloadsAgree() {
        let input = cryptoPatternBytes(300)
        let expected = Hex.lowercase(SHA256.digest(input))

        var viaData = SHA256()
        viaData.update(Data(input))
        #expect(Hex.lowercase(viaData.finalize()) == expected)

        var viaRaw = SHA256()
        input.withUnsafeBytes { viaRaw.update($0) }
        #expect(Hex.lowercase(viaRaw.finalize()) == expected)

        var viaNonContiguous = SHA256()
        viaNonContiguous.update(input.reversed())
        #expect(Hex.lowercase(viaNonContiguous.finalize())
            == Hex.lowercase(SHA256.digest(Array(input.reversed()))))
    }
}

// MARK: - Hex

/// The hex codec shared by the digests and by the Hikvision hex-valued parameters.
@Suite("Hex encoding")
struct HexTests {

    @Test("Encoding is two lowercase characters per byte, in order")
    func encodesLowercase() {
        #expect(Hex.lowercase([0x00, 0x0f, 0x10, 0xa5, 0xff]) == "000f10a5ff")
        #expect(Hex.encode([0xde, 0xad, 0xbe, 0xef]) == "deadbeef")
        // `config=1210` style values from the ISAPI layer are plain hex, no separators or prefix.
        #expect(Hex.lowercase(Array("1210".utf8)) == "31323130")
    }

    @Test("Uppercase encoding uses A-F")
    func encodesUppercase() {
        #expect(Hex.uppercase([0xde, 0xad, 0xbe, 0xef]) == "DEADBEEF")
        #expect(Hex.encode([0x00, 0x0f, 0xa5], uppercase: true) == "000FA5")
    }

    @Test("Empty input encodes to the empty string and decodes to no bytes")
    func emptyInput() throws {
        #expect(Hex.lowercase([]) == "")
        #expect(Hex.uppercase([]) == "")
        #expect(try Hex.decode("").isEmpty)
        #expect(try Hex.decode(bytes: [UInt8]()).isEmpty)
        #expect(Hex.decodeOrNil("")?.isEmpty == true)
    }

    @Test("Encode then decode returns the original bytes for every byte value")
    func roundTripsAllByteValues() throws {
        let all = (0 ... 255).map { UInt8($0) }
        #expect(try Hex.decode(Hex.lowercase(all)) == all)
        #expect(try Hex.decode(Hex.uppercase(all)) == all)
        // Digest output round-trips too, which is what the certificate-pinning store relies on.
        let digest = SHA256.digest("vigil")
        #expect(try Hex.decode(Hex.lowercase(digest)) == digest)
    }

    @Test("Mixed case decodes")
    func decodesMixedCase() throws {
        #expect(try Hex.decode("DeAdBeEf") == [0xde, 0xad, 0xbe, 0xef])
    }

    @Test("Odd-length input is rejected")
    func rejectsOddLength() {
        #expect(throws: Hex.DecodeError.oddLength(count: 1)) { try Hex.decode("a") }
        #expect(throws: Hex.DecodeError.oddLength(count: 3)) { try Hex.decode("abc") }
        #expect(throws: Hex.DecodeError.oddLength(count: 5)) { try Hex.decode("deadb") }
        #expect(Hex.decodeOrNil("abc") == nil)
    }

    @Test("Non-hex characters are rejected with their position")
    func rejectsNonHexCharacters() {
        // 'g' at index 1.
        #expect(throws: Hex.DecodeError.invalidCharacter(byte: 0x67, index: 1)) { try Hex.decode("ag") }
        // Whitespace is not skipped: tolerating it would silently change the decoded value. Note the
        // even length — the length check runs first, so "de ad" reports oddLength instead.
        #expect(throws: Hex.DecodeError.invalidCharacter(byte: 0x20, index: 2)) {
            try Hex.decode("de  ad")
        }
        #expect(throws: Hex.DecodeError.oddLength(count: 5)) { try Hex.decode("de ad") }
        // A `0x` prefix is not accepted either — 'x' at index 1.
        #expect(throws: Hex.DecodeError.invalidCharacter(byte: 0x78, index: 1)) {
            try Hex.decode("0xdead")
        }
        // Non-ASCII text: the first offending UTF-8 code unit is reported. "éé" is C3 A9 C3 A9.
        #expect(throws: Hex.DecodeError.invalidCharacter(byte: 0xc3, index: 0)) { try Hex.decode("éé") }
        #expect(Hex.decodeOrNil("zz") == nil)
    }

    @Test("The byte-collection convenience matches the enum entry points")
    func byteCollectionConvenience() {
        let bytes: [UInt8] = [0x00, 0x9f, 0xff]
        #expect(bytes.hexStringLowercase == "009fff")
        #expect(bytes.hexStringUppercase == "009FFF")
        #expect(MD5.digest("abc").hexStringLowercase == "900150983cd24fb0d6963f7d28e17f72")
    }
}
