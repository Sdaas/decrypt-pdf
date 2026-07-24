#!/usr/bin/env bash
#
# test-decrypt-pdf.sh — Tests for decrypt-pdf
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly DECRYPT_SCRIPT="${SCRIPT_DIR}/decrypt-pdf"

# All decryption tests run against synthetic fixtures generated at runtime
# (see make_encrypted_pdf) so the suite is self-contained and needs no
# customer-supplied files or secret passwords.
readonly FIXTURE_PASSWORD="s3cret"

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
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
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        pass "$description"
    else
        fail "$description (expected exit=$expected, got exit=$actual)"
    fi
}

# Write a valid unencrypted PDF to $1 with a large, incompressible content
# stream. Two things matter:
#   * Incompressible payload — qpdf compresses low-entropy data, which would
#     shrink the encrypted fixture below the script's size-based sanity check
#     and make wrong-password failures indistinguishable from success. ~40 KB of
#     /dev/urandom keeps encrypted fixtures realistically sized (like a real PDF).
#   * A correct xref table with byte-accurate offsets — this lets qpdf read the
#     file normally instead of entering recovery mode, where it would rescan the
#     whole file for object markers and could be tripped up by random bytes that
#     happen to look like PDF tokens (a source of flaky failures).
make_plain_pdf() {
    local dest="$1"
    local payload="${dest}.payload"
    head -c 40000 /dev/urandom > "$payload"
    local plen
    plen="$(wc -c < "$payload")"

    # Emit the body, capturing each object's byte offset for the xref table.
    # The separate appends are deliberate: we measure the file size between them
    # to record offsets, so they can't be collapsed into one redirect.
    printf '%%PDF-1.4\n' > "$dest"
    local off1 off2 off3 off4 xref_off
    off1="$(wc -c < "$dest")"
    printf '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n' >> "$dest"
    off2="$(wc -c < "$dest")"
    printf '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n' >> "$dest"
    off3="$(wc -c < "$dest")"
    printf '3 0 obj<</Type/Page/MediaBox[0 0 612 792]/Parent 2 0 R/Contents 4 0 R/Resources<<>>>>endobj\n' >> "$dest"
    off4="$(wc -c < "$dest")"
    # shellcheck disable=SC2129  # grouped with the following stream appends
    printf '4 0 obj<</Length %s>>stream\n' "$plen" >> "$dest"
    cat "$payload" >> "$dest"
    printf '\nendstream\nendobj\n' >> "$dest"

    # xref entries are exactly 20 bytes: "NNNNNNNNNN GGGGG n \n".
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

# Generate a synthetic AES-256 encrypted PDF at $1 protected by password $2.
# Requires qpdf; callers must guard on its availability.
make_encrypted_pdf() {
    local dest="$1" password="$2"
    local plain="${dest}.plain"
    make_plain_pdf "$plain"
    # qpdf normally exits 0 for our valid fixture; tolerate exit 3 ("succeeded
    # with warnings") defensively and hush any cosmetic warnings.
    qpdf --encrypt "$password" "$password" 256 -- "$plain" "$dest" 2>/dev/null \
        || [[ $? -eq 3 ]]
    rm -f "$plain"
}

cleanup_tmp_files() {
    # Broad globs so intermediate fixture files (.pdf, .bak, .plain, .payload)
    # are removed even if a fixture build aborts mid-test.
    rm -f /tmp/test_decrypt_*
    rm -f /tmp/test_unencrypted*
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
test_help_flag() {
    echo "--- Test: --help prints usage ---"
    local output
    output="$(bash "$DECRYPT_SCRIPT" --help 2>&1)"
    local rc=$?
    assert_exit_code "--help exits with 0" 0 "$rc"

    if echo "$output" | grep -q "Usage:"; then
        pass "--help output contains Usage:"
    else
        fail "--help output missing Usage:"
    fi

    if echo "$output" | grep -q "\-p PASSWORD"; then
        pass "--help output documents -p flag"
    else
        fail "--help output missing -p flag documentation"
    fi
}

test_missing_password() {
    echo "--- Test: missing password ---"
    local input="/tmp/test_decrypt_missingpw_in.pdf"
    make_plain_pdf "$input"
    local rc=0
    DECRYPT_PASSWORD= bash "$DECRYPT_SCRIPT" "$input" >/dev/null 2>&1 || rc=$?
    assert_exit_code "Missing -p flag exits with 1" 1 "$rc"
    rm -f "$input"
}

test_missing_input_file() {
    echo "--- Test: missing input file ---"
    local rc=0
    bash "$DECRYPT_SCRIPT" -p "test" >/dev/null 2>&1 || rc=$?
    assert_exit_code "Missing input file exits with 1" 1 "$rc"
}

test_nonexistent_file() {
    echo "--- Test: nonexistent input file ---"
    local rc=0
    bash "$DECRYPT_SCRIPT" -p "test" /tmp/nonexistent_file.pdf >/dev/null 2>&1 || rc=$?
    assert_exit_code "Nonexistent file exits with 1" 1 "$rc"
}

test_non_pdf_file() {
    echo "--- Test: non-PDF file ---"
    echo "this is not a pdf" > /tmp/test_decrypt_not_a.pdf
    local rc=0
    bash "$DECRYPT_SCRIPT" -p "test" /tmp/test_decrypt_not_a.pdf >/dev/null 2>&1 || rc=$?
    assert_exit_code "Non-PDF file exits with 1" 1 "$rc"
    rm -f /tmp/test_decrypt_not_a.pdf
}

test_already_unencrypted() {
    echo "--- Test: already unencrypted file ---"
    if ! command -v qpdf &>/dev/null; then
        echo "  SKIP (qpdf not installed)"
        return
    fi

    # Create an unencrypted PDF with a minimal valid structure
    # Using qpdf to create from the test pdf if we can decrypt it first,
    # or just use a simple approach
    local unenc="/tmp/test_unencrypted_input.pdf"
    # Create a minimal valid PDF
    cat > "$unenc" <<'MINPDF'
%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/MediaBox[0 0 612 792]/Parent 2 0 R>>endobj
xref
0 4
0000000000 65535 f
0000000009 00000 n
0000000058 00000 n
0000000115 00000 n
trailer<</Size 4/Root 1 0 R>>
startxref
190
%%EOF
MINPDF

    local output rc=0
    output="$(bash "$DECRYPT_SCRIPT" -p "test" "$unenc" /tmp/test_unencrypted_out.pdf 2>&1)" || rc=$?
    assert_exit_code "Unencrypted file exits with 0" 0 "$rc"

    if echo "$output" | grep -q "not encrypted"; then
        pass "Reports file is not encrypted"
    else
        fail "Should report file is not encrypted"
    fi

    rm -f "$unenc" /tmp/test_unencrypted_out.pdf "${unenc}.bak"
}

test_successful_decryption() {
    echo "--- Test: successful decryption ---"
    if ! command -v qpdf &>/dev/null; then
        echo "  SKIP (qpdf not installed)"
        return
    fi

    local enc="/tmp/test_decrypt_success.pdf"
    make_encrypted_pdf "$enc" "$FIXTURE_PASSWORD"

    local output_file="/tmp/test_decrypt_success_out.pdf"
    local rc=0
    bash "$DECRYPT_SCRIPT" -p "$FIXTURE_PASSWORD" "$enc" "$output_file" 2>&1 || rc=$?
    assert_exit_code "Decryption exits with 0" 0 "$rc"

    if [[ -f "$output_file" ]]; then
        pass "Output file created"
    else
        fail "Output file not created"
        rm -f "$enc" "${enc}.bak"
        return
    fi

    # Verify the output is not encrypted
    local enc_check
    enc_check="$(qpdf --show-encryption "$output_file" 2>&1)" || true
    if echo "$enc_check" | grep -q "File is not encrypted"; then
        pass "Output file is not encrypted"
    else
        fail "Output file still appears encrypted"
    fi

    rm -f "$enc" "$output_file" "${enc}.bak"
}

test_env_var_password() {
    echo "--- Test: DECRYPT_PASSWORD env var fallback ---"
    if ! command -v qpdf &>/dev/null; then
        echo "  SKIP (qpdf not installed)"
        return
    fi

    local enc="/tmp/test_decrypt_envvar_in.pdf"
    make_encrypted_pdf "$enc" "$FIXTURE_PASSWORD"

    local output_file="/tmp/test_decrypt_envvar.pdf"
    local rc=0
    DECRYPT_PASSWORD="$FIXTURE_PASSWORD" bash "$DECRYPT_SCRIPT" "$enc" "$output_file" >/dev/null 2>&1 || rc=$?
    assert_exit_code "Env var password exits with 0" 0 "$rc"

    if [[ -f "$output_file" ]]; then
        pass "Output file created via env var password"
    else
        fail "Output file not created via env var password"
    fi

    rm -f "$enc" "$output_file" "${enc}.bak"
}

test_quiet_mode() {
    echo "--- Test: quiet mode ---"
    if ! command -v qpdf &>/dev/null; then
        echo "  SKIP (qpdf not installed)"
        return
    fi

    local enc="/tmp/test_decrypt_quiet_in.pdf"
    make_encrypted_pdf "$enc" "$FIXTURE_PASSWORD"

    local output_file="/tmp/test_decrypt_quiet.pdf"
    local output rc=0
    output="$(bash "$DECRYPT_SCRIPT" -q -p "$FIXTURE_PASSWORD" "$enc" "$output_file" 2>&1)" || rc=$?

    if [[ -z "$output" ]]; then
        pass "Quiet mode produces no output"
    else
        fail "Quiet mode produced output: ${output}"
    fi

    assert_exit_code "Quiet mode exits with 0" 0 "$rc"
    rm -f "$enc" "$output_file" "${enc}.bak"
}

test_default_output_filename() {
    echo "--- Test: default output filename ---"
    if ! command -v qpdf &>/dev/null; then
        echo "  SKIP (qpdf not installed)"
        return
    fi

    local enc="/tmp/test_decrypt_default.pdf"
    make_encrypted_pdf "$enc" "$FIXTURE_PASSWORD"

    local expected_output="/tmp/test_decrypt_default_decrypted.pdf"
    local rc=0
    bash "$DECRYPT_SCRIPT" -q -p "$FIXTURE_PASSWORD" "$enc" 2>&1 || rc=$?
    assert_exit_code "Default output name exits with 0" 0 "$rc"

    if [[ -f "$expected_output" ]]; then
        pass "Default output file created at expected path"
    else
        fail "Default output file not found at ${expected_output}"
    fi

    rm -f "$enc" "$expected_output" "${enc}.bak"
}

test_verbose_mode() {
    echo "--- Test: verbose mode ---"
    if ! command -v qpdf &>/dev/null; then
        echo "  SKIP (qpdf not installed)"
        return
    fi

    local enc="/tmp/test_decrypt_verbose_in.pdf"
    make_encrypted_pdf "$enc" "$FIXTURE_PASSWORD"

    local output_file="/tmp/test_decrypt_verbose.pdf"
    local output rc=0
    output="$(bash "$DECRYPT_SCRIPT" --verbose -p "$FIXTURE_PASSWORD" "$enc" "$output_file" 2>&1)" || rc=$?
    assert_exit_code "Verbose mode exits with 0" 0 "$rc"

    if echo "$output" | grep -qE "\[DEBUG\]|Running:"; then
        pass "Verbose mode produces debug output"
    else
        fail "Verbose mode missing debug output"
    fi

    rm -f "$enc" "$output_file" "${enc}.bak"
}

test_unknown_flag() {
    echo "--- Test: unknown flag ---"
    local rc=0
    bash "$DECRYPT_SCRIPT" --invalid -p "test" /tmp/nonexistent.pdf >/dev/null 2>&1 || rc=$?
    assert_exit_code "Unknown flag exits with 1" 1 "$rc"
}

test_wrong_password() {
    echo "--- Test: wrong password ---"
    if ! command -v qpdf &>/dev/null; then
        echo "  SKIP (qpdf not installed)"
        return
    fi

    local enc="/tmp/test_decrypt_wrongpw_in.pdf"
    make_encrypted_pdf "$enc" "$FIXTURE_PASSWORD"

    local output_file="/tmp/test_decrypt_wrongpw.pdf"
    local rc=0
    bash "$DECRYPT_SCRIPT" -p "definitely_wrong_password_12345" "$enc" "$output_file" >/dev/null 2>&1 || rc=$?
    assert_exit_code "Wrong password exits with 1" 1 "$rc"

    rm -f "$enc" "$output_file" "${enc}.bak"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
main() {
    echo "========================================="
    echo " decrypt-pdf — Test Suite"
    echo "========================================="
    echo ""

    cleanup_tmp_files

    test_help_flag
    test_missing_password
    test_missing_input_file
    test_nonexistent_file
    test_non_pdf_file
    test_already_unencrypted
    test_successful_decryption
    test_env_var_password
    test_quiet_mode
    test_default_output_filename
    test_verbose_mode
    test_unknown_flag
    test_wrong_password

    cleanup_tmp_files

    echo ""
    echo "========================================="
    echo " Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
    echo "========================================="

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
