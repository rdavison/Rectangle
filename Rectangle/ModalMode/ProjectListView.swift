//
//  ProjectListView.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa
import Carbon

class ProjectListView: NSView {

    var projects: [WindowProject] = [] {
        didSet {
            applyFilter()
            needsDisplay = true
        }
    }

    var selectedIndex: Int = 0 {
        didSet { needsDisplay = true }
    }

    var isActive: Bool = false {
        didSet {
            needsDisplay = true
            alphaValue = isActive ? 1.0 : 0.6
        }
    }

    var onProjectChanged: ((Int) -> Void)?
    var onProjectCreated: ((String) -> Void)?
    var onProjectDeleted: ((Int) -> Void)?

    // Type-to-filter
    private(set) var filterText: String = "" {
        didSet {
            applyFilter()
            needsDisplay = true
        }
    }
    private var filteredIndices: [Int] = [] // indices into projects array
    private var filteredSelectedRow: Int = 0 // row in filtered list

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rowHeight: CGFloat = 24
        let leftPadding: CGFloat = 10

        let displayProjects = filteredProjects()

        if displayProjects.isEmpty {
            let hint = filterText.isEmpty ? "No projects" : "No matches for \"\(filterText)\""
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white.withAlphaComponent(0.4)
            ]
            (hint as NSString).draw(at: NSPoint(x: leftPadding, y: 4), withAttributes: attrs)

