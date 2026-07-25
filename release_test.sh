#!/usr/bin/env bash
#
# release_test.sh — Characterization tests for release.sh
#
# These pin release.sh's CURRENT behavior (a safety net, not a spec). Every
# test drives release.sh with --dry-run inside a throwaway git repo, so no real
# tag, push, or brew command ever runs. release.sh cd's to its own directory
# (SCRIPT_DIR), so copying it into a temp repo makes it operate on that repo's
# controlled git history — giving us deterministic version-bump output to assert.
#
# NOTE: test_feat_bang_bump pins a KNOWN BUG — a breaking `feat!:` commit is
# currently suggested as a MINOR bump instead of MAJOR. When that bug is fixed,
# this test will go red; update the expected value to "major" at that point.

set -uo pipefail   # NOT -e: assertions handle their own failures

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
readonly RELEASE_SCRIPT="${SCRIPT_DIR}/release.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "\033[0;32m  PASS\033[0m $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "\033[0;31m  FAIL\033[0m $1"; }

# assert_contains DESC HAYSTACK NEEDLE
assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        fail "$desc (missing: '${needle}')"
    fi
}

# assert_exit_code DESC EXPECTED ACTUAL
assert_exit_code() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc (expected exit=$expected, got exit=$actual)"
    fi
}

# ---------------------------------------------------------------------------
# Build a throwaway git repo containing a copy of release.sh plus a stub test
# runner. Commits/tags are created per-test to control the version-bump logic.
# Echoes the repo path on stdout.
# ---------------------------------------------------------------------------
make_repo() {
    local repo
    repo="$(mktemp -d /tmp/test_release_XXXXXX)"
    cp "$RELEASE_SCRIPT" "$repo/release.sh"
    chmod +x "$repo/release.sh"
    # Stub runner so step 4's `run ./run-tests.sh` has something to name; under
    # --dry-run it is only echoed, never executed, so the stub can be trivial.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/run-tests.sh"
    chmod +x "$repo/run-tests.sh"
    (
        cd "$repo" || exit 1
        git init -q
        git config user.email test@example.com
        git config user.name  test
        git config commit.gpgsign false
    )
    echo "$repo"
}

# commit REPO MESSAGE — create an empty commit with the given message.
commit() {
    git -C "$1" commit -q --allow-empty -m "$2"
}

# run_release REPO STDIN_ANSWERS -- runs release.sh --dry-run with answers piped
# to its interactive prompts. Echoes combined stdout+stderr; sets global RC.
RC=0
run_release() {
    local repo="$1" answers="$2"
    local out
    out="$(cd "$repo" && printf '%s' "$answers" | ./release.sh --dry-run 2>&1)"
    RC=$?
    echo "$out"
}

cleanup_tmp_files() { rm -rf /tmp/test_release_*; }

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# No tags, a plain commit → defaults to a patch bump (0.0.0 -> 0.0.1) and warns.
test_no_tag_defaults_patch() {
    echo "--- Test: no tag, plain commit → patch ---"
    local repo out
    repo="$(make_repo)"
    commit "$repo" "initial commit"
    out="$(run_release "$repo" $'\n\n')"   # accept suggested bump, then abort at confirm
    assert_contains "current version reported as none/0.0.0" "$out" "Current version: none (0.0.0)"
    assert_contains "suggests patch" "$out" "Suggested bump: patch"
    assert_contains "warns about no feat/fix commits" "$out" "WARNING: no feat:/fix: commits"
    assert_contains "new version 0.0.1" "$out" "New version will be: 0.0.1"
    rm -rf "$repo"
}

# fix: commit → patch bump.
test_fix_commit_patch() {
    echo "--- Test: fix: commit → patch ---"
    local repo out
    repo="$(make_repo)"
    commit "$repo" "fix: correct a thing"
    out="$(run_release "$repo" $'\n\n')"
    assert_contains "suggests patch" "$out" "Suggested bump: patch"
    assert_contains "new version 0.0.1" "$out" "New version will be: 0.0.1"
    rm -rf "$repo"
}

# feat: commit → minor bump.
test_feat_commit_minor() {
    echo "--- Test: feat: commit → minor ---"
    local repo out
    repo="$(make_repo)"
    commit "$repo" "feat: add a thing"
    out="$(run_release "$repo" $'\n\n')"
    assert_contains "suggests minor" "$out" "Suggested bump: minor"
    assert_contains "new version 0.1.0" "$out" "New version will be: 0.1.0"
    rm -rf "$repo"
}

