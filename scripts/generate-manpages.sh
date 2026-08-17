#!/usr/bin/env bash
# Generates man pages from the ArgumentParser command tree via the
# swift-argument-parser `generate-manual` plugin. One page per subcommand
# (--multi-page) so `man appctl-versions-submit` works.
#
# Usage: scripts/generate-manpages.sh [output-dir]   (default: .build/manpages)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-.build/manpages}"
mkdir -p "$OUT"
swift package plugin --allow-writing-to-directory "$OUT" \
  generate-manual --multi-page --output-directory "$OUT"
echo "Man pages written to $OUT:"
ls "$OUT" | head
