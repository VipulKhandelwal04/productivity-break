// ProductivityBreakCore — the pure, side-effect-free logic behind
// productivity_break, split out from the GUI executable so it can be unit
// tested without launching the app's run loop.
//
// Nothing in here touches the process environment, the filesystem, the network,
// or AppKit. Callers (the executable) supply the environment and config as
// plain dictionaries and the file's bytes as `Data`, keeping every function
// deterministic and testable.

import Foundation

public enum Core {

    // ------------------------------------------------------------------
    // Config file parsing
    // ------------------------------------------------------------------
    public enum ConfigError: Error, Equatable {
        case invalidJSON(String)   // not parseable as JSON
        case notAnObject           // valid JSON, but not a top-level object
    }

    /// Parse the bytes of a config.json into a `[String: String]`, applying the
    /// normalization rules the executable relies on:
    ///   - JSON booleans -> "true"/"false" (NOT "1"/"0")
    ///   - JSON numbers   -> their string value
    ///   - JSON arrays    -> comma-joined (so list-style keys work with the
    ///                       executable's `.split(separator: ",")` call sites)
    ///   - null / nested objects -> ignored
    /// Throws `ConfigError` so the caller can emit the right diagnostic.
    public static func parseConfigJSON(_ data: Data) throws -> [String: String] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ConfigError.invalidJSON(error.localizedDescription)
        }
        guard let dict = parsed as? [String: Any] else {
            throw ConfigError.notAnObject
        }
        var out: [String: String] = [:]
        for (k, v) in dict {
            // JSONSerialization bridges both bool and number to NSNumber, so a
            // bare `true` would otherwise stringify to "1". Disambiguate.
            if let n = v as? NSNumber, CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
                out[k] = n.boolValue ? "true" : "false"
            } else if let s = v as? String {
                out[k] = s
            } else if let n = v as? NSNumber {
                out[k] = n.stringValue
            } else if let arr = v as? [Any] {
                out[k] = arr.map { "\($0)" }.joined(separator: ",")
            }
            // anything else (null / nested object) is ignored
        }
        return out
    }

    // ------------------------------------------------------------------
    // Layered lookups: env wins, then config.json, then the default.
    // ------------------------------------------------------------------

    /// Raw string lookup: env wins, else config, else nil.
    public static func string(_ key: String,
                              env: [String: String],
                              cfg: [String: String]) -> String? {
        env[key] ?? cfg[key]
    }

    /// Numeric lookup with a default. A present-but-unparseable value falls
    /// through to the next layer (env -> cfg -> default).
    public static func double(_ key: String, _ def: Double,
                              env: [String: String],
                              cfg: [String: String]) -> Double {
        if let v = env[key], let x = Double(v) { return x }
        if let v = cfg[key], let x = Double(v) { return x }
        return def
    }

    /// Parse a boolean-ish value (on/off/true/false/yes/no/1/0/y/n),
    /// case- and whitespace-insensitive. Unrecognized / empty -> default.
    public static func parseBool(_ raw: String?, _ def: Bool) -> Bool {
        guard let v = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return def }
        if ["1", "on", "true", "yes", "y"].contains(v) { return true }
        if ["0", "off", "false", "no", "n"].contains(v) { return false }
        return def
    }

    /// Boolean lookup with a default: env wins, else config, else default.
    public static func bool(_ key: String, _ def: Bool,
                            env: [String: String],
                            cfg: [String: String]) -> Bool {
        parseBool(env[key] ?? cfg[key], def)
    }

    // ------------------------------------------------------------------
    // Image/GIF provider keys, classified by the media they return.
    // A provider is "available" when its API key is present and non-empty.
    // ------------------------------------------------------------------
    private static func hasKey(_ key: String, env: [String: String], cfg: [String: String]) -> Bool {
        !(string(key, env: env, cfg: cfg) ?? "").isEmpty
    }

    /// Providers that return STATIC photos (Unsplash, Pexels), in order.
    public static func staticImageProviders(env: [String: String], cfg: [String: String]) -> [String] {
        var p: [String] = []
        if hasKey("PRODUCTIVITY_BREAK_UNSPLASH_KEY", env: env, cfg: cfg) { p.append("unsplash") }
        if hasKey("PRODUCTIVITY_BREAK_PEXELS_KEY", env: env, cfg: cfg)   { p.append("pexels") }
        return p
    }

    /// Providers that return animated GIFs (Giphy, Tenor), in order.
    public static func gifProviders(env: [String: String], cfg: [String: String]) -> [String] {
        var p: [String] = []
        if hasKey("PRODUCTIVITY_BREAK_GIPHY_KEY", env: env, cfg: cfg) { p.append("giphy") }
        if hasKey("PRODUCTIVITY_BREAK_TENOR_KEY", env: env, cfg: cfg) { p.append("tenor") }
        return p
    }

    // ------------------------------------------------------------------
    // Media + formatting helpers
    // ------------------------------------------------------------------

    public static let imageExtensions = ["gif", "png", "jpg", "jpeg", "heic", "bmp", "tiff", "webp"]
    /// Search/preference order: videos first, then images.
    public static let mediaExtensions = ["mp4", "mov", "m4v"] + imageExtensions

    public static func isImageURL(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Format a Double without a trailing ".0" when it is whole.
    public static func fmt(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%g", x)
    }

    // ------------------------------------------------------------------
    // Theme selection for break visuals
    // ------------------------------------------------------------------

    /// Map salient words in a break message to a clean, image-search-friendly
    /// theme. Returns one of the `calming` themes if nothing matches.
    public static func themeQuery(for message: String) -> String {
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
        return calmingThemes.randomElement() ?? "mountain landscape"
    }

    /// The fallback pool used when a message matches no specific theme.
    public static let calmingThemes = [
        "mountain landscape", "ocean sunset", "forest path", "starry night sky",
        "calm lake", "autumn forest", "misty mountains", "tropical beach",
        "northern lights", "cherry blossom",
    ]

    /// Reaction categories supported by otakugifs.xyz (the free, keyless anime
    /// GIF source). One is picked at random per break for variety.
    public static let otakuReactions = [
        "airkiss", "angrystare", "bite", "bleh", "blush", "brofist", "celebrate",
        "cheers", "clap", "confused", "cool", "cry", "cuddle", "dance", "drool",
        "evillaugh", "facepalm", "handhold", "happy", "headbang", "hug", "huh",
        "kiss", "laugh", "lick", "love", "mad", "nervous", "nom", "nosebleed",
        "nuzzle", "nyah", "pat", "peek", "pinch", "poke", "pout", "punch", "roll",
        "run", "sad", "scared", "shout", "shrug", "shy", "sigh", "sing", "sip",
        "slap", "sleep", "slowclap", "smack", "smile", "smug", "sneeze", "sorry",
        "stare", "stop", "surprised", "sweat", "thumbsup", "tickle", "tired",
        "wave", "wink", "woah", "yawn", "yay", "yes",
    ]
}