# feat!: breaking commit → major bump. (Previously a bug suggested patch here;
# the fixed regex now accounts for the git-log hash prefix and the `!` marker.)
test_feat_bang_bump() {
    echo "--- Test: feat!: breaking commit → major ---"
    local repo out
    repo="$(make_repo)"
    commit "$repo" "feat!: breaking redesign"
    out="$(run_release "$repo" $'\n\n')"
    assert_contains "suggests major" "$out" "Suggested bump: major"
    rm -rf "$repo"
}

# feat(scope)!: breaking commit with a scope → also major.
test_scoped_bang_bump() {
    echo "--- Test: feat(api)!: scoped breaking commit → major ---"
    local repo out
    repo="$(make_repo)"
    commit "$repo" "feat(api)!: rework interface"
    out="$(run_release "$repo" $'\n\n')"
    assert_contains "suggests major" "$out" "Suggested bump: major"
    rm -rf "$repo"
}

# Existing v1.2.3 tag + a feat commit → minor bump to 1.3.0.
test_existing_tag_minor() {
    echo "--- Test: existing tag v1.2.3 + feat → 1.3.0 ---"
    local repo out
    repo="$(make_repo)"
    commit "$repo" "initial"
    git -C "$repo" tag v1.2.3
    commit "$repo" "feat: another thing"
    out="$(run_release "$repo" $'\n\n')"
    assert_contains "current version v1.2.3" "$out" "Current version: v1.2.3 (1.2.3)"
    assert_contains "suggests minor" "$out" "Suggested bump: minor"
    assert_contains "new version 1.3.0" "$out" "New version will be: 1.3.0"
    rm -rf "$repo"
}

# User overrides the suggested bump at the prompt (types "major").
test_override_bump() {
    echo "--- Test: user overrides suggested bump → major ---"
    local repo out
    repo="$(make_repo)"
    commit "$repo" "fix: small fix"          # would suggest patch
    out="$(run_release "$repo" $'major\n\n')" # override to major
    assert_contains "new version 1.0.0 from override" "$out" "New version will be: 1.0.0"
    rm -rf "$repo"
}

# --dry-run must NOT create a real tag or push anything.
test_dry_run_no_tag_created() {
    echo "--- Test: --dry-run creates no tag ---"
    local repo before after out
    repo="$(make_repo)"
    commit "$repo" "feat: thing"
    before="$(git -C "$repo" tag -l | wc -l | tr -d ' ')"
    out="$(run_release "$repo" $'patch\ny\n')"   # confirm the release
    after="$(git -C "$repo" tag -l | wc -l | tr -d ' ')"
    if [[ "$before" == "$after" ]]; then
        pass "no new tag created under --dry-run (before=$before after=$after)"
    else
        fail "tag count changed under --dry-run (before=$before after=$after)"
    fi
    assert_contains "dry-run echoes the tag command" "$out" "[dry-run] git tag"
    rm -rf "$repo"
}

# Empty confirm answer aborts cleanly with exit 0.
test_abort_on_empty_confirm() {
    echo "--- Test: empty confirm answer aborts (exit 0) ---"
    local repo out
    repo="$(make_repo)"
    commit "$repo" "feat: thing"
    out="$(run_release "$repo" $'\n\n')"
    assert_exit_code "aborts with exit 0" 0 "$RC"
    assert_contains "prints Aborted" "$out" "Aborted."
    rm -rf "$repo"
}

# Unknown argument → exit 1.
test_unknown_arg() {
    echo "--- Test: unknown argument → exit 1 ---"
    local repo out
    repo="$(make_repo)"
    commit "$repo" "initial"
    out="$(cd "$repo" && ./release.sh --bogus 2>&1)"; local rc=$?
    assert_exit_code "unknown arg exits 1" 1 "$rc"
    assert_contains "reports unknown argument" "$out" "Unknown argument"
    rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
main() {
    echo "========================================="
    echo " release.sh — Characterization Suite"
    echo "========================================="
    echo ""

    cleanup_tmp_files

    test_no_tag_defaults_patch
    test_fix_commit_patch
    test_feat_commit_minor
    test_feat_bang_bump
    test_scoped_bang_bump
    test_existing_tag_minor
    test_override_bump
    test_dry_run_no_tag_created
    test_abort_on_empty_confirm
    test_unknown_arg

    cleanup_tmp_files

    echo ""
    echo "========================================="
    echo " Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
    echo "========================================="
    [[ "$FAIL_COUNT" -gt 0 ]] && exit 1
    exit 0
}

main "$@"
