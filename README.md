# 🐱 cat-break

A tiny macOS productivity nudge. When your **terminal has been the focused app
for 25 continuous minutes**, a cat fills the screen — sliding up through a
dimmed overlay, hanging out for a few seconds, then fading away — your cue to
stretch, blink, and drink some water. The timer then resets.

Native **Swift + AppKit + AVFoundation**. No third-party dependencies. The
default cat is drawn in code (vector art), so it works offline out of the box.
You can optionally swap in a looping cat **video** (see below).

![build](https://img.shields.io/badge/build-swift%20build-orange)
![platform](https://img.shields.io/badge/platform-macOS%2012%2B-blue)
![license](https://img.shields.io/badge/license-MIT-green)

## How the timer works

- **Continuous focus** — the clock only ticks while a terminal app is the
  active/frontmost window. Switch to another app and it **pauses** (it does not
  reset); switch back and it resumes counting.
- After 25 min the cat appears, auto-fades after ~8 s, and the timer resets.
- Click anywhere (or just wait) to dismiss the cat.
- Uses `NSWorkspace` for focus detection — **no Accessibility permission needed**.

## Requirements

- macOS 12 or later
- A Swift toolchain (`swift --version`) — ships with Xcode or the Command Line
  Tools (`xcode-select --install`).

## Quick start

```bash
git clone https://github.com/<you>/cat-break.git
cd cat-break

swift run cat-break --test        # see the cat right now
BREAK_MINUTES=0.2 swift run cat-break   # try the full flow (cat after ~12 s of terminal focus)
```

## Install as a background tool (auto-start at login)

```bash
./Scripts/install.sh
```

This builds a release binary, copies it to
`~/Library/Application Support/cat-break/`, and registers a `launchd` login
agent (`com.cat-break.agent`) that runs quietly in the background — no Dock
icon, no menu-bar item. It starts immediately and again at every login.

Remove it any time:

```bash
./Scripts/uninstall.sh
```

## Optional: the floating-cat video

By default cat-break draws its own vector cat. If you'd rather see the
floating-cat clip ([source pin](https://in.pinterest.com/pin/2251868559305065/)):

```bash
./Scripts/fetch-cat.sh        # downloads cat.mp4 for personal use
```

> ⚠️ **The video is third-party artwork and is *not* included in this
> repository** (it's git-ignored). `fetch-cat.sh` downloads it locally for your
> personal use only — please make sure you have the right to use any clip you
> add. To use your own video, skip the script and set `CAT_VIDEO`:
>
> ```bash
> CAT_VIDEO=/path/to/your.mp4 swift run cat-break --test
> ```

## Configuration

Set these as environment variables (or edit the `EnvironmentVariables` block in
the installed `~/Library/LaunchAgents/com.cat-break.agent.plist`, then re-run
`install.sh`):

| Variable             | Default | Meaning                                            |
|----------------------|---------|----------------------------------------------------|
| `BREAK_MINUTES`      | `25`    | Focused-terminal minutes before the cat appears    |
| `CAT_SHOW_SECONDS`   | `8`     | How long the cat stays on screen                   |
| `CAT_POLL_SECONDS`   | `5`     | How often focus is checked                         |
| `CAT_OVERLAY_ALPHA`  | `0.92`  | Background dimming (0 = clear, 1 = opaque black)   |
| `CAT_VIDEO`          | (auto)  | Path to a cat video. Auto-discovered from the repo's `Resources/cat.mp4`, the install dir, etc. |
| `CAT_TERMINAL_APPS`  | `Terminal,iTerm,Warp,Alacritty,kitty,Hyper,WezTerm,Ghostty` | Comma-separated app names that count as "the terminal" (matched as case-insensitive substrings) |

## Project layout

```
cat-break/
├── Package.swift                      # Swift Package Manager manifest
├── Sources/cat-break/main.swift       # the whole program
├── Scripts/
│   ├── install.sh / uninstall.sh      # set up / tear down the login agent
│   └── fetch-cat.sh                   # download the optional video (personal use)
├── packaging/com.cat-break.agent.plist  # launchd template
├── Resources/cat.mp4                  # optional video (git-ignored, not published)
└── .github/workflows/build.yml        # CI: builds on macOS
```

## Building manually

```bash
swift build -c release          # -> .build/release/cat-break
# or a single-file build:
swiftc -O Sources/cat-break/main.swift -o cat-break
```

## License

MIT — see [LICENSE](LICENSE). The license covers the **source code**; the
optional cat video is third-party and is not distributed with this repo.
