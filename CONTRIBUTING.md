# Contributing to appctl

Thanks for your interest in contributing. Here's how to get started.

## Setup

```bash
git clone https://github.com/sabby3861/appctl.git
cd appctl
swift build
swift test
```

## Code Style

We use [swift-format](https://github.com/apple/swift-format) for consistent formatting. Run it before submitting a PR:

```bash
swift-format format --in-place --recursive Sources/ Tests/
```

## Pull Requests

1. Fork the repo and create a branch from `main`
2. Add tests for new functionality
3. Run `swift test` and ensure all tests pass
4. Run `swift-format` to format your code
5. Open a PR with a clear description of the change

## Reporting Issues

Open a GitHub issue with:
- What you expected to happen
- What actually happened
- Steps to reproduce
- Your environment (macOS version, Swift version, Xcode version)

## Architecture

The project has two targets:
- **AppctlCore** — all business logic, importable as a library
- **AppctlCLI** — the executable entry point

Top-level command types (e.g. `AuthCommand`, `WorkflowCommand`) are `public` with `public init()` because AppctlCLI is a separate module that needs to reference them. Their nested subcommand structs (`Setup`, `List`, `Info`, …) are intentionally `internal` — they are only registered with ArgumentParser inside the parent command's `subcommands:` array, never instantiated from outside the module.

The deliberately small public surface is roughly:
- Networking: `APIClient`, `JWTGenerator`, `AuthStore`
- Config: `AppctlConfig`, `ConfigLoader`, `OutputFormat`
- Errors: `AppctlError`, `ExitCode`
- Output: `OutputFormatter`, `Column`, `SpinnerHandle`, `StandardError`
- Models: every `Decodable` type in `Models/APIModels.swift` and the `Encodable` request shapes in `Models/SharedTypes.swift`
- `AppctlVersion`

## Configuration File Format

`.appctl.toml` uses a small subset of TOML implemented locally to avoid an extra
dependency. Supported:

- `[section]` headers, one level deep
- `key = "string"`, `key = 'string'`, and `key = bareword`
- End-of-line `# comments`

Not supported: multi-line strings, arrays, inline tables, dotted keys, date/time
literals, backslash escapes beyond `\\`. If you need any of these, the parser
won't crash — it'll silently ignore the line or store the raw string. See
`ConfigLoader.parseTOML` for the exact behavior. To extend the format, prefer
swapping in [TOMLKit](https://github.com/LebJe/TOMLKit) over growing the local parser.
