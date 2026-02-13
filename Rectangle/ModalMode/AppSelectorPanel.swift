//
//  AppSelectorPanel.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

class AppSelectorPanel: NSPanel {

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

    private var appNameLabel: NSTextField?

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

        super.init(contentRect: panelRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)

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

        let itemWidth = iconSize + iconPadding

        for (_, view) in iconViews.enumerated() {
            view.alphaValue = 1.0
        }

        if let scrollView = iconStripScrollView, let selBox = appSelectionBox {
            let scrollFrame = scrollView.frame

            // Scroll first so we know the offset
            let targetX = CGFloat(index) * itemWidth - scrollView.bounds.width / 2 + itemWidth / 2
            let maxScroll = max(0, (scrollView.documentView?.frame.width ?? 0) - scrollView.bounds.width)
            let clampedX = max(0, min(targetX, maxScroll))
            scrollView.contentView.scroll(to: NSPoint(x: clampedX, y: 0))

            // Position selection box in parent coordinates, accounting for scroll offset
            let boxX = CGFloat(index) * itemWidth - clampedX

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.035
                selBox.animator().frame = NSRect(
                    x: scrollFrame.origin.x + boxX,
                    y: scrollFrame.origin.y - (itemWidth - iconSize) / 2,
                    width: itemWidth,
                    height: itemWidth
                )
            }
        }

        // Update app name label
        appNameLabel?.stringValue = apps[index].localizedName ?? "Unknown"
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
            // [pad] icon strip [8] app name label(20) [pad]
            let height = panelPadding + iconItemWidth + 8 + 20 + panelPadding
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
        appNameLabel?.removeFromSuperview()
        appNameLabel = nil
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
        var y: CGFloat = panelPadding

        // Selection box (behind icons)
        let selBox = makeSelectionBox()
        visualEffect.addSubview(selBox)
        appSelectionBox = selBox

        // Icon strip (96px icons)
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
        y += itemWidth + 8

        // App name label
        let appName = apps.indices.contains(selectedAppIndex) ? (apps[selectedAppIndex].localizedName ?? "Unknown") : ""
        let label = NSTextField(labelWithString: appName)
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: panelPadding, y: y, width: panelW - panelPadding * 2, height: 20)
        label.lineBreakMode = .byTruncatingTail
        visualEffect.addSubview(label)
        appNameLabel = label

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
