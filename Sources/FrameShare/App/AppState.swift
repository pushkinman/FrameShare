//
//  AppState.swift
//  FrameShare
//
//  Created by Anton Pushkin.
//  Copyright © 2026 Anton Pushkin. All rights reserved.
//

import AppKit
import Combine
import Carbon.HIToolbox

enum AspectRatio: String, CaseIterable, Identifiable, Codable {
    case r16x9 = "16:9", r16x10 = "16:10", r4x3 = "4:3", r3x2 = "3:2", r1x1 = "1:1",
         r21x9 = "21:9", r9x16 = "9:16", free = "Free"
    var id: String { rawValue }
    var value: CGFloat? {
        switch self {
        case .r16x9: 16.0 / 9.0
        case .r16x10: 16.0 / 10.0
        case .r4x3: 4.0 / 3.0
        case .r3x2: 3.0 / 2.0
        case .r1x1: 1
        case .r21x9: 21.0 / 9.0
        case .r9x16: 9.0 / 16.0
        case .free: nil
        }
    }
}

enum DrawTool: String, CaseIterable, Codable, Identifiable {
    case pen, highlighter, line, arrow, rectangle, ellipse, eraser
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .eraser: "eraser"
        }
    }
}

enum TimerMode: String, CaseIterable, Codable, Identifiable {
    case stopwatch = "Stopwatch", countdown = "Countdown"
    var id: String { rawValue }
}

enum Corner: String, CaseIterable, Codable, Identifiable {
    case topLeft = "Top left", topRight = "Top right", bottomLeft = "Bottom left", bottomRight = "Bottom right"
    var id: String { rawValue }
}

/// Where the shared window lives. It must stay "open" for meeting apps to share it.
enum MirrorVisibility: String, CaseIterable, Codable, Identifiable {
    case hidden = "Hidden (recommended)", behind = "Behind other windows", visible = "Visible"
    var id: String { rawValue }
}

/// When the floating control bar is on screen.
enum ControlBarMode: String, CaseIterable, Codable, Identifiable {
    case whileSharing = "While sharing", always = "Always", whileDrawing = "Only while drawing"
    var id: String { rawValue }
}

enum PrivacyMode: String, CaseIterable, Codable, Identifiable {
    case blur = "Blur", exclude = "Hide"
    var id: String { rawValue }
}

struct PrivacyRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var bundleID: String
    var name: String
    var mode: PrivacyMode
}

struct Hotkey: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask

    static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var display: String {
        KeyNames.symbols(control: modifiers & UInt32(controlKey) != 0,
                         option: modifiers & UInt32(optionKey) != 0,
                         shift: modifiers & UInt32(shiftKey) != 0,
                         command: modifiers & UInt32(cmdKey) != 0) + KeyNames.name(for: Int(keyCode))
    }
}

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case toggleSharing, toggleDrawing, clearDrawings, toggleSpotlight, toggleZoom, toggleTimer,
         toggleKeystrokes, toggleBlurAll, toggleHideCursor, snapFrameToWindow, fitWindowToFrame,
         positionLeft, positionCenter, positionRight, halfLeft, halfRight, toggleControlBar, toggleClicks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .toggleSharing: "Start / stop sharing"
        case .toggleDrawing: "Drawing mode"
        case .clearDrawings: "Clear drawings"
        case .toggleSpotlight: "Spotlight"
        case .toggleZoom: "Zoom"
        case .toggleTimer: "Timer"
        case .toggleKeystrokes: "Show keystrokes"
        case .toggleBlurAll: "Blur everything"
        case .toggleHideCursor: "Hide cursor"
        case .snapFrameToWindow: "Frame → active window"
        case .fitWindowToFrame: "Active window → frame"
        case .positionLeft: "Move frame left"
        case .positionCenter: "Move frame to center"
        case .positionRight: "Move frame right"
        case .halfLeft: "Left half (press again: ⅔, ⅓)"
        case .halfRight: "Right half (press again: ⅔, ⅓)"
        case .toggleControlBar: "Show / hide control bar"
        case .toggleClicks: "Show clicks"
        }
    }

    static var defaults: [HotkeyAction: Hotkey] {
        let co = UInt32(controlKey | optionKey)
        let coc = UInt32(controlKey | optionKey | cmdKey)
        let cos = UInt32(controlKey | optionKey | shiftKey)
        return [
            .toggleSharing: Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: co),
            .toggleDrawing: Hotkey(keyCode: UInt32(kVK_ANSI_D), modifiers: co),
            .clearDrawings: Hotkey(keyCode: UInt32(kVK_ANSI_C), modifiers: co),
            .toggleSpotlight: Hotkey(keyCode: UInt32(kVK_ANSI_L), modifiers: co),
            .toggleZoom: Hotkey(keyCode: UInt32(kVK_ANSI_Z), modifiers: co),
            .toggleTimer: Hotkey(keyCode: UInt32(kVK_ANSI_T), modifiers: co),
            .toggleKeystrokes: Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: co),
            .toggleBlurAll: Hotkey(keyCode: UInt32(kVK_ANSI_B), modifiers: co),
            .snapFrameToWindow: Hotkey(keyCode: UInt32(kVK_ANSI_W), modifiers: co),
            .positionLeft: Hotkey(keyCode: UInt32(kVK_LeftArrow), modifiers: coc),
            .positionCenter: Hotkey(keyCode: UInt32(kVK_DownArrow), modifiers: coc),
            .positionRight: Hotkey(keyCode: UInt32(kVK_RightArrow), modifiers: coc),
            .halfLeft: Hotkey(keyCode: UInt32(kVK_LeftArrow), modifiers: cos),
            .halfRight: Hotkey(keyCode: UInt32(kVK_RightArrow), modifiers: cos),
            .toggleControlBar: Hotkey(keyCode: UInt32(kVK_ANSI_G), modifiers: co),
            .toggleClicks: Hotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: co),
        ]
    }
}

