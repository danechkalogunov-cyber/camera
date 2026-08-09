import Foundation
import Testing

import VigilProtocols

@Suite("Clip export selection")
struct ClipExportSelectionTests {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func requiresTwoDifferentPoints() {
        var selection = ClipExportSelection()
        #expect(selection.range == nil)
        selection.setIn(origin)
        #expect(selection.range == nil)
        selection.setOut(origin)
        #expect(selection.range == nil)
    }

    @Test func crossedHandlesStillProduceAnOrderedRange() {
        var selection = ClipExportSelection()
        selection.setIn(origin.addingTimeInterval(30))
        selection.setOut(origin)

        #expect(selection.range == origin..<origin.addingTimeInterval(30))
        #expect(selection.duration == 30)
    }

    @Test func progressIsClampedAndRejectsNonFiniteInput() {
        let selection = ClipExportSelection(
            inPoint: origin, outPoint: origin.addingTimeInterval(20))

        #expect(selection.progress(mediaSeconds: -1) == 0)
        #expect(selection.progress(mediaSeconds: 5) == 0.25)
        #expect(selection.progress(mediaSeconds: 50) == 1)
        #expect(selection.progress(mediaSeconds: .infinity) == 0)
    }
}
