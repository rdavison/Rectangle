//
//  CarouselBackdropPanel.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

/// Full-screen dark backdrop that renders the selected app's windows
/// as a GPU-accelerated 3D scene using Core Animation transforms.
class CarouselBackdropPanel: NSPanel {

    enum Style {
        case cascade
        case expose
        case ring
    }

    var style: Style = .cascade

    private var sceneView: NSView!

    // Pre-allocated layer pools — reused across setWindows calls
    private var cardPool: [CALayer] = []
    private var reflPool: [CALayer] = []
    private var reflMasks: [CAGradientLayer] = []
    private var activeCardCount: Int = 0

    // 3D scene parameters
    private let perspectiveD: CGFloat = 900
    private let maxVisibleCards: Int = 8

    private var targetScreen: NSScreen

    init(screen: NSScreen) {
        self.targetScreen = screen
        let panelRect = screen.visibleFrame

        super.init(contentRect: panelRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)

        isOpaque = false
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        hasShadow = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        collectionBehavior = [.transient, .canJoinAllSpaces]

        // Dark frosted-glass background
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelRect.size))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.autoresizingMask = [.width, .height]
        contentView = bg

        // Layer-backed overlay for 3D card rendering
        sceneView = NSView(frame: bg.bounds)
        sceneView.wantsLayer = true
        sceneView.autoresizingMask = [.width, .height]

        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / perspectiveD
        sceneView.layer?.sublayerTransform = perspective

        bg.addSubview(sceneView)

        // Pre-allocate layer pools
        guard let sceneLayer = sceneView.layer else { return }
        let borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        let gradientColors = [NSColor.white.cgColor, NSColor.clear.cgColor]

        for _ in 0..<maxVisibleCards {
            // Card layer
            let card = CALayer()
            card.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            card.cornerRadius = 10
            card.masksToBounds = false
            card.borderWidth = 1
            card.borderColor = borderColor
            card.shadowColor = NSColor.black.cgColor
            card.shadowOffset = CGSize(width: 0, height: -6)
            card.contentsGravity = .resizeAspectFill
            card.isHidden = true
            sceneLayer.addSublayer(card)
            cardPool.append(card)

            // Reflection layer
            let refl = CALayer()
            refl.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            refl.cornerRadius = 10
            refl.masksToBounds = true
            refl.opacity = 0.10
            refl.contentsGravity = .resizeAspectFill
            refl.isHidden = true

            let mask = CAGradientLayer()
            mask.colors = gradientColors
            mask.startPoint = CGPoint(x: 0.5, y: 1.0)
            mask.endPoint = CGPoint(x: 0.5, y: 0.3)
            refl.mask = mask

            sceneLayer.addSublayer(refl)
            reflPool.append(refl)
            reflMasks.append(mask)
        }
    }

    // MARK: - Card Placement

    private struct CardPlacement {
        let size: CGSize
        let position: CGPoint       // card center in scene coords
        let transform: CATransform3D
        let reflectionTransform: CATransform3D?  // nil = no reflection
        let shadowOpacity: Float
        let shadowRadius: CGFloat
    }

    private func calculatePlacements(
        windowFrames: [CGRect],
        sceneBounds: CGRect
    ) -> [CardPlacement] {
        switch style {
        case .cascade:
            return cascadePlacements(windowFrames: windowFrames, sceneBounds: sceneBounds)
        case .expose:
            return exposePlacements(windowFrames: windowFrames, sceneBounds: sceneBounds)
        case .ring:
            return ringPlacements(windowFrames: windowFrames, sceneBounds: sceneBounds)
        }
    }

    // MARK: Cascade Layout

    private func cascadePlacements(
        windowFrames: [CGRect],
        sceneBounds: CGRect
    ) -> [CardPlacement] {
        let count = windowFrames.count
        guard count > 0 else { return [] }

        let cx = sceneBounds.midX
        let cy = sceneBounds.height * 0.62
        // Flat layout — no tilt

        // Scale cards to fit all side-by-side with padding
        let availableW = sceneBounds.width * 0.85
        let availableH = sceneBounds.height * 0.45
        let maxCardW = min(availableW / CGFloat(count) - 16, 420)
        let maxCardH = min(availableH, 300)

        var placements: [CardPlacement] = []
        for i in 0..<count {
            let winFrame = windowFrames[i]
            let aspect = winFrame.width / max(winFrame.height, 1)
            let w: CGFloat, h: CGFloat
            if aspect > maxCardW / maxCardH {
                w = maxCardW; h = maxCardW / aspect
            } else {
                h = maxCardH; w = maxCardH * aspect
            }

            // Spread evenly across available width
            let totalW = CGFloat(count) * (maxCardW + 16) - 16
            let startX = -totalW / 2
            let offsetX = startX + (CGFloat(i) + 0.5) * (maxCardW + 16)

            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, offsetX, 0, 0)

            placements.append(CardPlacement(
                size: CGSize(width: w, height: h),
                position: CGPoint(x: cx, y: cy),
                transform: t,
                reflectionTransform: nil,
                shadowOpacity: 0.7,
                shadowRadius: 20
            ))
        }
        return placements
    }

    // MARK: Expose Layout

    private func exposePlacements(
        windowFrames: [CGRect],
        sceneBounds: CGRect
    ) -> [CardPlacement] {
        let count = windowFrames.count
        guard count > 0 else { return [] }

        let sceneW = sceneBounds.width * 0.85
        let sceneH = sceneBounds.height * 0.75
        let padding: CGFloat = 20

        // Find optimal column count that maximizes cell size
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
        let originX = sceneBounds.midX - gridW / 2
        let originY = sceneBounds.height * 0.72 - gridH / 2  // Center grid above the HUD strip

        var placements: [CardPlacement] = []
        for i in 0..<count {
            let col = i % cols
            let row = i / cols
            let winFrame = windowFrames[i]

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
            // Flip row order so first window is top-left
            let cy = originY + (CGFloat(rows - 1 - row) + 0.5) * cellH

            placements.append(CardPlacement(
                size: CGSize(width: w, height: h),
                position: CGPoint(x: cx, y: cy),
                transform: CATransform3DIdentity,
                reflectionTransform: nil,
                shadowOpacity: 0.4,
                shadowRadius: 12
            ))
        }
        return placements
    }

    // MARK: Ring Layout

    private func ringPlacements(
        windowFrames: [CGRect],
        sceneBounds: CGRect
    ) -> [CardPlacement] {
        let cardMaxW: CGFloat = 300
        let cardMaxH: CGFloat = 220
        let count = windowFrames.count
        guard count > 0 else { return [] }

        let radius: CGFloat = min(max(CGFloat(count) * 40, 250), 400)
        let cx = sceneBounds.midX
        let cy = sceneBounds.height * 0.72  // Position above the HUD strip

        var placements: [CardPlacement] = []
        for i in 0..<count {
            let winFrame = windowFrames[i]
            let aspect = winFrame.width / max(winFrame.height, 1)
            let w: CGFloat, h: CGFloat
            if aspect > cardMaxW / cardMaxH {
                w = cardMaxW; h = cardMaxW / aspect
            } else {
                h = cardMaxH; w = cardMaxH * aspect
            }

            let angle = CGFloat(i) * 2 * .pi / CGFloat(count)
            let px = sin(angle) * radius
            let pz = cos(angle) * radius - radius  // shift so front card is at z=0

            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, px, 0, pz)
            t = CATransform3DRotate(t, angle, 0, 1, 0)

            var rt = CATransform3DIdentity
            rt = CATransform3DTranslate(rt, px, -h - 8, pz)
            rt = CATransform3DRotate(rt, angle, 0, 1, 0)
            rt = CATransform3DScale(rt, 1, -1, 1)

            placements.append(CardPlacement(
                size: CGSize(width: w, height: h),
                position: CGPoint(x: cx, y: cy),
                transform: t,
                reflectionTransform: rt,
                shadowOpacity: 0.6,
                shadowRadius: 18
            ))
        }
        return placements
    }

    // MARK: - Set Windows

    /// Replace the displayed windows with a new set. Animates a slide transition when `direction` is nonzero.
    func setWindows(_ screenshots: [(image: CGImage, windowFrame: CGRect)],
                    animated: Bool, direction: CGFloat = 0) {

        let sw0 = CACurrentMediaTime()

        let count = min(screenshots.count, maxVisibleCards)
        let trimmed = Array(screenshots.prefix(count))
        let frames = trimmed.map { $0.windowFrame }

        let sw1 = CACurrentMediaTime()
        let placements = count > 0 ? calculatePlacements(windowFrames: frames, sceneBounds: sceneView.bounds) : []
        let sw2 = CACurrentMediaTime()

        // Update pool layers with disabled implicit animations
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for i in 0..<maxVisibleCards {
            let card = cardPool[i]
            let refl = reflPool[i]

            if i < count {
                let placement = placements[i]

                card.contents = trimmed[i].image
                card.bounds = CGRect(origin: .zero, size: placement.size)
                card.position = placement.position
                card.transform = placement.transform
                card.shadowOpacity = placement.shadowOpacity
                card.shadowRadius = placement.shadowRadius
                card.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: placement.size),
                                         cornerWidth: 10, cornerHeight: 10, transform: nil)
                card.zPosition = CGFloat(count - i) * 2
                card.isHidden = false
                card.opacity = 1

                if let reflTransform = placement.reflectionTransform {
                    refl.contents = trimmed[i].image
                    refl.bounds = card.bounds
                    refl.position = placement.position
                    refl.transform = reflTransform
                    refl.zPosition = CGFloat(count - i) * 2 - 1
                    refl.isHidden = false
                    refl.opacity = 0.10
                    reflMasks[i].frame = refl.bounds
                } else {
                    refl.isHidden = true
                }
            } else {
                card.isHidden = true
                refl.isHidden = true
            }
        }

        activeCardCount = count

        CATransaction.commit()

        let sw3 = CACurrentMediaTime()

        if animated && direction != 0 {
            slideIn(direction: direction)
        }

        let sw4 = CACurrentMediaTime()
        NSLog("[Backdrop]     setWindows(%d cards, style=%@): layout=%.1fms  updatePool=%.1fms  animate=%.1fms  total=%.1fms",
              count, "\(style)", (sw2-sw1)*1000, (sw3-sw2)*1000, (sw4-sw3)*1000, (sw4-sw0)*1000)
    }

    // MARK: - Update Thumbnail

    func updateThumbnail(_ image: CGImage, at index: Int) {
        guard index >= 0, index < activeCardCount else { return }
        cardPool[index].contents = image
        if !reflPool[index].isHidden {
            reflPool[index].contents = image
        }
    }

    // MARK: - Fly-out Animation

    /// Animate cards from their 3D positions to the real window screen positions, then call completion.
    func animateFlyout(windowFrames: [CGRect], completion: @escaping () -> Void) {
        let origin = frame.origin
        let sceneBounds = sceneView.bounds
        let cx: CGFloat = sceneBounds.midX
        let cy: CGFloat = sceneBounds.height * 0.72

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock(completion)

        for i in 0..<activeCardCount where i < windowFrames.count {
            let card = cardPool[i]
            let target = windowFrames[i].screenFlipped
            let lx = target.midX - origin.x - cx
            let ly = target.midY - origin.y - cy
            let sx = target.width / card.bounds.width
            let sy = target.height / card.bounds.height

            var t = CATransform3DIdentity
            t = CATransform3DTranslate(t, lx, ly, 0)
            t = CATransform3DScale(t, sx, sy, 1)
            card.transform = t
            card.opacity = 0
        }

        // Fade reflections
        for i in 0..<activeCardCount {
            reflPool[i].opacity = 0
        }

        CATransaction.commit()
    }

    // MARK: - Animation Helpers

    private func slideIn(direction: CGFloat) {
        for i in 0..<activeCardCount {
            let card = cardPool[i]
            let refl = reflPool[i]

            let finalCardT = card.transform
            let finalReflT = refl.transform

            let startCardT: CATransform3D
            let startReflT: CATransform3D

            switch style {
            case .cascade:
                startCardT = CATransform3DTranslate(finalCardT, direction * 250, 0, -120)
                startReflT = CATransform3DTranslate(finalReflT, direction * 250, 0, -120)
            case .expose:
                startCardT = CATransform3DScale(finalCardT, 0.8, 0.8, 1)
                startReflT = CATransform3DScale(finalReflT, 0.8, 0.8, 1)
            case .ring:
                startCardT = CATransform3DRotate(finalCardT, direction * 0.4, 0, 1, 0)
                startReflT = CATransform3DRotate(finalReflT, direction * 0.4, 0, 1, 0)
            }

            animateSlide(layer: card, from: startCardT, to: finalCardT, fromOpacity: 0, toOpacity: 1)

            if !refl.isHidden {
                animateSlide(layer: refl, from: startReflT, to: finalReflT, fromOpacity: 0, toOpacity: 0.10)
            }
        }
    }

    private func animateSlide(layer: CALayer, from startT: CATransform3D, to finalT: CATransform3D,
                              fromOpacity: Float, toOpacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = startT
        layer.opacity = fromOpacity
        CATransaction.commit()

        let tAnim = CABasicAnimation(keyPath: "transform")
        tAnim.fromValue = startT
        tAnim.toValue = finalT
        tAnim.duration = 0.3
        tAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let oAnim = CABasicAnimation(keyPath: "opacity")
        oAnim.fromValue = fromOpacity
        oAnim.toValue = toOpacity
        oAnim.duration = 0.25
        oAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        layer.transform = finalT
        layer.opacity = toOpacity
        layer.add(tAnim, forKey: "slideIn")
        layer.add(oAnim, forKey: "fadeIn")
    }
}
