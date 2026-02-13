//
//  WindowStage.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

/// Unified panel pool that renders windows in 4 layout modes.
/// Manages up to `maxPanels` NSPanels, repositioning them for each mode.
/// Carousel mode uses CVDisplayLink-driven elliptical animation with z-crossing.
class WindowStage {

    enum Layout {
        case cascade
        case expose
        case ring
        case carousel
    }

    struct Config {
        let screen: NSScreen
        let hudLevel: NSWindow.Level   // .popUpMenu
    }

    /// Computed pose for one panel slot.
    private struct PanelPose {
        let frame: NSRect
        let alpha: CGFloat
        let isFront: Bool     // above vs below HUD
        let zOrder: CGFloat   // stacking within front/back group
        let shadowOpacity: Float
        let shadowRadius: CGFloat
    }

    /// One slot per window.
    private struct Slot {
        let windowInfo: WindowInfo
        var cachedImage: NSImage?
        var angle: CGFloat        // used by carousel mode
        var wasFront: Bool = false
    }

    // MARK: - Public State

    private(set) var layout: Layout = .cascade
    private(set) var frontSlotIndex: Int = 0
    var isAnimating: Bool { animRunning }

    var frontWindow: WindowInfo? {
        guard !slots.isEmpty, frontSlotIndex < slots.count else { return nil }
        return slots[frontSlotIndex].windowInfo
    }

    var isEmpty: Bool { slots.isEmpty }
    var windowCount: Int { slots.count }

    // MARK: - Private State

    private let maxPanels = 8
    private var panels: [NSPanel] = []
    private var slots: [Slot] = []
    private var config: Config

    // Window levels
    private var frontLevel: NSWindow.Level { NSWindow.Level(rawValue: config.hudLevel.rawValue + 1) }
    private var backLevel: NSWindow.Level { NSWindow.Level(rawValue: config.hudLevel.rawValue - 1) }

    // CVDisplayLink animation
    private var displayLink: CVDisplayLink?
    private var animStartTime: CFTimeInterval = 0
    private var animDuration: TimeInterval = 0
    private var animRunning = false
    private var animCompletion: (() -> Void)?

    // Carousel animation: per-slot angle interpolation
    private var animStartAngles: [CGFloat] = []
    private var animDeltaPerSlot: [CGFloat] = []

    // Transition animation: interpolate from one pose set to another
    private var animFromPoses: [PanelPose] = []
    private var animToPoses: [PanelPose] = []
    private var animIsTransition = false

    // Carousel geometry
    private var carouselCenterX: CGFloat = 0
    private var carouselCenterY: CGFloat = 0
    private var carouselARadius: CGFloat = 0
    private var carouselBRadius: CGFloat = 0
    private var carouselBaseW: CGFloat = 0
    private var carouselBaseH: CGFloat = 0
    private var carouselBackScale: CGFloat = 0.55

    init(config: Config) {
        self.config = config
    }

    deinit {
        stopDisplayLink()
    }

    // MARK: - Show

