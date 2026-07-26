# ASSIGNMENT: video

AGENT_LABEL for your log lines is: spec:video
Write the file: /home/user/camera/docs/spec-video-pipeline.md

Author the decode and playback pipeline specification (module VigilVideo).
Cover:
- Constructing CMVideoFormatDescription from SPS/PPS and VPS via
  CMVideoFormatDescriptionCreateFromH264ParameterSets and
  CMVideoFormatDescriptionCreateFromHEVCParameterSets - exact signatures, pointer handling with
  nested withUnsafeBufferPointer over an array of pointers, and nalUnitHeaderLength 4.
- Wrapping length-prefixed NAL data into a CMBlockBuffer and CMSampleBuffer with correct
  CMSampleTimingInfo (duration, pts, dts), the NotSync sample attachment for non-keyframes, and
  the DisplayImmediately attachment for low latency.
- Two display strategies and when each is used:
  (a) **AVSampleBufferDisplayLayer** with requiresFlushToResumeDecoding, a control timebase versus
      immediate mode, and its automatic hardware decode - the default fast path;
  (b) an explicit **VTDecompressionSession** producing CVPixelBuffers rendered with **Metal** -
      used when we need pixel access (digital-zoom shader, snapshots, motion overlay, colour
      grading, video-wall compositing).
  Specify the VTDecompressionSessionCreate attributes: EnableHardwareAcceleratedVideoDecoder,
  RealTime, MaximizePowerEfficiency, ThreadCount, output pixel format
  420YpCbCr8BiPlanarVideoRange (and 420YpCbCr10BiPlanarVideoRange for HEVC Main10),
  MetalCompatibility and IOSurfaceProperties keys, and a CVPixelBufferPool. Also the decode flags
  EnableAsynchronousDecompression and 1xRealTimePlayback, and how to handle
  kVTVideoDecoderBadDataErr, kVTInvalidSessionErr and kVTVideoDecoderMalfunctionErr (recreate the
  session, then wait for an IDR).
- **Mid-stream format changes** (a new SPS with a different resolution): detect, drain, recreate
  the session without dropping the window or flashing black.
- **Low-latency live clock**: no A/V sync buffering for live, render on decode, display
  immediately, a bounded 2-3 frame queue, drop-to-keyframe when behind, and an adaptive latency
  controller that measures queue depth over a sliding window. Give the exact thresholds.
- **Recorded playback**, which is different: a real timebase, PTS-ordered reordering for B-frames
  and POC reorder, pause, seek, scale 0.25x to 8x, reverse, and single-frame step.
- **Decode-budget scheduler**: a global actor that admits decode sessions by cost
  (resolution x fps x codec weight) because macOS has a finite number of hardware decode
  sessions. Give the policy for a 16-up grid (substreams only; and when a tile is smaller than a
  threshold use the ISAPI JPEG snapshot refresh instead of decoding at all - give the exact pixel
  thresholds and refresh intervals), pausing decode for offscreen, occluded or minimized tiles
  via NSWindow.occlusionState, and dropping to keyframe-only below a size threshold.
- **Audio**: AVAudioEngine plus an AVAudioSourceNode fed from AAC (decoded with AudioConverter /
  AudioToolbox) or G.711 (table lookup), per-camera mute and solo, and the rule that audio is
  enabled only for the focused camera by default. Include the two-way-audio capture path
  (AVAudioEngine input -> G.711 encode -> ISAPI upload) and push-to-talk semantics.
- Snapshot capture: CVPixelBuffer to CGImage via VTCreateCGImageFromCVPixelBuffer or CIContext,
  then PNG/JPEG/HEIC write with metadata.
- Hardware and energy notes: how to verify hardware decode is actually engaged, expected CPU and
  GPU numbers, thermal and low-power-mode adaptation, and the design of a benchmark harness.
- The full public Swift API (actor DecodePipeline, protocol VideoSink, and friends) and the exact
  error handling.

Create parent directories if needed. Be exhaustive and concrete.
