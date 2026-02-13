//
//  AppSelectorBackdrop.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

extension AppSelectorWindow {

    /// The current backdrop layout based on user settings.
    var currentBackdropLayout: WindowStage.Layout {
        let styles: [WindowStage.Layout] = [.cascade, .expose, .ring]
        let idx = min(Defaults.backdropStyle.value, styles.count - 1)
        return styles[idx]
    }

    func loadBackdropWindows(for appIndex: Int) {
        guard appIndex >= 0, appIndex < apps.count else {
            backdropWindows = []
            return
        }
        let app = apps[appIndex]
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        let sourceList = app.isHidden ? cachedWindowList : cachedOnScreenWindowList
        backdropWindows = Self.filterWindowsForBackdrop(
            from: sourceList, pid: app.processIdentifier,
            normalLevel: normalLevel, appIsHidden: app.isHidden
        )
    }

    func captureBackdropScreenshots(direction: CGFloat = 0) {
        let windows = backdropWindows
        guard !windows.isEmpty else {
            // No windows — show empty stage
            windowStage?.replaceWindows([], cache: [:], animated: false)
            return
        }
        let totalStart = CFAbsoluteTimeGetCurrent()

        // Build cache with NSImage values for WindowStage
        var imageCacheCG: [CGWindowID: CGImage] = [:]
        var uncachedIndices: [Int] = []
        for (i, win) in windows.enumerated() {
            if let cached = screenshotCache[win.id] {
                imageCacheCG[win.id] = cached
            } else {
                uncachedIndices.append(i)
            }
        }

        windowStage?.replaceWindows(windows, cache: imageCacheCG,
                                    animated: direction != 0, direction: direction)
        perfLog("[perf] captureBackdropScreenshots setup \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - totalStart) * 1000))ms (\(windows.count - uncachedIndices.count) cached, \(uncachedIndices.count) pending)")

        // Capture uncached windows in the background, updating the stage as each arrives
        guard !uncachedIndices.isEmpty else { return }
        let gen = selectionGeneration
        let windowsToCapture = uncachedIndices.map { (index: $0, win: windows[$0]) }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let bgStart = CFAbsoluteTimeGetCurrent()
            var captured = 0
            for item in windowsToCapture {
                if let nsImage = WindowScreenshot.capture(windowID: item.win.id, maxSize: CGSize(width: 420, height: 300)),
                   let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    captured += 1
                    let idx = item.index
                    let wid = item.win.id
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.selectionGeneration == gen else { return }
                        self.screenshotCache[wid] = cgImage
                        self.windowStage?.updateImage(nsImage, at: idx)
                    }
                }
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - bgStart) * 1000
            DispatchQueue.main.async {
                perfLog("[perf] backdrop async done: \(captured)/\(windowsToCapture.count) in \(String(format: "%.1f", elapsed))ms")
            }
        }
    }

    /// Pre-cache screenshots for all apps so tab transitions are instant.
    func precacheAllAppScreenshots() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        let t0 = CFAbsoluteTimeGetCurrent()
        let allWindows = WindowUtil.getWindowList()
        perfLog("[perf] precache getWindowList() \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000))ms (\(allWindows.count) windows)")

        // Collect all uncached windows across every app
        var windowsToCapture: [WindowInfo] = []
        for app in apps {
            let pid = app.processIdentifier
            for win in allWindows where win.pid == pid && win.level == normalLevel && win.pid != myPID {
                if screenshotCache[win.id] == nil {
                    windowsToCapture.append(win)
                }
            }
        }

        guard !windowsToCapture.isEmpty else {
            perfLog("[perf] precache: all \(screenshotCache.count) windows already cached")
            return
        }

        perfLog("[perf] precache dispatching \(windowsToCapture.count) windows to background")

        // Snapshot cached IDs on main thread — dictionary is not thread-safe
        let alreadyCached = Set(screenshotCache.keys)

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let bgStart = CFAbsoluteTimeGetCurrent()
            var count = 0
            for win in windowsToCapture {
                guard !alreadyCached.contains(win.id) else { continue }
                if let nsImage = WindowScreenshot.capture(windowID: win.id, maxSize: CGSize(width: 420, height: 300)),
                   let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    count += 1
                    DispatchQueue.main.async { [weak self] in
                        self?.screenshotCache[win.id] = cgImage
                    }
                }
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - bgStart) * 1000
            DispatchQueue.main.async {
                perfLog("[perf] precache background done: \(count)/\(windowsToCapture.count) captured in \(String(format: "%.1f", elapsed))ms")
            }
        }
    }
}
