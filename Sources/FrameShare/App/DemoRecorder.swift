//
//  DemoRecorder.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit
import ScreenCaptureKit
import AVFoundation

/// Records the README screenshots and clips: `FrameShare --record-demo`.
///
/// It covers the main display with a made-up desktop (`DemoStageWindow`) and records with a filter that
/// includes FrameShare's own windows only. Other apps, notifications, the real menu bar and Dock
/// never appear in the footage. Saved settings aren't touched. Output: ~/Library/Caches/FrameShare-demo/.
@MainActor
final class DemoRecorder {
    private let c: AppController
    private var state: AppState { c.state }
    private let screen: NSScreen
    private let stage: DemoStageWindow
    private let cursor = DemoCursorWindow()
    private let out: URL
    private var crops: [String: [Int]] = [:]
    private var log: [String] = []
    private var display: SCDisplay?
    private var myApp: SCRunningApplication?

    init(controller: AppController) {
        c = controller
        screen = NSScreen.main ?? NSScreen.screens[0]
        stage = DemoStageWindow(screen: screen)
        out = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrameShare-demo", isDirectory: true)
    }

    private var L: DemoLayout { stage.layout }
    private var scale: CGFloat { screen.backingScaleFactor }

    func run() async {
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            try await record()
            note("done")
        } catch {
            note("ERROR: \(error.localizedDescription)")
        }
        if let data = try? JSONSerialization.data(withJSONObject: crops, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("crops.json"))
        }
        try? log.joined(separator: "\n").write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        c.stopSharing()
        NSApp.terminate(nil)
    }

    private func note(_ s: String) { log.append(s) }

    // MARK: Script

    private func record() async throws {
        guard #available(macOS 15, *) else { throw DemoError.message("Recording clips needs macOS 15 or newer.") }
        stage.orderFrontRegardless()
        cursor.orderFrontRegardless()
        cursor.move(to: CGPoint(x: L.slides.midX, y: L.slides.midY - 60))

        var s = state.settings
        s.ratio = .free
        s.showFrame = true
        s.dimOutside = true
        s.lockFrame = false
        s.hideCursor = true
        s.mirrorTitle = "FrameShare"
        s.hideTitleBar = false
        s.mirrorVisibility = .visible
        s.matchMirrorToFrame = false
        s.controlBarMode = .whileSharing
        s.controlBarVertical = false
        s.controlBarExpanded = false
        s.tool = .pen
        s.penColorHex = "#FF3B30"
        s.penWidth = 5
        s.drawingFadeSeconds = 0
        s.privacyRules = []
        s.titleKeywords = []
        s.matchBrowserURLs = false
        s.timerMode = .stopwatch
        s.timerCorner = .topRight
        s.spotlightRadius = 130
        s.zoomFactor = 2
        s.region = L.slides
        state.settings = s
        state.spotlightOn = false; state.zoomOn = false; state.blurAll = false
        state.timerVisible = false; state.keystrokesOn = false; state.clicksOn = false
        await wait(0.3)

        c.demoIncludedWindows = [CGWindowID(stage.windowNumber), CGWindowID(cursor.windowNumber)]
        c.startSharing()
        await wait(1.0)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        display = content.displays.first { $0.displayID == screen.displayID }
        myApp = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard display != nil, myApp != nil else { throw DemoError.message("Display or app not found for capture.") }

        placeMirror(in: L.meetingBox)
        placeBar(expanded: false)
        await wait(0.8)

        // --- Stills: overview and the collapsed bar
        try await still("overview", rect: screen.frame, margin: 0)
        if let bar = c.controlBar { try await still("bar-collapsed", rect: bar.frame, margin: 8) }

        // --- 1. Overview: move the frame between windows; the shared window follows.
        try await clip("overview", rect: screen.frame) {
            await self.wait(1.2)
            await self.dragFrame(to: self.L.code, duration: 1.3)
            await self.wait(1.4)
            await self.dragFrame(to: self.L.chat, duration: 1.3)
            await self.wait(1.4)
            await self.dragFrame(to: self.L.slides, duration: 1.3)
            await self.wait(1.0)
        }

        // --- 2. Drawing with the expanded control bar
        state.settings.controlBarExpanded = true
        await wait(0.4)
        placeBar(expanded: true)
        await wait(0.4)
        if let bar = c.controlBar { try await still("bar-expanded", rect: bar.frame, margin: 8) }
        c.selectTool(.pen)
        cursor.style = .crosshair
        await wait(0.6)
        placeBar(expanded: true)
        await wait(0.4)
        let barRect = c.controlBar?.frame ?? .zero
        let drawCrop = L.slides.union(barRect).insetBy(dx: -24, dy: -24)
        try await clip("drawing", rect: drawCrop) {
            await self.wait(0.8)
            // Circle the tallest bar.
            await self.drawStroke(self.ellipsePoints(around: self.L.tallestBar.insetBy(dx: -22, dy: -26)), duration: 1.3)
            await self.wait(0.5)
            // Arrow from the headline to the bar.
            self.state.settings.penColorHex = "#FFCC00"
            self.c.selectTool(.arrow)
            await self.wait(0.5)
            let from = CGPoint(x: self.L.bullet1.maxX + 30, y: self.L.bullet1.midY + 4)
            let to = CGPoint(x: self.L.tallestBar.minX - 30, y: self.L.tallestBar.maxY - 40)
            await self.drawStroke([from, to], duration: 0.7)
            await self.wait(0.5)
            // Highlight a line of text.
            self.state.settings.penColorHex = "#34C759"
            self.state.settings.penWidth = 10
            self.c.selectTool(.highlighter)
            await self.wait(0.5)
            let y = self.L.bullet2.midY
            await self.drawStroke([CGPoint(x: self.L.bullet2.minX - 4, y: y), CGPoint(x: self.L.bullet2.maxX + 4, y: y + 1)], duration: 0.7)
            await self.wait(0.8)
            // Undo, redo
            self.c.undoDrawing(); await self.wait(0.7)
            self.c.undoDrawing(); await self.wait(0.7)
            self.c.redoDrawing(); await self.wait(0.7)
            self.c.redoDrawing(); await self.wait(1.2)
            if let bar = self.c.controlBar { try? await self.still("bar-drawing", rect: bar.frame, margin: 8) }
            self.c.clearDrawings()
            await self.wait(0.9)
        }
        c.selectPointer()
        state.settings.penWidth = 5
        state.settings.penColorHex = "#FF3B30"
        cursor.style = .arrow
        state.settings.controlBarExpanded = false
        await wait(0.6)
        placeBar(expanded: false)

        // --- 3. Spotlight
        state.spotlightOn = true
        cursor.move(to: CGPoint(x: L.bullet1.midX, y: L.bullet1.midY))
        c.demoMouse = cursor.point
        await wait(0.4)
        try await clip("spotlight", rect: L.slides) {
            await self.wait(0.6)
            await self.moveCursor(to: CGPoint(x: self.L.bullet2.midX, y: self.L.bullet2.midY), duration: 0.9)
            await self.wait(0.4)
            await self.moveCursor(to: CGPoint(x: self.L.chart.midX - 60, y: self.L.chart.midY), duration: 1.0)
            await self.wait(0.4)
            await self.moveCursor(to: CGPoint(x: self.L.tallestBar.midX, y: self.L.tallestBar.maxY - 30), duration: 0.9)
            await self.wait(0.9)
            await self.moveCursor(to: CGPoint(x: self.L.bullet1.midX, y: self.L.bullet1.midY), duration: 1.1)
            await self.wait(0.4)
        }
        state.spotlightOn = false
        await wait(0.3)

        // The next clips show what viewers get, so the shared window is sized 1:1 and recorded on its own.
        state.settings.matchMirrorToFrame = true
        state.settings.mirrorVisibility = .hidden
        await wait(0.8)

        // --- 4. Zoom (recorded from the shared window)
        cursor.move(to: CGPoint(x: L.title.midX, y: L.title.midY))
        c.demoMouse = cursor.point
        state.zoomOn = true
        await wait(0.8)
        try await windowClip("zoom") {
            await self.wait(0.6)
            await self.moveCursor(to: CGPoint(x: self.L.bullet2.midX, y: self.L.bullet2.midY), duration: 1.2)
            await self.wait(0.5)
            await self.moveCursor(to: CGPoint(x: self.L.tallestBar.midX, y: self.L.tallestBar.midY + 40), duration: 1.4)
            await self.wait(0.9)
            await self.moveCursor(to: CGPoint(x: self.L.title.midX, y: self.L.title.midY), duration: 1.3)
            await self.wait(0.6)
        }
        state.zoomOn = false
        c.demoMouse = nil
        await wait(0.4)

        // --- 5. Privacy blur (recorded from the shared window)
        let both = L.slides.union(L.chat).insetBy(dx: -10, dy: -10)
        c.setRegion(both)
        cursor.move(to: CGPoint(x: L.slides.midX, y: L.slides.minY + 40))
        await wait(1.0)
        let r = state.settings.region
        let chatN = CGRect(x: (L.chat.minX - r.minX) / r.width, y: (r.maxY - L.chat.maxY) / r.height,
                           width: L.chat.width / r.width, height: L.chat.height / r.height)
        try await windowClip("privacy") {
            await self.wait(1.3)
            self.c.blurRects = [chatN]; self.c.updateEffects()
            await self.wait(2.2)
            self.c.blurRects = []; self.c.updateEffects()
            await self.wait(0.8)
        }
        c.setRegion(L.slides)
        await wait(0.8)

        // --- 6. Timer, keystrokes, click rings
        state.timerVisible = true
        c.startPauseTimer()
        cursor.move(to: CGPoint(x: L.slides.midX, y: L.slides.minY + 60))
        await wait(0.6)
        try await clip("presenter", rect: L.slides) {
            await self.wait(0.5)
            for bar in self.L.bars.prefix(3) {
                await self.moveCursor(to: CGPoint(x: bar.midX, y: bar.maxY - 14), duration: 0.5)
                self.click(right: false)
                await self.wait(0.45)
            }
            self.c.overlay.keystrokes.add("⌘C", typing: false)
            await self.wait(0.7)
            await self.moveCursor(to: CGPoint(x: self.L.bullet3.maxX + 20, y: self.L.bullet3.midY), duration: 0.6)
            self.click(right: true)
            await self.wait(0.5)
            self.c.overlay.keystrokes.add("⌘V", typing: false)
            await self.wait(0.6)
            for ch in "Q4 plan" {
                self.c.overlay.keystrokes.add(String(ch), typing: true)
                await self.wait(0.12)
            }
            await self.wait(2.2)
        }
        c.resetTimer()
        state.timerVisible = false

        // --- Stills: menu and settings
        cursor.orderOut(nil)
        if let d = NSApp.delegate as? AppDelegate { d.togglePopover() }
        await wait(1.0)
        if let pop = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) {
            pop.makeFirstResponder(nil)
            await wait(0.3)
            try await still("menu", rect: pop.frame, margin: 18)
        } else { note("menu popover not found") }
        if let d = NSApp.delegate as? AppDelegate { d.togglePopover() }
        await wait(0.4)

        c.stopSharing()
        await wait(0.5)
        c.openSettings()
        if let w = c.settingsWindow {
            w.level = NSWindow.Level(rawValue: Levels.toolbar.rawValue + 1)
            w.setFrameOrigin(CGPoint(x: L.slides.midX - w.frame.width / 2, y: screen.visibleFrame.midY - w.frame.height / 2))
            w.makeFirstResponder(nil)
            await wait(0.8)
            try await still("settings", rect: w.frame, margin: 30)
            w.close()
        }
    }

    // MARK: Helpers: scene

    private func placeMirror(in box: CGRect) {
        guard let m = c.mirror else { return }
        let w = m.window
        w.level = NSWindow.Level(rawValue: Levels.toolbar.rawValue + 1)
        let r = state.settings.region
        let title = w.frame.height - w.contentRect(forFrameRect: w.frame).height
        let k = min(box.width / r.width, (box.height - title) / r.height)
        let size = CGSize(width: (r.width * k).rounded(), height: (r.height * k).rounded() + title)
        w.setFrame(CGRect(x: box.maxX - size.width, y: box.minY, width: size.width, height: size.height), display: true)
        w.orderFrontRegardless()
    }

    private func placeBar(expanded: Bool) {
        guard let bar = c.controlBar else { return }
        let top = L.slides.maxY + 18 + bar.frame.height
        bar.move(topLeft: CGPoint(x: (L.slides.midX - bar.frame.width / 2).rounded(), y: top.rounded()))
    }

    /// Moves the frame as if dragged by its top edge.
    private func dragFrame(to target: CGRect, duration: Double) async {
        let from = state.settings.region
        let grab = CGPoint(x: from.midX, y: from.maxY)
        await moveCursor(to: grab, duration: 0.35)
        await animate(duration) { t in
            let r = CGRect(x: lerp(from.minX, target.minX, t), y: lerp(from.minY, target.minY, t),
                           width: lerp(from.width, target.width, t), height: lerp(from.height, target.height, t)).integral
            self.c.setRegion(r)
            self.cursor.move(to: CGPoint(x: r.midX, y: r.maxY))
            self.placeMirror(in: self.L.meetingBox)
        }
        await wait(0.05)
        placeMirror(in: L.meetingBox)
    }

    private func moveCursor(to p: CGPoint, duration: Double) async {
        let a = cursor.point
        await animate(duration) { t in
            self.cursor.move(to: CGPoint(x: lerp(a.x, p.x, t), y: lerp(a.y, p.y, t)))
            self.c.demoMouse = self.cursor.point
        }
    }

    private func click(right: Bool) {
        let o = c.overlay.frame.origin
        c.overlay.clicks.add(at: CGPoint(x: cursor.point.x - o.x, y: cursor.point.y - o.y), right: right)
    }

    private func drawStroke(_ pts: [CGPoint], duration: Double) async {
        guard let first = pts.first else { return }
        await moveCursor(to: first, duration: 0.35)
        let view = c.overlay.annotation
        view.mouseDown(with: mouseEvent(.leftMouseDown, first))
        // Walk the polyline at constant speed.
        var lengths: [CGFloat] = [0]
        for i in 1..<max(pts.count, 1) where pts.count > 1 {
            lengths.append(lengths[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
        }
        let total = max(lengths.last ?? 0, 1)
        await animate(duration, easing: false) { t in
            let d = CGFloat(t) * total
            var i = 1
            while i < pts.count - 1 && lengths[i] < d { i += 1 }
            let seg = max(lengths[i] - lengths[i - 1], 0.0001)
            let u = min(max((d - lengths[i - 1]) / seg, 0), 1)
            let p = CGPoint(x: lerp(pts[i - 1].x, pts[i].x, Double(u)), y: lerp(pts[i - 1].y, pts[i].y, Double(u)))
            self.cursor.move(to: p)
            view.mouseDragged(with: self.mouseEvent(.leftMouseDragged, p))
        }
        view.mouseUp(with: mouseEvent(.leftMouseUp, pts.last!))
    }

    private func mouseEvent(_ type: NSEvent.EventType, _ screenPoint: CGPoint) -> NSEvent {
        let o = c.overlay.frame.origin
        return NSEvent.mouseEvent(with: type, location: CGPoint(x: screenPoint.x - o.x, y: screenPoint.y - o.y),
                                  modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: c.overlay.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: 1)!
    }

    private func ellipsePoints(around r: CGRect) -> [CGPoint] {
        // A hand-drawn loop: starts top-left and overshoots a little.
        (0...48).map { i in
            let a = .pi * 0.75 - Double(i) / 44 * 2 * .pi
            let wobble = 1 + 0.04 * sin(Double(i) * 0.9)
            return CGPoint(x: r.midX + r.width / 2 * CGFloat(cos(a) * wobble), y: r.midY + r.height / 2 * CGFloat(sin(a) * wobble))
        }
    }

    private func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func animate(_ duration: Double, easing: Bool = true, _ step: (Double) -> Void) async {
        let start = Date()
        while true {
            let raw = min(1, Date().timeIntervalSince(start) / duration)
            let t = easing ? (raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2) : raw
            step(t)
            if raw >= 1 { break }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    // MARK: Helpers: capture

    private func pixelRect(_ r: CGRect) -> CGRect {
        let f = screen.frame
        let rr = r.intersection(f)
        return CGRect(x: ((rr.minX - f.minX) * scale).rounded(), y: ((f.maxY - rr.maxY) * scale).rounded(),
                      width: (rr.width * scale).rounded(), height: (rr.height * scale).rounded())
    }

    private func ourFilter() -> SCContentFilter {
        SCContentFilter(display: display!, including: [myApp!], exceptingWindows: [])
    }

    private func still(_ name: String, rect: CGRect, margin: CGFloat) async throws {
        let cfg = SCStreamConfiguration()
        cfg.width = Int(screen.frame.width * scale); cfg.height = Int(screen.frame.height * scale)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        let img = try await SCScreenshotManager.captureImage(contentFilter: ourFilter(), configuration: cfg)
        let px = pixelRect(rect.insetBy(dx: -margin, dy: -margin))
        let cropped = img.cropping(to: px) ?? img
        AppController.savePNG(cropped, out.appendingPathComponent("\(name).png"))
        note("still \(name) \(cropped.width)x\(cropped.height)")
    }

    @available(macOS 15, *)
    private func clip(_ name: String, rect: CGRect, _ body: () async -> Void) async throws {
        let cfg = SCStreamConfiguration()
        cfg.width = Int(screen.frame.width * scale); cfg.height = Int(screen.frame.height * scale)
        try await recordClip(name, filter: ourFilter(), config: cfg, body)
        let px = pixelRect(rect)
        crops[name] = [Int(px.minX), Int(px.minY), Int(px.width), Int(px.height)]
    }

    /// Records only the shared window (exactly what a meeting app receives), without its title bar.
    @available(macOS 15, *)
    private func windowClip(_ name: String, _ body: () async -> Void) async throws {
        guard let m = c.mirror else { throw DemoError.message("No shared window") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let win = content.windows.first(where: { $0.windowID == CGWindowID(m.window.windowNumber) }) else {
            throw DemoError.message("Shared window not found")
        }
        let w = m.window
        let cfg = SCStreamConfiguration()
        cfg.width = Int(w.frame.width * scale); cfg.height = Int(w.frame.height * scale)
        try await recordClip(name, filter: SCContentFilter(desktopIndependentWindow: win), config: cfg, body)
        let title = Int(((w.frame.height - w.contentRect(forFrameRect: w.frame).height) * scale).rounded())
        crops[name] = [0, title, cfg.width, cfg.height - title]
    }

    @available(macOS 15, *)
    private func recordClip(_ name: String, filter: SCContentFilter, config cfg: SCStreamConfiguration,
                            _ body: () async -> Void) async throws {
        cfg.showsCursor = false
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.queueDepth = 6
        cfg.captureResolution = .best
        let url = out.appendingPathComponent("\(name).mov")
        let rec = DemoClipRecorder()
        try await rec.start(filter: filter, config: cfg, url: url)
        await body()
        await rec.stop()
        note("clip \(name) \(cfg.width)x\(cfg.height) finished=\(rec.finished) error=\(rec.error ?? "none")")
    }
}

enum DemoError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

// MARK: - Recording

@available(macOS 15, *)
final class DemoClipRecorder: NSObject, SCStreamOutput, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "frameshare.demo.rec")
    private(set) var finished = false
    private(set) var error: String?

    func start(filter: SCContentFilter, config: SCStreamConfiguration, url: URL) async throws {
        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = .mov
        rc.videoCodecType = .h264
        try s.addRecordingOutput(SCRecordingOutput(configuration: rc, delegate: self))
        try await s.startCapture()
        stream = s
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    func stop() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
        try? await stream?.stopCapture()
        for _ in 0..<40 where !finished { try? await Task.sleep(nanoseconds: 100_000_000) }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finished = true }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        self.error = error.localizedDescription
        finished = true
    }
}

// MARK: - Fake cursor

final class DemoCursorWindow: NSWindow {
    enum Style { case arrow, crosshair }
    private let imageView = NSImageView()
    private(set) var point: CGPoint = .zero
    var style: Style = .arrow { didSet { applyStyle(); move(to: point) } }
    private var hotSpot: CGPoint = .zero

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 32, height: 32), styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = imageView
        imageView.imageScaling = .scaleNone
        applyStyle()
    }

    private func applyStyle() {
        let cur: NSCursor = style == .arrow ? .arrow : .crosshair
        imageView.image = cur.image
        hotSpot = cur.hotSpot
        setContentSize(cur.image.size)
        imageView.frame = CGRect(origin: .zero, size: cur.image.size)
    }

    func move(to p: CGPoint) {
        point = p
        let h = frame.height
        setFrameOrigin(CGPoint(x: (p.x - hotSpot.x).rounded(), y: (p.y - (h - hotSpot.y)).rounded()))
    }
}

