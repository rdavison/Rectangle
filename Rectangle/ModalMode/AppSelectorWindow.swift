//
//  AppSelectorWindow.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa
import Carbon

class AppSelectorWindow: SelectorNode {

    enum HUDMode {
        case appsOnly, windowsOnly, combined
    }

    private var selectorPanel: AppSelectorPanel?
    private var apps: [NSRunningApplication] = []
    private var selectedIndex: Int = 0
    private var previousApp: NSRunningApplication?
    private var refreshTimer: Timer?

    // Gallery state (window thumbnails for the selected app)
    private var galleryWindows: [WindowInfo] = []
    private var gallerySelectedIndex: Int = 0

    // Pre-cached AX elements and screenshots keyed by window ID
    private var galleryElements: [CGWindowID: AccessibilityElement] = [:]
    private var screenshotCache: [CGWindowID: NSImage] = [:]

    // HUD mode
    private(set) var hudMode: HUDMode = .appsOnly
    var initialHUDMode: HUDMode = .appsOnly

    var panel: NSPanel? { selectorPanel }

    var selectedApp: NSRunningApplication? {
        guard selectedIndex >= 0, selectedIndex < apps.count else { return nil }
        return apps[selectedIndex]
    }

    func activate(context: SelectorContext) {
        previousApp = NSWorkspace.shared.frontmostApplication

        // Build app list in MRU order using window z-order
        let myPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        let allWindows = WindowUtil.getWindowList()

        var seenPIDs = Set<pid_t>()
        var orderedPIDs: [pid_t] = []
        for win in allWindows where win.level == normalLevel && win.pid != myPID {
            if seenPIDs.insert(win.pid).inserted {
                orderedPIDs.append(win.pid)
            }
        }

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

        hudMode = initialHUDMode

        // Build initial gallery windows if starting in window mode
        if hudMode == .windowsOnly || hudMode == .combined {
            let targetPID = previousApp?.processIdentifier ?? (apps.first?.processIdentifier ?? 0)
            selectedIndex = apps.firstIndex(where: { $0.processIdentifier == targetPID }) ?? 0
            loadGalleryWindows(for: selectedIndex)
            // Start at index 1 (next window) like app selector starts at next app
            gallerySelectedIndex = galleryWindows.count > 1 ? 1 : 0
        } else {
            // appsOnly: start with the second app (index 1) since index 0 is the current app
            selectedIndex = apps.count > 1 ? 1 : 0
            galleryWindows = []
            gallerySelectedIndex = 0
        }

        let panel = AppSelectorPanel(
            mode: hudMode,
            apps: apps,
            selectedAppIndex: selectedIndex,
            galleryCount: galleryWindows.count,
            selectedWindowIndex: gallerySelectedIndex,
            screen: context.screen
        )
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
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }

        // Load gallery thumbnails async if gallery is visible
        if hudMode == .windowsOnly || hudMode == .combined {
            captureGalleryThumbnails()
            raiseWindow(gallerySelectedIndex)
        }

        // Start refresh timer only when gallery is visible
        startRefreshTimerIfNeeded()

