//
//  BlurTracker.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit
import CoreGraphics

/// Finds the visible parts of windows that should be blurred inside the region.
enum BlurTracker {
    private static var bundleCache: [pid_t: String] = [:]

    private static func bundleID(_ pid: pid_t) -> String {
        if let b = bundleCache[pid] { return b }
        let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        bundleCache[pid] = b
        return b
    }

    /// - Parameters:
    ///   - region: shared region in AppKit global coordinates.
    ///   - blurBundles: apps to blur entirely.
    ///   - hiddenBundles: apps removed from the capture (ignored here).
    ///   - keywords: blur any window whose title contains one of these.
    ///   - urlMatchedPIDs: browsers whose front tab URL matched a keyword (their front window is blurred).
    /// - Returns: rects normalized to the region, top-left origin.
    static func compute(region: CGRect, blurBundles: Set<String>, hiddenBundles: Set<String>, keywords: [String],
                        urlMatchedPIDs: Set<pid_t>) -> [CGRect] {
        if blurBundles.isEmpty && keywords.isEmpty && urlMatchedPIDs.isEmpty { return [] }
        let regionCG = Geo.flip(region)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let lowered = keywords.map { $0.lowercased() }.filter { !$0.isEmpty }
        var covers: [CGRect] = []
        var seenFrontWindow = Set<pid_t>()
        var out: [CGRect] = []

        for info in list { // front to back
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: bd),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { continue }
            // Hidden apps are removed from the capture, so they don't cover anything.
            if hiddenBundles.contains(bundleID(pid)) { continue }
            let isFront = !seenFrontWindow.contains(pid)
            seenFrontWindow.insert(pid)

            var blur = blurBundles.contains(bundleID(pid))
            if !blur, !lowered.isEmpty, let title = (info[kCGWindowName as String] as? String)?.lowercased() {
                blur = lowered.contains { title.contains($0) }
            }
            if !blur, isFront, urlMatchedPIDs.contains(pid) { blur = true }

            if blur {
                let visible = bounds.intersection(regionCG)
                if !visible.isNull && !visible.isEmpty {
                    var pieces = [visible]
                    for c in covers { pieces = pieces.flatMap { Geo.subtract($0, c) } }
                    for p in pieces {
                        out.append(CGRect(x: (p.minX - regionCG.minX) / regionCG.width,
                                          y: (p.minY - regionCG.minY) / regionCG.height,
                                          width: p.width / regionCG.width,
                                          height: p.height / regionCG.height))
                    }
                }
            }
            covers.append(bounds)
        }
        return out
    }
}

/// Reads the active tab URL of supported browsers with AppleScript (asks for Automation permission once).
final class BrowserURLWatcher {
    private let queue = DispatchQueue(label: "frameshare.browser-url")
    private var busy = false

    static let browsers: [(bundle: String, script: String)] = [
        ("com.apple.Safari", "URL of current tab of front window"),
        ("com.google.Chrome", "URL of active tab of front window"),
        ("com.brave.Browser", "URL of active tab of front window"),
        ("com.microsoft.edgemac", "URL of active tab of front window"),
    ]

    /// Calls `completion` on the main thread with the PIDs of browsers whose front tab URL contains a keyword.
    func check(keywords: [String], completion: @escaping (Set<pid_t>) -> Void) {
        let lowered = keywords.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !busy, !lowered.isEmpty else { return }
        let running = Self.browsers.compactMap { b -> (pid_t, String, String)? in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: b.bundle).first
            else { return nil }
            return (app.processIdentifier, b.bundle, b.script)
        }
        guard !running.isEmpty else { completion([]); return }
        busy = true
        queue.async {
            var matched = Set<pid_t>()
            for (pid, bundle, expr) in running {
                let src = "tell application id \"\(bundle)\" to if (count of windows) > 0 then return \(expr)"
                if let url = Self.osascript(src)?.lowercased(), lowered.contains(where: { url.contains($0) }) {
                    matched.insert(pid)
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                completion(matched)
            }
        }
    }

    private static func osascript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