            drawHints(at: CGFloat(1) * rowHeight + 8, leftPadding: leftPadding)
            return
        }

        for (row, entry) in displayProjects.enumerated() {
            let project = entry.project
            let rowRect = NSRect(x: 0, y: CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight)

            if row == filteredSelectedRow && isActive {
                let selectionRect = rowRect.insetBy(dx: 4, dy: 1)
                let path = NSBezierPath(roundedRect: selectionRect, xRadius: 4, yRadius: 4)
                NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
                path.fill()
            }

            let isEditing = isEditingName && entry.index == editingIndex
            let isSelectedRow = row == filteredSelectedRow && isActive

            let indicator: String
            if isSelectedRow {
                indicator = "> "
            } else {
                indicator = "  "
            }

            let displayName: String
            if isEditing && editingSelectAll {
                displayName = indicator + "[" + editingName + "]"
            } else if isEditing {
                displayName = indicator + editingName + "|"
            } else {
                let windowCount = project.windowIDs.count
                let countStr = isActive ? " (\(windowCount))" : ""
                displayName = indicator + project.name + countStr
            }

            let nameColor: NSColor
            if isEditing {
                nameColor = NSColor.controlAccentColor
            } else if project.isDefault {
                nameColor = isSelectedRow ? NSColor.white : NSColor.white.withAlphaComponent(0.5)
            } else {
                nameColor = isSelectedRow ? NSColor.white : NSColor.white.withAlphaComponent(0.7)
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: nameColor
            ]
            let textRect = NSRect(x: leftPadding, y: rowRect.origin.y + 4, width: bounds.width - leftPadding - 4, height: rowHeight)
            (displayName as NSString).draw(in: textRect, withAttributes: attrs)
        }

        // Draw filter text if active
        if !filterText.isEmpty {
            let filterY = CGFloat(displayProjects.count) * rowHeight + 4
            let filterAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.controlAccentColor.withAlphaComponent(0.8)
            ]
            let filterStr = "Filter: \(filterText)" as NSString
            filterStr.draw(at: NSPoint(x: leftPadding, y: filterY), withAttributes: filterAttrs)
        }

        // Draw hints
        let hintsY = CGFloat(displayProjects.count) * rowHeight + (filterText.isEmpty ? 8 : 24)
        drawHints(at: hintsY, leftPadding: leftPadding)
    }

    private func drawHints(at y: CGFloat, leftPadding: CGFloat) {
        guard isActive else { return }
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.white.withAlphaComponent(0.35)
        ]
        let hints = "^n:new ^r:rename ^c:clone ^d:del ^e:edit ^↑↓:swap"
        (hints as NSString).draw(at: NSPoint(x: leftPadding, y: y), withAttributes: hintAttrs)
    }

    func moveSelectionUp() {
        guard !filteredIndices.isEmpty else { return }
        filteredSelectedRow = max(0, filteredSelectedRow - 1)
        syncSelectedIndex()
        needsDisplay = true
    }

    func moveSelectionDown() {
        guard !filteredIndices.isEmpty else { return }
        filteredSelectedRow = min(filteredIndices.count - 1, filteredSelectedRow + 1)
        syncSelectedIndex()
        needsDisplay = true
    }

    /// Programmatic selection that keeps filteredSelectedRow in sync.
    func selectProjectIndex(_ index: Int) {
        guard let row = filteredIndices.firstIndex(of: index) else { return }
        filteredSelectedRow = row
        selectedIndex = index
        needsDisplay = true
    }

    // MARK: - Type-to-filter

    func appendFilterCharacter(_ char: Character) {
        filterText.append(char)
    }

    func deleteFilterCharacter() {
        if !filterText.isEmpty {
            filterText.removeLast()
        }
    }

    func clearFilter() {
        filterText = ""
    }

    private func applyFilter() {
        if filterText.isEmpty {
            filteredIndices = Array(projects.indices)
        } else {
            let lower = filterText.lowercased()
            filteredIndices = projects.indices.filter {
                projects[$0].name.lowercased().contains(lower)
            }
        }
        // Clamp selection
        if filteredSelectedRow >= filteredIndices.count {
            filteredSelectedRow = max(0, filteredIndices.count - 1)
        }
        syncSelectedIndex()
    }

    private func filteredProjects() -> [(index: Int, project: WindowProject)] {
        return filteredIndices.map { (index: $0, project: projects[$0]) }
    }

    private func syncSelectedIndex() {
        guard !filteredIndices.isEmpty, filteredSelectedRow < filteredIndices.count else { return }
        let actualIndex = filteredIndices[filteredSelectedRow]
        if selectedIndex != actualIndex {
            selectedIndex = actualIndex
            onProjectChanged?(selectedIndex)
        }
    }

    // Inline name editing
    private(set) var isEditingName: Bool = false
    private var editingName: String = ""
    private var editingIndex: Int = -1
    private var editingSelectAll: Bool = false
    var onNameEdited: ((Int, String) -> Void)?

    func startEditing(at index: Int) {
        guard index >= 0, index < projects.count, !projects[index].isDefault else { return }
        editingIndex = index
        editingName = projects[index].name
        editingSelectAll = true
        isEditingName = true
        // Clear filter while editing
        filterText = ""
        needsDisplay = true
    }

    func confirmEditing() {
        guard isEditingName else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? "Untitled" : trimmed
        onNameEdited?(editingIndex, name)
        isEditingName = false
        editingIndex = -1
        editingName = ""
        editingSelectAll = false
        needsDisplay = true
    }

    func cancelEditing() {
        isEditingName = false
        editingIndex = -1
        editingName = ""
        editingSelectAll = false
        needsDisplay = true
    }

    func appendEditCharacter(_ char: Character) {
        guard isEditingName else { return }
        if editingSelectAll {
            editingName = String(char)
            editingSelectAll = false
        } else {
            editingName.append(char)
        }
        needsDisplay = true
    }

    func deleteEditCharacter() {
        guard isEditingName else { return }
        if editingSelectAll {
            editingName = ""
            editingSelectAll = false
        } else if !editingName.isEmpty {
            editingName.removeLast()
        }
        needsDisplay = true
    }
}

// MARK: - ProjectSelectorNode

class ProjectSelectorNode: SelectorNode {

    private var projectPanel: ProjectSelectorPanel?
    private(set) var projectListView = ProjectListView()
    private var overlayManager: WindowOverlayManager?
    private var autoEnterEditMode = false

    var panel: NSPanel? { projectPanel }

