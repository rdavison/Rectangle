//
//  GroupSelectorWindow.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa
import Carbon

class GroupSelectorWindow: SelectorNode {

    enum Mode {
        case app, project
    }

    private(set) var mode: Mode = .app
    private var appSelector: AppSelectorWindow
    private var projectSelector: ProjectSelectorNode
    private var context: SelectorContext?
    private var modeIndicator: ModeIndicatorPanel?

    // Ctrl "tap" detection: toggle only on Ctrl release if no key was pressed while held
    private var ctrlDown = false
    private var keyPressedDuringCtrl = false

    var panel: NSPanel? {
        switch mode {
        case .app: return appSelector.panel
        case .project: return projectSelector.panel
        }
    }

    var selectedApp: NSRunningApplication? {
        return appSelector.selectedApp
    }

    /// Set before pushing this node to control the initial HUD layout.
    var initialHUDMode: AppSelectorWindow.HUDMode = .appsOnly

    /// Set before pushing this node to start directly in project mode.
    var initialGroupMode: Mode = .app

    init() {
        appSelector = AppSelectorWindow()
        projectSelector = ProjectSelectorNode()
    }

    func activate(context: SelectorContext) {
        self.context = context

        if initialGroupMode == .project {
            mode = .project
            // Pre-arm Ctrl tap state so the initial Ctrl release doesn't toggle back
            ctrlDown = true
            keyPressedDuringCtrl = true
            projectSelector.activate(context: context)
        } else {
            mode = .app
            appSelector.initialHUDMode = initialHUDMode
            appSelector.activate(context: context)
        }
        showModeIndicator(on: context.screen)
    }

    func deactivate() {
        switch mode {
        case .app:
            appSelector.deactivate(animated: true)
        case .project:
            projectSelector.deactivate()
        }
        hideModeIndicator(animated: true)
        context = nil
    }

    func handleKeyDown(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?) -> KeyEventResult {
        if ctrlDown {
            keyPressedDuringCtrl = true
        }
        switch mode {
        case .app:
            return appSelector.handleKeyDown(keyCode: keyCode, modifiers: modifiers, characters: characters)
        case .project:
            return projectSelector.handleKeyDown(keyCode: keyCode, modifiers: modifiers, characters: characters)
        }
    }

    private func debugLog(_ msg: String) {
        let entry = "\(Date()): [GroupSelector] \(msg)\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/rectangle_debug.log") {
            handle.seekToEndOfFile()
            handle.write(entry.data(using: .utf8)!)
            handle.closeFile()
        }
    }

    func handleFlagsChanged(modifiers: CGEventFlags) -> KeyEventResult {
        debugLog("flagsChanged: ctrl=\(modifiers.contains(.maskControl)) cmd=\(modifiers.contains(.maskCommand)) ctrlDown=\(ctrlDown) keyPressed=\(keyPressedDuringCtrl) mode=\(mode)")
        // Ctrl "tap" detection: toggle only on Ctrl release if no other key was pressed
        if modifiers.contains(.maskControl) {
            if !ctrlDown {
                ctrlDown = true
                keyPressedDuringCtrl = false
                debugLog("Ctrl pressed down, starting tap detection")
            }
            // Don't toggle yet — wait for release
        } else if ctrlDown {
            // Ctrl was just released
            let wasTap = !keyPressedDuringCtrl
            ctrlDown = false
            keyPressedDuringCtrl = false
            debugLog("Ctrl released, wasTap=\(wasTap)")
            if wasTap {
                toggleMode()
                return .handled
            }
        }

        switch mode {
        case .app:
            // Cmd release in app mode → confirm
            return appSelector.handleFlagsChanged(modifiers: modifiers)
        case .project:
            // Cmd release in project mode → do NOT dismiss (sticky)
            if !modifiers.contains(.maskCommand) {
                // Just ignore the Cmd release — project mode is sticky
                return .handled
            }
            return projectSelector.handleFlagsChanged(modifiers: modifiers)
        }
    }

    // MARK: - Navigation (forwarded from manager for Cmd+Tab)

    func navigateNext() {
        switch mode {
        case .app:
            appSelector.navigateNextApp()
        case .project:
            projectSelector.navigateNext()
        }
    }

    func navigatePrevious() {
        switch mode {
        case .app:
            appSelector.navigatePreviousApp()
        case .project:
            projectSelector.navigatePrevious()
        }
    }

    // MARK: - Cmd+` Gallery

    func handleCmdGrave(reverse: Bool = false) {
        switch mode {
        case .app:
            switch appSelector.hudMode {
            case .appsOnly:
                appSelector.expandGallery()
            case .windowsOnly, .combined:
                if reverse {
                    appSelector.cycleGalleryPrevious()
                } else {
                    appSelector.cycleGalleryNext()
                }
            }
        case .project:
            break // no-op for now
        }
    }

    // MARK: - Cmd+Tab Handling (forwarded from manager)

    func handleCmdTab(reverse: Bool) {
        switch mode {
        case .app:
            if appSelector.hudMode == .windowsOnly {
                appSelector.expandAppStrip()
                if reverse {
                    appSelector.navigatePreviousApp()
                } else {
                    appSelector.navigateNextApp()
                }
            } else {
                if reverse {
                    navigatePrevious()
                } else {
                    navigateNext()
                }
            }
        case .project:
            if reverse {
                navigatePrevious()
            } else {
                navigateNext()
            }
        }
    }

    // MARK: - Mode Toggle

    private func toggleMode() {
        guard let context = context else { return }

        switch mode {
        case .app:
            appSelector.deactivate()
            mode = .project
            projectSelector.activate(context: context)
        case .project:
            projectSelector.deactivate()
            mode = .app
            appSelector.activate(context: context)
        }
        updateModeIndicator()
    }

    // MARK: - Mode Indicator Pill

    private func showModeIndicator(on screen: NSScreen) {
        let indicator = ModeIndicatorPanel(screen: screen)
        modeIndicator = indicator
        updateModeIndicator()
        indicator.orderFrontRegardless()
    }

    private func hideModeIndicator(animated: Bool = false) {
        guard let indicator = modeIndicator else { return }
        modeIndicator = nil
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                indicator.animator().alphaValue = 0
            } completionHandler: {
                indicator.orderOut(nil)
            }
        } else {
            indicator.orderOut(nil)
        }
    }

    private func updateModeIndicator() {
        let text = mode == .app ? "Apps" : "Projects"
        modeIndicator?.updateText(text)
    }
}

// MARK: - Mode Indicator Panel

private class ModeIndicatorPanel: NSPanel {
    private let label: NSTextField

    init(screen: NSScreen) {
        label = NSTextField(labelWithString: "Apps")
        label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let width: CGFloat = 60
        let height: CGFloat = 22
        let panelRect = NSRect(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.midY + 80,
            width: width,
            height: height
        )

        super.init(contentRect: panelRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        level = .popUpMenu
        hasShadow = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        collectionBehavior = [.transient, .canJoinAllSpaces]
        ignoresMouseEvents = true

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelRect.size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = height / 2

        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])

        contentView = bg
    }

    func updateText(_ text: String) {
        label.stringValue = text
    }
}
