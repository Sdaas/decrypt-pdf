#!/usr/bin/env bash
#
# decrypt-pdfs_test.sh — Tests for the batch decryptor decrypt-pdfs
#
# These are integration tests: decrypt-pdfs orchestrates the real sibling
# decrypt-pdf engine, so the suite drives both together against synthetic,
# self-generated encrypted PDFs (no customer files, no secret passwords).
# Tests that actually decrypt are guarded on qpdf being installed.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
readonly BATCH_SCRIPT="${SCRIPT_DIR}/decrypt-pdfs"

readonly FIXTURE_PASSWORD="s3cret"

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "\033[0;32m  PASS\033[0m $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "\033[0;31m  FAIL\033[0m $1"
}

assert_exit_code() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        pass "$description"
    else
        fail "$description (expected exit=$expected, got exit=$actual)"
    fi
}

# ---------------------------------------------------------------------------
# Fixture builders (duplicated from decrypt-pdf_test.sh so this suite is
# self-contained). See that file for the rationale behind the incompressible
# payload and byte-accurate xref table.
# ---------------------------------------------------------------------------
make_plain_pdf() {
    local dest="$1"
    local payload="${dest}.payload"
    head -c 40000 /dev/urandom > "$payload"
    local plen
    plen="$(wc -c < "$payload")"

    printf '%%PDF-1.4\n' > "$dest"
    local off1 off2 off3 off4 xref_off
    off1="$(wc -c < "$dest")"
    printf '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n' >> "$dest"
    off2="$(wc -c < "$dest")"
    printf '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n' >> "$dest"
    off3="$(wc -c < "$dest")"
    printf '3 0 obj<</Type/Page/MediaBox[0 0 612 792]/Parent 2 0 R/Contents 4 0 R/Resources<<>>>>endobj\n' >> "$dest"
    off4="$(wc -c < "$dest")"
    # shellcheck disable=SC2129
    printf '4 0 obj<</Length %s>>stream\n' "$plen" >> "$dest"
    cat "$payload" >> "$dest"
    printf '\nendstream\nendobj\n' >> "$dest"

    xref_off="$(wc -c < "$dest")"
    {
        printf 'xref\n0 5\n'
        printf '0000000000 65535 f \n'
        printf '%010d 00000 n \n' "$off1" "$off2" "$off3" "$off4"
        printf 'trailer<</Size 5/Root 1 0 R>>\n'
        printf 'startxref\n%s\n' "$xref_off"
        printf '%%%%EOF\n'
    } >> "$dest"
    rm -f "$payload"
}

make_encrypted_pdf() {
    local dest="$1" password="$2"
    local plain="${dest}.plain"
    make_plain_pdf "$plain"
    qpdf --encrypt "$password" "$password" 256 -- "$plain" "$dest" 2>/dev/null \
        || [[ $? -eq 3 ]]
    rm -f "$plain"
}

# Is $1 an unencrypted PDF? (via qpdf)
is_plain_pdf() {
    qpdf --show-encryption "$1" 2>&1 | grep -q "File is not encrypted"
}

need_qpdf() {
    if ! command -v qpdf &>/dev/null; then
        echo "  SKIP (qpdf not installed)"
        return 1
    fi
    return 0
}

# Each test runs inside its own mktemp -d workspace under /tmp.
new_workspace() { mktemp -d /tmp/test_decryptpdfs.XXXXXX; }

cleanup_tmp_files() { rm -rf /tmp/test_decryptpdfs.*; }

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
test_help() {
    echo "--- Test: --help ---"
    local output rc=0
    output="$(bash "$BATCH_SCRIPT" --help 2>&1)" || rc=$?
    assert_exit_code "B1: --help exits 0" 0 "$rc"
    echo "$output" | grep -q "Usage:"        && pass "B1: help has Usage:"        || fail "B1: help missing Usage:"
    echo "$output" | grep -q -- "--recursive" && pass "B1: help documents --recursive" || fail "B1: help missing --recursive"
    echo "$output" | grep -q -- "--cleanup"   && pass "B1: help documents --cleanup"   || fail "B1: help missing --cleanup"
}

test_missing_password() {
    echo "--- Test: no password (non-dry-run) ---"
    local work rc=0
    work="$(new_workspace)"
    # shellcheck disable=SC1007
    DECRYPT_PASSWORD= bash "$BATCH_SCRIPT" "$work" >/dev/null 2>&1 || rc=$?
    assert_exit_code "B2: missing password exits 2" 2 "$rc"
    rm -rf "$work"
}

test_not_a_directory() {
    echo "--- Test: target is not a directory ---"
    local rc=0
    bash "$BATCH_SCRIPT" -p pw /tmp/test_decryptpdfs_nope_dir >/dev/null 2>&1 || rc=$?
    assert_exit_code "B3: non-directory target exits 2" 2 "$rc"
}