/// Everything that is saved between launches.
struct Settings: Codable, Equatable {
    /// Bumped when defaults change, so saved settings can be upgraded once.
    var version = 0
    var region: CGRect = .zero
    var ratio: AspectRatio = .r16x9
    var showFrame = true
    var frameColorHex = "#FF3B30"
    var frameOpacity: Double = 0.9
    var borderWidth: Double = 3
    var padding: Double = 0
    var lockFrame = false
    var dimOutside = true
    var dimOpacity: Double = 0.45
    var hideCursor = false
    var fps: Int = 60
    /// Size the shared window so it has as many pixels as the frame (sharpest result).
    var matchMirrorToFrame = true
    var mirrorTitle = "FrameShare"
    var hideTitleBar = false
    var mirrorVisibility: MirrorVisibility = .hidden
    var controlBarMode: ControlBarMode = .whileSharing
    var controlBarExpanded = true
    var controlBarVertical = false
    /// Top-left corner of the control bar (AppKit coordinates); nil = default spot.
    var controlBarTopLeft: CGPoint?
    var tool: DrawTool = .pen
    var penColorHex = "#FF3B30"
    var penWidth: Double = 4
    /// Seconds before drawings fade away on their own (0 = keep them).
    var drawingFadeSeconds: Double = 0
    var spotlightRadius: Double = 160
    var spotlightDim: Double = 0.65
    var zoomFactor: Double = 2
    var timerMode: TimerMode = .stopwatch
    var countdownMinutes: Int = 10
    var timerCorner: Corner = .topRight
    var keystrokesOnlyShortcuts = false
    var privacyRules: [PrivacyRule] = []
    var titleKeywords: [String] = []
    var matchBrowserURLs = false
    var blurRadius: Double = 24
    var hotkeys: [HotkeyAction: Hotkey] = HotkeyAction.defaults

    init() {}

    // Tolerant decoding: missing keys keep their defaults, so new settings never wipe old ones.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        get(.version, &version); get(.matchMirrorToFrame, &matchMirrorToFrame)
        get(.region, &region); get(.ratio, &ratio); get(.showFrame, &showFrame)
        get(.frameColorHex, &frameColorHex); get(.frameOpacity, &frameOpacity)
        get(.borderWidth, &borderWidth); get(.padding, &padding); get(.lockFrame, &lockFrame)
        get(.dimOutside, &dimOutside); get(.dimOpacity, &dimOpacity); get(.hideCursor, &hideCursor)
        get(.fps, &fps); get(.mirrorTitle, &mirrorTitle); get(.hideTitleBar, &hideTitleBar)
        get(.mirrorVisibility, &mirrorVisibility);
        get(.controlBarMode, &controlBarMode); get(.controlBarExpanded, &controlBarExpanded)
        get(.controlBarVertical, &controlBarVertical); get(.controlBarTopLeft, &controlBarTopLeft); get(.tool, &tool); get(.penColorHex, &penColorHex)
        get(.penWidth, &penWidth); get(.drawingFadeSeconds, &drawingFadeSeconds); get(.spotlightRadius, &spotlightRadius); get(.spotlightDim, &spotlightDim)
        get(.zoomFactor, &zoomFactor); get(.timerMode, &timerMode); get(.countdownMinutes, &countdownMinutes)
        get(.timerCorner, &timerCorner); get(.keystrokesOnlyShortcuts, &keystrokesOnlyShortcuts)
        get(.privacyRules, &privacyRules); get(.titleKeywords, &titleKeywords)
        get(.matchBrowserURLs, &matchBrowserURLs); get(.blurRadius, &blurRadius); get(.hotkeys, &hotkeys)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var settings: Settings

    // Session-only state
    @Published var isSharing = false
    @Published var isDrawing = false
    @Published var spotlightOn = false
    @Published var zoomOn = false
    @Published var timerVisible = false
    @Published var timerRunning = false
    @Published var timerText = "00:00"
    @Published var keystrokesOn = false
    @Published var blurAll = false
    @Published var clicksOn = false
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var statusMessage: String?

    static let currentVersion = 6

    private static func migrate(_ s: inout Settings) {
        guard s.version < currentVersion else { return }
        if s.version < 2 {
            s.fps = 60
            s.matchMirrorToFrame = true
            for (action, key) in HotkeyAction.defaults where s.hotkeys[action] == nil
                && !s.hotkeys.values.contains(key) {
                s.hotkeys[action] = key
            }
        }
        if s.version < 3 && s.padding == 2 { s.padding = 0 }
        if s.version < 4 { s.mirrorVisibility = .hidden }
        // Give newly added actions their default shortcut, if nothing else uses it.
        let added: [(Int, HotkeyAction)] = [(5, .toggleControlBar), (6, .toggleClicks)]
        for (v, action) in added where s.version < v && s.hotkeys[action] == nil {
            if let key = HotkeyAction.defaults[action], !s.hotkeys.values.contains(key) { s.hotkeys[action] = key }
        }
        s.version = currentVersion
    }

    private static let key = "FrameShare.settings.v1"
    private var saveCancellable: AnyCancellable?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = s
        } else {
            settings = Settings()
        }
        Self.migrate(&settings)
        saveCancellable = $settings
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { s in Self.save(s) }
    }

    /// Writes settings right away (used on quit, so nothing from the last moment is lost).
    func saveNow() { Self.save(settings) }

    private static func save(_ s: Settings) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
