# ASSIGNMENT: render

AGENT_LABEL for your log lines is: spec:render
Write the file: /home/user/camera/docs/spec-render.md

Author the rendering and on-video interaction specification (module VigilRender).
Cover:
- The VideoTileView: an NSView backed by either AVSampleBufferDisplayLayer or CAMetalLayer,
  wrapped for SwiftUI via NSViewRepresentable. Get the details right: wantsLayer,
  layerContentsRedrawPolicy, updating layer.contentsScale when the backing display changes,
  videoGravity, and how to avoid the classic AppKit resize flicker (CATransaction with actions
  disabled, NSView.inLiveResize, an opaque layer-backed background).
- The **Metal renderer**: one shared MTLDevice and MTLCommandQueue app-wide; a CVMetalTextureCache
  for zero-copy CVPixelBuffer to MTLTexture conversion for both planes of a biplanar buffer; the
  YCbCr to RGB conversion matrices (BT.709 video-range and full-range, and BT.2020 for 10-bit
  HEVC) applied in the fragment shader; a vertex shader with a model matrix for **digital zoom and
  pan** up to 8x with inertial motion; and optional post effects: sharpen, brightness, contrast,
  gamma, deinterlace (bob and blend, for interlaced analog NVR channels) and a night-boost tone
  curve. Provide the ACTUAL Metal shader source for the YUV-to-RGB plus transform plus adjustment
  pass, and the pipeline-state setup code. Specify triple buffering, presentsWithTransaction for
  glitch-free resize, maximumDrawableCount, displaySyncEnabled, and using the macOS 14
  NSView displayLink API for pacing on ProMotion displays.
- **Overlays**: decide and justify which are drawn as SwiftUI on top versus inside Metal:
  timestamp OSD, camera-name chip, recording indicator, motion boxes from ISAPI events mapped
  from the camera 0..1000 normalized coordinate space into view space (spell out the transform,
  including the inverted Y axis some firmware uses), privacy-mask preview, PTZ direction
  indicator, and the drag rectangle for 3D-positioning PTZ.
- **Interactions**: scroll-to-zoom anchored at the cursor, two-finger pan, pinch magnify via
  NSMagnificationGestureRecognizer, double-click to fullscreen with a matched-geometry-style
  transition, right-click context menu, drag-and-drop of a tile between grid cells with a live
  ghost image, dragging a camera from the sidebar onto a cell, arrow keys driving PTZ when a tile
  is focused, and precise cursor changes.
- **Video-wall compositing**: whether N tiles share one Metal layer or get one layer each. Make
  the decision (one CAMetalLayer per tile up to K tiles, single-layer atlas compositing above K)
  with the rationale, and explain how we hold 120 Hz with 16 tiles.
- HDR and EDR notes, colour-space tagging (CAMetalLayer colorspace,
  wantsExtendedDynamicRangeContent), and correct behaviour across multiple displays with
  different scale factors.
- An AVSampleBufferDisplayLayer-only fallback path for machines where Metal initialisation fails.
- The full public Swift API and a checklist of visual-correctness tests: aspect ratio with
  non-square pixels (SAR), the cropping window, the 1088-versus-1080 crop, interlaced content,
  and 10-bit content.

Create parent directories if needed. Be exhaustive and concrete.