test_empty_directory() {
    echo "--- Test: empty directory ---"
    local work rc=0
    work="$(new_workspace)"
    bash "$BATCH_SCRIPT" -p pw "$work" >/dev/null 2>&1 || rc=$?
    assert_exit_code "B4: empty directory exits 0" 0 "$rc"
    rm -rf "$work"
}

test_happy_path() {
    echo "--- Test: happy path (2 encrypted + 1 plain) ---"
    need_qpdf || return
    local work rc=0
    work="$(new_workspace)"
    make_encrypted_pdf "$work/a.pdf" "$FIXTURE_PASSWORD"
    make_encrypted_pdf "$work/b.pdf" "$FIXTURE_PASSWORD"
    make_plain_pdf     "$work/c.pdf"

    bash "$BATCH_SCRIPT" -p "$FIXTURE_PASSWORD" "$work" >/dev/null 2>&1 || rc=$?
    assert_exit_code "B5: happy path exits 0" 0 "$rc"

    if [[ -f "$work/a_decrypted.pdf" ]] && is_plain_pdf "$work/a_decrypted.pdf" \
       && [[ -f "$work/b_decrypted.pdf" ]] && is_plain_pdf "$work/b_decrypted.pdf"; then
        pass "B5: both encrypted files decrypted"
    else
        fail "B5: expected decrypted outputs missing or still encrypted"
    fi
    # The plain file must not have produced a spurious output.
    if [[ ! -f "$work/c_decrypted.pdf" ]]; then
        pass "B5: plain file was skipped"
    else
        fail "B5: plain file was decrypted unexpectedly"
    fi
    rm -rf "$work"
}

test_wrong_password() {
    echo "--- Test: wrong password ---"
    need_qpdf || return
    local work rc=0
    work="$(new_workspace)"
    make_encrypted_pdf "$work/a.pdf" "$FIXTURE_PASSWORD"

    bash "$BATCH_SCRIPT" -p "totally_wrong_pw" "$work" >/dev/null 2>&1 || rc=$?
    assert_exit_code "B6: wrong password exits 1" 1 "$rc"
    if [[ ! -f "$work/a_decrypted.pdf" ]]; then
        pass "B6: no decrypted output on failure"
    else
        fail "B6: decrypted output created despite wrong password"
    fi
    rm -rf "$work"
}

test_multiple_passwords() {
    echo "--- Test: multiple passwords, second is correct ---"
    need_qpdf || return
    local work rc=0
    work="$(new_workspace)"
    make_encrypted_pdf "$work/a.pdf" "$FIXTURE_PASSWORD"

    bash "$BATCH_SCRIPT" -p "wrong_one" -p "$FIXTURE_PASSWORD" "$work" >/dev/null 2>&1 || rc=$?
    assert_exit_code "B7: correct second password exits 0" 0 "$rc"
    if [[ -f "$work/a_decrypted.pdf" ]] && is_plain_pdf "$work/a_decrypted.pdf"; then
        pass "B7: decrypted with the second candidate password"
    else
        fail "B7: expected decrypted output missing"
    fi
    rm -rf "$work"
}

test_cleanup_passthrough() {
    echo "--- Test: --cleanup passthrough ---"
    need_qpdf || return
    local work rc=0
    work="$(new_workspace)"
    make_encrypted_pdf "$work/a.pdf" "$FIXTURE_PASSWORD"

    bash "$BATCH_SCRIPT" --cleanup -p "$FIXTURE_PASSWORD" "$work" >/dev/null 2>&1 || rc=$?
    assert_exit_code "B8: --cleanup exits 0" 0 "$rc"

    if [[ -f "$work/originals/a.pdf" ]] && [[ -f "$work/a.pdf" ]] \
       && is_plain_pdf "$work/a.pdf" && [[ ! -f "$work/a_decrypted.pdf" ]]; then
        pass "B8: original archived and name.pdf holds the decrypted PDF"
    else
        fail "B8: --cleanup did not archive/promote as expected"
    fi
    rm -rf "$work"
}

test_dry_run() {
    echo "--- Test: --dry-run writes nothing and needs no password ---"
    need_qpdf || return
    local work output rc=0
    work="$(new_workspace)"
    make_encrypted_pdf "$work/a.pdf" "$FIXTURE_PASSWORD"

    # No -p and no DECRYPT_PASSWORD: dry-run must not require one.
    output="$(bash "$BATCH_SCRIPT" --dry-run "$work" 2>&1)" || rc=$?
    assert_exit_code "B9: --dry-run exits 0 without a password" 0 "$rc"
    if [[ ! -f "$work/a_decrypted.pdf" ]] && [[ ! -d "$work/originals" ]]; then
        pass "B9: dry-run wrote nothing"
    else
        fail "B9: dry-run modified the filesystem"
    fi
    if echo "$output" | grep -qi "would decrypt"; then
        pass "B9: dry-run reports intended action"
    else
        fail "B9: dry-run did not report intended action"
    fi
    rm -rf "$work"
}

