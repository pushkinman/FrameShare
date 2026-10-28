//
//  PresenterOverlayWindow.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit

/// A transparent window that sits exactly over the shared region and IS captured.
/// It holds the drawings, spotlight, timer and keystroke views, so viewers see them.
final class PresenterOverlayWindow: NSWindow {
    let annotation = AnnotationView()
    let spotlight = SpotlightView()
    let clicks = ClickRippleView()
    let timerBadge = TimerBadgeView()
    let keystrokes = KeystrokeView()
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                   styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = Levels.overlay
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        for v in [spotlight, annotation, clicks, timerBadge, keystrokes] as [NSView] {
            v.frame = root.bounds
            v.autoresizingMask = [.width, .height]
            root.addSubview(v)
        }
        contentView = root
    }

    override var canBecomeKey: Bool { true }

    func setDrawing(_ on: Bool) {
        ignoresMouseEvents = !on
        annotation.active = on
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    /// While drawing: ⌘Z undoes, ⇧⌘Z redoes.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            event.modifierFlags.contains(.shift) ? annotation.redo() : annotation.undo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Drawing

struct Stroke {
    let id = UUID()
    var tool: DrawTool
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]
    var created = Date()
}

/// The drawing layer. Every change (new stroke, erase, clear) is a step in the undo/redo history.
final class AnnotationView: NSView {
    private(set) var strokes: [Stroke] = [] { didSet { needsDisplay = true } }
    private var current: Stroke?
    private var history: [[Stroke]] = [[]]
    private var index = 0
    private var erasing = false

