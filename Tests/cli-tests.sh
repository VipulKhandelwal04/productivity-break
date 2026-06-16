#!/usr/bin/env bash
#
# Integration tests for the productivity_break CLI contract.
#
# productivity_break is a macOS GUI app: its main loop ends in `app.run()`, so
# the code can't be `@testable import`ed without launching the overlay, and
# `swift test` needs full Xcode (not just CommandLineTools) to host a test
# bundle. The headless, scriptable surface is the CLI — `--validate-config`,
# `--version`, `--help` — so that is what we test here, the same way CI does.
#
# These tests are HERMETIC: config-file lookups read NSHomeDirectory(), which
# honors CFFIXED_USER_HOME, so each case points that at a throwaway temp home.
# Nothing touches your real ~/.config/productivity_break.
#
# Usage:  Tests/cli-tests.sh            # builds (debug) then tests
#         BIN=/path/to/binary Tests/cli-tests.sh   # test a prebuilt binary
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || { echo "cannot cd to repo root: $REPO_ROOT" >&2; exit 1; }

# Locate (or build) the binary. CI sets BIN to the release build.
BIN="${BIN:-}"
if [[ -z "$BIN" ]]; then
    if [[ -x .build/debug/productivity_break ]]; then
        BIN=.build/debug/productivity_break
    else
        echo "Building debug binary..." >&2
        swift build -c debug >&2 || { echo "build failed" >&2; exit 1; }
        BIN=.build/debug/productivity_break
    fi
fi
echo "Testing binary: $BIN" >&2

PASS=0
FAIL=0

# A scratch home with no config.json, so the "defaults" cases are not perturbed
# by any real or test config file. Cleaned up on exit.
EMPTY_HOME="$(mktemp -d)"
trap 'rm -rf "$EMPTY_HOME" "${TMP_HOMES[@]:-}"' EXIT
TMP_HOMES=()

# make_home '<json>' -> prints a temp home dir containing
# .config/productivity_break/config.json with that body.
make_home() {
    local dir; dir="$(mktemp -d)"
    TMP_HOMES+=("$dir")
    mkdir -p "$dir/.config/productivity_break"
    printf '%s' "$1" > "$dir/.config/productivity_break/config.json"
    printf '%s' "$dir"
}

# ok <name> <condition-result> — record a boolean assertion.
ok() {
    if [[ "$2" == "0" ]]; then
        printf '  ok   %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1))
    fi
}

# Assert combined stdout+stderr of a command contains a substring.
# Usage: assert_contains <name> <needle> <env-assignments...> -- <args...>
assert_contains() {
    local name="$1" needle="$2"; shift 2
    local out; out="$("$@" 2>&1)"
    if [[ "$out" == *"$needle"* ]]; then ok "$name" 0
    else ok "$name (missing: '$needle')" 1; fi
}

# Assert exit code of a command.
assert_exit() {
    local name="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1; local got=$?
    if [[ "$got" == "$want" ]]; then ok "$name" 0
    else ok "$name (exit $got, want $want)" 1; fi
}

echo "== --version =="
assert_contains  "version prints name + semver" "productivity_break 0.2.0" "$BIN" --version
assert_exit      "version exits 0" 0 "$BIN" --version

echo "== --help =="
assert_contains  "help shows usage"   "USAGE:" "$BIN" --help
assert_contains  "help lists BREAK_MINUTES" "BREAK_MINUTES" "$BIN" --help
assert_exit      "help exits 0" 0 "$BIN" --help

echo "== --validate-config: defaults (hermetic, empty home) =="
assert_contains  "default BREAK_MINUTES is 25" "BREAK_MINUTES   = 25.0" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" "$BIN" --validate-config
assert_contains  "default threshold is 1500s" "threshold 1500.0s" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" "$BIN" --validate-config
assert_contains  "default SHOW_SECONDS is 8" "SHOW_SECONDS    = 8.0" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" "$BIN" --validate-config
assert_contains  "default POLL_SECONDS is 5" "POLL_SECONDS    = 5.0" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" "$BIN" --validate-config
assert_contains  "default IDLE_SECONDS is 60" "IDLE_SECONDS    = 60.0" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" "$BIN" --validate-config
assert_contains  "default STYLE is overlay" "STYLE           = overlay" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" "$BIN" --validate-config
assert_contains  "reports OK" "OK" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" "$BIN" --validate-config
assert_exit      "valid config exits 0" 0 \
    env CFFIXED_USER_HOME="$EMPTY_HOME" "$BIN" --validate-config