// MARK: - Made-up desktop

/// Positions of the made-up windows and slide elements, in screen coordinates.
struct DemoLayout {
    var code = CGRect.zero, slides = CGRect.zero, chat = CGRect.zero, meetingBox = CGRect.zero
    var title = CGRect.zero, bullet1 = CGRect.zero, bullet2 = CGRect.zero, bullet3 = CGRect.zero
    var chart = CGRect.zero, bars: [CGRect] = []
    var tallestBar: CGRect { bars.max { $0.height < $1.height } ?? .zero }
}

final class DemoStageWindow: NSWindow {
    let layout: DemoLayout

    init(screen: NSScreen) {
        let f = screen.frame
        let menuH = max(24, f.maxY - screen.visibleFrame.maxY)
        // Designed for 1512×982 points; scaled to the actual display.
        let k = min(f.width / 1512, (f.height - menuH) / 945)
        func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: f.minX + (x * k).rounded(), y: f.minY + (y * k).rounded(), width: (w * k).rounded(), height: (h * k).rounded())
        }
        var L = DemoLayout()
        L.code = R(24, 64, 430, 806)
        L.slides = R(476, 250, 640, 520)
        L.chat = R(1138, 316, 350, 560)
        L.meetingBox = R(1138, 24, 350, 270)
        // Slide content (relative to the slides window).
        let s = L.slides
        func S(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: s.minX + (x * k).rounded(), y: s.minY + (y * k).rounded(), width: (w * k).rounded(), height: (h * k).rounded())
        }
        L.title = S(40, 412, 330, 40)
        L.bullet1 = S(40, 330, 236, 22)
        L.bullet2 = S(40, 292, 210, 22)
        L.bullet3 = S(40, 254, 190, 22)
        L.chart = S(330, 60, 270, 300)
        let heights: [CGFloat] = [120, 165, 150, 250]
        L.bars = heights.enumerated().map { i, h in S(346 + CGFloat(i) * 62, 96, 44, h) }
        layout = L

        super.init(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Levels.dim.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = DemoStageView(layout: L, screenFrame: f, menuHeight: menuH, k: k)
    }

    override var canBecomeKey: Bool { false }
}

