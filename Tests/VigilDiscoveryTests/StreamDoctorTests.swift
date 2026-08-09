import Testing

@testable import VigilDiscovery

@Suite struct StreamDoctorTests {
    @Test(arguments: StreamDoctorStep.allCases)
    func diagnosesEveryInjectedFailure(_ failed: StreamDoctorStep) async {
        var probes: [StreamDoctorStep: StreamDoctor.Probe] = [:]
        for step in StreamDoctorStep.allCases {
            probes[step] = { @Sendable in step != failed }
        }
        let result = await StreamDoctor(probes: probes).run()
        #expect(result.firstFailure == failed)
        guard let offset = StreamDoctorStep.allCases.firstIndex(of: failed) else {
            Issue.record("The injected step is absent from the sequence")
            return
        }
        for later in StreamDoctorStep.allCases.dropFirst(offset + 1) {
            #expect(result.outcomes[later] == .skipped)
        }
    }

    @Test func detailedCauseAndRedactedReportArePreserved() async {
        let marker = "diagnostic detail without endpoint"
        var probes: [StreamDoctorStep: StreamDoctor.DetailedProbe] = [:]
        for step in StreamDoctorStep.allCases {
            probes[step] = { @Sendable in
                step == .codec ? .fail(.unsupportedCodec, detail: marker) : .pass()
            }
        }

        let result = await StreamDoctor(detailedProbes: probes).run()

        #expect(result.failures[.codec] == .unsupportedCodec)
        #expect(result.details[.codec] == marker)
        #expect(result.redactedText.contains("unsupportedCodec"))
        #expect(result.redactedText.contains(marker))
        #expect(result.outcomes[.firstRTP] == .skipped)
    }

    @Test func sequenceContainsEveryNormativeStageInOrder() {
        #expect(StreamDoctorStep.allCases == [
            .addressResolution, .tcpRTSP, .tcpHTTP, .options, .isapiDeviceInfo,
            .describeAnonymous, .describeAuthenticated, .codec, .firstRTP,
            .firstKeyframe, .qualitySample,
        ])
    }

    @Test func seededFaultTaxonomyMapsToTheExpectedStageAndCause() async {
        let fixtures: [(StreamDoctorStep, StreamDoctorFailure)] = [
            (.tcpRTSP, .rtspPortClosed),
            (.describeAuthenticated, .authFailed),
            (.codec, .unsupportedCodec),
            (.describeAuthenticated, .wrongRTSPPath),
            (.firstRTP, .noMediaData),
            (.qualitySample, .highLoss),
        ]

        for (failedStep, cause) in fixtures {
            var probes: [StreamDoctorStep: StreamDoctor.DetailedProbe] = [:]
            for step in StreamDoctorStep.allCases {
                probes[step] = { @Sendable in
                    step == failedStep ? .fail(cause) : .pass()
                }
            }
            let result = await StreamDoctor(detailedProbes: probes).run()
            #expect(result.firstFailure == failedStep)
            #expect(result.failures[failedStep] == cause)
        }
    }
}
