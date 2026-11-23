/// ModifierDragTests.swift

import XCTest
@testable import Rectangle

final class ModifierDragTests: XCTestCase {
    private typealias Handle = ModifierDragManager.Handle
    private let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let minimum = CGSize(width: 64, height: 64)

    func testNearestCorner() {
        XCTAssertEqual(ModifierDragManager.nearestCorner(of: frame, to: CGPoint(x: 120, y: 120)), Handle(left: true, top: true))
        XCTAssertEqual(ModifierDragManager.nearestCorner(of: frame, to: CGPoint(x: 480, y: 120)), Handle(left: false, top: true))
        XCTAssertEqual(ModifierDragManager.nearestCorner(of: frame, to: CGPoint(x: 120, y: 380)), Handle(left: true, top: false))
        XCTAssertEqual(ModifierDragManager.nearestCorner(of: frame, to: CGPoint(x: 480, y: 380)), Handle(left: false, top: false))
    }

    func testBottomRightResizeKeepsOrigin() {
        let result = ModifierDragManager.resizedFrame(from: frame, handle: Handle(left: false, top: false),
                                                      delta: CGPoint(x: 50, y: -20), minimumSize: minimum)
        XCTAssertEqual(result, CGRect(x: 100, y: 100, width: 450, height: 280))
    }

    func testTopLeftResizeKeepsOppositeCorner() {
        let result = ModifierDragManager.resizedFrame(from: frame, handle: Handle(left: true, top: true),
                                                      delta: CGPoint(x: -30, y: 40), minimumSize: minimum)
        XCTAssertEqual(result, CGRect(x: 70, y: 140, width: 430, height: 260))
        XCTAssertEqual(result.maxX, frame.maxX)
        XCTAssertEqual(result.maxY, frame.maxY)
    }

    func testResizeClampsToMinimumAndStaysAnchored() {
        let result = ModifierDragManager.resizedFrame(from: frame, handle: Handle(left: true, top: false),
                                                      delta: CGPoint(x: 1000, y: -1000), minimumSize: minimum)
        XCTAssertEqual(result.size, minimum)
        XCTAssertEqual(result.maxX, frame.maxX)
        XCTAssertEqual(result.minY, frame.minY)
    }

    func testModifiersMatchExactly() {
        XCTAssertTrue(ModifierDragManager.modifiersMatch([.command], required: .command))
        XCTAssertTrue(ModifierDragManager.modifiersMatch([.command, .capsLock], required: .command))
        XCTAssertFalse(ModifierDragManager.modifiersMatch([.command, .shift], required: .command))
        XCTAssertFalse(ModifierDragManager.modifiersMatch([], required: .command))
        XCTAssertTrue(ModifierDragManager.modifiersMatch([.command, .control], required: [.command, .control]))
    }

    func testNearestEdge() {
        // frame is x 100...500, y 100...400
        XCTAssertEqual(ModifierDragManager.nearestEdge(of: frame, to: CGPoint(x: 300, y: 110)), Handle(left: nil, top: true))
        XCTAssertEqual(ModifierDragManager.nearestEdge(of: frame, to: CGPoint(x: 300, y: 390)), Handle(left: nil, top: false))
        XCTAssertEqual(ModifierDragManager.nearestEdge(of: frame, to: CGPoint(x: 110, y: 250)), Handle(left: true, top: nil))
        XCTAssertEqual(ModifierDragManager.nearestEdge(of: frame, to: CGPoint(x: 490, y: 250)), Handle(left: false, top: nil))
    }

    func testTopEdgeResizeChangesOnlyHeight() {
        let result = ModifierDragManager.resizedFrame(from: frame, handle: Handle(left: nil, top: true),
                                                      delta: CGPoint(x: 80, y: -50), minimumSize: minimum)
        XCTAssertEqual(result, CGRect(x: 100, y: 50, width: 400, height: 350))
    }

    func testLeftEdgeResizeChangesOnlyWidth() {
        let result = ModifierDragManager.resizedFrame(from: frame, handle: Handle(left: true, top: nil),
                                                      delta: CGPoint(x: 40, y: 90), minimumSize: minimum)
        XCTAssertEqual(result, CGRect(x: 140, y: 100, width: 360, height: 300))
    }

    func testModeSelection() {
        typealias M = ModifierDragManager
        XCTAssertEqual(M.mode(for: .leftMouseDown, flags: [.command], required: .command), .move)
        XCTAssertEqual(M.mode(for: .rightMouseDown, flags: [.command], required: .command), .resizeCorner)
        XCTAssertEqual(M.mode(for: .rightMouseDown, flags: [.command, .shift], required: .command), .resizeEdge)
        XCTAssertNil(M.mode(for: .leftMouseDown, flags: [.command, .shift], required: .command))
        XCTAssertNil(M.mode(for: .rightMouseDown, flags: [.shift], required: .command))
    }
}
