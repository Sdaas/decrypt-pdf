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

usage() {
  cat <<'EOF'
Usage: ./release.sh [--dry-run] [-h|--help]

Local pre-flight + tag for decrypt-pdf.

Options:
  --dry-run     Show what would happen; make no tags, pushes, or brew changes.
  -h, --help    Show this help message and exit.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

$DRY_RUN && printf '[dry-run mode — no changes will be made]\n'

run() {
  if $DRY_RUN; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi
}

# --- Step 1: current version from the latest tag ---
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
CURRENT="${LAST_TAG#v}"; CURRENT="${CURRENT:-0.0.0}"
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
printf 'Current version: %s (%s)\n' "${LAST_TAG:-none}" "$CURRENT"

# --- Step 2: analyze commits, suggest bump (lenient + nudge) ---
LOG_RANGE=${LAST_TAG:+$LAST_TAG..HEAD}; LOG_RANGE=${LOG_RANGE:-HEAD}
COMMITS=$(git log "$LOG_RANGE" --oneline 2>/dev/null || true)

# Major: any conventional-commit line marked breaking with `!` before the colon
# (feat!:, fix!:, feat(scope)!: …) or a literal "BREAKING CHANGE". The leading
# `^[a-f0-9]+ ` matches the short-hash prefix that `git log --oneline` emits —
# omitting it (the previous bug) meant no real commit line ever matched, so
# breaking changes silently fell through to a patch bump.
if printf '%s\n' "$COMMITS" | grep -qiE '^[a-f0-9]+ [a-z]+(\(.+\))?!:|BREAKING CHANGE'; then
  SUGGESTED="major"
elif printf '%s\n' "$COMMITS" | grep -qiE '^[a-f0-9]+ feat(\(.+\))?:'; then
  SUGGESTED="minor"
elif printf '%s\n' "$COMMITS" | grep -qiE '^[a-f0-9]+ fix(\(.+\))?:'; then
  SUGGESTED="patch"
else
  SUGGESTED="patch"
  printf 'WARNING: no feat:/fix: commits since %s; defaulting to a patch bump.\n' "${LAST_TAG:-repo start}"
fi

printf '\n'
printf 'Commits since %s:\n' "${LAST_TAG:-repo start}"
if [[ -z "$COMMITS" ]]; then
  printf '  (none)\n'
else
  printf '%s\n' "$COMMITS" | sed 's/^/  /'
fi
printf '\n'
printf 'Suggested bump: %s\n' "$SUGGESTED"

# --- Step 3: confirm bump ---
read -rp "Bump type? [major/minor/patch] (default=$SUGGESTED): " BUMP_INPUT
BUMP="${BUMP_INPUT:-$SUGGESTED}"
case "$BUMP" in
  major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
  minor) NEW_VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
  patch) NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
  *) printf "ERROR: unknown bump type '%s'\n" "$BUMP" >&2; exit 1 ;;
esac
printf 'New version will be: %s\n' "$NEW_VERSION"

# --- Step 4: local quality gates ---
printf '\n'
printf '==> Running tests\n'
run ./run-tests.sh

if command -v brew >/dev/null 2>&1; then
  printf '==> Running brew gates against the current formula\n'
  run brew style "$FORMULA_TAP" || true
  run brew audit --strict "$FORMULA_TAP" || true
  run brew install --build-from-source "$FORMULA_TAP" || true
  run brew test "$FORMULA_TAP" || true
else
  printf 'WARNING: brew not found; skipping brew gates.\n'
fi

read -rp "Gates done. Release v$NEW_VERSION (tag + push)? [y/N]: " CONFIRM
[[ "$(printf '%s' "$CONFIRM" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { printf 'Aborted.\n'; exit 0; }

# --- Step 5: tag + push. Stops here; CI takes over. ---
printf '\n'
run git push origin main
run git tag "v$NEW_VERSION"
run git push origin "v$NEW_VERSION"

printf '\n'
printf '==> Tagged v%s and pushed. release.yml will now update the tap.\n' "$NEW_VERSION"
