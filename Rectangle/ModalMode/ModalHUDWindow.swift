//
//  ModalHUDWindow.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa
import Carbon

class ModalHUDWindow: NSPanel {

    let gridView = ModalGridView()
    private let escLabel: NSTextField

    private var targetScreen: NSScreen?

    init() {
        escLabel = NSTextField(labelWithString: "Esc to cancel")

        let initialRect = NSRect(x: 0, y: 0, width: 320, height: 280)
        super.init(contentRect: initialRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        title = "Rectangle Modal"
        isOpaque = false
        level = .floating
        hasShadow = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        alphaValue = 0
        acceptsMouseMovedEvents = true

        collectionBehavior = [.transient, .canJoinAllSpaces]
        styleMask.insert(.fullSizeContentView)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12

        // Grid view
        gridView.translatesAutoresizingMaskIntoConstraints = false

        // Title
        let titleLabel = NSTextField(labelWithString: "Rectangle")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Esc hint
        escLabel.font = NSFont.systemFont(ofSize: 10)
        escLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        escLabel.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(titleLabel)
        visualEffect.addSubview(gridView)
        visualEffect.addSubview(escLabel)

        NSLayoutConstraint.activate([
            // Title
            titleLabel.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),

            // Grid
            gridView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            gridView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),
            gridView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -16),
            gridView.bottomAnchor.constraint(equalTo: escLabel.topAnchor, constant: -8),

            // Esc hint
            escLabel.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),
            escLabel.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -10),
        ])

        contentView = visualEffect
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Let shortcuts pass through — grid interaction is mouse-based
        super.keyDown(with: event)
    }

    // MARK: - Show / Hide

    func showAtMouseScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first!
        targetScreen = screen

        let width: CGFloat = 320
        let height: CGFloat = 280

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - width / 2
        let y = screenFrame.midY - height / 2
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)

        makeKeyAndOrderFront(nil)
        animator().alphaValue = 1.0
    }

    func getTargetScreen() -> NSScreen {
        return targetScreen ?? NSScreen.main ?? NSScreen.screens.first!
    }

    override func orderOut(_ sender: Any?) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 0.0
        } completionHandler: {
            super.orderOut(nil)
        }
    }
}

// MARK: - GridHUDNode

class GridHUDNode: SelectorNode {
    let hudWindow = ModalHUDWindow()

    var panel: NSPanel? { hudWindow }

    func activate(context: SelectorContext) {
        hudWindow.gridView.onGridSelection = { [weak self] startCol, startRow, endCol, endRow in
            _ = self // prevent unused capture warning
            ModalModeManager.shared.handleGridSelection(startCol: startCol, startRow: startRow, endCol: endCol, endRow: endRow)
        }
        hudWindow.showAtMouseScreen()
    }

    func deactivate() {
        hudWindow.gridView.onGridSelection = nil
        hudWindow.orderOut(nil)
    }

    func handleKeyDown(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?) -> KeyEventResult {
        // Grid is mouse-driven; let keyboard shortcuts pass through
        return .unhandled
    }

    func handleFlagsChanged(modifiers: CGEventFlags) -> KeyEventResult {
        return .unhandled
    }
}
