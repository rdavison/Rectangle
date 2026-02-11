//
//  SelectorNode.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

enum KeyEventResult {
    case handled
    case unhandled
    case dismiss
    case confirmDismiss  // dismiss without restoring layout (confirmed selection)
    case pushChild(SelectorNode)
}

protocol SelectorNode: AnyObject {
    var panel: NSPanel? { get }
    func activate(context: SelectorContext)
    func deactivate()
    func handleKeyDown(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?) -> KeyEventResult
    func handleFlagsChanged(modifiers: CGEventFlags) -> KeyEventResult
}

extension SelectorNode {
    func handleFlagsChanged(modifiers: CGEventFlags) -> KeyEventResult {
        return .unhandled
    }
}

struct SelectorContext {
    let screen: NSScreen
    let projectManager: ProjectManager
    let snapshot: WindowLayoutSnapshot?
}
