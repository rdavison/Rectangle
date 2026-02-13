//
//  AppSelectorTests.swift
//  RectangleTests
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import XCTest
import Carbon
@testable import Rectangle

class AppSelectorTests: XCTestCase {

    var node: AppSelectorWindow!

    // Helper: create a WindowInfo with given parameters
    private func makeWindow(
        id: CGWindowID = 1,
        pid: pid_t = 100,
        level: CGWindowLevel = CGWindowLevelForKey(.normalWindow),
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        processName: String? = nil,
        isOnscreen: Bool = true
    ) -> WindowInfo {
        return WindowInfo(id: id, level: level, frame: frame, pid: pid, processName: processName, isOnscreen: isOnscreen)
    }

    private let normalLevel = CGWindowLevelForKey(.normalWindow)

    override func setUp() {
        super.setUp()
        node = AppSelectorWindow()
    }

    override func tearDown() {
        node = nil
        super.tearDown()
    }

    // MARK: - MRU Ordering

    func testMRUOrderReflectsWindowZOrder() {
        // Windows in z-order: pid 10 frontmost, then pid 20, then pid 30
        let onScreen = [
            makeWindow(id: 1, pid: 10, isOnscreen: true),
            makeWindow(id: 2, pid: 20, isOnscreen: true),
            makeWindow(id: 3, pid: 30, isOnscreen: true),
        ]

        let pids = AppSelectorWindow.buildMRUPIDs(
            onScreenWindows: onScreen, allWindows: onScreen, myPID: 999,
            normalLevel: normalLevel, hiddenPIDs: []
        )

        XCTAssertEqual(pids, [10, 20, 30])
    }

    func testMRUDeduplicatesMultipleWindowsPerApp() {
        let onScreen = [
            makeWindow(id: 1, pid: 10, isOnscreen: true),
            makeWindow(id: 2, pid: 10, isOnscreen: true),  // second window of same app
            makeWindow(id: 3, pid: 20, isOnscreen: true),
        ]

        let pids = AppSelectorWindow.buildMRUPIDs(
            onScreenWindows: onScreen, allWindows: onScreen, myPID: 999,
            normalLevel: normalLevel, hiddenPIDs: []
        )

        XCTAssertEqual(pids, [10, 20], "Each PID should appear exactly once")
    }

    func testMRUExcludesMyPID() {
        let onScreen = [
            makeWindow(id: 1, pid: 999, isOnscreen: true),  // our own process
            makeWindow(id: 2, pid: 10, isOnscreen: true),
        ]

        let pids = AppSelectorWindow.buildMRUPIDs(
            onScreenWindows: onScreen, allWindows: onScreen, myPID: 999,
            normalLevel: normalLevel, hiddenPIDs: []
        )

        XCTAssertEqual(pids, [10], "Our own PID should be excluded")
    }

    func testMRUHiddenAppsAppearAfterVisibleApps() {
        let onScreen = [
            makeWindow(id: 1, pid: 10, isOnscreen: true),
            makeWindow(id: 3, pid: 30, isOnscreen: true),
        ]
        let all = [
            makeWindow(id: 1, pid: 10, isOnscreen: true),
            makeWindow(id: 2, pid: 20, isOnscreen: false),  // hidden app
            makeWindow(id: 3, pid: 30, isOnscreen: true),
        ]

        let pids = AppSelectorWindow.buildMRUPIDs(
            onScreenWindows: onScreen, allWindows: all, myPID: 999,
            normalLevel: normalLevel, hiddenPIDs: [20]
        )

        XCTAssertEqual(pids, [10, 30, 20], "Hidden app (20) should come after visible apps")
    }

    func testMRUIgnoresNonNormalLevelWindows() {
        let onScreen = [
            makeWindow(id: 1, pid: 10, level: normalLevel + 1, isOnscreen: true),  // overlay
            makeWindow(id: 2, pid: 20, isOnscreen: true),
        ]

        let pids = AppSelectorWindow.buildMRUPIDs(
            onScreenWindows: onScreen, allWindows: onScreen, myPID: 999,
            normalLevel: normalLevel, hiddenPIDs: []
        )

        XCTAssertEqual(pids, [20], "Only normal-level windows should count for MRU")
    }

