//
//  WindowSnapper.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit
import ApplicationServices

/// Reads and sets the focused window frame of another app via the Accessibility API.
/// Frames are in CG global coordinates (top-left origin).
enum WindowSnapper {
    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() {
            return (v as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &value) == .success,
           let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() {
            return (v as! AXUIElement)
        }
        return nil
    }

    static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        guard let w = focusedWindow(pid: pid) else { return nil }
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    @discardableResult
    static func setFocusedWindowFrame(pid: pid_t, _ r: CGRect) -> Bool {
        guard let w = focusedWindow(pid: pid) else { return false }
        var pos = r.origin, size = r.size
        guard let pv = AXValueCreate(.cgPoint, &pos), let sv = AXValueCreate(.cgSize, &size) else { return false }
        // Size, position, size again: some apps clamp size against the old position.
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
        return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv) == .success
    }
}
