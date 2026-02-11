//
//  WindowSelectorWindow.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa
import Carbon

class WindowSelectorWindow: SelectorNode {

    private var selectorPanel: WindowSelectorPanel?
    private var thumbnails: [WindowThumbnail] = []
    private var selectedIndex: Int = 0
    private var previousWindowOrder: [CGWindowID] = []
    private var refreshTimer: Timer?

    /// Set before activation to show windows for a specific app (e.g. from app selector).
    /// If nil, defaults to the frontmost app.
    var targetPID: pid_t?

    var panel: NSPanel? { selectorPanel }

    func activate(context: SelectorContext) {
        let pid = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let myPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = CGWindowLevelForKey(.normalWindow)

        let allWindows = WindowUtil.getWindowList().filter {
            $0.level == normalLevel && $0.pid != myPID && $0.pid == pid
        }

        previousWindowOrder = allWindows.map { $0.id }

        // Build thumbnails with placeholder images so the panel shows instantly
        let apps = NSWorkspace.shared.runningApplications.reduce(into: [pid_t: NSRunningApplication]()) {
            $0[$1.processIdentifier] = $1
        }
        let thumbSize = CGSize(width: 160, height: 120)
        let placeholder = NSImage(size: thumbSize)
        thumbnails = allWindows.map { windowInfo in
            let app = apps[windowInfo.pid]
            return WindowThumbnail(
                windowID: windowInfo.id,
                windowInfo: windowInfo,
                image: placeholder,
                title: windowInfo.processName,
                appName: app?.localizedName,
                appIcon: app?.icon
            )
        }
        selectedIndex = 0

        let panel = WindowSelectorPanel(thumbnails: thumbnails, selectedIndex: selectedIndex, screen: context.screen)
        panel.onHover = { [weak self] index in
            self?.selectIndex(index)
        }
        panel.onClickConfirm = { [weak self] in
            self?.confirmSelection()
            ModalModeManager.shared.deactivate(restoreLayout: false)
        }
        selectorPanel = panel
        panel.makeKeyAndOrderFront(nil)

        // Capture real thumbnails async
        let windowIDs = thumbnails.map { $0.windowID }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for (i, windowID) in windowIDs.enumerated() {
                if let image = WindowScreenshot.capture(windowID: windowID, maxSize: thumbSize) {
                    DispatchQueue.main.async {
                        self?.selectorPanel?.updateThumbnailImage(image, at: i)
                    }
                }
            }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshThumbnails()
        }
    }

    func deactivate() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        selectorPanel?.orderOut(nil)
        selectorPanel = nil
    }

    func handleKeyDown(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?) -> KeyEventResult {
        switch keyCode {
        case kVK_Tab, kVK_RightArrow, kVK_ANSI_Grave:
            navigateNext()
            return .handled
        case kVK_LeftArrow:
            navigatePrevious()
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

    // MARK: - Navigation

    func navigateNext() {
        guard !thumbnails.isEmpty else { return }
        selectIndex((selectedIndex + 1) % thumbnails.count)
    }

    func navigatePrevious() {
        guard !thumbnails.isEmpty else { return }
        selectIndex((selectedIndex - 1 + thumbnails.count) % thumbnails.count)
    }

    private func selectIndex(_ index: Int) {
        guard index >= 0, index < thumbnails.count, index != selectedIndex else { return }
        selectedIndex = index
        selectorPanel?.updateSelection(selectedIndex)
        previewWindow(at: selectedIndex)
    }

    private func previewWindow(at index: Int) {
        guard index >= 0, index < thumbnails.count else { return }
        let windowID = thumbnails[index].windowID
        if let element = AccessibilityElement.getWindowElement(windowID) {
            element.performAction(kAXRaiseAction as String)
        }
    }

    private func refreshThumbnails() {
        let thumbsCopy = thumbnails
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for (i, thumb) in thumbsCopy.enumerated() {
                if let newImage = WindowScreenshot.capture(windowID: thumb.windowID, maxSize: CGSize(width: 160, height: 120)) {
                    DispatchQueue.main.async {
                        self?.selectorPanel?.updateThumbnailImage(newImage, at: i)
                    }
                }
            }
        }
    }

    private func confirmSelection() {
        guard selectedIndex >= 0, selectedIndex < thumbnails.count else { return }
        let windowID = thumbnails[selectedIndex].windowID
        if let element = AccessibilityElement.getWindowElement(windowID) {
            element.performAction(kAXRaiseAction as String)
        }
        let pid = thumbnails[selectedIndex].windowInfo.pid
        NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
    }
}

// MARK: - WindowSelectorPanel

private class WindowSelectorPanel: NSPanel {

    override var canBecomeKey: Bool { true }

    private let thumbnailWidth: CGFloat = 160
    private let thumbnailHeight: CGFloat = 120
    private let itemPadding: CGFloat = 12
    private let panelPadding: CGFloat = 16
    private var thumbViews: [NSImageView] = []
    private var labelView: NSTextField
    private var selectionBox: NSView
    private var thumbnails: [WindowThumbnail]
    private var thumbStripScrollView: NSScrollView!

    var onHover: ((Int) -> Void)?
    var onClickConfirm: (() -> Void)?

