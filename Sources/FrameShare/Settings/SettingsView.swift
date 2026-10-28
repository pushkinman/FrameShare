//
//  SettingsView.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var state: AppState
    let controller: AppController

    var body: some View {
        TabView {
            GeneralTab(state: state).tabItem { Label("General", systemImage: "gearshape") }
            FrameTab(state: state, controller: controller).tabItem { Label("Frame", systemImage: "rectangle.dashed") }
            ToolsTab(state: state, controller: controller).tabItem { Label("Tools", systemImage: "pencil.tip") }
            PrivacyTab(state: state).tabItem { Label("Privacy", systemImage: "eye.slash") }
            HotkeysTab(state: state).tabItem { Label("Hotkeys", systemImage: "command") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 520)
        .padding()
    }
}

private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
    Binding(get: { Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .systemRed) },
            set: { hex.wrappedValue = NSColor($0).hexString })
}

// MARK: General

private struct GeneralTab: View {
    @ObservedObject var state: AppState
    @StateObject private var launchAtLogin = Box(SMAppService.mainApp.status == .enabled)
    @StateObject private var refresh = Box(0)

    var body: some View {
        Form {
            Section("Shared window") {
                TextField("Window title", text: $state.settings.mirrorTitle)
                Toggle("Hide title bar", isOn: $state.settings.hideTitleBar)
                Picker("Shared window", selection: $state.settings.mirrorVisibility) {
                    ForEach(MirrorVisibility.allCases) { Text($0.rawValue).tag($0) }
                }
                if state.settings.mirrorVisibility == .hidden {
                    Text("The window stays open just past the corner of your display, so you never see it. Meeting apps can still share it in full quality.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Frame rate", selection: $state.settings.fps) {
                    Text("15 fps").tag(15); Text("30 fps").tag(30); Text("60 fps").tag(60)
                    Text("120 fps (ProMotion displays)").tag(120)
                }
                Toggle("Size the window to match the frame (sharpest)", isOn: $state.settings.matchMirrorToFrame)
                Toggle("Hide mouse cursor", isOn: $state.settings.hideCursor)
                Text("In Zoom, Meet or Teams, share the window with this title instead of your whole screen. If you show it, don't minimize it: macOS can't capture minimized windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin.v }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSSound.beep()
                    }
                    launchAtLogin.v = SMAppService.mainApp.status == .enabled
                }))
            }
            Section("Permissions") {
                permissionRow("Screen Recording", "Required to mirror the frame", Permissions.screenRecording, .screenRecording)
                permissionRow("Accessibility", "For snapping the frame to windows", Permissions.accessibility, .accessibility)
                permissionRow("Input Monitoring", "For showing keystrokes", Permissions.inputMonitoring, .inputMonitoring)
                Button("Refresh") { refresh.v += 1 }.controlSize(.small)
            }
            .id(refresh.v)
        }
        .formStyle(.grouped)
    }

    private func permissionRow(_ title: String, _ detail: String, _ granted: Bool, _ pane: Permissions.Pane) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Open Settings") { Permissions.open(pane) }.controlSize(.small) }
        }
    }
}

// MARK: Frame

private struct FrameTab: View {
    @ObservedObject var state: AppState
    let controller: AppController

