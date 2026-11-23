import Carbon.HIToolbox
import XCTest
@testable import ClutterBuster

final class PeekShortcutTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "PeekShortcutTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Storage

    func testDefaultsToControlSpace() {
        XCTAssertEqual(AppSettings.peekShortcut(in: defaults), .controlSpace)
        XCTAssertEqual(KeyShortcut.controlSpace.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(KeyShortcut.controlSpace.modifiers, UInt32(controlKey))
    }

    func testSavesKeyCodeAndModifiers() {
        let shortcut = KeyShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | cmdKey))
        AppSettings.setPeekShortcut(shortcut, in: defaults)
        XCTAssertEqual(defaults.integer(forKey: AppSettings.peekKeyCodeKey), kVK_ANSI_P)
        XCTAssertEqual(defaults.integer(forKey: AppSettings.peekModifiersKey), optionKey | cmdKey)
        XCTAssertEqual(AppSettings.peekShortcut(in: defaults), shortcut)
    }

    func testClearingIsKeptRatherThanFallingBackToTheDefault() {
        AppSettings.setPeekShortcut(nil, in: defaults)
        XCTAssertNil(AppSettings.peekShortcut(in: defaults))
        AppSettings.setPeekShortcut(.controlSpace, in: defaults)
        XCTAssertEqual(AppSettings.peekShortcut(in: defaults), .controlSpace)
    }

    func testOnlyKeepsTheFourModifiers() {
        let shortcut = KeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | alphaLock))
        XCTAssertEqual(shortcut, .controlSpace, "Caps Lock isn't part of a shortcut")
        let flags = KeyShortcut(keyCode: UInt16(kVK_Space), flags: [.control, .capsLock, .numericPad])
        XCTAssertEqual(flags, .controlSpace)
    }

    // MARK: Display

    func testDisplayNames() {
        XCTAssertEqual(KeyShortcut.controlSpace.displayName, "\u{2303}Space")
        XCTAssertEqual(KeyShortcut(keyCode: UInt32(kVK_F5), modifiers: 0).displayName, "F5")
        XCTAssertEqual(KeyShortcut(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(cmdKey | optionKey)).displayName, "\u{2325}\u{2318}\u{2191}")
        XCTAssertEqual(KeyShortcut.escape.displayName, "\u{238B}")
    }

    func testModifiersShowInMenuOrder() {
        let all = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        XCTAssertEqual(KeyShortcut.symbols(for: all), "\u{2303}\u{2325}\u{21E7}\u{2318}")
    }

    func testLetterKeysFallBackToAUSKeyboard() {
        XCTAssertEqual(KeyShortcut.keyName(UInt32(kVK_ANSI_K), usingLayout: false), "K")
        XCTAssertEqual(KeyShortcut.keyName(UInt32(kVK_ANSI_Slash), usingLayout: false), "/")
        let flags = KeyShortcut(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .shift])
        XCTAssertEqual(KeyShortcut.symbols(for: flags.modifiers) + KeyShortcut.keyName(flags.keyCode, usingLayout: false), "\u{2303}\u{21E7}K")
    }

    // MARK: What can be a shortcut

    func testNeedsControlOptionOrCommandUnlessItsAFunctionKey() {
        XCTAssertNil(KeyShortcut.controlSpace.problem)
        XCTAssertNil(KeyShortcut(keyCode: UInt32(kVK_F12), modifiers: 0).problem)
        XCTAssertNotNil(KeyShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: 0).problem)
        XCTAssertNotNil(KeyShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey)).problem, "Shift alone would go off while typing")
        XCTAssertNil(KeyShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | shiftKey)).problem)
    }

    func testControlSpaceConflictsWithTheInputSourceShortcutOnlyWithSeveralSources() {
        let inputSource = SystemShortcuts.Entry(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey), enabled: true)
        XCTAssertEqual(SystemShortcuts.conflict(for: .controlSpace, entries: [inputSource], inputSources: 2), "select the previous input source")
        XCTAssertNil(SystemShortcuts.conflict(for: .controlSpace, entries: [inputSource], inputSources: 1))
        var off = inputSource
        off.enabled = false
        XCTAssertNil(SystemShortcuts.conflict(for: .controlSpace, entries: [off], inputSources: 2))
    }

    func testOtherSystemShortcutsAlwaysConflict() {
        let spotlight = SystemShortcuts.Entry(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), enabled: true)
        let commandSpace = KeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
        XCTAssertEqual(SystemShortcuts.conflict(for: commandSpace, entries: [spotlight], inputSources: 1), "open Spotlight")
        XCTAssertNil(SystemShortcuts.conflict(for: .controlSpace, entries: [spotlight], inputSources: 3))
        let missionControl = SystemShortcuts.Entry(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey), enabled: true)
        let controlUp = KeyShortcut(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey))
        XCTAssertEqual(SystemShortcuts.conflict(for: controlUp, entries: [missionControl], inputSources: 1), "run one of its keyboard shortcuts")
    }
}

