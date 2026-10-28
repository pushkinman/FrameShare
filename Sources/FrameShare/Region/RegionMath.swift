//
//  RegionMath.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit

enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// -1 = left edge moves, +1 = right edge moves, 0 = neither.
    var xDir: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .topRight, .right, .bottomRight: 1
        default: 0
        }
    }
    /// AppKit coordinates: -1 = bottom edge moves, +1 = top edge moves.
    var yDir: Int {
        switch self {
        case .bottomLeft, .bottom, .bottomRight: -1
        case .topLeft, .top, .topRight: 1
        default: 0
        }
    }
}

enum QuickPosition { case left, center, right }
enum Side { case left, right }

/// Which edge stays put when a rect is rounded: -1 = min edge, +1 = max edge, 0 = center.
struct Anchor { var x: Int; var y: Int; static let center = Anchor(x: 0, y: 0); static let origin = Anchor(x: -1, y: -1) }

enum RegionMath {
    static let minSize: CGFloat = 120

    /// Smallest whole numbers a:b for a ratio (16:9, 4:3, 7:3 for 21:9, ...).
    static func steps(for ratio: CGFloat) -> (CGFloat, CGFloat) {
        for b in 1...32 {
            let a = (ratio * CGFloat(b)).rounded()
            if a >= 1 && abs(a / CGFloat(b) - ratio) < 1e-6 { return (a, CGFloat(b)) }
        }
        return (ratio, 1)
    }

    /// Rounds to whole points. With a ratio, the size becomes an exact multiple of a:b,
    /// so 16:9 really is 16:9 (e.g. 960×540, never 1001×564). Stays inside `bounds`.
    static func finalize(_ r: CGRect, ratio: CGFloat?, anchor: Anchor, within bounds: CGRect) -> CGRect {
        var w: CGFloat, h: CGFloat
        if let ratio {
            let (a, b) = steps(for: ratio)
            var k = max(1, (r.width / a).rounded())
            let kMax = max(1, min((bounds.width / a).rounded(.down), (bounds.height / b).rounded(.down)))
            k = min(k, kMax)
            w = a * k; h = b * k
        } else {
            w = min(r.width.rounded(), bounds.width.rounded(.down))
            h = min(r.height.rounded(), bounds.height.rounded(.down))
        }
        func place(_ minV: CGFloat, _ maxV: CGFloat, _ size: CGFloat, _ dir: Int) -> CGFloat {
            switch dir {
            case -1: return minV.rounded()
            case 1: return maxV.rounded() - size
            default: return ((minV + maxV) / 2 - size / 2).rounded()
            }
        }
        var x = place(r.minX, r.maxX, w, anchor.x)
        var y = place(r.minY, r.maxY, h, anchor.y)
        x = min(max(bounds.minX.rounded(.up), x), bounds.maxX.rounded(.down) - w)
        y = min(max(bounds.minY.rounded(.up), y), bounds.maxY.rounded(.down) - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Makes `r` fit inside `bounds`, keeping the aspect ratio when one is set.
    static func clamp(_ r: CGRect, to bounds: CGRect, ratio: CGFloat?) -> CGRect {
        var w = max(minSize, r.width), h = max(minSize, r.height)
        if let ratio {
            if w / h > ratio { w = h * ratio } else { h = w / ratio }
            if w > bounds.width { w = bounds.width; h = w / ratio }
            if h > bounds.height { h = bounds.height; w = h * ratio }
        } else {
            w = min(w, bounds.width); h = min(h, bounds.height)
        }
        // Keep the original corner if the size didn't change, else keep the center.
        let anchor = Anchor(x: r.width == w ? -1 : 0, y: r.height == h ? -1 : 0)
        let sized = CGRect(x: anchor.x == -1 ? r.minX : r.midX - w / 2,
                           y: anchor.y == -1 ? r.minY : r.midY - h / 2, width: w, height: h)
        return finalize(sized, ratio: ratio, anchor: anchor, within: bounds)
    }

    static func move(_ start: CGRect, by d: CGPoint, within bounds: CGRect) -> CGRect {
        var r = start.offsetBy(dx: d.x, dy: d.y)
        r.origin.x = min(max(bounds.minX, r.minX), bounds.maxX - r.width).rounded()
        r.origin.y = min(max(bounds.minY, r.minY), bounds.maxY - r.height).rounded()
        return r
    }

    static func resize(_ start: CGRect, handle: Handle, by d: CGPoint, ratio: CGFloat?, within bounds: CGRect) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.xDir < 0 { minX += d.x }
        if handle.xDir > 0 { maxX += d.x }
        if handle.yDir < 0 { minY += d.y }
        if handle.yDir > 0 { maxY += d.y }
        minX = max(minX, bounds.minX); maxX = min(maxX, bounds.maxX)
        minY = max(minY, bounds.minY); maxY = min(maxY, bounds.maxY)
        var w = max(minSize, maxX - minX), h = max(minSize, maxY - minY)
        if let ratio {
            if handle.xDir != 0 && handle.yDir != 0 {
                if abs(d.x) >= abs(d.y) * ratio { h = w / ratio } else { w = h * ratio }
            } else if handle.xDir != 0 {
                h = w / ratio
            } else {
                w = h * ratio
            }
            if w > bounds.width { w = bounds.width; h = w / ratio }
            if h > bounds.height { h = bounds.height; w = h * ratio }
        }
        // The edge opposite the dragged handle stays exactly where it was.
        let anchor = Anchor(x: -handle.xDir, y: -handle.yDir)
        let x: CGFloat = handle.xDir < 0 ? start.maxX - w : handle.xDir > 0 ? start.minX : start.midX - w / 2
        let y: CGFloat = handle.yDir < 0 ? start.maxY - h : handle.yDir > 0 ? start.minY : start.midY - h / 2
        return finalize(CGRect(x: x, y: y, width: w, height: h), ratio: ratio, anchor: anchor, within: bounds)
    }

    /// Keeps the center and height, and changes the width to match the new ratio.
    static func applyRatio(_ r: CGRect, ratio: CGFloat?, within bounds: CGRect) -> CGRect {
        guard let ratio else { return r }
        let h = r.height, w = h * ratio
        return clamp(CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), to: bounds, ratio: ratio)
    }

