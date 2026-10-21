#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Print the configurePresets names of an app's CMakePresets.json as a
# comma-separated list suitable for `ci/build.sh --preset`.
#
# CI and the release workflow use this instead of hand-maintained preset
# lists, so a preset added to CMakePresets.json is built automatically.
#
# Usage: list-presets.sh <target>
#   <target>  App directory relative to the repo root (e.g. initiator, reflector)
#
# Prints nothing (exit 0) when the app has no presets — the pre-board scaffold
# state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
  echo "Usage: list-presets.sh <target>" >&2
  exit 1
fi

PRESETS_FILE="${REPO_ROOT}/${TARGET}/CMakePresets.json"
if [[ ! -f "${PRESETS_FILE}" ]]; then
  echo "Error: ${PRESETS_FILE} not found" >&2
  exit 1
fi

python3 - "${PRESETS_FILE}" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    presets = json.load(f).get("configurePresets", [])

print(",".join(p["name"] for p in presets))
PY
