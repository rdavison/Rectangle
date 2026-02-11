//
//  EditModeController.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa
import Carbon

class EditModeController: SelectorNode {

    private var editPanel: EditModePanel?
    private var overlayManager: WindowOverlayManager?
    private var dimWindows: [DimWindow] = []
    private var thumbnails: [WindowThumbnail] = []
    private var selectedGalleryIndex: Int = 0
    var projectIndex: Int = 0
    private var galleryColumns: Int = 4
    private var isSetUp = false

    var panel: NSPanel? { editPanel }

    func activate(context: SelectorContext) {
        // If resuming from a child selector, just show the panel again
        if isSetUp {
            resume()
            return
        }
        isSetUp = true

        let manager = context.projectManager
        manager.validateAllProjects()

        // Validate externally-set projectIndex, default to first user project
        if projectIndex <= 0 || projectIndex >= manager.projects.count {
            projectIndex = max(1, min(1, manager.projects.count - 1))
        }

        // Get all live windows
        let allWindows = manager.orderedLiveWindows()
        thumbnails = WindowScreenshot.captureAll(windows: allWindows, maxSize: CGSize(width: 160, height: 120))

        // Show dim overlay
        for screen in NSScreen.screens {
            let dim = DimWindow(screen: screen)
            dim.orderFrontRegardless()
            dimWindows.append(dim)
        }

        // Show number badges on actual windows
        overlayManager = WindowOverlayManager()
        let projectIDs = projectIndex < manager.projects.count ? manager.projects[projectIndex].windowIDs : []
        overlayManager?.showOverlays(projectWindowIDs: projectIDs, allWindows: allWindows)

        // Show gallery panel
        let panel = EditModePanel(thumbnails: thumbnails, projectWindowIDs: projectIDs, screen: context.screen)
        panel.onHover = { [weak self] index in
            self?.selectIndex(index)
        }
        panel.onClick = { [weak self] index in
            self?.selectIndex(index)
            self?.toggleSelectedWindow()
        }
        editPanel = panel
        panel.orderFrontRegardless()

        selectedGalleryIndex = 0
        updateGallerySelection()
    }

    func deactivate() {
        isSetUp = false
        editPanel?.orderOut(nil)
        editPanel = nil
        overlayManager?.hideOverlays()
        overlayManager = nil
        for dim in dimWindows { dim.orderOut(nil) }
        dimWindows.removeAll()
    }

    /// Hide the panel but keep overlays (dim + badges) while a child selector is active.
    func suspend() {
        editPanel?.orderOut(nil)
    }

    /// Show the panel again after a child selector is dismissed.
    func resume() {
        editPanel?.orderFrontRegardless()
        // Refresh overlays in case windows changed while selector was active
        let manager = ProjectManager.shared
        let projectIDs = projectIndex < manager.projects.count ? manager.projects[projectIndex].windowIDs : []
        overlayManager?.updateBadges(projectWindowIDs: projectIDs)

        // Refresh dim overlays and badges positions
        for dim in dimWindows { dim.orderFrontRegardless() }
    }

    func handleKeyDown(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?) -> KeyEventResult {
        switch keyCode {
        case kVK_LeftArrow:
            moveSelection(by: -1)
            return .handled
        case kVK_RightArrow:
            moveSelection(by: 1)
            return .handled
        case kVK_UpArrow:
            moveSelection(by: -galleryColumns)
            return .handled
        case kVK_DownArrow:
            moveSelection(by: galleryColumns)
            return .handled
        case kVK_Tab:
            if modifiers.contains(.shift) {
                moveSelection(by: -1)
            } else {
                moveSelection(by: 1)
            }
            return .handled
        case kVK_Space:
            // Only plain Space toggles; let Cmd+Shift+Space etc. pass through to shortcuts
            let significantMods = modifiers.intersection([.command, .shift, .control, .option])
            if significantMods.isEmpty {
                toggleSelectedWindow()
                return .handled
            }
            return .unhandled
        default:
            // Badge key press (1-9, 0, a-z) → toggle that window
            if let chars = characters, let char = chars.first {
                let key = String(char).lowercased()
                let toggleKeys = "1234567890abcdefghijklmnopqrstuvwxyz"
                if toggleKeys.contains(key) {
                    toggleWindowByKey(key)
                    return .handled
                }
            }
            return .unhandled
        }
    }

    func handleFlagsChanged(modifiers: CGEventFlags) -> KeyEventResult {
        return .unhandled
    }

    // MARK: - Gallery Navigation

    private func selectIndex(_ index: Int) {
        guard index >= 0, index < thumbnails.count, index != selectedGalleryIndex else { return }
        selectedGalleryIndex = index
        updateGallerySelection()
    }