    static func quick(_ r: CGRect, _ pos: QuickPosition, in vf: CGRect, ratio: CGFloat?) -> CGRect {
        var rect = clamp(r, to: vf, ratio: ratio)
        rect.origin.y = (vf.midY - rect.height / 2).rounded()
        switch pos {
        case .left: rect.origin.x = vf.minX
        case .center: rect.origin.x = (vf.midX - rect.width / 2).rounded()
        case .right: rect.origin.x = vf.maxX - rect.width
        }
        return rect
    }

    /// Largest frame with the ratio that fills the screen height, centered on the current frame.
    static func fullHeight(_ r: CGRect, in vf: CGRect, ratio: CGFloat?) -> CGRect {
        let h = vf.height
        let w = ratio.map { min(vf.width, h * $0) } ?? r.width
        let hh = ratio.map { w / $0 } ?? h
        let x = min(max(vf.minX, r.midX - w / 2), vf.maxX - w)
        let anchor = Anchor(x: 0, y: ratio == nil || hh >= vf.height ? 1 : 0)
        return finalize(CGRect(x: x, y: vf.midY - hh / 2, width: w, height: hh), ratio: ratio, anchor: anchor, within: vf)
    }

    /// Full-height slice of the screen hugging one side, like Rectangle's "Left/Right Half".
    static func side(_ side: Side, fraction: CGFloat, in vf: CGRect) -> CGRect {
        let w = (vf.width * fraction).rounded()
        let x = side == .left ? vf.minX : vf.maxX - w
        return CGRect(x: x, y: vf.minY, width: w, height: vf.height)
    }

    static func defaultRegion() -> CGRect {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let h = (vf.height * 0.85).rounded()
        let w = min(vf.width, h * 16 / 9)
        return clamp(CGRect(x: vf.midX - w / 2, y: vf.midY - w * 9 / 32, width: w, height: w * 9 / 16),
                     to: vf, ratio: 16.0 / 9)
    }
}
