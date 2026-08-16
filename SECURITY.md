# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in appctl, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, use [GitHub Security Advisories](https://github.com/sabby3861/appctl/security/advisories/new) to report the issue privately.

You should receive an acknowledgement within 48 hours and a detailed response within 7 days.

## Scope

Security issues we care about:
- Credential leakage (API keys, .p8 files exposed in logs or output)
- JWT token handling vulnerabilities
- Command injection through user input
- Insecure file permissions on config or key files
- Dependency vulnerabilities in swift-argument-parser or swift-crypto

## Credential Handling

appctl follows these security practices:
- Private keys are never logged, even in verbose mode
- Credentials resolve in a fixed order: command-line flags > environment
  variables > login keychain > config file — never hardcoded
- `appctl auth setup --keychain` stores the key ID, issuer ID, and .p8 contents
  as generic-password items in the login keychain (service
  `com.appctl.credentials`, accounts `key-id`, `issuer-id`, `private-key`);
  `appctl auth setup --remove-keychain` deletes them again
- Config files containing key paths should be gitignored (included in our .gitignore)
- JWT tokens are cached in memory only, never written to disk
- `appctl auth setup` (file mode) writes the configuration file with `0600` permissions

## Plugin Trust Model

`appctl plugin` discovers and runs any executable on `$PATH` whose name starts
with `appctl-`. Plugins are **not sandboxed**, but they run on the far side of a
credential trust boundary:

- **Child processes never receive key material.** Before launching a plugin,
  `appctl plugin run` strips `APPCTL_KEY_ID`, `APPCTL_ISSUER_ID`,
  `APPCTL_PRIVATE_KEY_PATH`, and any environment value containing PEM
  private-key material from the child environment.
- **API access is opt-in via manifest.** A plugin that needs App Store Connect
  access must ship a sidecar manifest next to its binary
  (`appctl-<name>.manifest.json` containing `{"requiresAPIAccess": true}`).
  Such plugins receive a single `APPCTL_TOKEN` variable holding a freshly
  minted JWT that expires within 5 minutes — enough to call the API during the
  run, of limited value if exfiltrated.
- **Plugins without a manifest receive no credentials of any kind.**

The residual risk: within its ≤5-minute lifetime, a delegated token carries the
same App Store Connect role as your API key. Treat third-party plugins like you
would any other binary you install: only run plugins you wrote or have audited,
install them from sources you trust, and prefer pinned releases over
`curl | sh`-style installers. If you maintain a shared engineering machine,
audit `$PATH` for unexpected `appctl-*` entries.