    func activate(context: SelectorContext) {
        let manager = context.projectManager
        manager.rebuildMacOSProject()
        manager.validateAllProjects()

        overlayManager = WindowOverlayManager()
        projectListView.projects = manager.projects
        projectListView.isActive = true

        // Set callbacks before initial selection so preview triggers
        projectListView.onProjectChanged = { [weak self] index in
            self?.handleSelectionChanged(index)
        }
        projectListView.onNameEdited = { [weak self] index, name in
            self?.applyRename(at: index, name: name)
        }

        let panel = ProjectSelectorPanel(listView: projectListView, screen: context.screen)
        projectPanel = panel
        panel.orderFrontRegardless()

        // Select first user project and trigger initial preview
        if manager.projects.count > 1 {
            projectListView.selectProjectIndex(1)
            handleSelectionChanged(1)
        } else {
            refreshOverlays()
        }
    }

    func deactivate() {
        projectListView.isActive = false
        projectListView.clearFilter()
        projectListView.onProjectChanged = nil
        overlayManager?.hideOverlays()
        overlayManager = nil
        projectPanel?.orderOut(nil)
        projectPanel = nil
    }

    func handleKeyDown(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?) -> KeyEventResult {
        // When editing a name, intercept keys for the edit field
        if projectListView.isEditingName {
            switch keyCode {
            case kVK_Return:
                projectListView.confirmEditing()
                if autoEnterEditMode {
                    autoEnterEditMode = false
                    let editMode = EditModeController()
                    editMode.projectIndex = projectListView.selectedIndex
                    return .pushChild(editMode)
                }
                return .handled
            case kVK_Escape:
                projectListView.cancelEditing()
                return .handled
            case kVK_Delete:
                projectListView.deleteEditCharacter()
                return .handled
            default:
                if let chars = characters, let char = chars.first, !char.isNewline {
                    // Allow printable characters (but not ctrl combos)
                    if !modifiers.contains(.control) && !modifiers.contains(.command) {
                        projectListView.appendEditCharacter(char)
                        return .handled
                    }
                }
                return .handled // consume everything while editing
            }
        }

        // Ctrl+key combos (only without Cmd, to avoid conflict with Cmd+Ctrl entry)
        if modifiers.contains(.control) && !modifiers.contains(.command) {
            switch keyCode {
            case kVK_ANSI_N:
                createProject()
                return .handled
            case kVK_ANSI_R:
                renameProject()
                return .handled
            case kVK_ANSI_C:
                cloneProject()
                return .handled
            case kVK_ANSI_D:
                deleteProject()
                return .handled
            case kVK_ANSI_E:
                let index = projectListView.selectedIndex
                guard index > 0 else { return .handled }
                let editMode = EditModeController()
                editMode.projectIndex = index
                return .pushChild(editMode)
            case kVK_UpArrow:
                swapProjectUp()
                return .handled
            case kVK_DownArrow:
                swapProjectDown()
                return .handled
            default:
                break
            }
        }

        switch keyCode {
        case kVK_UpArrow:
            projectListView.moveSelectionUp()
            return .handled
        case kVK_DownArrow, kVK_Tab:
            projectListView.moveSelectionDown()
            return .handled
        case kVK_Return:
            revealProject()
            return .confirmDismiss
        case kVK_Delete:
            projectListView.deleteFilterCharacter()
            return .handled
        default:
            // Type-to-filter: printable characters
            if let chars = characters, let char = chars.first, char.isLetter || char.isNumber || char == " " {
                projectListView.appendFilterCharacter(char)
                return .handled
            }
            return .unhandled
        }
    }

    func handleFlagsChanged(modifiers: CGEventFlags) -> KeyEventResult {
        return .unhandled
    }

    // MARK: - Navigation

    func navigateNext() {
        projectListView.moveSelectionDown()
    }

    func navigatePrevious() {
        projectListView.moveSelectionUp()
    }

    // MARK: - Project Actions

