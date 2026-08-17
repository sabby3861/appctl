# Roadmap

Everything in this file is **planned work — statements of intent, not shipped behavior**.
The README describes only what exists today; anything aspirational lives here.

## README demo recording

Record and embed a terminal demo of the release workflow.

Option A (recommended) — asciinema:

```bash
brew install asciinema
asciinema rec demo.cast \
  --command "appctl workflow release --version 1.2.0 --dry-run" \
  --idle-time-limit 1
asciinema upload demo.cast    # returns an https://asciinema.org/a/<id> URL
```

Embed:

```markdown
[![asciicast](https://asciinema.org/a/<id>.svg)](https://asciinema.org/a/<id>)
```

Option B — VHS-produced GIF (deterministic, no network):

```bash
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
```

Embed:

```markdown
![Demo](assets/demo.gif)
```

## Signing repair

`appctl signing repair`: diagnose and repair code-signing state — expired or
revoked certificates, missing or mismatched provisioning profiles — via the
Certificates/Profiles endpoints. This is the appctl answer to the gap
`appctl migrate --from-fastlane` reports for fastlane's `match`: not a
git-synced certificate store, but making the signing assets an account already
has valid and consistent. Until it lands, `appctl certificates list` shows
what exists.

## Per-territory price tiers

`appctl pricing info` currently shows territory-availability flags only
(the command's own help text says so). Extend it to fetch and display
per-territory price tiers via the App Store Connect pricing endpoints.
