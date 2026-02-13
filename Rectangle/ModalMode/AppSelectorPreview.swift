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
        guard let screen = selectorPanel?.screen ?? NSScreen.main else { return }
        guard index >= 0, index < galleryWindows.count else { return }

        isPreviewingWindow = true

        // Calculate preview size: fit within 75% of screen, preserving aspect ratio
        let win = galleryWindows[index]
        let maxH = screen.visibleFrame.height * 0.75
        let maxW = screen.visibleFrame.width * 0.75
        let winAspect = win.frame.width / max(win.frame.height, 1)
        let previewW: CGFloat, previewH: CGFloat
        if winAspect > maxW / maxH {
            previewW = maxW; previewH = maxW / winAspect
        } else {
            previewH = maxH; previewW = maxH * winAspect
        }

        let config = WindowCarousel.Config(
            centerX: screen.visibleFrame.midX,
            centerY: screen.visibleFrame.midY,
            aRadius: previewW * 0.25,
            bRadius: 80,
            baseW: previewW,
            baseH: previewH,
            backScale: 0.55
        )

        if let carousel = windowCarousel {
            // Carousel already exists — cycle it
            carouselLog("[carousel] cycle direction=\(direction) frontSlot=\(carousel.frontSlotIndex) windowCount=\(carousel.windowCount)")
            if direction != 0 {
                carousel.cycle(direction: direction)
            }
        } else {
            // First show — create carousel with entry animation
            let carousel = WindowCarousel(config: config)
            windowCarousel = carousel

            let windowIDs = galleryWindows.map { "wid:\($0.id)" }
            carouselLog("[carousel] setUp \(galleryWindows.count) windows [\(windowIDs.joined(separator: ", "))] initialFront=\(index) config=(cx=\(Int(config.centerX)) cy=\(Int(config.centerY)) base=\(Int(config.baseW))x\(Int(config.baseH)))")

            // Hide backdrop panel — orderOut is required because
            // NSVisualEffectView ignores alphaValue animation
            backdropPanel?.orderOut(nil)

            carousel.setUpWithEntryAnimation(
                windows: galleryWindows,
                initialFrontIndex: index,
                cache: screenshotCache,
                config: config
            )

            // Keep HUD above carousel
            selectorPanel?.orderFront(nil)
        }

        // Capture full-res async for the front window, then start live refresh.
        // Cap at the actual preview panel size (retina 2x) — no need for full screen resolution.
        previewRefreshTimer?.invalidate()
        let windowID = galleryWindows[index].id
        let captureSize = CGSize(width: previewW * 2, height: previewH * 2)
        let gen = selectionGeneration

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let nsImg = WindowScreenshot.capture(windowID: windowID, maxSize: captureSize) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.selectionGeneration == gen, self.isPreviewingWindow else { return }
                self.windowCarousel?.updateFrontImage(nsImg)

                // Live refresh at 200ms — only the front window, only when not animating
                self.previewRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    guard let self = self, self.isPreviewingWindow,
                          !(self.windowCarousel?.isAnimating ?? false) else { return }
                    let frontWID = self.windowCarousel?.frontWindow?.id ?? windowID
                    DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                        guard let nsImg = WindowScreenshot.capture(windowID: frontWID, maxSize: captureSize) else { return }
                        DispatchQueue.main.async { [weak self] in
                            self?.windowCarousel?.updateFrontImage(nsImg)
                        }
                    }
                }
            }
        }
    }

    /// Dismiss the carousel.
    func hideWindowPreview() {
        guard isPreviewingWindow else { return }
        isPreviewingWindow = false
        previewRefreshTimer?.invalidate()
        previewRefreshTimer = nil
        windowCarousel?.tearDown(animated: true)
        windowCarousel = nil

        // Restore backdrop panel
        if let backdrop = backdropPanel {
            backdrop.alphaValue = 1.0
            backdrop.orderFront(nil)
            selectorPanel?.orderFront(nil)  // Keep HUD above backdrop
        }
    }

    /// Animate the front panel from its carousel position to the target window's actual screen frame.
    func animatePreviewFlyout(to win: WindowInfo) {
        previewRefreshTimer?.invalidate()
        previewRefreshTimer = nil

        guard let carousel = windowCarousel else { return }
        windowCarousel = nil
        isPreviewingWindow = false

        // Convert CG coords (Y-down from top of main screen) to Cocoa coords (Y-up from bottom)
        let mainScreenH = NSScreen.screens.first?.frame.height ?? 1080
        let targetRect = NSRect(
            x: win.frame.origin.x,
            y: mainScreenH - win.frame.origin.y - win.frame.height,
            width: win.frame.width,
            height: win.frame.height
        )

        carousel.flyOutFront(to: targetRect) {}
    }
}