        // Pre-cache screenshots for selected app so gallery opens instantly
        if hudMode == .appsOnly {
            precacheScreenshots(for: selectedIndex)
        }
    }

    func deactivate() {
        deactivate(animated: false)
    }

    func deactivate(animated: Bool) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        screenshotCache.removeAll()
        galleryElements.removeAll()

        if animated, let panel = selectorPanel {
            selectorPanel = nil
            animateDismiss(panel: panel)
        } else {
            selectorPanel?.orderOut(nil)
            selectorPanel = nil
        }
    }

    private func animateDismiss(panel: NSPanel) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

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
        selectAppIndex((selectedIndex + 1) % apps.count)
    }

    func navigatePreviousApp() {
        pruneTerminatedApps()
        guard !apps.isEmpty else { return }
        selectAppIndex((selectedIndex - 1 + apps.count) % apps.count)
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

        let liveIDs = Set(WindowUtil.getWindowList().map { $0.id })
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

    private func selectAppIndex(_ index: Int) {
        guard index >= 0, index < apps.count, index != selectedIndex else { return }
        selectedIndex = index
        selectorPanel?.updateAppSelection(selectedIndex)

        // Foreground all windows of the selected app
        raiseAllWindows(for: index)

        // In combined mode, refresh gallery for the newly selected app
        if hudMode == .combined {
            loadGalleryWindows(for: selectedIndex)
            gallerySelectedIndex = 0
            selectorPanel?.replaceGallery(count: galleryWindows.count)
            captureGalleryThumbnails()
            selectorPanel?.updateWindowSelection(gallerySelectedIndex)
        } else if hudMode == .appsOnly {
            // Pre-cache for the newly selected app
            precacheScreenshots(for: selectedIndex)
        }
    }

    /// Raise all non-minimized windows belonging to the app at the given index.
    private func raiseAllWindows(for appIndex: Int) {
        guard appIndex >= 0, appIndex < apps.count else { return }
        let app = apps[appIndex]

        // Raise each non-minimized window individually first
        let axApp = AccessibilityElement(app.processIdentifier)
        if let windowElements = axApp.windowElements {
            for element in windowElements {
                if element.isMinimized != true {
                    element.performAction(kAXRaiseAction as String)
                }
            }
        }

        // Then activate with all-windows flag to bring the entire app layer to front
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
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

    func expandGallery() {
        guard hudMode == .appsOnly else { return }
        loadGalleryWindows(for: selectedIndex)
        guard !galleryWindows.isEmpty else { return }

        hudMode = .combined
        gallerySelectedIndex = galleryWindows.count > 1 ? 1 : 0

        selectorPanel?.reconfigure(
            mode: .combined,
            apps: apps,
            selectedAppIndex: selectedIndex,
            galleryCount: galleryWindows.count,
            selectedWindowIndex: gallerySelectedIndex
        )

        captureGalleryThumbnails()
        startRefreshTimerIfNeeded()

        raiseWindow(gallerySelectedIndex)
    }

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
        switch hudMode {
        case .appsOnly:
            guard selectedIndex >= 0, selectedIndex < apps.count else { return }
            let app = apps[selectedIndex]
            guard !app.isTerminated else { return }

            let myPID = ProcessInfo.processInfo.processIdentifier
            let normalLevel = CGWindowLevelForKey(.normalWindow)
            let hasWindows = WindowUtil.getWindowList().contains {
                $0.pid == app.processIdentifier && $0.level == normalLevel && $0.pid != myPID
            }

            if !hasWindows, let bundleURL = app.bundleURL {
                NSWorkspace.shared.open(bundleURL)
            } else {
                app.activate(options: .activateIgnoringOtherApps)
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

    func restorePrevious() {
        previousApp?.activate(options: .activateIgnoringOtherApps)
    }

    // MARK: - Gallery Windows

    private func loadGalleryWindows(for appIndex: Int) {
        guard appIndex >= 0, appIndex < apps.count else {
            galleryWindows = []
            galleryElements = [:]
            return
        }
        let app = apps[appIndex]
        let pid = app.processIdentifier
        let myPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = CGWindowLevelForKey(.normalWindow)

        galleryWindows = WindowUtil.getWindowList().filter {
            $0.pid == pid && $0.level == normalLevel && $0.pid != myPID
        }

        // Pre-fetch all AX elements for this app's windows in one pass
        galleryElements = [:]
        let axApp = AccessibilityElement(pid)
        if let windowElements = axApp.windowElements {
            for element in windowElements {
                if let wid = element.windowId {
                    galleryElements[wid] = element
                }
            }
        }
    }

    private func captureGalleryThumbnails() {
        let windows = galleryWindows
        let cache = screenshotCache

        // Immediately apply any cached screenshots
        for (i, win) in windows.enumerated() {
            if let cached = cache[win.id] {
                selectorPanel?.updateGalleryThumbnail(cached, at: i)
            }
        }

        // Then capture fresh screenshots in the background
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for (i, win) in windows.enumerated() {
                if let image = WindowScreenshot.capture(windowID: win.id, maxSize: CGSize(width: 160, height: 120)) {
                    DispatchQueue.main.async {
                        self?.screenshotCache[win.id] = image
                        self?.selectorPanel?.updateGalleryThumbnail(image, at: i)
                    }
                }
            }
        }
    }

    private func precacheScreenshots(for appIndex: Int) {
        guard appIndex >= 0, appIndex < apps.count else { return }
        let pid = apps[appIndex].processIdentifier
        let myPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = CGWindowLevelForKey(.normalWindow)

        let windows = WindowUtil.getWindowList().filter {
            $0.pid == pid && $0.level == normalLevel && $0.pid != myPID
        }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for win in windows {
                if let image = WindowScreenshot.capture(windowID: win.id, maxSize: CGSize(width: 160, height: 120)) {
                    DispatchQueue.main.async {
                        self?.screenshotCache[win.id] = image
                    }
                }
            }
        }
    }

    private func raiseWindow(_ galleryIndex: Int) {
        guard galleryIndex >= 0, galleryIndex < galleryWindows.count else { return }
        let win = galleryWindows[galleryIndex]
        if let element = galleryElements[win.id] {
            element.performAction(kAXRaiseAction as String)
        }
    }

    // MARK: - Refresh Timer

    private func startRefreshTimerIfNeeded() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard hudMode == .windowsOnly || hudMode == .combined else { return }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshGalleryThumbnails()
        }
    }

    private func refreshGalleryThumbnails() {
        let windows = galleryWindows
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for (i, win) in windows.enumerated() {
                if let image = WindowScreenshot.capture(windowID: win.id, maxSize: CGSize(width: 160, height: 120)) {
                    DispatchQueue.main.async {
                        self?.selectorPanel?.updateGalleryThumbnail(image, at: i)
                    }
                }
            }
        }
    }
}

