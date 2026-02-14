//
//  AppSelectorPreview.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

extension AppSelectorWindow {

    /// Cycle through the selected app's windows, showing a merry-go-round carousel.
    func cycleWindowPreview(reverse: Bool = false) {
        // Load windows on first call or when the selected app changed
        let currentPID = (selectedIndex >= 0 && selectedIndex < apps.count) ? apps[selectedIndex].processIdentifier : pid_t(0)
        if galleryWindows.isEmpty || galleryWindows.first?.pid != currentPID {
            loadGalleryWindows(for: selectedIndex)
            gallerySelectedIndex = 0  // Will advance to 1 (next window, not current)
        }
        guard !galleryWindows.isEmpty else { return }

        if reverse {
            gallerySelectedIndex = (gallerySelectedIndex - 1 + galleryWindows.count) % galleryWindows.count
        } else {
            gallerySelectedIndex = (gallerySelectedIndex + 1) % galleryWindows.count
        }

        showWindowPreview(at: gallerySelectedIndex, direction: reverse ? -1 : 1)
    }

    func showWindowPreview(at index: Int, direction: CGFloat = 0) {
        guard index >= 0, index < galleryWindows.count else { return }

        isPreviewingWindow = true

        if let stage = windowStage {
            if stage.layout == .carousel {
                if direction != 0 {
                    stage.cycle(direction: direction)
                }
            } else {
                stage.transitionTo(.carousel, animated: true, frontIndex: index)
            }
        }

        // Capture full-res async for the front window, then start live refresh.
        previewRefreshTimer?.invalidate()
        let windowID = galleryWindows[index].id
        let screen = selectorPanel?.screen ?? NSScreen.main ?? config.screen
        let maxW = screen.visibleFrame.width * 0.75
        let maxH = screen.visibleFrame.height * 0.75
        let captureSize = CGSize(width: maxW * 2, height: maxH * 2)
        let gen = selectionGeneration

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let nsImg = WindowScreenshot.capture(windowID: windowID, maxSize: captureSize) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.selectionGeneration == gen, self.isPreviewingWindow else { return }
                // Use forWindowID: so the image always goes to the correct panel,
                // even if frontSlotIndex has moved due to rapid backtick presses.
                self.windowStage?.updateImage(nsImg, forWindowID: windowID)

                // Live refresh at 200ms — only the front window, only when not animating
                self.previewRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    guard let self = self, self.isPreviewingWindow,
                          !(self.windowStage?.isAnimating ?? false) else { return }
                    let frontWID = self.windowStage?.frontWindow?.id ?? windowID
                    DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                        guard let nsImg = WindowScreenshot.capture(windowID: frontWID, maxSize: captureSize) else { return }
                        DispatchQueue.main.async { [weak self] in
                            self?.windowStage?.updateImage(nsImg, forWindowID: frontWID)
                        }
                    }
                }
            }
        }
    }

    /// Dismiss the carousel, returning to backdrop layout.
    func hideWindowPreview() {
        guard isPreviewingWindow else { return }
        isPreviewingWindow = false
        previewRefreshTimer?.invalidate()
        previewRefreshTimer = nil

        // Transition back to backdrop layout
        windowStage?.transitionTo(currentBackdropLayout, animated: true)

        // Keep HUD above
        selectorPanel?.orderFront(nil)
    }

    /// Animate the front panel from its carousel position to the target window's actual screen frame.
    func animatePreviewFlyout(to win: WindowInfo) {
        previewRefreshTimer?.invalidate()
        previewRefreshTimer = nil

        guard let stage = windowStage else { return }
        isPreviewingWindow = false

        // Convert CG coords (Y-down from top of main screen) to Cocoa coords (Y-up from bottom)
        let mainScreenH = NSScreen.screens.first?.frame.height ?? 1080
        let targetRect = NSRect(
            x: win.frame.origin.x,
            y: mainScreenH - win.frame.origin.y - win.frame.height,
            width: win.frame.width,
            height: win.frame.height
        )

        stage.flyOutFront(to: targetRect) {}
    }
}
