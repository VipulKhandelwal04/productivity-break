// productivity_break — a productivity nudge for macOS.
//
// Watches how long your terminal has been the *focused* (frontmost) app.
// After 25 minutes of continuous focused use, a full-screen break overlay
// fills the screen, holds for a few seconds, then fades away. The timer resets.
//
// "Continuous focus": the clock only ticks while the terminal is the active
// app. Switch away and it pauses (does NOT reset); switch back and it resumes.
//
// The overlay shows a hand-drawn vector animal by default. If a break visual is
// found (see resolveMediaURL / the PRODUCTIVITY_BREAK_VIDEO env var) it is shown
// instead — a looping video (mp4/mov) OR a still image / animated GIF.
//
// Build:  swift build -c release    (or: swiftc -O Sources/productivity_break/main.swift -o productivity_break)
// Run:    .build/release/productivity_break
//         .build/release/productivity_break --test       (show the overlay right now)
//         BREAK_MINUTES=0.2 .build/release/productivity_break

import Cocoa
import AVFoundation
import CoreGraphics

// ---------------------------------------------------------------------------
// Configuration (override with env vars)
// ---------------------------------------------------------------------------
let ENV = ProcessInfo.processInfo.environment
// Parsed once at startup; consulted by the env helpers below when an env var is
// absent. MUST be initialized here, before any config `let` constant uses it.
let CFG = loadConfigJSON()
func envDouble(_ key: String, _ def: Double) -> Double {
    if let v = ENV[key], let x = Double(v) { return x }
    if let v = CFG[key], let x = Double(v) { return x }
    return def
}

// Parse a boolean-ish env var consistently (on/off/true/false/yes/no/1/0).
func envBool(_ key: String, _ def: Bool) -> Bool {
    let raw = ENV[key] ?? CFG[key]
    guard let v = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return def }
    if ["1", "on", "true", "yes", "y"].contains(v) { return true }
    if ["0", "off", "false", "no", "n"].contains(v) { return false }
    return def
}

// ============================================================================
// Layered config file support.
//
// Precedence (lowest -> highest):
//   built-in default  <  ~/.config/productivity_break/config.json  <  env var
//
// CFG is a [String:String] parsed from the JSON file at startup. The env-lookup
// helpers (envDouble/envBool/envString) consult CFG only when the env var is
// absent, so the environment always wins and the existing top-level `let`
// constants keep working unchanged. JSON keys are the env var names verbatim.
// ============================================================================
func loadConfigJSON() -> [String: String] {
    let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".config/productivity_break/config.json")
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return [:] }   // no file -> defaults only

    guard let data = fm.contents(atPath: path) else {
        FileHandle.standardError.write("[productivity_break] could not read \(path) — ignoring.\n".data(using: .utf8)!)
        return [:]
    }
    let parsed: Any
    do {
        parsed = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
        FileHandle.standardError.write("[productivity_break] invalid JSON in \(path): \(error.localizedDescription) — ignoring.\n".data(using: .utf8)!)
        return [:]
    }
    guard let dict = parsed as? [String: Any] else {
        FileHandle.standardError.write("[productivity_break] \(path) must contain a top-level JSON object — ignoring.\n".data(using: .utf8)!)
        return [:]
    }

    var out: [String: String] = [:]
    for (k, v) in dict {
        // Disambiguate JSON booleans from numbers: JSONSerialization bridges both
        // to NSNumber, and `true` would otherwise stringify to "1".
        if let n = v as? NSNumber, CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
            out[k] = n.boolValue ? "true" : "false"
        } else if let s = v as? String {
            out[k] = s
        } else if let n = v as? NSNumber {
            out[k] = n.stringValue
        } else if let arr = v as? [Any] {
            // Comma-join arrays so list-style keys work with the existing
            // `.split(separator: ",")` call sites.
            out[k] = arr.map { "\($0)" }.joined(separator: ",")
        }
        // anything else (null/nested object) is ignored
    }
    return out
}

// Look up a raw string: env var wins, else config.json, else nil.
func envString(_ key: String) -> String? {
    if let v = ENV[key] { return v }
    return CFG[key]
}

// Remove any leftover downloaded break visual(s) from the temp dir.
func cleanupTempVisuals() {
    let dir = NSTemporaryDirectory()
    let fm = FileManager.default
    if let items = try? fm.contentsOfDirectory(atPath: dir) {
        for f in items where f.hasPrefix("productivity_break_visual.") {
            try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(f))
        }
    }
}

// Can this media file actually be decoded? (Network images are validated on
// download; this guards local/pinned files so a corrupt one doesn't show blank.)
func mediaIsUsable(_ url: URL) -> Bool {
    if isImageURL(url) { return NSImage(contentsOf: url) != nil }
    return !AVURLAsset(url: url).tracks(withMediaType: .video).isEmpty
}

let BREAK_MINUTES   = max(0.05, envDouble("BREAK_MINUTES", 25))            // focus time before the break shows
let SHOW_SECONDS    = max(0.1, envDouble("PRODUCTIVITY_BREAK_SHOW_SECONDS", 8))   // how long the overlay stays up
let POLL_SECONDS    = max(0.5, envDouble("PRODUCTIVITY_BREAK_POLL_SECONDS", 5))   // how often we check the focused app
let OVERLAY_ALPHA   = min(1.0, max(0.0, envDouble("PRODUCTIVITY_BREAK_OVERLAY_ALPHA", 0.92)))  // background dimming
let IDLE_SECONDS    = max(5.0, envDouble("PRODUCTIVITY_BREAK_IDLE_SECONDS", 60)) // input-idle time that pauses the focus clock
let THRESHOLD       = max(1.0, BREAK_MINUTES * 60.0)
let SNOOZE_MINUTES  = max(0.05, envDouble("PRODUCTIVITY_BREAK_SNOOZE_MINUTES", 5))  // re-arm delay when snoozed

// Break presentation style. "overlay" (default) shows the full-screen overlay;
// "notify" posts a lightweight macOS notification via osascript instead
// (no bundle id required — UNUserNotificationCenter would NOT work here).
// Reads via envString so it also honors config.json (env wins).
let BREAK_STYLE = (envString("PRODUCTIVITY_BREAK_STYLE") ?? "overlay")
    .trimmingCharacters(in: .whitespaces).lowercased()

let APP_VERSION = "0.2.0"
// Generic, non-identifying User-Agent (no app name/version) for the content APIs.
let HTTP_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"

