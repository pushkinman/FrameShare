//
//  Util.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import Combine
import AppKit
import Carbon.HIToolbox

/// Runs `work` on the main thread, as main-actor code.
func onMain(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 6 {
            r = CGFloat((v >> 16) & 0xff) / 255; g = CGFloat((v >> 8) & 0xff) / 255
            b = CGFloat(v & 0xff) / 255; a = 1
        } else {
            r = CGFloat((v >> 24) & 0xff) / 255; g = CGFloat((v >> 16) & 0xff) / 255
            b = CGFloat((v >> 8) & 0xff) / 255; a = CGFloat(v & 0xff) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Geometry helpers. AppKit uses a bottom-left origin; Core Graphics window lists use top-left.
enum Geo {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// AppKit global rect -> CG global (top-left origin) rect. The conversion is its own inverse.
    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) }
    }

    static func screen(for r: CGRect) -> NSScreen? {
        if let s = screen(containing: CGPoint(x: r.midX, y: r.midY)) { return s }
        return NSScreen.screens.max { a, b in
            area(a.frame.intersection(r)) < area(b.frame.intersection(r))
        } ?? NSScreen.main
    }

    static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// Parts of `a` not covered by `b`.
    static func subtract(_ a: CGRect, _ b: CGRect) -> [CGRect] {
        let i = a.intersection(b)
        if i.isNull || i.isEmpty { return [a] }
        var out: [CGRect] = []
        if i.minY > a.minY { out.append(CGRect(x: a.minX, y: a.minY, width: a.width, height: i.minY - a.minY)) }
        if i.maxY < a.maxY { out.append(CGRect(x: a.minX, y: i.maxY, width: a.width, height: a.maxY - i.maxY)) }
        if i.minX > a.minX { out.append(CGRect(x: a.minX, y: i.minY, width: i.minX - a.minX, height: i.height)) }
        if i.maxX < a.maxX { out.append(CGRect(x: i.maxX, y: i.minY, width: a.maxX - i.maxX, height: i.height)) }
        return out.filter { $0.width > 0.5 && $0.height > 0.5 }
    }
}

enum Levels {
    static let dim = NSWindow.Level(rawValue: 5)
    static let overlay = NSWindow.Level(rawValue: 6)
    static let frame = NSWindow.Level(rawValue: 7)
    static let toolbar = NSWindow.Level(rawValue: 8)
}

/// Human-readable key names, shared by the hotkey recorder and the keystroke overlay.
enum KeyNames {
    static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_CapsLock: "⇪", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11",
        kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
    ]

    static func isSpecial(_ keyCode: Int) -> Bool { special[keyCode] != nil }

    static func name(for keyCode: Int) -> String {
        if let s = special[keyCode] { return s }
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &len, &chars)
        }
        let s = String(utf16CodeUnits: chars, count: len).uppercased()
        return s.isEmpty ? "?" : s
    }

    static func symbols(control: Bool, option: Bool, shift: Bool, command: Bool) -> String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
    }
}

/// Local view state without the `@State` macro (its plugin ships only with Xcode).
final class Box<T>: ObservableObject {
    @Published var v: T
    init(_ v: T) { self.v = v }
}
