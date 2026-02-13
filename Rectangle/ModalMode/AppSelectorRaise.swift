//
//  AppSelectorRaise.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

extension AppSelectorWindow {

    /// Raise all non-minimized windows belonging to the app at the given index.
    /// Debounced: cancels any pending raise from a previous selection, then waits
    /// 50ms before dispatching. This prevents concurrent raise/activate calls when
    /// the user tabs rapidly through apps.
    func raiseAllWindows(for appIndex: Int) {
        guard appIndex >= 0, appIndex < apps.count else { return }

        // Cancel any pending raise from a previous selection
        pendingRaiseWork?.cancel()

        let app = apps[appIndex]
        let gen = selectionGeneration

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Check generation on main thread before dispatching heavy AX work
            guard self.selectionGeneration == gen else { return }

            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                let t = CFAbsoluteTimeGetCurrent()
                let axApp = AccessibilityElement(app.processIdentifier)
                var raised = 0
                if let windowElements = axApp.windowElements {
                    for element in windowElements {
                        if element.isMinimized != true {
                            element.performAction(kAXRaiseAction as String)
                            raised += 1
                        }
                    }
                }
                let axMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
                // Activate on main thread, guarded by generation
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.selectionGeneration == gen else { return }
                    app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                    perfLog("[perf] raiseAllWindows pid:\(app.processIdentifier) \(String(format: "%.1f", axMs))ms (\(raised) raised)")
                }
            }
        }

        pendingRaiseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
}