    var tool: DrawTool = .pen { didSet { window?.invalidateCursorRects(for: self) } }
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var active = false {
        didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }
    /// Called whenever undo/redo availability may have changed.
    var onHistoryChange: (() -> Void)?
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < history.count - 1 }

    /// Seconds before drawings fade away on their own (0 = they stay).
    var fadeAfter: TimeInterval = 0 { didSet { if fadeAfter != oldValue { updateFadeTimer() } } }
    private let fadeDuration: TimeInterval = 0.6
    private var fadeTimer: Timer?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: History

    private func commit(_ new: [Stroke]) {
        if index < history.count - 1 { history.removeSubrange((index + 1)...) }
        history.append(new)
        if history.count > 200 { history.removeFirst() }
        index = history.count - 1
        strokes = new
        historyChanged()
    }

    func undo() {
        guard canUndo, current == nil else { return }
        index -= 1
        strokes = history[index]
        historyChanged()
    }

    func redo() {
        guard canRedo, current == nil else { return }
        index += 1
        strokes = history[index]
        historyChanged()
    }

    func clear() {
        current = nil
        if !strokes.isEmpty { commit([]) } else { needsDisplay = true }
    }

    private func historyChanged() {
        onHistoryChange?()
        updateFadeTimer()
    }

    // MARK: Fading

    private func updateFadeTimer() {
        let needed = fadeAfter > 0 && !strokes.isEmpty
        if needed && fadeTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fadeTick() }
            }
            RunLoop.main.add(t, forMode: .common)
            fadeTimer = t
        } else if !needed {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    private func fadeTick() {
        let now = Date()
        let expired = Set(strokes.filter { now.timeIntervalSince($0.created) > fadeAfter + fadeDuration }.map(\.id))
        if !expired.isEmpty {
            // Faded strokes are gone for good: remove them from every history step too.
            var newHistory: [[Stroke]] = []
            var newIndex = 0
            for (i, snap) in history.enumerated() {
                let kept = snap.filter { !expired.contains($0.id) }
                if let last = newHistory.last, last.map(\.id) == kept.map(\.id) {
                    if i <= index { newIndex = newHistory.count - 1 }
                    continue
                }
                newHistory.append(kept)
                if i <= index { newIndex = newHistory.count - 1 }
            }
            history = newHistory.isEmpty ? [[]] : newHistory
            index = min(newIndex, history.count - 1)
            strokes = history[index]
            historyChanged()
        }
        needsDisplay = true
    }

    private func alpha(for s: Stroke) -> CGFloat {
        guard fadeAfter > 0 else { return 1 }
        let age = Date().timeIntervalSince(s.created)
        return age <= fadeAfter ? 1 : CGFloat(max(0, 1 - (age - fadeAfter) / fadeDuration))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if active {
            // Nearly invisible fill so the window receives clicks everywhere while drawing.
            NSColor(white: 0, alpha: 0.004).setFill()
            bounds.fill()
        }
        for s in strokes { draw(s, alpha: alpha(for: s)) }
        if let c = current { draw(c, alpha: 1) }
    }

    private func draw(_ s: Stroke, alpha: CGFloat) {
        guard alpha > 0, let path = Self.path(for: s) else { return }
        let highlighter = s.tool == .highlighter
        path.lineWidth = highlighter ? s.width * 4 : s.width
        path.lineCapStyle = highlighter ? .butt : .round
        path.lineJoinStyle = .round
        let base = highlighter ? s.color.withAlphaComponent(0.35) : s.color
        base.withAlphaComponent(base.alphaComponent * alpha).setStroke()
        path.stroke()
    }

    static func path(for s: Stroke) -> NSBezierPath? {
        guard let first = s.points.first else { return nil }
        let last = s.points.last ?? first
        let p = NSBezierPath()
        switch s.tool {
        case .pen, .highlighter, .eraser:
            p.move(to: first)
            if s.points.count == 1 { p.line(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            for pt in s.points.dropFirst() { p.line(to: pt) }
        case .line:
            p.move(to: first); p.line(to: last)
        case .arrow:
            p.move(to: first); p.line(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let len = max(14, s.width * 4)
            for a in [angle + .pi * 0.85, angle - .pi * 0.85] {
                p.move(to: last)
                p.line(to: CGPoint(x: last.x + cos(a) * len, y: last.y + sin(a) * len))
            }
        case .rectangle:
            p.appendRect(Self.rect(first, last))
        case .ellipse:
            p.appendOval(in: Self.rect(first, last))
        }
        return p
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func erase(at p: CGPoint) {
        let before = strokes.count
        let kept = strokes.filter { s in
            guard let path = Self.path(for: s) else { return true }
            let w = (s.tool == .highlighter ? s.width * 4 : s.width) + 16
            return !path.cgPath.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
        }
        if kept.count != before { strokes = kept }
    }

    /// Holding Shift keeps lines and arrows straight at 45° steps.
    private func constrained(_ p: CGPoint, from start: CGPoint, _ event: NSEvent) -> CGPoint {
        guard event.modifierFlags.contains(.shift) else { return p }
        let dx = p.x - start.x, dy = p.y - start.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let len = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * len, y: start.y + sin(angle) * len)
    }

    override func mouseDown(with event: NSEvent) {
        guard active else { return }
        let p = convert(event.locationInWindow, from: nil)
        if tool == .eraser { erasing = true; erase(at: p); return }
        current = Stroke(tool: tool, color: color, width: lineWidth, points: [p])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard active else { return }
        let p = convert(event.locationInWindow, from: nil)
        if erasing { erase(at: p); return }
        guard var c = current else { return }
        switch c.tool {
        case .pen, .highlighter: c.points.append(p)
        case .line, .arrow: c.points = [c.points[0], constrained(p, from: c.points[0], event)]
        default: c.points = [c.points[0], p]
        }
        current = c
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if erasing {
            erasing = false
            // One undo step for the whole eraser drag.
            if strokes.map(\.id) != history[index].map(\.id) { commit(strokes) }
            return
        }
        guard var c = current else { return }
        current = nil
        let isShape = ![.pen, .highlighter].contains(c.tool)
        if isShape, c.points.count < 2 { needsDisplay = true; return }
        c.created = Date()
        commit(strokes + [c])
    }

    override func resetCursorRects() {
        guard active else { return }
        addCursorRect(bounds, cursor: tool == .eraser ? .disappearingItem : .crosshair)
    }
}

// MARK: - Click rings

/// Shows an expanding ring wherever you click, so viewers can follow the mouse.
final class ClickRippleView: NSView {
    private struct Ripple { var point: CGPoint; var start: Date; var right: Bool }
    private var ripples: [Ripple] = []
    private var timer: Timer?
    private let duration: TimeInterval = 0.5

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func add(at point: CGPoint, right: Bool) {
        ripples.append(Ripple(point: point, start: Date(), right: right))
        needsDisplay = true
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func tick() {
        let now = Date()
        ripples.removeAll { now.timeIntervalSince($0.start) > duration }
        needsDisplay = true
        if ripples.isEmpty { timer?.invalidate(); timer = nil }
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        for r in ripples {
            let t = CGFloat(min(1, now.timeIntervalSince(r.start) / duration))
            let radius = 10 + 28 * t
            let color = (r.right ? NSColor.systemBlue : NSColor.systemYellow).withAlphaComponent(0.9 * (1 - t))
            let circle = NSBezierPath(ovalIn: CGRect(x: r.point.x - radius, y: r.point.y - radius, width: radius * 2, height: radius * 2))
            color.withAlphaComponent(0.25 * (1 - t)).setFill()
            circle.fill()
            circle.lineWidth = 3
            color.setStroke()
            circle.stroke()
        }
    }
}

// MARK: - Spotlight

final class SpotlightView: NSView {
    var enabled = false { didSet { if enabled != oldValue { needsDisplay = true } } }
    var center: CGPoint = .zero { didSet { if enabled && center != oldValue { needsDisplay = true } } }
    var radius: CGFloat = 160
    var dim: CGFloat = 0.65

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard enabled else { return }
        let p = NSBezierPath(rect: bounds)
        p.append(NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                             width: radius * 2, height: radius * 2)))
        p.windingRule = .evenOdd
        NSColor(white: 0, alpha: dim).setFill()
        p.fill()
    }
}

// MARK: - Timer badge

final class TimerBadgeView: NSView {
    var text: String? { didSet { if text != oldValue { needsDisplay = true } } }
    var corner: Corner = .topRight { didSet { needsDisplay = true } }
    var alert = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let text else { return }
        let size = min(48, max(16, bounds.height * 0.035))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let ts = s.size()
        let pad = size * 0.5, margin: CGFloat = 14
        let w = ts.width + pad * 2, h = ts.height + pad * 0.8
        let x: CGFloat = (corner == .topLeft || corner == .bottomLeft) ? margin : bounds.width - w - margin
        let y: CGFloat = (corner == .bottomLeft || corner == .bottomRight) ? margin : bounds.height - h - margin
        let r = CGRect(x: x, y: y, width: w, height: h)
        (alert ? NSColor.systemRed : NSColor(white: 0, alpha: 0.7)).setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        s.draw(at: CGPoint(x: r.minX + pad, y: r.minY + pad * 0.4))
    }
}

