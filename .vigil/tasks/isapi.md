# ASSIGNMENT: isapi

AGENT_LABEL for your log lines is: spec:isapi
Write the file: /home/user/camera/docs/spec-isapi.md

Author the Hikvision ISAPI integration specification (module VigilISAPI). This is the control
plane of the app. For EVERY endpoint give: HTTP method, path, auth, request XML, response XML,
the Swift model type it decodes to, and the error codes.
Cover:
- Device identity and capability: GET /ISAPI/System/deviceInfo, /ISAPI/System/capabilities,
  /ISAPI/System/status, /ISAPI/System/time, /ISAPI/System/Network/interfaces,
  /ISAPI/Security/userCheck (the cheap credential probe - describe its response and the
  lock-out / retry fields), /ISAPI/ContentMgmt/InputProxy/channels (NVR IP channels) and
  /ISAPI/System/Video/inputs/channels.
- Streaming config: GET and PUT /ISAPI/Streaming/channels and /ISAPI/Streaming/channels/{id}
  (read resolution, bitrate, fps, codec, GOP; and how to change substream settings), how channel
  IDs map to RTSP paths, and
  /ISAPI/Streaming/channels/{id}/picture?videoResolutionWidth=&videoResolutionHeight= for JPEG
  snapshots - this is the fast path for grid thumbnails and sidebar previews.
- **PTZ**: PUT /ISAPI/PTZCtrl/channels/{ch}/continuous with a PTZData body carrying pan, tilt and
  zoom in the range -100..100; /momentary with a duration; /absolute with elevation, azimuth and
  absoluteZoom; /relative; /presets/{n}/goto; GET /presets; PUT /presets/{n} to set;
  /patrols and /patrols/{n}/start and /stop; /homeposition/goto; /PTZCtrl/channels/{ch}/status;
  /capabilities; and 3D positioning PUT /ISAPI/PTZCtrl/channels/{ch}/position3D with the XY box,
  which powers drag-to-zoom directly on the video. Give ranges, units, and the required
  Content-Type: application/xml.
- **Events**: GET /ISAPI/Event/notification/alertStream - the long-lived multipart/mixed stream.
  Give a realistic sample showing the boundary, an application/xml part with
  EventNotificationAlert (eventType values VMD, linedetection, fielddetection, regionEntrance,
  facedetection, tamperdetection, io, videoloss, diskfull; eventState, channelID, dateTime,
  activePostCount, and the DetectionRegionList polygon) and an image/jpeg part for event
  snapshots. Specify a streaming multipart parser design that never buffers unbounded data, plus
  the reconnect policy. Also /ISAPI/Event/triggers, /ISAPI/Event/schedules, and motion-detection
  config at /ISAPI/System/Video/inputs/channels/{ch}/motionDetection.
- **Recorded video (playback)**: POST /ISAPI/ContentMgmt/search with a CMSearchDescription
  (searchID GUID, trackIDList, timeSpanList start and end, maxResults, searchResultPostion for
  paging - note the real misspelling - and metadataList) returning CMSearchResult with
  matchList / searchMatchItem / trackID, timeSpan, mediaSegmentDescriptor with contentType,
  codecType and playbackURI. Show the playbackURI form
  rtsp://host/Streaming/tracks/101?starttime=...&endtime=...&name=...&size=...
  Also /ISAPI/ContentMgmt/record/tracks, storage at /ISAPI/ContentMgmt/Storage (HDD/SD status,
  capacity, quota) and the day-level calendar query used to paint the timeline heatmap - specify
  exactly which endpoint we use for the timeline UI and its response shape.
- **Two-way audio**: GET /ISAPI/System/TwoWayAudio/channels, PUT .../{id}/open,
  POST .../{id}/audioData (chunked G.711 upload), and .../close. Include the codec negotiation.
- Image settings: PUT /ISAPI/Image/channels/{ch}/... (brightness, contrast, saturation, sharpness,
  WDR, IR-cut, day/night), plus reboot, /ISAPI/Security/users, and NVR-specific
  /ISAPI/ContentMgmt/InputProxy/channels/{id}/status.
- Error handling: the ResponseStatus body with statusCode and subStatusCode values such as
  notSupport, badParameters, deviceBusy, invalidOperation - and how each maps to a user-facing
  message.
- A robust **lenient XML decoder**: XMLParser-based, namespace-agnostic, path-keyed, tolerant of
  unknown elements and of differing firmware casings, because Hikvision XML varies wildly by
  firmware. Give its full API and explain why we do not use Codable XML.
- HTTP client requirements: Digest auth, connection reuse, per-request timeouts, cancellation,
  plain http on LAN, accepting self-signed TLS for https, and a per-device concurrency limit.

Create parent directories if needed. Be exhaustive and concrete.
