# Contributing to productivity_break

Thanks for your interest! This is a small, dependency-free macOS app, so
contributing is quick to get into.

## Prerequisites

- macOS 12 or later
- A Swift toolchain — `swift --version` (ships with Xcode or the Command Line
  Tools: `xcode-select --install`)

## Build & run

```bash
git clone https://github.com/<you>/productivity_break.git
cd productivity_break

swift build -c release
.build/release/productivity_break --help        # usage
.build/release/productivity_break --test        # preview the break overlay now
.build/release/productivity_break --validate-config   # check resolved config
```

There are no third-party dependencies, and **no API keys are required** — the
break content comes from free public APIs with local fallbacks.

## Tests

Two complementary layers, both run in CI (`.github/workflows/build.yml`):

```bash
# 1) Unit tests for the pure logic (config parsing, lookups, theming).
#    Requires Xcode's XCTest — i.e. full Xcode, not just the Command Line Tools.
swift test

# 2) CLI integration tests — exercise the built binary's --validate-config /
#    --version / --help contract. Run with only the Command Line Tools (no Xcode).
Tests/cli-tests.sh                              # builds debug, then tests
BIN=.build/release/productivity_break Tests/cli-tests.sh   # test a prebuilt binary
```

The integration tests are hermetic: they point `CFFIXED_USER_HOME` at throwaway
temp dirs, so they never read or write your real `~/.config/productivity_break`.

## Project layout

```
Sources/ProductivityBreakCore/          # pure, unit-tested logic (no AppKit/IO/network)
Sources/productivity_break/main.swift   # the macOS app: GUI, focus monitoring, networking
Tests/ProductivityBreakCoreTests/       # XCTest unit tests for the core logic
Tests/cli-tests.sh                       # CLI integration tests against the built binary
Scripts/                                # install / uninstall / fetch-video
packaging/                              # launchd plist template
config.example.json                     # example config file
.github/workflows/build.yml             # CI (build + tests on macOS)
```

Logic that can be tested without AppKit (parsing, config resolution, string
helpers) belongs in `ProductivityBreakCore`; `main.swift` keeps the GUI, focus
monitoring, and network calls and delegates to the core.

The break video/image asset is **not** committed (it may be third-party art);
it's git-ignored. The built-in vector cat is the default. See the README's
"Optional: a break video" section.

## Making a change

1. **Fork** the repo and create a branch: `git checkout -b my-feature`.
2. Make your change. Pure logic goes in `Sources/ProductivityBreakCore/`; GUI,
   focus monitoring, and networking stay in `Sources/productivity_break/main.swift`.
3. Keep the code style consistent with the surrounding file (4-space indent,
   small focused functions, comments that explain *why*).
4. Build cleanly with **no new warnings**: `swift build -c release`.
5. If you add or rename a config knob, update **all** of: the `--help` text,
   the README config table, `config.example.json`, and `validateConfig()`.
6. Run the tests (`swift test` and `Tests/cli-tests.sh`) and add coverage for
   your change. Add a CLI assertion when you touch `--validate-config` output;
   add a unit test when you add core logic. Then manually verify with `--test`.
7. Commit with a clear message and open a **pull request** describing what and
   why. Link any related issue.

## Guidelines

- **No third-party dependencies.** Part of the appeal is a single self-contained
  binary — please keep it that way unless there's a strong reason.
- **Stay permission-free.** Focus detection uses `NSWorkspace` and idle uses
  `CGEventSource` precisely so the app needs no Accessibility permission. Avoid
  changes that would require one.
- **Respect privacy.** Network calls are opt-out (`*_QUOTES=off`, `*_VISUALS=off`)
  and content is pre-fetched off the break instant. Don't add tracking/telemetry.
- **Be kind to the user.** New break behaviors should be dismissible and not
  surprising (see the defer-during-calls and snooze logic).

## Reporting bugs / ideas

Open an issue using the templates. Include your macOS version and, for bugs, the
relevant `--validate-config` output and any `[productivity_break] ...` log lines.

By contributing you agree your work is licensed under the project's MIT license.
