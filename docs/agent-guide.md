# appctl for agents and scripts

appctl's JSON mode is designed to be driven by programs — CI scripts and LLM
agents alike — following the CAEOAS pattern (Command-line Agent Experience,
Output-As-State): every response tells you both *what is* (`data`) and *what you
can do next* (`next`), so a caller never has to guess valid transitions.

JSON mode is automatic when stdout is not a TTY (pipes, CI) and explicit with
`--output json`.

## The envelope (contract v1)

In JSON mode, every list/detail command (`apps list`, `versions list`,
`auth status`, …), every `appctl api` call, and **every failure** prints exactly
one envelope on stdout. Mutating commands (`versions submit`, `workflow
release`, …) currently report success on stderr with an empty stdout and exit
0 — success envelopes for them arrive with the execute-seam rollout.

```json
{
  "apiVersion": "appctl/v1",
  "data": …,
  "warnings": [],
  "error": { "code": "…", "exitClass": 3, "message": "…", "docs": "…" },
  "next": { "submit": "appctl versions submit 123456" }
}
```

- `apiVersion` — the contract version. This document describes `appctl/v1`,
  the contract's debut; any breaking change to field names or types bumps it.
- `data` — the result. `null` on failure.
- `warnings` — non-fatal notes (safety stops, partial results).
- `error` — present only on failure. `code` is a stable identifier from
  [docs/errors.md](errors.md); `exitClass` matches the process exit code;
  `message` is the human What/Why/Fix text; `docs` links the code's anchor.
- `next` — always present, `null` when nothing sensible follows. Otherwise a
  map of action name → **a literal, ready-to-run appctl command**.

Human-readable progress (spinners, ✓ lines) goes to stderr, never stdout —
`appctl … | jq` always parses.

## `next` is state-aware

Actions appear only when the resource's state permits them. For versions:

- `submit` is offered only while the version is editable
  (`PREPARE_FOR_SUBMISSION`, `DEVELOPER_REJECTED`, `REJECTED`,
  `METADATA_REJECTED`, `INVALID_BINARY`);
- `reject` is offered only while it sits in review (`WAITING_FOR_REVIEW`,
  `IN_REVIEW`);
- a locked version (`READY_FOR_SALE`, `PENDING_APPLE_RELEASE`, …) offers
  neither.

Suggested commands carry the auth and output flags you invoked appctl with
(`--key-id`, `--issuer-id`, `--private-key-path`, `--output`, `--mock`), so
they run in the same context verbatim. `appctl api GET` responses with more
pages offer `next.nextPage`, a complete command for the following page.

An agent loop is therefore: run command → read `data` → pick an entry from
`next` → execute it verbatim.

## Error codes and exit classes

Every failure sets `error.code` and exits with its class:
**1** usage, **2** validation, **3** API, **4** auth, **5** network.
The full catalog, one anchor per code, is in [docs/errors.md](errors.md).
Branch on the code, not on message text — messages may be reworded, codes never.

## Global flags

Available on every data command:

| Flag | Effect |
|---|---|
| `--output json\|table\|markdown\|text\|csv` | Output format (`--format` is a deprecated alias). |
| `--query <expr>` | Filter JSON `data` before printing; implies `--output json`. |
| `--quiet` | Suppress progress/success chatter on stderr. |
| `--yes` | Assume "yes" at prompts. Typed-confirmation gates (e.g. `api DELETE --confirm`) refuse it by design. |
| `--timeout <seconds>` | Network timeout override. |
| `--no-color` | Disable ANSI colors. |

### `--query`

A small JMESPath subset evaluated against the envelope's `data`:

- dot paths: `--query 'data.attributes.name'` *(paths are relative to `data`)*
- indexes: `[0]`, `[-1]`
- projections: `[*].id`
- filters: `[?state=='READY_FOR_SALE'].id`, `!=` also supported; literals are
  `'strings'`, numbers, `true`, `false`, `null`

Example — IDs of every version awaiting submission (JSON mode carries raw API
values like `PREPARE_FOR_SUBMISSION` and full IDs, not the decorated display
strings tables show):

```sh
appctl versions list --app-id 123 --query "[?state=='PREPARE_FOR_SUBMISSION'].id"
```

JMESPath semantics: a non-matching path yields `null`, projections drop nulls,
and only syntax errors fail (exit class 1).

## Completions and man pages

- `appctl completions zsh|bash|fish` prints a completion script for the whole
  command tree (Homebrew installs these automatically).
- Man pages are generated from the same tree:
  `scripts/generate-manpages.sh`, or `man appctl` / `man appctl-versions-submit`
  from a packaged install.

## Retry behavior (so you don't have to)

appctl retries before you ever see an error: HTTP 429 up to 5 attempts with
exponential backoff + jitter (respecting `Retry-After`, capped at 60s), 5xx and
transport errors up to 3 attempts. If you still get `API_RATE_LIMITED`, the
server means it — slow down rather than looping.