    init(thumbnails: [WindowThumbnail], selectedIndex: Int, screen: NSScreen) {
        self.thumbnails = thumbnails

        labelView = NSTextField(labelWithString: "")
        labelView.font = NSFont.systemFont(ofSize: 12)
        labelView.textColor = .white
        labelView.alignment = .center

        selectionBox = NSView()
        selectionBox.wantsLayer = true
        selectionBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        selectionBox.layer?.cornerRadius = 8

        let itemWidth = thumbnailWidth + itemPadding
        let totalWidth = CGFloat(thumbnails.count) * itemWidth + panelPadding * 2
        let height: CGFloat = thumbnailHeight + 40 + panelPadding * 2

        let panelWidth = min(totalWidth, screen.visibleFrame.width - 40)
        let panelRect = NSRect(
            x: screen.visibleFrame.midX - panelWidth / 2,
            y: screen.visibleFrame.midY - height / 2,
            width: panelWidth,
            height: height
        )

        super.init(contentRect: panelRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        level = .popUpMenu
        hasShadow = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        acceptsMouseMovedEvents = true
        collectionBehavior = [.transient, .canJoinAllSpaces]

        let visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelRect.size))
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.autoresizingMask = [.width, .height]

        selectionBox.frame = .zero
        visualEffect.addSubview(selectionBox)

        // Thumbnail strip
        let scrollView = NSScrollView(frame: NSRect(
            x: panelPadding,
            y: 30 + panelPadding,
            width: panelRect.width - panelPadding * 2,
            height: thumbnailHeight
        ))
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width]
        thumbStripScrollView = scrollView

        let clipView = NSClipView(frame: scrollView.bounds)
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        let docWidth = CGFloat(thumbnails.count) * itemWidth
        let docView = NSView(frame: NSRect(x: 0, y: 0, width: max(docWidth, scrollView.bounds.width), height: thumbnailHeight))
        scrollView.documentView = docView

        for (index, thumb) in thumbnails.enumerated() {
            let x = CGFloat(index) * itemWidth
            let imageView = NSImageView(frame: NSRect(x: x, y: 0, width: thumbnailWidth, height: thumbnailHeight))
            imageView.image = thumb.image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 6
            imageView.layer?.borderWidth = 1
            imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
            docView.addSubview(imageView)
            thumbViews.append(imageView)
        }

        visualEffect.addSubview(scrollView)

        // Label
        labelView.frame = NSRect(x: panelPadding, y: panelPadding, width: panelRect.width - panelPadding * 2, height: 20)
        labelView.autoresizingMask = [.width]
        visualEffect.addSubview(labelView)

        contentView = visualEffect

        // Tracking area for mouse moved events
        let trackingArea = NSTrackingArea(
            rect: visualEffect.bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        visualEffect.addTrackingArea(trackingArea)

        updateSelection(selectedIndex)
    }

    override func mouseMoved(with event: NSEvent) {
        if let index = thumbIndex(for: event) {
            onHover?(index)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if thumbIndex(for: event) != nil {
            onClickConfirm?()
        }
    }

    private func thumbIndex(for event: NSEvent) -> Int? {
        guard let contentView = contentView else { return nil }
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)

        let scrollFrame = thumbStripScrollView.frame
        guard scrollFrame.contains(pointInContent) else { return nil }

        let pointInScroll = thumbStripScrollView.convert(pointInContent, from: contentView)
        let scrollOffset = thumbStripScrollView.contentView.bounds.origin
        let pointInDoc = NSPoint(x: pointInScroll.x + scrollOffset.x, y: pointInScroll.y + scrollOffset.y)

        let itemWidth = thumbnailWidth + itemPadding
        let index = Int(pointInDoc.x / itemWidth)
        guard index >= 0, index < thumbnails.count else { return nil }
        return index
    }

    func updateSelection(_ index: Int) {
        guard index >= 0, index < thumbnails.count else { return }

        let thumb = thumbnails[index]
        labelView.stringValue = thumb.title ?? thumb.appName ?? ""

        for (i, view) in thumbViews.enumerated() {
            view.alphaValue = (i == index) ? 1.0 : 0.5
            view.layer?.borderColor = (i == index)
                ? NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
                : NSColor.white.withAlphaComponent(0.2).cgColor
            view.layer?.borderWidth = (i == index) ? 2.0 : 1.0
        }

        let itemWidth = thumbnailWidth + itemPadding
        let boxX = panelPadding + CGFloat(index) * itemWidth - itemPadding / 2
        let boxY: CGFloat = 30 + panelPadding - 4
        let boxWidth = thumbnailWidth + itemPadding
        let boxHeight = thumbnailHeight + 8

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.035
            selectionBox.animator().frame = NSRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
        }

        if let scrollView = thumbStripScrollView {
            let targetX = CGFloat(index) * itemWidth - scrollView.bounds.width / 2 + itemWidth / 2
            let maxScroll = max(0, (scrollView.documentView?.frame.width ?? 0) - scrollView.bounds.width)
            let clampedX = max(0, min(targetX, maxScroll))
            scrollView.contentView.scroll(to: NSPoint(x: clampedX, y: 0))
        }
    }

    func updateThumbnailImage(_ image: NSImage, at index: Int) {
        guard index >= 0, index < thumbViews.count else { return }
        thumbViews[index].image = image
    }
}