// MARK: - AppSelectorPanel

private class AppSelectorPanel: NSPanel {

    override var canBecomeKey: Bool { true }

    // Layout constants
    private let iconSize: CGFloat = 96
    private let iconPadding: CGFloat = 16
    private let panelPadding: CGFloat = 16
    private let galleryThumbWidth: CGFloat = 160
    private let galleryThumbHeight: CGFloat = 120
    private let galleryThumbPadding: CGFloat = 12
    private var mode: AppSelectorWindow.HUDMode
    private var apps: [NSRunningApplication]
    private var targetScreen: NSScreen

    // Subviews
    private var visualEffect: NSVisualEffectView!
    private var iconStripScrollView: NSScrollView?
    private var iconViews: [NSImageView] = []
    private var appSelectionBox: NSView?
    private var galleryScrollView: NSScrollView?
    private var galleryThumbViews: [NSImageView] = []
    private var gallerySelectionBox: NSView?
    private var galleryLeftInset: CGFloat = 0

    var onAppHover: ((Int) -> Void)?
    var onWindowHover: ((Int) -> Void)?
    var onClickConfirm: (() -> Void)?

    init(mode: AppSelectorWindow.HUDMode,
         apps: [NSRunningApplication],
         selectedAppIndex: Int,
         galleryCount: Int,
         selectedWindowIndex: Int,
         screen: NSScreen) {
        self.mode = mode
        self.apps = apps
        self.targetScreen = screen

        let size = AppSelectorPanel.panelSize(mode: mode, appCount: apps.count, galleryCount: galleryCount, screen: screen)
        let panelRect = NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        super.init(contentRect: panelRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        level = .popUpMenu
        hasShadow = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        acceptsMouseMovedEvents = true
        collectionBehavior = [.transient, .canJoinAllSpaces]

        visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelRect.size))
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.autoresizingMask = [.width, .height]
        contentView = visualEffect

        buildLayout(mode: mode, selectedAppIndex: selectedAppIndex, galleryCount: galleryCount, selectedWindowIndex: selectedWindowIndex)

