#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Bump the NCS version across the repo in one operation.
#
# The single way to move the NCS version: rewrites west.yml's `nrf` revision
# (the canonical source) and every NCS version literal the shared scanner finds
# (README/docs/scripts), and opens a PR. The maintainer updates
# `vars.NCS_VERSION` immediately before merging that PR. The guard
# catches anything this script missed.
#
# Docs "update automatically when the SDK is bumped" by construction: this
# script IS the bump.
#
# `--dry-run` rewrites the files and runs the self-check but skips PR creation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/ncs-version-lib.sh"

REPO_ROOT="$(find_repo_root)"
DRY_RUN=0
REASON_FILE=""

usage() {
  cat <<'EOF'
Usage: bump-ncs.sh <version> [options]

Bump the NCS version across the repo: west.yml's `nrf` revision and every live
NCS literal the scanner finds (README/docs/scripts), then open a PR.

  <version>      Target NCS version, e.g. v3.4.1 (must match vMAJOR.MINOR.PATCH).
  --dry-run      Rewrite files and run the self-check, but skip PR creation.
                 Review with `git diff` and revert with `git restore -- .`.
  --reason-file PATH  Append the reason in PATH to the bump commit body.
  -h, --help     Show this help.
EOF
}

NEW_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --reason-file)
      [[ $# -ge 2 ]] || { echo "Error: --reason-file requires a path" >&2; exit 1; }
      REASON_FILE="$2"
      shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [[ -n "$NEW_VERSION" ]]; then
        echo "Error: only one version may be specified" >&2
        exit 1
      fi
      NEW_VERSION="$1"
      shift ;;
  esac
done

if [[ -z "$NEW_VERSION" ]]; then
  echo "Error: <version> is required" >&2
  usage >&2
  exit 1
fi
if ! [[ "$NEW_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: <version> must match vMAJOR.MINOR.PATCH (got: ${NEW_VERSION})" >&2
  exit 1
fi
if [[ -n "$REASON_FILE" && ! -s "$REASON_FILE" ]]; then
  echo "Error: --reason-file must name a nonempty file" >&2
  exit 1
fi
if [[ -n "$REASON_FILE" ]]; then
  REASON_FILE="$(realpath "$REASON_FILE")"
fi

log() { echo "[bump-ncs] $*"; }

OLD_VERSION="$(ncs_version_from_west)"
if [[ "$NEW_VERSION" == "$OLD_VERSION" ]]; then
  log "west.yml already at ${OLD_VERSION}; nothing to do"
  exit 0
fi

NEW_SEMVER="${NEW_VERSION#v}"
cd "$REPO_ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: working tree must be clean before bumping NCS" >&2
  exit 1
fi
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')"
CURRENT_BRANCH="$(git branch --show-current)"
if [[ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]]; then
  echo "Error: bump must start on default branch ${DEFAULT_BRANCH} (current: ${CURRENT_BRANCH})" >&2
  exit 1
fi
if ! git ls-remote --exit-code --tags https://github.com/nrfconnect/sdk-nrf.git "refs/tags/${NEW_VERSION}" >/dev/null; then
  echo "Error: upstream sdk-nrf tag ${NEW_VERSION} does not exist" >&2
  exit 1
fi
if ! docker manifest inspect "ghcr.io/nrfconnect/sdk-nrf-toolchain:${NEW_VERSION}" >/dev/null; then
  echo "Error: toolchain image for ${NEW_VERSION} does not exist" >&2
  exit 1
fi

log "Bumping NCS ${OLD_VERSION} -> ${NEW_VERSION}"
if ! python3 "${SCRIPT_DIR}/ncs-version-refs.py" rewrite "$REPO_ROOT" "$NEW_VERSION"; then
  git restore --worktree -- .
  exit 1
fi

# Self-check: the guard must pass against the new west.yml. On failure, revert
# the working-tree edits so a half-bump doesn't linger.
log "running guard self-check"
if ! bash "${SCRIPT_DIR}/check-ncs-version.sh"; then
  echo "Error: guard failed after rewrite; some literal was missed." >&2
  git restore --worktree -- .
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run: skipping PR creation"
  log "done (dry-run). Review with: git -C ${REPO_ROOT} diff"
  exit 0
fi

# Commit and open a PR.
BRANCH="fix/bump-ncs-${NEW_SEMVER}"
log "creating branch ${BRANCH}"
git -C "$REPO_ROOT" checkout -b "$BRANCH"
mapfile -d '' -t FILES < <(git diff --name-only -z)
git -C "$REPO_ROOT" add -- "${FILES[@]}"
COMMIT_BODY="Bumps the NCS version across west.yml, CI, docs, and scripts via
scripts/bump-ncs.sh."
if [[ -n "$REASON_FILE" ]]; then
  COMMIT_BODY="${COMMIT_BODY}

$(cat "$REASON_FILE")"
fi
git -C "$REPO_ROOT" commit -m "fix: bump NCS ${OLD_VERSION} -> ${NEW_VERSION}" -m "$COMMIT_BODY"
git -C "$REPO_ROOT" push -u origin "$BRANCH"
gh pr create --title "fix: bump NCS ${OLD_VERSION} -> ${NEW_VERSION}" \
  --body "Bumps NCS ${OLD_VERSION} -> ${NEW_VERSION} via \`scripts/bump-ncs.sh\`.

- west.yml \`nrf\` revision -> ${NEW_VERSION}
- README/docs/script literals -> ${NEW_VERSION}
- Set \`vars.NCS_VERSION\` to ${NEW_VERSION} immediately before merge"
log "done: PR opened on ${BRANCH}"