// MARK: - Keystrokes

final class KeystrokeView: NSView {
    private struct Bubble { var text: String; var time: Date; var typing: Bool }
    private var bubbles: [Bubble] = []
    private var timer: Timer?
    private let visibleFor: TimeInterval = 1.6
    private let fadeFor: TimeInterval = 0.5

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func add(_ text: String, typing: Bool) {
        let now = Date()
        if typing, var last = bubbles.last, last.typing, now.timeIntervalSince(last.time) < 1.2 {
            last.text = String((last.text + text).suffix(40))
            last.time = now
            bubbles[bubbles.count - 1] = last
        } else {
            bubbles.append(Bubble(text: text, time: now, typing: typing))
            if bubbles.count > 3 { bubbles.removeFirst() }
        }
        needsDisplay = true
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    func clear() { bubbles.removeAll(); needsDisplay = true }

    private func tick() {
        let now = Date()
        bubbles.removeAll { now.timeIntervalSince($0.time) > visibleFor + fadeFor }
        needsDisplay = true
        if bubbles.isEmpty { timer?.invalidate(); timer = nil }
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = min(40, max(16, bounds.height * 0.04))
        var y: CGFloat = 24
        let now = Date()
        for b in bubbles.reversed() {
            let age = now.timeIntervalSince(b.time)
            let alpha = CGFloat(age < visibleFor ? 1 : max(0, 1 - (age - visibleFor) / fadeFor))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            ]
            let s = NSAttributedString(string: b.text, attributes: attrs)
            let ts = s.size()
            let pad = size * 0.55
            let r = CGRect(x: bounds.midX - ts.width / 2 - pad, y: y, width: ts.width + pad * 2, height: ts.height + pad * 0.7)
            NSColor(white: 0, alpha: 0.72 * alpha).setFill()
            NSBezierPath(roundedRect: r, xRadius: size * 0.4, yRadius: size * 0.4).fill()
            s.draw(at: CGPoint(x: r.minX + pad, y: r.minY + pad * 0.35))
            y += r.height + 8
        }
    }
}
