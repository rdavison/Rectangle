//
//  WindowOverlayManager.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

class WindowOverlayManager {

    private var dimWindows: [DimWindow] = []
    private var perWindowDims: [PerWindowDimOverlay] = []
    private var badgeWindows: [NumberBadgeWindow] = []
    private var keyToWindowID: [String: CGWindowID] = [:]
    private var hoverTimer: Timer?
    private var hoveredWindowID: CGWindowID?
    private var allWindowsRef: [WindowInfo] = []

    static let badgeKeys = Array("1234567890abcdefghijklmnopqrstuvwxyz")

    func showOverlays(projectWindowIDs: Set<CGWindowID>, allWindows: [WindowInfo], perWindowDim: Bool = false) {
        hideOverlays()
        allWindowsRef = allWindows

        if perWindowDim {
            // Per-window dim overlays (skip project member windows)
            for windowInfo in allWindows {
                if !projectWindowIDs.contains(windowInfo.id) {
                    let overlay = PerWindowDimOverlay(windowInfo: windowInfo)
                    overlay.orderFrontRegardless()
                    perWindowDims.append(overlay)
                }
            }
            startHoverTracking()
        } else {
            // Full-screen dim
            for screen in NSScreen.screens {
                let dim = DimWindow(screen: screen)
                dim.orderFrontRegardless()
                dimWindows.append(dim)
            }
        }

        // Number badge per visible window
        keyToWindowID.removeAll()
        for (index, windowInfo) in allWindows.enumerated() {
            guard index < WindowOverlayManager.badgeKeys.count else { break }
            let key = String(WindowOverlayManager.badgeKeys[index])
            keyToWindowID[key] = windowInfo.id
            let isInProject = projectWindowIDs.contains(windowInfo.id)
            let badge = NumberBadgeWindow(key: key, windowInfo: windowInfo, isInProject: isInProject)
            badge.orderFrontRegardless()
            badgeWindows.append(badge)
        }
    }

    func updateBadges(projectWindowIDs: Set<CGWindowID>) {
        for badge in badgeWindows {
            let isInProject = projectWindowIDs.contains(badge.windowID)
            badge.updateState(isInProject: isInProject)
        }
        // Update per-window dims: hide for project members, show for non-members
        for overlay in perWindowDims {
            if projectWindowIDs.contains(overlay.windowID) {
                overlay.setDimmed(false, animated: true)
            } else if overlay.windowID != hoveredWindowID {
                overlay.setDimmed(true, animated: true)
            }
        }
    }

    func hideOverlays() {
        stopHoverTracking()
        for dim in dimWindows { dim.orderOut(nil) }
        dimWindows.removeAll()
        for overlay in perWindowDims { overlay.orderOut(nil) }
        perWindowDims.removeAll()
        for badge in badgeWindows { badge.orderOut(nil) }
        badgeWindows.removeAll()
        keyToWindowID.removeAll()
        allWindowsRef.removeAll()
        hoveredWindowID = nil
    }

    func windowIDForKey(_ key: String) -> CGWindowID? {
        return keyToWindowID[key.lowercased()]
    }

    func windowIDAtPoint(_ point: CGPoint, allWindows: [WindowInfo]) -> CGWindowID? {
        // point is in AppKit screen coords (origin bottom-left)
        // WindowInfo frames are in CG screen coords (origin top-left)
        let cgPoint = point.screenFlipped
        for windowInfo in allWindows {
            if windowInfo.frame.contains(cgPoint) {
                return windowInfo.id
            }
        }
        return nil
    }

    // MARK: - Hover Tracking

    private func startHoverTracking() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateHoverState()
        }
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func updateHoverState() {
        let mouseLocation = NSEvent.mouseLocation
        let cgPoint = mouseLocation.screenFlipped

        // Find topmost window under cursor (allWindowsRef is z-ordered front-to-back)
        var newHoveredID: CGWindowID? = nil
        for windowInfo in allWindowsRef {
            if windowInfo.frame.contains(cgPoint) {
                // Only track hover for dimmed (non-project) windows
                if perWindowDims.contains(where: { $0.windowID == windowInfo.id }) {
                    newHoveredID = windowInfo.id
                }
                break
            }
        }

        if newHoveredID != hoveredWindowID {
            // Re-dim previous
            if let prevID = hoveredWindowID {
                perWindowDims.first { $0.windowID == prevID }?.setDimmed(true, animated: true)
            }
            // Undim new
            if let newID = newHoveredID {
                perWindowDims.first { $0.windowID == newID }?.setDimmed(false, animated: true)
            }
            hoveredWindowID = newHoveredID
        }
    }
}

// MARK: - Per-Window Dim Overlay

class PerWindowDimOverlay: NSPanel {
    let windowID: CGWindowID

    init(windowInfo: WindowInfo) {
        self.windowID = windowInfo.id
        let appKitFrame = windowInfo.frame.screenFlipped

        super.init(contentRect: appKitFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        backgroundColor = NSColor.black.withAlphaComponent(0.15)
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .canJoinAllSpaces]
    }

    func setDimmed(_ dimmed: Bool, animated: Bool) {
        let targetAlpha: CGFloat = dimmed ? 1.0 : 0.0
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = targetAlpha
            }
        } else {
            alphaValue = targetAlpha
        }
    }
}

// MARK: - Dim Window

class DimWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        backgroundColor = NSColor.black.withAlphaComponent(0.4)
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .canJoinAllSpaces]
    }
}

// MARK: - Number Badge Window

class NumberBadgeWindow: NSPanel {

    let windowID: CGWindowID
    private let badgeView: NumberBadgeView

    init(key: String, windowInfo: WindowInfo, isInProject: Bool) {
        self.windowID = windowInfo.id
        let badgeSize: CGFloat = 28
        // Position at top-left of window frame, converted to AppKit coords
        let cgFrame = windowInfo.frame
        let appKitFrame = cgFrame.screenFlipped
        let badgeFrame = NSRect(
            x: appKitFrame.origin.x + 8,
            y: appKitFrame.origin.y + appKitFrame.height - badgeSize - 8,
            width: badgeSize,
            height: badgeSize
        )

        badgeView = NumberBadgeView(key: key, isInProject: isInProject)

        super.init(contentRect: badgeFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        hasShadow = true
        backgroundColor = .clear
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .canJoinAllSpaces]

        badgeView.frame = NSRect(x: 0, y: 0, width: badgeSize, height: badgeSize)
        contentView = badgeView
    }

    func updateState(isInProject: Bool) {
        badgeView.isInProject = isInProject
        badgeView.needsDisplay = true
    }
}

// MARK: - Number Badge View

private class NumberBadgeView: NSView {
    let key: String
    var isInProject: Bool

    init(key: String, isInProject: Bool) {
        self.key = key
        self.isInProject = isInProject
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if isInProject {
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        } else {
            NSColor.black.withAlphaComponent(0.7).setFill()
        }
        path.fill()

        NSColor.white.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.white
        ]
        let str = key as NSString
        let size = str.size(withAttributes: attrs)
        let textRect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        str.draw(in: textRect, withAttributes: attrs)
    }
}
