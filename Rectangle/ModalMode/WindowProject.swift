//
//  WindowProject.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

struct WindowProject {
    var name: String
    var windowIDs: Set<CGWindowID>
    let isDefault: Bool

    init(name: String, windowIDs: Set<CGWindowID> = [], isDefault: Bool = false) {
        self.name = name
        self.windowIDs = windowIDs
        self.isDefault = isDefault
    }
}

struct WindowLayoutSnapshot {
    let visiblePIDs: Set<pid_t>
    let frontWindowID: CGWindowID?
    let frontPID: pid_t?
}

class ProjectManager {
    static let shared = ProjectManager()

    var projects: [WindowProject] = []
    var savedSnapshot: WindowLayoutSnapshot?

    private init() {
        rebuildMacOSProject()
    }

    func rebuildMacOSProject() {
        let liveIDs = liveWindowIDs()
        let macOS = WindowProject(name: "system", windowIDs: liveIDs, isDefault: true)
        if projects.isEmpty {
            projects.insert(macOS, at: 0)
        } else {
            projects[0] = macOS
        }
    }

    func saveSnapshot() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        let allWindows = WindowUtil.getWindowList()

        // Collect PIDs of apps with visible normal windows
        let visiblePIDs = Set(allWindows.filter {
            $0.level == normalLevel && $0.pid != myPID
        }.map { $0.pid })

        // Front window is first in z-order
        let frontWindow = allWindows.first { $0.level == normalLevel && $0.pid != myPID }

