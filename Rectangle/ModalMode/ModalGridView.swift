//
//  ModalGridView.swift
//  Rectangle
//
//  Copyright © 2024 Ryan Hanson. All rights reserved.
//

import Cocoa

class ModalGridView: NSView {

    var columns: Int { Defaults.modalGridColumns.value }
    var rows: Int { Defaults.modalGridRows.value }

    var onGridSelection: ((Int, Int, Int, Int) -> Void)?

    var isInteractive: Bool = true

    private var selectionStart: (col: Int, row: Int)?
    private var selectionEnd: (col: Int, row: Int)?
    private var hoverCell: (col: Int, row: Int)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)

        for col in 0..<columns {
            for row in 0..<rows {
                let cellRect = NSRect(
                    x: CGFloat(col) * cellWidth,
                    y: CGFloat(row) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                ).insetBy(dx: 1.5, dy: 1.5)

                let path = NSBezierPath(roundedRect: cellRect, xRadius: 3, yRadius: 3)

                if isInSelection(col: col, row: row) {
                    NSColor.controlAccentColor.withAlphaComponent(0.5).setFill()
                    path.fill()
                    NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                } else if hoverCell?.col == col && hoverCell?.row == row && selectionStart == nil {
                    NSColor.white.withAlphaComponent(0.15).setFill()
                    path.fill()
                    NSColor.white.withAlphaComponent(0.3).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                } else {
                    NSColor.white.withAlphaComponent(0.08).setFill()
                    path.fill()
                    NSColor.white.withAlphaComponent(0.2).setStroke()
                    path.lineWidth = 0.5
                    path.stroke()
                }
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionStart = cellAt(point: point)
        selectionEnd = selectionStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        selectionEnd = cellAt(point: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = selectionStart, let end = selectionEnd else { return }
        let startCol = min(start.col, end.col)
        let endCol = max(start.col, end.col)
        let startRow = min(start.row, end.row)
        let endRow = max(start.row, end.row)

        selectionStart = nil
        selectionEnd = nil
        needsDisplay = true

        onGridSelection?(startCol, startRow, endCol, endRow)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            hoverCell = cellAt(point: point)
        } else {
            hoverCell = nil
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverCell = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    private func cellAt(point: NSPoint) -> (col: Int, row: Int) {
        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)
        let col = max(0, min(columns - 1, Int(point.x / cellWidth)))
        let row = max(0, min(rows - 1, Int(point.y / cellHeight)))
        return (col, row)
    }

    private func isInSelection(col: Int, row: Int) -> Bool {
        guard let start = selectionStart, let end = selectionEnd else { return false }
        let minCol = min(start.col, end.col)
        let maxCol = max(start.col, end.col)
        let minRow = min(start.row, end.row)
        let maxRow = max(start.row, end.row)
        return col >= minCol && col <= maxCol && row >= minRow && row <= maxRow
    }
}