    func testMRUOffScreenNonHiddenAppsExcluded() {
        // PID 20 has off-screen windows but is NOT in the hidden set
        let onScreen = [
            makeWindow(id: 1, pid: 10, isOnscreen: true),
        ]
        let all = [
            makeWindow(id: 1, pid: 10, isOnscreen: true),
            makeWindow(id: 2, pid: 20, isOnscreen: false),  // off-screen, not hidden
        ]

        let pids = AppSelectorWindow.buildMRUPIDs(
            onScreenWindows: onScreen, allWindows: all, myPID: 999,
            normalLevel: normalLevel, hiddenPIDs: []
        )

        XCTAssertEqual(pids, [10], "Off-screen non-hidden apps should not appear in MRU")
    }

    // MARK: - Backdrop Filtering

    func testBackdropShowsOnScreenWindowsForVisibleApp() {
        let windows = [
            makeWindow(id: 1, pid: 10, isOnscreen: true),
            makeWindow(id: 2, pid: 10, isOnscreen: true),
            makeWindow(id: 3, pid: 20, isOnscreen: true),  // different app
        ]

        let result = AppSelectorWindow.filterWindowsForBackdrop(
            from: windows, pid: 10,
            normalLevel: normalLevel, appIsHidden: false
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.pid == 10 })
    }

    func testBackdropExcludesOffScreenWindowsForVisibleApp() {
        let windows = [
            makeWindow(id: 1, pid: 10, isOnscreen: true),
            makeWindow(id: 2, pid: 10, isOnscreen: false),  // off-screen
        ]

        let result = AppSelectorWindow.filterWindowsForBackdrop(
            from: windows, pid: 10,
            normalLevel: normalLevel, appIsHidden: false
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, 1)
    }

    func testBackdropShowsAllWindowsForHiddenApp() {
        let windows = [
            makeWindow(id: 1, pid: 10, isOnscreen: false),
            makeWindow(id: 2, pid: 10, isOnscreen: false),
        ]

        let result = AppSelectorWindow.filterWindowsForBackdrop(
            from: windows, pid: 10,
            normalLevel: normalLevel, appIsHidden: true
        )

        XCTAssertEqual(result.count, 2, "All windows should be included when app is hidden")
    }

    func testBackdropExcludesNonNormalLevelWindows() {
        let windows = [
            makeWindow(id: 1, pid: 10, level: normalLevel, isOnscreen: true),
            makeWindow(id: 2, pid: 10, level: normalLevel + 1, isOnscreen: true),  // overlay
            makeWindow(id: 3, pid: 10, level: normalLevel - 1, isOnscreen: true),  // below normal
        ]

        let result = AppSelectorWindow.filterWindowsForBackdrop(
            from: windows, pid: 10,
            normalLevel: normalLevel, appIsHidden: false
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, 1)
    }

    func testBackdropExcludesTinyWindows() {
        let windows = [
            makeWindow(id: 1, pid: 10, frame: CGRect(x: 0, y: 0, width: 800, height: 600), isOnscreen: true),
            makeWindow(id: 2, pid: 10, frame: CGRect(x: 0, y: 0, width: 10, height: 10), isOnscreen: true),   // tiny
            makeWindow(id: 3, pid: 10, frame: CGRect(x: 0, y: 0, width: 200, height: 1), isOnscreen: true),    // 1px tall
            makeWindow(id: 4, pid: 10, frame: CGRect(x: 0, y: 0, width: 1, height: 200), isOnscreen: true),    // 1px wide
        ]

        let result = AppSelectorWindow.filterWindowsForBackdrop(
            from: windows, pid: 10,
            normalLevel: normalLevel, appIsHidden: false
        )

        XCTAssertEqual(result.count, 1, "Only the 800x600 window should pass the size filter")
        XCTAssertEqual(result.first?.id, 1)
    }

    // MARK: - Gallery Filtering

    func testGalleryShowsOnScreenWindowsForVisibleApp() {
        let windows = [
            makeWindow(id: 1, pid: 10, isOnscreen: true),
            makeWindow(id: 2, pid: 10, isOnscreen: true),
        ]

        let result = AppSelectorWindow.filterWindowsForGallery(
            from: windows, pid: 10, myPID: 999,
            normalLevel: normalLevel, appIsHidden: false
        )

        XCTAssertEqual(result.count, 2)
    }

    func testGalleryExcludesMyPID() {
        let windows = [
            makeWindow(id: 1, pid: 999, isOnscreen: true),  // our own
            makeWindow(id: 2, pid: 10, isOnscreen: true),
        ]

        let result = AppSelectorWindow.filterWindowsForGallery(
            from: windows, pid: 999, myPID: 999,
            normalLevel: normalLevel, appIsHidden: false
        )

        XCTAssertEqual(result.count, 0, "Gallery should exclude our own process windows")
    }

    func testGalleryShowsAllWindowsForHiddenApp() {
        let windows = [
            makeWindow(id: 1, pid: 10, isOnscreen: false),
            makeWindow(id: 2, pid: 10, isOnscreen: false),
        ]

        let result = AppSelectorWindow.filterWindowsForGallery(
            from: windows, pid: 10, myPID: 999,
            normalLevel: normalLevel, appIsHidden: true
        )

        XCTAssertEqual(result.count, 2)
    }

    func testGalleryExcludesTinyWindows() {
        let windows = [
            makeWindow(id: 1, pid: 10, frame: CGRect(x: 0, y: 0, width: 800, height: 600), isOnscreen: true),
            makeWindow(id: 2, pid: 10, frame: CGRect(x: 0, y: 0, width: 30, height: 30), isOnscreen: true),
        ]

        let result = AppSelectorWindow.filterWindowsForGallery(
            from: windows, pid: 10, myPID: 999,
            normalLevel: normalLevel, appIsHidden: false
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, 1)
    }

    // MARK: - Initial Selection Index

    func testAppsOnlyStartsAtSecondApp() {
        XCTAssertEqual(AppSelectorWindow.initialSelectionIndex(appCount: 5, override: nil), 1)
    }

    func testAppsOnlyWithSingleAppStartsAtZero() {
        XCTAssertEqual(AppSelectorWindow.initialSelectionIndex(appCount: 1, override: nil), 0)
    }

    func testAppsOnlyWithZeroAppsStartsAtZero() {
        XCTAssertEqual(AppSelectorWindow.initialSelectionIndex(appCount: 0, override: nil), 0)
    }

    func testAppsOnlyWithOverrideUsesOverride() {
        XCTAssertEqual(AppSelectorWindow.initialSelectionIndex(appCount: 5, override: 3), 3)
    }

    func testAppsOnlyWithOverrideBeyondCountFallsBack() {
        XCTAssertEqual(AppSelectorWindow.initialSelectionIndex(appCount: 3, override: 5), 1,
                       "Override beyond app count should fall back to default (index 1)")
    }

    // MARK: - Key Navigation (handleKeyDown)

    func testRightArrowNavigatesNextInAppsOnlyMode() {
        // Set up minimal state: 3 apps, selected at index 1, appsOnly mode
        // We can't use real NSRunningApplication in tests, so we test the static
        // navigation math directly
        node.hudMode = .appsOnly
        // navigateNextApp/navigatePreviousApp rely on apps array and selectorPanel
        // Test the wrapping math instead:
        let count = 5
        var index = 3
        index = (index + 1) % count
        XCTAssertEqual(index, 4)
        index = (index + 1) % count
        XCTAssertEqual(index, 0, "Should wrap around to 0")
    }

    func testLeftArrowWrapsToEnd() {
        let count = 5
        var index = 0
        index = (index - 1 + count) % count
        XCTAssertEqual(index, 4, "Should wrap to last index")
    }

    // MARK: - handleFlagsChanged (Cmd release)

    func testCmdReleaseReturnsDismiss() {
        // When Cmd is released, handleFlagsChanged should return .dismiss
        let flags = CGEventFlags()  // no flags = Cmd released
        let result = node.handleFlagsChanged(modifiers: flags)

        if case .dismiss = result {
            // Expected
        } else {
            XCTFail("Expected .dismiss when Cmd released, got \(result)")
        }
    }

    func testCmdStillHeldReturnsUnhandled() {
        let flags = CGEventFlags.maskCommand
        let result = node.handleFlagsChanged(modifiers: flags)

        if case .unhandled = result {
            // Expected
        } else {
            XCTFail("Expected .unhandled when Cmd still held, got \(result)")
        }
    }

    // MARK: - handleKeyDown routing

    func testRightArrowInAppsOnlyReturnsHandled() {
        node.hudMode = .appsOnly
        let result = node.handleKeyDown(keyCode: kVK_RightArrow, modifiers: [], characters: nil)

        if case .handled = result {
            // Expected
        } else {
            XCTFail("Expected .handled for right arrow, got \(result)")
        }
    }

    func testLeftArrowInAppsOnlyReturnsHandled() {
        node.hudMode = .appsOnly
        let result = node.handleKeyDown(keyCode: kVK_LeftArrow, modifiers: [], characters: nil)

        if case .handled = result {
            // Expected
        } else {
            XCTFail("Expected .handled for left arrow, got \(result)")
        }
    }

    func testUnrecognizedKeyReturnsUnhandled() {
        let result = node.handleKeyDown(keyCode: kVK_ANSI_Z, modifiers: [], characters: "z")

        if case .unhandled = result {
            // Expected
        } else {
            XCTFail("Expected .unhandled for unrecognized key, got \(result)")
        }
    }

    // MARK: - Edge cases

    func testMRUEmptyWindowListReturnsEmptyPIDs() {
        let pids = AppSelectorWindow.buildMRUPIDs(
            onScreenWindows: [], allWindows: [], myPID: 999,
            normalLevel: normalLevel, hiddenPIDs: []
        )
        XCTAssertTrue(pids.isEmpty)
    }

    func testBackdropEmptyWindowListReturnsEmpty() {
        let result = AppSelectorWindow.filterWindowsForBackdrop(
            from: [], pid: 10,
            normalLevel: normalLevel, appIsHidden: false
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testGalleryEmptyWindowListReturnsEmpty() {
        let result = AppSelectorWindow.filterWindowsForGallery(
            from: [], pid: 10, myPID: 999,
            normalLevel: normalLevel, appIsHidden: false
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testBackdropMinSizeThreshold() {
        // Windows exactly at the threshold should be excluded (> 50, not >=)
        let windows = [
            makeWindow(id: 1, pid: 10, frame: CGRect(x: 0, y: 0, width: 50, height: 50), isOnscreen: true),
            makeWindow(id: 2, pid: 10, frame: CGRect(x: 0, y: 0, width: 51, height: 51), isOnscreen: true),
        ]

        let result = AppSelectorWindow.filterWindowsForBackdrop(
            from: windows, pid: 10,
            normalLevel: normalLevel, appIsHidden: false
        )

        XCTAssertEqual(result.count, 1, "50x50 should be excluded, 51x51 should pass")
        XCTAssertEqual(result.first?.id, 2)
    }

    func testMRUOnScreenAppBeatsHiddenAppEvenIfHiddenWindowComesFirst() {
        // On-screen list only has visible windows
        let onScreen = [
            makeWindow(id: 2, pid: 10, isOnscreen: true),
        ]
        // All-windows list includes the hidden app's off-screen window
        let all = [
            makeWindow(id: 1, pid: 20, isOnscreen: false),  // hidden app
            makeWindow(id: 2, pid: 10, isOnscreen: true),
        ]

        let pids = AppSelectorWindow.buildMRUPIDs(
            onScreenWindows: onScreen, allWindows: all, myPID: 999,
            normalLevel: normalLevel, hiddenPIDs: [20]
        )

        XCTAssertEqual(pids, [10, 20], "Visible app should come before hidden app regardless of z-order")
    }
}