        savedSnapshot = WindowLayoutSnapshot(
            visiblePIDs: visiblePIDs,
            frontWindowID: frontWindow?.id,
            frontPID: frontWindow?.pid
        )
    }

    func restoreSnapshot() {
        guard let snapshot = savedSnapshot else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier

        // Unhide all apps that were visible before
        for pid in snapshot.visiblePIDs {
            guard pid != myPID else { continue }
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }

        // Restore the original front window
        if let frontWindowID = snapshot.frontWindowID {
            if let element = AccessibilityElement.getWindowElement(frontWindowID) {
                element.performAction(kAXRaiseAction as String)
            }
        }
        if let frontPID = snapshot.frontPID {
            NSRunningApplication(processIdentifier: frontPID)?.activate(options: .activateIgnoringOtherApps)
        }

        savedSnapshot = nil
    }

    func previewProject(at index: Int) {
        guard index >= 0, index < projects.count else { return }
        let project = projects[index]

        if project.isDefault {
            // System project: restore the original snapshot
            guard let snapshot = savedSnapshot else { return }

            // Unhide all apps that were visible before
            let myPID = ProcessInfo.processInfo.processIdentifier
            for pid in snapshot.visiblePIDs {
                guard pid != myPID else { continue }
                NSRunningApplication(processIdentifier: pid)?.unhide()
            }

            // Restore the original front window
            if let frontWindowID = snapshot.frontWindowID {
                if let element = AccessibilityElement.getWindowElement(frontWindowID) {
                    element.performAction(kAXRaiseAction as String)
                }
            }
            if let frontPID = snapshot.frontPID {
                NSRunningApplication(processIdentifier: frontPID)?.activate(options: .activateIgnoringOtherApps)
            }
            return
        }

        let projectPIDs = uniquePIDs(for: project)
        let myPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        let allPIDs = Set(WindowUtil.getWindowList().filter {
            $0.level == normalLevel && $0.pid != myPID
        }.map { $0.pid })

        // Hide non-project apps
        for pid in allPIDs.subtracting(projectPIDs) {
            NSRunningApplication(processIdentifier: pid)?.hide()
        }

        // Unhide project apps that might be hidden
        for pid in projectPIDs {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }

        // Raise project windows
        for windowID in project.windowIDs {
            if let element = AccessibilityElement.getWindowElement(windowID) {
                element.performAction(kAXRaiseAction as String)
            }
        }

        for pid in projectPIDs {
            NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
        }
    }

    func validateAllProjects() {
        let liveIDs = liveWindowIDs()
        rebuildMacOSProject()
        for i in 1..<projects.count {
            projects[i].windowIDs = projects[i].windowIDs.intersection(liveIDs)
        }
    }

    func toggleWindow(_ id: CGWindowID, inProjectAt index: Int) {
        guard index > 0, index < projects.count else { return }
        if projects[index].windowIDs.contains(id) {
            projects[index].windowIDs.remove(id)
        } else {
            projects[index].windowIDs.insert(id)
        }
    }

    func createProject(name: String) -> Int {
        let project = WindowProject(name: name)
        projects.append(project)
        return projects.count - 1
    }

    func deleteProject(at index: Int) {
        guard index > 0, index < projects.count else { return }
        projects.remove(at: index)
    }

    func cloneProject(at index: Int) -> Int? {
        guard index > 0, index < projects.count else { return nil }
        let source = projects[index]
        let clone = WindowProject(name: "Clone of " + source.name, windowIDs: source.windowIDs)
        projects.append(clone)
        return projects.count - 1
    }

    func renameProject(at index: Int, to name: String) {
        guard index > 0, index < projects.count else { return }
        projects[index].name = name
    }

    func swapProjects(_ i: Int, _ j: Int) {
        guard i > 0, j > 0, i < projects.count, j < projects.count, i != j else { return }
        projects.swapAt(i, j)
    }

    func revealProject(at index: Int) {
        guard index >= 0, index < projects.count else { return }
        let project = projects[index]
        let projectPIDs = uniquePIDs(for: project)

        // Hide all apps that have no windows in this project (skip for macOS project)
        if !project.isDefault {
            let allWindows = WindowUtil.getWindowList()
            let myPID = ProcessInfo.processInfo.processIdentifier
            let normalLevel = CGWindowLevelForKey(.normalWindow)
            let allPIDs = Set(allWindows.filter { $0.level == normalLevel && $0.pid != myPID }.map { $0.pid })
            for pid in allPIDs.subtracting(projectPIDs) {
                NSRunningApplication(processIdentifier: pid)?.hide()
            }
        }

        // Raise each specific window via AXRaise
        for windowID in project.windowIDs {
            if let element = AccessibilityElement.getWindowElement(windowID) {
                element.performAction(kAXRaiseAction as String)
            }
        }

        // Activate each project app so the raised windows come to front
        for pid in projectPIDs {
            NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
        }
    }

    func hideProject(at index: Int) {
        guard index >= 0, index < projects.count else { return }
        let pids = uniquePIDs(for: projects[index])
        for pid in pids {
            NSRunningApplication(processIdentifier: pid)?.hide()
        }
    }

    func quitProject(at index: Int) {
        guard index > 0, index < projects.count else { return }
        let pids = uniquePIDs(for: projects[index])
        for pid in pids {
            NSRunningApplication(processIdentifier: pid)?.terminate()
        }
    }

    func closeProject(at index: Int) {
        guard index > 0, index < projects.count else { return }
        let project = projects[index]
        for windowID in project.windowIDs {
            if let element = AccessibilityElement.getWindowElement(windowID) {
                if let closeButton = element.getChildElement(.closeButton) {
                    closeButton.performAction(kAXPressAction)
                }
            }
        }
    }

    func liveWindowIDs() -> Set<CGWindowID> {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        let windows = WindowUtil.getWindowList()
        let ids = windows.filter { info in
            info.level == normalLevel && info.pid != myPID
        }.map { $0.id }
        return Set(ids)
    }

    func orderedLiveWindows() -> [WindowInfo] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        return WindowUtil.getWindowList().filter { info in
            info.level == normalLevel && info.pid != myPID
        }
    }

    private func uniquePIDs(for project: WindowProject) -> Set<pid_t> {
        let allWindows = WindowUtil.getWindowList(ids: Array(project.windowIDs))
        return Set(allWindows.map { $0.pid })
    }
}