    private func moveSelection(by delta: Int) {
        guard !thumbnails.isEmpty else { return }
        let newIndex = selectedGalleryIndex + delta
        guard newIndex >= 0, newIndex < thumbnails.count else { return }
        selectedGalleryIndex = newIndex
        updateGallerySelection()
    }

    private func updateGallerySelection() {
        editPanel?.updateSelection(selectedGalleryIndex)

        // Raise selected window so user can see its contents
        guard selectedGalleryIndex < thumbnails.count else { return }
        let thumb = thumbnails[selectedGalleryIndex]

        if let element = AccessibilityElement.getWindowElement(thumb.windowID) {
            element.performAction(kAXRaiseAction as String)
        }
    }

    // MARK: - Toggle

    private func toggleSelectedWindow() {
        guard selectedGalleryIndex < thumbnails.count else { return }
        let windowID = thumbnails[selectedGalleryIndex].windowID
        guard projectIndex > 0 else { return }

        ProjectManager.shared.toggleWindow(windowID, inProjectAt: projectIndex)
        refreshBadges()
    }

    private func toggleWindowByKey(_ key: String) {
        guard let overlayManager = overlayManager else { return }
        guard let windowID = overlayManager.windowIDForKey(key) else { return }
        guard projectIndex > 0 else { return }

        ProjectManager.shared.toggleWindow(windowID, inProjectAt: projectIndex)
        refreshBadges()
    }

    private func refreshBadges() {
        let manager = ProjectManager.shared
        let projectIDs = projectIndex < manager.projects.count ? manager.projects[projectIndex].windowIDs : []
        overlayManager?.updateBadges(projectWindowIDs: projectIDs)
        editPanel?.updateProjectMembership(projectIDs)
    }
}

// MARK: - EditModePanel

private class EditModePanel: NSPanel {

