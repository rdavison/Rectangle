//
//  AppSelectorWindow.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa
import Carbon

/// Log perf message to stderr (always captured) and in-app log viewer (when open).
func perfLog(_ message: String) {
    NSLog("%@", message)
    Logger.log(message)
}

class AppSelectorWindow: SelectorNode {

    enum HUDMode {
        case appsOnly, windowsOnly, combined
    }

    // MARK: - Pure Logic (testable)

    /// Build MRU-ordered PID list from window z-order.
    /// `onScreenWindows` must come from `.optionOnScreenOnly` for reliable z-order.
    /// `allWindows` from `.optionAll` is used only to find hidden app windows.
    static func buildMRUPIDs(
        onScreenWindows: [WindowInfo],
        allWindows: [WindowInfo],
        myPID: pid_t,
        normalLevel: CGWindowLevel,
        hiddenPIDs: Set<pid_t>
    ) -> [pid_t] {
        var seenPIDs = Set<pid_t>()
        var orderedPIDs: [pid_t] = []
        // On-screen windows determine MRU order (from .optionOnScreenOnly — reliable z-order)
        for win in onScreenWindows where win.level == normalLevel && win.pid != myPID {
            if seenPIDs.insert(win.pid).inserted {
                orderedPIDs.append(win.pid)
            }
        }
        // Hidden apps that have windows (appended after on-screen apps)
        for win in allWindows where win.level == normalLevel && win.pid != myPID && !win.isOnscreen && hiddenPIDs.contains(win.pid) {
            if seenPIDs.insert(win.pid).inserted {
                orderedPIDs.append(win.pid)
            }
        }
        return orderedPIDs
    }

    /// Filter windows for the 3D backdrop display.
    static func filterWindowsForBackdrop(
        from windows: [WindowInfo],
        pid: pid_t,
        normalLevel: CGWindowLevel,
        appIsHidden: Bool,
        minSize: CGFloat = 50
    ) -> [WindowInfo] {
        return windows.filter {
            $0.pid == pid && $0.level == normalLevel
                && $0.frame.width > minSize && $0.frame.height > minSize
                && ($0.isOnscreen || appIsHidden)
        }
    }

    /// Filter windows for the gallery thumbnail strip.
    static func filterWindowsForGallery(
        from windows: [WindowInfo],
        pid: pid_t,
        myPID: pid_t,
        normalLevel: CGWindowLevel,
        appIsHidden: Bool,
        minSize: CGFloat = 50
    ) -> [WindowInfo] {
        return windows.filter {
            $0.pid == pid && $0.level == normalLevel && $0.pid != myPID
                && $0.frame.width > minSize && $0.frame.height > minSize
                && ($0.isOnscreen || appIsHidden)
        }
    }

    /// Compute initial selected index for appsOnly mode.
    static func initialSelectionIndex(appCount: Int, override: Int?) -> Int {
        if let override = override, override < appCount {
            return override
        }
        return appCount > 1 ? 1 : 0
    }

    // MARK: - Properties

    private(set) var selectorPanel: AppSelectorPanel?
    var apps: [NSRunningApplication] = []
    var selectedIndex: Int = 0
    private(set) var previousApp: NSRunningApplication?
    var refreshTimer: Timer?

    // Gallery state (window thumbnails for the selected app)
    var galleryWindows: [WindowInfo] = []
    var gallerySelectedIndex: Int = 0

    // Unified window stage (replaces backdropPanel + windowCarousel)
    var windowStage: WindowStage?
    var backdrop: BackdropPanel?
    var backdropWindows: [WindowInfo] = []

    // Config saved from activate() for use in extensions
    var config: WindowStage.Config!

    // Cached window list snapshots — taken once at activation, reused for tab switches.
    // onScreen has reliable z-order (.optionOnScreenOnly); all includes off-screen windows.
    var cachedOnScreenWindowList: [WindowInfo] = []
    var cachedWindowList: [WindowInfo] = []

    // Pre-cached AX elements and screenshots keyed by window ID
    var galleryElements: [CGWindowID: AccessibilityElement] = [:]
    var screenshotCache: [CGWindowID: CGImage] = [:]

    // HUD mode
    var hudMode: HUDMode = .appsOnly
    var initialHUDMode: HUDMode = .appsOnly
    var initialAppIndex: Int?

    // Window preview state — tracks whether we're cycling windows with `
    var isPreviewingWindow: Bool = false
    var previewRefreshTimer: Timer?

    // Generation counter — incremented on each selection change.
    // Background callbacks capture the current generation and check it before
    // applying updates, discarding stale results from previous selections.
    private(set) var selectionGeneration: UInt = 0

    // Debounced raise — cancelled on each new selection to prevent concurrent raises.
    var pendingRaiseWork: DispatchWorkItem?