    var body: some View {
        Form {
            Section("Shape") {
                Picker("Aspect ratio", selection: Binding(get: { state.settings.ratio }, set: { controller.setRatio($0) })) {
                    ForEach(AspectRatio.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Lock frame (no dragging)", isOn: $state.settings.lockFrame)
            }
            Section("Border") {
                Toggle("Show border", isOn: $state.settings.showFrame)
                ColorPicker("Color", selection: colorBinding($state.settings.frameColorHex), supportsOpacity: false)
                slider("Opacity", $state.settings.frameOpacity, 0.1...1, "%.0f%%", scale: 100)
                slider("Thickness", $state.settings.borderWidth, 1...10, "%.0f pt")
                slider("Padding", $state.settings.padding, 0...20, "%.0f pt")
                Text("The border sits outside the shared area, so viewers never see it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Focus overlay") {
                Toggle("Dim everything outside the frame", isOn: $state.settings.dimOutside)
                slider("Dim amount", $state.settings.dimOpacity, 0.1...0.9, "%.0f%%", scale: 100)
            }
        }
        .formStyle(.grouped)
    }
}

private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String,
                    scale: Double = 1) -> some View {
    HStack {
        Text(title)
        Slider(value: value, in: range)
        Text(String(format: fmt, value.wrappedValue * scale)).monospacedDigit().frame(width: 56, alignment: .trailing)
    }
}

// MARK: Tools

private struct ToolsTab: View {
    @ObservedObject var state: AppState
    let controller: AppController

    var body: some View {
        Form {
            Section("Control bar") {
                Picker("Show the bar", selection: $state.settings.controlBarMode) {
                    ForEach(ControlBarMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Vertical layout", isOn: $state.settings.controlBarVertical)
                Toggle("Expanded", isOn: $state.settings.controlBarExpanded)
                Button("Reset position") { controller.resetControlBarPosition() }.controlSize(.small)
                Text("A floating bar with all presenter tools. Drag it by its dotted handle. Viewers never see it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Drawing") {
                Picker("Default tool", selection: $state.settings.tool) {
                    ForEach(DrawTool.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                ColorPicker("Color", selection: colorBinding($state.settings.penColorHex), supportsOpacity: false)
                slider("Line width", $state.settings.penWidth, 1...16, "%.0f pt")
                Picker("Drawings fade away", selection: $state.settings.drawingFadeSeconds) {
                    Text("Never").tag(0.0); Text("After 2 seconds").tag(2.0); Text("After 3 seconds").tag(3.0)
                    Text("After 5 seconds").tag(5.0); Text("After 10 seconds").tag(10.0)
                }
                Text("While drawing: Esc returns to the mouse, ⌘Z undoes, ⇧⌘Z redoes, hold Shift for straight lines and arrows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spotlight") {
                slider("Radius", $state.settings.spotlightRadius, 60...400, "%.0f pt")
                slider("Dim amount", $state.settings.spotlightDim, 0.2...0.9, "%.0f%%", scale: 100)
            }
            Section("Zoom") {
                slider("Magnification", $state.settings.zoomFactor, 1.25...4, "%.2gx")
                Text("Viewers see the area around your cursor, magnified. The dashed box shows you what they see.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Timer") {
                Picker("Mode", selection: $state.settings.timerMode) {
                    ForEach(TimerMode.allCases) { Text($0.rawValue).tag($0) }
                }
                if state.settings.timerMode == .countdown {
                    Stepper("Countdown: \(state.settings.countdownMinutes) min",
                            value: $state.settings.countdownMinutes, in: 1...240)
                }
                Picker("Position", selection: $state.settings.timerCorner) {
                    ForEach(Corner.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Section("Keystrokes") {
                Toggle("Only show shortcuts (with ⌘, ⌃ or ⌥)", isOn: $state.settings.keystrokesOnlyShortcuts)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Privacy

private struct PrivacyTab: View {
    @ObservedObject var state: AppState
    @StateObject private var newKeyword = Box("")

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Blur everything in the frame", isOn: $state.blurAll)
                slider("Blur strength", $state.settings.blurRadius, 8...60, "%.0f")
            }
            Section {
                ForEach($state.settings.privacyRules) { $rule in
                    HStack {
                        Text(rule.name)
                        Spacer()
                        Picker("", selection: $rule.mode) {
                            ForEach(PrivacyMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        Button { state.settings.privacyRules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("Add app…") {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier!) {
                            let id = app.bundleIdentifier!
                            guard !state.settings.privacyRules.contains(where: { $0.bundleID == id }) else { return }
                            state.settings.privacyRules.append(
                                PrivacyRule(bundleID: id, name: app.localizedName ?? id, mode: .blur))
                        }
                    }
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("Blur: the app's windows are blurred when they show up in the frame. Hide: viewers see what's behind the app instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(state.settings.titleKeywords, id: \.self) { k in
                    HStack {
                        Text(k)
                        Spacer()
                        Button { state.settings.titleKeywords.removeAll { $0 == k } } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("e.g. Gmail, bank, Slack", text: $newKeyword.v).onSubmit(addKeyword)
                    Button("Add", action: addKeyword).disabled(newKeyword.v.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Toggle("Also match browser tab URLs (Safari, Chrome, Brave, Edge)", isOn: $state.settings.matchBrowserURLs)
            } header: {
                Text("Windows and browser tabs")
            } footer: {
                Text("Any window whose title contains a keyword is blurred. Browser window titles are the current tab's title. URL matching asks for Automation permission the first time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addKeyword() {
        let k = newKeyword.v.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, !state.settings.titleKeywords.contains(k) else { return }
        state.settings.titleKeywords.append(k)
        newKeyword.v = ""
    }
}

// MARK: Hotkeys

private struct HotkeysTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        HotkeyRecorder(hotkey: Binding(get: { state.settings.hotkeys[action] }, set: { new in
                            // A shortcut can only belong to one action: take it away from any other.
                            if let new {
                                for (other, key) in state.settings.hotkeys where key == new && other != action {
                                    state.settings.hotkeys[other] = nil
                                }
                            }
                            state.settings.hotkeys[action] = new
                        }))
                    }
                }
            } footer: {
                HStack {
                    Text("Click a shortcut, then press the new keys. Esc cancels.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore defaults") { state.settings.hotkeys = HotkeyAction.defaults }.controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: About

private struct AboutTab: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("FrameShare").font(.title.weight(.semibold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Share just part of your screen — sharp, private and simple.")
                .multilineTextAlignment(.center)
            Divider().frame(width: 220).padding(.vertical, 4)
            Text("Developed by Anton Pushkin").font(.headline)
            Text("© 2026 Anton Pushkin").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