test_recursive() {
    echo "--- Test: --recursive ---"
    need_qpdf || return
    local work rc=0
    work="$(new_workspace)"
    mkdir -p "$work/sub"
    make_encrypted_pdf "$work/sub/deep.pdf" "$FIXTURE_PASSWORD"

    # Without -r, the nested file is not found -> nothing decrypted, exit 0.
    bash "$BATCH_SCRIPT" -p "$FIXTURE_PASSWORD" "$work" >/dev/null 2>&1 || rc=$?
    assert_exit_code "B10: non-recursive ignores subdirs (exit 0)" 0 "$rc"
    if [[ ! -f "$work/sub/deep_decrypted.pdf" ]]; then
        pass "B10: nested file skipped without -r"
    else
        fail "B10: nested file decrypted without -r"
    fi

    # With -r, it is decrypted.
    rc=0
    bash "$BATCH_SCRIPT" -r -p "$FIXTURE_PASSWORD" "$work" >/dev/null 2>&1 || rc=$?
    assert_exit_code "B10: recursive run exits 0" 0 "$rc"
    if [[ -f "$work/sub/deep_decrypted.pdf" ]] && is_plain_pdf "$work/sub/deep_decrypted.pdf"; then
        pass "B10: nested file decrypted with -r"
    else
        fail "B10: nested file not decrypted with -r"
    fi
    rm -rf "$work"
}

test_skip_existing_outputs_and_originals() {
    echo "--- Test: skips *_decrypted.pdf and prunes originals/ ---"
    need_qpdf || return
    local work rc=0
    work="$(new_workspace)"
    make_encrypted_pdf "$work/a.pdf" "$FIXTURE_PASSWORD"
    # A leftover decrypted output and an archived original that must be ignored.
    make_plain_pdf "$work/old_decrypted.pdf"
    mkdir -p "$work/originals"
    make_encrypted_pdf "$work/originals/archived.pdf" "$FIXTURE_PASSWORD"

    bash "$BATCH_SCRIPT" -p "$FIXTURE_PASSWORD" "$work" >/dev/null 2>&1 || rc=$?
    assert_exit_code "B11: run exits 0" 0 "$rc"
    if [[ ! -f "$work/originals/archived_decrypted.pdf" ]] \
       && [[ ! -f "$work/old_decrypted_decrypted.pdf" ]]; then
        pass "B11: originals/ pruned and *_decrypted.pdf skipped"
    else
        fail "B11: processed a file it should have skipped"
    fi
    rm -rf "$work"
}

test_env_password() {
    echo "--- Test: DECRYPT_PASSWORD fallback ---"
    need_qpdf || return
    local work rc=0
    work="$(new_workspace)"
    make_encrypted_pdf "$work/a.pdf" "$FIXTURE_PASSWORD"

    DECRYPT_PASSWORD="$FIXTURE_PASSWORD" bash "$BATCH_SCRIPT" "$work" >/dev/null 2>&1 || rc=$?
    assert_exit_code "B12: env password exits 0" 0 "$rc"
    [[ -f "$work/a_decrypted.pdf" ]] && pass "B12: decrypted via env password" \
                                     || fail "B12: env password did not decrypt"
    rm -rf "$work"
}

test_spaces_in_filenames() {
    echo "--- Test: spaces in filenames ---"
    need_qpdf || return
    local work rc=0
    work="$(new_workspace)"
    make_encrypted_pdf "$work/my statement.pdf" "$FIXTURE_PASSWORD"

    bash "$BATCH_SCRIPT" -p "$FIXTURE_PASSWORD" "$work" >/dev/null 2>&1 || rc=$?
    assert_exit_code "B13: spaced filename exits 0" 0 "$rc"
    if [[ -f "$work/my statement_decrypted.pdf" ]] && is_plain_pdf "$work/my statement_decrypted.pdf"; then
        pass "B13: file with spaces decrypted"
    else
        fail "B13: file with spaces not handled"
    fi
    rm -rf "$work"
}

test_version() {
    echo "--- Test: --version ---"
    local output rc=0
    output="$(bash "$BATCH_SCRIPT" --version 2>&1)" || rc=$?
    assert_exit_code "B14: --version exits 0" 0 "$rc"
    echo "$output" | grep -q "decrypt-pdfs" && pass "B14: version output names the tool" \
                                            || fail "B14: version output missing tool name"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
main() {
    echo "========================================="
    echo " decrypt-pdfs — Test Suite"
    echo "========================================="
    echo ""

    cleanup_tmp_files

    test_help
    test_missing_password
    test_not_a_directory
    test_empty_directory
    test_happy_path
    test_wrong_password
    test_multiple_passwords
    test_cleanup_passthrough
    test_dry_run
    test_recursive
    test_skip_existing_outputs_and_originals
    test_env_password
    test_spaces_in_filenames
    test_version

    cleanup_tmp_files

    echo ""
    echo "========================================="
    echo " Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
    echo "========================================="

    [[ "$FAIL_COUNT" -gt 0 ]] && exit 1
    exit 0
}

main "$@"
