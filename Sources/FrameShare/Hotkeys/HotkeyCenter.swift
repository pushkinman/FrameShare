//
//  HotkeyCenter.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Global hotkeys via Carbon's RegisterEventHotKey (no extra permissions needed).
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: HotkeyAction] = [:]
    private var current: [HotkeyAction: Hotkey] = [:]
    private var handler: ((HotkeyAction) -> Void)?
    private var installed = false
    private var suspended = false

    func register(_ map: [HotkeyAction: Hotkey], handler: @escaping (HotkeyAction) -> Void) {
        self.handler = handler
        current = map
        installIfNeeded()
        if !suspended { apply() }
    }

    func suspend() { suspended = true; unregisterAll() }
    func resume() { suspended = false; apply() }

    fileprivate func fire(_ id: UInt32) {
        if let a = actions[id] { handler?(a) }
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    private func apply() {
        unregisterAll()
        var n: UInt32 = 1
        for (action, key) in current.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4653_4852), id: n) // "FSHR"
            if RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
                actions[n] = action
            }
            n += 1
        }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Click, then press a key combination. Esc cancels.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    @StateObject private var model = RecorderModel()
    private var recording: Bool { model.recording }

    var body: some View {
        HStack(spacing: 4) {
            Button(recording ? "Press keys…" : (hotkey?.display ?? "Record")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 120)
            if hotkey != nil && !recording {
                Button { hotkey = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Remove")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        model.recording = true
        HotkeyCenter.shared.suspend()
        model.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if Int(e.keyCode) == kVK_Escape { stop(); return nil }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            let isFKey = (KeyNames.special[Int(e.keyCode)] ?? "").hasPrefix("F")
            guard !mods.isEmpty || isFKey else { NSSound.beep(); return nil }
            hotkey = Hotkey(keyCode: UInt32(e.keyCode), modifiers: Hotkey.carbon(mods))
            stop()
            return nil
        }
    }

    private func stop() {
        guard model.recording || model.monitor != nil else { return }
        model.recording = false
        if let m = model.monitor { NSEvent.removeMonitor(m) }
        model.monitor = nil
        HotkeyCenter.shared.resume()
    }
}

final class RecorderModel: ObservableObject {
    @Published var recording = false
    var monitor: Any?
}
