//
//  ModalModeManager.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa
import MASShortcut
import Carbon

// CGEventTap callback — must be a free function for @convention(c)
private func selectorEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passRetained(event) }
    let manager = Unmanaged<ModalModeManager>.fromOpaque(refcon).takeUnretainedValue()
    return manager.handleSelectorEvent(proxy: proxy, type: type, event: event)
}

class ModalModeManager {
    static let shared = ModalModeManager()
    static let activateDefaultsKey = "modalModeActivate"

    enum State {
        case inactive, active
    }

    private(set) var state: State = .inactive
    private var shortcutManager: ShortcutManager?
    private var escapeMonitor: PassiveEventMonitor?
    private var timeoutTimer: Timer?
    private var actionObserver: NSObjectProtocol?
    private(set) var targetWindowElement: AccessibilityElement?

    // Node stack — topmost node receives events first
    private(set) var nodeStack: [SelectorNode] = []

    // CGEventTap for intercepting Cmd+Tab, Cmd+`, flags, and forwarding keys
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    // Cmd+Ctrl project selector trigger
    private var cmdCtrlTriggered = false

    private init() {}

    func configure(shortcutManager: ShortcutManager) {
        self.shortcutManager = shortcutManager
        debugLog("configure called, modalMode.userEnabled=\(Defaults.modalMode.userEnabled)")
    }

    // MARK: - Activation Shortcut

    static func initActivateShortcut() {
        if UserDefaults.standard.dictionary(forKey: activateDefaultsKey) == nil {
            guard let dictTransformer = ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName)) else { return }