private final class DemoStageView: NSView {
    let L: DemoLayout
    let sf: CGRect
    let menuH: CGFloat
    let k: CGFloat

    init(layout: DemoLayout, screenFrame: CGRect, menuHeight: CGFloat, k: CGFloat) {
        L = layout; sf = screenFrame; menuH = menuHeight; self.k = k
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
    }
    required init?(coder: NSCoder) { nil }

    /// Screen rect → view rect.
    private func v(_ r: CGRect) -> CGRect { r.offsetBy(dx: -sf.minX, dy: -sf.minY) }

    private func color(_ hex: String, _ a: CGFloat = 1) -> NSColor { (NSColor(hex: hex) ?? .gray).withAlphaComponent(a) }

    private func text(_ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color c: NSColor, mono: Bool = false) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size * k, weight: weight) : NSFont.systemFont(ofSize: size * k, weight: weight)
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: c])
    }

    override func draw(_ dirtyRect: NSRect) {
        // Wallpaper
        NSGradient(colors: [color("#2E3A78"), color("#5B4596"), color("#B8667F")])!.draw(in: bounds, angle: -35)
        // Soft shapes
        color("#FFFFFF", 0.06).setFill()
        NSBezierPath(ovalIn: CGRect(x: bounds.width * 0.55, y: -bounds.height * 0.3, width: bounds.width * 0.7, height: bounds.height * 0.9)).fill()

        // Menu bar
        let mb = CGRect(x: 0, y: bounds.height - menuH, width: bounds.width, height: menuH)
        color("#10131F", 0.55).setFill(); mb.fill()
        let ty = mb.minY + (menuH - 15 * k) / 2 - 1
        text("Slides", at: CGPoint(x: 18 * k, y: ty), size: 13, weight: .bold, color: .white)
        var x: CGFloat = 76 * k
        for item in ["File", "Edit", "View", "Insert", "Window", "Help"] {
            text(item, at: CGPoint(x: x, y: ty), size: 13, color: .white)
            x += (CGFloat(item.count) * 8 + 22) * k
        }
        text("Tue 10:30", at: CGPoint(x: bounds.width - 86 * k, y: ty), size: 13, color: .white)

        drawCode()
        drawChat()
        drawSlides()
    }

    private func window(_ r: CGRect, title: String, dark: Bool) -> CGRect {
        let rr = v(r)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24 * k
        shadow.shadowOffset = CGSize(width: 0, height: -8 * k)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        (dark ? color("#1E2130") : color("#FFFFFF")).setFill()
        NSBezierPath(roundedRect: rr, xRadius: 11 * k, yRadius: 11 * k).fill()
        NSGraphicsContext.restoreGraphicsState()
        let tb = CGRect(x: rr.minX, y: rr.maxY - 30 * k, width: rr.width, height: 30 * k)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rr, xRadius: 11 * k, yRadius: 11 * k).addClip()
        (dark ? color("#2A2E40") : color("#ECEEF4")).setFill(); tb.fill()
        NSGraphicsContext.restoreGraphicsState()
        for (i, c) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
            color(c).setFill()
            NSBezierPath(ovalIn: CGRect(x: tb.minX + (14 + CGFloat(i) * 20) * k, y: tb.midY - 6 * k, width: 12 * k, height: 12 * k)).fill()
        }
        let font = NSFont.systemFont(ofSize: 12.5 * k, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dark ? color("#B8BED6") : color("#4A5070")]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: CGPoint(x: tb.midX - size.width / 2, y: tb.midY - size.height / 2), withAttributes: attrs)
        return CGRect(x: rr.minX, y: rr.minY, width: rr.width, height: rr.height - 30 * k)
    }

    private func drawCode() {
        let body = window(L.code, title: "ChartView.swift", dark: true)
        let lines: [[(String, String)]] = [
            [("import", "#FF7AB2"), (" SwiftUI", "#D9DEF0")],
            [],
            [("struct", "#FF7AB2"), (" QuarterChart", "#5DD8FF"), (": View {", "#D9DEF0")],
            [("    let", "#FF7AB2"), (" values", "#D9DEF0"), (": [", "#D9DEF0"), ("Double", "#5DD8FF"), ("]", "#D9DEF0")],
            [],
            [("    var", "#FF7AB2"), (" body", "#D9DEF0"), (": some ", "#D9DEF0"), ("View", "#5DD8FF"), (" {", "#D9DEF0")],
            [("        HStack", "#5DD8FF"), ("(alignment: .bottom) {", "#D9DEF0")],
            [("            ForEach", "#5DD8FF"), ("(values, id: \\.self) {", "#D9DEF0")],
            [("                Bar", "#5DD8FF"), ("(height: $0)", "#D9DEF0")],
            [("            }", "#D9DEF0")],
            [("        }", "#D9DEF0")],
            [("        .", "#D9DEF0"), ("padding", "#A167E6"), ("(", "#D9DEF0"), ("24", "#D9C97C"), (")", "#D9DEF0")],
            [("    }", "#D9DEF0")],
            [("}", "#D9DEF0")],
            [],
            [("// Growth compared with last quarter", "#7F8C98")],
            [("func", "#FF7AB2"), (" growth", "#67B7A4"), ("(_ a: ", "#D9DEF0"), ("Double", "#5DD8FF"), (", _ b: ", "#D9DEF0"), ("Double", "#5DD8FF"), (") -> ", "#D9DEF0"), ("Double", "#5DD8FF"), (" {", "#D9DEF0")],
            [("    (b - a) / a * ", "#D9DEF0"), ("100", "#D9C97C")],
            [("}", "#D9DEF0")],
            [],
            [("let", "#FF7AB2"), (" q3", "#D9DEF0"), (" = ", "#D9DEF0"), ("growth", "#67B7A4"), ("(", "#D9DEF0"), ("4.2", "#D9C97C"), (", ", "#D9DEF0"), ("4.96", "#D9C97C"), (")", "#D9DEF0")],
            [("print", "#67B7A4"), ("(", "#D9DEF0"), ("\"Q3: +\\(q3)%\"", "#FC6A5D"), (")", "#D9DEF0")],
        ]
        let font = NSFont.monospacedSystemFont(ofSize: 12.5 * k, weight: .regular)
        var y = body.maxY - 34 * k
        for (n, line) in lines.enumerated() {
            ("\(n + 1)" as NSString).draw(at: CGPoint(x: body.minX + 14 * k, y: y),
                                          withAttributes: [.font: font, .foregroundColor: color("#5C6380")])
            var x = body.minX + 46 * k
            for (t, c) in line {
                let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(c)]
                (t as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: a)
                x += (t as NSString).size(withAttributes: a).width
            }
            y -= 22 * k
        }
    }

    private func drawChat() {
        let body = window(L.chat, title: "Team Chat", dark: false)
        let msgs: [(String, String, Bool, String)] = [
            ("Maya", "Morning! Can you walk us through the Q3 numbers?", false, "#7C8CF8"),
            ("You", "Sure, sharing the slide now", true, ""),
            ("Leo", "The Q3 bar looks great 🎉", false, "#F59E6B"),
            ("Maya", "What drove the jump?", false, "#7C8CF8"),
            ("You", "Two new markets and the summer launch", true, ""),
            ("Leo", "Nice. Let's plan Q4 next", false, "#F59E6B"),
        ]
        var y = body.maxY - 20 * k
        let font = NSFont.systemFont(ofSize: 12.5 * k)
        let maxW = body.width - 90 * k
        for (who, msg, mine, avatar) in msgs {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: mine ? NSColor.white : color("#1E2130")]
            let bound = (msg as NSString).boundingRect(with: CGSize(width: maxW - 24 * k, height: 400), options: [.usesLineFragmentOrigin], attributes: attrs)
            let bw = ceil(bound.width) + 24 * k, bh = ceil(bound.height) + 16 * k
            if !mine {
                text(who, at: CGPoint(x: body.minX + 54 * k, y: y - 14 * k), size: 11, weight: .semibold, color: color("#6A7090"))
                y -= 18 * k
                color(avatar).setFill()
                NSBezierPath(ovalIn: CGRect(x: body.minX + 14 * k, y: y - 30 * k, width: 30 * k, height: 30 * k)).fill()
                text(String(who.prefix(1)), at: CGPoint(x: body.minX + 24 * k, y: y - 24 * k), size: 13, weight: .bold, color: .white)
            }
            let bx = mine ? body.maxX - 14 * k - bw : body.minX + 54 * k
            let bubble = CGRect(x: bx, y: y - bh, width: bw, height: bh)
            (mine ? color("#3C6DF0") : color("#EEF0F6")).setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 14 * k, yRadius: 14 * k).fill()
            (msg as NSString).draw(with: CGRect(x: bx + 12 * k, y: y - bh + 8 * k, width: maxW - 24 * k, height: bound.height),
                                   options: [.usesLineFragmentOrigin], attributes: attrs)
            y -= bh + 16 * k
        }
        // Input field
        let field = CGRect(x: body.minX + 14 * k, y: body.minY + 14 * k, width: body.width - 28 * k, height: 34 * k)
        color("#F3F4F8").setFill()
        NSBezierPath(roundedRect: field, xRadius: 17 * k, yRadius: 17 * k).fill()
        text("Message", at: CGPoint(x: field.minX + 16 * k, y: field.midY - 8 * k), size: 12.5, color: color("#9AA0B8"))
    }

    private func drawSlides() {
        _ = window(L.slides, title: "Quarterly Review", dark: false)
        let t = v(L.title)
        text("Q3 Highlights", at: CGPoint(x: t.minX, y: t.minY), size: 30, weight: .bold, color: color("#1E2130"))
        text("Product & growth update", at: CGPoint(x: t.minX, y: t.minY - 28 * k), size: 14, color: color("#6A7090"))
        for (r, s) in [(L.bullet1, "Revenue up 18% this quarter"), (L.bullet2, "Two new markets launched"), (L.bullet3, "Customer score: 62 → 71")] {
            let rr = v(r)
            color("#3C6DF0").setFill()
            NSBezierPath(ovalIn: CGRect(x: rr.minX, y: rr.midY - 3.5 * k, width: 7 * k, height: 7 * k)).fill()
            text(s, at: CGPoint(x: rr.minX + 16 * k, y: rr.minY + 2 * k), size: 14, weight: .medium, color: color("#2B3047"))
        }
        // Chart
        let ch = v(L.chart)
        color("#F4F5FA").setFill()
        NSBezierPath(roundedRect: ch, xRadius: 10 * k, yRadius: 10 * k).fill()
        text("Revenue, $M", at: CGPoint(x: ch.minX + 16 * k, y: ch.maxY - 28 * k), size: 12, weight: .semibold, color: color("#6A7090"))
        let colors = ["#9DB3F7", "#8EA5F5", "#7C95F2", "#3C6DF0"]
        let labels = ["Q4", "Q1", "Q2", "Q3"]
        let values = ["3.1", "4.2", "3.8", "4.96"]
        for (i, b) in L.bars.enumerated() {
            let bb = v(b)
            color(colors[i]).setFill()
            NSBezierPath(roundedRect: bb, xRadius: 6 * k, yRadius: 6 * k).fill()
            text(labels[i], at: CGPoint(x: bb.midX - 11 * k, y: bb.minY - 22 * k), size: 12, color: color("#6A7090"))
            text(values[i], at: CGPoint(x: bb.midX - 12 * k, y: bb.maxY + 4 * k), size: 11, weight: .semibold, color: color("#2B3047"))
        }
        // Footer
        let s = v(L.slides)
        color("#E6E8F0").setFill()
        CGRect(x: s.minX + 40 * k, y: s.minY + 40 * k, width: 250 * k, height: 1).fill()
        text("Sample data for illustration", at: CGPoint(x: s.minX + 40 * k, y: s.minY + 18 * k), size: 11, color: color("#A0A6BE"))
    }
}
