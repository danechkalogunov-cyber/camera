# ASSIGNMENT: architecture

AGENT_LABEL for your log lines is: spec:architecture
Write the file: /home/user/camera/docs/ARCHITECTURE.md

Author the system architecture document.
Cover:
- The full module/target graph with dependency arrows and why each edge exists.
- The exact Package.swift contents (swift-tools-version 6.0, macOS 14 platform, all targets plus
  test targets) and the mechanism that lets the pure targets build on Linux while macOS-only
  targets are excluded there. SwiftPM has no per-platform target exclusion, so DECIDE the real
  mechanism (e.g. a documented "swift build --target" subset for Linux CI, plus file-level
  #if os(macOS) guards) and write it out.
- The concurrency model: which types are actor, which are @MainActor, which are Sendable value
  types; how the per-camera pipeline is an actor with a bounded frame queue; how backpressure and
  cancellation propagate; the structured-concurrency task tree per camera; why we avoid GCD except
  for the VideoToolbox callback hop; how we satisfy Swift 6 strict concurrency at every boundary.
- The end-to-end data flow: discovery -> camera record -> RTSP session -> RTP depacketize ->
  EncodedFrame -> VideoToolbox -> CVPixelBuffer -> Metal / AVSampleBufferDisplayLayer -> screen,
  naming the exact type that crosses each boundary.
- Error taxonomy and a retry/reconnect state machine with exponential backoff plus jitter
  (give the state diagram and the timings).
- Observability: OSLog categories, signposts, a per-stream stats struct, and how the pure layer
  logs through an injected LoggerProtocol instead of importing OSLog.
- Persistence strategy: JSON document in Application Support plus Keychain for secrets, atomic
  writes, schema versioning and migration.
- Testing strategy: what is unit-tested on Linux, what needs a Mac, and the design of a
  **synthetic RTSP server + RTP generator test fixture** so the whole pure pipeline can be tested
  end-to-end with no camera present. This fixture is important - specify its API in detail.
- Repo directory layout; the build-script contract (Scripts/build-app.sh producing Vigil.app);
  Info.plist keys needed (NSLocalNetworkUsageDescription, NSAppTransportSecurity with
  NSAllowsLocalNetworking for plain-http ISAPI on LAN, LSMinimumSystemVersion, document types);
  the entitlements file contents (App Sandbox decision, com.apple.security.network.client,
  com.apple.developer.networking.multicast, user-selected files read-write) and hardened-runtime
  notes. Justify the sandbox decision explicitly.
- Repo-wide **Swift style rules** implementers must follow: file header format, access control,
  naming, no force-unwrap outside tests, error handling style, doc comments on public API,
  MARK sections, 110-column lines.

Create parent directories if needed. Be exhaustive and concrete.
