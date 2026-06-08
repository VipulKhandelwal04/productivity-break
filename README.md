# 🧘 productivity_break

A tiny macOS productivity nudge. When your **terminal has been the focused app
for 25 continuous minutes**, a full-screen break overlay fills the screen —
sliding up through a dimmed backdrop, hanging out for a few seconds, then fading
away — your cue to stretch, blink, and drink some water. The timer then resets.

Native **Swift + AppKit + AVFoundation**. No third-party dependencies. The
default art is drawn in code (a vector animal), so it works offline out of the
box. You can optionally swap in a looping **video** (see below).

![build](https://img.shields.io/badge/build-swift%20build-orange)
![platform](https://img.shields.io/badge/platform-macOS%2012%2B-blue)
![license](https://img.shields.io/badge/license-MIT-green)

## How the timer works

- **Continuous focus** — the clock only ticks while a terminal app is the
  active/frontmost window. Switch to another app and it **pauses** (it does not
  reset); switch back and it resumes counting.
- **Idle pause** — if you stop typing/moving the mouse for `PRODUCTIVITY_BREAK_IDLE_SECONDS` (default 60s), the clock pauses too, so stepping away from a focused terminal doesn't count (no Accessibility permission needed).
- After 25 min the break appears, auto-fades after ~8 s, and the timer resets.
- **Covers every monitor** — all displays dim; the visual + message appear on the main screen.
- **Defers around calls** — a due break is postponed (not reset) while a call/recording/presentation app is frontmost (`PRODUCTIVITY_BREAK_DEFER_APPS`).
- **Controls** — click / `Esc` / `Space` to dismiss, or `S` to **snooze** (re-arm in `PRODUCTIVITY_BREAK_SNOOZE_MINUTES` without losing the whole cycle). A countdown shows how long is left. Accidental clicks during the slide-in are ignored.
- Uses `NSWorkspace` for focus detection — **no Accessibility permission needed**. (The overlay briefly takes keyboard focus during the break so the controls work, then restores your previous app.)
- **Optional menu-bar control** — set `PRODUCTIVITY_BREAK_MENUBAR=on` for a ☕ status item (status / take a break now / pause / quit). Off by default.

## Requirements

- macOS 12 or later
- A Swift toolchain (`swift --version`) — ships with Xcode or the Command Line
  Tools (`xcode-select --install`).

## Quick start

```bash
git clone https://github.com/<you>/productivity_break.git
cd productivity_break

swift run productivity_break --test        # see the overlay right now
BREAK_MINUTES=0.2 swift run productivity_break   # try the full flow (after ~12 s of terminal focus)
```

## Install as a background tool (auto-start at login)

```bash
./Scripts/install.sh
```

This builds a release binary, copies it to
`~/Library/Application Support/productivity_break/`, and registers a `launchd`
login agent (`com.productivity_break.agent`) that runs quietly in the
background — no Dock icon, no menu-bar item. It starts immediately and again at
every login.

Remove it any time:

```bash
./Scripts/uninstall.sh
```

## Optional: a break video

By default productivity_break draws its own vector animal. To play a looping
video instead, drop one in and it'll be picked up automatically.

### Use your own video

```bash
PRODUCTIVITY_BREAK_VIDEO=/path/to/your.mp4 swift run productivity_break --test
```

Any aspect ratio works (portrait, landscape, square) — the video's real
dimensions are detected and it's scaled to fit the screen.

You can also place a file named `productivity_break.mp4` in any of these spots
(checked in order) instead of setting the env var:

1. next to the binary (the install dir)
2. `~/Library/Application Support/productivity_break/productivity_break.mp4`
3. `./Resources/productivity_break.mp4` (when running from a checkout)

### The sample "floating cat" clip

A nice sample is the floating-cat clip
([source pin](https://in.pinterest.com/pin/2251868559305065/)):

```bash
./Scripts/fetch-video.sh        # downloads productivity_break.mp4 for personal use
```

> ⚠️ **That video is third-party artwork and is *not* included in this
> repository** (it's git-ignored). `fetch-video.sh` downloads it locally for
> your personal use only — please make sure you have the right to use any clip
> you add.

## Dynamic break content

Every break is different. When the overlay appears it fetches, on the fly:

- **A fresh message** — a famous quote, a fun fact, or a piece of advice pulled
  at random from free public APIs (ZenQuotes, dummyjson, uselessfacts,
  adviceslip). Set `PRODUCTIVITY_BREAK_QUOTES=off` to use the built-in local
  pool instead, or `PRODUCTIVITY_BREAK_MESSAGES="a|b|c"` to supply your own.

- **A matching visual** — a theme is derived from that message (e.g. a message
  about the sea → *ocean waves*; about stars → *starry night sky*; otherwise a
  random calming landscape) and a relevant image is fetched from
  [Openverse](https://openverse.org). Set `PRODUCTIVITY_BREAK_VISUALS=off` to
  use the local image instead. Set `PRODUCTIVITY_BREAK_ANIME=on` to also mix in
  anime art now and then (off by default — that source returns character art
  that can be stylized/suggestive).

Both fetches are async with short timeouts and **graceful fallbacks**: if you're
offline or a source is slow, the message falls back to the local pool and the
visual falls back to your local file, then to the built-in vector cat. So a
break always works, online or not.

> Content is **pre-fetched ahead of time** on a jittered ~10-minute timer and cached, so the break appears instantly and the network activity isn't tied to your break cadence. These features make outbound HTTPS requests to the APIs above
> (no personal data is sent). Turn them off with the `*_QUOTES=off` /
> `*_VISUALS=off` switches if you prefer a fully offline tool.

## Configuration

Set these as environment variables (or edit the `EnvironmentVariables` block in
the installed `~/Library/LaunchAgents/com.productivity_break.agent.plist`, then
re-run `install.sh`):

| Variable                          | Default | Meaning                                            |
|-----------------------------------|---------|----------------------------------------------------|
| `BREAK_MINUTES`                   | `25`    | Focused-terminal minutes before the break appears  |
| `PRODUCTIVITY_BREAK_SHOW_SECONDS` | `8`     | How long the overlay stays on screen               |
| `PRODUCTIVITY_BREAK_POLL_SECONDS` | `5`     | How often focus is checked                         |
| `PRODUCTIVITY_BREAK_IDLE_SECONDS` | `60`    | Input-idle seconds that pause the focus clock      |
| `PRODUCTIVITY_BREAK_SNOOZE_MINUTES`| `5`     | Re-arm delay when you press `S` to snooze          |
| `PRODUCTIVITY_BREAK_MENUBAR`      | (off)   | `on` shows a ☕ menu-bar control                    |
| `PRODUCTIVITY_BREAK_DEFER_APPS`   | (calls) | Comma-separated apps during which a due break waits |
| `PRODUCTIVITY_BREAK_OVERLAY_ALPHA`| `0.92`  | Background dimming (0 = clear, 1 = opaque black)   |
| `PRODUCTIVITY_BREAK_QUOTES`       | (on)    | Set to `off` to use only local messages (no network) |
| `PRODUCTIVITY_BREAK_MESSAGES`     | (none)  | Your own message pool, separated by `\|` — overrides the online fetch |
| `PRODUCTIVITY_BREAK_VISUALS`      | (on)    | Set to `off` to skip fetching a matching image (use the local visual) |
| `PRODUCTIVITY_BREAK_ANIME`        | (off)   | Set to `on` to occasionally use anime art (nekos.best) as the visual |
| `PRODUCTIVITY_BREAK_VIDEO`        | (auto)  | Path to a video. Auto-discovered from the repo's `Resources/`, the install dir, etc. |
| `PRODUCTIVITY_BREAK_TERMINAL_APPS`| `Terminal,iTerm,Warp,Alacritty,kitty,Hyper,WezTerm,Ghostty` | Comma-separated app names that count as "the terminal" (matched as case-insensitive substrings) |

## Project layout

```
productivity_break/
├── Package.swift                              # Swift Package Manager manifest
├── Sources/productivity_break/main.swift      # the whole program
├── Scripts/
│   ├── install.sh / uninstall.sh              # set up / tear down the login agent
│   └── fetch-video.sh                         # download the optional sample video
├── packaging/com.productivity_break.agent.plist  # launchd template
├── Resources/productivity_break.mp4           # optional video (git-ignored, not published)
└── .github/workflows/build.yml                # CI: builds on macOS
```

## Building manually

```bash
swift build -c release          # -> .build/release/productivity_break
# check your configuration without launching the GUI:
./.build/release/productivity_break --validate-config
# or a single-file build:
swiftc -O Sources/productivity_break/main.swift -o productivity_break
```

## License

MIT — see [LICENSE](LICENSE). The license covers the **source code**; any
optional break video is third-party and is not distributed with this repo.
