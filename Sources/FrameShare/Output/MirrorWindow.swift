//
//  MirrorWindow.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit
import IOSurface

/// Shows the captured frames. This is the view inside the window you share in a meeting app.
/// When the window has exactly as many pixels as the frame, frames are shown 1:1 with no resampling.
final class MirrorView: NSView {
    private let contentLayer = CALayer()
    private(set) var surfaceSize: CGSize = .zero
    private(set) var isPixelExact = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root          // layer-hosting: AppKit never redraws over our contents
        wantsLayer = true
        contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        root.addSublayer(contentLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); updateGeometry() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateGeometry() }

    func show(_ surface: IOSurfaceRef) {
        let size = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if size != surfaceSize { surfaceSize = size; updateGeometry() }
        contentLayer.contents = surface
        CATransaction.commit()
    }

    func clear() { contentLayer.contents = nil }

    private func updateGeometry() {
        let scale = window?.backingScaleFactor ?? 2
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contentsScale = scale
        let wPx = b.width * scale, hPx = b.height * scale
        isPixelExact = surfaceSize.width > 0
            && abs(wPx - surfaceSize.width) <= 1.01 && abs(hPx - surfaceSize.height) <= 1.01
        if isPixelExact {
            // Exactly one screen pixel per captured pixel, pinned to the top-left corner.
            let w = surfaceSize.width / scale, h = surfaceSize.height / scale
            contentLayer.frame = CGRect(x: 0, y: b.height - h, width: w, height: h)
            contentLayer.contentsGravity = .resize
            contentLayer.magnificationFilter = .nearest
            contentLayer.minificationFilter = .nearest
        } else {
            contentLayer.frame = b
            contentLayer.contentsGravity = .resizeAspect
            contentLayer.magnificationFilter = .linear
            contentLayer.minificationFilter = .linear
        }
        CATransaction.commit()
    }
}

/// macOS normally squeezes windows to fit the screen. The shared window may need to be
/// as big as the frame (or bigger, on a lower-resolution display), so allow that.
final class MirrorNSWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class MirrorWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
    var onClose: (() -> Void)?
    /// Called when the window moves to a display with a different scale.
    var onScreenChange: (() -> Void)?

    override init() {
        window = MirrorNSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .black
        // On every desktop (Space), so sharing doesn't stop when you switch desktops.
        window.collectionBehavior = [.canJoinAllSpaces, .participatesInCycle]
    }

    func apply(title: String, hideTitleBar: Bool) {
        window.title = title
        if hideTitleBar {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        } else {
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
        }
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(b)?.isHidden = hideTitleBar
        }
        window.isMovableByWindowBackground = hideTitleBar
    }

    /// Keeps the window's content at the region's aspect ratio.
    func setAspect(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        window.contentAspectRatio = size
        var frame = window.contentRect(forFrameRect: window.frame)
        let newHeight = (frame.width * size.height / size.width).rounded()
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        window.setFrame(window.frameRect(forContentRect: frame), display: true)
    }

    private(set) var visibility: MirrorVisibility = .hidden
    private var placed = false

    /// Hidden placement: the window sits just past the bottom-right corner of the frame's display,
    /// touching it with only its (rounded, transparent) top-left corner point.
    /// macOS refuses to capture windows that are fully off every display, but a window that
    /// touches one by a single point is captured completely, pixel for pixel, at full frame rate.
    static func hiddenOrigin(size: CGSize, region: CGRect) -> CGPoint {
        let screen = (Geo.screen(for: region) ?? NSScreen.main)?.frame ?? CGRect(x: 0, y: 0, width: 1000, height: 1000)
        return CGPoint(x: screen.maxX - 1, y: screen.minY - size.height + 1)
    }

    private var lastRegion: CGRect = .zero

    /// Sizes the content so it has the same number of pixels as the captured frame.
    /// `regionScale` is the frame's display scale; the window keeps that scale when hidden.
    func matchPixels(of regionSize: CGSize, regionScale: CGFloat) {
        guard regionSize.width > 0, regionSize.height > 0 else { return }
        // Hidden: the window lives on the frame's own display, so it uses that display's scale.
        let targetScale = visibility == .hidden ? regionScale
            : (window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let size = CGSize(width: (regionSize.width * regionScale / targetScale).rounded(),
                          height: (regionSize.height * regionScale / targetScale).rounded())
        window.contentAspectRatio = size
        let old = window.contentRect(forFrameRect: window.frame)
        guard old.size != size else { return }
        let content = CGRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
        var f = window.frameRect(forContentRect: content)
        if visibility == .hidden {
            f.origin = Self.hiddenOrigin(size: f.size, region: lastRegion)
        } else if let vf = (window.screen ?? NSScreen.main)?.visibleFrame {
            // Keep it on its screen when it fits; otherwise pin its top-left corner to the screen.
            f.origin.x = f.width <= vf.width ? min(max(vf.minX, f.minX), vf.maxX - f.width) : vf.minX
            f.origin.y = f.height <= vf.height ? min(max(vf.minY, f.minY), vf.maxY - f.height) : vf.maxY - f.height
        }
        window.setFrame(f, display: true)
    }

    /// Moves the window to match the visibility setting.
    func setVisibility(_ v: MirrorVisibility, region: CGRect) {
        let wasHidden = visibility == .hidden && placed
        visibility = v
        placed = true
        lastRegion = region
        var f = window.frame
        switch v {
        case .hidden:
            f.origin = Self.hiddenOrigin(size: f.size, region: region)
            window.setFrame(f, display: true)
            window.orderBack(nil)
        case .behind, .visible:
            if wasHidden || !NSScreen.screens.contains(where: { $0.frame.intersects(f) }) {
                // Bring it back onto a display: another one if there is one, else the lower-left corner.
                let regionScreen = Geo.screen(for: region)
                if let target = NSScreen.screens.first(where: { $0 != regionScreen }) ?? regionScreen ?? NSScreen.main {
                    let vf = target.visibleFrame
                    f.origin = target != regionScreen
                        ? CGPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2)
                        : CGPoint(x: vf.minX + 20, y: vf.minY + 20)
                    f.origin.y = min(f.origin.y, vf.maxY - f.height)
                    window.setFrame(f, display: true)
                }
            }
            v == .behind ? window.orderBack(nil) : window.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) { onScreenChange?() }
    func windowDidChangeScreen(_ notification: Notification) { onScreenChange?() }
}