    private func createProject() {
        let manager = ProjectManager.shared
        let count = manager.projects.count
        let name = "Untitled Project \(count)"
        let newIndex = manager.createProject(name: name)
        projectListView.projects = manager.projects
        projectListView.selectedIndex = newIndex
        refreshOverlays()
        // Auto-start editing the new project's name
        projectListView.startEditing(at: newIndex)
        // After naming, auto-enter edit mode for the first time
        autoEnterEditMode = true
    }

    private func renameProject() {
        let index = projectListView.selectedIndex
        guard index > 0 else { return } // can't rename system project
        projectListView.startEditing(at: index)
    }

    private func applyRename(at index: Int, name: String) {
        let manager = ProjectManager.shared
        guard index > 0, index < manager.projects.count else { return }
        manager.renameProject(at: index, to: name)
        projectListView.projects = manager.projects
    }

    private func cloneProject() {
        let manager = ProjectManager.shared
        let index = projectListView.selectedIndex
        if let newIndex = manager.cloneProject(at: index) {
            projectListView.projects = manager.projects
            projectListView.selectedIndex = newIndex
            refreshOverlays()
        }
    }

    private func deleteProject() {
        let index = projectListView.selectedIndex
        guard index > 0 else { return }
        let manager = ProjectManager.shared
        manager.deleteProject(at: index)
        projectListView.projects = manager.projects
        if projectListView.selectedIndex >= manager.projects.count {
            projectListView.selectedIndex = max(0, manager.projects.count - 1)
        }
        refreshOverlays()
    }

    private func swapProjectUp() {
        let index = projectListView.selectedIndex
        guard index > 1 else { return } // can't swap system or first user project up
        let manager = ProjectManager.shared
        manager.swapProjects(index, index - 1)
        projectListView.projects = manager.projects
        projectListView.selectedIndex = index - 1
    }

    private func swapProjectDown() {
        let index = projectListView.selectedIndex
        let manager = ProjectManager.shared
        guard index > 0, index < manager.projects.count - 1 else { return }
        manager.swapProjects(index, index + 1)
        projectListView.projects = manager.projects
        projectListView.selectedIndex = index + 1
    }

    private func revealProject() {
        ProjectManager.shared.revealProject(at: projectListView.selectedIndex)
    }

    private func handleSelectionChanged(_ index: Int) {
        ProjectManager.shared.previewProject(at: index)
        refreshOverlays()
    }

    private func refreshOverlays() {
        guard let overlayManager = overlayManager else { return }
        let manager = ProjectManager.shared
        manager.validateAllProjects()

        let allWindows = manager.orderedLiveWindows()
        let selectedIndex = projectListView.selectedIndex
        let projectIDs: Set<CGWindowID>
        if selectedIndex < manager.projects.count {
            projectIDs = manager.projects[selectedIndex].windowIDs
        } else {
            projectIDs = []
        }
        overlayManager.showOverlays(projectWindowIDs: projectIDs, allWindows: allWindows, perWindowDim: true)
    }

}

// MARK: - ProjectSelectorPanel

private class ProjectSelectorPanel: NSPanel {

    init(listView: ProjectListView, screen: NSScreen) {
        let width: CGFloat = 250
        let height: CGFloat = 300
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
        collectionBehavior = [.transient, .canJoinAllSpaces]

        let visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelRect.size))
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.autoresizingMask = [.width, .height]

        // Title
        let titleLabel = NSTextField(labelWithString: "Projects")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Esc hint
        let escLabel = NSTextField(labelWithString: "Esc to close  Ctrl to switch")
        escLabel.font = NSFont.systemFont(ofSize: 10)
        escLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        escLabel.translatesAutoresizingMaskIntoConstraints = false

        listView.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(titleLabel)
        visualEffect.addSubview(listView)
        visualEffect.addSubview(escLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),

            listView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            listView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 8),
            listView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -8),
            listView.bottomAnchor.constraint(equalTo: escLabel.topAnchor, constant: -8),

            escLabel.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),
            escLabel.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -10),
        ])

        contentView = visualEffect
    }

    override var canBecomeKey: Bool { true }
}
