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
    }

    /// Computed pose for a slot at a given angle.
    struct Pose {
        let frame: NSRect
        let alpha: CGFloat
        let isFront: Bool
    }

    static let frontLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    static let backLevel  = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

    private var slots: [Slot] = []
    private let maxPanels = 7
    private var panels: [NSPanel] = []
    private var config: Config
    private var animationTimer: Timer?

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
    var isAnimating: Bool { animationTimer != nil }

    init(config: Config) {
        self.config = config
    }

    // MARK: - Pose Computation

    /// Compute the carousel pose for angle θ on the elliptical orbit.
    static func computePose(theta: CGFloat, config: Config, direction: CGFloat) -> Pose {
        let cosθ = cos(theta)
        let sinθ = sin(theta)
        let cx = config.centerX - direction * config.aRadius * sinθ
        let cy = config.centerY + config.bRadius * cosθ
        let scale = (1 + cosθ) / 2 * (1 - config.backScale) + config.backScale
        let w = config.baseW * scale
        let h = config.baseH * scale
        let alpha = (1 + cosθ) / 2 * 0.6 + 0.4
        let isFront = cosθ > 0
        return Pose(
            frame: NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
            alpha: alpha,
            isFront: isFront
        )
    }

    // MARK: - Panel Factory

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.level = Self.backLevel
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .canJoinAllSpaces]

        let contentFrame = NSRect(origin: .zero, size: panel.frame.size)
        let imageView = NSImageView(frame: contentFrame)
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

    // MARK: - Setup

    /// Create panels and distribute windows around the ellipse.
    /// `initialFrontIndex` is the index into `windows` that should start at the front (θ=0).
    func setUp(windows: [WindowInfo], initialFrontIndex: Int,
               cache: [CGWindowID: CGImage], config: Config) {
        self.config = config
        tearDownImmediate()

        guard !windows.isEmpty else { return }

        let n = windows.count
        let angleStep = 2 * CGFloat.pi / CGFloat(n)

        // Build slots. The initialFrontIndex window gets θ=0, others are evenly spaced clockwise.
        slots = windows.enumerated().map { (i, win) in
            let offsetFromFront = (i - initialFrontIndex + n) % n
            let angle = CGFloat(offsetFromFront) * angleStep
            let nsImage: NSImage?
            if let cached = cache[win.id] {
                nsImage = NSImage(cgImage: cached, size: NSSize(width: CGFloat(cached.width), height: CGFloat(cached.height)))
            } else {
                nsImage = nil
            }
            return Slot(windowInfo: win, cachedImage: nsImage, angle: angle)
        }
        frontSlotIndex = initialFrontIndex

        // Create panel pool (up to maxPanels)
        let panelCount = min(n, maxPanels)
        panels = (0..<panelCount).map { _ in makePanel() }

        // Apply initial poses
        assignPanels(direction: 1)
        for panel in panels {
            panel.orderFront(nil)
        }
        logSlotState("setUp")
    }

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
            return Slot(windowInfo: win, cachedImage: nsImage, angle: finalAngle + .pi)
        }
        frontSlotIndex = initialFrontIndex

        let panelCount = min(n, maxPanels)
        panels = (0..<panelCount).map { _ in makePanel() }

        assignPanels(direction: 1)
        for panel in panels {
            panel.orderFront(nil)
        }
        logSlotState("setUpWithEntryAnimation (start)")

        // Animate from current angles (offset by π) to final angles (subtract π from all)
        let startTime = CACurrentMediaTime()
        let startAngles = slots.map { $0.angle }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            let elapsed = CACurrentMediaTime() - startTime
            let raw = min(CGFloat(elapsed / duration), 1.0)
            let t = raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2

            // Interpolate: each angle moves from startAngle to startAngle - π
            for i in self.slots.indices {
                self.slots[i].angle = startAngles[i] - .pi * t
            }
            self.assignPanels(direction: 1)

            if raw >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.normalizeAngles()
                self.assignPanels(direction: 1)
                self.logSlotState("setUpWithEntryAnimation (end)")
            }
        }
    }

    // MARK: - Cycling

    /// Rotate all windows by one step. direction: 1 = next (clockwise), -1 = previous.
    func cycle(direction: CGFloat, duration: TimeInterval = 0.35) {
        guard slots.count > 1 else { return }

        // Cancel any in-progress animation, snap to current interpolated positions
        if let timer = animationTimer {
            timer.invalidate()
            animationTimer = nil
            normalizeAngles()
        }

        let n = slots.count
        let angleStep = 2 * CGFloat.pi / CGFloat(n)
        let delta = direction * angleStep  // positive direction = rotate forward

        let startTime = CACurrentMediaTime()
        let startAngles = slots.map { $0.angle }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            let elapsed = CACurrentMediaTime() - startTime
            let raw = min(CGFloat(elapsed / duration), 1.0)
            let t = raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2

            for i in self.slots.indices {
                self.slots[i].angle = startAngles[i] + delta * t
            }
            self.assignPanels(direction: direction)

            if raw >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.normalizeAngles()
                self.updateFrontSlotIndex()
                self.assignPanels(direction: direction)
                self.logSlotState("cycle (end, dir=\(direction))")
            }
        }

        // Eagerly update front slot index for callers
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
        animationTimer?.invalidate()
        animationTimer = nil

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
        animationTimer?.invalidate()
        animationTimer = nil
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
        animationTimer?.invalidate()
        animationTimer = nil

        guard !panels.isEmpty else {
            completion()
            return
        }

        // Find the panel currently at the front (lowest absolute angle)
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

        // Find the panel showing the front slot and update it
        if let panel = findFrontPanel(),
           let imageView = panel.contentView?.subviews.first as? NSImageView {
            imageView.image = image
        }
    }

    /// Update the cached image for a specific window ID.
    func updateImage(_ image: NSImage, forWindowID windowID: CGWindowID) {
        guard let slotIndex = slots.firstIndex(where: { $0.windowInfo.id == windowID }) else { return }
        slots[slotIndex].cachedImage = image
        // Panel assignment will pick it up on next frame or assignPanels call
    }

    // MARK: - Panel Assignment

    /// Sort slots by proximity to front (θ=0), assign the nearest `maxPanels` to visible panels.
    private func assignPanels(direction: CGFloat) {
        guard !slots.isEmpty, !panels.isEmpty else { return }

        // Compute a sort key: absolute angular distance from 0 (normalized to [0, π])
        let indexed = slots.enumerated().map { (index: $0.offset, slot: $0.element, dist: angularDistanceFromFront($0.element.angle)) }
        let sorted = indexed.sorted { $0.dist < $1.dist }

        // Assign the nearest slots to panels; sort by angle for correct z-ordering
        let visible = Array(sorted.prefix(panels.count))
        let byAngle = visible.sorted { $0.slot.angle < $1.slot.angle }

        for (panelIndex, item) in byAngle.enumerated() {
            let pose = Self.computePose(theta: item.slot.angle, config: config, direction: direction)
            let panel = panels[panelIndex]

            panel.setFrame(pose.frame, display: true)
            panel.alphaValue = pose.alpha
            panel.level = pose.isFront ? Self.frontLevel : Self.backLevel

            if let imageView = panel.contentView?.subviews.first as? NSImageView {
                imageView.image = item.slot.cachedImage
            }
        }
    }

    /// Log current slot and panel state for debugging.
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

    /// Find the panel currently showing the front slot.
    private func findFrontPanel() -> NSPanel? {
        guard !panels.isEmpty else { return nil }
        // Front panel is the one at frontLevel with highest alpha
        return panels.max(by: { $0.alphaValue < $1.alphaValue })
    }

    // MARK: - Angle Helpers

    /// Normalize all angles to [0, 2π).
    private func normalizeAngles() {
        for i in slots.indices {
            var a = slots[i].angle.truncatingRemainder(dividingBy: 2 * .pi)
            if a < 0 { a += 2 * .pi }
            slots[i].angle = a
        }
    }

    /// Update frontSlotIndex to the slot nearest θ=0.
    private func updateFrontSlotIndex() {
        guard !slots.isEmpty else { return }
        var bestIndex = 0
        var bestDist = angularDistanceFromFront(slots[0].angle)
        for i in 1..<slots.count {
            let dist = angularDistanceFromFront(slots[i].angle)
            if dist < bestDist {
                bestDist = dist
                bestIndex = i
            }
        }
        frontSlotIndex = bestIndex
    }

    /// Angular distance from the front position (θ=0), in [0, π].
    private func angularDistanceFromFront(_ angle: CGFloat) -> CGFloat {
        var d = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if d < 0 { d += 2 * .pi }
        return d > .pi ? 2 * .pi - d : d
    }
}
