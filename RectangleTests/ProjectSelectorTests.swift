//
//  ProjectSelectorTests.swift
//  RectangleTests
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import XCTest
import Carbon
@testable import Rectangle

class ProjectSelectorTests: XCTestCase {

    var node: ProjectSelectorNode!

    override func setUp() {
        super.setUp()
        node = ProjectSelectorNode()
        // Seed ProjectManager with a system project + one user project
        let manager = ProjectManager.shared
        manager.projects = [
            WindowProject(name: "system", windowIDs: [], isDefault: true),
            WindowProject(name: "TestProject", windowIDs: [])
        ]
        // Sync the list view so handleKeyDown works without activate()
        node.projectListView.projects = manager.projects
        node.projectListView.isActive = true
        node.projectListView.selectProjectIndex(1)
    }

    override func tearDown() {
        node = nil
        // Reset ProjectManager
        ProjectManager.shared.projects = [
            WindowProject(name: "system", windowIDs: [], isDefault: true)
        ]
        super.tearDown()
    }

    // MARK: - Enter confirms project and preserves layout

    func testEnterReturnsConfirmDismiss() {
        let result = node.handleKeyDown(keyCode: kVK_Return, modifiers: [], characters: "\r")

        if case .confirmDismiss = result {
            // Expected
        } else {
            XCTFail("Expected .confirmDismiss but got \(result)")
        }
    }

    // MARK: - Esc during editing cancels without dismiss

    func testEscDuringEditingCancelsAndReturnsHandled() {
        node.projectListView.startEditing(at: 1)
        XCTAssertTrue(node.projectListView.isEditingName)

        let result = node.handleKeyDown(keyCode: kVK_Escape, modifiers: [], characters: nil)

        if case .handled = result {
            XCTAssertFalse(node.projectListView.isEditingName, "Editing should be cancelled")
        } else {
            XCTFail("Expected .handled but got \(result)")
        }
    }

    // MARK: - Arrow navigation

    func testDownArrowMovesSelection() {
        node.projectListView.selectProjectIndex(0)
        let result = node.handleKeyDown(keyCode: kVK_DownArrow, modifiers: [], characters: nil)

        if case .handled = result {
            XCTAssertEqual(node.projectListView.selectedIndex, 1)
        } else {
            XCTFail("Expected .handled but got \(result)")
        }
    }

    func testUpArrowMovesSelection() {
        node.projectListView.selectProjectIndex(1)
        let result = node.handleKeyDown(keyCode: kVK_UpArrow, modifiers: [], characters: nil)

        if case .handled = result {
            XCTAssertEqual(node.projectListView.selectedIndex, 0)
        } else {
            XCTFail("Expected .handled but got \(result)")
        }
    }

    // MARK: - Ctrl+N creates project and auto-enters edit mode on confirm

    func testCtrlNCreatesProjectAndAutoEntersEditMode() {
        let initialCount = ProjectManager.shared.projects.count

        // Ctrl+N to create project
        let createResult = node.handleKeyDown(keyCode: kVK_ANSI_N, modifiers: .control, characters: "n")
        if case .handled = createResult {} else {
            XCTFail("Expected .handled for Ctrl+N but got \(createResult)")
        }

        XCTAssertEqual(ProjectManager.shared.projects.count, initialCount + 1, "New project should be created")
        XCTAssertTrue(node.projectListView.isEditingName, "Should be editing the new project's name")

        // Type a name and press Enter
        node.projectListView.appendEditCharacter("A")
        let confirmResult = node.handleKeyDown(keyCode: kVK_Return, modifiers: [], characters: "\r")

        if case .pushChild(let child) = confirmResult {
            XCTAssertTrue(child is EditModeController, "Should push EditModeController")
            if let editMode = child as? EditModeController {
                XCTAssertEqual(editMode.projectIndex, node.projectListView.selectedIndex,
                               "EditModeController should have correct projectIndex")
            }
        } else {
            XCTFail("Expected .pushChild(EditModeController) but got \(confirmResult)")
        }
    }

    // MARK: - Enter during editing without auto-edit returns handled

    func testEnterDuringManualEditReturnsHandled() {
        // Start editing manually (Ctrl+R rename, not Ctrl+N create)
        node.projectListView.startEditing(at: 1)
        XCTAssertTrue(node.projectListView.isEditingName)

        let result = node.handleKeyDown(keyCode: kVK_Return, modifiers: [], characters: "\r")

        if case .handled = result {
            XCTAssertFalse(node.projectListView.isEditingName, "Editing should be finished")
        } else {
            XCTFail("Expected .handled but got \(result)")
        }
    }

    // MARK: - Ctrl+E enters edit mode with correct project index

    func testCtrlEPushesEditModeWithProjectIndex() {
        node.projectListView.selectProjectIndex(1)

        let result = node.handleKeyDown(keyCode: kVK_ANSI_E, modifiers: .control, characters: "e")

        if case .pushChild(let child) = result {
            XCTAssertTrue(child is EditModeController)
            if let editMode = child as? EditModeController {
                XCTAssertEqual(editMode.projectIndex, 1)
            }
        } else {
            XCTFail("Expected .pushChild(EditModeController) but got \(result)")
        }
    }

    // MARK: - Ctrl+E on system project does not enter edit mode

    func testCtrlEOnSystemProjectReturnsHandled() {
        node.projectListView.selectProjectIndex(0)

        let result = node.handleKeyDown(keyCode: kVK_ANSI_E, modifiers: .control, characters: "e")

        if case .handled = result {
            // Expected — can't edit system project
        } else {
            XCTFail("Expected .handled for Ctrl+E on system project but got \(result)")
        }
    }

    // MARK: - Type-to-filter

    func testTypeToFilterNarrowsList() {
        // Add another project
        ProjectManager.shared.projects.append(WindowProject(name: "Other"))
        node.projectListView.projects = ProjectManager.shared.projects

        // Type "Test" to filter
        _ = node.handleKeyDown(keyCode: kVK_ANSI_T, modifiers: [], characters: "T")
        _ = node.handleKeyDown(keyCode: kVK_ANSI_E, modifiers: [], characters: "e")
        _ = node.handleKeyDown(keyCode: kVK_ANSI_S, modifiers: [], characters: "s")
        _ = node.handleKeyDown(keyCode: kVK_ANSI_T, modifiers: [], characters: "t")

        XCTAssertEqual(node.projectListView.filterText, "Test")
    }
}
