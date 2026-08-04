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
        let offset = StreamDoctorStep.allCases.firstIndex(of: failed)!
        for later in StreamDoctorStep.allCases.dropFirst(offset + 1) {
            #expect(result.outcomes[later] == .skipped)
        }
    }
}
