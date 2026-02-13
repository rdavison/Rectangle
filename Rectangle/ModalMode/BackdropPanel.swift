//
//  BackdropPanel.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

/// Full-screen dark frosted-glass backdrop panel.
class BackdropPanel: NSPanel {

    init(screen: NSScreen) {
        let panelRect = screen.visibleFrame
        super.init(contentRect: panelRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)

        isOpaque = false
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        hasShadow = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        collectionBehavior = [.transient, .canJoinAllSpaces]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelRect.size))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.autoresizingMask = [.width, .height]
        contentView = bg
    }
}
