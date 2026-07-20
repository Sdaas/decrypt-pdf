#!/usr/bin/env bash
# release.sh — local pre-flight + tag for decrypt-pdf.
#
# Usage: ./release.sh [--dry-run]
#
# What it does (and only this):
#   1. Reads the current version from the latest git tag.
#   2. Analyzes commits since that tag and SUGGESTS a SemVer bump.
#   3. Prompts you to confirm or override the bump.
#   4. Runs local quality gates (shell tests + brew audit/style/install/test).
#   5. Tags vX.Y.Z and pushes main + the tag.
#
# The git tag IS the version source of truth — there is no file to bump. The
# release workflow stamps the tag version into the script's VERSION placeholder
# when it renders the formula. This script STOPS after pushing the tag; that
# push triggers .github/workflows/release.yml, which updates the tap. This
# script never touches the tap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
FORMULA_TAP="sdaas/tools/decrypt-pdf"   # installed formula name, for brew gates
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

$DRY_RUN && echo "[dry-run mode — no changes will be made]"

run() {
  if $DRY_RUN; then echo "  [dry-run] $*"; else "$@"; fi
}

# --- Step 1: current version from the latest tag ---
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
CURRENT="${LAST_TAG#v}"; CURRENT="${CURRENT:-0.0.0}"
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
echo "Current version: ${LAST_TAG:-none} ($CURRENT)"

# --- Step 2: analyze commits, suggest bump (lenient + nudge) ---
LOG_RANGE=${LAST_TAG:+$LAST_TAG..HEAD}; LOG_RANGE=${LOG_RANGE:-HEAD}
COMMITS=$(git log "$LOG_RANGE" --oneline 2>/dev/null || echo "")

if echo "$COMMITS" | grep -qiE '(^|:)\s*(feat!|.*BREAKING CHANGE)'; then
  SUGGESTED="major"
elif echo "$COMMITS" | grep -qiE '^[a-f0-9]+ feat(\(.+\))?:'; then
  SUGGESTED="minor"
elif echo "$COMMITS" | grep -qiE '^[a-f0-9]+ fix(\(.+\))?:'; then
  SUGGESTED="patch"
else
  SUGGESTED="patch"
  echo "WARNING: no feat:/fix: commits since ${LAST_TAG:-repo start}; defaulting to a patch bump."
fi

echo ""
echo "Commits since ${LAST_TAG:-repo start}:"
[[ -z "$COMMITS" ]] && echo "  (none)" || echo "$COMMITS" | sed 's/^/  /'
echo ""
echo "Suggested bump: $SUGGESTED"

# --- Step 3: confirm bump ---
read -rp "Bump type? [major/minor/patch] (default=$SUGGESTED): " BUMP_INPUT
BUMP="${BUMP_INPUT:-$SUGGESTED}"
case "$BUMP" in
  major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
  minor) NEW_VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
  patch) NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
  *) echo "ERROR: unknown bump type '$BUMP'"; exit 1 ;;
esac
echo "New version will be: $NEW_VERSION"

# --- Step 4: local quality gates ---
echo ""
echo "==> Running tests"
run ./test-decrypt-pdf.sh

if command -v brew >/dev/null 2>&1; then
  echo "==> Running brew gates against the current formula"
  run brew style "$FORMULA_TAP" || true
  run brew audit --strict "$FORMULA_TAP" || true
  run brew install --build-from-source "$FORMULA_TAP" || true
  run brew test "$FORMULA_TAP" || true
else
  echo "WARNING: brew not found; skipping brew gates."
fi

read -rp "Gates done. Release v$NEW_VERSION (tag + push)? [y/N]: " CONFIRM
[[ "$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { echo "Aborted."; exit 0; }

# --- Step 5: tag + push. Stops here; CI takes over. ---
echo ""
run git push origin main
run git tag "v$NEW_VERSION"
run git push origin "v$NEW_VERSION"

echo ""
echo "==> Tagged v$NEW_VERSION and pushed. release.yml will now update the tap."
