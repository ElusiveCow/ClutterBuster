import CoreGraphics
import UniformTypeIdentifiers
import XCTest
@testable import ClutterBuster

final class NewFileTests: XCTestCase {
    private func facts(_ name: String, _ kinds: Set<FileKind>) -> FileFacts {
        FileFacts(
            url: URL(fileURLWithPath: "/tmp/" + name), name: name,
            ext: (name as NSString).pathExtension.lowercased(), kinds: kinds, screenshotSource: nil
        )
    }

    // MARK: Kinds

    func testKindsFromTypes() {
        XCTAssertEqual(FileFacts.kinds(of: .pdf, isFolder: false), [.pdf])
        XCTAssertEqual(FileFacts.kinds(of: .png, isFolder: false), [.image])
        XCTAssertEqual(FileFacts.kinds(of: .plainText, isFolder: false), [.document])
        XCTAssertEqual(FileFacts.kinds(of: .commaSeparatedText, isFolder: false), [.spreadsheet])
        XCTAssertEqual(FileFacts.kinds(of: .zip, isFolder: false), [.archive])
        XCTAssertEqual(FileFacts.kinds(of: .quickTimeMovie, isFolder: false), [.video])
        XCTAssertEqual(FileFacts.kinds(of: .mp3, isFolder: false), [.audio])
        XCTAssertEqual(FileFacts.kinds(of: .applicationBundle, isFolder: false), [.app])
        XCTAssertEqual(FileFacts.kinds(of: nil, isFolder: true), [.folder])
        if let pptx = UTType(filenameExtension: "pptx") {
            XCTAssertEqual(FileFacts.kinds(of: pptx, isFolder: false), [.presentation])
        }
        if let docx = UTType(filenameExtension: "docx") {
            XCTAssertEqual(FileFacts.kinds(of: docx, isFolder: false), [.document])
        }
    }

    // MARK: Rules

    func testRuleMatching() {
        let pdf = facts("Invoice March.PDF", [.pdf])
        XCTAssertTrue(AutoFileRule(kind: .pdf).matches(pdf))
        XCTAssertTrue(AutoFileRule(kind: .any).matches(pdf))
        XCTAssertFalse(AutoFileRule(kind: .image).matches(pdf))
        XCTAssertTrue(AutoFileRule(nameContains: "invoice").matches(pdf))
        XCTAssertFalse(AutoFileRule(nameContains: "receipt").matches(pdf))
        XCTAssertTrue(AutoFileRule(fileExtension: ".png, pdf").matches(pdf))
        XCTAssertFalse(AutoFileRule(fileExtension: "png jpg").matches(pdf))
        XCTAssertTrue(AutoFileRule(kind: .image).matches(facts("Screenshot.png", [.screenshot, .image])))
    }

    func testFirstUsableRuleWins() {
        var fence = Fence(title: "Docs", frame: .zero, color: .slate, iconsPerRow: 4)
        fence.tabs.append(FenceTab(name: "Invoices"))
        let missingFence = AutoFileRule(kind: .pdf, fenceID: UUID())
        let missingTab = AutoFileRule(kind: .pdf, fenceID: fence.id, tabID: UUID())
        let image = AutoFileRule(kind: .image, fenceID: fence.id)
        let good = AutoFileRule(kind: .pdf, fenceID: fence.id, tabID: fence.tabs[1].id)
        let later = AutoFileRule(kind: .any, fenceID: fence.id)
        let (match, skipped) = RuleMatch.first(for: facts("a.pdf", [.pdf]), in: [missingFence, missingTab, image, good, later], fences: [fence])
        XCTAssertEqual(match?.rule.id, good.id)
        XCTAssertEqual(match?.index, 3)
        XCTAssertEqual(skipped.map(\.index), [0, 1])
        XCTAssertEqual(missingFence.problem(in: [fence]), "Its fence was deleted")
        XCTAssertEqual(missingTab.problem(in: [fence]), "Its tab was deleted")
        XCTAssertNil(good.problem(in: [fence]))
        XCTAssertNil(RuleMatch.first(for: facts("a.pdf", [.pdf]), in: [missingFence], fences: [fence]).match)
    }

    func testRulesRoundTripThroughJSON() throws {
        let rule = AutoFileRule(kind: .screenshot, nameContains: "CB", fileExtension: "png", fenceID: UUID(), tabID: nil)
        let decoded = try JSONDecoder().decode([AutoFileRule].self, from: JSONEncoder().encode([rule]))
        XCTAssertEqual(decoded, [rule])
        let unknownKind = #"[{"kind":"hologram","nameContains":"x"}]"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode([AutoFileRule].self, from: unknownKind).first?.kind, .any)
    }

