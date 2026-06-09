import XCTest
import Foundation
@testable import ProductivityBreakCore

// Unit tests for the pure config/format/theme logic in ProductivityBreakCore.
// These run via `swift test` (requires Xcode's XCTest on macOS). The CLI
// integration tests in Tests/cli-tests.sh cover the same logic end-to-end
// through the built binary and run with just CommandLineTools.
final class ConfigTests: XCTestCase {

    // MARK: parseConfigJSON

    func testParsesStringsNumbersBoolsArrays() throws {
        let json = """
        {
          "BREAK_MINUTES": 7,
          "PRODUCTIVITY_BREAK_OVERLAY_ALPHA": 0.5,
          "PRODUCTIVITY_BREAK_QUOTES": true,
          "PRODUCTIVITY_BREAK_ANIME": false,
          "PRODUCTIVITY_BREAK_STYLE": "notify",
          "PRODUCTIVITY_BREAK_TERMINAL_APPS": ["Terminal", "Ghostty", "Warp"]
        }
        """.data(using: .utf8)!
        let cfg = try Core.parseConfigJSON(json)
        XCTAssertEqual(cfg["BREAK_MINUTES"], "7")
        XCTAssertEqual(cfg["PRODUCTIVITY_BREAK_OVERLAY_ALPHA"], "0.5")
        XCTAssertEqual(cfg["PRODUCTIVITY_BREAK_STYLE"], "notify")
        // Comma-joined array (the executable later .split(separator: ",")s it).
        XCTAssertEqual(cfg["PRODUCTIVITY_BREAK_TERMINAL_APPS"], "Terminal,Ghostty,Warp")
    }