// Apps during which a due break is postponed (not reset) — calls, screen shares,
// recording. Matched as case-insensitive substrings of the frontmost app name.
let DEFER_APPS: [String] = (envString("PRODUCTIVITY_BREAK_DEFER_APPS")
    ?? "zoom,Microsoft Teams,Webex,FaceTime,OBS Studio,QuickTime Player,ScreenFlow,Loom,Keynote")
    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }

let TERMINAL_APPS: [String] = (envString("PRODUCTIVITY_BREAK_TERMINAL_APPS")
    ?? "Terminal,iTerm,Warp,Alacritty,kitty,Hyper,WezTerm,Ghostty")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    .filter { !$0.isEmpty }

let IMAGE_EXTENSIONS = ["gif", "png", "jpg", "jpeg", "heic", "bmp", "tiff", "webp"]
let MEDIA_EXTENSIONS = ["mp4", "mov", "m4v"] + IMAGE_EXTENSIONS   // search/preference order

func isImageURL(_ url: URL) -> Bool {
    IMAGE_EXTENSIONS.contains(url.pathExtension.lowercased())
}

// Find an optional break visual (video, image, or GIF). It is NOT bundled with
// the project (it may be third-party art); we look in these places, in order:
//   1. $PRODUCTIVITY_BREAK_VIDEO  (any media file — kept this name for compat)
//   2. productivity_break.<ext> next to the executable          (installed layout)
//   3. ~/Library/Application Support/productivity_break/productivity_break.<ext>
//   4. ./Resources/productivity_break.<ext> and ./productivity_break.<ext>
//   5. ~/productivity_break/Resources/productivity_break.<ext> (legacy)
// If none exist, we draw a vector animal instead.
func resolveMediaURL() -> URL? {
    let fm = FileManager.default
    var paths: [String] = []
    if let p = envString("PRODUCTIVITY_BREAK_VIDEO") { paths.append(p) }
    let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    let exeDir = (exe as NSString).deletingLastPathComponent
    let home = NSHomeDirectory() as NSString
    let cwd = fm.currentDirectoryPath
    let dirs = [
        exeDir,
        home.appendingPathComponent("Library/Application Support/productivity_break"),
        cwd + "/Resources",
        cwd,
        home.appendingPathComponent("productivity_break/Resources"),
    ]
    for d in dirs {
        for e in MEDIA_EXTENSIONS {
            paths.append(d + "/productivity_break." + e)
        }
    }
    for p in paths where fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
    return nil
}

func mediaNaturalSize(_ url: URL) -> CGSize {
    let fallback = CGSize(width: 720, height: 1280)
    if isImageURL(url) {
        if let rep = NSImage(contentsOf: url)?.representations.first {
            let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
            if w > 0 && h > 0 { return CGSize(width: w, height: h) }
        }
        return fallback
    }
    let asset = AVURLAsset(url: url)
    if let track = asset.tracks(withMediaType: .video).first {
        let sz = track.naturalSize.applying(track.preferredTransform)
        let w = abs(sz.width), h = abs(sz.height)
        if w > 0 && h > 0 { return CGSize(width: w, height: h) }
    }
    return fallback
}

// ---------------------------------------------------------------------------
// The overlay view: dims the screen, shows a break banner, and either hosts
// the break visual or draws a vector animal as the default.
// ---------------------------------------------------------------------------
final class DimView: NSView {
    var message = ""
    var slideOffset: CGFloat = 0     // used by the vector art
    var bob: CGFloat = 0
    var useVectorArt = false
    var contentRect: NSRect = .zero   // main-screen region (layout target); .zero -> bounds
    var hintText = ""                  // dismiss/snooze hint + countdown
    weak var controller: OverlayController?

    override var isFlipped: Bool { false }   // origin bottom-left, y grows upward

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        controller?.dismiss()         // click anywhere to dismiss early
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 49: controller?.dismiss()              // Esc or Space
        case 1:      controller?.dismiss(snooze: true)  // S = snooze
        default:     break                              // swallow (no beep)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSColor(calibratedWhite: 0.04, alpha: OVERLAY_ALPHA).setFill()
        b.fill()                              // dim EVERY display

        let c = contentRect.width > 0 ? contentRect : bounds   // lay out on the main screen
        drawMessage(in: c)
        drawHint(in: c)