    func show(windows: [WindowInfo], layout: Layout, initialFrontIndex: Int,
              cache: [CGWindowID: CGImage], animated: Bool, direction: CGFloat = 0) {
        tearDownImmediate()

        self.layout = layout
        guard !windows.isEmpty else { return }

        let n = min(windows.count, maxPanels)

        if layout == .carousel {
            computeCarouselGeometry()
            let angleStep = 2 * CGFloat.pi / CGFloat(n)
            slots = (0..<n).map { i in
                let win = windows[i]
                let offsetFromFront = (i - initialFrontIndex + n) % n
                let finalAngle = CGFloat(offsetFromFront) * angleStep
                let startAngle = animated ? finalAngle + .pi : finalAngle
                let nsImage = imageFromCache(win.id, cache: cache)
                return Slot(windowInfo: win, cachedImage: nsImage, angle: startAngle, wasFront: false)
            }
            frontSlotIndex = initialFrontIndex

            panels = (0..<n).map { i in makePanel(image: slots[i].cachedImage) }
            updatePanelPosesCarousel()
            for panel in panels { panel.orderFront(nil) }

            if animated {
                animStartTime = CACurrentMediaTime()
                animDuration = 0.35
                animStartAngles = slots.map { $0.angle }
                animDeltaPerSlot = Array(repeating: -.pi, count: slots.count)
                animIsTransition = false
                animRunning = true
                startDisplayLink()
            }
        } else {
            slots = (0..<n).map { i in
                let win = windows[i]
                let nsImage = imageFromCache(win.id, cache: cache)
                return Slot(windowInfo: win, cachedImage: nsImage, angle: 0, wasFront: false)
            }
            frontSlotIndex = initialFrontIndex

            panels = (0..<n).map { i in makePanel(image: slots[i].cachedImage) }
            let poses = computeBackdropPoses()
            applyPoses(poses, animated: false)
            for panel in panels { panel.orderFront(nil) }

            if animated && direction != 0 {
                slideInBackdrop(direction: direction)
            }
        }
    }

    // MARK: - Transition Between Modes

    func transitionTo(_ newLayout: Layout, animated: Bool) {
        guard !slots.isEmpty else { return }
        let oldLayout = layout

        // If moving to carousel, compute geometry first
        if newLayout == .carousel {
            computeCarouselGeometry()
        }

        // Capture current poses
        let fromPoses: [PanelPose]
        if oldLayout == .carousel {
            fromPoses = currentCarouselPoses()
        } else {
            fromPoses = computeBackdropPoses()
        }

        // Set new layout
        layout = newLayout

        // Compute target poses
        let toPoses: [PanelPose]
        if newLayout == .carousel {
            // Set up carousel angles for target
            let n = slots.count
            let angleStep = 2 * CGFloat.pi / CGFloat(n)
            for i in 0..<n {
                let offsetFromFront = (i - frontSlotIndex + n) % n
                slots[i].angle = CGFloat(offsetFromFront) * angleStep
            }
            toPoses = currentCarouselPoses()
        } else {
            toPoses = computeBackdropPoses()
        }

        if animated && panels.count == toPoses.count {
            // Disable shadows during transition
            for panel in panels { panel.hasShadow = false }

            animFromPoses = fromPoses
            animToPoses = toPoses
            animIsTransition = true
            animStartTime = CACurrentMediaTime()
            animDuration = 0.35
            animRunning = true
            startDisplayLink()
        } else {
            applyPoses(toPoses, animated: false)
        }
    }

    // MARK: - Replace Windows (same layout)

    func replaceWindows(_ windows: [WindowInfo], cache: [CGWindowID: CGImage],
                        animated: Bool, direction: CGFloat = 0) {
        guard !windows.isEmpty else {
            tearDownImmediate()
            return
        }

        let n = min(windows.count, maxPanels)

        // Rebuild slots preserving layout
        slots = (0..<n).map { i in
            let win = windows[i]
            let nsImage = imageFromCache(win.id, cache: cache)
            return Slot(windowInfo: win, cachedImage: nsImage, angle: 0, wasFront: false)
        }
        frontSlotIndex = 0

        // Ensure correct panel count
        adjustPanelCount(to: n)

        // Update images
        for i in 0..<n {
            setImage(slots[i].cachedImage, onPanel: panels[i])
        }

        if layout == .carousel {
            computeCarouselGeometry()
            let angleStep = 2 * CGFloat.pi / CGFloat(n)
            for i in 0..<n {
                slots[i].angle = CGFloat(i) * angleStep
            }
            updatePanelPosesCarousel()
        } else {
            let poses = computeBackdropPoses()
            applyPoses(poses, animated: false)

            if animated && direction != 0 {
                slideInBackdrop(direction: direction)
            }
        }
    }

    // MARK: - Carousel Cycling