        let trackingArea = NSTrackingArea(
            rect: visualEffect.bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        visualEffect.addTrackingArea(trackingArea)
    }

    // MARK: - Reconfigure (mode transition)

    func reconfigure(mode: AppSelectorWindow.HUDMode,
                     apps: [NSRunningApplication],
                     selectedAppIndex: Int,
                     galleryCount: Int,
                     selectedWindowIndex: Int) {
        self.mode = mode
        self.apps = apps

        // Clear all subviews
        clearLayout()

        // Resize panel
        let size = AppSelectorPanel.panelSize(mode: mode, appCount: apps.count, galleryCount: galleryCount, screen: targetScreen)
        let newRect = NSRect(
            x: targetScreen.visibleFrame.midX - size.width / 2,
            y: targetScreen.visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        setFrame(newRect, display: false)
        visualEffect.frame = NSRect(origin: .zero, size: size)

        buildLayout(mode: mode, selectedAppIndex: selectedAppIndex, galleryCount: galleryCount, selectedWindowIndex: selectedWindowIndex)
    }

    // MARK: - Update Methods

    func updateAppSelection(_ index: Int) {
        guard index >= 0, index < apps.count else { return }

        for (i, view) in iconViews.enumerated() {
            view.alphaValue = 1.0
        }

        let itemWidth = iconSize + iconPadding
        if let scrollView = iconStripScrollView, let selBox = appSelectionBox {
            let boxX = CGFloat(index) * itemWidth
            let scrollFrame = scrollView.frame

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.035
                selBox.animator().frame = NSRect(
                    x: scrollFrame.origin.x + boxX,
                    y: scrollFrame.origin.y - (itemWidth - iconSize) / 2,
                    width: itemWidth,
                    height: itemWidth
                )
            }

            let targetX = CGFloat(index) * itemWidth - scrollView.bounds.width / 2 + itemWidth / 2
            let maxScroll = max(0, (scrollView.documentView?.frame.width ?? 0) - scrollView.bounds.width)
            let clampedX = max(0, min(targetX, maxScroll))
            scrollView.contentView.scroll(to: NSPoint(x: clampedX, y: 0))
        }
    }

