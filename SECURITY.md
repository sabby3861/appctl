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
- Secrets are resolved from environment variables or files, never hardcoded
- Config files containing key paths should be gitignored (included in our .gitignore)
- JWT tokens are cached in memory only, never written to disk
- `appctl auth setup` writes the configuration file with `0600` permissions

## Plugin Trust Model

`appctl plugin` discovers and runs any executable on `$PATH` whose name starts
with `appctl-`. Plugins are **not sandboxed** and inherit the parent process's
environment, including the App Store Connect credentials that `appctl plugin run`
explicitly forwards (`APPCTL_KEY_ID`, `APPCTL_ISSUER_ID`, `APPCTL_PRIVATE_KEY_PATH`).

Treat third-party plugins like you would any other binary you install: only run
plugins you wrote or have audited, install them from sources you trust, and
prefer pinned releases over `curl | sh`-style installers. If you maintain a
shared engineering machine, audit `$PATH` for unexpected `appctl-*` entries.
