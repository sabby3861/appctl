# appctl error codes

Every appctl failure carries a stable, machine-readable code. In text output it
appears on the final `Code:` line; in `--output json` it is `error.code` in the
envelope. Codes are a public contract: new ones may be added, but existing codes
are never renamed or removed.

Each code belongs to one **exit class**, which is also the process exit code:

| Exit code | Class | Meaning |
|---|---|---|
| 1 | usage | The command line itself was wrong (bad flag, missing argument, refused combination). |
| 2 | validation | Local input (files, text, images) failed validation before anything was sent. |
| 3 | api | App Store Connect (or an external tool) accepted the request shape but refused it. |
| 4 | auth | Credentials are missing, invalid, or not authorized. |
| 5 | network | The request never completed — connectivity, timeouts, upload transport. |

Scripts should branch on `error.code` first and the exit class second; the class
is a coarse router, the code is precise.

## Auth — exit class 4

## AUTH_MISSING_KEY
No API key is configured. Run `appctl auth setup`, or set `APPCTL_KEY_ID`,
`APPCTL_ISSUER_ID`, and `APPCTL_PRIVATE_KEY_PATH`.

## AUTH_INVALID_KEY_FILE
The `.p8` file exists but could not be parsed. Re-download it from App Store
Connect → Users and Access → Keys.

## AUTH_JWT_FAILED
Token signing failed — usually a corrupted or wrong-format private key.

## AUTH_TOKEN_EXPIRED
The signed token expired mid-flight. appctl auto-refreshes; if this persists,
run `appctl auth verify`.

## AUTH_UNAUTHORIZED
The key authenticated but lacks the role for this endpoint. Check the key's
role in App Store Connect.

## AUTH_AGREEMENT_PENDING
A developer program agreement is unsigned, which blocks most API writes. An
Account Holder must accept it in App Store Connect; no API call can fix this.

## AUTH_KEYCHAIN
Reading or writing the login keychain failed. Unlock the keychain and retry;
inspect items in Keychain Access by searching for the service name shown.

## AUTH_ALTOOL_KEY_NOT_FOUND
The altool fallback only reads keys from its own directories. Copy your key to
`~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`.

## Usage — exit class 1

## USAGE_INVALID_ARGUMENT
A flag or argument value is not acceptable. The message names the field and
what was expected.

## USAGE_MISSING_FIELD
A required field was neither passed as a flag nor present in `.appctl.toml`.

## USAGE_CONFIG_NOT_FOUND
No configuration file was found on the search path. Run `appctl init`.

## USAGE_CONFIRMATION_REQUIRED
The operation is destructive and needs its explicit confirmation flag
(e.g. `appctl api DELETE … --confirm`). `--yes` is deliberately refused here.

## USAGE_UNSUPPORTED
The operation is not supported in this configuration; the message says why.

## USAGE_CANCELLED
The user cancelled (Ctrl-C or declined a prompt). Not an error in scripts that
expect interactivity.

## Validation — exit class 2

## VALIDATION_CHAR_LIMIT
A metadata field exceeds App Store Connect's character limit. The message names
the file, the limit, and the overage. Nothing was pushed.

## VALIDATION_SCREENSHOT
Screenshot files failed dimension/format validation. Nothing was uploaded.

## VALIDATION_CONFIG_PARSE
`.appctl.toml` (or the global config) has a syntax error at the reported line.

## VALIDATION_FILE_NOT_FOUND
A user-supplied path does not exist.

## VALIDATION_FILE_NOT_READABLE
The path exists but is not readable — check permissions.

## VALIDATION_FILE_WRITE
Writing an output file failed (permissions, disk space, read-only volume).

## VALIDATION_SIGNING_CERT_EXPIRED
The named certificate has expired. `appctl certificates create --type distribution`.

## VALIDATION_SIGNING_CERT_NOT_FOUND
No matching certificate. `appctl certificates list` shows what exists.

## VALIDATION_SIGNING_PROFILE_MISMATCH
The provisioning profile's bundle ID does not match the app's.

## VALIDATION_SIGNING_IDENTITY_NOT_FOUND
The signing identity is not in the keychain — install the certificate.

## API — exit class 3

## API_ERROR
App Store Connect rejected the request. The Apple error codes, titles, and
details are reproduced in the message and, in JSON mode, inside `error.message`.

## API_REQUEST_FAILED
A non-2xx response that carried no parseable JSON:API error document.

## API_RATE_LIMITED
HTTP 429 persisted through 5 attempts of exponential backoff. Wait, then batch
or slow the operation.

## API_RESOURCE_LOCKED
Apple reported a `STATE_ERROR`: the resource is in a state that forbids this
change (e.g. a version already in review). Resolve the state first — for
versions, `appctl versions reject <id>` pulls one back out of review.

## API_NOT_FOUND
The resource does not exist under this account. Verify the identifier with the
matching `list` command.

## API_CONFLICT
Another operation is mid-flight on the same resource. Wait and retry.

## API_PARTIAL_FAILURE
A batch operation (e.g. `localizations push`) succeeded for some items and
failed for others. Each failure is listed in the warnings; completed items are
safe to repeat, so fix the causes and re-run.

## API_INVALID_RESPONSE
The server responded, but not with the promised shape. Often transient; check
for appctl updates if it persists.

## API_BUILD_PROCESSING_FAILED
The uploaded build finished processing in a FAILED/INVALID state. The full
processing report is in App Store Connect → TestFlight.

## API_SCHEMA_UNAVAILABLE
The cached OpenAPI schema could not be loaded or refreshed
(`appctl api --update-schema`).

## SUBPROCESS_FAILED
An external tool (altool, git) exited non-zero; its own output above the error
explains why.

## Network — exit class 5

## NETWORK_TIMEOUT
The request exceeded `--timeout` (or the configured `network.timeout`).

## NETWORK_CONNECTION_FAILED
DNS, TLS, or socket-level failure — including after transport retries.

## UPLOAD_PART_FAILED
One chunk of a resumable upload failed after all attempts. Re-running the same
command resumes: completed parts are recorded in the sidecar file and skipped.
