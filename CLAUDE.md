# appctl — CLAUDE.md
Swift 6.2 CLI for App Store Connect. Targets: AppctlCLI (entry), AppctlCore (everything).
Build: swift build   Test: swift test   Toolchain: Xcode 26 / Swift 6.2, swift-tools-version 6.2
Runtime minimum: macOS 13 (do not raise without discussion). This is a macOS CLI — no iOS SDK code ever.

## Concurrency (strict mode is ON)
- async/await + actors only. No DispatchQueue, no locks, no semaphores, no completion handlers.
- Mutable shared state lives in an actor (e.g. TokenCache). NEVER add @unchecked Sendable;
  if conformance is hard, restructure the type instead.
- Public AppctlCore types are Sendable by design.

## Architecture rules
- Commands depend on `any AppStoreConnectClient` (protocol), injected via init.
  Concrete APIClient is constructed ONLY in GlobalOptions.apiClient().
- Every user-facing failure uses the What/Why/Fix formatter with a stable error.code.
  NEVER catch an API error and print a generic message instead.
- All JSON output goes through the versioned envelope { apiVersion, data, warnings, error?, next }.
- Every mutating command writes to the audit log and supports --dry-run.
- ASC API is JSON:API; always paginate via links.next; per-page limit max 200.

## Code style (senior bar)
- No force unwraps (!), no try!, no fatalError in production paths — typed throws or guarded exits.
- Value types by default; final classes only with a reason; access control explicit (public is a decision).
- Follow Swift API Design Guidelines for naming; small focused functions; no dead code or TODO left behind.
- Comments explain WHY, not what. No decorative comment banners.
- New code must not introduce warnings. swift-format clean.

## Testing
- Swift Testing (@Test/#expect) — never XCTest. Every feature ships with mocked tests via
  MockAppStoreConnectClient. No network, no filesystem writes outside temp dirs, in unit tests.
- Acceptance criteria in the current task prompt are the definition of done — verify each explicitly.