echo "== --validate-config: env overrides =="
assert_contains  "env sets BREAK_MINUTES=13" "BREAK_MINUTES   = 13.0" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" BREAK_MINUTES=13 "$BIN" --validate-config
assert_contains  "env BREAK_MINUTES=13 -> threshold 780s" "threshold 780.0s" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" BREAK_MINUTES=13 "$BIN" --validate-config
# BREAK_MINUTES has a 0.05 floor (max(0.05, ...)).
assert_contains  "BREAK_MINUTES clamps up to 0.05 floor" "BREAK_MINUTES   = 0.05" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" BREAK_MINUTES=0 "$BIN" --validate-config
# OVERLAY_ALPHA is clamped into 0.0...1.0.
assert_contains  "OVERLAY_ALPHA clamps down to 1.0" "OVERLAY_ALPHA   = 1.0" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" PRODUCTIVITY_BREAK_OVERLAY_ALPHA=5 "$BIN" --validate-config
assert_contains  "TERMINAL_APPS override reflected" "TERMINAL_APPS   = ghostty" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" PRODUCTIVITY_BREAK_TERMINAL_APPS=Ghostty "$BIN" --validate-config
assert_contains  "STYLE=notify reflected" "STYLE           = notify" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" PRODUCTIVITY_BREAK_STYLE=notify "$BIN" --validate-config

echo "== --validate-config: boolean parsing (on/off/true/false/yes/no/1/0 + fallback) =="
# False path on a default-true var.
assert_contains  "QUOTES=off -> false" "QUOTES=false" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" PRODUCTIVITY_BREAK_QUOTES=off "$BIN" --validate-config
assert_contains  "QUOTES=no -> false" "QUOTES=false" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" PRODUCTIVITY_BREAK_QUOTES=no "$BIN" --validate-config
# True path on a default-false var (ANIME defaults off).
assert_contains  "ANIME=on -> true" "ANIME=true" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" PRODUCTIVITY_BREAK_ANIME=on "$BIN" --validate-config
assert_contains  "ANIME=1 -> true" "ANIME=true" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" PRODUCTIVITY_BREAK_ANIME=1 "$BIN" --validate-config
# Unrecognized value falls back to the default (ANIME default is false).
assert_contains  "ANIME=bogus -> default false" "ANIME=false" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" PRODUCTIVITY_BREAK_ANIME=bogus "$BIN" --validate-config

echo "== --validate-config: config.json arrays comma-join (e.g. config.example.json) =="
ARR_HOME="$(make_home '{"PRODUCTIVITY_BREAK_TERMINAL_APPS": ["Terminal", "Ghostty", "Warp"]}')"
assert_contains  "JSON array -> comma-joined, lowercased" "TERMINAL_APPS   = terminal, ghostty, warp" \
    env CFFIXED_USER_HOME="$ARR_HOME" "$BIN" --validate-config

echo "== --validate-config: config.json precedence (default < json < env) =="
JSON_HOME="$(make_home '{"BREAK_MINUTES": 7, "PRODUCTIVITY_BREAK_QUOTES": false}')"
assert_contains  "config.json sets BREAK_MINUTES=7" "BREAK_MINUTES   = 7.0" \
    env CFFIXED_USER_HOME="$JSON_HOME" "$BIN" --validate-config
assert_contains  "config.json bool QUOTES=false" "QUOTES=false" \
    env CFFIXED_USER_HOME="$JSON_HOME" "$BIN" --validate-config
assert_contains  "env beats config.json (15 > 7)" "BREAK_MINUTES   = 15.0" \
    env CFFIXED_USER_HOME="$JSON_HOME" BREAK_MINUTES=15 "$BIN" --validate-config

echo "== --validate-config: invalid input is rejected =="
assert_contains  "non-numeric env reports INVALID CONFIG" "INVALID CONFIG" \
    env CFFIXED_USER_HOME="$EMPTY_HOME" BREAK_MINUTES=not-a-number "$BIN" --validate-config
# Every numeric var is validated — a regression dropping one from the loop
# must fail here, so check them all.
for v in BREAK_MINUTES PRODUCTIVITY_BREAK_SHOW_SECONDS PRODUCTIVITY_BREAK_POLL_SECONDS \
         PRODUCTIVITY_BREAK_OVERLAY_ALPHA PRODUCTIVITY_BREAK_IDLE_SECONDS \
         PRODUCTIVITY_BREAK_SNOOZE_MINUTES; do
    assert_exit  "non-numeric $v exits 1" 1 \
        env CFFIXED_USER_HOME="$EMPTY_HOME" "$v=xyz" "$BIN" --validate-config
done
BAD_JSON_HOME="$(make_home '{"PRODUCTIVITY_BREAK_POLL_SECONDS": "abc"}')"
assert_exit      "non-numeric value in config.json exits 1" 1 \
    env CFFIXED_USER_HOME="$BAD_JSON_HOME" "$BIN" --validate-config

echo "== --validate-config: malformed config.json is ignored (falls back to defaults) =="
BROKEN_JSON_HOME="$(make_home '{ this is not json')"
assert_exit      "malformed config.json still exits 0" 0 \
    env CFFIXED_USER_HOME="$BROKEN_JSON_HOME" "$BIN" --validate-config
assert_contains  "malformed config.json -> default BREAK_MINUTES=25" "BREAK_MINUTES   = 25.0" \
    env CFFIXED_USER_HOME="$BROKEN_JSON_HOME" "$BIN" --validate-config

echo
echo "------------------------------------"
echo "passed: $PASS   failed: $FAIL"
if [[ "$FAIL" == "0" ]]; then
    echo "ALL TESTS PASSED"; exit 0
else
    echo "TESTS FAILED"; exit 1
fi