    func testRememberTarget() {
        XCTAssertEqual(RememberTarget.shared(by: [facts("a.pdf", [.pdf]), facts("b.pdf", [.pdf])]), .kind(.pdf))
        XCTAssertEqual(RememberTarget.shared(by: [facts("a.pdf", [.pdf])])?.label, "Remember for PDFs")
        XCTAssertEqual(RememberTarget.shared(by: [facts("a.xyz", []), facts("b.xyz", [])]), .fileExtension("xyz"))
        XCTAssertNil(RememberTarget.shared(by: [facts("a.pdf", [.pdf]), facts("b.png", [.image])]))
        XCTAssertEqual(RememberTarget.shared(by: [facts("Screenshot.png", [.screenshot, .image])])?.label, "Remember for screenshots")
    }

    // MARK: Watching

    func testTransientNames() {
        XCTAssertEqual(DesktopWatcher.transientReason("Report.pdf.crdownload"), "download in progress")
        XCTAssertEqual(DesktopWatcher.transientReason("Report.pdf.download"), "download in progress")
        XCTAssertEqual(DesktopWatcher.transientReason("movie.mp4.part"), "download in progress")
        XCTAssertEqual(DesktopWatcher.transientReason(".Screenshot 2026.png"), "hidden file")
        XCTAssertEqual(DesktopWatcher.transientReason("~$Budget.xlsx"), "temporary file")
        XCTAssertEqual(DesktopWatcher.transientReason("notes.txt~"), "temporary file")
        XCTAssertNotNil(DesktopWatcher.transientReason("untitled folder 2"))
        XCTAssertNil(DesktopWatcher.transientReason("Report.pdf"))
        XCTAssertNil(DesktopWatcher.transientReason("untitled folders.txt"))
    }

    // MARK: Card placement

    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1100)
    private let card = CGSize(width: 340, height: 160)

    func testCardBelowTopBarAndAboveBottomBar() {
        let top = CGRect(x: 660, y: 1048, width: 480, height: 44)
        let below = NewFilePromptController.cardFrame(size: card, toolbar: ToolbarPlacement(frame: top, shape: .horizontal, collapsed: false), screen: screen)
        XCTAssertEqual(below.maxY, top.minY - 10)
        XCTAssertEqual(below.midX, top.midX)
        let bottom = CGRect(x: 660, y: 8, width: 480, height: 44)
        let above = NewFilePromptController.cardFrame(size: card, toolbar: ToolbarPlacement(frame: bottom, shape: .horizontal, collapsed: false), screen: screen)
        XCTAssertEqual(above.minY, bottom.maxY + 10)
    }

    func testCardBesideColumnTowardTheMiddle() {
        let right = CGRect(x: 1748, y: 400, width: 44, height: 260)
        let frame = NewFilePromptController.cardFrame(size: card, toolbar: ToolbarPlacement(frame: right, shape: .vertical, collapsed: false), screen: screen)
        XCTAssertEqual(frame.maxX, right.minX - 10)
        XCTAssertEqual(frame.midY, right.midY)
        let left = CGRect(x: 8, y: 400, width: 44, height: 260)
        XCTAssertEqual(NewFilePromptController.cardFrame(size: card, toolbar: ToolbarPlacement(frame: left, shape: .vertical, collapsed: false), screen: screen).minX, left.maxX + 10)
    }

    func testCardClearsTheQuarterCircle() {
        for corner in ScreenCorner.allCases {
            let r = ToolbarLayout.arcRadius
            let arc = CGRect(x: corner.isLeft ? 0 : screen.maxX - r, y: corner.isTop ? screen.maxY - r : 0, width: r, height: r)
            let frame = NewFilePromptController.cardFrame(size: card, toolbar: ToolbarPlacement(frame: arc, shape: .cornerArc(corner), collapsed: false), screen: screen)
            XCTAssertTrue(screen.contains(frame))
            // The card's nearest point to the disc's center is its nearest corner, past the curve.
            let center = CGPoint(x: corner.isLeft ? screen.minX : screen.maxX, y: corner.isTop ? screen.maxY : screen.minY)
            let nearest = CGPoint(x: corner.isLeft ? frame.minX : frame.maxX, y: corner.isTop ? frame.maxY : frame.minY)
            XCTAssertGreaterThanOrEqual(hypot(nearest.x - center.x, nearest.y - center.y), r + 9.9, "\(corner)")
            XCTAssertFalse(frame.intersects(arc.insetBy(dx: 1, dy: 1)) && hypot(nearest.x - center.x, nearest.y - center.y) < r, "\(corner)")
        }
    }

    func testCardStaysOnScreenNextToBubble() {
        let bubble = CGRect(x: 1756, y: 0, width: 44, height: 44)
        let frame = NewFilePromptController.cardFrame(size: card, toolbar: ToolbarPlacement(frame: bubble, shape: .cornerArc(.bottomRight), collapsed: true), screen: screen)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertFalse(frame.intersects(bubble))
        let noToolbar = NewFilePromptController.cardFrame(size: card, toolbar: nil, screen: screen)
        XCTAssertEqual(noToolbar.maxX, screen.maxX - 16)
    }
}
