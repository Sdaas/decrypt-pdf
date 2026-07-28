# decrypt-pdf

A command-line tool that decrypts password-protected PDF files using a cascading
strategy of tools: **qpdf**, **mutool**, and **ghostscript**. It tries each tool
in sequence until one succeeds — so you don't have to remember which tool works
for which PDF.

This is **not** a password cracker. It assumes you already know the password.

## Quick Start

```bash
# 1. Install (Homebrew)
brew tap sdaas/tools && brew install decrypt-pdf

# 2. Decrypt with the password on the command line
decrypt-pdf -p 's3cret' document.pdf

# 3. …or pass the password via an environment variable
DECRYPT_PASSWORD='s3cret' decrypt-pdf document.pdf
```

The decrypted file is written to `document_decrypted.pdf` by default.

## Usage

### Install

Install via the Homebrew tap:

```bash
brew tap sdaas/tools
brew trust sdaas/tools     # optional — only on newer Homebrew (see note)
brew install decrypt-pdf
```

> **Why `brew trust`?** Recent versions of Homebrew require you to explicitly
> **trust** third-party taps before they will install or run formulae, casks, or
> commands from them — a supply-chain safety measure, since a tap can ship
> arbitrary code. Until the tap is trusted, Homebrew *ignores* it and
> `brew install` won't find `decrypt-pdf`. Trust the whole tap with
> `brew trust sdaas/tools`, or just this formula with
> `brew trust --formula sdaas/tools/decrypt-pdf`. If your Homebrew doesn't
> require it, the command is a harmless no-op. (To opt out globally — not
> recommended — set `HOMEBREW_NO_REQUIRE_TAP_TRUST=1`.)

`decrypt-pdf` needs at least one of the underlying tools installed (all three
recommended for the best success rate); Homebrew pulls these in as formula
dependencies, but you can also install them directly:

```bash
brew install qpdf
brew install mupdf-tools
brew install ghostscript
```

### Running the command

```
decrypt-pdf [OPTIONS] [-p PASSWORD] INPUT_FILE [OUTPUT_FILE]
```

`INPUT_FILE` is the encrypted PDF. `OUTPUT_FILE` is optional — it defaults to
`<input>_decrypted.pdf` in the same directory.

**Specifying the password.** The password can be provided two ways, in this
order of precedence:

1. **`-p` flag** (highest priority) — passed on the command line. Simple, but
   visible in `ps` output and shell history.

   ```bash
   decrypt-pdf -p 's3cret' document.pdf
   ```

2. **`DECRYPT_PASSWORD` environment variable** — used as a fallback when `-p`
   is not given. Keeps the password off the command line.

   ```bash
   export DECRYPT_PASSWORD='s3cret'
   decrypt-pdf document.pdf

   # or inline for a single invocation
   DECRYPT_PASSWORD='s3cret' decrypt-pdf document.pdf
   ```

If neither is provided, the command exits with an error.

**Options**

| Flag | Description |
|------|-------------|
| `-p PASSWORD` | Password for the encrypted PDF |
| `--verbose` | Show detailed output from each decryption tool |
| `--quiet`, `-q` | Suppress all output; rely on exit code and output file |
| `--version` | Show version information and exit |
| `-h`, `--help` | Show help message and exit |

**Exit codes**

| Code | Meaning |
|------|---------|
| 0 | Success (or file is already unencrypted) |
| 1 | Failure |

### Automator Quick Action (macOS)

Set up a macOS Quick Action to right-click any PDF in Finder and decrypt it — no
terminal required.

**One-time setup**

1. Copy the decryption script into the workflow bundle:

   ```bash
   mkdir -p ~/Library/Services/"Decrypt PDF File.workflow"/Contents/
   cp "$(command -v decrypt-pdf)" ~/Library/Services/"Decrypt PDF File.workflow"/Contents/
   ```

2. Open **Automator** and select **Quick Action** as the document type.
3. At the top, set **"Workflow receives current PDF files in Finder"**.
4. From the actions library, drag **Run AppleScript** into the workflow.
5. Replace the default script with the contents of
   [`automator/decrypt-pdf.applescript`](automator/decrypt-pdf.applescript).
6. **File > Save** and name it **"Decrypt PDF File"**.

**Usage**

Right-click a PDF in Finder > **Quick Actions** > **Decrypt PDF File**. A dialog
prompts for the password; the decrypted file appears in the same folder as
`<filename>_decrypted.pdf`.

> **Note:** the Quick Action currently expects the script inside the workflow
> bundle and runs with a minimal `PATH`. Compatibility with a Homebrew install
> is tracked in the [issues](https://github.com/Sdaas/decrypt-pdf/issues).

## Developer Guide

### Design

See [design.md](design.md) for the decryption strategy, tool-specific notes
(qpdf, mutool, ghostscript), the cascading workflow, and Homebrew packaging.

### Structure of the codebase

| Path | Purpose |
|------|---------|
| `decrypt-pdf` | The main script — cascading PDF decryptor |
| `decrypt-pdf_test.sh` | Tests for `decrypt-pdf` (synthetic fixtures) |
| `release.sh` | Local release pre-flight: bump, gate, tag, push |
| `release_test.sh` | Characterization tests for `release.sh` |
| `run-tests.sh` | Single test runner (discovers every `*_test.sh`) |
| `automator/decrypt-pdf.applescript` | Automator Quick Action script |
| `.githooks/pre-push` | Runs the full suite before every `git push` |
| `.github/workflows/ci.yml` | CI — runs the suite on push / PR |
| `.github/workflows/release.yml` | Renders the Homebrew formula and pushes it to the tap on a tag |
| `design.md` | Design notes |
| `homebrew_packaging_guide.md` | How the Homebrew tap / packaging works |

### Running tests

Run the full suite via the single runner (add `-v` for verbose output):

```bash
./run-tests.sh
```

Tests are any `*_test.sh` file; the runner discovers them automatically. The
decryption suite is self-contained — it generates its own synthetic encrypted
PDFs at runtime (via `qpdf`), so no customer files or secret passwords are
needed. Decryption tests are skipped only if `qpdf` is not installed.

### Release process

The **git tag is the version source of truth** — there is no version file to
bump. To cut a release, run the local pre-flight:

```bash
./release.sh            # add --dry-run to preview without tagging/pushing
```

It suggests a SemVer bump from the commits since the last tag, runs the quality
gates (tests + `brew` audit/style/install/test), then tags `vX.Y.Z` and pushes.
That tag push triggers [`.github/workflows/release.yml`](.github/workflows/release.yml),
which renders `Formula/decrypt-pdf.rb` (stamping the tag version into the
script's `__VERSION__` placeholder) and pushes it to the `sdaas/tools` tap
(repo `Sdaas/homebrew-tools`). See [`release.sh`](release.sh) and
[homebrew_packaging_guide.md](homebrew_packaging_guide.md) for details.

### Other notes

- **Pre-push hook** — [`.githooks/pre-push`](.githooks/pre-push) runs the full
  suite before every push and blocks the push if it fails. Enable it once per
  clone with `git config core.hooksPath .githooks`; bypass in an emergency with
  `git push --no-verify`.
- **CI/CD** — `ci.yml` runs the suite on every push and PR (macOS runner,
  installs `qpdf`/`mupdf-tools`/`ghostscript`). `release.yml` publishes the
  Homebrew formula on tags (see [Release process](#release-process)).

## Issues

Open items and bug reports live on the
[GitHub Issues page](https://github.com/Sdaas/decrypt-pdf/issues).
