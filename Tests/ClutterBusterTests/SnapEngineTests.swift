import CoreGraphics
import XCTest
@testable import ClutterBuster

final class SnapEngineTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1100)
    /// minX 500, midX 700, maxX 900; minY 500, midY 650, maxY 800.
    private let neighbor = CGRect(x: 500, y: 500, width: 400, height: 300)
    private let engine = SnapEngine(threshold: 10, gap: 6)

    private func move(_ frame: CGRect, others: [CGRect]? = nil, engine: SnapEngine? = nil) -> SnapEngine.Result {
        (engine ?? self.engine).snap(frame, mode: .move, others: others ?? [neighbor], screen: screen)
    }

    private func resize(_ frame: CGRect, _ edges: ResizeEdges, others: [CGRect]? = nil, engine: SnapEngine? = nil) -> SnapEngine.Result {
        (engine ?? self.engine).snap(frame, mode: .resize(edges), others: others ?? [neighbor], screen: screen)
    }

    // MARK: Moving

    func testFarFromEverythingStaysPut() {
        let frame = CGRect(x: 1100, y: 200, width: 300, height: 200)
        let result = move(frame)
        XCTAssertEqual(result.frame, frame)
        XCTAssertTrue(result.guides.isEmpty)
    }

    func testSnapsToScreenEdge() {
        let result = move(CGRect(x: 7, y: 300, width: 300, height: 200))
        XCTAssertEqual(result.frame, CGRect(x: 0, y: 300, width: 300, height: 200))
        XCTAssertEqual(result.guides, [SnapEngine.Guide(axis: .x, position: 0, start: 300, end: 500, reasons: [.screenEdge])])
    }

    func testSnapsToEveryScreenEdge() {
        XCTAssertEqual(move(CGRect(x: 1495, y: 300, width: 300, height: 200)).frame.maxX, 1800)
        XCTAssertEqual(move(CGRect(x: 1100, y: 896, width: 300, height: 200)).frame.maxY, 1100)
        XCTAssertEqual(move(CGRect(x: 1100, y: -9, width: 300, height: 200)).frame.minY, 0)
    }

    func testJustPastTheThresholdDoesNotSnap() {
        let frame = CGRect(x: 10.5, y: 300, width: 300, height: 200)
        XCTAssertEqual(move(frame, others: []).frame, frame)
        XCTAssertEqual(move(CGRect(x: 10, y: 300, width: 300, height: 200), others: []).frame.minX, 0)
    }

    func testSitsTheGapAwayRightOfANeighbor() {
        let result = move(CGRect(x: 910, y: 520, width: 300, height: 200))
        XCTAssertEqual(result.frame, CGRect(x: 906, y: 520, width: 300, height: 200))
        // The guide runs down the middle of the gap, the length of both fences.
        XCTAssertEqual(result.guides, [SnapEngine.Guide(axis: .x, position: 903, start: 500, end: 800, reasons: [.flush(index: 0)])])
    }

    func testSitsTheGapAwayLeftOfANeighbor() {
        let result = move(CGRect(x: 191, y: 520, width: 300, height: 200))
        XCTAssertEqual(result.frame.maxX, 494)
        XCTAssertEqual(result.guides.first?.position, 497)
    }

    func testSitsTheGapAwayAboveAndBelowANeighbor() {
        XCTAssertEqual(move(CGRect(x: 520, y: 290, width: 300, height: 200)).frame.maxY, 494)
        XCTAssertEqual(move(CGRect(x: 520, y: 809, width: 300, height: 200)).frame.minY, 806)
    }

    func testUsesTheGapSetting() {
        let flush = SnapEngine(threshold: 10, gap: 0)
        XCTAssertEqual(move(CGRect(x: 905, y: 520, width: 300, height: 200), engine: flush).frame.minX, 900)
        let wide = SnapEngine(threshold: 10, gap: 20)
        XCTAssertEqual(move(CGRect(x: 925, y: 520, width: 300, height: 200), engine: wide).frame.minX, 920)
    }

    func testDoesNotSitBesideAFenceThatIsFarAboveOrBelow() {
        let frame = CGRect(x: 909, y: 100, width: 300, height: 200)
        XCTAssertEqual(move(frame).frame, frame)
    }

    func testSitsBesideAFenceThatNearlyOverlaps() {
        // Its top is 5pt under the neighbor's bottom, inside the threshold.
        let result = move(CGRect(x: 909, y: 295, width: 300, height: 200))
        XCTAssertEqual(result.frame.minX, 906)
    }

    func testLinesUpTopsOfFencesFarApart() {
        let result = move(CGRect(x: 1200, y: 595, width: 300, height: 200))
        XCTAssertEqual(result.frame, CGRect(x: 1200, y: 600, width: 300, height: 200))
        XCTAssertEqual(result.guides, [SnapEngine.Guide(axis: .y, position: 800, start: 500, end: 1500, reasons: [.aligned(index: 0)])])
    }

    func testLinesUpBottomsLeftsAndRights() {
        XCTAssertEqual(move(CGRect(x: 1200, y: 492, width: 300, height: 200)).frame.minY, 500)
        XCTAssertEqual(move(CGRect(x: 504, y: 100, width: 300, height: 200)).frame.minX, 500)
        XCTAssertEqual(move(CGRect(x: 596, y: 100, width: 310, height: 200)).frame.maxX, 900)
    }

    func testLinesUpCenters() {
        let result = move(CGRect(x: 553, y: 100, width: 300, height: 200))
        XCTAssertEqual(result.frame.midX, 700)
        XCTAssertEqual(result.guides.first?.position, 700)
        XCTAssertEqual(move(CGRect(x: 1200, y: 556, width: 300, height: 200)).frame.midY, 650)
    }

    func testLeavesOutTheCenterLineWhenEdgesLineUp() {
        // Same height as the neighbor, beside it: tops, bottoms and centers all line up, but
        // only the edges and the gap get lines.
        let result = move(CGRect(x: 909, y: 504, width: 300, height: 300))
        XCTAssertEqual(result.frame, CGRect(x: 906, y: 500, width: 300, height: 300))
        XCTAssertEqual(result.guides.filter { $0.axis == .y }.map(\.position), [500, 800])
        XCTAssertEqual(result.guides.filter { $0.axis == .x }.map(\.position), [903])
    }

    func testSnapsBothAxesAtOnce() {
        let result = move(CGRect(x: 5, y: 896, width: 300, height: 200), others: [])
        XCTAssertEqual(result.frame, CGRect(x: 0, y: 900, width: 300, height: 200))
        XCTAssertEqual(result.guides.map(\.axis), [.x, .y])
    }

    func testNearestTargetWins() {
        // Flush with the neighbor is 3pt away; lined up with the other fence's left is 4pt.
        let other = CGRect(x: 913, y: 100, width: 200, height: 100)
        let result = move(CGRect(x: 909, y: 520, width: 300, height: 200), others: [neighbor, other])
        XCTAssertEqual(result.frame.minX, 906)
    }

    func testSittingBesideWinsATieWithLiningUp() {
        let other = CGRect(x: 912, y: 100, width: 200, height: 100)
        let result = move(CGRect(x: 909, y: 520, width: 300, height: 200), others: [neighbor, other])
        XCTAssertEqual(result.frame.minX, 906)
    }

    func testOneGuideForEveryFenceOnTheSameLine() {
        let below = CGRect(x: 500, y: 100, width: 200, height: 100)
        let result = move(CGRect(x: 503, y: 260, width: 200, height: 150), others: [neighbor, below])
        XCTAssertEqual(result.frame.minX, 500)
        let guide = result.guides.first { $0.axis == .x && $0.position == 500 }
        XCTAssertEqual(guide?.reasons, [.aligned(index: 0), .aligned(index: 1)])
        XCTAssertEqual(guide?.start, 100)
        XCTAssertEqual(guide?.end, 800)
    }

    func testLetsGoOncePastTheThreshold() {
        // Each step of a drag snaps from where the pointer put the fence, not where it last
        // snapped to, so there's nothing to pull free from.
        let steps: [CGFloat] = [12, 9, 4, 0, -3, 9, 11, 30]
        let snapped = steps.map { move(CGRect(x: $0, y: 300, width: 300, height: 200), others: []).frame.minX }
        XCTAssertEqual(snapped, [12, 0, 0, 0, 0, 0, 11, 30])
    }

    func testMovingIgnoresTheMinimumSize() {
        // A collapsed fence shows only its title bar, shorter than its minimum.
        let engine = SnapEngine(threshold: 10, gap: 6, minimumSize: CGSize(width: 180, height: 200))
        let result = move(CGRect(x: 7, y: 500, width: 300, height: 30), others: [], engine: engine)
        XCTAssertEqual(result.frame.minX, 0)
    }

    // MARK: Resizing

    func testResizingTheRightEdgeKeepsTheLeftEdge() {
        // Moving, its bottom would also line up with the neighbor's; resizing only the right
        // edge leaves it.
        let result = resize(CGRect(x: 200, y: 503, width: 291, height: 200), .right)
        XCTAssertEqual(result.frame, CGRect(x: 200, y: 503, width: 294, height: 200))
        XCTAssertEqual(result.guides.map(\.reasons), [[.flush(index: 0)]])
    }

    func testResizingTheLeftEdgeKeepsTheRightEdge() {
        let result = resize(CGRect(x: 909, y: 520, width: 300, height: 200), .left)
        XCTAssertEqual(result.frame, CGRect(x: 906, y: 520, width: 303, height: 200))
    }

    func testResizingTheTopAndBottom() {
        XCTAssertEqual(resize(CGRect(x: 1200, y: 400, width: 300, height: 395), .top).frame, CGRect(x: 1200, y: 400, width: 300, height: 400))
        XCTAssertEqual(resize(CGRect(x: 1200, y: 8, width: 300, height: 300), .bottom).frame, CGRect(x: 1200, y: 0, width: 300, height: 308))
    }

    func testResizingACornerSnapsBothEdges() {
        let result = resize(CGRect(x: 1200, y: 6, width: 596, height: 300), [.bottom, .right], others: [])
        XCTAssertEqual(result.frame, CGRect(x: 1200, y: 0, width: 600, height: 306))
        XCTAssertEqual(result.guides.count, 2)
    }

    func testResizingDoesNotLineUpCenters() {
        let frame = CGRect(x: 553, y: 100, width: 296, height: 200)
        XCTAssertEqual(resize(frame, .right).frame, frame)
    }

    func testResizingNeverSnapsBelowTheMinimum() {
        let engine = SnapEngine(threshold: 10, gap: 6, minimumSize: CGSize(width: 180, height: 100))
        // Snapping the right edge in to the screen's edge would leave it 178pt wide.
        let frame = CGRect(x: 1622, y: 300, width: 183, height: 200)
        XCTAssertEqual(resize(frame, .right, others: [], engine: engine).frame, frame)
        // Growing to a target is fine.
        XCTAssertEqual(resize(CGRect(x: 1612, y: 300, width: 181, height: 200), .right, others: [], engine: engine).frame.maxX, 1800)
    }

    func testResizingOneEdgeLeavesTheOthersAlone() {
        // The bottom is 4pt off the screen's edge, but only the right edge is being dragged.
        let frame = CGRect(x: 1100, y: 4, width: 300, height: 200)
        XCTAssertEqual(resize(frame, .right).frame, frame)
    }
}
