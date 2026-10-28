//
//  Permissions.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    static func requestScreenRecording() { CGRequestScreenCaptureAccess() }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func requestInputMonitoring() { CGRequestListenEventAccess() }

    enum Pane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
        case automation = "Privacy_Automation"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
