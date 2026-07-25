#!/usr/bin/env bash
#
# run-tests.sh — single entry point that runs ALL tests for this repo.
#
# Usage:
#   ./run-tests.sh [-v] [PATH ...]
#
#   -v            verbose: stream each test's output even on success
#   PATH ...      optional dirs/files to limit the run (default: whole repo)
#
# Discovery: every file matching *_test.zsh, *_test.sh, *_test.bash, or *.bats
# under the search paths is treated as a test file and executed with the right
# runner (zsh / bash / bats). A test file "passes" if it exits 0.
#
# Exit codes: 0 = all tests passed; 1 = one or more failed; 2 = usage/setup error.
#
# This script is intentionally portable bash (not zsh) so it runs unchanged in
# CI (GitHub-hosted runners have bash) and in the pre-push hook.
set -euo pipefail

VERBOSE=0
paths=()
while [ $# -gt 0 ]; do
  case "$1" in
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) sed -n '3,15p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) paths+=("$1") ;;
  esac
  shift
done
[ $# -gt 0 ] && paths+=("$@")
[ ${#paths[@]} -eq 0 ] && paths=(".")

# Resolve a runner for a given test file, or empty if the tool is missing.
runner_for() {
  case "$1" in
    *_test.zsh)              command -v zsh  >/dev/null 2>&1 && echo "zsh"  ;;
    *_test.sh|*_test.bash)   command -v bash >/dev/null 2>&1 && echo "bash" ;;
    *.bats)                  command -v bats >/dev/null 2>&1 && echo "bats" ;;
  esac
}

# Collect test files (null-delimited to survive spaces in paths).
files=()
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(find "${paths[@]}" \
           \( -name '*_test.zsh' -o -name '*_test.sh' \
              -o -name '*_test.bash' -o -name '*.bats' \) \
           -type f -print0 | sort -z)

if [ ${#files[@]} -eq 0 ]; then
  echo "no test files found (looked for *_test.zsh, *_test.sh, *_test.bash, *.bats)" >&2
  exit 2
fi

pass=0 fail=0 skip=0
failed_names=()
for f in "${files[@]}"; do
  runner="$(runner_for "$f")"
  if [ -z "$runner" ]; then
    printf 'SKIP - %s (runner not installed)\n' "$f" >&2
    skip=$((skip + 1))
    continue
  fi
  if [ "$VERBOSE" -eq 1 ]; then
    if "$runner" "$f"; then rc=0; else rc=$?; fi
  else
    if out="$("$runner" "$f" 2>&1)"; then rc=0; else rc=$?; fi
  fi
  if [ "$rc" -eq 0 ]; then
    printf 'PASS - %s\n' "$f"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s (exit %d)\n' "$f" "$rc" >&2
    [ "$VERBOSE" -eq 0 ] && printf '%s\n' "${out:-}" >&2
    fail=$((fail + 1))
    failed_names+=("$f")
  fi
done

echo "-----------------------------------------"
printf 'total=%d pass=%d fail=%d skip=%d\n' \
  "$((pass + fail + skip))" "$pass" "$fail" "$skip"
if [ "$fail" -gt 0 ]; then
  printf 'FAILED: %s\n' "${failed_names[*]}" >&2
  exit 1
fi
# A skipped test means a runner is missing — treat as failure in CI to avoid
# silently green builds. Locally (interactive) it's a warning only.
if [ "$skip" -gt 0 ] && [ -n "${CI:-}" ]; then
  echo "FAIL: $skip test file(s) skipped in CI (missing runner)" >&2
  exit 1
fi
echo "all tests passed"
