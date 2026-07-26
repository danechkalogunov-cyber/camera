# ASSIGNMENT: rtp

AGENT_LABEL for your log lines is: spec:rtp
Write the file: /home/user/camera/docs/spec-rtp.md

Author the RTP/RTCP and depacketization specification (module VigilRTP).
Cover:
- RTP fixed header (RFC 3550) with a bit/byte layout table, CSRC list, header extension
  (0xBEDE one-byte form and the 0x1000 two-byte form), and padding handling.
- **H.264 depacketization (RFC 6184)**: single NAL, STAP-A (mention STAP-B/MTAP), FU-A reassembly
  with the exact FU indicator/header bit math to rebuild the original NAL header, handling of a
  lost first or last fragment, and DON.
- **H.265 depacketization (RFC 7798)**: the 2-byte PayloadHdr layout (F, Type, LayerId, TID),
  AP aggregation packets, FU with S and E bits, DONL when sprop-max-don-diff is greater than 0;
  how to detect VPS/SPS/PPS (types 32/33/34), IRAP types (16..23) and slice types (0..21).
- **AAC (RFC 3640, mode=AAC-hbr)**: the AU-header-Length prefix, sizeLength / indexLength /
  indexDeltaLength taken from the fmtp config, multi-AU packets, and how to build ADTS or an
  AudioSpecificConfig from a hex config string such as config=1210. Handle the case-insensitivity
  of mpeg4-generic vs MPEG4-GENERIC.
- **G.711 PCMA/PCMU (payload types 8 and 0)** and G.726 as used by Hikvision two-way audio;
  give the mu-law and A-law to linear PCM conversion approach.
- Frame-boundary detection: the RTP marker bit versus timestamp change, and the correct rule for
  H.264/H.265 access-unit boundaries (first_mb_in_slice == 0 /
  first_slice_segment_in_pic_flag). Implement AU splitting that does NOT rely solely on the
  marker bit, because some Hikvision firmware sets it unreliably. This is important - be explicit.
- **Reorder/jitter buffer**: a bounded sequence-number-ordered ring with 16-bit wraparound-safe
  comparison (give the seqLess helper), depth configurable in packets AND milliseconds,
  late/duplicate/lost accounting, an onGap hook that requests an IDR, and a low-latency mode that
  flushes immediately while packets are in order.
- Timestamp math: the 90 kHz video clock mapped to MediaTimestamp (define it as a struct with an
  Int64 value and an Int32 timescale), wraparound across 2^32, RTCP SR NTP-to-RTP mapping to
  derive wall-clock time, and the drift-correcting presentation clock (describe the EWMA/PLL).
- RTCP: parse SR / RR / SDES / BYE, generate a Receiver Report with fraction-lost and interarrival
  jitter per RFC 3550 appendix A.8 (give the jitter formula), RTCP interval rules, and note that
  interleaved channel 1 carries RTCP.
- Statistics: define a StreamStatistics struct (fps, kbps EWMA, packets lost, out-of-order,
  jitter in ms, keyframe interval, decode queue depth, dropped frames, latency estimate) and the
  exact update algebra including the EWMA constants.
- The public API: a Depacketizer protocol with a mutating push(packet) returning frames, and the
  EncodedFrame definition (Foundation-only: data as 4-byte-length-prefixed NALs, pts, dts,
  isKeyframe, codec, parameterSets).

Create parent directories if needed. Be exhaustive and concrete.