    private var thumbViews: [GalleryCell] = []
    private var thumbnails: [WindowThumbnail]
    private var projectWindowIDs: Set<CGWindowID>
    private let columns = 4
    private let cellWidth: CGFloat = 180
    private let cellHeight: CGFloat = 150
    private var scrollView: NSScrollView!

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    init(thumbnails: [WindowThumbnail], projectWindowIDs: Set<CGWindowID>, screen: NSScreen) {
        self.thumbnails = thumbnails
        self.projectWindowIDs = projectWindowIDs

        let rows = max(1, Int(ceil(Double(thumbnails.count) / Double(columns))))
        let width = CGFloat(columns) * cellWidth + 40
        let height = min(CGFloat(rows) * cellHeight + 60, screen.visibleFrame.height * 0.8)

        let panelRect = NSRect(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.midY - height / 2,
            width: width,
            height: height
        )

        super.init(contentRect: panelRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        level = .floating
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

        // Title
        let titleLabel = NSTextField(labelWithString: "Edit Mode — Space/click to toggle, arrows/tab to navigate")
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        titleLabel.frame = NSRect(x: 20, y: panelRect.height - 30, width: panelRect.width - 40, height: 20)
        visualEffect.addSubview(titleLabel)

        // Scroll view for gallery
        let sv = NSScrollView(frame: NSRect(x: 10, y: 10, width: panelRect.width - 20, height: panelRect.height - 45))
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.autoresizingMask = [.width, .height]
        scrollView = sv

        let docHeight = CGFloat(rows) * cellHeight
        let docView = FlippedView(frame: NSRect(x: 0, y: 0, width: sv.bounds.width, height: max(docHeight, sv.bounds.height)))
        sv.documentView = docView

        let badgeKeys = Array("1234567890abcdefghijklmnopqrstuvwxyz")

        for (index, thumb) in thumbnails.enumerated() {
            let col = index % columns
            let row = index / columns
            let x = CGFloat(col) * cellWidth + 10
            let y = CGFloat(row) * cellHeight

            let isInProject = projectWindowIDs.contains(thumb.windowID)
            let badgeKey = index < badgeKeys.count ? String(badgeKeys[index]) : ""
            let cell = GalleryCell(
                frame: NSRect(x: x, y: y, width: cellWidth - 10, height: cellHeight - 10),
                thumbnail: thumb,
                badgeKey: badgeKey,
                isInProject: isInProject
            )
            docView.addSubview(cell)
            thumbViews.append(cell)
        }

        visualEffect.addSubview(sv)
        contentView = visualEffect

        // Tracking area for mouse hover
        let trackingArea = NSTrackingArea(
            rect: visualEffect.bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        visualEffect.addTrackingArea(trackingArea)
    }

    func updateSelection(_ index: Int) {
        for (i, cell) in thumbViews.enumerated() {
            cell.isSelected = (i == index)
        }
        // Scroll to make the selected cell visible
        if index >= 0, index < thumbViews.count {
            let cellFrame = thumbViews[index].frame
            scrollView.contentView.scrollToVisible(cellFrame)
        }
    }

    func updateProjectMembership(_ projectIDs: Set<CGWindowID>) {
        self.projectWindowIDs = projectIDs
        for cell in thumbViews {
            cell.isInProject = projectIDs.contains(cell.windowID)
        }
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Mouse Events

    override func mouseMoved(with event: NSEvent) {
        if let index = cellIndex(for: event) {
            onHover?(index)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = cellIndex(for: event) {
            onClick?(index)
        }
    }

    private func cellIndex(for event: NSEvent) -> Int? {
        guard let contentView = contentView else { return nil }
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)

        // Check if point is within the scroll view's frame
        let svFrame = scrollView.frame
        guard svFrame.contains(pointInContent) else { return nil }

        // Convert to document view coordinates
        let pointInScroll = scrollView.convert(pointInContent, from: contentView)
        let scrollOffset = scrollView.contentView.bounds.origin
        // Document view is flipped, so y increases downward
        let pointInDoc = NSPoint(x: pointInScroll.x + scrollOffset.x, y: scrollOffset.y + (scrollView.bounds.height - pointInScroll.y))

        for (index, cell) in thumbViews.enumerated() {
            if cell.frame.contains(pointInDoc) {
                return index
            }
        }
        return nil
    }
}

// MARK: - GalleryCell

private class GalleryCell: NSView {
    let windowID: CGWindowID
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var isInProject: Bool {
        didSet { needsDisplay = true }
    }
    private let thumbnail: WindowThumbnail
    private let badgeKey: String

    init(frame: NSRect, thumbnail: WindowThumbnail, badgeKey: String, isInProject: Bool) {
        self.windowID = thumbnail.windowID
        self.thumbnail = thumbnail
        self.badgeKey = badgeKey
        self.isInProject = isInProject
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let thumbRect = NSRect(x: 4, y: 28, width: bounds.width - 8, height: bounds.height - 36)

        // Selection highlight
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
            let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            bgPath.fill()
        }

        // Thumbnail image
        thumbnail.image.draw(in: thumbRect,
                             from: NSRect(origin: .zero, size: thumbnail.image.size),
                             operation: .sourceOver,
                             fraction: isInProject ? 1.0 : 0.5)

        // Border
        let borderColor = isInProject ? NSColor.controlAccentColor.withAlphaComponent(0.8) : NSColor.white.withAlphaComponent(0.2)
        borderColor.setStroke()
        let borderPath = NSBezierPath(roundedRect: thumbRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        borderPath.lineWidth = isSelected ? 2 : 1
        borderPath.stroke()

        // App icon (bottom left)
        if let icon = thumbnail.appIcon {
            let iconSize: CGFloat = 16
            let iconRect = NSRect(x: 8, y: 6, width: iconSize, height: iconSize)
            icon.draw(in: iconRect, from: NSRect(origin: .zero, size: icon.size), operation: .sourceOver, fraction: 1.0)
        }

        // App name label (bottom, next to icon)
        let labelX: CGFloat = thumbnail.appIcon != nil ? 28 : 8
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7)
        ]
        let label = (thumbnail.title ?? thumbnail.appName ?? "") as NSString
        let labelRect = NSRect(x: labelX, y: 6, width: bounds.width - labelX - 30, height: 16)
        label.draw(in: labelRect, withAttributes: labelAttrs)

        // Badge key (top-left of thumbnail)
        if !badgeKey.isEmpty {
            let badgeSize: CGFloat = 18
            let badgeRect = NSRect(x: thumbRect.minX + 4, y: thumbRect.maxY - badgeSize - 4, width: badgeSize, height: badgeSize)
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)

            if isInProject {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            } else {
                NSColor.black.withAlphaComponent(0.7).setFill()
            }
            badgePath.fill()

            let keyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: NSColor.white
            ]
            let keyStr = badgeKey as NSString
            let keySize = keyStr.size(withAttributes: keyAttrs)
            let keyRect = NSRect(
                x: badgeRect.midX - keySize.width / 2,
                y: badgeRect.midY - keySize.height / 2,
                width: keySize.width,
                height: keySize.height
            )
            keyStr.draw(in: keyRect, withAttributes: keyAttrs)
        }

        // In-project indicator (bottom right)
        if isInProject {
            let indicatorSize: CGFloat = 8
            let indicatorRect = NSRect(x: bounds.width - indicatorSize - 8, y: 10, width: indicatorSize, height: indicatorSize)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: indicatorRect).fill()
        }
    }
}

// MARK: - FlippedView

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
