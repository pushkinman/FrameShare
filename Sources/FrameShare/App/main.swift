//
//  main.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