    func testBoolsStringifyAsWordsNotOneZero() throws {
        // The crux of the NSNumber disambiguation: `true` must NOT become "1".
        let cfg = try Core.parseConfigJSON(#"{"a": true, "b": false}"#.data(using: .utf8)!)
        XCTAssertEqual(cfg["a"], "true")
        XCTAssertEqual(cfg["b"], "false")
    }

    func testNullAndNestedObjectsAreIgnored() throws {
        let cfg = try Core.parseConfigJSON(#"{"keep": "x", "n": null, "obj": {"k": 1}}"#.data(using: .utf8)!)
        XCTAssertEqual(cfg["keep"], "x")
        XCTAssertNil(cfg["n"])
        XCTAssertNil(cfg["obj"])
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try Core.parseConfigJSON("{ not json".data(using: .utf8)!)) { err in
            guard case Core.ConfigError.invalidJSON = err else {
                return XCTFail("expected .invalidJSON, got \(err)")
            }
        }
    }

    func testNonObjectTopLevelThrows() {
        XCTAssertThrowsError(try Core.parseConfigJSON("[1, 2, 3]".data(using: .utf8)!)) { err in
            XCTAssertEqual(err as? Core.ConfigError, .notAnObject)
        }
    }

    // MARK: layered lookups (env > cfg > default)

    func testDoublePrecedence() {
        let env = ["K": "13"], cfg = ["K": "7"]
        XCTAssertEqual(Core.double("K", 25, env: env, cfg: cfg), 13)        // env wins
        XCTAssertEqual(Core.double("K", 25, env: [:], cfg: cfg), 7)         // cfg next
        XCTAssertEqual(Core.double("K", 25, env: [:], cfg: [:]), 25)        // default
    }

    func testDoubleSkipsUnparseableLayer() {
        // A present-but-garbage env value falls through to cfg, then default.
        XCTAssertEqual(Core.double("K", 25, env: ["K": "xyz"], cfg: ["K": "7"]), 7)
        XCTAssertEqual(Core.double("K", 25, env: ["K": "xyz"], cfg: [:]), 25)
    }

    func testStringPrecedence() {
        XCTAssertEqual(Core.string("K", env: ["K": "e"], cfg: ["K": "c"]), "e")
        XCTAssertEqual(Core.string("K", env: [:], cfg: ["K": "c"]), "c")
        XCTAssertNil(Core.string("K", env: [:], cfg: [:]))
    }

    // MARK: boolean parsing

    func testParseBoolTrueForms() {
        for v in ["1", "on", "true", "yes", "y", "ON", "True", " yes "] {
            XCTAssertTrue(Core.parseBool(v, false), "‘\(v)’ should be true")
        }
    }

    func testParseBoolFalseForms() {
        for v in ["0", "off", "false", "no", "n", "OFF", "False", " no "] {
            XCTAssertFalse(Core.parseBool(v, true), "‘\(v)’ should be false")
        }
    }

    func testParseBoolFallsBackToDefault() {
        XCTAssertTrue(Core.parseBool("bogus", true))
        XCTAssertFalse(Core.parseBool("bogus", false))
        XCTAssertTrue(Core.parseBool(nil, true))
        XCTAssertFalse(Core.parseBool("", false))
        XCTAssertTrue(Core.parseBool("   ", true))   // whitespace-only -> default
    }

    func testBoolLookupPrecedence() {
        XCTAssertFalse(Core.bool("Q", true, env: ["Q": "off"], cfg: [:]))      // env overrides default
        XCTAssertFalse(Core.bool("Q", true, env: [:], cfg: ["Q": "false"]))    // cfg overrides default
        XCTAssertTrue(Core.bool("Q", false, env: ["Q": "on"], cfg: ["Q": "off"])) // env beats cfg
    }

    // MARK: provider classification

    func testProvidersEmptyByDefault() {
        XCTAssertEqual(Core.staticImageProviders(env: [:], cfg: [:]), [])
        XCTAssertEqual(Core.gifProviders(env: [:], cfg: [:]), [])
    }

    func testStaticProvidersFromKeys() {
        let env = ["PRODUCTIVITY_BREAK_UNSPLASH_KEY": "u", "PRODUCTIVITY_BREAK_PEXELS_KEY": "p"]
        XCTAssertEqual(Core.staticImageProviders(env: env, cfg: [:]), ["unsplash", "pexels"])
        XCTAssertEqual(Core.gifProviders(env: env, cfg: [:]), [])   // photo keys are not GIF providers
    }

    func testGifProvidersFromKeys() {
        let env = ["PRODUCTIVITY_BREAK_GIPHY_KEY": "g", "PRODUCTIVITY_BREAK_TENOR_KEY": "t"]
        XCTAssertEqual(Core.gifProviders(env: env, cfg: [:]), ["giphy", "tenor"])
        XCTAssertEqual(Core.staticImageProviders(env: env, cfg: [:]), [])
    }

    func testEmptyKeyValueIsNotAProvider() {
        // A present-but-empty key must not count as available.
        XCTAssertEqual(Core.gifProviders(env: ["PRODUCTIVITY_BREAK_GIPHY_KEY": ""], cfg: [:]), [])
    }

    func testProviderKeyFromConfigCounts() {
        // Keys may live in config.json, not just the environment.
        XCTAssertEqual(Core.staticImageProviders(env: [:], cfg: ["PRODUCTIVITY_BREAK_UNSPLASH_KEY": "u"]), ["unsplash"])
    }

    // MARK: media helpers

    func testIsImageURL() {
        for ext in ["gif", "png", "JPG", "jpeg", "Heic", "webp"] {
            XCTAssertTrue(Core.isImageURL(URL(fileURLWithPath: "/x/y.\(ext)")), ".\(ext) is an image")
        }
        for ext in ["mp4", "mov", "m4v", "txt", ""] {
            XCTAssertFalse(Core.isImageURL(URL(fileURLWithPath: "/x/y.\(ext)")), ".\(ext) is not an image")
        }
    }

    func testMediaExtensionsPreferVideoFirst() {
        XCTAssertEqual(Array(Core.mediaExtensions.prefix(3)), ["mp4", "mov", "m4v"])
        XCTAssertTrue(Core.mediaExtensions.contains("png"))
    }

    // MARK: fmt

    func testFmtDropsTrailingZeroForWholeNumbers() {
        XCTAssertEqual(Core.fmt(25), "25")
        XCTAssertEqual(Core.fmt(0), "0")
        XCTAssertEqual(Core.fmt(0.2), "0.2")
        XCTAssertEqual(Core.fmt(1.5), "1.5")
    }

    // MARK: themeQuery

    func testThemeQueryMapsKeywords() {
        XCTAssertEqual(Core.themeQuery(for: "go find a spot by the OCEAN waves"), "ocean waves")
        XCTAssertEqual(Core.themeQuery(for: "climb a mountain"), "mountain landscape")
        XCTAssertEqual(Core.themeQuery(for: "breathe and relax"), "zen garden")
        XCTAssertEqual(Core.themeQuery(for: "look at the stars"), "starry night sky")
    }

    func testThemeQueryFirstMatchWins() {
        // "mountain" precedes "forest" in the map ordering.
        XCTAssertEqual(Core.themeQuery(for: "a mountain in the forest"), "mountain landscape")
    }

    func testThemeQueryFallsBackToACalmingTheme() {
        // No keyword -> one of the curated calming themes (not empty / arbitrary).
        let q = Core.themeQuery(for: "xyzzy plugh frobnicate")
        XCTAssertTrue(Core.calmingThemes.contains(q), "‘\(q)’ should be a calming fallback theme")
    }

    // MARK: keyless GIF reaction pool

    func testOtakuReactionsAreVariedAndURLSafe() {
        XCTAssertGreaterThan(Core.otakuReactions.count, 30, "expected a broad reaction pool for variety")
        XCTAssertEqual(Set(Core.otakuReactions).count, Core.otakuReactions.count, "no duplicate reactions")
        // Each is a bare lowercase token (safe to drop straight into a query).
        for r in Core.otakuReactions {
            XCTAssertTrue(r.allSatisfy { $0.isLowercase || $0.isNumber }, "‘\(r)’ should be URL-safe")
            XCTAssertFalse(r.isEmpty)
        }
    }
}