        if useVectorArt {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: 0, yBy: -slideOffset + bob)
            t.concat()
            drawProductivityBreak(in: c)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawMessage(in b: NSRect) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 6
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        func attrs(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.white,
             .paragraphStyle: para, .shadow: shadow]
        }
        let msg = message as NSString
        let boxW = b.width * 0.8
        let maxH = b.height * 0.16
        // Shrink the font until a long quote/fact fits the banner band instead
        // of overflowing off-screen.
        var fontSize = max(20, b.height / 30)
        func measure(_ size: CGFloat) -> NSRect {
            msg.boundingRect(with: NSSize(width: boxW, height: .greatestFiniteMagnitude),
                             options: [.usesLineFragmentOrigin], attributes: attrs(size))
        }
        var measured = measure(fontSize)
        while fontSize > 13 && measured.height > maxH {
            fontSize -= 2
            measured = measure(fontSize)
        }
        let y = b.minY + b.height * 0.9 - measured.height / 2
        msg.draw(with: NSRect(x: b.minX + (b.width - boxW) / 2, y: y, width: boxW, height: measured.height),
                 options: [.usesLineFragmentOrigin], attributes: attrs(fontSize))
    }

    private func drawHint(in b: NSRect) {
        guard !hintText.isEmpty else { return }
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85); shadow.shadowBlurRadius = 8
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(12, b.height / 55), weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .paragraphStyle: para, .shadow: shadow,
        ]
        let t = hintText as NSString
        let boxW = b.width * 0.8
        let m = t.boundingRect(with: NSSize(width: boxW, height: 200),
                               options: [.usesLineFragmentOrigin], attributes: attrs)
        t.draw(with: NSRect(x: b.minX + (b.width - boxW) / 2, y: b.minY + b.height * 0.045,
                            width: boxW, height: m.height),
               options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    // ----- the hand-drawn vector animal (default) -----
    private func ov(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }
    private func fillStroke(_ path: NSBezierPath, _ fill: NSColor, _ stroke: NSColor?, _ w: CGFloat) {
        fill.setFill(); path.fill()
        if let s = stroke { s.setStroke(); path.lineWidth = w; path.stroke() }
    }
    private func drawProductivityBreak(in b: NSRect) {
        let orange  = NSColor(srgbRed: 0.949, green: 0.635, blue: 0.235, alpha: 1)
        let orangeD = NSColor(srgbRed: 0.878, green: 0.482, blue: 0.180, alpha: 1)
        let cream   = NSColor(srgbRed: 0.984, green: 0.902, blue: 0.784, alpha: 1)
        let pink    = NSColor(srgbRed: 0.965, green: 0.651, blue: 0.698, alpha: 1)
        let dark    = NSColor(srgbRed: 0.227, green: 0.165, blue: 0.118, alpha: 1)
        let white   = NSColor.white
        let s = b.height / 20.0
        let cx = b.midX
        let feetY = b.minY + b.height * 0.05
        let bodyCy = feetY + 4.2 * s
        let headCy = feetY + 10.2 * s
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: cx + 3.4 * s, y: feetY + 2.6 * s))
        tail.curve(to: NSPoint(x: cx + 5.2 * s, y: feetY + 9.2 * s),
                   controlPoint1: NSPoint(x: cx + 7.6 * s, y: feetY + 3.5 * s),
                   controlPoint2: NSPoint(x: cx + 8.0 * s, y: feetY + 8.5 * s))
        tail.lineWidth = 1.5 * s; tail.lineCapStyle = .round
        orange.setStroke(); tail.stroke()
        fillStroke(ov(cx, bodyCy, 4.2 * s, 4.7 * s), orange, orangeD, 0.14 * s)
        fillStroke(ov(cx, bodyCy - 0.4 * s, 2.6 * s, 3.4 * s), cream, nil, 0)
        for px in [-1.7 as CGFloat, 1.7] {
            fillStroke(ov(cx + px * s, feetY + 0.9 * s, 0.85 * s, 0.95 * s), cream, orangeD, 0.08 * s)
        }
        fillStroke(ov(cx, headCy, 3.5 * s, 3.4 * s), orange, orangeD, 0.14 * s)
        func ear(_ sign: CGFloat) {
            let outer = NSBezierPath()
            outer.move(to: NSPoint(x: cx + sign * 3.0 * s, y: headCy + 1.6 * s))
            outer.line(to: NSPoint(x: cx + sign * 3.8 * s, y: headCy + 5.0 * s))
            outer.line(to: NSPoint(x: cx + sign * 1.1 * s, y: headCy + 3.0 * s))
            outer.close(); fillStroke(outer, orange, orangeD, 0.1 * s)
            let inner = NSBezierPath()
            inner.move(to: NSPoint(x: cx + sign * 2.7 * s, y: headCy + 2.0 * s))
            inner.line(to: NSPoint(x: cx + sign * 3.2 * s, y: headCy + 4.2 * s))
            inner.line(to: NSPoint(x: cx + sign * 1.7 * s, y: headCy + 3.0 * s))
            inner.close(); fillStroke(inner, pink, nil, 0)
        }
        ear(-1); ear(1)
        for dx in [-0.5 as CGFloat, 0.0, 0.5] {
            let st = NSBezierPath()
            st.move(to: NSPoint(x: cx + dx * s, y: headCy + 1.4 * s))
            st.line(to: NSPoint(x: cx + dx * s, y: headCy + 2.6 * s))
            st.lineWidth = 0.2 * s; st.lineCapStyle = .round
            orangeD.setStroke(); st.stroke()
        }
        fillStroke(ov(cx, headCy - 1.3 * s, 3.2 * s, 1.9 * s), cream, nil, 0)
        for ex in [-1.5 as CGFloat, 1.5] {
            fillStroke(ov(cx + ex * s, headCy + 0.1 * s, 0.95 * s, 1.05 * s), white, dark, 0.06 * s)
            fillStroke(ov(cx + ex * s, headCy - 0.05 * s, 0.46 * s, 0.66 * s), dark, nil, 0)
            fillStroke(ov(cx + ex * s + 0.22 * s, headCy + 0.35 * s, 0.2 * s, 0.22 * s), white, nil, 0)
        }
        let nose = NSBezierPath()
        nose.move(to: NSPoint(x: cx - 0.45 * s, y: headCy - 1.4 * s))
        nose.line(to: NSPoint(x: cx + 0.45 * s, y: headCy - 1.4 * s))
        nose.line(to: NSPoint(x: cx, y: headCy - 2.05 * s))
        nose.close(); fillStroke(nose, pink, orangeD, 0.05 * s)
        for side in [-1.0 as CGFloat, 1.0] {
            for i in 0..<3 {
                let k = CGFloat(i)
                let wpath = NSBezierPath()
                wpath.move(to: NSPoint(x: cx + side * 1.0 * s, y: headCy - (1.2 + 0.55 * k) * s))
                wpath.line(to: NSPoint(x: cx + side * 4.4 * s, y: headCy - (0.7 + 0.55 * k) * s))
                wpath.lineWidth = 0.07 * s; wpath.lineCapStyle = .round
                white.setStroke(); wpath.stroke()
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Overlay window + animation
// ---------------------------------------------------------------------------
// A borderless window normally can't become key; allow it so the overlay can
// receive keyboard input (Esc / Space / S) during the break.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayController {
    enum Phase { case fadingIn, holding, fadingOut }

    private let window: NSWindow
    private let view: DimView
    private var mediaContainer: NSView?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var timer: Timer?

    private var phase: Phase = .fadingIn
    private var phaseStart = Date()
    private var lastRemaining = -1
    private var previousApp: NSRunningApplication?
    var snoozeRequested = false
    private let startOffset: CGFloat
    private let restY: CGFloat
    private let bobAmp: CGFloat
    var onDone: (() -> Void)?

    private let slideDur = 0.6
    private let fadeInDur = 0.4
    private let fadeOutDur = 0.5

    init(message: String, mediaURL: URL? = nil) {
        // Span ALL displays with one window so every monitor dims; lay the
        // visual/message out on the main screen's region within that window.
        let screens = NSScreen.screens
        let mainFrame = (NSScreen.main ?? screens.first)?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)   // safe fallback; showBreak() guards real use
        let union = screens.isEmpty ? mainFrame : screens.reduce(mainFrame) { $0.union($1.frame) }
        let content = NSRect(x: mainFrame.origin.x - union.origin.x,
                             y: mainFrame.origin.y - union.origin.y,
                             width: mainFrame.width, height: mainFrame.height)
        window = KeyableWindow(contentRect: union, styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.alphaValue = 0

        view = DimView(frame: NSRect(origin: .zero, size: union.size))
        view.message = message
        view.contentRect = content

        // Try a break visual (video, image, or GIF), fitted into the lower ~84%
        // of the MAIN screen (leaving a band at the top for the break banner).
        // Fall back to the vector art if no media is available.
        var rest: CGFloat = 0
        var startOff = content.height * 1.12
        if let url = (mediaURL ?? resolveMediaURL()), mediaIsUsable(url) {
            let size = mediaNaturalSize(url)
            let vw = size.width, vh = size.height
            // Reserve a top band for the message and a bottom band for the hint,
            // and fit the media into the middle — so text is never covered.
            let topBand = content.height * 0.20      // message lives here
            let bottomBand = content.height * 0.07   // countdown/hint lives here
            let regionH = content.height - topBand - bottomBand
            let availW = content.width * 0.92
            let scale = min(availW / vw, regionH / vh)
            let w = vw * scale, h = vh * scale
            let x = content.minX + (content.width - w) / 2
            rest = content.minY + bottomBand + (regionH - h) / 2   // centered in the middle band
            startOff = rest - (content.minY - h)     // start just below the main screen

            let container = NSView(frame: NSRect(x: x, y: rest, width: w, height: h))
            container.wantsLayer = true
            container.layer?.cornerRadius = max(10, w * 0.04)
            container.layer?.masksToBounds = true

            if isImageURL(url) {
                let iv = NSImageView(frame: container.bounds)
                // Load bytes into memory now so a later prefetch overwriting the
                // temp file can't affect what's on screen. (Animates GIFs too.)
                iv.image = (try? Data(contentsOf: url)).flatMap { NSImage(data: $0) } ?? NSImage(contentsOf: url)
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.animates = true                 // animates GIFs
                iv.autoresizingMask = [.width, .height]
                container.addSubview(iv)
            } else {
                let item = AVPlayerItem(url: url)
                let queue = AVQueuePlayer()
                queue.isMuted = true
                let lp = AVPlayerLooper(player: queue, templateItem: item)
                let playerLayer = AVPlayerLayer(player: queue)
                playerLayer.frame = container.bounds
                playerLayer.videoGravity = .resizeAspect
                container.layer?.addSublayer(playerLayer)
                self.player = queue
                self.looper = lp
            }

            view.addSubview(container)
            self.mediaContainer = container
            container.setFrameOrigin(NSPoint(x: x, y: rest - startOff))
        } else {
            view.useVectorArt = true
            view.slideOffset = startOff
        }

        restY = rest
        startOffset = startOff
        bobAmp = content.height * 0.004

        window.contentView = view
        view.controller = self
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        player?.play()
        phase = .fadingIn
        phaseStart = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func dismiss(snooze: Bool = false) {
        if phase == .fadingIn { return }   // ignore clicks/keys during the slide-in
        if phase != .fadingOut {
            snoozeRequested = snooze
            phase = .fadingOut
            phaseStart = Date()
        }
    }

    private func place(offset: CGFloat, bob: CGFloat) {
        if let c = mediaContainer {
            c.setFrameOrigin(NSPoint(x: c.frame.origin.x, y: restY - offset + bob))
        } else {
            view.slideOffset = offset
            view.bob = bob
            view.needsDisplay = true
        }
    }

    private func tick() {
        let e = Date().timeIntervalSince(phaseStart)
        switch phase {
        case .fadingIn:
            let p = min(1.0, e / slideDur)
            let ease = 1 - pow(1 - p, 3)                       // easeOutCubic
            place(offset: startOffset * (1 - ease), bob: 0)
            window.alphaValue = min(1.0, e / fadeInDur)
            if e >= slideDur {
                place(offset: 0, bob: 0)
                window.alphaValue = 1
                phase = .holding
                phaseStart = Date()
            }
        case .holding:
            place(offset: 0, bob: CGFloat(sin(e * 2.2)) * bobAmp)
            let remaining = max(0, Int(ceil(SHOW_SECONDS - e)))
            if remaining != lastRemaining {
                lastRemaining = remaining
                view.hintText = "\(remaining)s  ·  Esc / click to dismiss  ·  S to snooze"
                view.needsDisplay = true
            }
            if e >= SHOW_SECONDS {
                phase = .fadingOut
                phaseStart = Date()
            }
        case .fadingOut:
            window.alphaValue = max(0, 1 - e / fadeOutDur)
            if e >= fadeOutDur {
                timer?.invalidate(); timer = nil
                player?.pause()
                window.orderOut(nil)
                previousApp?.activate(options: [])
                onDone?()
                return
            }
        }
    }
}

// ---------------------------------------------------------------------------
// App delegate: focus monitoring
// ---------------------------------------------------------------------------
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var focused = 0.0
    private var lastTick = Date()
    private var overlay: OverlayController?
    private var monitor: Timer?
    private var presenting = false
    private var paused = false
    private var statusItem: NSStatusItem?
    private var cachedMessage: String?       // pre-fetched ahead of time so the
    private var cachedMediaURL: URL?         // break is instant & doesn't leak cadence
    private var prefetchTimer: Timer?
    private let testMode: Bool

    init(testMode: Bool) { self.testMode = testMode }

    func applicationDidFinishLaunching(_ note: Notification) {
        if testMode {
            FileHandle.standardError.write("[productivity_break] --test: showing the break overlay now.\n".data(using: .utf8)!)
            showBreak()
            return
        }
        FileHandle.standardError.write(
            "[productivity_break] watching terminal focus — break appears after \(fmt(BREAK_MINUTES)) min of continuous focused use.\n"
                .data(using: .utf8)!)
        if envBool("PRODUCTIVITY_BREAK_MENUBAR", false) { setupMenuBar() }
        lastTick = Date()
        let t = Timer(timeInterval: POLL_SECONDS, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        monitor = t
        prefetch()              // warm content now...
        scheduleNextPrefetch()  // ...and refresh on a jittered timer (decoupled from breaks)
    }

    // Fetch a message + matching visual ahead of time so the break can appear
    // instantly and the network activity isn't tied to your break cadence.
    private func prefetch() {
        fetchBreakMessage { [weak self] msg in
            guard let self = self else { return }
            self.fetchBreakImage(for: msg) { [weak self] url in
                self?.cachedMessage = msg
                self?.cachedMediaURL = url
            }
        }
    }

    private func scheduleNextPrefetch() {
        let delay = max(60.0, 600.0 + Double.random(in: -150...240))   // ~7.5–14 min, jittered
        prefetchTimer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.prefetch()
            self?.scheduleNextPrefetch()
        }
        RunLoop.main.add(t, forMode: .common)
        prefetchTimer = t
    }

    // Opt-in menu-bar control (PRODUCTIVITY_BREAK_MENUBAR=on). Default off keeps
    // the tool invisible. Works under .accessory (no Dock icon).
    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "☕"
        let menu = NSMenu()
        menu.delegate = self
        statusItem = item
        item.menu = menu
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        let mins = Int(focused / 60.0)
        let status = paused ? "Paused"
            : "Focused: \(mins)/\(Int(BREAK_MINUTES)) min"
        let s = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        s.isEnabled = false
        menu.addItem(s)
        menu.addItem(.separator())
        let take = NSMenuItem(title: "Take a break now", action: #selector(takeBreakNow), keyEquivalent: "b")
        let pause = NSMenuItem(title: paused ? "Resume" : "Pause", action: #selector(togglePause), keyEquivalent: "p")
        take.target = self; pause.target = self
        menu.addItem(take)
        menu.addItem(pause)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit productivity_break", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    @objc private func takeBreakNow() {
        guard overlay == nil && !presenting else { return }
        showBreak(force: true)
    }

    @objc private func togglePause() {
        paused.toggle()
        if !paused { lastTick = Date() }   // don't credit the paused span
        statusItem?.button?.title = paused ? "⏸" : "☕"
    }

    func applicationWillTerminate(_ note: Notification) {
        cleanupTempVisuals()
    }

    // Postpone (don't reset) a due break while a call/recording/presentation app
    // is frontmost, so we don't pop the overlay over a meeting or screen share.
    private func shouldDefer() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let name = (app.localizedName ?? "").lowercased()
        return DEFER_APPS.contains { name.contains($0) }
    }

    private func terminalFocused() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let name = (app.localizedName ?? "").lowercased()
        return TERMINAL_APPS.contains { name.contains($0) }
    }

    // Seconds since the last keyboard/mouse input — used to pause the clock when
    // the user walks away. Permission-free (unlike a CGEventTap).
    private func userIsIdle() -> Bool {
        guard let anyInput = CGEventType(rawValue: ~0) else { return false }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return idle >= IDLE_SECONDS
    }

    private func poll() {
        let now = Date()
        // Clamp dt so a sleep/wake gap doesn't dump the whole sleep duration
        // into the counter and fire a break the instant the machine wakes.
        let dt = min(now.timeIntervalSince(lastTick), POLL_SECONDS * 2)
        lastTick = now
        if paused || overlay != nil || presenting { return }   // paused, break up, or being prepared
        // Only count time the terminal is focused AND the user is actually here.
        if terminalFocused() && !userIsIdle() {
            focused += dt
            if focused >= THRESHOLD {
                FileHandle.standardError.write(
                    "[productivity_break] \(fmt(BREAK_MINUTES)) min of focus reached — here comes your break.\n"
                        .data(using: .utf8)!)
                showBreak()
            }
        }
        // not focused or idle -> pause: neither accumulate nor reset
    }

    private func showBreak(force: Bool = false) {
        guard (NSScreen.main ?? NSScreen.screens.first) != nil else {
            FileHandle.standardError.write("[productivity_break] no display available — skipping break.\n".data(using: .utf8)!)
            focused = 0
            lastTick = Date()
            if testMode { NSApp.terminate(nil) }
            return
        }
        if !force && shouldDefer() {
            FileHandle.standardError.write("[productivity_break] deferring break — a call/presentation app is active.\n".data(using: .utf8)!)
            lastTick = Date()   // keep `focused`; retry on a later poll
            return
        }
        presenting = true
        if let msg = cachedMessage {                       // instant: use pre-fetched content
            let url = cachedMediaURL
            cachedMessage = nil; cachedMediaURL = nil
            FileHandle.standardError.write("[productivity_break] break message: \(msg)\n".data(using: .utf8)!)
            presentBreak(message: msg, mediaURL: url)
            prefetch()                                     // warm the next one
        } else {                                           // cold: fetch live
            fetchBreakMessage { [weak self] msg in
                guard let self = self else { return }
                FileHandle.standardError.write("[productivity_break] break message: \(msg)\n".data(using: .utf8)!)
                self.fetchBreakImage(for: msg) { [weak self] mediaURL in
                    guard let self = self else { return }
                    self.presentBreak(message: msg, mediaURL: mediaURL)
                    self.prefetch()
                }
            }
        }
    }

    // Deliver the break as a macOS notification banner. Shells out to osascript so
    // it works WITHOUT a bundle id (UNUserNotificationCenter is unavailable to a
    // bare executable). The message is passed as an argv item — NOT interpolated
    // into the AppleScript source — so quotes/backslashes in API-sourced text
    // can't break or inject into the script.
    private func notifyBreak(message: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [
            "-e", "on run argv",
            "-e", "display notification (item 1 of argv) with title (item 2 of argv)",
            "-e", "end run",
            message, "productivity_break",
        ]
        do {
            try p.run()
            p.waitUntilExit()   // ensure the banner is dispatched before test-mode terminate
        } catch {
            FileHandle.standardError.write(
                "[productivity_break] notify failed: \(error)\n".data(using: .utf8)!)
        }
    }

    private func presentBreak(message: String, mediaURL: URL?) {
        if BREAK_STYLE == "notify" {
            FileHandle.standardError.write("[productivity_break] notify mode — posting notification.\n".data(using: .utf8)!)
            notifyBreak(message: message)
            // No overlay, no onDone callback: complete the break inline. Mirror the
            // non-snooze branch of OverlayController.onDone. Snooze has no equivalent
            // here (no key/button routing to a bare notification), so SNOOZE_MINUTES is inert.
            self.overlay = nil
            self.presenting = false          // CRITICAL: poll() guards on `presenting`; leaving it true stops all future breaks
            self.focused = 0                 // reset the focus clock (no snooze in notify mode)
            self.lastTick = Date()
            if self.testMode { NSApp.terminate(nil) }
            return
        }
        let oc = OverlayController(message: message, mediaURL: mediaURL)
        oc.onDone = { [weak self, weak oc] in
            guard let self = self else { return }
            let snoozed = oc?.snoozeRequested ?? false
            self.overlay = nil
            self.presenting = false
            // Snooze: re-arm in SNOOZE_MINUTES instead of nuking the cycle.
            self.focused = snoozed ? max(0, THRESHOLD - SNOOZE_MINUTES * 60.0) : 0
            self.lastTick = Date()
            if snoozed {
                FileHandle.standardError.write("[productivity_break] snoozed — back in ~\(Int(SNOOZE_MINUTES)) min.\n".data(using: .utf8)!)
            }
            if self.testMode { NSApp.terminate(nil) }
        }
        self.overlay = oc
        oc.show()
    }

    // Fetch a fresh quote / fun fact / piece of advice from a free public API,
    // chosen at random, so the break message changes every time. The call is
    // async with a short timeout and falls back to a local break message.
    //   - Disable all network with PRODUCTIVITY_BREAK_QUOTES=off
    //   - Use your own pool with PRODUCTIVITY_BREAK_MESSAGES (separated by "|")
    private func fetchBreakMessage(completion: @escaping (String) -> Void) {
        if let custom = envString("PRODUCTIVITY_BREAK_MESSAGES") {
            let list = custom.split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let pick = list.randomElement() { completion(pick); return }
        }
        if !envBool("PRODUCTIVITY_BREAK_QUOTES", true) {
            completion(localBreakMessage()); return
        }
        struct Source { let url: String; let parse: (Any) -> String? }
        let sources: [Source] = [
            Source(url: "https://zenquotes.io/api/random") { json in
                guard let arr = json as? [[String: Any]], let f = arr.first,
                      let q = f["q"] as? String, let a = f["a"] as? String else { return nil }
                return "\u{201C}\(q.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D} \u{2014} \(a)"
            },
            Source(url: "https://dummyjson.com/quotes/random") { json in
                guard let obj = json as? [String: Any], let q = obj["quote"] as? String,
                      let a = obj["author"] as? String else { return nil }
                return "\u{201C}\(q)\u{201D} \u{2014} \(a)"
            },
            Source(url: "https://uselessfacts.jsph.pl/api/v2/facts/random?language=en") { json in
                guard let obj = json as? [String: Any], let t = obj["text"] as? String else { return nil }
                return "Fun fact: \(t)"
            },
            Source(url: "https://api.adviceslip.com/advice") { json in
                guard let obj = json as? [String: Any], let slip = obj["slip"] as? [String: Any],
                      let a = slip["advice"] as? String else { return nil }
                return "\u{1F4A1} \(a)"
            },
        ]
        guard let src = sources.randomElement(), let url = URL(string: src.url) else {
            completion(localBreakMessage()); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(HTTP_UA, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            var result: String?
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) {
                result = src.parse(json)
            }
            let final = result ?? (self?.localBreakMessage() ?? "Time for a break.")
            DispatchQueue.main.async { completion(final) }
        }.resume()
    }

    // Offline fallback pool (break-focused).
    private func localBreakMessage() -> String {
        let m = fmt(BREAK_MINUTES)
        let messages = [
            "Break time! You've been heads-down for \(m) min \u{2014} go find a spot in nature.",
            "Time to step away. Stretch, breathe, and drop your shoulders.",
            "Rest your eyes \u{2014} look at something 20 feet away for 20 seconds.",
            "Hydrate! Go grab a glass of water. \u{1F4A7}",
            "\(m) minutes of focus \u{2014} you've earned a real break. Stand up!",
            "Unclench your jaw, relax your shoulders, take a deep breath. \u{1F9D8}",
            "Take five. The code will still be here when you get back.",
            "Screen break! Let your eyes wander somewhere far away.",
        ]
        return messages.randomElement() ?? messages[0]
    }

    // Pick a visual that resonates with the message: derive a theme from the
    // text, then fetch a relevant image (scenery via Openverse, or anime art).
    // Falls back to the local media file (or vector art) on any failure.
    //   - Disable with PRODUCTIVITY_BREAK_VISUALS=off  (uses the local visual)
    //   - A pinned PRODUCTIVITY_BREAK_VIDEO always wins and skips this.
    private func fetchBreakImage(for message: String, completion: @escaping (URL?) -> Void) {
        if !envBool("PRODUCTIVITY_BREAK_VISUALS", true)
            || envString("PRODUCTIVITY_BREAK_VIDEO") != nil {
            completion(nil); return
        }
        // If the user supplied their own provider key (Unsplash/Pexels photos,
        // Giphy/Tenor GIFs), prefer it; otherwise use the free sources. Either
        // way, fall back gracefully so a break always has a visual.
        if !userImageProviders().isEmpty {
            fetchFromUserProvider(for: message) { [weak self] url in
                if url != nil { completion(url) }
                else { self?.fetchSceneryOrAnime(for: message, completion: completion) }
            }
            return
        }
        fetchSceneryOrAnime(for: message, completion: completion)
    }

    // Free, no-key sources: themed scenery by default; opt-in anime art.
    private func fetchSceneryOrAnime(for message: String, completion: @escaping (URL?) -> Void) {
        let animeOn = envBool("PRODUCTIVITY_BREAK_ANIME", false)
        if animeOn && Int.random(in: 0..<3) == 0 {
            fetchAnimeImage { url in
                if url != nil { completion(url) }
                else { self.fetchSceneryImage(for: message, completion: completion) }
            }
        } else {
            fetchSceneryImage(for: message) { url in
                if url != nil { completion(url) }
                else if animeOn { self.fetchAnimeImage(completion: completion) }
                else { completion(nil) }
            }
        }
    }

    // ---- optional user-supplied image/GIF providers (via API key) ----
    // Set any of these (env or config.json) to fetch break visuals from a
    // provider of your choice, themed to the message. Get free keys at:
    //   Unsplash: https://unsplash.com/developers   Pexels: https://www.pexels.com/api/
    //   Giphy:    https://developers.giphy.com/      Tenor:  https://tenor.com/gifapi
    private func userImageProviders() -> [String] {
        func has(_ k: String) -> Bool { !(envString(k) ?? "").isEmpty }
        var providers: [String] = []
        if has("PRODUCTIVITY_BREAK_UNSPLASH_KEY") { providers.append("unsplash") }
        if has("PRODUCTIVITY_BREAK_PEXELS_KEY")   { providers.append("pexels") }
        if has("PRODUCTIVITY_BREAK_GIPHY_KEY")    { providers.append("giphy") }
        if has("PRODUCTIVITY_BREAK_TENOR_KEY")    { providers.append("tenor") }
        return providers
    }

    private func fetchJSON(_ url: URL, headers: [String: String] = [:], completion: @escaping (Any?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.setValue(HTTP_UA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            completion(data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
        }.resume()
    }

    private func fetchFromUserProvider(for message: String, completion: @escaping (URL?) -> Void) {
        guard let provider = userImageProviders().randomElement() else { completion(nil); return }
        let q = themeQuery(for: message)
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        FileHandle.standardError.write("[productivity_break] visual via \(provider): \(q)\n".data(using: .utf8)!)
        func fail() { DispatchQueue.main.async { completion(nil) } }
        switch provider {
        case "unsplash":
            let key = envString("PRODUCTIVITY_BREAK_UNSPLASH_KEY") ?? ""
            guard let url = URL(string: "https://api.unsplash.com/photos/random?orientation=portrait&content_filter=high&query=\(enc)&client_id=\(key)") else { fail(); return }
            fetchJSON(url) { json in
                guard let o = json as? [String: Any], let urls = o["urls"] as? [String: Any],
                      let raw = (urls["regular"] as? String) ?? (urls["full"] as? String),
                      let m = URL(string: raw) else { fail(); return }
                self.downloadToTemp(m, completion: completion)
            }
        case "pexels":
            let key = envString("PRODUCTIVITY_BREAK_PEXELS_KEY") ?? ""
            guard let url = URL(string: "https://api.pexels.com/v1/search?orientation=portrait&per_page=20&query=\(enc)") else { fail(); return }
            fetchJSON(url, headers: ["Authorization": key]) { json in
                guard let o = json as? [String: Any], let photos = o["photos"] as? [[String: Any]],
                      let src = photos.randomElement()?["src"] as? [String: Any],
                      let raw = (src["portrait"] as? String) ?? (src["large"] as? String),
                      let m = URL(string: raw) else { fail(); return }
                self.downloadToTemp(m, completion: completion)
            }
        case "giphy":
            let key = envString("PRODUCTIVITY_BREAK_GIPHY_KEY") ?? ""
            guard let url = URL(string: "https://api.giphy.com/v1/gifs/search?rating=g&limit=20&q=\(enc)&api_key=\(key)") else { fail(); return }
            fetchJSON(url) { json in
                guard let o = json as? [String: Any], let data = o["data"] as? [[String: Any]],
                      let images = data.randomElement()?["images"] as? [String: Any],
                      let orig = images["original"] as? [String: Any],
                      let raw = orig["url"] as? String, let m = URL(string: raw) else { fail(); return }
                self.downloadToTemp(m, completion: completion)
            }
        case "tenor":
            let key = envString("PRODUCTIVITY_BREAK_TENOR_KEY") ?? ""
            guard let url = URL(string: "https://tenor.googleapis.com/v2/search?contentfilter=high&media_filter=gif&limit=20&q=\(enc)&key=\(key)") else { fail(); return }
            fetchJSON(url) { json in
                guard let o = json as? [String: Any], let results = o["results"] as? [[String: Any]],
                      let mf = results.randomElement()?["media_formats"] as? [String: Any],
                      let gif = mf["gif"] as? [String: Any],
                      let raw = gif["url"] as? String, let m = URL(string: raw) else { fail(); return }
                self.downloadToTemp(m, completion: completion)
            }
        default:
            fail()
        }
    }

    // Map salient words in the message to a clean, image-search-friendly theme.
    private func themeQuery(for message: String) -> String {
        let m = message.lowercased()
        let map: [([String], String)] = [
            (["sea", "ocean", "wave", "tide", "sail", "ship", "boat"], "ocean waves"),
            (["beach", "shore", "sand", "coast"], "tropical beach"),
            (["mountain", "peak", "summit", "hill", "climb", "storm"], "mountain landscape"),
            (["forest", "tree", "woods", "leaf", "leaves", "jungle"], "forest path"),
            (["sky", "star", "cosmos", "universe", "space", "galaxy", "moon"], "starry night sky"),
            (["sun", "sunrise", "sunset", "dawn", "dusk"], "sunset sky"),
            (["rain", "cloud", "mist", "fog"], "misty landscape"),
            (["river", "lake", "stream", "pond"], "calm lake"),
            (["flower", "garden", "bloom", "spring"], "flower garden"),
            (["snow", "winter", "ice", "cold"], "snowy mountains"),
            (["calm", "peace", "rest", "relax", "breathe", "quiet", "still"], "zen garden"),
            (["walk", "path", "journey", "road", "travel"], "scenic path"),
            (["nature", "wild", "earth", "green", "grow"], "nature landscape"),
        ]
        for (words, q) in map where words.contains(where: { m.contains($0) }) { return q }
        let calming = ["mountain landscape", "ocean sunset", "forest path", "starry night sky",
                       "calm lake", "autumn forest", "misty mountains", "tropical beach",
                       "northern lights", "cherry blossom"]
        return calming.randomElement() ?? "mountain landscape"
    }

    private func downloadToTemp(_ url: URL, completion: @escaping (URL?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue(HTTP_UA, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data, data.count > 1024, NSImage(data: data) != nil else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            var ext = url.pathExtension.lowercased()
            if ext.isEmpty || ext.count > 4 { ext = "jpg" }
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("productivity_break_visual." + ext)
            do {
                try? FileManager.default.removeItem(at: tmp)
                try data.write(to: tmp)
                DispatchQueue.main.async { completion(tmp) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }.resume()
    }

    private func fetchSceneryImage(for message: String, completion: @escaping (URL?) -> Void) {
        let q = themeQuery(for: message)
        FileHandle.standardError.write("[productivity_break] visual theme: \(q)\n".data(using: .utf8)!)
        var comps = URLComponents(string: "https://api.openverse.org/v1/images/")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "page_size", value: "20"),
            URLQueryItem(name: "mature", value: "false"),
            URLQueryItem(name: "license_type", value: "all"),
        ]
        guard let url = comps.url else { completion(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.setValue(HTTP_UA, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let urls = results.compactMap { $0["url"] as? String }.filter { $0.hasPrefix("http") }
            guard let pick = urls.randomElement(), let imgURL = URL(string: pick) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            self.downloadToTemp(imgURL, completion: completion)
        }.resume()
    }

    private func fetchAnimeImage(completion: @escaping (URL?) -> Void) {
        let cats = ["neko", "kitsune"]   // nekos.best is SFW-only; keep the tamer categories
        let cat = cats.randomElement() ?? "neko"
        FileHandle.standardError.write("[productivity_break] visual theme: anime/\(cat)\n".data(using: .utf8)!)
        guard let url = URL(string: "https://nekos.best/api/v2/\(cat)") else { completion(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.setValue(HTTP_UA, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first, let pick = first["url"] as? String,
                  let imgURL = URL(string: pick) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            self.downloadToTemp(imgURL, completion: completion)
        }.resume()
    }

    private func fmt(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%g", x)
    }
}

// ---------------------------------------------------------------------------
// Parse config and report it, exiting non-zero on bad input. Headless (no GUI),
// so it is safe to run in CI and from scripts.
func validateConfig() -> Int32 {
    var ok = true
    let numeric = ["BREAK_MINUTES", "PRODUCTIVITY_BREAK_SHOW_SECONDS", "PRODUCTIVITY_BREAK_POLL_SECONDS",
                   "PRODUCTIVITY_BREAK_OVERLAY_ALPHA", "PRODUCTIVITY_BREAK_IDLE_SECONDS"]
    for k in numeric {
        if let v = ENV[k], Double(v) == nil {
            FileHandle.standardError.write("[productivity_break] invalid \(k)=\(v) — expected a number\n".data(using: .utf8)!)
            ok = false
        } else if ENV[k] == nil, let v = CFG[k], Double(v) == nil {
            FileHandle.standardError.write("[productivity_break] invalid \(k)=\(v) in config.json — expected a number\n".data(using: .utf8)!)
            ok = false
        }
    }
    print("productivity_break config:")
    print("  BREAK_MINUTES   = \(BREAK_MINUTES)  (threshold \(THRESHOLD)s)")
    print("  SHOW_SECONDS    = \(SHOW_SECONDS)")
    print("  POLL_SECONDS    = \(POLL_SECONDS)")
    print("  OVERLAY_ALPHA   = \(OVERLAY_ALPHA)")
    print("  IDLE_SECONDS    = \(IDLE_SECONDS)")
    print("  TERMINAL_APPS   = \(TERMINAL_APPS.joined(separator: ", "))")
    print("  QUOTES=\(envBool("PRODUCTIVITY_BREAK_QUOTES", true)) VISUALS=\(envBool("PRODUCTIVITY_BREAK_VISUALS", true)) ANIME=\(envBool("PRODUCTIVITY_BREAK_ANIME", false))")
    print("  QUOTES=\(envBool("PRODUCTIVITY_BREAK_QUOTES", true)) VISUALS=\(envBool("PRODUCTIVITY_BREAK_VISUALS", true)) ANIME=\(envBool("PRODUCTIVITY_BREAK_ANIME", false))")
    print("  STYLE           = \(BREAK_STYLE)")
    print(ok ? "OK" : "INVALID CONFIG")
    return ok ? 0 : 1
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    productivity_break \(APP_VERSION) — a productivity-break nudge for macOS.

    Watches how long your terminal has been the focused (frontmost) app. After
    BREAK_MINUTES of continuous focused use, a full-screen break overlay appears,
    holds for a few seconds, then fades away and the timer resets. Runs quietly
    with no Dock icon. Click / Esc / Space dismisses the break; S snoozes it.

    USAGE:
      productivity_break [flags]
      VAR=value ... productivity_break        (configure via environment, see below)

    FLAGS:
      --version           Print the version and exit.
      --validate-config   Parse config from the environment and config.json, print it,
                          and exit (exit 1 if a numeric var is non-numeric).
                          Headless — safe in CI / scripts.
      --test              Trigger a break immediately (overlay, or a notification
                          if STYLE=notify), then exit.
      --help, -h          Print this help and exit.

    ENVIRONMENT VARIABLES (default in brackets):
      BREAK_MINUTES                      [25]    Focused minutes before a break shows.
      PRODUCTIVITY_BREAK_SHOW_SECONDS    [8]     How long the overlay stays up.
      PRODUCTIVITY_BREAK_POLL_SECONDS    [5]     How often the focused app is checked.
      PRODUCTIVITY_BREAK_OVERLAY_ALPHA   [0.92]  Background dimming opacity (0.0–1.0).
      PRODUCTIVITY_BREAK_IDLE_SECONDS    [60]    Input-idle time that pauses the focus clock.
      PRODUCTIVITY_BREAK_SNOOZE_MINUTES  [5]     Re-arm delay after you press S to snooze.
      PRODUCTIVITY_BREAK_STYLE           [overlay] Break delivery: "overlay" or "notify" (osascript banner).
      PRODUCTIVITY_BREAK_TERMINAL_APPS   [Terminal,iTerm,Warp,Alacritty,kitty,Hyper,WezTerm,Ghostty]
                                                 Comma-separated app-name substrings counted as "terminal".
      PRODUCTIVITY_BREAK_DEFER_APPS      [zoom,Microsoft Teams,Webex,FaceTime,OBS Studio,QuickTime Player,ScreenFlow,Loom,Keynote]
                                                 Comma-separated apps during which a due break is postponed (not reset).
      PRODUCTIVITY_BREAK_MENUBAR         [off]   Show a menu-bar control (Take a break / Pause / Quit).
      PRODUCTIVITY_BREAK_QUOTES          [on]    Fetch a quote/fact/advice from a public API for each break.
      PRODUCTIVITY_BREAK_VISUALS         [on]    Fetch a themed scenery image for the overlay background.
      PRODUCTIVITY_BREAK_ANIME           [off]   Allow opt-in anime art (nekos.best, SFW) as a visual.
      PRODUCTIVITY_BREAK_MESSAGES        [unset] Your own break messages, separated by "|" (overrides QUOTES fetch).
      PRODUCTIVITY_BREAK_VIDEO           [unset] Path to a custom break visual (mp4/mov/image/GIF); always wins, skips VISUALS.
      PRODUCTIVITY_BREAK_UNSPLASH_KEY    [unset] Unsplash API key — fetch themed photos from your account.
      PRODUCTIVITY_BREAK_PEXELS_KEY      [unset] Pexels API key — fetch themed photos.
      PRODUCTIVITY_BREAK_GIPHY_KEY       [unset] Giphy API key — fetch themed GIFs.
      PRODUCTIVITY_BREAK_TENOR_KEY       [unset] Tenor API key — fetch themed GIFs.
                                                 (Any provider key set is preferred over the free image source.)

    Boolean vars accept on/off, true/false, yes/no, 1/0.
    Any variable above may also be set in ~/.config/productivity_break/config.json
    (JSON object, keys = variable names). Precedence: default < config.json < env.

    EXAMPLES:
      # Preview the break right now and exit:
      productivity_break --test

      # Run with a short 0.2-minute break for testing, and a custom message:
      BREAK_MINUTES=0.2 PRODUCTIVITY_BREAK_MESSAGES="Stretch!|Look away" productivity_break

      # Run quietly with the menu-bar control on and no network calls:
      PRODUCTIVITY_BREAK_MENUBAR=on PRODUCTIVITY_BREAK_QUOTES=off PRODUCTIVITY_BREAK_VISUALS=off productivity_break
    """)
    exit(0)
}



if CommandLine.arguments.contains("--version") {
    print("productivity_break \(APP_VERSION)")
    exit(0)
}

if CommandLine.arguments.contains("--validate-config") {
    exit(validateConfig())
}

let app = NSApplication.shared
let delegate = AppDelegate(testMode: CommandLine.arguments.contains("--test"))
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar takeover
app.run()
