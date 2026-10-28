//
//  CaptureEngine.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import Foundation
import ScreenCaptureKit
import CoreMedia

struct CaptureParams: Equatable {
    var displayID: CGDirectDisplayID
    /// Region in display-local points, top-left origin.
    var sourceRect: CGRect
    /// Output size in pixels.
    var outputSize: CGSize
    var showsCursor: Bool
    var fps: Int
    /// Apps hidden from the capture (our own app is always hidden).
    var excludedBundleIDs: Set<String>
    /// Our own windows that should still be captured (the presenter overlay).
    var includedWindowIDs: Set<CGWindowID>
}

/// Wraps an SCStream that captures one rectangle of one display.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "frameshare.capture", qos: .userInteractive)
    /// Called on `queue` for every complete frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the main thread if the system stops the stream.
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private var current: CaptureParams?

    var isRunning: Bool { stream != nil }

    func apply(_ p: CaptureParams, refreshFilter: Bool = false) async throws {
        if let stream, let cur = current, cur.displayID == p.displayID {
            if cur.sourceRect != p.sourceRect || cur.outputSize != p.outputSize
                || cur.showsCursor != p.showsCursor || cur.fps != p.fps {
                try await stream.updateConfiguration(Self.configuration(p))
            }
            if refreshFilter || cur.excludedBundleIDs != p.excludedBundleIDs
                || cur.includedWindowIDs != p.includedWindowIDs {
                try await stream.updateContentFilter(try await Self.filter(p))
            }
            current = p
            return
        }
        await stop()
        let filter = try await Self.filter(p)
        let s = SCStream(filter: filter, configuration: Self.configuration(p), delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        current = p
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        current = nil
        try? await s.stopCapture()
    }

    private static func filter(_ p: CaptureParams) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == p.displayID }) else {
            throw NSError(domain: "FrameShare", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The display for the frame was not found."])
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let excludedApps = content.applications.filter {
            $0.processID == pid || p.excludedBundleIDs.contains($0.bundleIdentifier)
        }
        let keep = content.windows.filter { p.includedWindowIDs.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: keep)
    }

    private static func configuration(_ p: CaptureParams) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.sourceRect = p.sourceRect
        c.width = max(2, Int(p.outputSize.width.rounded()))
        c.height = max(2, Int(p.outputSize.height.rounded()))
        c.showsCursor = p.showsCursor
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, p.fps)))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.queueDepth = 6
        c.captureResolution = .best
        return c
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw), status == .complete,
              let pb = sampleBuffer.imageBuffer else { return }
        onFrame?(pb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            if self.stream === stream {
                self.stream = nil
                self.current = nil
                self.onStop?(error)
            }
        }
    }
}
