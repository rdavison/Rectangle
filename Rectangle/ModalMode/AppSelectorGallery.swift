//
//  AppSelectorGallery.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

extension AppSelectorWindow {

    func loadGalleryWindows(for appIndex: Int) {
        guard appIndex >= 0, appIndex < apps.count else {
            galleryWindows = []
            galleryElements = [:]
            return
        }
        let app = apps[appIndex]
        let pid = app.processIdentifier
        let myPID = ProcessInfo.processInfo.processIdentifier
        let normalLevel = CGWindowLevelForKey(.normalWindow)

        // Use on-screen list for z-order (MRU); fall back to all-windows for hidden apps
        let sourceList = app.isHidden ? cachedWindowList : cachedOnScreenWindowList
        galleryWindows = Self.filterWindowsForGallery(
            from: sourceList, pid: pid, myPID: myPID,
            normalLevel: normalLevel, appIsHidden: app.isHidden
        )
        let winIDs = galleryWindows.map { "wid:\($0.id)" }
        perfLog("[mru] gallery windows for \(app.localizedName ?? "pid:\(pid)"): [\(winIDs.joined(separator: ", "))]")

        // Pre-fetch AX elements off main thread — AX IPC can hang for seconds on some apps
        galleryElements = [:]
        let gen = selectionGeneration
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let axStart = CFAbsoluteTimeGetCurrent()
            let axApp = AccessibilityElement(pid)
            var fetched: [CGWindowID: AccessibilityElement] = [:]
            if let windowElements = axApp.windowElements {
                for element in windowElements {
                    if let wid = element.windowId {
                        fetched[wid] = element
                    }
                }
            }
            let axMs = (CFAbsoluteTimeGetCurrent() - axStart) * 1000
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.selectionGeneration == gen else { return }
                self.galleryElements.merge(fetched) { _, new in new }
                perfLog("[perf] AX prefetch pid:\(pid) \(String(format: "%.1f", axMs))ms (\(fetched.count) elements)")
            }
        }
    }

    func captureGalleryThumbnails() {
        let windows = galleryWindows
        let cache = screenshotCache
        let gen = selectionGeneration

        // Immediately apply any cached screenshots (convert CGImage → NSImage for gallery)
        var cacheHits = 0
        for (i, win) in windows.enumerated() {
            if let cached = cache[win.id] {
                let nsImage = NSImage(cgImage: cached, size: NSSize(width: CGFloat(cached.width), height: CGFloat(cached.height)))
                selectorPanel?.updateGalleryThumbnail(nsImage, at: i)
                cacheHits += 1
            }
        }

        // Only capture uncached windows in the background
        let uncached = windows.enumerated().filter { cache[$0.element.id] == nil }
        guard !uncached.isEmpty else {
            perfLog("[perf] captureGalleryThumbnails: all \(windows.count) cached")
            return
        }
        perfLog("[perf] captureGalleryThumbnails: \(cacheHits) cached, \(uncached.count) to capture")

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let bgStart = CFAbsoluteTimeGetCurrent()
            for (i, win) in uncached {
                let t = CFAbsoluteTimeGetCurrent()
                if let nsImage = WindowScreenshot.capture(windowID: win.id, maxSize: CGSize(width: 160, height: 120)),
                   let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let capMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.selectionGeneration == gen else { return }
                        self.screenshotCache[win.id] = cgImage
                        self.selectorPanel?.updateGalleryThumbnail(nsImage, at: i)
                        perfLog("[perf] gallery thumb wid:\(win.id) \(String(format: "%.1f", capMs))ms")
                    }
                }
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - bgStart) * 1000
            DispatchQueue.main.async {
                perfLog("[perf] gallery thumb batch done \(String(format: "%.1f", elapsed))ms")
            }
        }
    }

    func refreshGalleryThumbnails() {
        let windows = galleryWindows
        let gen = selectionGeneration
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let bgStart = CFAbsoluteTimeGetCurrent()
            for (i, win) in windows.enumerated() {
                if let image = WindowScreenshot.capture(windowID: win.id, maxSize: CGSize(width: 160, height: 120)) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.selectionGeneration == gen else { return }
                        self.selectorPanel?.updateGalleryThumbnail(image, at: i)
                    }
                }
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - bgStart) * 1000
            DispatchQueue.main.async {
                perfLog("[perf] refreshGalleryThumbnails \(String(format: "%.1f", elapsed))ms (\(windows.count) windows)")
            }
        }
    }

    func raiseWindow(_ galleryIndex: Int) {
        guard galleryIndex >= 0, galleryIndex < galleryWindows.count else { return }
        let win = galleryWindows[galleryIndex]
        let pid = win.pid
        let gen = selectionGeneration

        if let element = galleryElements[win.id] {
            DispatchQueue.global(qos: .userInteractive).async {
                let t = CFAbsoluteTimeGetCurrent()
                element.performAction(kAXRaiseAction as String)
                let axMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.selectionGeneration == gen else { return }
                    NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
                    perfLog("[perf] raiseWindow wid:\(win.id) (cached AX) \(String(format: "%.1f", axMs))ms")
                }
            }
        } else {
            let windowID = win.id
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                let t = CFAbsoluteTimeGetCurrent()
                let axApp = AccessibilityElement(pid)
                if let windowElements = axApp.windowElements {
                    for element in windowElements {
                        if element.windowId == windowID {
                            element.performAction(kAXRaiseAction as String)
                            DispatchQueue.main.async { [weak self] in
                                guard let self = self, self.selectionGeneration == gen else { return }
                                self.galleryElements[windowID] = element
                            }
                            break
                        }
                    }
                }
                let axMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.selectionGeneration == gen else { return }
                    NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
                    perfLog("[perf] raiseWindow wid:\(windowID) (AX lookup) \(String(format: "%.1f", axMs))ms")
                }
            }
        }
    }
}
