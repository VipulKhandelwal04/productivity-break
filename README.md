# 🧘 productivity_break

A tiny macOS productivity nudge. When your terminal has been the focused app for
**25 continuous minutes**, a full-screen break gently takes over the screen for a
few seconds — with a fresh quote/fact and a calming visual — then fades away and
the timer resets. Your cue to stretch, blink, and look away.

Native **Swift + AppKit + AVFoundation**, a single self-contained binary with
**no third-party dependencies** and **no required permissions or API keys**. It
works fully offline (built-in vector art + local message pool), and optionally
pulls fresh, themed content from the web or from a media source of your choice.

![build](https://img.shields.io/badge/build-swift%20build-orange)
![platform](https://img.shields.io/badge/platform-macOS%2012%2B-blue)
![license](https://img.shields.io/badge/license-MIT-green)

## Features

- ⏱️ **Continuous-focus timer** — only counts time your terminal is frontmost;
  pauses (doesn't reset) when you switch away or go idle. No Accessibility
  permission needed (`NSWorkspace` + `CGEventSource`).
- 🖥️ **Full-screen break across every monitor** — dims all displays, slides a
  visual up on the main screen, holds, then fades. Click / `Esc` / `Space` to
  dismiss, `S` to **snooze**, with a live countdown. Accidental clicks during the
  entrance are ignored.
- 🎙️ **Defers around calls** — postpones (doesn't reset) a due break while a
  call/recording/presentation app is frontmost.
- 💬 **Fresh content every break** — a random quote / fun fact / advice + a
  **matching** themed image, with graceful offline fallbacks.
- 🖼️ **Bring your own visuals** — a local image/GIF/video, or your own
  **Unsplash / Pexels / Giphy / Tenor** account via an API key.
- 🔔 **Gentle notification mode** — a macOS notification instead of the takeover.
- ☕ **Optional menu-bar control** — status / take a break now / pause / quit.
- 🔧 **Configurable** — environment variables or a `config.json`, plus `--help`
  and `--validate-config`.
- 🔒 **Privacy-respecting** — content is pre-fetched off the break instant; all
  network access is optional and off-switchable.

## Requirements

- macOS 12 or later
- A Swift toolchain (`swift --version`) — ships with Xcode or the Command Line
  Tools (`xcode-select --install`).

## Quick start

```bash
git clone https://github.com/<you>/productivity_break.git
cd productivity_break

swift run productivity_break --test                 # preview a break right now
swift run productivity_break --help                 # all flags + env vars
BREAK_MINUTES=0.2 swift run productivity_break       # full flow after ~12 s of focus
```

### Command-line flags

| Flag | What it does |
|------|--------------|
| `--test` | Show a break immediately, then exit. |
| `--help`, `-h` | Print usage (all flags + env vars + examples) and exit. |
| `--validate-config` | Print the resolved configuration and exit non-zero on bad input. Headless / CI-safe. |
| `--version` | Print the version and exit. |

## Install as a background tool (auto-start at login)

```bash
./Scripts/install.sh      # build + register a launchd login agent
./Scripts/uninstall.sh    # stop + remove it
```

`install.sh` builds a release binary, copies it to
`~/Library/Application Support/productivity_break/`, and registers a `launchd`
agent (`com.productivity_break.agent`) that runs quietly in the background — no
Dock icon — starting immediately and at every login.

## How the focus timer works

- **Continuous focus** — the clock ticks only while a terminal app is the
  frontmost window. Switch away → it **pauses** (does not reset); switch back →
  it resumes.
- **Idle pause** — no keyboard/mouse input for `…_IDLE_SECONDS` (default 60s)
  also pauses the clock, so stepping away doesn't count.
- **Defer** — if the break comes due while a call/presentation app is frontmost,
  it's postponed (not reset) until you're back.
- During a break the overlay briefly takes keyboard focus (so the controls work)
  and restores your previous app afterward.

## Break visuals

By default the break draws a built-in **vector animal** — works offline, ships
in the binary. Beyond that, in order of precedence:

1. **A pinned local file** — set `PRODUCTIVITY_BREAK_VIDEO=/path/to/file`
   (mp4/mov/image/GIF), or drop a `productivity_break.<ext>` next to the binary,
   in `~/Library/Application Support/productivity_break/`, or in `./Resources/`.
   Any aspect ratio is auto-fit. Always wins; skips the fetch below.
2. **A fetched visual** — when `PRODUCTIVITY_BREAK_VISUALS` is on (default), each
   break is a **50/50 coin flip between an animated GIF and a static image**
   (each falls back to the other if its source is unavailable):
   - **Static image** — a themed photo from your Unsplash/Pexels key if set,
     else free themed scenery from [Openverse](https://openverse.org) (no key);
     opt-in anime art via `PRODUCTIVITY_BREAK_ANIME=on`.
   - **Animated GIF** — themed to the break message. Uses your Giphy/Tenor key
     if set (reliable). Otherwise **keyless**: an any-topic themed GIF via
     [Tenor](https://tenor.com)'s public *demo* endpoint, falling back to cat
     GIFs ([The Cat API](https://thecatapi.com)) and 70+ anime reaction GIFs
     ([otakugifs.xyz](https://otakugifs.xyz)) if that shared demo key is
     throttled. The demo key is best-effort — for reliability, set your own free
     `PRODUCTIVITY_BREAK_TENOR_KEY` (below).
3. **The vector animal** — the always-available offline fallback.

### Bring your own images / GIFs (API key)

Drop in a free API key and break visuals come from that provider, still **themed
to the message** and with safe content ratings:

| Provider | Key env var | Get a free key |
|----------|-------------|----------------|
| Unsplash (photos) | `PRODUCTIVITY_BREAK_UNSPLASH_KEY` | https://unsplash.com/developers |
| Pexels (photos)   | `PRODUCTIVITY_BREAK_PEXELS_KEY`   | https://www.pexels.com/api/ |
| Giphy (GIFs)      | `PRODUCTIVITY_BREAK_GIPHY_KEY`    | https://developers.giphy.com/ |
| Tenor (GIFs)      | `PRODUCTIVITY_BREAK_TENOR_KEY`    | https://tenor.com/gifapi |

```bash
PRODUCTIVITY_BREAK_UNSPLASH_KEY=your_key swift run productivity_break --test
```

If several keys are set, one provider is chosen at random per break. On any
failure it falls back to Openverse → your local file → the vector animal.

### A sample "floating cat" clip

```bash
./Scripts/fetch-video.sh     # downloads productivity_break.mp4 for personal use
```

> ⚠️ The sample clip ([source pin](https://in.pinterest.com/pin/2251868559305065/))
> is third-party artwork, **not** included in this repo (it's git-ignored).
> `fetch-video.sh` downloads it locally for personal use — make sure you have the
> right to use any media you add.

## Break messages

Each break shows a random **quote / fun fact / advice** fetched from free public
APIs (ZenQuotes, dummyjson, uselessfacts, adviceslip). Turn it off with
`PRODUCTIVITY_BREAK_QUOTES=off` (uses a built-in local pool), or supply your own
with `PRODUCTIVITY_BREAK_MESSAGES="Stretch!|Hydrate|Look away"`.

> Messages and visuals are **pre-fetched on a jittered ~10-minute timer** and
> cached, so a break is instant and the network activity isn't tied to your
> break cadence. No personal data is sent. Set `…_QUOTES=off` and `…_VISUALS=off`
> for a fully offline tool.

## Configuration

Configuration is layered, in increasing precedence:

1. Built-in defaults
2. `~/.config/productivity_break/config.json` — a JSON object whose keys are the
   env-var names below (values may be strings, numbers, bools, or arrays). See
   [`config.example.json`](config.example.json). Missing/invalid files are
   ignored with a warning.
3. Environment variables — always win.

Run `--validate-config` to see the resolved values. When installed as a login
agent, you can also edit the `EnvironmentVariables` block of
`~/Library/LaunchAgents/com.productivity_break.agent.plist` and re-run
`install.sh`.

**Timing**

| Variable | Default | Meaning |
|----------|---------|---------|
| `BREAK_MINUTES` | `25` | Focused minutes before a break appears |
| `PRODUCTIVITY_BREAK_SHOW_SECONDS` | `8` | How long the break stays on screen |
| `PRODUCTIVITY_BREAK_POLL_SECONDS` | `5` | How often focus is checked |
| `PRODUCTIVITY_BREAK_IDLE_SECONDS` | `60` | Input-idle seconds that pause the clock |
| `PRODUCTIVITY_BREAK_SNOOZE_MINUTES` | `5` | Re-arm delay when you press `S` |

**Appearance & behavior**

| Variable | Default | Meaning |
|----------|---------|---------|
| `PRODUCTIVITY_BREAK_STYLE` | `overlay` | `overlay` (full-screen) or `notify` (a notification) |
| `PRODUCTIVITY_BREAK_OVERLAY_ALPHA` | `0.92` | Background dimming (0 = clear, 1 = opaque) |
| `PRODUCTIVITY_BREAK_MENUBAR` | `off` | `on` shows a ☕ menu-bar control |
| `PRODUCTIVITY_BREAK_DEFER_APPS` | _(call apps)_ | Comma-separated apps during which a due break waits |
| `PRODUCTIVITY_BREAK_TERMINAL_APPS` | _(common terminals)_ | Comma-separated app-name substrings counted as "terminal" |

**Break content**

| Variable | Default | Meaning |
|----------|---------|---------|
| `PRODUCTIVITY_BREAK_QUOTES` | `on` | `off` → local messages only (no network) |
| `PRODUCTIVITY_BREAK_MESSAGES` | _(unset)_ | Your own messages, separated by `\|` (overrides the fetch) |
| `PRODUCTIVITY_BREAK_VISUALS` | `on` | Fetch a visual per break — 50/50 animated GIF vs static image. `off` → skip the fetch (use the local/vector visual) |
| `PRODUCTIVITY_BREAK_ANIME` | `off` | `on` → occasionally use anime art (nekos.best, SFW) |
| `PRODUCTIVITY_BREAK_VIDEO` | _(auto)_ | Path to a pinned local visual (mp4/mov/image/GIF) |
| `PRODUCTIVITY_BREAK_UNSPLASH_KEY` | _(unset)_ | Unsplash API key — themed photos |
| `PRODUCTIVITY_BREAK_PEXELS_KEY` | _(unset)_ | Pexels API key — themed photos |
| `PRODUCTIVITY_BREAK_GIPHY_KEY` | _(unset)_ | Giphy API key — themed GIFs |
| `PRODUCTIVITY_BREAK_TENOR_KEY` | _(unset)_ | Tenor API key — themed GIFs |

Booleans accept `on/off`, `true/false`, `yes/no`, `1/0`.

## Project layout

```
productivity_break/
├── Package.swift                              # Swift Package Manager manifest
├── Sources/
│   ├── ProductivityBreakCore/                 # pure, unit-tested logic (no AppKit/IO)
│   └── productivity_break/main.swift          # the macOS app (GUI, focus, networking)
├── Tests/
│   ├── ProductivityBreakCoreTests/            # XCTest unit tests (`swift test`)
│   └── cli-tests.sh                           # CLI integration tests (no Xcode needed)
├── Scripts/
│   ├── install.sh / uninstall.sh              # set up / tear down the login agent
│   └── fetch-video.sh                         # download the optional sample clip
├── packaging/com.productivity_break.agent.plist  # launchd template
├── config.example.json                        # example config file
├── Resources/productivity_break.*             # optional media (git-ignored)
├── .github/
│   ├── workflows/build.yml                    # CI: builds on macOS
│   ├── ISSUE_TEMPLATE/                         # bug report / feature request
│   └── PULL_REQUEST_TEMPLATE.md
├── CONTRIBUTING.md · CODE_OF_CONDUCT.md · LICENSE
└── README.md
```

## Building manually

```bash
swift build -c release          # -> .build/release/productivity_break
```

## Tests

```bash
swift test            # unit tests for the core logic (needs Xcode's XCTest)
Tests/cli-tests.sh    # CLI integration tests (Command Line Tools only)
```

## Contributing

Contributions welcome! Fork the repo, make your change in
`Sources/productivity_break/main.swift`, and open a pull request. See
[CONTRIBUTING.md](CONTRIBUTING.md) for build/run steps and project goals, and
please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

Good first issues: more break-message sources, additional default terminal apps,
accessibility (Reduce Motion), or a Settings UI.

## License

MIT — see [LICENSE](LICENSE). The license covers the **source code**; any
optional break media is third-party and is not distributed with this repo.
