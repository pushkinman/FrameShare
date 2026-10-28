//
//  AppDelegate.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var controller: AppController!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var iconCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--record-demo") { AppState.persistenceEnabled = false }
        state = AppState()
        controller = AppController(state: state)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let host = NSHostingController(rootView: MenuView(state: state, controller: controller))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient

        if CommandLine.arguments.contains("--record-demo") {
            let c = controller!
            Task { @MainActor in await DemoRecorder(controller: c).run() }
        } else if CommandLine.arguments.contains("--selftest-hidden") {
            let c = controller!
            Task { @MainActor in await c.runHiddenProbe() }
        } else if CommandLine.arguments.contains("--selftest-snap") {
            let c = controller!
            Task { @MainActor in await c.runSnapTest() }
        } else if CommandLine.arguments.contains("--selftest") {
            let c = controller!
            Task { @MainActor in await c.runSelfTest() }
        }

        iconCancellable = state.$isSharing.sink { [weak self] on in
            MainActor.assumeIsolated {
                let img = NSImage(systemSymbolName: on ? "rectangle.inset.filled" : "rectangle.dashed",
                                  accessibilityDescription: "FrameShare")
                img?.isTemplate = true
                self?.statusItem.button?.image = img
            }
        }
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
