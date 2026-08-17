#!/usr/bin/env bash
#
# Install appctl from a GitHub release, verifying the SHA-256 checksum.
#
#   curl -fsSL https://raw.githubusercontent.com/sabby3861/appctl/main/scripts/install.sh | bash
#
# Environment overrides:
#   VERSION  release to install without the v prefix (default: latest)
#   PREFIX   install prefix (default: /usr/local)

set -euo pipefail

REPO="sabby3861/appctl"
PREFIX="${PREFIX:-/usr/local}"
VERSION="${VERSION:-}"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "appctl release binaries are macOS-only"
command -v curl > /dev/null || fail "curl is required"
command -v shasum > /dev/null || fail "shasum is required"

CURL=(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2)

if [[ -z "$VERSION" ]]; then
  # Resolve the latest tag from the release redirect rather than the GitHub
  # API, which is rate-limited for unauthenticated callers.
  LATEST_URL="$("${CURL[@]}" -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest")"
  VERSION="${LATEST_URL##*/}"
  VERSION="${VERSION#v}"
  [[ "$VERSION" =~ ^[0-9] ]] || fail "could not determine the latest version (resolved '${LATEST_URL}')"
fi

TARBALL="appctl-${VERSION}-macos-universal.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/download/v${VERSION}"

TMPDIR_INSTALL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_INSTALL"' EXIT
cd "$TMPDIR_INSTALL"

echo "Downloading appctl ${VERSION}..."
"${CURL[@]}" -O "${BASE_URL}/${TARBALL}"
"${CURL[@]}" -O "${BASE_URL}/checksums.txt"

# Verify before extraction and before any privilege elevation — never
# sudo first and check later.
grep " ${TARBALL}\$" checksums.txt | shasum -a 256 -c - \
  || fail "checksum verification failed for ${TARBALL}"

tar -xzf "$TARBALL"
[[ -x appctl && -f appctl.1 ]] || fail "unexpected archive contents"

# A target dir may not exist yet; sudo is needed only if the nearest existing
# ancestor is not writable (so PREFIX=$HOME/.local never prompts).
needs_sudo() {
  local p="$1"
  while [[ ! -d "$p" ]]; do p="$(dirname "$p")"; done
  [[ ! -w "$p" ]]
}

SUDO=""
if needs_sudo "$PREFIX/bin" || needs_sudo "$PREFIX/share/man/man1"; then
  echo "Installing to ${PREFIX} requires sudo."
  SUDO="sudo"
fi

$SUDO install -d "$PREFIX/bin" "$PREFIX/share/man/man1"
$SUDO install -m 755 appctl "$PREFIX/bin/appctl"
$SUDO install -m 644 appctl.1 "$PREFIX/share/man/man1/appctl.1"

"$PREFIX/bin/appctl" version --short > /dev/null || fail "installed binary failed to run"
echo "Installed appctl ${VERSION} to ${PREFIX}/bin/appctl"
