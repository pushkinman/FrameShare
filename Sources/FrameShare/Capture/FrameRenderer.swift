//
//  FrameRenderer.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import Foundation
import CoreImage
import CoreVideo
import IOSurface

struct RenderEffects: Equatable {
    /// Rects to blur, normalized to the region (0...1, top-left origin).
    var blurRects: [CGRect] = []
    var blurAll = false
    var blurRadius: CGFloat = 24
    var zoom: CGFloat = 1
    /// Zoom center, normalized to the region (top-left origin).
    var zoomCenter = CGPoint(x: 0.5, y: 0.5)

    var isIdentity: Bool { !blurAll && blurRects.isEmpty && zoom <= 1.001 }
}

/// Applies blur and zoom to captured frames. All rendering happens on the capture queue.
final class FrameRenderer {
    let queue: DispatchQueue
    /// Called on the capture queue with the surface to display.
    var onOutput: ((IOSurfaceRef) -> Void)?

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private var _effects = RenderEffects()
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var recent: [CVPixelBuffer] = []
    private var last: CVPixelBuffer?

    init(queue: DispatchQueue) { self.queue = queue }

    var effects: RenderEffects {
        get { lock.lock(); defer { lock.unlock() }; return _effects }
        set { lock.lock(); _effects = newValue; lock.unlock() }
    }

    /// Must be called on `queue`.
    func process(_ pb: CVPixelBuffer) {
        last = pb
        render(pb)
    }

    /// Re-renders the last frame, e.g. when the zoom moves but the screen did not change.
    func rerender() {
        queue.async { if let l = self.last { self.render(l) } }
    }

    func reset() {
        queue.async { self.last = nil; self.recent.removeAll() }
    }

    private func render(_ pb: CVPixelBuffer) {
        let fx = effects
        if fx.isIdentity {
            if let s = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() { onOutput?(s) }
            return
        }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let W = CGFloat(w), H = CGFloat(h)
        var image = CIImage(cvPixelBuffer: pb)
        let extent = image.extent

        if fx.blurAll || !fx.blurRects.isEmpty {
            let sigma = Double(fx.blurRadius) * Double(W) / 1600.0 + Double(fx.blurRadius) * 0.5
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            if fx.blurAll {
                image = blurred
            } else {
                var out = image
                for r in fx.blurRects {
                    let rr = CGRect(x: r.minX * W, y: (1 - r.maxY) * H, width: r.width * W, height: r.height * H)
                        .integral.intersection(extent)
                    if !rr.isNull && !rr.isEmpty { out = blurred.cropped(to: rr).composited(over: out) }
                }
                image = out
            }
        }

        if fx.zoom > 1.001 {
            let z = fx.zoom
            let cw = W / z, ch = H / z
            var ox = fx.zoomCenter.x * W - cw / 2
            var oy = (1 - fx.zoomCenter.y) * H - ch / 2
            ox = min(max(0, ox), W - cw)
            oy = min(max(0, oy), H - ch)
            image = image.cropped(to: CGRect(x: ox, y: oy, width: cw, height: ch))
                .transformed(by: CGAffineTransform(translationX: -ox, y: -oy)
                    .concatenating(CGAffineTransform(scaleX: z, y: z)))
        }

        guard let out = makeBuffer(w, h) else { return }
        let space = CVImageBufferGetColorSpace(pb)?.takeUnretainedValue() ?? srgb
        context.render(image, to: out, bounds: extent, colorSpace: space)
        CVBufferPropagateAttachments(pb, out) // keep the color space tag for display
        recent.append(out)
        if recent.count > 3 { recent.removeFirst() }
        if let s = CVPixelBufferGetIOSurface(out)?.takeUnretainedValue() { onOutput?(s) }
    }

    private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (w, h) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                    attrs as CFDictionary, &p)
            pool = p
            poolSize = (w, h)
            recent.removeAll()
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }
}
