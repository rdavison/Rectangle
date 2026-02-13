//
//  AppSelectorPreview.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

extension AppSelectorWindow {

    /// Cycle through the selected app's windows, showing a large screenshot preview above the HUD.
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

        // Cancel any in-progress carousel animation — snap to final state
        if let timer = carouselTimer {
            timer.invalidate()
            carouselTimer = nil
            carouselOutgoing?.orderOut(nil)
            carouselOutgoing = nil
            // Snap incoming to its target (previewOverlay is already set to incoming)
        }

        isPreviewingWindow = true

        let win = galleryWindows[index]

        // Use cached low-res image immediately for responsive feel; full-res arrives async
        let initialImage: NSImage?
        if let cached = screenshotCache[win.id] {
            initialImage = NSImage(cgImage: cached, size: NSSize(width: CGFloat(cached.width), height: CGFloat(cached.height)))
        } else {
            initialImage = nil
        }

        // Calculate preview size: fit within 75% of screen, preserving aspect ratio
        let maxH = screen.visibleFrame.height * 0.75
        let maxW = screen.visibleFrame.width * 0.75
        let winAspect = win.frame.width / max(win.frame.height, 1)
        let previewW: CGFloat, previewH: CGFloat
        if winAspect > maxW / maxH {
            previewW = maxW; previewH = maxW / winAspect
        } else {
            previewH = maxH; previewW = maxH * winAspect
        }

        let panelRect = NSRect(
            x: screen.visibleFrame.midX - previewW / 2,
            y: screen.visibleFrame.midY - previewH / 2,
            width: previewW,
            height: previewH
        )

        if direction != 0, let oldOverlay = previewOverlay {
            // --- Elliptical carousel: both panels orbit along an ellipse ---
            previewOverlay = nil
            carouselOutgoing = oldOverlay

            // Snap old overlay to current target rect in case it was mid-animation
            oldOverlay.setFrame(panelRect, display: false)
            oldOverlay.alphaValue = 1

            // Create incoming panel at the "back" of the carousel (small, centered above, invisible)
            let newOverlay = makePreviewPanel(contentRect: panelRect, image: initialImage)
            newOverlay.alphaValue = 0
            newOverlay.orderFront(nil)
            // Keep old overlay in front initially
            oldOverlay.order(.above, relativeTo: newOverlay.windowNumber)
            previewOverlay = newOverlay

            // Ellipse parameters
            let a = panelRect.width * 0.35       // horizontal semi-axis
            let b: CGFloat = 70                  // vertical semi-axis (arc height)
            let backScale: CGFloat = 0.70        // scale at the "back" of the carousel
            let centerX = panelRect.midX
            let centerY = panelRect.midY
            let baseW = panelRect.width
            let baseH = panelRect.height
            let duration: TimeInterval = 0.3
            let startTime = CACurrentMediaTime()

            carouselTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }

                let elapsed = CACurrentMediaTime() - startTime
                let raw = min(CGFloat(elapsed / duration), 1.0)
                // Ease in-out (quadratic)
                let t = raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2

                // Outgoing traces θ from 0 → π (front → left/right → back)
                let outθ = t * .pi
                let outCX = centerX - direction * a * sin(outθ)
                let outCY = centerY + b * (1 - cos(outθ)) / 2
                let outScale = (1 + cos(outθ)) / 2 * (1 - backScale) + backScale
                let outW = baseW * outScale
                let outH = baseH * outScale
                oldOverlay.setFrame(NSRect(x: outCX - outW / 2, y: outCY - outH / 2,
                                           width: outW, height: outH), display: true)
                oldOverlay.alphaValue = max(1 - t * 1.5, 0)

                // Incoming traces θ from π → 2π (back → right/left → front)
                let inθ = .pi + t * .pi
                let inCX = centerX - direction * a * sin(inθ)
                let inCY = centerY + b * (1 - cos(inθ)) / 2
                let inScale = (1 + cos(inθ)) / 2 * (1 - backScale) + backScale
                let inW = baseW * inScale
                let inH = baseH * inScale
                newOverlay.setFrame(NSRect(x: inCX - inW / 2, y: inCY - inH / 2,
                                           width: inW, height: inH), display: true)
                newOverlay.alphaValue = min(t * 1.5, 1)

                // Swap z-order at the midpoint so incoming comes to front
                if t > 0.5 {
                    newOverlay.order(.above, relativeTo: oldOverlay.windowNumber)
                }

