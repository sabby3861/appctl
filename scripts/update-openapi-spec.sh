#!/usr/bin/env bash
# Refreshes the cached App Store Connect OpenAPI spec at ~/.appctl/openapi.json.
# Same source and destination as `appctl api --update-schema`; kept as a script
# so the cache can be refreshed without a working appctl build.
set -euo pipefail

SPEC_URL="https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip"
CACHE_DIR="${HOME}/.appctl"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Downloading ${SPEC_URL}…"
curl -fsSL "${SPEC_URL}" -o "${WORK_DIR}/spec.zip"
unzip -o -q "${WORK_DIR}/spec.zip" -d "${WORK_DIR}"

JSON_FILE="$(find "${WORK_DIR}" -maxdepth 1 -name '*.json' | head -n 1)"
if [[ -z "${JSON_FILE}" ]]; then
  echo "error: the downloaded archive contained no JSON spec" >&2
  exit 1
fi

mkdir -p "${CACHE_DIR}"
mv "${JSON_FILE}" "${CACHE_DIR}/openapi.json"
echo "✓ Updated ${CACHE_DIR}/openapi.json"