final class PeekStateTests: XCTestCase {
    func testTheShortcutStartsAndEndsAPeek() {
        var peek = PeekState()
        XCTAssertEqual(peek.handle(.hotKey, fencesHidden: false), .start(showingHiddenFences: false))
        XCTAssertTrue(peek.isPeeking)
        XCTAssertEqual(peek.handle(.hotKey, fencesHidden: false), .end(hidingFencesAgain: false))
        XCTAssertFalse(peek.isPeeking)
    }

    func testEscapeOutsideClicksOpeningAndRevealingEndIt() {
        for trigger in [PeekState.Trigger.escape, .outsideClick, .openedItem, .revealedInFinder, .fencesShownOrHidden] {
            var peek = PeekState()
            _ = peek.handle(.hotKey, fencesHidden: false)
            XCTAssertEqual(peek.handle(trigger, fencesHidden: false), .end(hidingFencesAgain: false), "\(trigger)")
            XCTAssertFalse(peek.isPeeking, "\(trigger)")
        }
    }

    func testOnlyTheShortcutStartsOne() {
        for trigger in [PeekState.Trigger.escape, .outsideClick, .clickInFence, .openedItem, .revealedInFinder, .fencesShownOrHidden] {
            var peek = PeekState()
            XCTAssertNil(peek.handle(trigger, fencesHidden: false), "\(trigger)")
            XCTAssertFalse(peek.isPeeking, "\(trigger)")
        }
    }

    func testClickingInAFenceKeepsItGoing() {
        var peek = PeekState()
        _ = peek.handle(.hotKey, fencesHidden: false)
        XCTAssertNil(peek.handle(.clickInFence, fencesHidden: false))
        XCTAssertNil(peek.handle(.clickInFence, fencesHidden: false))
        XCTAssertTrue(peek.isPeeking)
        XCTAssertEqual(peek.handle(.escape, fencesHidden: false), .end(hidingFencesAgain: false))
    }

    func testHiddenFencesComeOutForThePeekAndGoAwayAfter() {
        for trigger in [PeekState.Trigger.hotKey, .escape, .outsideClick, .openedItem, .revealedInFinder] {
            var peek = PeekState()
            XCTAssertEqual(peek.handle(.hotKey, fencesHidden: true), .start(showingHiddenFences: true))
            XCTAssertTrue(peek.showsHiddenFences)
            XCTAssertNil(peek.handle(.clickInFence, fencesHidden: true))
            XCTAssertEqual(peek.handle(trigger, fencesHidden: true), .end(hidingFencesAgain: true), "\(trigger)")
            XCTAssertFalse(peek.showsHiddenFences)
        }
    }

    func testShowingTheFencesDuringAPeekLeavesThemOut() {
        var peek = PeekState()
        _ = peek.handle(.hotKey, fencesHidden: true)
        XCTAssertEqual(peek.handle(.fencesShownOrHidden, fencesHidden: true), .end(hidingFencesAgain: false),
                       "Show Fences decides they stay; the peek doesn't hide them again")
    }

    func testTheNextPeekStartsFresh() {
        var peek = PeekState()
        _ = peek.handle(.hotKey, fencesHidden: true)
        _ = peek.handle(.escape, fencesHidden: true)
        XCTAssertEqual(peek.handle(.hotKey, fencesHidden: false), .start(showingHiddenFences: false))
        XCTAssertEqual(peek.handle(.outsideClick, fencesHidden: false), .end(hidingFencesAgain: false))
    }
}
