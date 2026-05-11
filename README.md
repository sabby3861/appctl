# appctl

[![CI](https://github.com/sabby3861/appctl/actions/workflows/ci.yml/badge.svg)](https://github.com/sabby3861/appctl/actions/workflows/ci.yml)
[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-orange?logo=swift&logoColor=white)](https://swift.org)
[![Platform: macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-blue)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**The Swift CLI for App Store Connect. Zero Ruby. Zero friction.**

A single, fast binary that replaces Fastlane's 67-gem Ruby toolchain. Talks directly to the App Store Connect API with three-part error diagnostics, automatic retry, and CI-ready output.

## Demo

<!--
TODO: replace this block with the captured demo.

  Option A (recommended) — asciinema:
    brew install asciinema
    asciinema rec demo.cast \
      --command "appctl workflow release --version 1.2.0 --dry-run" \
      --idle-time-limit 1
    asciinema upload demo.cast    # returns an https://asciinema.org/a/<id> URL

  Embed:
    [![asciicast](https://asciinema.org/a/<id>.svg)](https://asciinema.org/a/<id>)

  Option B — VHS-produced GIF (deterministic, no network):
    brew install charmbracelet/tap/vhs
    cat > assets/demo.tape <<'EOF'
    Output assets/demo.gif
    Set FontSize 14
    Set Width 900
    Set Height 540
    Type "appctl workflow release --version 1.2.0 --dry-run"
    Enter
    Sleep 4s
    EOF
    vhs assets/demo.tape

  Embed:
    ![Demo](assets/demo.gif)
-->

## Quick Start

```bash
git clone https://github.com/sabby3861/appctl.git
cd appctl && swift build -c release
sudo cp .build/release/appctl /usr/local/bin/
appctl auth setup
appctl doctor
appctl apps list
```

## Commands

| Group | Commands |
|---|---|
| `auth` | setup, verify, status |
| `apps` | list, info (supports bundle ID lookup) |
| `builds` | list, info, set-compliance |
| `versions` | list, create, update, submit, phased-release, reject |
| `testflight` | groups, testers, distribute |
| `certificates` | list (with expiry warnings), profiles, devices, bundle-ids |
| `localizations` | list, get, set, sync (bidirectional git-trackable metadata) |
| `screenshots` | list, delete |
| `reviews` | list (with star ratings), respond |
| `iap` | list, subscriptions |
| `pricing` | info (territory availability flags), territories |
| `users` | list, roles |
| `workflow` | **release** (full pipeline), **publish** (TestFlight), **watch** (real-time), **diff** |
| `ai` | release-notes (categorized commit summary), optimize (ASO checklist), translate (locale folder scaffolding) |
| `plugin` | list, run, create |
| `doctor` | 7 environment checks |
| `init` | create config |
| `version` | show version |

## Why appctl?

| | Fastlane | appctl |
|---|---|---|
| Dependencies | 67 Ruby gems | **Zero** |
| Cold start | ~2 minutes | **Instant** |
| Xcode breakage | Every release | **API only** |
| Error messages | "Exit status: 65" | **What/Why/Fix** |
| One-command release | No | **Yes** |

## Configuration

```toml
# .appctl.toml
[auth]
key_id = "YOUR_KEY_ID"
issuer_id = "YOUR_ISSUER_ID"
private_key_path = "~/.config/appctl/AuthKey.p8"

[app]
id = "6478329100"
```

Precedence: CLI flags → env vars → project config → global config → defaults.

## Output Formats

Auto-detects: colored text in terminal, JSON when piped. Override with `--format json|text|table|csv`.

## License

MIT — [Sanjay Kumar](https://github.com/sabby3861)
