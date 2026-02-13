//
//  WindowCarousel.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

/// Append a line to /tmp/rectangle-carousel.log for debugging.
func carouselLog(_ message: String) {
    perfLog(message)
    let line = "\(Date()): \(message)\n"
    let path = "/tmp/rectangle-carousel.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

/// Manages a pool of NSPanels positioned along an elliptical track (merry-go-round).
/// Each window gets its own panel, enabling true z-crossing through the HUD.
/// The front window is large and above the HUD; back windows are small and behind it.
class WindowCarousel {

    struct Config {
        let centerX: CGFloat
        let centerY: CGFloat
        let aRadius: CGFloat      // horizontal semi-axis (lateral sway)
        let bRadius: CGFloat      // vertical semi-axis (depth travel)
        let baseW: CGFloat        // full-size preview width
        let baseH: CGFloat        // full-size preview height
        let backScale: CGFloat    // scale at back (θ=π)
    }

    /// One slot per window in the carousel ring.
    private struct Slot {
        let windowInfo: WindowInfo
        var cachedImage: NSImage?
        var angle: CGFloat        // current angle on the ellipse (0 = front, π = back)
        var wasFront: Bool = false // previous frame's front/back state (for z-order change detection)
    }

    static let frontLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    static let backLevel  = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

    private var slots: [Slot] = []
    private let maxPanels = 7
    private var panels: [NSPanel] = []
    private var config: Config
    private var displayLink: CVDisplayLink?

    // Animation state — set when an animation is active
    private var animStartTime: CFTimeInterval = 0
    private var animDuration: TimeInterval = 0
    private var animStartAngles: [CGFloat] = []
    private var animDeltaPerSlot: [CGFloat] = []  // per-slot delta (same for cycle, per-slot for entry)
    private var animCompletion: (() -> Void)?
    private var animRunning = false

    /// Index of the slot currently at the front (θ closest to 0).
    private(set) var frontSlotIndex: Int = 0

    /// The window info of the front slot.
    var frontWindow: WindowInfo? {
        guard !slots.isEmpty else { return nil }
        return slots[frontSlotIndex].windowInfo
    }

    var isEmpty: Bool { slots.isEmpty }
    var windowCount: Int { slots.count }

    /// Whether an animation is currently running.
    var isAnimating: Bool { animRunning }

    init(config: Config) {
        self.config = config
    }

    deinit {
        stopDisplayLink()
    }

    // MARK: - Pose Computation (inlined for hot path)

    /// Compute frame and isFront for a given angle. Minimal work — no allocations.
    private func computeFrame(theta: CGFloat) -> (frame: NSRect, isFront: Bool) {
        let cosθ = cos(theta)
        let sinθ = sin(theta)
        let cx = config.centerX + config.aRadius * sinθ
        let cy = config.centerY + config.bRadius * cosθ
        let scaleFactor = config.backScale
        let scale = (1 + cosθ) * 0.5 * (1 - scaleFactor) + scaleFactor
        let w = config.baseW * scale
        let h = config.baseH * scale
        return (NSRect(x: cx - w * 0.5, y: cy - h * 0.5, width: w, height: h), cosθ > 0)
    }

    // MARK: - Panel Factory

    private func makePanel(image: NSImage?) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.level = Self.backLevel
        panel.hasShadow = false          // shadows are expensive during animation
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

    // MARK: - CVDisplayLink

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link = link else { return }

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
            let carousel = Unmanaged<WindowCarousel>.fromOpaque(userInfo!).takeUnretainedValue()
            DispatchQueue.main.async { carousel.displayLinkTick() }
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

        for i in slots.indices {
            slots[i].angle = animStartAngles[i] + animDeltaPerSlot[i] * t
        }
        updatePanelPoses()

        if raw >= 1.0 {
            animRunning = false
            stopDisplayLink()
            normalizeAngles()
            updateFrontSlotIndex()
            updatePanelPoses()
            // Re-enable shadows now that animation is done
            for panel in panels { panel.hasShadow = true }
            animCompletion?()
            animCompletion = nil
            logSlotState("animation end")
        }
    }

    // MARK: - Setup

    /// Set up with an entry animation: all windows start at back (θ=π), and the
    /// target window animates to front over duration.
    func setUpWithEntryAnimation(windows: [WindowInfo], initialFrontIndex: Int,
                                  cache: [CGWindowID: CGImage], config: Config,
                                  duration: TimeInterval = 0.35) {
        self.config = config
        tearDownImmediate()

        guard !windows.isEmpty else { return }

        let n = windows.count
        let angleStep = 2 * CGFloat.pi / CGFloat(n)

        // Build slots — all start at their "final" positions offset by π (at back)
        slots = windows.enumerated().map { (i, win) in
            let offsetFromFront = (i - initialFrontIndex + n) % n
            let finalAngle = CGFloat(offsetFromFront) * angleStep
            let nsImage: NSImage?
            if let cached = cache[win.id] {
                nsImage = NSImage(cgImage: cached, size: NSSize(width: CGFloat(cached.width), height: CGFloat(cached.height)))
            } else {
                nsImage = nil
            }
            // Start at back: offset by π
            return Slot(windowInfo: win, cachedImage: nsImage, angle: finalAngle + .pi, wasFront: false)
        }
        frontSlotIndex = initialFrontIndex

        let panelCount = min(n, maxPanels)
        panels = (0..<panelCount).map { i in makePanel(image: slots[i].cachedImage) }

        updatePanelPoses()
        for panel in panels { panel.orderFront(nil) }
        logSlotState("setUpWithEntryAnimation (start)")

        // Animate: each slot moves by -π (from back to final position)
        animStartTime = CACurrentMediaTime()
        animDuration = duration
        animStartAngles = slots.map { $0.angle }
        animDeltaPerSlot = Array(repeating: -.pi, count: slots.count)
        animCompletion = nil
        animRunning = true
        startDisplayLink()
    }

    // MARK: - Cycling

    /// Rotate all windows by one step. direction: 1 = next (clockwise), -1 = previous.
    func cycle(direction: CGFloat, duration: TimeInterval = 0.35) {
        guard slots.count > 1 else { return }

        // Cancel any in-progress animation, snap to current interpolated positions
        if animRunning {
            animRunning = false
            stopDisplayLink()
            normalizeAngles()
        }

        let n = slots.count
        let angleStep = 2 * CGFloat.pi / CGFloat(n)
        let delta = -direction * angleStep

        // Disable shadows during animation for performance
        for panel in panels { panel.hasShadow = false }

        animStartTime = CACurrentMediaTime()
        animDuration = duration
        animStartAngles = slots.map { $0.angle }
        animDeltaPerSlot = Array(repeating: delta, count: slots.count)
        animCompletion = nil
        animRunning = true
        startDisplayLink()

        // Eagerly update front slot index for callers.
        let nextFront: Int
        if direction > 0 {
            nextFront = (frontSlotIndex + 1) % n
        } else {
            nextFront = (frontSlotIndex - 1 + n) % n
        }
        frontSlotIndex = nextFront
    }

    // MARK: - Tear Down

    /// Fade out all panels and clean up.
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

    /// Immediate cleanup with no animation.
    private func tearDownImmediate() {
        animRunning = false
        stopDisplayLink()
        for panel in panels {
            panel.orderOut(nil)
        }
        panels = []
        slots = []
        frontSlotIndex = 0
    }

    // MARK: - Fly-out

    /// Animate the front panel to the window's real screen position, fade others out.
    func flyOutFront(to targetRect: NSRect, completion: @escaping () -> Void) {
        animRunning = false
        stopDisplayLink()

        guard !panels.isEmpty else {
            completion()
            return
        }

        let frontPanel = findFrontPanel()
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
            for panel in self.panels {
                panel.orderOut(nil)
            }
            self.panels = []
            self.slots = []
            completion()
        })
    }

    // MARK: - Image Updates

    /// Update the image for the front window's panel.
    func updateFrontImage(_ image: NSImage) {
        guard !slots.isEmpty else { return }
        slots[frontSlotIndex].cachedImage = image

        if frontSlotIndex < panels.count,
           let imageView = panels[frontSlotIndex].contentView?.subviews.first as? NSImageView {
            imageView.image = image
        }
    }

    /// Update the cached image for a specific window ID. Also pushes to panel if visible.
    func updateImage(_ image: NSImage, forWindowID windowID: CGWindowID) {
        guard let i = slots.firstIndex(where: { $0.windowInfo.id == windowID }) else { return }
        slots[i].cachedImage = image
        if i < panels.count,
           let imageView = panels[i].contentView?.subviews.first as? NSImageView {
            imageView.image = image
        }
    }

    // MARK: - Panel Pose Update (HOT PATH)

    /// Update each panel's frame and z-level. Images are NOT touched here —
    /// they are set only during setup and explicit updateImage calls.
    private func updatePanelPoses() {
        let n = panels.count
        guard n > 0 else { return }

        var zOrderChanged = false

        for i in 0..<n {
            let (frame, isFront) = computeFrame(theta: slots[i].angle)
            let panel = panels[i]

            panel.setFrame(frame, display: false)
            panel.level = isFront ? Self.frontLevel : Self.backLevel

            if slots[i].wasFront != isFront {
                slots[i].wasFront = isFront
                zOrderChanged = true
            }
        }

        // Only re-stack when a panel crosses the front/back boundary
        if zOrderChanged {
            let byDepth = (0..<n).sorted {
                angularDistFromFront(slots[$0].angle) > angularDistFromFront(slots[$1].angle)
            }
            for j in 1..<byDepth.count {
                panels[byDepth[j]].order(.above, relativeTo: panels[byDepth[j - 1]].windowNumber)
            }
        }
    }

    /// Find the panel currently showing the front slot.
    private func findFrontPanel() -> NSPanel? {
        guard frontSlotIndex < panels.count else { return nil }
        return panels[frontSlotIndex]
    }

    // MARK: - Angle Helpers

    /// Normalize all angles to [0, 2π).
    private func normalizeAngles() {
        let twoPi = 2 * CGFloat.pi
        for i in slots.indices {
            var a = slots[i].angle.truncatingRemainder(dividingBy: twoPi)
            if a < 0 { a += twoPi }
            slots[i].angle = a
        }
    }

    /// Update frontSlotIndex to the slot nearest θ=0.
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

    /// Angular distance from the front position (θ=0), in [0, π].
    private func angularDistFromFront(_ angle: CGFloat) -> CGFloat {
        let twoPi = 2 * CGFloat.pi
        var d = angle.truncatingRemainder(dividingBy: twoPi)
        if d < 0 { d += twoPi }
        return d > .pi ? twoPi - d : d
    }

    // MARK: - Debug Logging

    private func logSlotState(_ label: String) {
        var lines: [String] = ["[carousel] \(label): \(slots.count) slots, \(panels.count) panels, frontSlot=\(frontSlotIndex)"]
        for (i, slot) in slots.enumerated() {
            let deg = slot.angle * 180 / .pi
            let cosθ = cos(slot.angle)
            let isFront = cosθ > 0
            let scale = (1 + cosθ) / 2 * (1 - config.backScale) + config.backScale
            lines.append("  slot[\(i)] wid:\(slot.windowInfo.id) θ=\(String(format: "%.1f°", deg)) scale=\(String(format: "%.2f", scale)) \(isFront ? "FRONT" : "back") hasImage=\(slot.cachedImage != nil)")
        }
        for (i, panel) in panels.enumerated() {
            let f = panel.frame
            lines.append("  panel[\(i)] frame=(\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))) alpha=\(String(format: "%.2f", panel.alphaValue)) level=\(panel.level == Self.frontLevel ? "FRONT" : panel.level == Self.backLevel ? "back" : "other(\(panel.level.rawValue))")")
        }
        carouselLog(lines.joined(separator: "\n"))
    }
}
