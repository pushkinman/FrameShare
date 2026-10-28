//
//  DimOverlayWindow.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit

/// Darkens one display everywhere except the shared region. Hidden from the capture, click-through.
final class DimOverlayWindow: NSWindow {
    let screenID: CGDirectDisplayID
    private let dimView = DimView()

    init(screen: NSScreen) {
        screenID = screen.displayID
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = Levels.dim
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = dimView
    }

    override var canBecomeKey: Bool { false }

    func update(screenFrame: CGRect, hole: CGRect, opacity: CGFloat) {
        if frame != screenFrame { setFrame(screenFrame, display: false) }
        dimView.hole = hole.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        dimView.opacity = opacity
        dimView.needsDisplay = true
    }
}

private final class DimView: NSView {
    var hole: CGRect = .zero
    var opacity: CGFloat = 0.45

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        bounds.fill()
        let p = NSBezierPath(rect: bounds)
        if !hole.isEmpty { p.append(NSBezierPath(rect: hole)) }
        p.windingRule = .evenOdd
        NSColor(white: 0, alpha: opacity).setFill()
        p.fill()
    }
}
