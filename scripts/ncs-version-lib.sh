#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Shared NCS-version helpers for mars-cs-nrf54lm.
#
# Sourced by scripts/check-ncs-version.sh (the guard) and scripts/bump-ncs.sh
# (the bump operation) so the two agree on exactly what counts as an NCS
# version reference. Mirrors the ci/common.sh convention: a functions-only
# library, no `set` flags (callers set their own).
#
# Canonical source of truth: west.yml's `nrf` project `revision`. Live NCS
# version references (container image tags, cache keys, README/docs prose,
# script comments) are expected to agree with it; historical records are not.

# find_repo_root -> repo top-level path (matches scripts/check-docs.sh).
find_repo_root() {
  git rev-parse --show-toplevel
}

# ncs_version_from_west -> print the `nrf` project revision (vX.Y.Z) from
# west.yml. Fails loudly if west.yml is missing or the revision can't be
# parsed. The scanner owns the manifest pattern used for both reading and
# rewriting, with no PyYAML dependency.
ncs_version_from_west() {
  local west="${1:-$(find_repo_root)/west.yml}"
  [[ -f "$west" ]] || { echo "Error: west.yml not found at ${west}" >&2; return 1; }
  local ver
  ver="$(python3 "$(dirname "${BASH_SOURCE[0]}")/ncs-version-refs.py" version "$west")" || {
    echo "Error: could not parse nrf revision from ${west}" >&2
    return 1
  }
  printf '%s\n' "$ver"
}

# find_ncs_refs -> emit `file:lineno:version` for every NCS version literal in
# live tracked files, excluding west.yml (the canonical source) and historical
# records. Python handles wrapped references and reports normalized versions.
find_ncs_refs() {
  python3 "$(dirname "${BASH_SOURCE[0]}")/ncs-version-refs.py" scan "$(find_repo_root)"
}
