//
//  ControlBar.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit
import SwiftUI

/// Floating, draggable control bar with the presenter tools.
/// It belongs to FrameShare, whose windows are all left out of the capture, so viewers never see it.
/// It never takes keyboard focus, so clicking it doesn't pull focus from the app you're presenting.
final class ControlBarPanel: NSPanel {
    /// Called with the new top-left corner whenever the bar moves.
    var onMoved: ((CGPoint) -> Void)?

    init(content: AnyView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = Levels.toolbar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = FirstClickHostingView(rootView: content)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onMoved?(CGPoint(x: self.frame.minX, y: self.frame.maxY))
            }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Resizes to fit the content, keeping the top-left corner in place.
    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        let top = frame.maxY
        setFrame(CGRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        keepOnScreen()
    }

    func move(topLeft p: CGPoint) {
        setFrameTopLeftPoint(p)
        keepOnScreen()
    }

    /// Pulls the bar back fully onto the display it's on (or the main one).
    func keepOnScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var f = frame
        f.origin.x = min(max(vf.minX, f.minX), vf.maxX - f.width)
        f.origin.y = min(max(vf.minY, f.minY), vf.maxY - f.height)
        if f != frame { setFrame(f, display: true) }
    }
}

/// Buttons react to the first click even though the bar never becomes the key window.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - SwiftUI content

private struct BarSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct ControlBarView: View {
    @ObservedObject var state: AppState
    let controller: AppController
    let onSize: (CGSize) -> Void

    static let palette = ["#FF3B30", "#FFCC00", "#34C759", "#0A84FF", "#FFFFFF", "#000000"]
    static let widths: [Double] = [2, 5, 10]

    private var vertical: Bool { state.settings.controlBarVertical }
    private var expanded: Bool { state.settings.controlBarExpanded }

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
        layout {
            DragGrip(vertical: vertical)
                .frame(width: vertical ? 28 : 12, height: vertical ? 12 : 28)
                .help("Drag to move")
            if expanded { expandedContent } else { collapsedContent }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .fixedSize()
        .background(GeometryReader { g in Color.clear.preference(key: BarSizeKey.self, value: g.size) })
        .onPreferenceChange(BarSizeKey.self) { onSize($0) }
    }

    // Collapsed: pointer/draw switch, share button, expand.
    @ViewBuilder private var collapsedContent: some View {
        BarButton(symbol: state.isDrawing ? state.settings.tool.symbol : "cursorarrow",
                  active: state.isDrawing, enabled: state.isSharing,
                  help: (state.isDrawing ? "Back to the mouse" : "Draw with \(state.settings.tool.rawValue)") + hint(.toggleDrawing)) {
            state.isDrawing ? controller.selectPointer() : controller.selectTool(state.settings.tool)
        }
        shareButton
        BarButton(symbol: vertical ? "chevron.down" : "chevron.right", help: "Show all tools") {
            state.settings.controlBarExpanded = true
        }
    }

