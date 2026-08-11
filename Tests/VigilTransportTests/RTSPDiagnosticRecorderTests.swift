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
}

#endif
