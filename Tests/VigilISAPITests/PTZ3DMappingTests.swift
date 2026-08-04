//
//  PTZTests.swift
//  VigilISAPITests
//
//  The PTZ bodies asserted byte-for-byte against docs/spec-isapi.md §13, the 0…255 lower-left
//  `position3D` mapping including the Y flip, the capability documents under both spellings of the
//  root element, and the controller's keep-alive and triple zero-stop.
//

import Foundation
import Testing
import VigilProtocols
@testable import VigilISAPI

// MARK: - PTZ3DMappingSuite

@Suite struct PTZ3DMappingSuite {

    @Test func ptz3DMapsAViewRectIntoLowerLeftOriginWireSpace() {
        // A 256×256 view makes the arithmetic checkable by eye: view Y 0 is the *top*, which is
        // 255 in the device's lower-left space.
        let box = PTZ3D.box(rectX: 0, rectY: 0, rectWidth: 128, rectHeight: 128,
                            viewWidth: 256, viewHeight: 256, originIsTopLeft: false)
        #expect(box.startX == 0)
        #expect(box.startY == 255)      // top edge of the view ⇒ top of the image
        #expect(box.endX == 128)
        #expect(box.endY == 128)        // halfway down ⇒ halfway up
    }

    @Test func ptz3DFlipsYOnlyForTheLowerLeftConvention() {
        // The same rectangle under both conventions differs in Y and only in Y.
        let lowerLeft = PTZ3D.box(rectX: 64, rectY: 32, rectWidth: 128, rectHeight: 64,
                                  viewWidth: 256, viewHeight: 256, originIsTopLeft: false)
        let topLeft = PTZ3D.box(rectX: 64, rectY: 32, rectWidth: 128, rectHeight: 64,
                                viewWidth: 256, viewHeight: 256, originIsTopLeft: true)
        #expect(lowerLeft.startX == topLeft.startX)
        #expect(lowerLeft.endX == topLeft.endX)
        #expect(lowerLeft.startY == 223)        // 255 - 32
        #expect(topLeft.startY == 32)
        #expect(lowerLeft.endY == 159)          // 255 - 96
        #expect(topLeft.endY == 96)
        // In the device's space the start point is above the end point, exactly as the §13.5
        // sample shows (start 180, end 60).
        #expect(lowerLeft.startY > lowerLeft.endY)
        #expect(topLeft.startY < topLeft.endY)
    }

    @Test func ptz3DNormalisesADragDrawnInAnyDirection() {
        // Drag direction is irrelevant to the device; only the rectangle matters. A drag up-left
        // and a drag down-right over the same area must produce the same body.
        let downRight = PTZ3D.box(rectX: 40, rectY: 40, rectWidth: 80, rectHeight: 60,
                                  viewWidth: 320, viewHeight: 240, originIsTopLeft: false)
        let upLeft = PTZ3D.box(rectX: 120, rectY: 100, rectWidth: -80, rectHeight: -60,
                               viewWidth: 320, viewHeight: 240, originIsTopLeft: false)
        #expect(downRight == upLeft)
    }

    @Test func ptz3DPointIsAClickToCentre() {
        let point = PTZ3D.point(x: 160, y: 120, viewWidth: 320, viewHeight: 240,
                               originIsTopLeft: false)
        #expect(point.isPoint)
        #expect(point.startX == 128)
        #expect(point.startY == 128)      // the exact centre maps to the middle of 0…255
    }

    @Test func ptz3DClampsAndSurvivesADegenerateView() {
        // A drag that ran outside the content rect must still produce a legal body.
        let outside = PTZ3D.box(rectX: -50, rectY: -50, rectWidth: 1000, rectHeight: 1000,
                                viewWidth: 320, viewHeight: 240, originIsTopLeft: false)
        #expect(outside.startX == 0)
        #expect(outside.startY == 255)
        #expect(outside.endX == 255)
        #expect(outside.endY == 0)
        // A zero-sized view centres rather than dividing by zero.
        let degenerate = PTZ3D.box(rectX: 0, rectY: 0, rectWidth: 10, rectHeight: 10,
                                   viewWidth: 0, viewHeight: 0, originIsTopLeft: false)
        #expect(degenerate.isPoint)
        #expect(degenerate.startX == 128)
    }

    @Test func ptz3DMinimumDragIsTwelvePoints() {
        #expect(PTZ3D.minimumDragPoints == 12)
    }
}