    @ViewBuilder private var expandedContent: some View {
        // Pointer + drawing tools
        BarButton(symbol: "cursorarrow", active: !state.isDrawing, help: "Pointer: use the mouse normally" + hint(.toggleDrawing)) {
            controller.selectPointer()
        }
        ForEach(DrawTool.allCases) { t in
            BarButton(symbol: t.symbol, active: state.isDrawing && state.settings.tool == t, enabled: state.isSharing,
                      help: state.isSharing ? t.rawValue.capitalized : "Start sharing to draw") {
                controller.selectTool(t)
            }
        }
        if state.isDrawing {
            separator
            ForEach(Self.palette, id: \.self) { hex in
                Button { state.settings.penColorHex = hex } label: {
                    Circle().fill(Color(nsColor: NSColor(hex: hex) ?? .red))
                        .frame(width: 15, height: 15)
                        .overlay(Circle().stroke(state.settings.penColorHex == hex ? Color.accentColor : Color.gray.opacity(0.6),
                                                 lineWidth: state.settings.penColorHex == hex ? 2.5 : 1))
                        .frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            separator
            ForEach(Self.widths, id: \.self) { w in
                Button { state.settings.penWidth = w } label: {
                    Circle().fill(Color.primary)
                        .frame(width: 3 + w * 0.8, height: 3 + w * 0.8)
                        .frame(width: 24, height: 28)
                        .background(abs(state.settings.penWidth - w) < 0.5 ? Color.accentColor.opacity(0.3) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Line width \(Int(w))")
            }
            separator
            BarButton(symbol: "arrow.uturn.backward", enabled: state.canUndo, help: "Undo (⌘Z)") { controller.undoDrawing() }
            BarButton(symbol: "arrow.uturn.forward", enabled: state.canRedo, help: "Redo (⇧⌘Z)") { controller.redoDrawing() }
            BarButton(symbol: "trash", enabled: state.canUndo || state.canRedo, help: "Clear drawings (undoable)" + hint(.clearDrawings)) {
                controller.clearDrawings()
            }
        }
        separator
        // Presenter tools
        BarButton(symbol: "light.max", active: state.spotlightOn, help: "Spotlight" + hint(.toggleSpotlight)) { state.spotlightOn.toggle() }
        BarButton(symbol: "plus.magnifyingglass", active: state.zoomOn, help: "Zoom" + hint(.toggleZoom)) { state.zoomOn.toggle() }
        BarButton(symbol: "timer", active: state.timerVisible, help: "Timer" + hint(.toggleTimer)) { state.timerVisible.toggle() }
        if state.timerVisible {
            Text(state.timerText)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(minWidth: 44, minHeight: 28)
            BarButton(symbol: state.timerRunning ? "pause.fill" : "play.fill",
                      help: state.timerRunning ? "Pause timer" : "Start timer") { controller.startPauseTimer() }
            BarButton(symbol: "arrow.counterclockwise", help: "Reset timer") { controller.resetTimer() }
        }
        BarButton(symbol: "cursorarrow.click.2", active: state.clicksOn, help: "Show clicks" + hint(.toggleClicks)) { state.clicksOn.toggle() }
        BarButton(symbol: "keyboard", active: state.keystrokesOn, help: "Show keystrokes" + hint(.toggleKeystrokes)) { state.keystrokesOn.toggle() }
        BarButton(symbol: "eye.slash", active: state.blurAll, help: "Blur everything" + hint(.toggleBlurAll)) { state.blurAll.toggle() }
        BarButton(symbol: "cursorarrow.slash", active: state.settings.hideCursor, help: "Hide mouse cursor from viewers" + hint(.toggleHideCursor)) {
            state.settings.hideCursor.toggle()
        }
        separator
        shareButton
        BarButton(symbol: "gearshape", help: "Settings") { controller.openSettings() }
        BarButton(symbol: vertical ? "chevron.up" : "chevron.left", help: "Collapse") {
            state.settings.controlBarExpanded = false
        }
    }

    private var shareButton: some View {
        BarButton(symbol: state.isSharing ? "stop.fill" : "record.circle",
                  active: state.isSharing, tint: .red,
                  help: (state.isSharing ? "Stop sharing" : "Start sharing") + hint(.toggleSharing)) {
            controller.toggleSharing()
        }
    }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.18))
            .frame(width: vertical ? 22 : 1, height: vertical ? 1 : 22)
            .padding(vertical ? .vertical : .horizontal, 3)
    }

    private func hint(_ action: HotkeyAction) -> String {
        state.settings.hotkeys[action].map { " (\($0.display))" } ?? ""
    }
}

private struct BarButton: View {
    let symbol: String
    var active = false
    var tint: Color = .accentColor
    var enabled = true
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(active ? tint : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }
}

/// The dotted handle used to drag the bar around.
private struct DragGrip: NSViewRepresentable {
    let vertical: Bool
    func makeNSView(context: Context) -> GripView { GripView() }
    func updateNSView(_ v: GripView, context: Context) { v.vertical = vertical; v.needsDisplay = true }

    final class GripView: NSView {
        var vertical = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.setFill()
            let cols = vertical ? 3 : 2, rows = vertical ? 2 : 3
            let d: CGFloat = 2.5, gap: CGFloat = 3
            let w = CGFloat(cols) * d + CGFloat(cols - 1) * gap, h = CGFloat(rows) * d + CGFloat(rows - 1) * gap
            let x0 = bounds.midX - w / 2, y0 = bounds.midY - h / 2
            for c in 0..<cols {
                for r in 0..<rows {
                    NSBezierPath(ovalIn: CGRect(x: x0 + CGFloat(c) * (d + gap), y: y0 + CGFloat(r) * (d + gap), width: d, height: d)).fill()
                }
            }
        }
    }
}
