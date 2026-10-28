//
//  AppController.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import ScreenCaptureKit
import AppKit
import Combine
import SwiftUI

/// Owns all windows, the capture stream and the tool state, and keeps them in sync with `AppState`.
@MainActor
final class AppController {
    let state: AppState

    private let capture = CaptureEngine()
    private let renderer: FrameRenderer
    var mirror: MirrorWindowController?
    let frameWindow = RegionFrameWindow()
    private var dimWindows: [DimOverlayWindow] = []
    let overlay = PresenterOverlayWindow()
    var controlBar: ControlBarPanel?
    private let keyMonitor = KeystrokeMonitor()
    private let urlWatcher = BrowserURLWatcher()
    var settingsWindow: NSWindow?

    private var cancellables = Set<AnyCancellable>()
    private var lastSettings: Settings
    private var last = (drawing: false, spotlight: false, zoom: false, keys: false, blurAll: false, timer: false, clicks: false)
    private var clickMonitor: Any?

    private var dragStartRegion: CGRect = .zero
    private var captureBusy = false, captureDirty = false, filterDirty = false
    private(set) var lastFrontApp: NSRunningApplication?

    private var presenterTimer: Timer?
    private var privacyTimer: Timer?
    private var privacyTicks = 0
    private var clockTimer: Timer?
    var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    var blurRects: [CGRect] = []
    /// Demo recording only: a stand-in mouse position, and extra windows of ours to include in the capture.
    var demoMouse: CGPoint?
    var demoIncludedWindows: Set<CGWindowID> = []
    private var urlMatchedPIDs = Set<pid_t>()
    private var timerStart: Date?
    private var timerElapsed: TimeInterval = 0
    private var activity: NSObjectProtocol?
    private var lastSeenWindowFrame: CGRect?

    init(state: AppState) {
        self.state = state
        renderer = FrameRenderer(queue: capture.queue)
        let r = state.settings.region
        if r.isEmpty || Geo.screen(containing: CGPoint(x: r.midX, y: r.midY)) == nil {
            state.settings.region = RegionMath.defaultRegion()
        }
        lastSettings = state.settings
        wire()
        applyToolSettings()
        registerHotkeys()
        updateControlBar()
    }

    // MARK: Wiring

