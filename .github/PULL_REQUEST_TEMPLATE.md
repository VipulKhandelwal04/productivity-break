## What & why

<!-- What does this change do, and why? Link any related issue (e.g. Closes #12). -->

## How I tested

<!-- e.g. `swift build -c release` clean; `--test` shows the overlay; `--validate-config` output -->

## Checklist

- [ ] `swift build -c release` compiles with no new warnings
- [ ] Verified behavior with `--test` (and `--validate-config` if config changed)
- [ ] If I added/renamed a config knob, I updated `--help`, the README table,
      `config.example.json`, and `validateConfig()`
- [ ] No new third-party dependencies; no new system permissions required