    func updateWindowSelection(_ index: Int) {
        guard index >= 0, index < galleryThumbViews.count else { return }

        for (i, view) in galleryThumbViews.enumerated() {
            view.alphaValue = 1.0
            view.layer?.borderColor = (i == index)
                ? NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
                : NSColor.white.withAlphaComponent(0.2).cgColor
            view.layer?.borderWidth = (i == index) ? 2.0 : 1.0
        }

        let itemWidth = galleryThumbWidth + galleryThumbPadding
        if let scrollView = galleryScrollView, let selBox = gallerySelectionBox {
            let scrollFrame = scrollView.frame
            let thumbY = (scrollView.bounds.height - galleryThumbHeight) / 2
            let boxX = scrollFrame.origin.x + galleryLeftInset + CGFloat(index) * itemWidth - galleryThumbPadding / 2
            let boxY = scrollFrame.origin.y + thumbY - 4
            let boxWidth = galleryThumbWidth + galleryThumbPadding
            let boxHeight = galleryThumbHeight + 8

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.035
                selBox.animator().frame = NSRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
            }

            let targetX = galleryLeftInset + CGFloat(index) * itemWidth - scrollView.bounds.width / 2 + itemWidth / 2
            let maxScroll = max(0, (scrollView.documentView?.frame.width ?? 0) - scrollView.bounds.width)
            let clampedX = max(0, min(targetX, maxScroll))
            scrollView.contentView.scroll(to: NSPoint(x: clampedX, y: 0))
        }
    }

    func updateGalleryThumbnail(_ image: NSImage, at index: Int) {
        guard index >= 0, index < galleryThumbViews.count else { return }
        let view = galleryThumbViews[index]
        view.image = image
        if view.alphaValue < 1.0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1.0
            }
        }
    }

    func replaceGallery(count: Int) {
        // Remove old gallery views
        galleryScrollView?.removeFromSuperview()
        gallerySelectionBox?.removeFromSuperview()
        galleryThumbViews.removeAll()

        guard let scrollFrame = galleryScrollViewFrame() else { return }

        // Rebuild gallery selection box
        let selBox = makeSelectionBox()
        visualEffect.addSubview(selBox)
        gallerySelectionBox = selBox

        // Rebuild gallery scroll
        let (scrollView, thumbViews) = buildGalleryStrip(frame: scrollFrame, count: count)
        visualEffect.addSubview(scrollView)
        galleryScrollView = scrollView
        galleryThumbViews = thumbViews
    }

    // MARK: - Mouse Events

    override func mouseMoved(with event: NSEvent) {
        if let index = appIconIndex(for: event) {
            onAppHover?(index)
        } else if let index = galleryThumbIndex(for: event) {
            onWindowHover?(index)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if appIconIndex(for: event) != nil || galleryThumbIndex(for: event) != nil {
            onClickConfirm?()
        }
    }

    // MARK: - Hit Testing

    private func appIconIndex(for event: NSEvent) -> Int? {
        guard let contentView = contentView, let scrollView = iconStripScrollView else { return nil }
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)

        let scrollFrame = scrollView.frame
        guard scrollFrame.contains(pointInContent) else { return nil }

        let pointInScroll = scrollView.convert(pointInContent, from: contentView)
        let scrollOffset = scrollView.contentView.bounds.origin
        let pointInDoc = NSPoint(x: pointInScroll.x + scrollOffset.x, y: pointInScroll.y + scrollOffset.y)

        let itemWidth = iconSize + iconPadding
        let index = Int(pointInDoc.x / itemWidth)
        guard index >= 0, index < apps.count else { return nil }
        return index
    }

    private func galleryThumbIndex(for event: NSEvent) -> Int? {
        guard let contentView = contentView, let scrollView = galleryScrollView else { return nil }
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)

        let scrollFrame = scrollView.frame
        guard scrollFrame.contains(pointInContent) else { return nil }

        let pointInScroll = scrollView.convert(pointInContent, from: contentView)
        let scrollOffset = scrollView.contentView.bounds.origin
        let pointInDoc = NSPoint(x: pointInScroll.x + scrollOffset.x, y: pointInScroll.y + scrollOffset.y)

        let itemWidth = galleryThumbWidth + galleryThumbPadding
        let adjustedX = pointInDoc.x - galleryLeftInset
        guard adjustedX >= 0 else { return nil }
        let index = Int(adjustedX / itemWidth)
        guard index >= 0, index < galleryThumbViews.count else { return nil }
        return index
    }

    // MARK: - Panel Sizing

    private static func panelSize(mode: AppSelectorWindow.HUDMode, appCount: Int, galleryCount: Int, screen: NSScreen) -> NSSize {
        let panelPadding: CGFloat = 16
        let iconSize: CGFloat = 96
        let iconPadding: CGFloat = 16
        let galleryThumbWidth: CGFloat = 160
        let galleryThumbPadding: CGFloat = 12
        let galleryThumbHeight: CGFloat = 120
        let iconItemWidth = iconSize + iconPadding

        let maxWidth = screen.visibleFrame.width - 40

        switch mode {
        case .appsOnly:
            let totalAppWidth = CGFloat(appCount) * iconItemWidth + panelPadding * 2
            let width = min(max(totalAppWidth, 400), maxWidth)
            // [pad] icon strip [pad]
            let height = panelPadding + iconItemWidth + panelPadding
            return NSSize(width: width, height: height)

        case .windowsOnly:
            let galleryItemWidth = galleryThumbWidth + galleryThumbPadding
            let totalGalleryWidth = CGFloat(galleryCount) * galleryItemWidth + panelPadding * 2
            let width = min(max(totalGalleryWidth, 400), maxWidth)
            // [pad] thumbnail strip [pad]
            let height = panelPadding + galleryThumbHeight + panelPadding
            return NSSize(width: width, height: height)

        case .combined:
            let totalAppWidth = CGFloat(appCount) * iconItemWidth + panelPadding * 2
            let galleryItemWidth = galleryThumbWidth + galleryThumbPadding
            let totalGalleryWidth = CGFloat(galleryCount) * galleryItemWidth + panelPadding * 2
            let width = min(max(max(totalAppWidth, totalGalleryWidth), 400), maxWidth)
            // [pad] thumbnails [12] icon strip [pad]
            let height = panelPadding + galleryThumbHeight + 12 + iconItemWidth + panelPadding
            return NSSize(width: width, height: height)
        }
    }

    // MARK: - Layout Building

    private func clearLayout() {
        iconStripScrollView?.removeFromSuperview()
        iconStripScrollView = nil
        iconViews.removeAll()
        appSelectionBox?.removeFromSuperview()
        appSelectionBox = nil
        galleryScrollView?.removeFromSuperview()
        galleryScrollView = nil
        galleryThumbViews.removeAll()
        gallerySelectionBox?.removeFromSuperview()
        gallerySelectionBox = nil
        galleryLeftInset = 0
    }

    private func buildLayout(mode: AppSelectorWindow.HUDMode, selectedAppIndex: Int, galleryCount: Int, selectedWindowIndex: Int) {
        switch mode {
        case .appsOnly:
            buildAppsOnlyLayout(selectedAppIndex: selectedAppIndex)
        case .windowsOnly:
            buildWindowsOnlyLayout(galleryCount: galleryCount, selectedWindowIndex: selectedWindowIndex)
        case .combined:
            buildCombinedLayout(selectedAppIndex: selectedAppIndex, galleryCount: galleryCount, selectedWindowIndex: selectedWindowIndex)
        }
    }

    private func buildAppsOnlyLayout(selectedAppIndex: Int) {
        let itemWidth = iconSize + iconPadding
        let panelW = frame.width

        // Selection box (behind icons)
        let selBox = makeSelectionBox()
        visualEffect.addSubview(selBox)
        appSelectionBox = selBox

        // Icon strip scroll view
        let stripY = panelPadding
        let stripHeight = iconSize
        let scrollView = NSScrollView(frame: NSRect(x: panelPadding, y: stripY + (itemWidth - iconSize) / 2, width: panelW - panelPadding * 2, height: stripHeight))
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width]

        let clipView = NSClipView(frame: scrollView.bounds)
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        let docWidth = CGFloat(apps.count) * itemWidth
        let docView = NSView(frame: NSRect(x: 0, y: 0, width: max(docWidth, scrollView.bounds.width), height: stripHeight))
        scrollView.documentView = docView

        for (index, app) in apps.enumerated() {
            let x = CGFloat(index) * itemWidth + (itemWidth - iconSize) / 2
            let imageView = NSImageView(frame: NSRect(x: x, y: 0, width: iconSize, height: iconSize))
            imageView.image = app.icon
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 12
            docView.addSubview(imageView)
            iconViews.append(imageView)
        }

        visualEffect.addSubview(scrollView)
        iconStripScrollView = scrollView

        updateAppSelection(selectedAppIndex)
    }

    private func buildWindowsOnlyLayout(galleryCount: Int, selectedWindowIndex: Int) {
        let panelW = frame.width

        // Gallery selection box
        let selBox = makeSelectionBox()
        visualEffect.addSubview(selBox)
        gallerySelectionBox = selBox

        // Gallery strip
        let galleryFrame = NSRect(x: panelPadding, y: panelPadding, width: panelW - panelPadding * 2, height: galleryThumbHeight)
        let (scrollView, thumbViews) = buildGalleryStrip(frame: galleryFrame, count: galleryCount)
        visualEffect.addSubview(scrollView)
        galleryScrollView = scrollView
        galleryThumbViews = thumbViews

        if galleryCount > 0 {
            updateWindowSelection(selectedWindowIndex)
        }
    }

    private func buildCombinedLayout(selectedAppIndex: Int, galleryCount: Int, selectedWindowIndex: Int) {
        let itemWidth = iconSize + iconPadding
        let panelW = frame.width
        var y: CGFloat = panelPadding

        // Bottom: Gallery thumbnail strip
        let galSelBox = makeSelectionBox()
        visualEffect.addSubview(galSelBox)
        gallerySelectionBox = galSelBox

        let galleryFrame = NSRect(x: panelPadding, y: y, width: panelW - panelPadding * 2, height: galleryThumbHeight)
        let (galScrollView, thumbViews) = buildGalleryStrip(frame: galleryFrame, count: galleryCount)
        visualEffect.addSubview(galScrollView)
        galleryScrollView = galScrollView
        galleryThumbViews = thumbViews
        y += galleryThumbHeight + 12

        // App icon strip above gallery
        let appSelBox = makeSelectionBox()
        visualEffect.addSubview(appSelBox)
        appSelectionBox = appSelBox

        let iconStripY = y + (itemWidth - iconSize) / 2
        let scrollView = NSScrollView(frame: NSRect(x: panelPadding, y: iconStripY, width: panelW - panelPadding * 2, height: iconSize))
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width]

        let clipView = NSClipView(frame: scrollView.bounds)
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        let docWidth = CGFloat(apps.count) * itemWidth
        let docView = NSView(frame: NSRect(x: 0, y: 0, width: max(docWidth, scrollView.bounds.width), height: iconSize))
        scrollView.documentView = docView

        for (index, app) in apps.enumerated() {
            let x = CGFloat(index) * itemWidth + (itemWidth - iconSize) / 2
            let imageView = NSImageView(frame: NSRect(x: x, y: 0, width: iconSize, height: iconSize))
            imageView.image = app.icon
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 12
            docView.addSubview(imageView)
            iconViews.append(imageView)
        }

        visualEffect.addSubview(scrollView)
        iconStripScrollView = scrollView

        updateAppSelection(selectedAppIndex)
        if galleryCount > 0 {
            updateWindowSelection(selectedWindowIndex)
        }
    }

    // MARK: - Helpers

    private func makeSelectionBox() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        box.layer?.cornerRadius = 8
        box.frame = .zero
        return box
    }

    private func buildGalleryStrip(frame: NSRect, count: Int) -> (NSScrollView, [NSImageView]) {
        let scrollView = NSScrollView(frame: frame)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width]

        let clipView = NSClipView(frame: scrollView.bounds)
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        let itemWidth = galleryThumbWidth + galleryThumbPadding
        let totalContentWidth = CGFloat(count) * itemWidth
        let docWidth = max(totalContentWidth, scrollView.bounds.width)
        let docView = NSView(frame: NSRect(x: 0, y: 0, width: docWidth, height: frame.height))
        scrollView.documentView = docView

        // Center thumbnails when they fit within the visible width
        let inset = totalContentWidth < frame.width ? (frame.width - totalContentWidth) / 2 : 0
        galleryLeftInset = inset

        var thumbViews: [NSImageView] = []
        let thumbY = (frame.height - galleryThumbHeight) / 2
        for i in 0..<count {
            let x = inset + CGFloat(i) * itemWidth
            let imageView = NSImageView(frame: NSRect(x: x, y: thumbY, width: galleryThumbWidth, height: galleryThumbHeight))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 6
            imageView.layer?.borderWidth = 1
            imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
            imageView.alphaValue = 0
            docView.addSubview(imageView)
            thumbViews.append(imageView)
        }

        return (scrollView, thumbViews)
    }

    private func galleryScrollViewFrame() -> NSRect? {
        // Returns where the gallery scroll view should be based on current mode
        guard let scrollView = galleryScrollView else {
            // Estimate from mode
            switch mode {
            case .windowsOnly:
                return NSRect(x: panelPadding, y: panelPadding, width: frame.width - panelPadding * 2, height: galleryThumbHeight)
            case .combined:
                return NSRect(x: panelPadding, y: panelPadding, width: frame.width - panelPadding * 2, height: galleryThumbHeight)
            case .appsOnly:
                return nil
            }
        }
        return scrollView.frame
    }
}