                if raw >= 1.0 {
                    timer.invalidate()
                    self.carouselTimer = nil
                    oldOverlay.orderOut(nil)
                    self.carouselOutgoing = nil
                    newOverlay.setFrame(panelRect, display: true)
                    newOverlay.alphaValue = 1
                }
            }

        } else if let overlay = previewOverlay {
            // Reuse existing panel — update frame and image (no animation)
            overlay.setFrame(panelRect, display: false)
            let contentFrame = NSRect(origin: .zero, size: panelRect.size)
            overlay.contentView?.frame = contentFrame
            if let imageView = overlay.contentView?.subviews.first as? NSImageView {
                if let img = initialImage { imageView.image = img }
                imageView.frame = contentFrame
            }
        } else {
            // First show — fade in
            let overlay = makePreviewPanel(contentRect: panelRect, image: initialImage)
            previewOverlay = overlay
            overlay.alphaValue = 0
            overlay.orderFront(nil)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                overlay.animator().alphaValue = 1
            }
        }

        // Raise the previewed window so it's visible behind the overlay
        raiseWindow(index)

        // Capture full-res async, then start live refresh timer
        previewRefreshTimer?.invalidate()
        let windowID = win.id
        let previewMaxSize = CGSize(width: screen.frame.width * 2, height: screen.frame.height * 2)
        let gen = selectionGeneration

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let t = CFAbsoluteTimeGetCurrent()
            guard let nsImg = WindowScreenshot.capture(windowID: windowID, maxSize: previewMaxSize) else { return }
            let capMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.selectionGeneration == gen, self.isPreviewingWindow else { return }
                perfLog("[perf] preview capture wid:\(windowID) \(String(format: "%.1f", capMs))ms (full-res, async)")
                if let imageView = self.previewOverlay?.contentView?.subviews.first as? NSImageView {
                    imageView.image = nsImg
                }

                // Now start live refresh
                self.previewRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self = self, self.isPreviewingWindow else { return }
                    DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                        guard let nsImg = WindowScreenshot.capture(windowID: windowID, maxSize: previewMaxSize) else { return }
                        DispatchQueue.main.async { [weak self] in
                            guard let overlay = self?.previewOverlay else { return }
                            if let imageView = overlay.contentView?.subviews.first as? NSImageView {
                                imageView.image = nsImg
                            }
                        }
                    }
                }
            }
        }
    }

    /// Create a preview overlay panel with the given frame and image.
    private func makePreviewPanel(contentRect: NSRect, image: NSImage?) -> NSPanel {
        let panel = NSPanel(contentRect: contentRect,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .canJoinAllSpaces]

        let contentFrame = NSRect(origin: .zero, size: contentRect.size)
        let imageView = NSImageView(frame: contentFrame)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        imageView.autoresizingMask = [.width, .height]

        let container = NSView(frame: contentFrame)
        container.wantsLayer = true
        container.shadow = NSShadow()
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.5
        container.layer?.shadowRadius = 20
        container.layer?.shadowOffset = CGSize(width: 0, height: -4)
        container.autoresizingMask = [.width, .height]
        container.addSubview(imageView)

        panel.contentView = container
        return panel
    }

    /// Dismiss the preview overlay.
    func hideWindowPreview() {
        guard isPreviewingWindow else { return }
        isPreviewingWindow = false
        previewRefreshTimer?.invalidate()
        previewRefreshTimer = nil
        carouselTimer?.invalidate()
        carouselTimer = nil
        carouselOutgoing?.orderOut(nil)
        carouselOutgoing = nil
        if let overlay = previewOverlay {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                overlay.animator().alphaValue = 0
            }, completionHandler: {
                overlay.orderOut(nil)
            })
            previewOverlay = nil
        }
    }

    /// Animate the preview overlay from its current large position to the target window's actual screen frame.
    func animatePreviewFlyout(to win: WindowInfo) {
        previewRefreshTimer?.invalidate()
        previewRefreshTimer = nil
        carouselTimer?.invalidate()
        carouselTimer = nil
        carouselOutgoing?.orderOut(nil)
        carouselOutgoing = nil

        // Detach the overlay so deactivate() doesn't tear it down
        guard let overlay = previewOverlay else { return }
        previewOverlay = nil
        isPreviewingWindow = false

        // Convert CG coords (Y-down from top of main screen) to Cocoa coords (Y-up from bottom)
        let mainScreenH = NSScreen.screens.first?.frame.height ?? 1080
        let targetRect = NSRect(
            x: win.frame.origin.x,
            y: mainScreenH - win.frame.origin.y - win.frame.height,
            width: win.frame.width,
            height: win.frame.height
        )

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlay.animator().setFrame(targetRect, display: true)
            overlay.animator().alphaValue = 0
        }, completionHandler: {
            overlay.orderOut(nil)
        })
    }
}
