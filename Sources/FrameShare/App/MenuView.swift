//
//  MenuView.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import SwiftUI

struct MenuView: View {
    @ObservedObject var state: AppState
    let controller: AppController

    @StateObject private var w = Box(0.0)
    @StateObject private var h = Box(0.0)
    @StateObject private var x = Box(0.0)
    @StateObject private var y = Box(0.0)
    @StateObject private var editedHeight = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let msg = state.statusMessage {
                Text(msg).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            frameSection
            Divider()
            toolsSection
            Divider()
            optionsSection
            Divider()
            HStack {
                Button("Settings…") { controller.openSettings() }
                Spacer()
                Text("by Anton Pushkin").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit FrameShare") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: loadNumbers)
        .onChange(of: state.settings.region) { _, _ in loadNumbers() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FrameShare").font(.headline)
                Text(state.isSharing ? "Share the “\(state.settings.mirrorTitle)” window in your meeting app"
                                     : "Pick an area, then start sharing")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(state.isSharing ? "Stop" : "Start Sharing") { controller.toggleSharing() }
                .buttonStyle(.borderedProminent)
                .tint(state.isSharing ? .red : .accentColor)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ratio")
                Picker("", selection: Binding(get: { state.settings.ratio }, set: { controller.setRatio($0) })) {
                    ForEach(AspectRatio.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                Spacer()
                if state.isSharing && state.settings.mirrorVisibility != .hidden {
                    Button("Show window") { controller.showMirrorWindow() }.controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                numberField("W", w) { editedHeight.v = false }
                numberField("H", h) { editedHeight.v = true }
                numberField("X", x) {}
                numberField("Y", y) {}
                Button("Set", action: applyNumbers).controlSize(.small)
            }
            Text("Points, measured from the display's top-left corner.")
                .font(.caption2).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                wideButton("Left half", "rectangle.lefthalf.filled") { controller.snapHalf(.left) }
                wideButton("Right half", "rectangle.righthalf.filled") { controller.snapHalf(.right) }
            }
            HStack(spacing: 6) {
                wideButton("Left", "arrow.left.to.line") { controller.quickPosition(.left) }
                wideButton("Center", "rectangle.center.inset.filled") { controller.quickPosition(.center) }
                wideButton("Right", "arrow.right.to.line") { controller.quickPosition(.right) }
                wideButton("Full height", "arrow.up.and.down") { controller.fullHeight() }
            }
            HStack(spacing: 6) {
                wideButton("Frame → Window", "macwindow") { controller.snapFrameToWindow() }
                wideButton("Window → Frame", "macwindow.badge.plus") { controller.fitWindowToFrame() }
            }
            Text("Press a half button again to cycle ½ → ⅔ → ⅓, like Rectangle.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presenter tools").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                toolToggle("Draw", "pencil.tip", $state.isDrawing, enabled: state.isSharing)
                toolToggle("Spotlight", "light.max", $state.spotlightOn)
                toolToggle("Zoom", "plus.magnifyingglass", $state.zoomOn)
                toolToggle("Timer", "timer", $state.timerVisible)
                toolToggle("Keys", "keyboard", $state.keystrokesOn)
                toolToggle("Clicks", "cursorarrow.click.2", $state.clicksOn)
            }
            if state.timerVisible {
                HStack {
                    Text(state.timerText).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button(state.timerRunning ? "Pause" : "Start") { controller.startPauseTimer() }
                    Button("Reset") { controller.resetTimer() }
                }
                .controlSize(.small)
            }
            if state.isDrawing {
                Button("Clear drawings") { controller.clearDrawings() }.controlSize(.small)
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Show frame border", isOn: $state.settings.showFrame)
            Toggle("Dim outside the frame", isOn: $state.settings.dimOutside)
            Toggle("Lock frame (no dragging)", isOn: $state.settings.lockFrame)
            Toggle("Hide mouse cursor", isOn: $state.settings.hideCursor)
            Toggle("Blur everything", isOn: $state.blurAll)
            Toggle("Show control bar", isOn: Binding(get: { state.settings.controlBarMode != .whileDrawing },
                                                     set: { state.settings.controlBarMode = $0 ? .whileSharing : .whileDrawing }))
        }
        .toggleStyle(.checkbox)
    }

    private func wideButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
    }

    private func numberField(_ label: String, _ box: Box<Double>, onEdit: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: Binding(get: { box.v }, set: { box.v = $0; onEdit() }),
                      format: .number.precision(.fractionLength(0)).grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
                .onSubmit(applyNumbers)
        }
    }

    private func toolToggle(_ title: String, _ symbol: String, _ isOn: Binding<Bool>, enabled: Bool = true) -> some View {
        Toggle(isOn: isOn) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .toggleStyle(.button)
        .disabled(!enabled)
        .help(enabled ? title : "Start sharing to draw")
    }

    private func loadNumbers() {
        let r = state.settings.region
        guard let f = Geo.screen(for: r)?.frame else { return }
        w.v = r.width; h.v = r.height
        x.v = r.minX - f.minX; y.v = f.maxY - r.maxY
    }

    private func applyNumbers() {
        controller.applyNumbers(width: w.v, height: h.v, x: x.v, y: y.v, changedHeight: editedHeight.v)
        loadNumbers()
    }
}
