//
//  WindowScreenshot.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

struct WindowThumbnail {
    let windowID: CGWindowID
    let windowInfo: WindowInfo
    let image: NSImage
    let title: String?
    let appName: String?
    let appIcon: NSImage?
}

class WindowScreenshot {

    static func capture(windowID: CGWindowID, maxSize: CGSize = CGSize(width: 320, height: 240)) -> NSImage? {
        guard let cgImage = captureWindowImage(windowID: windowID) else {
            return nil
        }

        let fullImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return resized(fullImage, maxSize: maxSize)
    }

    static func captureAll(windows: [WindowInfo], maxSize: CGSize = CGSize(width: 320, height: 240)) -> [WindowThumbnail] {
        var thumbnails: [WindowThumbnail] = []
        let apps = NSWorkspace.shared.runningApplications.reduce(into: [pid_t: NSRunningApplication]()) {
            $0[$1.processIdentifier] = $1
        }

        for windowInfo in windows {
            let app = apps[windowInfo.pid]
            let image: NSImage
            if let captured = capture(windowID: windowInfo.id, maxSize: maxSize) {
                image = captured
            } else {
                image = placeholderImage(size: maxSize)
            }

            let thumbnail = WindowThumbnail(
                windowID: windowInfo.id,
                windowInfo: windowInfo,
                image: image,
                title: windowInfo.processName,
                appName: app?.localizedName,
                appIcon: app?.icon
            )
            thumbnails.append(thumbnail)
        }
        return thumbnails
    }

    private static func resized(_ image: NSImage, maxSize: CGSize) -> NSImage {
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return image }

        let widthRatio = maxSize.width / originalSize.width
        let heightRatio = maxSize.height / originalSize.height
        let scale = min(widthRatio, heightRatio, 1.0)

        let newSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)
        let resizedImage = NSImage(size: newSize)
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: originalSize),
                   operation: .copy,
                   fraction: 1.0)
        resizedImage.unlockFocus()
        return resizedImage
    }

    // CGWindowListCreateImage is deprecated on macOS 15+ but ScreenCaptureKit
    // requires additional entitlements and async APIs. This remains the simplest
    // approach for synchronous single-window capture on 10.15+.
    @available(macOS, deprecated: 15.0, message: "Migrate to ScreenCaptureKit when minimum target allows")
    private static func captureWindowImage(windowID: CGWindowID) -> CGImage? {
        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
    }

    static func captureRegionBelowWindow(windowID: CGWindowID, rect: CGRect) -> CGImage? {
        return captureRegionImage(windowID: windowID, rect: rect)
    }

    @available(macOS, deprecated: 15.0, message: "Migrate to ScreenCaptureKit when minimum target allows")
    private static func captureRegionImage(windowID: CGWindowID, rect: CGRect) -> CGImage? {
        return CGWindowListCreateImage(
            rect,
            .optionOnScreenBelowWindow,
            windowID,
            [.bestResolution]
        )
    }

    private static func placeholderImage(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.gray.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 4, yRadius: 4).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5)
        ]
        let text = "No Preview" as NSString
        let textSize = text.size(withAttributes: attrs)
        let textRect = NSRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attrs)
        image.unlockFocus()
        return image
    }
}
