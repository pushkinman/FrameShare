//
//  RegionFrameWindow.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit

/// The colored border with drag handles drawn around the shared region.
/// It is hidden from the capture. Its middle is fully transparent, so clicks pass through to apps below.
final class RegionFrameWindow: NSWindow {
    static let margin: CGFloat = 16
    let frameView = RegionFrameView()

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = Levels.frame
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = frameView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func layout(region: CGRect, settings s: Settings, zoomRect: CGRect?) {
        let m = Self.margin + CGFloat(s.padding + s.borderWidth)
        frameView.inset = m
        frameView.padding = CGFloat(s.padding)
        frameView.borderWidth = CGFloat(s.borderWidth)
        frameView.color = NSColor(hex: s.frameColorHex) ?? .systemRed
        frameView.opacity = CGFloat(s.frameOpacity)
        frameView.locked = s.lockFrame
        frameView.zoomRect = zoomRect
        let scale = Geo.screen(for: region)?.backingScaleFactor ?? 2
        frameView.sizeLabel = "\(Int(region.width * scale)) × \(Int(region.height * scale))"
        setFrame(region.insetBy(dx: -m, dy: -m), display: false)
        frameView.needsDisplay = true
        invalidateCursorRects(for: frameView)
    }
}

final class RegionFrameView: NSView {
    var inset: CGFloat = 16
    var padding: CGFloat = 2
    var borderWidth: CGFloat = 3
    var color: NSColor = .systemRed
    var opacity: CGFloat = 0.9
    var locked = false
    var sizeLabel = ""
    /// Area the zoom shows, normalized to the region (top-left origin).
    var zoomRect: CGRect? { didSet { if zoomRect != oldValue { needsDisplay = true } } }

    var onBeginDrag: (() -> Void)?
    /// Handle (nil = move) and mouse delta in global points.
    var onDrag: ((Handle?, CGPoint) -> Void)?
    var onEndDrag: (() -> Void)?

    private var dragHandle: Handle?
    private var dragStart: CGPoint = .zero
    private var dragging = false

    private var regionRect: CGRect { bounds.insetBy(dx: inset, dy: inset) }
    private var borderRect: CGRect {
        let d = padding + borderWidth / 2
        return regionRect.insetBy(dx: -d, dy: -d)
    }

    private func handlePoint(_ h: Handle) -> CGPoint {
        let r = borderRect
        switch h {
        case .topLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .top: return CGPoint(x: r.midX, y: r.maxY)
        case .topRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottom: return CGPoint(x: r.midX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.minY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    private var hasSize: Bool { bounds.width > inset * 2 + 1 && bounds.height > inset * 2 + 1 }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        bounds.fill()
        guard hasSize else { return }

        if !locked {
            // An almost invisible band outside the region that catches clicks for moving the frame.
            let band = NSBezierPath(rect: bounds)
            band.append(NSBezierPath(rect: regionRect))
            band.windingRule = .evenOdd
            NSColor(white: 0, alpha: 0.02).setFill()
            band.fill()
        }

        let border = NSBezierPath(rect: borderRect)
        border.lineWidth = borderWidth
        color.withAlphaComponent(opacity).setStroke()
        border.stroke()

        if let z = zoomRect {
            let r = regionRect
            let zr = CGRect(x: r.minX + z.minX * r.width, y: r.maxY - z.maxY * r.height,
                            width: z.width * r.width, height: z.height * r.height)
            let p = NSBezierPath(rect: zr)
            p.lineWidth = 2
            p.setLineDash([8, 6], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            p.stroke()
        }

        guard !locked else { return }
        for h in Handle.allCases {
            let c = handlePoint(h)
            let r = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
            let p = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            p.fill()
            p.lineWidth = 1.5
            color.setStroke()
            p.stroke()
        }

        if !sizeLabel.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let text = NSAttributedString(string: sizeLabel + " px", attributes: attrs)
            let size = text.size()
            let pill = CGRect(x: borderRect.minX + 14, y: borderRect.maxY + 1,
                              width: size.width + 10, height: min(size.height + 2, bounds.maxY - borderRect.maxY - 1))
            color.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            text.draw(at: CGPoint(x: pill.minX + 5, y: pill.minY + 1))
        }
    }

    private func handle(at p: CGPoint) -> Handle? {
        Handle.allCases.first { h in
            let c = handlePoint(h)
            return abs(c.x - p.x) <= 9 && abs(c.y - p.y) <= 9
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !locked, hasSize else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragHandle = handle(at: p)
        if dragHandle == nil && regionRect.insetBy(dx: 1, dy: 1).contains(p) { return }
        dragStart = NSEvent.mouseLocation
        dragging = true
        onBeginDrag?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let cur = NSEvent.mouseLocation
        onDrag?(dragHandle, CGPoint(x: cur.x - dragStart.x, y: cur.y - dragStart.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEndDrag?()
    }

    override func resetCursorRects() {
        guard !locked, hasSize else { return }
        for h in Handle.allCases {
            let c = handlePoint(h)
            let r = CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)
            let cursor: NSCursor
            switch h {
            case .left, .right: cursor = .resizeLeftRight
            case .top, .bottom: cursor = .resizeUpDown
            default: cursor = .crosshair
            }
            addCursorRect(r, cursor: cursor)
        }
    }
}