            let shortcut = MASShortcut(keyCode: kVK_Space,
                                       modifierFlags: [.control, .option])
            let shortcutDict = dictTransformer.reverseTransformedValue(shortcut)
            UserDefaults.standard.set(shortcutDict, forKey: activateDefaultsKey)
        }
    }

    static func registerActivateShortcut() {
        MASShortcutBinder.shared()?.bindShortcut(withDefaultsKey: activateDefaultsKey, toAction: {
            if ModalModeManager.shared.state == .active && ModalModeManager.shared.topmostNode is GridHUDNode {
                ModalModeManager.shared.deactivate()
            } else if ModalModeManager.shared.state == .inactive {
                ModalModeManager.shared.activate()
            }
        })
    }

    static func unregisterActivateShortcut() {
        MASShortcutBinder.shared()?.breakBinding(withDefaultsKey: activateDefaultsKey)
    }

    static func getActivateKeyDisplay() -> (String?, NSEvent.ModifierFlags)? {
        guard
            let shortcutDict = UserDefaults.standard.dictionary(forKey: activateDefaultsKey),
            let dictTransformer = ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName)),
            let shortcut = dictTransformer.transformedValue(shortcutDict) as? MASShortcut
        else {
            return nil
        }
        return (shortcut.keyCodeStringForKeyEquivalent, shortcut.modifierFlags)
    }

    // MARK: - Activate / Deactivate (Grid HUD)

    func activate() {
        guard state == .inactive else { return }
        guard !ApplicationToggle.shortcutsDisabled else { return }
        guard let shortcutManager = shortcutManager else { return }

        state = .active
        targetWindowElement = AccessibilityElement.getFrontWindowElement()

        ProjectManager.shared.saveSnapshot()
        ProjectManager.shared.rebuildMacOSProject()
        ProjectManager.shared.validateAllProjects()

        shortcutManager.bindShortcuts()

        let gridNode = GridHUDNode()
        pushNode(gridNode)

        startEscapeMonitor()
        observeWindowAction()
        Notification.Name.modalModeActivated.post()
    }

    func deactivate(restoreLayout: Bool = true) {
        guard state == .active else { return }
        guard let shortcutManager = shortcutManager else { return }

        state = .inactive
        targetWindowElement = nil

        // Pop all nodes
        popToRoot()

        if restoreLayout {
            ProjectManager.shared.restoreSnapshot()
        } else {
            ProjectManager.shared.savedSnapshot = nil
        }

        shortcutManager.unbindShortcuts()
        stopEscapeMonitor()
        stopTimeoutTimer()
        stopObservingWindowAction()
        Notification.Name.modalModeDeactivated.post()
    }

    private func debugLog(_ msg: String) {
        let entry = "\(Date()): \(msg)\n"
        let path = "/tmp/rectangle_debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(entry.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: entry.data(using: .utf8))
        }
    }

    func reloadFromDefaults() {
        debugLog("reloadFromDefaults: modalMode.userEnabled=\(Defaults.modalMode.userEnabled)")
        if Defaults.modalMode.userEnabled {
            ModalModeManager.initActivateShortcut()
            ModalModeManager.registerActivateShortcut()
            startEventTap()
            if state == .inactive, !ApplicationToggle.shortcutsDisabled {
                shortcutManager?.unbindShortcuts()
            }
        } else {
            if state == .active {
                deactivate()
            }
            ModalModeManager.unregisterActivateShortcut()
            stopEventTap()
            if !ApplicationToggle.shortcutsDisabled {
                shortcutManager?.bindShortcuts()
            }
        }
    }

    // MARK: - Node Stack

    var topmostNode: SelectorNode? {
        return nodeStack.last
    }

    func pushNode(_ node: SelectorNode) {
        debugLog("pushNode: \(type(of: node))")
        // Suspend EditModeController instead of deactivating (keeps overlays alive)
        if let editMode = topmostNode as? EditModeController {
            editMode.suspend()
        } else {
            topmostNode?.deactivate()
        }

        nodeStack.append(node)

        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first!
        let context = SelectorContext(
            screen: screen,
            projectManager: ProjectManager.shared,
            snapshot: ProjectManager.shared.savedSnapshot
        )
        node.activate(context: context)
    }

    func popNode() {
        guard let node = nodeStack.popLast() else { return }
        node.deactivate()

        // Reactivate the new topmost node
        if let newTop = topmostNode {
            let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                ?? NSScreen.main ?? NSScreen.screens.first!
            let context = SelectorContext(
                screen: screen,
                projectManager: ProjectManager.shared,
                snapshot: ProjectManager.shared.savedSnapshot
            )
            newTop.activate(context: context)
        }
    }

    func popToRoot() {
        while let node = nodeStack.popLast() {
            node.deactivate()
        }
    }

    // MARK: - CGEventTap

    func startEventTap() {
        debugLog("startEventTap called, existing tap: \(eventTap != nil)")
        guard eventTap == nil else { return }

        let eventMask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: selectorEventCallback,
            userInfo: refcon
        ) else {
            debugLog("FAILED to create CGEventTap for selector interception")
            return
        }

        eventTap = tap
        eventTapRunLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Disable system Cmd+Tab / Cmd+Shift+Tab app switcher
        disableSystemAppSwitcher()
        debugLog("EventTap created successfully")
    }

    func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        eventTapRunLoopSource = nil

        // Re-enable system Cmd+Tab app switcher
        enableSystemAppSwitcher()
    }

    // Symbolic hot key IDs (from SkyLight/CoreGraphics private API):
    // 1 = Cmd+Tab, 2 = Cmd+Shift+Tab, 6 = Cmd+` (key above Tab)
    private static let cmdTabHotKey: Int32 = 1
    private static let cmdShiftTabHotKey: Int32 = 2
    private static let cmdGraveHotKey: Int32 = 6

    private func disableSystemAppSwitcher() {
        let r1 = CGSSetSymbolicHotKeyEnabled(ModalModeManager.cmdTabHotKey, false)
        let r2 = CGSSetSymbolicHotKeyEnabled(ModalModeManager.cmdShiftTabHotKey, false)
        let r3 = CGSSetSymbolicHotKeyEnabled(ModalModeManager.cmdGraveHotKey, false)
        debugLog("disableSystemAppSwitcher: Cmd+Tab=\(r1.rawValue), Cmd+Shift+Tab=\(r2.rawValue), Cmd+`=\(r3.rawValue)")
    }

    private func enableSystemAppSwitcher() {
        CGSSetSymbolicHotKeyEnabled(ModalModeManager.cmdTabHotKey, true)
        CGSSetSymbolicHotKeyEnabled(ModalModeManager.cmdShiftTabHotKey, true)
        CGSSetSymbolicHotKeyEnabled(ModalModeManager.cmdGraveHotKey, true)
    }

    func handleSelectorEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown {
            debugLog("EventTap keyDown: keyCode=\(keyCode) flags=\(flags.rawValue) cmd=\(flags.contains(.maskCommand))")
        }

        // --- Initiation events (when no selector is active or to push children) ---

        if type == .keyDown {
            // Cmd+Tab → push GroupSelector (App Selector visible)
            if flags.contains(.maskCommand) && keyCode == kVK_Tab {
                debugLog("Cmd+Tab intercepted!")
                return handleCmdTab(flags: flags)
            }

            // Cmd+` → push WindowSelector
            if flags.contains(.maskCommand) && keyCode == kVK_ANSI_Grave {
                return handleCmdGrave(flags: flags)
            }

            // Forward other keyDown to topmost node if stack is active
            if let topNode = topmostNode, !nodeStack.isEmpty {
                // Esc → dismiss topmost
                if keyCode == kVK_Escape {
                    let dismiss = { [weak self] in
                        guard let self = self else { return }
                        if self.nodeStack.count <= 1 {
                            self.deactivate()
                        } else {
                            self.popNode()
                        }
                    }
                    if Thread.isMainThread { dismiss() } else { DispatchQueue.main.sync { dismiss() } }
                    return nil // consume
                }

                let characters = event.keyCharString
                let nsModifiers = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
                    .intersection(.deviceIndependentFlagsMask)

                let result: KeyEventResult
                if Thread.isMainThread {
                    result = topNode.handleKeyDown(keyCode: keyCode, modifiers: nsModifiers, characters: characters)
                } else {
                    var r: KeyEventResult = .unhandled
                    DispatchQueue.main.sync { r = topNode.handleKeyDown(keyCode: keyCode, modifiers: nsModifiers, characters: characters) }
                    result = r
                }

                switch result {
                case .handled:
                    return nil // consume
                case .unhandled:
                    return Unmanaged.passRetained(event) // pass through
                case .dismiss:
                    let dismissWork = { [weak self] in
                        guard let self = self else { return }
                        if self.nodeStack.count <= 1 {
                            self.deactivate()
                        } else {
                            self.popNode()
                        }
                    }
                    if Thread.isMainThread { dismissWork() } else { DispatchQueue.main.sync { dismissWork() } }
                    return nil // consume
                case .confirmDismiss:
                    let confirmWork = { [weak self] in
                        guard let self = self else { return }
                        if self.nodeStack.count <= 1 {
                            self.deactivate(restoreLayout: false)
                        } else {
                            self.popNode()
                        }
                    }
                    if Thread.isMainThread { confirmWork() } else { DispatchQueue.main.sync { confirmWork() } }
                    return nil // consume
                case .pushChild(let child):
                    let pushWork = { [weak self] in self?.pushNode(child) }
                    if Thread.isMainThread { pushWork() } else { DispatchQueue.main.sync { pushWork() } }
                    return nil // consume
                }
            }
        }

        if type == .keyUp {
            // Consume keyUp for Cmd+Tab and Cmd+` when stack is active
            if !nodeStack.isEmpty {
                if keyCode == kVK_Tab && flags.contains(.maskCommand) { return nil }
                if keyCode == kVK_ANSI_Grave && flags.contains(.maskCommand) { return nil }
            }
        }

        if type == .flagsChanged {
            // Cmd+Ctrl → open project selector (when no selector is active)
            let hasCmdCtrl = flags.contains(.maskCommand) && flags.contains(.maskControl)
            if hasCmdCtrl && !cmdCtrlTriggered && nodeStack.isEmpty {
                cmdCtrlTriggered = true
                let work = { [weak self] in
                    guard let self = self else { return }
                    if self.state == .inactive {
                        self.state = .active
                        self.targetWindowElement = AccessibilityElement.getFrontWindowElement()
                        ProjectManager.shared.saveSnapshot()
                        ProjectManager.shared.rebuildMacOSProject()
                        ProjectManager.shared.validateAllProjects()
                        self.startEscapeMonitor()
                        Notification.Name.modalModeActivated.post()
                    }
                    let group = GroupSelectorWindow()
                    group.initialGroupMode = .project
                    self.pushNode(group)
                }
                if Thread.isMainThread { work() } else { DispatchQueue.main.sync { work() } }
                return nil // consume
            }
            if !hasCmdCtrl {
                cmdCtrlTriggered = false
            }

            if let topNode = topmostNode, !nodeStack.isEmpty {
                let result: KeyEventResult
                if Thread.isMainThread {
                    result = topNode.handleFlagsChanged(modifiers: flags)
                } else {
                    var r: KeyEventResult = .unhandled
                    DispatchQueue.main.sync { r = topNode.handleFlagsChanged(modifiers: flags) }
                    result = r
                }

                switch result {
                case .handled:
                    return nil
                case .dismiss:
                    let dismissWork = { [weak self] in
                        guard let self = self else { return }
                        if self.nodeStack.count <= 1 {
                            self.deactivate(restoreLayout: false)
                        } else {
                            self.popNode()
                            // Cascade: forward the flagsChanged to the new topmost node
                            // so it can also dismiss if appropriate (e.g. Cmd released)
                            if let newTop = self.topmostNode {
                                let cascadeResult = newTop.handleFlagsChanged(modifiers: flags)
                                if case .dismiss = cascadeResult {
                                    if self.nodeStack.count <= 1 {
                                        self.deactivate(restoreLayout: false)
                                    } else {
                                        self.popNode()
                                    }
                                }
                            }
                        }
                    }
                    if Thread.isMainThread { dismissWork() } else { DispatchQueue.main.sync { dismissWork() } }
                    return Unmanaged.passRetained(event)
                case .confirmDismiss:
                    let confirmWork = { [weak self] in
                        guard let self = self else { return }
                        if self.nodeStack.count <= 1 {
                            self.deactivate(restoreLayout: false)
                        } else {
                            self.popNode()
                        }
                    }
                    if Thread.isMainThread { confirmWork() } else { DispatchQueue.main.sync { confirmWork() } }
                    return Unmanaged.passRetained(event)
                case .pushChild(let child):
                    let pushWork = { [weak self] in self?.pushNode(child) }
                    if Thread.isMainThread { pushWork() } else { DispatchQueue.main.sync { pushWork() } }
                    return Unmanaged.passRetained(event)
                case .unhandled:
                    break
                }
            }
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Cmd+Tab Handling

    private func handleCmdTab(flags: CGEventFlags) -> Unmanaged<CGEvent>? {
        let reverse = flags.contains(.maskShift)

        let work = { [weak self] in
            guard let self = self else { return }

            // If topmost is GroupSelector, forward Tab handling (handles mode expansion)
            if let group = self.topmostNode as? GroupSelectorWindow {
                group.handleCmdTab(reverse: reverse)
                return
            }

            // If topmost is WindowSelector (pushed as child), pop it and navigate the GroupSelector underneath
            if self.topmostNode is WindowSelectorWindow {
                self.popNode()
                if let group = self.topmostNode as? GroupSelectorWindow {
                    group.handleCmdTab(reverse: reverse)
                }
                return
            }

            // If topmost is EditModeController, push GroupSelector as child
            if self.topmostNode is EditModeController {
                let group = GroupSelectorWindow()
                group.initialHUDMode = .appsOnly
                self.pushNode(group)
                return
            }

            // Otherwise, initiate fresh GroupSelector
            self.debugLog("handleCmdTab: state=\(self.state), topNode=\(String(describing: type(of: self.topmostNode)))")
            if self.state == .inactive {
                self.state = .active
                self.targetWindowElement = AccessibilityElement.getFrontWindowElement()
                ProjectManager.shared.saveSnapshot()
                ProjectManager.shared.rebuildMacOSProject()
                ProjectManager.shared.validateAllProjects()
                self.startEscapeMonitor()
                Notification.Name.modalModeActivated.post()
            }

            let group = GroupSelectorWindow()
            group.initialHUDMode = .appsOnly
            self.debugLog("Pushing GroupSelectorWindow")
            self.pushNode(group)
            self.debugLog("GroupSelectorWindow pushed, nodeStack.count=\(self.nodeStack.count)")

            if reverse {
                group.navigatePrevious()
            }
        }

        if Thread.isMainThread { work() } else { DispatchQueue.main.sync { work() } }
        return nil // consume
    }

    // MARK: - Cmd+` Handling

    private func handleCmdGrave(flags: CGEventFlags) -> Unmanaged<CGEvent>? {
        let reverse = flags.contains(.maskShift)

        let work = { [weak self] in
            guard let self = self else { return }

            // If topmost is EditModeController, push WindowSelector as child
            if self.topmostNode is EditModeController {
                let windowSelector = WindowSelectorWindow()
                self.pushNode(windowSelector)
                return
            }

            // If topmost is already a WindowSelector, cycle
            if let windowSelector = self.topmostNode as? WindowSelectorWindow {
                if reverse {
                    windowSelector.navigatePrevious()
                } else {
                    windowSelector.navigateNext()
                }
                return
            }

            // If topmost is GroupSelector, enter/cycle gallery within app selector
            if let group = self.topmostNode as? GroupSelectorWindow {
                group.handleCmdGrave(reverse: reverse)
                return
            }

            // Otherwise, initiate GroupSelector for the frontmost app's windows
            if self.state == .inactive {
                self.state = .active
                self.targetWindowElement = AccessibilityElement.getFrontWindowElement()
                ProjectManager.shared.saveSnapshot()
                Notification.Name.modalModeActivated.post()
            }

            let group = GroupSelectorWindow()
            group.initialHUDMode = .appsOnly
            group.initialAppIndex = 0  // Frontmost app (for window cycling)
            self.pushNode(group)
            // Immediately show the first window preview
            group.handleCmdGrave(reverse: reverse)
        }

        if Thread.isMainThread { work() } else { DispatchQueue.main.sync { work() } }
        return nil // consume
    }

    // MARK: - Grid Selection Handler

    func handleGridSelection(startCol: Int, startRow: Int, endCol: Int, endRow: Int) {
        guard let gridNode = topmostNode as? GridHUDNode,
              let screen = gridNode.hudWindow.getTargetScreen() as NSScreen? else { return }

        let visibleFrame = screen.adjustedVisibleFrame()
        let columns = CGFloat(Defaults.modalGridColumns.value)
        let rows = CGFloat(Defaults.modalGridRows.value)

        let cellWidth = visibleFrame.width / columns
        let cellHeight = visibleFrame.height / rows

        // Grid is top-left origin; screen coords are bottom-left origin
        let x = visibleFrame.origin.x + CGFloat(startCol) * cellWidth
        let y = visibleFrame.origin.y + visibleFrame.height - CGFloat(endRow + 1) * cellHeight
        let width = CGFloat(endCol - startCol + 1) * cellWidth
        let height = CGFloat(endRow - startRow + 1) * cellHeight

        var rect = CGRect(x: x, y: y, width: width, height: height)

        let gapSize = Defaults.gapSize.value
        if gapSize > 0 {
            var sharedEdges: Edge = []
            if startCol > 0 { sharedEdges.insert(.left) }
            if endCol < Int(columns) - 1 { sharedEdges.insert(.right) }
            if startRow > 0 { sharedEdges.insert(.top) }
            if endRow < Int(rows) - 1 { sharedEdges.insert(.bottom) }
            rect = GapCalculation.applyGaps(rect, sharedEdges: sharedEdges, gapSize: gapSize)
        }

        let screenFlipped = rect.screenFlipped

        guard let windowElement = targetWindowElement else {
            deactivate()
            return
        }

        windowElement.setFrame(screenFlipped)
        deactivate(restoreLayout: false)
    }

    // MARK: - Timeout

    func resetTimeout() {
        guard topmostNode is GridHUDNode else { return }
        stopTimeoutTimer()
        startTimeoutTimer()
    }

    // MARK: - Escape Monitor

    private func startEscapeMonitor() {
        escapeMonitor = PassiveEventMonitor(mask: .keyDown) { [weak self] event in
            guard let self = self else { return }
            if event.keyCode == UInt16(kVK_Escape) {
                // Don't handle Esc here — the event tap handles it when node stack is active
                if !self.nodeStack.isEmpty { return }
                self.deactivate()
            }
        }
        escapeMonitor?.start()
    }

    private func stopEscapeMonitor() {
        escapeMonitor?.stop()
        escapeMonitor = nil
    }

    // MARK: - Timeout Timer

    private func startTimeoutTimer() {
        let timeout = TimeInterval(Defaults.modalModeTimeout.value)
        guard timeout > 0 else { return }
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.deactivate()
        }
    }

    private func stopTimeoutTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    // MARK: - Window Action Observer

    private func observeWindowAction() {
        actionObserver = Notification.Name.windowActionExecuted.onPost { [weak self] notification in
            guard let self = self else { return }
            // Only auto-close when the Grid HUD is topmost and a shortcut fires
            guard self.topmostNode is GridHUDNode else { return }
            if let source = notification.object as? ExecutionSource, source == .keyboardShortcut {
                self.deactivate()
            }
        }
    }

    private func stopObservingWindowAction() {
        if let observer = actionObserver {
            NotificationCenter.default.removeObserver(observer)
            actionObserver = nil
        }
    }
}

// MARK: - CGEvent helpers

private extension CGEvent {
    var keyCharString: String? {
        let maxLength = 4
        var actualLength = 0
        var chars = [UniChar](repeating: 0, count: maxLength)
        keyboardGetUnicodeString(maxStringLength: maxLength, actualStringLength: &actualLength, unicodeString: &chars)
        guard actualLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: actualLength)
    }
}