    var panel: NSPanel? { selectorPanel }

    var selectedApp: NSRunningApplication? {
        guard selectedIndex >= 0, selectedIndex < apps.count else { return nil }
        return apps[selectedIndex]
    }

    // MARK: - Lifecycle

    func activate(context: SelectorContext) {
        let activateStart = CFAbsoluteTimeGetCurrent()
        previousApp = NSWorkspace.shared.frontmostApplication

        // Build app list in MRU order using window z-order
        let myPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        let t0 = CFAbsoluteTimeGetCurrent()
        // .optionOnScreenOnly gives reliable front-to-back z-order for MRU
        let onScreenWindows = WindowUtil.getWindowList()
        let allWindows = WindowUtil.getWindowList(all: true)
        perfLog("[perf] getWindowList \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000))ms (\(onScreenWindows.count) on-screen, \(allWindows.count) all)")
        cachedOnScreenWindowList = onScreenWindows
        cachedWindowList = allWindows

        // Build hidden PID set so we can include hidden app windows later
        let hiddenPIDs: Set<pid_t> = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.isHidden }
                .map { $0.processIdentifier }
        )

        let orderedPIDs = Self.buildMRUPIDs(
            onScreenWindows: onScreenWindows, allWindows: allWindows,
            myPID: myPID, normalLevel: normalLevel, hiddenPIDs: hiddenPIDs
        )

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        let appsByPID = Dictionary(uniqueKeysWithValues: runningApps.map { ($0.processIdentifier, $0) })

        // MRU apps first, then any running apps without visible windows
        var ordered: [NSRunningApplication] = orderedPIDs.compactMap { appsByPID[$0] }
        let orderedSet = Set(orderedPIDs)
        for app in runningApps where !orderedSet.contains(app.processIdentifier) {
            ordered.append(app)
        }
        apps = ordered

        let appNames = apps.prefix(10).map { $0.localizedName ?? "pid:\($0.processIdentifier)" }
        perfLog("[mru] app order: \(appNames.joined(separator: " → "))")

        hudMode = initialHUDMode

        // Build initial gallery windows if starting in window mode
        if hudMode == .windowsOnly || hudMode == .combined {
            let targetPID = previousApp?.processIdentifier ?? (apps.first?.processIdentifier ?? 0)
            selectedIndex = apps.firstIndex(where: { $0.processIdentifier == targetPID }) ?? 0
            loadGalleryWindows(for: selectedIndex)
            // Start at index 1 (next window) like app selector starts at next app
            gallerySelectedIndex = galleryWindows.count > 1 ? 1 : 0
        } else {
            selectedIndex = Self.initialSelectionIndex(appCount: apps.count, override: initialAppIndex)
            galleryWindows = []
            gallerySelectedIndex = 0
            loadBackdropWindows(for: selectedIndex)
        }

        let t1 = CFAbsoluteTimeGetCurrent()
        let panel = AppSelectorPanel(
            mode: hudMode,
            apps: apps,
            selectedAppIndex: selectedIndex,
            galleryCount: galleryWindows.count,
            selectedWindowIndex: gallerySelectedIndex,
            screen: context.screen
        )
        perfLog("[perf] AppSelectorPanel init \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t1) * 1000))ms")
        panel.onAppHover = { [weak self] index in
            self?.selectAppIndex(index)
        }
        panel.onWindowHover = { [weak self] index in
            self?.selectGalleryIndex(index)
        }
        panel.onClickConfirm = { [weak self] in
            self?.confirmSelection()
            ModalModeManager.shared.deactivate(restoreLayout: false)
        }
        selectorPanel = panel

        // Create backdrop + window stage (if needed)
        config = WindowStage.Config(screen: context.screen, hudLevel: .popUpMenu)
        var bdPanel: BackdropPanel?
        if hudMode == .appsOnly {
            let bd = BackdropPanel(screen: context.screen)
            backdrop = bd
            bdPanel = bd
            bd.alphaValue = 0
            bd.orderFront(nil)

            let stage = WindowStage(config: config)
            windowStage = stage
            stage.show(windows: backdropWindows, layout: currentBackdropLayout,
                       initialFrontIndex: 0, cache: screenshotCache, animated: false)
        }

        // Show HUD above backdrop — single orderFront call
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // Fade in HUD + backdrop in a single animation group
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
            bdPanel?.animator().alphaValue = 1.0
        }

        // Load gallery thumbnails async if gallery is visible
        if hudMode == .windowsOnly || hudMode == .combined {
            captureGalleryThumbnails()
            raiseWindow(gallerySelectedIndex)
        }

        // Start refresh timer only when gallery is visible
        startRefreshTimerIfNeeded()

        // Kick off async screenshot capture for backdrop
        if bdPanel != nil {
            captureBackdropScreenshots()
            precacheAllAppScreenshots()
        }
        perfLog("[perf] activate() total \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - activateStart) * 1000))ms (mode=\(hudMode), \(apps.count) apps)")
    }

    func deactivate() {
        deactivate(animated: false)
    }

    func deactivate(animated: Bool) {
        // Invalidate generation so any in-flight async work is discarded
        selectionGeneration &+= 1
        pendingRaiseWork?.cancel()
        pendingRaiseWork = nil

        refreshTimer?.invalidate()
        refreshTimer = nil
        isPreviewingWindow = false
        previewRefreshTimer?.invalidate()
        previewRefreshTimer = nil
        windowStage?.tearDown(animated: false)
        windowStage = nil
        screenshotCache.removeAll()
        galleryElements.removeAll()
        cachedOnScreenWindowList = []
        cachedWindowList = []
        backdropWindows = []
        galleryWindows = []
        if animated, let panel = selectorPanel {
            let bd = backdrop
            selectorPanel = nil
            backdrop = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
                bd?.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
                bd?.orderOut(nil)
            }
        } else {
            selectorPanel?.orderOut(nil)
            selectorPanel = nil
            backdrop?.orderOut(nil)
            backdrop = nil
        }
    }

    // MARK: - SelectorNode Protocol

    func handleKeyDown(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?) -> KeyEventResult {
        // Left/Right arrows navigate gallery when visible, else navigate apps
        switch keyCode {
        case kVK_RightArrow:
            if hudMode == .windowsOnly || hudMode == .combined {
                cycleGalleryNext()
            } else {
                navigateNextApp()
            }
            return .handled
        case kVK_LeftArrow:
            if hudMode == .windowsOnly || hudMode == .combined {
                cycleGalleryPrevious()
            } else {
                navigatePreviousApp()
            }
            return .handled
        default:
            return .unhandled
        }
    }

    func handleFlagsChanged(modifiers: CGEventFlags) -> KeyEventResult {
        if !modifiers.contains(.maskCommand) {
            confirmSelection()
            return .dismiss
        }
        return .unhandled
    }

    // MARK: - App Navigation (visual only — no activation)

    func navigateNextApp() {
        pruneTerminatedApps()
        guard !apps.isEmpty else { return }
        selectAppIndex((selectedIndex + 1) % apps.count, direction: 1)
    }

    func navigatePreviousApp() {
        pruneTerminatedApps()
        guard !apps.isEmpty else { return }
        selectAppIndex((selectedIndex - 1 + apps.count) % apps.count, direction: -1)
    }

    /// Remove terminated apps from the list and rebuild the panel if anything changed.
    private func pruneTerminatedApps() {
        let oldCount = apps.count
        let currentApp = selectedIndex < apps.count ? apps[selectedIndex] : nil

        apps.removeAll { $0.isTerminated }

        guard apps.count != oldCount else { return }

        // Preserve selection on the same app, or clamp
        if let currentApp = currentApp, !currentApp.isTerminated {
            selectedIndex = apps.firstIndex(of: currentApp) ?? min(selectedIndex, max(0, apps.count - 1))
        } else {
            selectedIndex = min(selectedIndex, max(0, apps.count - 1))
        }

        // Rebuild panel with pruned list
        selectorPanel?.reconfigure(
            mode: hudMode,
            apps: apps,
            selectedAppIndex: selectedIndex,
            galleryCount: galleryWindows.count,
            selectedWindowIndex: gallerySelectedIndex
        )
    }

    /// Remove closed windows from the gallery and rebuild if anything changed.
    private func pruneStaleGalleryWindows() {
        guard !galleryWindows.isEmpty else { return }

        // Use cached window list for pruning — windows that existed at activation are still valid
        // for navigation. A truly closed window will fail to raise (harmless).
        let liveIDs = Set(cachedWindowList.map { $0.id })
        let oldCount = galleryWindows.count

        galleryWindows.removeAll { !liveIDs.contains($0.id) }

        guard galleryWindows.count != oldCount else { return }

        // Remove stale AX element refs
        for key in galleryElements.keys where !liveIDs.contains(key) {
            galleryElements.removeValue(forKey: key)
        }

        gallerySelectedIndex = min(gallerySelectedIndex, max(0, galleryWindows.count - 1))
        selectorPanel?.replaceGallery(count: galleryWindows.count)
        captureGalleryThumbnails()
        if !galleryWindows.isEmpty {
            selectorPanel?.updateWindowSelection(gallerySelectedIndex)
        }
    }

    private func selectAppIndex(_ index: Int, direction: CGFloat = 0) {
        guard index >= 0, index < apps.count, index != selectedIndex else { return }
        let tabStart = CFAbsoluteTimeGetCurrent()
        hideWindowPreview()
        galleryWindows = []  // Reset so next ` reloads for new app
        selectionGeneration &+= 1
        selectedIndex = index
        selectorPanel?.updateAppSelection(selectedIndex)

        if hudMode == .appsOnly {
            loadBackdropWindows(for: selectedIndex)
            captureBackdropScreenshots(direction: direction)
        } else if hudMode == .combined {
            loadGalleryWindows(for: selectedIndex)
            gallerySelectedIndex = 0
            selectorPanel?.replaceGallery(count: galleryWindows.count)
            captureGalleryThumbnails()
            selectorPanel?.updateWindowSelection(gallerySelectedIndex)
        }
        let appName = apps[index].localizedName ?? "pid:\(apps[index].processIdentifier)"
        perfLog("[perf] selectAppIndex \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - tabStart) * 1000))ms → \(appName)")
    }

    // MARK: - Gallery Navigation

    func cycleGalleryNext() {
        pruneStaleGalleryWindows()
        guard !galleryWindows.isEmpty else { return }
        gallerySelectedIndex = (gallerySelectedIndex + 1) % galleryWindows.count
        updateGallerySelection()
    }

    func cycleGalleryPrevious() {
        pruneStaleGalleryWindows()
        guard !galleryWindows.isEmpty else { return }
        gallerySelectedIndex = (gallerySelectedIndex - 1 + galleryWindows.count) % galleryWindows.count
        updateGallerySelection()
    }

    private func selectGalleryIndex(_ index: Int) {
        guard index >= 0, index < galleryWindows.count, index != gallerySelectedIndex else { return }
        gallerySelectedIndex = index
        updateGallerySelection()
    }

    private func updateGallerySelection() {
        selectorPanel?.updateWindowSelection(gallerySelectedIndex)
        raiseWindow(gallerySelectedIndex)
    }

    // MARK: - Mode Transitions

    func expandAppStrip() {
        guard hudMode == .windowsOnly else { return }
        hudMode = .combined

        selectorPanel?.reconfigure(
            mode: .combined,
            apps: apps,
            selectedAppIndex: selectedIndex,
            galleryCount: galleryWindows.count,
            selectedWindowIndex: gallerySelectedIndex
        )

        // Re-capture gallery thumbnails after reconfigure
        captureGalleryThumbnails()
    }

    // MARK: - Confirm / Cancel

    private func confirmSelection() {
        pruneTerminatedApps()

        // Snapshot preview state before animatePreviewFlyout clears it
        let wasPreviewing = isPreviewingWindow
        let previewedWindow: WindowInfo? = (wasPreviewing && gallerySelectedIndex >= 0 && gallerySelectedIndex < galleryWindows.count)
            ? galleryWindows[gallerySelectedIndex] : nil

        // Animate preview overlay to the target window's position before dismissing
        if let win = previewedWindow {
            animatePreviewFlyout(to: win)
        }

        switch hudMode {
        case .appsOnly:
            guard selectedIndex >= 0, selectedIndex < apps.count else { return }
            let app = apps[selectedIndex]
            guard !app.isTerminated else { return }

            // If the user was previewing a specific window (via Cmd+`), raise it
            if let win = previewedWindow {
                if let element = galleryElements[win.id] {
                    element.performAction(kAXRaiseAction as String)
                }
                NSRunningApplication(processIdentifier: win.pid)?.activate(options: .activateIgnoringOtherApps)
            } else {
                activateApp(app)
            }

            // Start fly-out animation on the window stage (only if not previewing)
            if previewedWindow == nil, !backdropWindows.isEmpty, let stage = windowStage {
                let windowFrames = backdropWindows.map { $0.frame }
                stage.flyOutAll(windowFrames: windowFrames) {}
            }

        case .windowsOnly, .combined:
            guard gallerySelectedIndex >= 0, gallerySelectedIndex < galleryWindows.count else { return }
            let win = galleryWindows[gallerySelectedIndex]
            if let element = galleryElements[win.id] {
                element.performAction(kAXRaiseAction as String)
            }
            NSRunningApplication(processIdentifier: win.pid)?.activate(options: .activateIgnoringOtherApps)
        }
    }

    private func activateApp(_ app: NSRunningApplication) {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        // Use cached window list — no need for a fresh syscall on confirm
        let hasWindows = cachedWindowList.contains {
            $0.pid == app.processIdentifier && $0.level == normalLevel && $0.pid != myPID
        }

        if !hasWindows, let bundleURL = app.bundleURL {
            NSWorkspace.shared.open(bundleURL)
        } else {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    func restorePrevious() {
        previousApp?.activate(options: .activateIgnoringOtherApps)
    }

    // MARK: - Refresh Timer

    func startRefreshTimerIfNeeded() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard hudMode == .windowsOnly || hudMode == .combined else { return }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshGalleryThumbnails()
        }
    }
}
