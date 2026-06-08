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
func envDouble(_ key: String, _ def: Double) -> Double {
    if let v = ENV[key], let x = Double(v) { return x }
    return def
}

// Parse a boolean-ish env var consistently (on/off/true/false/yes/no/1/0).
func envBool(_ key: String, _ def: Bool) -> Bool {
    guard let v = ENV[key]?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return def }
    if ["1", "on", "true", "yes", "y"].contains(v) { return true }
    if ["0", "off", "false", "no", "n"].contains(v) { return false }
    return def
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

let TERMINAL_APPS: [String] = (ENV["PRODUCTIVITY_BREAK_TERMINAL_APPS"]
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
    if let p = ENV["PRODUCTIVITY_BREAK_VIDEO"] { paths.append(p) }
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
    weak var controller: OverlayController?

    override var isFlipped: Bool { false }   // origin bottom-left, y grows upward

    override func mouseDown(with event: NSEvent) {
        controller?.dismiss()         // click anywhere to dismiss early
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSColor(calibratedWhite: 0.04, alpha: OVERLAY_ALPHA).setFill()
        b.fill()

        drawMessage(in: b)

        if useVectorArt {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: 0, yBy: -slideOffset + bob)
            t.concat()
            drawProductivityBreak(in: b)
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
        let y = b.height * 0.9 - measured.height / 2
        msg.draw(with: NSRect(x: (b.width - boxW) / 2, y: y, width: boxW, height: measured.height),
                 options: [.usesLineFragmentOrigin], attributes: attrs(fontSize))
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
        let cx = b.width / 2.0
        let feetY = b.height * 0.05
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
    private let startOffset: CGFloat
    private let restY: CGFloat
    private let bobAmp: CGFloat
    var onDone: (() -> Void)?

    private let slideDur = 0.6
    private let fadeInDur = 0.4
    private let fadeOutDur = 0.5

    init(message: String, mediaURL: URL? = nil) {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)   // safe fallback; showBreak() guards real use
        window = NSWindow(contentRect: frame, styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.alphaValue = 0

        view = DimView(frame: NSRect(origin: .zero, size: frame.size))
        view.message = message

        // Try a break visual (video, image, or GIF), fitted into the lower ~84%
        // of the screen (leaving a band at the top for the break banner). Fall
        // back to the vector art if no media is available.
        var rest: CGFloat = 0
        var startOff = frame.height * 1.12
        if let url = (mediaURL ?? resolveMediaURL()), mediaIsUsable(url) {
            // Detect the media's actual size so ANY aspect ratio (portrait,
            // landscape, square) fits nicely.
            let size = mediaNaturalSize(url)
            let vw = size.width, vh = size.height
            let regionH = frame.height * 0.84
            let availW = frame.width * 0.92
            let scale = min(availW / vw, regionH / vh)
            let w = vw * scale, h = vh * scale
            let x = (frame.width - w) / 2
            rest = (regionH - h) / 2
            startOff = rest + h

            let container = NSView(frame: NSRect(x: x, y: rest, width: w, height: h))
            container.wantsLayer = true
            container.layer?.cornerRadius = max(10, w * 0.04)
            container.layer?.masksToBounds = true

            if isImageURL(url) {
                let iv = NSImageView(frame: container.bounds)
                iv.image = NSImage(contentsOf: url)
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
        bobAmp = frame.height * 0.004

        window.contentView = view
        view.controller = self
    }

    func show() {
        window.orderFrontRegardless()
        player?.play()
        phase = .fadingIn
        phaseStart = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func dismiss() {
        if phase != .fadingOut {
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
                onDone?()
                return
            }
        }
    }
}

// ---------------------------------------------------------------------------
// App delegate: focus monitoring
// ---------------------------------------------------------------------------
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var focused = 0.0
    private var lastTick = Date()
    private var overlay: OverlayController?
    private var monitor: Timer?
    private var presenting = false
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
        lastTick = Date()
        let t = Timer(timeInterval: POLL_SECONDS, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        monitor = t
    }

    func applicationWillTerminate(_ note: Notification) {
        cleanupTempVisuals()
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
        if overlay != nil || presenting { return }   // break is up or being prepared
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

    private func showBreak() {
        guard (NSScreen.main ?? NSScreen.screens.first) != nil else {
            FileHandle.standardError.write("[productivity_break] no display available — skipping break.\n".data(using: .utf8)!)
            focused = 0
            lastTick = Date()
            if testMode { NSApp.terminate(nil) }
            return
        }
        presenting = true
        fetchBreakMessage { [weak self] msg in
            guard let self = self else { return }
            FileHandle.standardError.write("[productivity_break] break message: \(msg)\n".data(using: .utf8)!)
            self.fetchBreakImage(for: msg) { [weak self] mediaURL in
                guard let self = self else { return }
                let oc = OverlayController(message: msg, mediaURL: mediaURL)
                oc.onDone = { [weak self] in
                    guard let self = self else { return }
                    self.overlay = nil
                    self.presenting = false
                    self.focused = 0
                    self.lastTick = Date()
                    cleanupTempVisuals()
                    if self.testMode { NSApp.terminate(nil) }
                }
                self.overlay = oc
                oc.show()
            }
        }
    }

    // Fetch a fresh quote / fun fact / piece of advice from a free public API,
    // chosen at random, so the break message changes every time. The call is
    // async with a short timeout and falls back to a local break message.
    //   - Disable all network with PRODUCTIVITY_BREAK_QUOTES=off
    //   - Use your own pool with PRODUCTIVITY_BREAK_MESSAGES (separated by "|")
    private func fetchBreakMessage(completion: @escaping (String) -> Void) {
        if let custom = ENV["PRODUCTIVITY_BREAK_MESSAGES"] {
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
        req.setValue("productivity_break/1.0", forHTTPHeaderField: "User-Agent")
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
            || ENV["PRODUCTIVITY_BREAK_VIDEO"] != nil {
            completion(nil); return
        }
        // Themed scenery by default (high quality, work-appropriate). Anime
        // character art (via nekos.best) is opt-in, since it can be stylized or
        // suggestive — enable it with PRODUCTIVITY_BREAK_ANIME=on.
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
        req.setValue("productivity_break/1.0", forHTTPHeaderField: "User-Agent")
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
        req.setValue("productivity_break/1.0", forHTTPHeaderField: "User-Agent")
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
        let cats = ["neko", "waifu", "husbando", "kitsune"]
        let cat = cats.randomElement() ?? "neko"
        FileHandle.standardError.write("[productivity_break] visual theme: anime/\(cat)\n".data(using: .utf8)!)
        guard let url = URL(string: "https://nekos.best/api/v2/\(cat)") else { completion(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.setValue("productivity_break/1.0", forHTTPHeaderField: "User-Agent")
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
    print(ok ? "OK" : "INVALID CONFIG")
    return ok ? 0 : 1
}

if CommandLine.arguments.contains("--validate-config") {
    exit(validateConfig())
}

let app = NSApplication.shared
let delegate = AppDelegate(testMode: CommandLine.arguments.contains("--test"))
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar takeover
app.run()
