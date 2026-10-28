//
//  KeystrokeMonitor.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit
import CoreGraphics

/// Listens to key presses system-wide (listen-only). Needs the Input Monitoring permission.
final class KeystrokeMonitor {
    /// Called on the main thread with (label, isPlainTyping).
    var onKey: ((String, Bool) -> Void)?
    var onlyShortcuts = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeystrokeMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else if type == .keyDown {
                me.handle(event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ event: CGEvent) {
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let f = event.flags
        let cmd = f.contains(.maskCommand), ctrl = f.contains(.maskControl)
        let opt = f.contains(.maskAlternate), shift = f.contains(.maskShift)
        let special = KeyNames.isSpecial(keyCode)

        if cmd || ctrl || opt || special {
            let label = KeyNames.symbols(control: ctrl, option: opt, shift: shift, command: cmd)
                + KeyNames.name(for: keyCode)
            onKey?(label, false)
        } else if !onlyShortcuts {
            let chars = NSEvent(cgEvent: event)?.characters ?? ""
            guard !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return }
            onKey?(chars, true)
        }
    }
}
