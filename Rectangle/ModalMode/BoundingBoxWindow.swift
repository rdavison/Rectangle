//
//  BoundingBoxWindow.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

class BoundingBoxWindow: NSPanel {

    private let borderWidth: CGFloat = 3
    private let borderPadding: CGFloat = 4
    private let segmentsPerEdge = 4
    private var segmentLuminances: [CGFloat] = [] // 16 segments: top(4), right(4), bottom(4), left(4)
    private let boundingBoxView: BoundingBoxView

    init(windowFrame: CGRect, windowID: CGWindowID) {
        let appKitFrame = windowFrame.screenFlipped
        let paddedFrame = appKitFrame.insetBy(dx: -(borderPadding + borderWidth), dy: -(borderPadding + borderWidth))

        boundingBoxView = BoundingBoxView()

        super.init(contentRect: paddedFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        hasShadow = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .canJoinAllSpaces]

        boundingBoxView.frame = NSRect(origin: .zero, size: paddedFrame.size)
        boundingBoxView.borderWidth = borderWidth
        boundingBoxView.segmentsPerEdge = segmentsPerEdge
        contentView = boundingBoxView

        // Show immediately with default colors, then refine async
        asyncSampleLuminance(windowID: windowID, windowFrame: windowFrame)
    }

    private func asyncSampleLuminance(windowID: CGWindowID, windowFrame: CGRect) {
        let segCount = segmentsPerEdge
        let bWidth = borderWidth
        let bPadding = borderPadding
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let luminances = BoundingBoxWindow.computeLuminance(
                windowID: windowID, windowFrame: windowFrame,
                segmentsPerEdge: segCount, borderWidth: bWidth, borderPadding: bPadding
            )
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.segmentLuminances = luminances
                self.boundingBoxView.segmentLuminances = luminances
                self.boundingBoxView.needsDisplay = true
            }
        }
    }

    func flashAndDismiss(duration: TimeInterval = 0.3) {
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration * 0.3
            animator().alphaValue = 1.0
        } completionHandler: { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.4) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration * 0.3
                    self.animator().alphaValue = 0.0
                } completionHandler: {
                    self.orderOut(nil)
                }
            }
        }
    }

    private static func computeLuminance(windowID: CGWindowID, windowFrame: CGRect,
                                          segmentsPerEdge: Int, borderWidth: CGFloat, borderPadding: CGFloat) -> [CGFloat] {
        var luminances = Array(repeating: CGFloat(0.5), count: segmentsPerEdge * 4)

        let expandedFrame = windowFrame.insetBy(dx: -(borderPadding + borderWidth + 2), dy: -(borderPadding + borderWidth + 2))

        guard let bgImage = WindowScreenshot.captureRegionBelowWindow(windowID: windowID, rect: expandedFrame) else {
            return luminances
        }

        let imgWidth = CGFloat(bgImage.width)
        let imgHeight = CGFloat(bgImage.height)
        guard imgWidth > 0, imgHeight > 0 else { return luminances }

        guard let dataProvider = bgImage.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else { return luminances }

        let bytesPerRow = bgImage.bytesPerRow
        let bytesPerPixel = bgImage.bitsPerPixel / 8

        for seg in 0..<segmentsPerEdge {
            let startX = Int(imgWidth * CGFloat(seg) / CGFloat(segmentsPerEdge))
            let endX = Int(imgWidth * CGFloat(seg + 1) / CGFloat(segmentsPerEdge))
            luminances[seg] = averageLuminance(ptr: ptr, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel,
                                               xRange: startX..<endX, yRange: 0..<min(Int(borderWidth + borderPadding), Int(imgHeight)))
        }

        for seg in 0..<segmentsPerEdge {
            let startY = Int(imgHeight * CGFloat(seg) / CGFloat(segmentsPerEdge))
            let endY = Int(imgHeight * CGFloat(seg + 1) / CGFloat(segmentsPerEdge))
            let rightX = max(0, Int(imgWidth) - Int(borderWidth + borderPadding))
            luminances[segmentsPerEdge + seg] = averageLuminance(ptr: ptr, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel,
                                                                  xRange: rightX..<Int(imgWidth), yRange: startY..<endY)
        }

        for seg in 0..<segmentsPerEdge {
            let startX = Int(imgWidth * CGFloat(seg) / CGFloat(segmentsPerEdge))
            let endX = Int(imgWidth * CGFloat(seg + 1) / CGFloat(segmentsPerEdge))
            let bottomY = max(0, Int(imgHeight) - Int(borderWidth + borderPadding))
            luminances[segmentsPerEdge * 2 + seg] = averageLuminance(ptr: ptr, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel,
                                                                      xRange: startX..<endX, yRange: bottomY..<Int(imgHeight))
        }

        for seg in 0..<segmentsPerEdge {
            let startY = Int(imgHeight * CGFloat(seg) / CGFloat(segmentsPerEdge))
            let endY = Int(imgHeight * CGFloat(seg + 1) / CGFloat(segmentsPerEdge))
            luminances[segmentsPerEdge * 3 + seg] = averageLuminance(ptr: ptr, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel,
                                                                      xRange: 0..<min(Int(borderWidth + borderPadding), Int(imgWidth)), yRange: startY..<endY)
        }

        return luminances
    }

    private static func averageLuminance(ptr: UnsafePointer<UInt8>, bytesPerRow: Int, bytesPerPixel: Int,
                                         xRange: Range<Int>, yRange: Range<Int>) -> CGFloat {
        var total: CGFloat = 0
        var count: CGFloat = 0

        // Sample every 4th pixel for performance
        for y in stride(from: yRange.lowerBound, to: yRange.upperBound, by: 4) {
            for x in stride(from: xRange.lowerBound, to: xRange.upperBound, by: 4) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = CGFloat(ptr[offset]) / 255.0
                let g = CGFloat(ptr[offset + 1]) / 255.0
                let b = CGFloat(ptr[offset + 2]) / 255.0
                // Perceptual luminance
                total += 0.299 * r + 0.587 * g + 0.114 * b
                count += 1
            }
        }

        return count > 0 ? total / count : 0.5
    }
}