    private func wire() {
        let renderer = self.renderer
        capture.onFrame = { pb in renderer.process(pb) }
        renderer.onOutput = { [weak self] surface in
            onMain { self?.mirror?.view.show(surface) }
        }
        capture.onStop = { [weak self] error in
            MainActor.assumeIsolated { self?.handleCaptureError(error) }
        }

        let fv = frameWindow.frameView
        fv.onBeginDrag = { [weak self] in
            MainActor.assumeIsolated { self?.dragStartRegion = self?.state.settings.region ?? .zero }
        }
        fv.onDrag = { [weak self] handle, delta in
            MainActor.assumeIsolated { self?.dragFrame(handle: handle, delta: delta) }
        }

        overlay.annotation.onHistoryChange = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let a = self.overlay.annotation
                if self.state.canUndo != a.canUndo { self.state.canUndo = a.canUndo }
                if self.state.canRedo != a.canRedo { self.state.canRedo = a.canRedo }
            }
        }

        overlay.onEscape = { [weak self] in
            MainActor.assumeIsolated { self?.state.isDrawing = false }
        }

        keyMonitor.onKey = { [weak self] label, typing in
            MainActor.assumeIsolated { self?.overlay.keystrokes.add(label, typing: typing) }
        }

        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.sync() } }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Displays changed: keep the hidden window off every display.
                if let m = self.mirror { m.setVisibility(self.state.settings.mirrorVisibility, region: self.state.settings.region) }
                self.controlBar?.keepOnScreen()
                self.setRegion(self.state.settings.region)
                self.layoutChrome()
                self.scheduleCapture()
            }
        }

        let ws = NSWorkspace.shared.notificationCenter
        lastFrontApp = NSWorkspace.shared.frontmostApplication
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self?.lastFrontApp = app
                }
            }
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let bundle = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let bundle else { return }
                if self.excludedBundles(self.state.settings).contains(bundle) { self.scheduleCapture(refreshFilter: true) }
            }
        }
    }

    /// Reacts to any change in `AppState`.
    private func sync() {
        let s = state.settings
        let old = lastSettings
        lastSettings = s

        if s != old {
            layoutChrome()
            applyToolSettings()
            if s.region != old.region || s.hideCursor != old.hideCursor || s.fps != old.fps
                || excludedBundles(s) != excludedBundles(old) {
                scheduleCapture()
            }
            if s.mirrorTitle != old.mirrorTitle || s.hideTitleBar != old.hideTitleBar {
                mirror?.apply(title: s.mirrorTitle, hideTitleBar: s.hideTitleBar)
            }
            if s.region.size != old.region.size || s.matchMirrorToFrame != old.matchMirrorToFrame
                || s.hideTitleBar != old.hideTitleBar {
                resizeMirror()
            }
            if s.mirrorVisibility == .hidden, let m = mirror,
               Geo.screen(for: s.region) != Geo.screen(for: old.region) || s.region.size != old.region.size {
                m.setVisibility(.hidden, region: s.region)
            }
            if s.mirrorVisibility != old.mirrorVisibility, let m = mirror {
                m.setVisibility(s.mirrorVisibility, region: s.region)
                resizeMirror()
            }
            if s.hotkeys != old.hotkeys { registerHotkeys() }
            if s.privacyRules != old.privacyRules || s.titleKeywords != old.titleKeywords
                || s.matchBrowserURLs != old.matchBrowserURLs {
                updatePrivacyTimer()
            }
            if s.timerMode != old.timerMode || s.countdownMinutes != old.countdownMinutes { updateClockText() }
            updateEffects()
        }

        if state.isDrawing != last.drawing {
            last.drawing = state.isDrawing
            applyDrawing(state.isDrawing)
        }
        if state.spotlightOn != last.spotlight || state.zoomOn != last.zoom {
            last.spotlight = state.spotlightOn
            if state.zoomOn != last.zoom { zoomCenter = currentMouseNormalized() ?? CGPoint(x: 0.5, y: 0.5) }
            last.zoom = state.zoomOn
            overlay.spotlight.enabled = state.spotlightOn
            if !state.zoomOn { frameWindow.frameView.zoomRect = nil }
            updatePresenterTimer()
            updateEffects()
        }
        if state.keystrokesOn != last.keys {
            last.keys = state.keystrokesOn
            if state.keystrokesOn {
                if !keyMonitor.start() {
                    state.statusMessage = "Allow FrameShare under Input Monitoring in System Settings to show keystrokes."
                    state.keystrokesOn = false
                    last.keys = false
                    Permissions.open(.inputMonitoring)
                }
            } else {
                keyMonitor.stop()
                overlay.keystrokes.clear()
            }
        }
        if state.blurAll != last.blurAll {
            last.blurAll = state.blurAll
            updateEffects()
        }
        if state.timerVisible != last.timer {
            last.timer = state.timerVisible
            updateClock()
        }
        if state.clicksOn != last.clicks || (clickMonitor != nil) != (state.clicksOn && state.isSharing) {
            last.clicks = state.clicksOn
            updateClickMonitor()
        }
        updateControlBar()
    }

    /// Click rings: watch clicks in other apps (no extra permission needed for mouse clicks).
    private func updateClickMonitor() {
        let needed = state.clicksOn && state.isSharing
        if needed && clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
                let right = e.type == .rightMouseDown
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let m = NSEvent.mouseLocation
                    let r = self.state.settings.region
                    guard r.contains(m) else { return }
                    self.overlay.clicks.add(at: CGPoint(x: m.x - r.minX, y: m.y - r.minY), right: right)
                }
            }
        } else if !needed, let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    private func applyToolSettings() {
        let s = state.settings
        let a = overlay.annotation
        if a.tool != s.tool { a.tool = s.tool }
        a.color = NSColor(hex: s.penColorHex) ?? .systemRed
        a.lineWidth = CGFloat(s.penWidth)
        a.fadeAfter = s.drawingFadeSeconds
        overlay.spotlight.radius = CGFloat(s.spotlightRadius)
        overlay.spotlight.dim = CGFloat(s.spotlightDim)
        overlay.spotlight.needsDisplay = true
        if overlay.timerBadge.corner != s.timerCorner { overlay.timerBadge.corner = s.timerCorner }
        keyMonitor.onlyShortcuts = s.keystrokesOnlyShortcuts
    }

    // MARK: Sharing

    func toggleSharing() { state.isSharing ? stopSharing() : startSharing() }

    func startSharing() {
        guard !state.isSharing else { return }
        if !Permissions.screenRecording { Permissions.requestScreenRecording() }
        state.statusMessage = nil
        state.isSharing = true
        // The shared window usually sits behind others; don't let macOS throttle us.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
            reason: "Sharing a screen area")
        let s = state.settings
        let m = MirrorWindowController()
        m.onClose = { [weak self] in MainActor.assumeIsolated { self?.stopSharing() } }
        m.onScreenChange = { [weak self] in MainActor.assumeIsolated { self?.resizeMirror() } }
        m.apply(title: s.mirrorTitle, hideTitleBar: s.hideTitleBar)
        m.window.setContentSize(s.region.size)
        m.setVisibility(s.mirrorVisibility, region: s.region)
        mirror = m
        resizeMirror()
        layoutChrome()
        if state.isDrawing { applyDrawing(true) }
        updatePresenterTimer()
        updatePrivacyTimer()
        updateClock()
        scheduleCapture()
    }

    func stopSharing() {
        guard state.isSharing else { return }
        state.isSharing = false
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        let engine = capture
        Task { await engine.stop() }
        renderer.reset()
        if let m = mirror {
            mirror = nil
            m.onClose = nil
            m.window.close()
        }
        state.isDrawing = false
        overlay.setDrawing(false)
        layoutChrome()
        updatePresenterTimer()
        updatePrivacyTimer()
    }

    /// Matches the shared window's pixel size to the frame so meeting apps get full detail.
    private func resizeMirror() {
        guard let m = mirror else { return }
        let s = state.settings
        if s.matchMirrorToFrame {
            let scale = Geo.screen(for: s.region)?.backingScaleFactor ?? 2
            m.matchPixels(of: s.region.size, regionScale: scale)
        } else {
            m.setAspect(s.region.size)
        }
    }

    func showMirrorWindow() {
        guard let m = mirror else { return }
        if state.settings.mirrorVisibility == .hidden { state.settings.mirrorVisibility = .visible }
        if m.window.isMiniaturized { m.window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        m.window.makeKeyAndOrderFront(nil)
    }

    private func excludedBundles(_ s: Settings) -> Set<String> {
        Set(s.privacyRules.filter { $0.mode == .exclude }.map(\.bundleID))
    }

    private func captureParams() -> CaptureParams? {
        let s = state.settings
        let r = s.region
        guard let screen = Geo.screen(for: r) else { return nil }
        let f = screen.frame
        let src = CGRect(x: r.minX - f.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
        // Native pixels of the display; only capped at the GPU texture limit.
        let scale = min(screen.backingScaleFactor, 8192 / r.width, 8192 / r.height)
        let out = CGSize(width: (r.width * scale).rounded(), height: (r.height * scale).rounded())
        return CaptureParams(displayID: screen.displayID, sourceRect: src, outputSize: out,
                             showsCursor: !s.hideCursor, fps: s.fps,
                             excludedBundleIDs: excludedBundles(s),
                             includedWindowIDs: Set([CGWindowID(overlay.windowNumber)]).union(demoIncludedWindows))
    }

    /// Applies the latest region/settings to the stream. Calls are coalesced while one is in flight.
    func scheduleCapture(refreshFilter: Bool = false) {
        guard state.isSharing else { return }
        if refreshFilter { filterDirty = true }
        captureDirty = true
        guard !captureBusy else { return }
        captureBusy = true
        Task { @MainActor in
            while self.captureDirty {
                self.captureDirty = false
                let refresh = self.filterDirty
                self.filterDirty = false
                guard self.state.isSharing, let p = self.captureParams() else { break }
                do {
                    try await self.capture.apply(p, refreshFilter: refresh)
                } catch {
                    self.handleCaptureError(error)
                    break
                }
            }
            if !self.state.isSharing { await self.capture.stop() }
            self.captureBusy = false
        }
    }

    private func handleCaptureError(_ error: Error) {
        guard state.isSharing else { return }
        stopSharing()
        let code = (error as NSError).domain == SCStreamErrorDomain ? (error as NSError).code : 0
        // Stopped from macOS's own screen-sharing control: that's a normal stop, not an error.
        if code == SCStreamError.Code.userStopped.rawValue { return }
        let permission = code == SCStreamError.Code.userDeclined.rawValue || !Permissions.screenRecording
        let alert = NSAlert()
        if permission {
            alert.messageText = "FrameShare can't capture the screen"
            alert.informativeText = """
            Turn on FrameShare under System Settings → Privacy & Security → Screen & System Audio Recording, \
            then quit and reopen FrameShare.

            (\(error.localizedDescription))
            """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")
        } else {
            alert.messageText = "Sharing stopped"
            alert.informativeText = "macOS stopped the screen capture (for example after sleep or a display change). Start sharing again to continue.\n\n(\(error.localizedDescription))"
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn && permission { Permissions.open(.screenRecording) }
    }

    // MARK: Region

    func setRegion(_ r: CGRect) {
        guard let screen = Geo.screen(for: r) else { return }
        let clamped = RegionMath.clamp(r, to: screen.frame, ratio: state.settings.ratio.value)
        if clamped != state.settings.region { state.settings.region = clamped }
    }

    func setRatio(_ ratio: AspectRatio) {
        state.settings.ratio = ratio
        let r = state.settings.region
        guard let screen = Geo.screen(for: r) else { return }
        state.settings.region = RegionMath.applyRatio(r, ratio: ratio.value, within: screen.frame)
    }

    /// Size and position from the menu, in points; x/y measured from the display's top-left corner.
    func applyNumbers(width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat, changedHeight: Bool) {
        guard let screen = Geo.screen(for: state.settings.region) else { return }
        var w = width, h = height
        if let ratio = state.settings.ratio.value {
            if changedHeight { w = h * ratio } else { h = w / ratio }
        }
        let f = screen.frame
        let r = CGRect(x: f.minX + x, y: f.maxY - y - h, width: w, height: h)
        state.settings.region = RegionMath.clamp(r, to: f, ratio: state.settings.ratio.value)
    }

    func quickPosition(_ p: QuickPosition) {
        let r = state.settings.region
        guard let vf = Geo.screen(for: r)?.visibleFrame else { return }
        state.settings.region = RegionMath.quick(r, p, in: vf, ratio: state.settings.ratio.value)
    }

    private var lastSideSnap: (side: Side, step: Int, rect: CGRect)?

    /// Snaps to the left/right half of the screen. Pressing again cycles ½ → ⅔ → ⅓.
    func snapHalf(_ side: Side) {
        let r = state.settings.region
        guard let vf = Geo.screen(for: r)?.visibleFrame else { return }
        let fractions: [CGFloat] = [1.0 / 2, 2.0 / 3, 1.0 / 3]
        var step = 0
        if let last = lastSideSnap, last.side == side, last.rect == r { step = (last.step + 1) % fractions.count }
        let target = RegionMath.side(side, fraction: fractions[step], in: vf)
        state.settings.ratio = .free
        state.settings.region = target
        lastSideSnap = (side, step, target)
    }

    func fullHeight() {
        let r = state.settings.region
        guard let vf = Geo.screen(for: r)?.visibleFrame else { return }
        state.settings.region = RegionMath.fullHeight(r, in: vf, ratio: state.settings.ratio.value)
    }

    private func dragFrame(handle: Handle?, delta: CGPoint) {
        let start = dragStartRegion
        let ratio = state.settings.ratio.value
        if let handle {
            guard let bounds = Geo.screen(for: start)?.frame else { return }
            state.settings.region = RegionMath.resize(start, handle: handle, by: delta, ratio: ratio, within: bounds)
        } else {
            guard let mouseScreen = Geo.screen(containing: NSEvent.mouseLocation) ?? Geo.screen(for: start) else { return }
            var moved = start.offsetBy(dx: delta.x, dy: delta.y)
            if !mouseScreen.frame.contains(CGPoint(x: moved.midX, y: moved.midY)) || moved.width > mouseScreen.frame.width
                || moved.height > mouseScreen.frame.height {
                moved = RegionMath.clamp(moved, to: mouseScreen.frame, ratio: ratio)
            }
            state.settings.region = RegionMath.move(moved, by: .zero, within: mouseScreen.frame)
        }
    }

    // MARK: Snap

    private func ensureAccessibility() -> Bool {
        if Permissions.accessibility { return true }
        Permissions.requestAccessibility()
        state.statusMessage = "Allow FrameShare under Accessibility in System Settings, then try again."
        return false
    }

    func snapFrameToWindow() {
        guard ensureAccessibility() else { return }
        guard let app = lastFrontApp, let cg = WindowSnapper.focusedWindowFrame(pid: app.processIdentifier) else {
            NSSound.beep(); return
        }
        state.settings.ratio = .free
        setRegion(Geo.flip(cg))
    }

    func fitWindowToFrame() {
        guard ensureAccessibility() else { return }
        lastSeenWindowFrame = nil
        guard let app = lastFrontApp,
              WindowSnapper.setFocusedWindowFrame(pid: app.processIdentifier, Geo.flip(state.settings.region)) else {
            NSSound.beep(); return
        }
        // macOS or the app may refuse the exact frame (menu bar, minimum sizes, Terminal's
        // character grid). Read back where the window really went and make the frame match it.
        alignFrameToWindow(pid: app.processIdentifier, attempt: 0)
    }

    private func alignFrameToWindow(pid: pid_t, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let cg = WindowSnapper.focusedWindowFrame(pid: pid) else { return }
                let actual = Geo.flip(cg)
                let region = self.state.settings.region
                if actual == region { self.lastSeenWindowFrame = nil; self.state.statusMessage = nil; return }
                if attempt < 3 && actual != self.lastSeenWindowFrame {
                    // The window may still be settling; check again shortly.
                    self.lastSeenWindowFrame = actual
                    self.alignFrameToWindow(pid: pid, attempt: attempt + 1)
                    return
                }
                self.lastSeenWindowFrame = nil
                if actual.size != region.size { self.state.settings.ratio = .free }
                self.setRegion(actual)
                self.state.statusMessage = actual.maxY > region.maxY || actual.minY < region.minY || actual.minX != region.minX
                    ? "The window couldn't go exactly there (e.g. under the menu bar), so the frame moved to match it."
                    : nil
            }
        }
    }

    // MARK: Chrome (frame, dimming, overlay)

    func layoutChrome() {
        let s = state.settings
        let r = s.region
        let sharing = state.isSharing

        if sharing && s.showFrame {
            frameWindow.layout(region: r, settings: s, zoomRect: state.zoomOn ? zoomRect() : nil)
            frameWindow.orderFrontRegardless()
        } else {
            frameWindow.orderOut(nil)
        }

        if sharing {
            if overlay.frame != r { overlay.setFrame(r, display: true) }
            overlay.orderFrontRegardless()
        } else {
            overlay.orderOut(nil)
        }

        if sharing && s.dimOutside {
            let screens = NSScreen.screens
            let ids = Set(screens.map(\.displayID))
            dimWindows.filter { !ids.contains($0.screenID) }.forEach { $0.orderOut(nil) }
            dimWindows.removeAll { !ids.contains($0.screenID) }
            let d = CGFloat(s.padding + s.borderWidth)
            for screen in screens {
                let w = dimWindows.first { $0.screenID == screen.displayID } ?? {
                    let w = DimOverlayWindow(screen: screen)
                    dimWindows.append(w)
                    return w
                }()
                w.update(screenFrame: screen.frame, hole: r.insetBy(dx: -d, dy: -d), opacity: CGFloat(s.dimOpacity))
                w.orderFrontRegardless()
            }
        } else {
            dimWindows.forEach { $0.orderOut(nil) }
        }
    }

    // MARK: Drawing

    private func applyDrawing(_ on: Bool) {
        guard state.isSharing || !on else { return }
        overlay.setDrawing(on)
        if on {
            NSApp.activate(ignoringOtherApps: true)
            overlay.makeKeyAndOrderFront(nil)
        } else {
            if NSApp.isActive, let app = lastFrontApp { app.activate(options: []) }
        }
    }

    func clearDrawings() { overlay.annotation.clear() }
    func undoDrawing() { overlay.annotation.undo() }
    func redoDrawing() { overlay.annotation.redo() }

    /// Control bar: start drawing with a tool (switches straight from the mouse).
    func selectTool(_ tool: DrawTool) {
        guard state.isSharing else { NSSound.beep(); return }
        state.settings.tool = tool
        state.isDrawing = true
    }

    /// Control bar: back to the normal mouse pointer.
    func selectPointer() { state.isDrawing = false }

    // MARK: Control bar

    private func updateControlBar() {
        let s = state.settings
        let show = state.isDrawing || s.controlBarMode == .always || (s.controlBarMode == .whileSharing && state.isSharing)
        guard show else { controlBar?.orderOut(nil); return }
        let bar: ControlBarPanel
        if let existing = controlBar {
            bar = existing
        } else {
            let view = ControlBarView(state: state, controller: self) { [weak self] size in
                MainActor.assumeIsolated { self?.controlBar?.resize(to: size) }
            }
            bar = ControlBarPanel(content: AnyView(view))
            bar.onMoved = { [weak self, weak bar] topLeft in
                MainActor.assumeIsolated {
                    guard let self, let bar, !self.barPositionLocked, bar.isVisible else { return }
                    if self.state.settings.controlBarTopLeft != topLeft { self.state.settings.controlBarTopLeft = topLeft }
                }
            }
            controlBar = bar
        }
        guard !bar.isVisible else { return }
        barPositionLocked = true
        bar.move(topLeft: s.controlBarTopLeft ?? defaultBarTopLeft(width: bar.frame.width))
        bar.orderFrontRegardless()
        barPositionLocked = false
    }

    private var barPositionLocked = false

    /// Default spot: top center of the frame's display.
    private func defaultBarTopLeft(width: CGFloat) -> CGPoint {
        let vf = (Geo.screen(for: state.settings.region) ?? NSScreen.main)?.visibleFrame ?? .zero
        return CGPoint(x: vf.midX - width / 2, y: vf.maxY - 12)
    }

    func resetControlBarPosition() {
        state.settings.controlBarTopLeft = nil
        guard let bar = controlBar, bar.isVisible else { return }
        barPositionLocked = true
        bar.move(topLeft: defaultBarTopLeft(width: bar.frame.width))
        barPositionLocked = false
    }

    func toggleControlBar() {
        state.settings.controlBarMode = state.settings.controlBarMode == .whileDrawing ? .whileSharing : .whileDrawing
    }

    // MARK: Spotlight & zoom

    private func currentMouseNormalized() -> CGPoint? {
        let m = demoMouse ?? NSEvent.mouseLocation
        let r = state.settings.region
        guard r.contains(m) else { return nil }
        return CGPoint(x: (m.x - r.minX) / r.width, y: (r.maxY - m.y) / r.height)
    }

    private func zoomRect() -> CGRect {
        let z = CGFloat(max(1, state.settings.zoomFactor))
        let w = 1 / z
        let x = min(max(0, zoomCenter.x - w / 2), 1 - w)
        let y = min(max(0, zoomCenter.y - w / 2), 1 - w)
        return CGRect(x: x, y: y, width: w, height: w)
    }

    private func updatePresenterTimer() {
        let needed = state.isSharing && (state.spotlightOn || state.zoomOn)
        if needed && presenterTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.presenterTick() }
            }
            RunLoop.main.add(t, forMode: .common)
            presenterTimer = t
        } else if !needed {
            presenterTimer?.invalidate()
            presenterTimer = nil
        }
    }

    private func presenterTick() {
        let m = demoMouse ?? NSEvent.mouseLocation
        let r = state.settings.region
        if state.spotlightOn {
            overlay.spotlight.center = CGPoint(x: m.x - r.minX, y: m.y - r.minY)
        }
        if state.zoomOn {
            if let target = currentMouseNormalized() {
                let dx = target.x - zoomCenter.x, dy = target.y - zoomCenter.y
                if abs(dx) > 0.0005 || abs(dy) > 0.0005 {
                    zoomCenter.x += dx * 0.2
                    zoomCenter.y += dy * 0.2
                    updateEffects()
                }
            }
            frameWindow.frameView.zoomRect = zoomRect()
        }
    }

    // MARK: Effects (blur + zoom)

    func updateEffects() {
        let s = state.settings
        let fx = RenderEffects(
            blurRects: state.isSharing ? blurRects : [],
            blurAll: state.blurAll,
            blurRadius: CGFloat(s.blurRadius),
            zoom: state.zoomOn ? CGFloat(s.zoomFactor) : 1,
            zoomCenter: zoomCenter)
        if fx != renderer.effects {
            renderer.effects = fx
            renderer.rerender()
        }
    }

    private func updatePrivacyTimer() {
        let s = state.settings
        let needed = state.isSharing && (s.privacyRules.contains { $0.mode == .blur } || !s.titleKeywords.isEmpty)
        if needed && privacyTimer == nil {
            let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.privacyTick() }
            }
            RunLoop.main.add(t, forMode: .common)
            privacyTimer = t
            privacyTick()
        } else if !needed {
            privacyTimer?.invalidate()
            privacyTimer = nil
            blurRects = []
            urlMatchedPIDs = []
            updateEffects()
        }
    }

    private func privacyTick() {
        let s = state.settings
        privacyTicks += 1
        if s.matchBrowserURLs && !s.titleKeywords.isEmpty && privacyTicks % 5 == 0 {
            urlWatcher.check(keywords: s.titleKeywords) { [weak self] pids in
                MainActor.assumeIsolated { self?.urlMatchedPIDs = pids }
            }
        } else if !s.matchBrowserURLs {
            urlMatchedPIDs = []
        }
        let blurBundles = Set(s.privacyRules.filter { $0.mode == .blur }.map(\.bundleID))
        let rects = BlurTracker.compute(region: s.region, blurBundles: blurBundles,
                                        hiddenBundles: excludedBundles(s), keywords: s.titleKeywords, urlMatchedPIDs: urlMatchedPIDs)
        if rects != blurRects {
            blurRects = rects
            updateEffects()
        }
    }

    // MARK: Timer

    var timerElapsedNow: TimeInterval {
        timerElapsed + (timerStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    func startPauseTimer() {
        if let start = timerStart {
            timerElapsed += Date().timeIntervalSince(start)
            timerStart = nil
            state.timerRunning = false
        } else {
            timerStart = Date()
            state.timerRunning = true
        }
        updateClockText()
    }

    func resetTimer() {
        timerElapsed = 0
        timerStart = state.timerRunning ? Date() : nil
        updateClockText()
    }

    private func updateClock() {
        if state.timerVisible {
            if clockTimer == nil {
                let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateClockText() }
                }
                RunLoop.main.add(t, forMode: .common)
                clockTimer = t
            }
        } else {
            clockTimer?.invalidate()
            clockTimer = nil
        }
        updateClockText()
    }

    private func updateClockText() {
        let s = state.settings
        let elapsed = timerElapsedNow
        let text: String
        var alert = false
        if s.timerMode == .stopwatch {
            text = Self.format(elapsed)
        } else {
            let remaining = Double(s.countdownMinutes * 60) - elapsed
            alert = remaining <= 0
            text = remaining >= 0 ? Self.format(remaining.rounded(.up)) : "−" + Self.format(-remaining)
        }
        if state.timerText != text { state.timerText = text }
        overlay.timerBadge.alert = alert
        overlay.timerBadge.text = state.timerVisible ? text : nil
    }

    private static func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: Hotkeys

    private func registerHotkeys() {
        HotkeyCenter.shared.register(state.settings.hotkeys) { [weak self] action in
            self?.perform(action)
        }
    }

    func perform(_ action: HotkeyAction) {
        switch action {
        case .toggleSharing: toggleSharing()
        case .toggleDrawing: if state.isSharing { state.isDrawing.toggle() } else { NSSound.beep() }
        case .clearDrawings: clearDrawings()
        case .toggleSpotlight: state.spotlightOn.toggle()
        case .toggleZoom: state.zoomOn.toggle()
        case .toggleTimer:
            if state.timerVisible {
                state.timerVisible = false
                if state.timerRunning { startPauseTimer() }
            } else {
                state.timerVisible = true
                timerElapsed = 0
                timerStart = nil
                state.timerRunning = false
                startPauseTimer()
            }
        case .toggleKeystrokes: state.keystrokesOn.toggle()
        case .toggleBlurAll: state.blurAll.toggle()
        case .toggleHideCursor: state.settings.hideCursor.toggle()
        case .snapFrameToWindow: snapFrameToWindow()
        case .fitWindowToFrame: fitWindowToFrame()
        case .positionLeft: quickPosition(.left)
        case .positionCenter: quickPosition(.center)
        case .positionRight: quickPosition(.right)
        case .halfLeft: snapHalf(.left)
        case .halfRight: snapHalf(.right)
        case .toggleControlBar: toggleControlBar()
        case .toggleClicks: state.clicksOn.toggle()
        }
    }

    // MARK: Settings window

    func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(state: state, controller: self))
            let w = NSWindow(contentViewController: host)
            w.title = "FrameShare Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Self-test

    /// `open -n FrameShare.app --args --selftest`: shares for a few seconds, then compares what a
    /// meeting app would capture from the shared window with the real screen, pixel by pixel.
    /// Results go to ~/Library/Caches/FrameShare-selftest/.
    func runSelfTest() async {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/FrameShare-selftest")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var report: [String: Any] = ["screenRecordingPermission": Permissions.screenRecording]
        defer {
            stopSharing()
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("report.json"))
            }
            NSApp.terminate(nil)
        }
        startSharing()
        try? await Task.sleep(for: .seconds(3))
        guard let m = mirror, let p = captureParams() else { report["error"] = "sharing did not start"; return }
        let scale = m.window.backingScaleFactor
        let content = m.window.contentRect(forFrameRect: m.window.frame)
        report["captureOutputPx"] = [p.outputSize.width, p.outputSize.height]
        report["mirrorContentPx"] = [content.width * scale, content.height * scale]
        report["mirrorSurfacePx"] = [m.view.surfaceSize.width, m.view.surfaceSize.height]
        report["pixelExact"] = m.view.isPixelExact
        report["mirrorWindowFrame"] = NSStringFromRect(m.window.frame)
        report["screenVisibleFrame"] = NSStringFromRect(m.window.screen?.visibleFrame ?? .zero)
        report["fps"] = p.fps
        report["mirrorVisibility"] = state.settings.mirrorVisibility.rawValue
        report["mirrorBackingScale"] = scale
        report["mirrorIntersectsAnyDisplay"] = NSScreen.screens.contains { $0.frame.intersects(m.window.frame) }
        let wid = CGWindowID(m.window.windowNumber)
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
           let info = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == wid }) {
            report["cgListedOnScreen"] = true
            report["cgLayer"] = info[kCGWindowLayer as String] as? Int
            report["cgTitle"] = info[kCGWindowName as String] as? String
        } else {
            report["cgListedOnScreen"] = false
        }
        do {
            // onScreenWindowsOnly: true is what window pickers in meeting apps typically ask for.
            let sc = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            report["sckListedOnScreen"] = sc.windows.contains { $0.windowID == wid }
            guard let display = sc.displays.first(where: { $0.displayID == p.displayID }),
                  let win = sc.windows.first(where: { $0.windowID == CGWindowID(m.window.windowNumber) }) else {
                report["error"] = "display or window not found"; return
            }
            let me = sc.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let keep = sc.windows.filter { p.includedWindowIDs.contains($0.windowID) }
            let c1 = SCStreamConfiguration()
            c1.sourceRect = p.sourceRect
            c1.width = Int(p.outputSize.width); c1.height = Int(p.outputSize.height)
            c1.showsCursor = false
            c1.captureResolution = .best
            // Put the control bar in the middle of the shared area: viewers must not see it.
            let savedBarSpot = state.settings.controlBarTopLeft
            var barRectPx: CGRect?
            if let bar = controlBar, bar.isVisible {
                let r = state.settings.region
                barPositionLocked = true
                bar.move(topLeft: CGPoint(x: (r.midX - bar.frame.width / 2).rounded(), y: (r.midY + bar.frame.height / 2).rounded()))
                barPositionLocked = false
                try? await Task.sleep(for: .milliseconds(500))
                let k = p.outputSize.width / r.width
                barRectPx = CGRect(x: (bar.frame.minX - r.minX) * k, y: (r.maxY - bar.frame.maxY) * k,
                                   width: bar.frame.width * k, height: bar.frame.height * k).integral
                report["controlBarInsideFrame"] = r.contains(bar.frame)
            }
            defer {
                state.settings.controlBarTopLeft = savedBarSpot
                if let bar = controlBar, let spot = savedBarSpot { barPositionLocked = true; bar.move(topLeft: spot); barPositionLocked = false }
            }
            report["step"] = "screen capture"
            let truth = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: keep),
                configuration: c1)
            let c2 = SCStreamConfiguration()
            c2.width = Int(win.frame.width * scale); c2.height = Int(win.frame.height * scale)
            c2.showsCursor = false
            c2.captureResolution = .best
            c2.ignoreShadowsSingleWindow = true
            report["step"] = "window screenshot"
            let whole = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: c2)
            let titlePx = Int(((m.window.frame.height - content.height) * scale).rounded())
            let shared = whole.cropping(to: CGRect(x: 0, y: titlePx, width: whole.width, height: whole.height - titlePx)) ?? whole
            Self.savePNG(truth, dir.appendingPathComponent("1-screen.png"))
            Self.savePNG(shared, dir.appendingPathComponent("2-shared-window.png"))
            report["screenPx"] = [truth.width, truth.height]
            report["sharedWindowPx"] = [shared.width, shared.height]
            if truth.width == shared.width && truth.height == shared.height,
               let a = Self.rgba(truth), let b = Self.rgba(shared) {
                var sum = 0, maxd = 0, big = 0
                for i in stride(from: 0, to: a.count, by: 4) {
                    let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
                    sum += d; maxd = max(maxd, d); if d > 8 { big += 1 }
                }
                let n = a.count / 4
                report["meanDiff"] = Double(sum) / Double(n)
                report["maxDiff"] = maxd
                report["percentPixelsDiffOver8"] = Double(big) * 100 / Double(n)
            } else {
                report["note"] = "sizes differ, so the shared window is being rescaled"
            }
            if let br = barRectPx, let a = Self.rgba(truth), let b = Self.rgba(shared) {
                // Same spot on the raw screen (nothing excluded), where the bar IS visible.
                let rawCfg = SCStreamConfiguration()
                rawCfg.sourceRect = p.sourceRect
                rawCfg.width = Int(p.outputSize.width); rawCfg.height = Int(p.outputSize.height)
                rawCfg.showsCursor = false
                let raw = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: rawCfg)
                Self.savePNG(raw, dir.appendingPathComponent("3-raw-screen-with-bar.png"))
                if let c = Self.rgba(raw), raw.width == truth.width {
                    report["bar_viewersVsScreenWithoutBar"] = Self.meanDiff(a, b, width: truth.width, in: br)
                    report["bar_rawScreenVsScreenWithoutBar"] = Self.meanDiff(c, a, width: truth.width, in: br)
                }
            }
            report["step"] = "window stream"
            // Live updates: stream the shared window like a meeting app, while the content changes.
            let counter = FrameCounter()
            let cfg = SCStreamConfiguration()
            cfg.width = c2.width; cfg.height = c2.height
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg, delegate: nil)
            try stream.addStreamOutput(counter, type: .screen, sampleHandlerQueue: DispatchQueue(label: "selftest.count"))
            try await stream.startCapture()
            for _ in 0..<20 { // flip "blur everything" 20 times over 2 seconds
                state.blurAll.toggle()
                try? await Task.sleep(for: .milliseconds(100))
            }
            try await stream.stopCapture()
            state.blurAll = false
            report["liveFramesWhileChanging20Times"] = counter.count
            report["step"] = "done"
        } catch {
            report["error"] = "\(error)"
        }
    }

    /// Mean per-pixel difference of two RGBA buffers inside a rect.
    private static func meanDiff(_ a: [UInt8], _ b: [UInt8], width: Int, in r: CGRect) -> Double {
        let height = a.count / 4 / width
        let x0 = max(0, Int(r.minX)), x1 = min(width, Int(r.maxX))
        let y0 = max(0, Int(r.minY)), y1 = min(height, Int(r.maxY))
        guard x1 > x0, y1 > y0 else { return -1 }
        var sum = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                sum += max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
            }
        }
        return Double(sum) / Double((x1 - x0) * (y1 - y0))
    }

    static func savePNG(_ img: CGImage, _ url: URL) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func rgba(_ img: CGImage) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let space = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: img.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return buf
    }

    // MARK: Snap self-test

    /// `open -n FrameShare.app --args --selftest-snap`: drives a TextEdit window through both snap
    /// actions and records where the window and frame really end up. Report in ~/Library/Caches/FrameShare-selftest/.
    func runSnapTest() async {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/FrameShare-selftest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var report: [String: Any] = ["accessibility": Permissions.accessibility]
        var rows: [[String: Any]] = []
        let savedRegion = state.settings.region, savedRatio = state.settings.ratio
        defer {
            state.settings.ratio = savedRatio
            state.settings.region = savedRegion
            report["results"] = rows
            if let d = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: dir.appendingPathComponent("snap-report.json"))
            }
            NSApp.terminate(nil)
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
            report["error"] = "TextEdit not running"; return
        }
        let pid = app.processIdentifier
        func actual() -> CGRect? {
            guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
            for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
                if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) {
                    return Geo.flip(r)
                }
            }
            return nil
        }
        func str(_ r: CGRect?) -> String { r.map { NSStringFromRect($0) } ?? "nil" }
        let screen = NSScreen.main!
        let vf = screen.visibleFrame, f = screen.frame
        report["screenFrame"] = str(f); report["visibleFrame"] = str(vf)

        // Window -> Frame, for several frames (including the halves and odd sizes)
        state.settings.ratio = .free
        let frames: [(String, CGRect)] = [
            ("plain", CGRect(x: vf.minX + 101, y: vf.minY + 77, width: 801, height: 503)),
            ("leftHalf", RegionMath.side(.left, fraction: 0.5, in: vf)),
            ("rightThird", RegionMath.side(.right, fraction: 1.0 / 3, in: vf)),
            ("touchesMenuBar", CGRect(x: f.minX + 300, y: f.maxY - 600, width: 900, height: 600)),
        ]
        for (name, target) in frames {
            state.settings.region = target
            lastFrontApp = app
            fitWindowToFrame()
            try? await Task.sleep(for: .milliseconds(700))
            rows.append(["test": "windowToFrame/\(name)", "frame": str(state.settings.region), "window": str(actual())])
        }

        // Frame -> Window, with the window at several places
        let windows: [CGRect] = [
            CGRect(x: vf.minX + 213, y: vf.minY + 151, width: 777, height: 555),
            CGRect(x: vf.minX + 40, y: vf.minY + 20, width: 1203, height: 699),
        ]
        for (i, w) in windows.enumerated() {
            WindowSnapper.setFocusedWindowFrame(pid: pid, Geo.flip(w))
            try? await Task.sleep(for: .milliseconds(700))
            let before = actual()
            state.settings.ratio = .r16x9
            lastFrontApp = app
            snapFrameToWindow()
            rows.append(["test": "frameToWindow/\(i)", "window": str(before), "frame": str(state.settings.region),
                         "ratioAfter": state.settings.ratio.rawValue])
        }

        // Ratio rounding: what clamp does to a 16:9 frame with a fractional width
        let r = RegionMath.clamp(CGRect(x: 100.4, y: 100.6, width: 1000.3, height: 562.67), to: f, ratio: 16.0 / 9)
        rows.append(["test": "clamp16x9", "result": str(r), "ratio": r.width / r.height])
    }

    // MARK: Hidden-window probe

    /// `--selftest-hidden`: tries several ways of keeping the shared window invisible and checks,
    /// for each, whether a meeting app could still list it, capture it exactly, and get live updates.
    func runHiddenProbe() async {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/FrameShare-selftest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var results: [[String: Any]] = []
        defer {
            stopSharing()
            if let d = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: dir.appendingPathComponent("hidden-report.json"))
            }
            NSApp.terminate(nil)
        }
        state.settings.mirrorVisibility = .behind
        startSharing()
        try? await Task.sleep(for: .seconds(2))
        guard let m = mirror, let p = captureParams(), let screen = Geo.screen(for: state.settings.region) else { return }
        let w = m.window
        let size = w.frame.size
        let vf = screen.visibleFrame
        _ = vf
        let variants: [(String, CGPoint, CGFloat)] = [
            ("hidden mode: 1x1pt corner", MirrorWindowController.hiddenOrigin(size: size, region: state.settings.region), 1),
            ("fully off-screen", CGPoint(x: screen.frame.maxX + 4000, y: screen.frame.minY), 1),
        ]
        for (name, origin, alpha) in variants {
            var row: [String: Any] = ["variant": name]
            w.alphaValue = alpha
            w.setFrame(CGRect(origin: origin, size: size), display: true)
            w.orderBack(nil)
            try? await Task.sleep(for: .milliseconds(800))
            let wid = CGWindowID(w.windowNumber)
            do {
                let sc = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let win = sc.windows.first(where: { $0.windowID == wid }),
                      let display = sc.displays.first(where: { $0.displayID == p.displayID }) else {
                    row["listed"] = false; results.append(row); continue
                }
                row["listed"] = true
                let scale = w.backingScaleFactor
                let me = sc.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let keep = sc.windows.filter { p.includedWindowIDs.contains($0.windowID) }
                let c1 = SCStreamConfiguration()
                c1.sourceRect = p.sourceRect
                c1.width = Int(p.outputSize.width); c1.height = Int(p.outputSize.height)
                c1.showsCursor = false
                let truth = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: keep), configuration: c1)
                let c2 = SCStreamConfiguration()
                c2.width = Int(win.frame.width * scale); c2.height = Int(win.frame.height * scale)
                c2.showsCursor = false
                c2.ignoreShadowsSingleWindow = true
                let whole = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: c2)
                let content = w.contentRect(forFrameRect: w.frame)
                let titlePx = Int(((w.frame.height - content.height) * scale).rounded())
                let shared = whole.cropping(to: CGRect(x: 0, y: titlePx, width: whole.width, height: whole.height - titlePx)) ?? whole
                Self.savePNG(shared, dir.appendingPathComponent("hidden-\(results.count).png"))
                row["capturedPx"] = [shared.width, shared.height]
                if truth.width == shared.width && truth.height == shared.height, let a = Self.rgba(truth), let b = Self.rgba(shared) {
                    var sum = 0, big = 0
                    for i in stride(from: 0, to: a.count, by: 4) {
                        let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
                        sum += d; if d > 8 { big += 1 }
                    }
                    row["meanDiff"] = Double(sum) / Double(a.count / 4)
                    row["percentPixelsDiffOver8"] = Double(big) * 100 / Double(a.count / 4)
                }
                let counter = FrameCounter()
                let cfg = SCStreamConfiguration()
                cfg.width = c2.width; cfg.height = c2.height
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg, delegate: nil)
                try stream.addStreamOutput(counter, type: .screen, sampleHandlerQueue: DispatchQueue(label: "probe.count"))
                try await stream.startCapture()
                for _ in 0..<20 { state.blurAll.toggle(); try? await Task.sleep(for: .milliseconds(100)) }
                try await stream.stopCapture()
                state.blurAll = false
                row["liveFrames"] = counter.count
            } catch {
                row["error"] = "\(error.localizedDescription)"
            }
            results.append(row)
        }
        w.alphaValue = 1
        state.settings.mirrorVisibility = .hidden
    }
}

/// Counts complete frames from a stream (self-test only).
final class FrameCounter: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = a.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        lock.lock(); n += 1; lock.unlock()
    }
}