    func cycle(direction: CGFloat, duration: TimeInterval = 0.35) {
        guard layout == .carousel, slots.count > 1 else { return }

        // Cancel any in-progress animation, snap to current interpolated positions
        if animRunning {
            animRunning = false
            stopDisplayLink()
            normalizeAngles()
        }

        let n = slots.count
        let angleStep = 2 * CGFloat.pi / CGFloat(n)
        let delta = -direction * angleStep

        for panel in panels { panel.hasShadow = false }

        animStartTime = CACurrentMediaTime()
        animDuration = duration
        animStartAngles = slots.map { $0.angle }
        animDeltaPerSlot = Array(repeating: delta, count: n)
        animIsTransition = false
        animRunning = true
        startDisplayLink()

        // Eagerly update front slot index
        if direction > 0 {
            frontSlotIndex = (frontSlotIndex + 1) % n
        } else {
            frontSlotIndex = (frontSlotIndex - 1 + n) % n
        }
    }

    // MARK: - Tear Down

    func tearDown(animated: Bool) {
        animRunning = false
        stopDisplayLink()

        if animated {
            let panelsToRemove = panels
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                for panel in panelsToRemove {
                    panel.animator().alphaValue = 0
                }
            }, completionHandler: {
                for panel in panelsToRemove {
                    panel.orderOut(nil)
                }
            })
        } else {
            for panel in panels {
                panel.orderOut(nil)
            }
        }

        panels = []
        slots = []
        frontSlotIndex = 0
    }

    private func tearDownImmediate() {
        animRunning = false
        stopDisplayLink()
        for panel in panels { panel.orderOut(nil) }
        panels = []
        slots = []
        frontSlotIndex = 0
    }

    // MARK: - Image Updates

    func updateImage(_ image: NSImage, forWindowID windowID: CGWindowID) {
        guard let i = slots.firstIndex(where: { $0.windowInfo.id == windowID }) else { return }
        slots[i].cachedImage = image
        if i < panels.count {
            setImage(image, onPanel: panels[i])
        }
    }

    func updateFrontImage(_ image: NSImage) {
        guard !slots.isEmpty, frontSlotIndex < slots.count else { return }
        slots[frontSlotIndex].cachedImage = image
        if frontSlotIndex < panels.count {
            setImage(image, onPanel: panels[frontSlotIndex])
        }
    }

    /// Update image at a specific slot index (for backdrop mode where index == display order).
    func updateImage(_ image: NSImage, at index: Int) {
        guard index >= 0, index < slots.count else { return }
        slots[index].cachedImage = image
        if index < panels.count {
            setImage(image, onPanel: panels[index])
        }
    }

    // MARK: - Fly-out Animations

    /// Carousel confirm: fly the front panel to the target rect, fade others.
    func flyOutFront(to targetRect: NSRect, completion: @escaping () -> Void) {
        animRunning = false
        stopDisplayLink()

        guard !panels.isEmpty else {
            completion()
            return
        }

        let frontPanel = frontSlotIndex < panels.count ? panels[frontSlotIndex] : nil
        let otherPanels = panels.filter { $0 !== frontPanel }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            frontPanel?.animator().setFrame(targetRect, display: true)
            frontPanel?.animator().alphaValue = 0
            for panel in otherPanels {
                panel.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            for panel in self.panels { panel.orderOut(nil) }
            self.panels = []
            self.slots = []
            completion()
        })
    }

    /// Backdrop confirm: fly all panels to their real window positions.
    func flyOutAll(windowFrames: [CGRect], completion: @escaping () -> Void) {
        animRunning = false
        stopDisplayLink()

        guard !panels.isEmpty else {
            completion()
            return
        }

        let mainScreenH = NSScreen.screens.first?.frame.height ?? 1080

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for i in 0..<min(panels.count, windowFrames.count) {
                let target = windowFrames[i]
                // Convert CG coords to Cocoa coords
                let cocoaRect = NSRect(
                    x: target.origin.x,
                    y: mainScreenH - target.origin.y - target.height,
                    width: target.width,
                    height: target.height
                )
                panels[i].animator().setFrame(cocoaRect, display: true)
                panels[i].animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            for panel in self.panels { panel.orderOut(nil) }
            self.panels = []
            self.slots = []
            completion()
        })
    }

    // MARK: - Panel Factory

    private func makePanel(image: NSImage?) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.level = backLevel
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .canJoinAllSpaces]

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.autoresizingMask = [.width, .height]

        let container = NSView()
        container.wantsLayer = true
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.5
        container.layer?.shadowRadius = 20
        container.layer?.shadowOffset = CGSize(width: 0, height: -4)
        container.autoresizingMask = [.width, .height]
        container.addSubview(imageView)

        panel.contentView = container
        return panel
    }

    private func setImage(_ image: NSImage?, onPanel panel: NSPanel) {
        if let imageView = panel.contentView?.subviews.first as? NSImageView {
            imageView.image = image
        }
    }

    private func adjustPanelCount(to n: Int) {
        while panels.count > n {
            let p = panels.removeLast()
            p.orderOut(nil)
        }
        while panels.count < n {
            let i = panels.count
            let img = i < slots.count ? slots[i].cachedImage : nil
            let p = makePanel(image: img)
            p.orderFront(nil)
            panels.append(p)
        }
    }

    private func imageFromCache(_ windowID: CGWindowID, cache: [CGWindowID: CGImage]) -> NSImage? {
        guard let cg = cache[windowID] else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
    }

    // MARK: - Carousel Geometry

    private func computeCarouselGeometry() {
        let screen = config.screen
        let visFrame = screen.visibleFrame

        // Fit preview within 75% of screen, preserving aspect ratio of the front window
        let maxH = visFrame.height * 0.75
        let maxW = visFrame.width * 0.75

        // Use front window's aspect ratio if available, else assume 16:9
        let aspect: CGFloat
        if !slots.isEmpty, frontSlotIndex < slots.count {
            let f = slots[frontSlotIndex].windowInfo.frame
            aspect = f.width / max(f.height, 1)
        } else {
            aspect = 16.0 / 9.0
        }

        let previewW: CGFloat, previewH: CGFloat
        if aspect > maxW / maxH {
            previewW = maxW; previewH = maxW / aspect
        } else {
            previewH = maxH; previewW = maxH * aspect
        }

        carouselCenterX = visFrame.midX
        carouselCenterY = visFrame.midY
        carouselARadius = previewW * 0.25
        carouselBRadius = 80
        carouselBaseW = previewW
        carouselBaseH = previewH
        carouselBackScale = 0.55
    }

    // MARK: - Carousel Pose Computation

    private func computeCarouselFrame(theta: CGFloat) -> (frame: NSRect, isFront: Bool, alpha: CGFloat) {
        let cosθ = cos(theta)
        let sinθ = sin(theta)
        let cx = carouselCenterX + carouselARadius * sinθ
        let cy = carouselCenterY + carouselBRadius * cosθ
        let scale = (1 + cosθ) * 0.5 * (1 - carouselBackScale) + carouselBackScale
        let w = carouselBaseW * scale
        let h = carouselBaseH * scale
        let crossoverWidth: CGFloat = 0.3
        let alpha = min(1.0, abs(cosθ) / crossoverWidth)
        return (NSRect(x: cx - w * 0.5, y: cy - h * 0.5, width: w, height: h), cosθ > 0, alpha)
    }

    private func currentCarouselPoses() -> [PanelPose] {
        return slots.enumerated().map { i, slot in
            let (frame, isFront, alpha) = computeCarouselFrame(theta: slot.angle)
            let distFromFront = angularDistFromFront(slot.angle)
            return PanelPose(
                frame: frame,
                alpha: alpha,
                isFront: isFront,
                zOrder: CGFloat.pi - distFromFront,
                shadowOpacity: 0.5,
                shadowRadius: 20
            )
        }
    }

    private func updatePanelPosesCarousel() {
        let n = min(panels.count, slots.count)
        guard n > 0 else { return }

        var zOrderChanged = false

        for i in 0..<n {
            let (frame, isFront, alpha) = computeCarouselFrame(theta: slots[i].angle)
            let panel = panels[i]

            panel.setFrame(frame, display: false)
            panel.alphaValue = alpha
            panel.level = isFront ? frontLevel : backLevel

            if slots[i].wasFront != isFront {
                slots[i].wasFront = isFront
                zOrderChanged = true
            }
        }

        if zOrderChanged {
            let byDepth = (0..<n).sorted {
                angularDistFromFront(slots[$0].angle) > angularDistFromFront(slots[$1].angle)
            }
            for j in 1..<byDepth.count {
                panels[byDepth[j]].order(.above, relativeTo: panels[byDepth[j - 1]].windowNumber)
            }
        }
    }

    // MARK: - Backdrop Pose Computation

    private func computeBackdropPoses() -> [PanelPose] {
        let screen = config.screen
        let visFrame = screen.visibleFrame

        switch layout {
        case .cascade:
            return cascadePoses(visFrame: visFrame)
        case .expose:
            return exposePoses(visFrame: visFrame)
        case .ring:
            return ringPoses(visFrame: visFrame)
        case .carousel:
            return currentCarouselPoses()
        }
    }

    private func cascadePoses(visFrame: NSRect) -> [PanelPose] {
        let count = slots.count
        guard count > 0 else { return [] }

        let availableW = visFrame.width * 0.85
        let availableH = visFrame.height * 0.45
        let maxCardW = min(availableW / CGFloat(count) - 16, 420)
        let maxCardH = min(availableH, 300)
        let cx = visFrame.midX
        let cy = visFrame.minY + visFrame.height * 0.62

        return (0..<count).map { i in
            let winFrame = slots[i].windowInfo.frame
            let aspect = winFrame.width / max(winFrame.height, 1)
            let w: CGFloat, h: CGFloat
            if aspect > maxCardW / maxCardH {
                w = maxCardW; h = maxCardW / aspect
            } else {
                h = maxCardH; w = maxCardH * aspect
            }

            let totalW = CGFloat(count) * (maxCardW + 16) - 16
            let startX = cx - totalW / 2
            let cardCX = startX + (CGFloat(i) + 0.5) * (maxCardW + 16)

            return PanelPose(
                frame: NSRect(x: cardCX - w / 2, y: cy - h / 2, width: w, height: h),
                alpha: 1.0,
                isFront: false,
                zOrder: CGFloat(count - i),
                shadowOpacity: 0.7,
                shadowRadius: 20
            )
        }
    }

    private func exposePoses(visFrame: NSRect) -> [PanelPose] {
        let count = slots.count
        guard count > 0 else { return [] }

        let sceneW = visFrame.width * 0.85
        let sceneH = visFrame.height * 0.75
        let padding: CGFloat = 20

        var bestCols = 1
        var bestCellSize: CGFloat = 0
        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let cellW = sceneW / CGFloat(cols) - padding
            let cellH = sceneH / CGFloat(rows) - padding
            let cellSize = min(cellW, cellH)
            if cellSize > bestCellSize {
                bestCellSize = cellSize
                bestCols = cols
            }
        }

        let cols = bestCols
        let rows = Int(ceil(Double(count) / Double(cols)))
        let cellW = sceneW / CGFloat(cols)
        let cellH = sceneH / CGFloat(rows)

        let gridW = CGFloat(cols) * cellW
        let gridH = CGFloat(rows) * cellH
        let originX = visFrame.midX - gridW / 2
        let originY = visFrame.minY + visFrame.height * 0.72 - gridH / 2

        return (0..<count).map { i in
            let col = i % cols
            let row = i / cols
            let winFrame = slots[i].windowInfo.frame

            let aspect = winFrame.width / max(winFrame.height, 1)
            let maxW = cellW - padding
            let maxH = cellH - padding
            let w: CGFloat, h: CGFloat
            if aspect > maxW / maxH {
                w = maxW; h = maxW / aspect
            } else {
                h = maxH; w = maxH * aspect
            }

            let cx = originX + (CGFloat(col) + 0.5) * cellW
            let cy = originY + (CGFloat(rows - 1 - row) + 0.5) * cellH

            return PanelPose(
                frame: NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
                alpha: 1.0,
                isFront: false,
                zOrder: CGFloat(count - i),
                shadowOpacity: 0.4,
                shadowRadius: 12
            )
        }
    }

    private func ringPoses(visFrame: NSRect) -> [PanelPose] {
        let cardMaxW: CGFloat = 300
        let cardMaxH: CGFloat = 220
        let count = slots.count
        guard count > 0 else { return [] }

        let radius: CGFloat = min(max(CGFloat(count) * 40, 250), 400)
        let cx = visFrame.midX
        let cy = visFrame.minY + visFrame.height * 0.72

        return (0..<count).map { i in
            let winFrame = slots[i].windowInfo.frame
            let aspect = winFrame.width / max(winFrame.height, 1)
            let w: CGFloat, h: CGFloat
            if aspect > cardMaxW / cardMaxH {
                w = cardMaxW; h = cardMaxW / aspect
            } else {
                h = cardMaxH; w = cardMaxH * aspect
            }

            let angle = CGFloat(i) * 2 * .pi / CGFloat(count)
            let cosA = cos(angle)
            let sinA = sin(angle)

            // Approximate Y-rotation with scale+position
            let depthScale = (1 + cosA) * 0.5 * 0.5 + 0.5  // 0.5 (back) → 1.0 (front)
            let scaledW = w * depthScale
            let scaledH = h * depthScale
            let px = cx + sinA * radius
            let py = cy + cosA * 30  // slight vertical shift for depth

            let alpha = (1 + cosA) * 0.5 * 0.6 + 0.4  // 0.4 (back) → 1.0 (front)

            return PanelPose(
                frame: NSRect(x: px - scaledW / 2, y: py - scaledH / 2, width: scaledW, height: scaledH),
                alpha: CGFloat(alpha),
                isFront: false,
                zOrder: cosA,  // depth-based stacking
                shadowOpacity: 0.6,
                shadowRadius: 18
            )
        }
    }

    // MARK: - Apply Poses

    private func applyPoses(_ poses: [PanelPose], animated: Bool) {
        let n = min(panels.count, poses.count)
        guard n > 0 else { return }

        for i in 0..<n {
            let pose = poses[i]
            let panel = panels[i]

            panel.setFrame(pose.frame, display: false)
            panel.alphaValue = pose.alpha
            panel.level = pose.isFront ? frontLevel : backLevel
            panel.hasShadow = !animRunning
        }

        // Stack by zOrder (lowest first = back)
        let sorted = (0..<n).sorted { poses[$0].zOrder < poses[$1].zOrder }
        for j in 1..<sorted.count {
            panels[sorted[j]].order(.above, relativeTo: panels[sorted[j - 1]].windowNumber)
        }
    }

    private func interpolatePoses(from: [PanelPose], to: [PanelPose], t: CGFloat) -> [PanelPose] {
        let n = min(from.count, to.count)
        return (0..<n).map { i in
            let f = from[i]
            let t2 = to[i]
            let frame = NSRect(
                x: f.frame.origin.x + (t2.frame.origin.x - f.frame.origin.x) * t,
                y: f.frame.origin.y + (t2.frame.origin.y - f.frame.origin.y) * t,
                width: f.frame.width + (t2.frame.width - f.frame.width) * t,
                height: f.frame.height + (t2.frame.height - f.frame.height) * t
            )
            // Use target's isFront when past halfway (for level switching)
            let isFront = t > 0.5 ? t2.isFront : f.isFront
            return PanelPose(
                frame: frame,
                alpha: f.alpha + (t2.alpha - f.alpha) * t,
                isFront: isFront,
                zOrder: f.zOrder + (t2.zOrder - f.zOrder) * t,
                shadowOpacity: f.shadowOpacity + (t2.shadowOpacity - f.shadowOpacity) * Float(t),
                shadowRadius: f.shadowRadius + (t2.shadowRadius - f.shadowRadius) * t
            )
        }
    }

    // MARK: - Backdrop Slide-in Animation

    private func slideInBackdrop(direction: CGFloat) {
        let poses = computeBackdropPoses()
        let n = min(panels.count, poses.count)
        guard n > 0 else { return }

        // Build "from" poses offset by direction
        let fromPoses: [PanelPose] = poses.enumerated().map { i, pose in
            var offsetFrame = pose.frame
            switch layout {
            case .cascade:
                offsetFrame.origin.x += direction * 250
            case .expose:
                let dw = pose.frame.width * 0.2
                let dh = pose.frame.height * 0.2
                offsetFrame = offsetFrame.insetBy(dx: dw / 2, dy: dh / 2)
            case .ring:
                offsetFrame.origin.x += direction * 100
            case .carousel:
                break
            }
            return PanelPose(
                frame: offsetFrame,
                alpha: 0,
                isFront: pose.isFront,
                zOrder: pose.zOrder,
                shadowOpacity: pose.shadowOpacity,
                shadowRadius: pose.shadowRadius
            )
        }

        // Apply start poses
        applyPoses(fromPoses, animated: false)

        // Animate to final
        animFromPoses = fromPoses
        animToPoses = poses
        animIsTransition = true
        animStartTime = CACurrentMediaTime()
        animDuration = 0.3
        animRunning = true
        startDisplayLink()
    }

    // MARK: - CVDisplayLink

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link = link else { return }

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
            let stage = Unmanaged<WindowStage>.fromOpaque(userInfo!).takeUnretainedValue()
            DispatchQueue.main.async { stage.displayLinkTick() }
            return kCVReturnSuccess
        }, selfPtr)
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    private func displayLinkTick() {
        guard animRunning else { return }

        let elapsed = CACurrentMediaTime() - animStartTime
        let raw = min(CGFloat(elapsed / animDuration), 1.0)
        // Ease in-out (quadratic)
        let t = raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2

        if animIsTransition {
            let interpolated = interpolatePoses(from: animFromPoses, to: animToPoses, t: t)
            applyPoses(interpolated, animated: true)
        } else {
            // Carousel angle-based animation
            for i in slots.indices {
                slots[i].angle = animStartAngles[i] + animDeltaPerSlot[i] * t
            }
            updatePanelPosesCarousel()
        }

        if raw >= 1.0 {
            animRunning = false
            stopDisplayLink()

            if animIsTransition {
                applyPoses(animToPoses, animated: false)
                animFromPoses = []
                animToPoses = []
                animIsTransition = false
            } else {
                normalizeAngles()
                updateFrontSlotIndex()
                updatePanelPosesCarousel()
            }

            // Re-enable shadows
            for panel in panels { panel.hasShadow = true }
            animCompletion?()
            animCompletion = nil
        }
    }

    // MARK: - Angle Helpers

    private func normalizeAngles() {
        let twoPi = 2 * CGFloat.pi
        for i in slots.indices {
            var a = slots[i].angle.truncatingRemainder(dividingBy: twoPi)
            if a < 0 { a += twoPi }
            slots[i].angle = a
        }
    }

    private func updateFrontSlotIndex() {
        guard !slots.isEmpty else { return }
        var bestIndex = 0
        var bestDist = angularDistFromFront(slots[0].angle)
        for i in 1..<slots.count {
            let dist = angularDistFromFront(slots[i].angle)
            if dist < bestDist {
                bestDist = dist
                bestIndex = i
            }
        }
        frontSlotIndex = bestIndex
    }

    private func angularDistFromFront(_ angle: CGFloat) -> CGFloat {
        let twoPi = 2 * CGFloat.pi
        var d = angle.truncatingRemainder(dividingBy: twoPi)
        if d < 0 { d += twoPi }
        return d > .pi ? twoPi - d : d
    }
}