// MARK: - BoundingBoxView

private class BoundingBoxView: NSView {
    var borderWidth: CGFloat = 3
    var segmentsPerEdge: Int = 4
    var segmentLuminances: [CGFloat] = []

    override func draw(_ dirtyRect: NSRect) {
        guard segmentLuminances.count == segmentsPerEdge * 4 else {
            // Fallback: single gray border
            NSColor.gray.withAlphaComponent(0.8).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                                    xRadius: 6, yRadius: 6)
            path.lineWidth = borderWidth
            path.stroke()
            return
        }

        let rect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)

        // Draw each edge as segments with adaptive luminance
        // Top edge
        for seg in 0..<segmentsPerEdge {
            let lum = segmentLuminances[seg]
            colorForLuminance(lum).setStroke()
            let startX = rect.minX + rect.width * CGFloat(seg) / CGFloat(segmentsPerEdge)
            let endX = rect.minX + rect.width * CGFloat(seg + 1) / CGFloat(segmentsPerEdge)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: startX, y: rect.maxY))
            path.line(to: NSPoint(x: endX, y: rect.maxY))
            path.lineWidth = borderWidth
            path.lineCapStyle = .round
            path.stroke()
        }

        // Right edge
        for seg in 0..<segmentsPerEdge {
            let lum = segmentLuminances[segmentsPerEdge + seg]
            colorForLuminance(lum).setStroke()
            let startY = rect.maxY - rect.height * CGFloat(seg) / CGFloat(segmentsPerEdge)
            let endY = rect.maxY - rect.height * CGFloat(seg + 1) / CGFloat(segmentsPerEdge)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.maxX, y: startY))
            path.line(to: NSPoint(x: rect.maxX, y: endY))
            path.lineWidth = borderWidth
            path.lineCapStyle = .round
            path.stroke()
        }

        // Bottom edge
        for seg in 0..<segmentsPerEdge {
            let lum = segmentLuminances[segmentsPerEdge * 2 + seg]
            colorForLuminance(lum).setStroke()
            let startX = rect.minX + rect.width * CGFloat(seg) / CGFloat(segmentsPerEdge)
            let endX = rect.minX + rect.width * CGFloat(seg + 1) / CGFloat(segmentsPerEdge)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: startX, y: rect.minY))
            path.line(to: NSPoint(x: endX, y: rect.minY))
            path.lineWidth = borderWidth
            path.lineCapStyle = .round
            path.stroke()
        }

        // Left edge
        for seg in 0..<segmentsPerEdge {
            let lum = segmentLuminances[segmentsPerEdge * 3 + seg]
            colorForLuminance(lum).setStroke()
            let startY = rect.maxY - rect.height * CGFloat(seg) / CGFloat(segmentsPerEdge)
            let endY = rect.maxY - rect.height * CGFloat(seg + 1) / CGFloat(segmentsPerEdge)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: startY))
            path.line(to: NSPoint(x: rect.minX, y: endY))
            path.lineWidth = borderWidth
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    private func colorForLuminance(_ luminance: CGFloat) -> NSColor {
        // Dark gray on light backgrounds, light gray on dark backgrounds
        if luminance > 0.5 {
            return NSColor(white: 0.2, alpha: 0.85)
        } else {
            return NSColor(white: 0.8, alpha: 0.85)
        }
    }
}
