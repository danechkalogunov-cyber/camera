#if os(macOS)

import Testing

@testable import VigilTransport

@Suite struct RTSPDiagnosticRecorderTests {
    @Test func transcriptIsRedactedSeparatedAndBounded() {
        let recorder = RTSPDiagnosticRecorder(maximumEntries: 2, maximumBytes: 4_096)
        recorder.append("one", streamID: "a")
        recorder.append("two", streamID: "a")
        recorder.append("three", streamID: "a")
        recorder.append("other", streamID: "b")

        let first = recorder.transcript(streamID: "a")
        #expect(!first.contains("one"))
        #expect(first.contains("two"))
        #expect(first.contains("three"))
        #expect(recorder.transcript(streamID: "b").contains("other"))

        let byteBounded = RTSPDiagnosticRecorder(maximumEntries: 10, maximumBytes: 1_024)
        byteBounded.append(String(repeating: "x", count: 10_000), streamID: "large")
        #expect(byteBounded.transcript(streamID: "large").utf8.count <= 1_024)
        #expect(byteBounded.transcript(streamID: "large").contains("truncated"))
    }

    @Test func lastSDPIsKeptSeparatelyFromTheBoundedTranscript() {
        let recorder = RTSPDiagnosticRecorder(maximumEntries: 1, maximumBytes: 4_096)
        recorder.append("""
            <<< RESPONSE
            RTSP/1.0 200 OK
            Content-Type: application/sdp

            v=0
            m=video 0 RTP/AVP 96
            """, streamID: "camera")
        recorder.append("later non-SDP response", streamID: "camera")

        #expect(!recorder.transcript(streamID: "camera").contains("m=video"))
        #expect(recorder.lastSDP(streamID: "camera") == "v=0\nm=video 0 RTP/AVP 96\n")
        #expect(recorder.lastSDP(streamID: "missing") == "No SDP recorded.\n")
    }
}

#endif
