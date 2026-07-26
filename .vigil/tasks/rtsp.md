# ASSIGNMENT: rtsp

AGENT_LABEL for your log lines is: spec:rtsp
Write the file: /home/user/camera/docs/spec-rtsp.md

Author the RTSP client specification (module VigilRTSP).
Cover:
- RTSP 1.0 (RFC 2326) message grammar; exact request/response serialization including CSeq,
  User-Agent, Session, Require, Content-Length.
- The full method sequence OPTIONS -> DESCRIBE -> SETUP (per track) -> PLAY ->
  GET_PARAMETER keepalive -> PAUSE -> TEARDOWN, with example wire dumps for a Hikvision
  DS-2CD2xxx camera and for a DS-7608 NVR.
- Authentication: Basic and **Digest (RFC 2617, MD5, qop=auth and the no-qop variant, nonce, nc,
  cnonce, opaque, re-auth on 401 with a new nonce, stale=true)**. Give the exact string
  construction for A1, A2 and response, and note that the URI in A2 must be the request URI.
  Note that Hikvision sends: WWW-Authenticate: Digest realm="IP Camera(XXXXX)", nonce="...",
  stale="FALSE". Specify that we must compute MD5 ourselves (no CryptoKit in the pure layer -
  decide: implement MD5 in VigilProtocols, it is ~120 lines, and unit-test it against RFC vectors).
- Transports: **TCP interleaved (RTP-over-RTSP, Transport: RTP/AVP/TCP;unicast;interleaved=0-1)**
  as the default, and the dollar-sign framing format (magic byte 0x24, channel byte, 16-bit
  big-endian length) including how to resynchronize after corruption and how to demux interleaved
  media frames from RTSP responses arriving on the SAME socket. Also UDP unicast as a secondary
  path with port pairing and keepalive, and RTSP-over-TLS (rtsps, port 322).
- SDP parsing (RFC 4566 plus RFC 3984/6184 fmtp): m= lines, a=control with absolute vs relative
  URL resolution against Content-Base / Content-Location / request URI (spell out the precedence
  rules exactly), a=rtpmap, a=fmtp with sprop-parameter-sets (H.264, base64 SPS,PPS) and
  sprop-vps / sprop-sps / sprop-pps (H.265), a=range, a=framerate, and the Hikvision extras
  a=Media_header and a=appversion that must be ignored gracefully.
- RTP-Info header parsing (url=, seq=, rtptime=) and how it seeds presentation time.
- Hikvision URL conventions as a table with which firmware generation uses which:
  rtsp://user:pass@host:554/Streaming/Channels/101 (channel*100 + stream),
  /Streaming/Channels/{ch}0{stream} for NVRs, /Streaming/tracks/101,
  legacy /h264/ch1/main/av_stream and /mpeg4/ch1/sub/av_stream, and the ISAPI playback URL
  rtsp://host/Streaming/tracks/101?starttime=20240101T000000Z&endtime=...
- Playback control: PLAY with Range: clock=20240101T000000Z-, the Scale header for
  fast-forward and reverse, RTCP-based progress, and the Rate-Control: no header used for
  gapless seeking of recorded video. Also frame-step behaviour.
- The **transport-agnostic state machine API**: define RTSPSessionMachine as a pure type driven by
  ingest(bytes) returning events and step(now) returning actions, where an action is
  send(Data) / setTimer / emitTrack / fail, so it is 100% unit-testable with no sockets.
  Give the complete public Swift API.
- A robust incremental parser design: header accumulation, Content-Length body, interleaved
  packets arriving mid-header, oversized-header protection, and the exact error cases.

Create parent directories if needed. Be exhaustive and concrete.
