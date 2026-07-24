# decrypt-pdf

<!-- vscode-markdown-toc -->
* [Install via Homebrew](#InstallviaHomebrew)
* [Quick Start](#QuickStart)
* [Dependencies](#Dependencies)
* [Usage](#Usage)
	* [Options](#Options)
	* [Exit Codes](#ExitCodes)
* [Specifying the Password](#SpecifyingthePassword)
* [Running Tests](#RunningTests)
* [Automator Quick Action (macOS)](#AutomatorQuickActionmacOS)
* [Design](#Design)
* [TODO](#TODO)

<!-- vscode-markdown-toc-config
	numbering=false
	autoSave=true
	/vscode-markdown-toc-config -->
<!-- /vscode-markdown-toc -->

A command-line tool that decrypts password-protected PDF files using a cascading
strategy of tools: **qpdf**, **mutool**, and **ghostscript**. It tries each tool
in sequence until one succeeds — so you don't have to remember which tool works
for which PDF.

This is **not** a password cracker. It assumes you already know the password.

The simplest way to use it through `homebrew`
```bash
brew tap sdaas/tap
brew install decrypt-pdf
```

This also contains instructions on how how to install it as an Automator script
and launch it via right-clicking on the file in Finder


## <a name='QuickStart'></a>Quick Start

```bash
# Using the -p flag
./decrypt-pdf -p 's3cret' document.pdf

# Using an environment variable
export DECRYPT_PASSWORD='s3cret'
./decrypt-pdf document.pdf
```

The decrypted file is written to `document_decrypted.pdf` by default, or you can
specify an output path:

```bash
./decrypt-pdf -p 's3cret' document.pdf /tmp/unlocked.pdf
```

## <a name='Dependencies'></a>Dependencies

Install at least one (all three recommended):

```bash
brew install qpdf
brew install mupdf-tools
brew install ghostscript
```

## <a name='Usage'></a>Usage

```
decrypt-pdf [OPTIONS] [-p PASSWORD] INPUT_FILE [OUTPUT_FILE]
```

### <a name='Options'></a>Options

| Flag | Description |
|------|-------------|
| `-p PASSWORD` | Password for the encrypted PDF |
| `--verbose` | Show detailed output from each decryption tool |
| `--quiet`, `-q` | Suppress all output; rely on exit code and output file |
| `-h`, `--help` | Show help message |

### <a name='ExitCodes'></a>Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (or file is already unencrypted) |
| 1 | Failure |

## <a name='SpecifyingthePassword'></a>Specifying the Password

The password can be provided in two ways:

1. **`-p` flag** (highest priority) — passed directly on the command line.
   Simple but visible in `ps` output and shell history.

   ```bash
   ./decrypt-pdf -p 's3cret' document.pdf
   ```

2. **`DECRYPT_PASSWORD` environment variable** — used as a fallback when `-p`
   is not provided. Avoids exposing the password on the command line.

   ```bash
   export DECRYPT_PASSWORD='s3cret'
   ./decrypt-pdf document.pdf
   ```

   Or inline for a single invocation:

   ```bash
   DECRYPT_PASSWORD='s3cret' ./decrypt-pdf document.pdf
   ```

**Precedence:** `-p` flag > `DECRYPT_PASSWORD` env var > error.

## <a name='RunningTests'></a>Running Tests

```bash
./test-decrypt-pdf.sh
```

The suite is self-contained: it generates its own synthetic encrypted PDFs at
runtime (via `qpdf`), so no customer files or secret passwords are needed.
Decryption tests are skipped only if `qpdf` is not installed.

## <a name='AutomatorQuickActionmacOS'></a>Automator Quick Action (macOS)

You can set up a macOS Quick Action so that you can right-click any PDF in Finder
and decrypt it — no terminal required.

### One-Time Setup

1. Copy the decryption script into the workflow bundle:

   ```bash
   mkdir -p ~/Library/Services/"Decrypt PDF File.workflow"/Contents/
   cp decrypt-pdf ~/Library/Services/"Decrypt PDF File.workflow"/Contents/
   ```

2. Open **Automator** and select **Quick Action** as the document type.

3. At the top, set **"Workflow receives current PDF files in Finder"**.

4. From the actions library, drag **Run AppleScript** into the workflow.

5. Replace the default script with the contents of
   [`automator/decrypt-pdf.applescript`](automator/decrypt-pdf.applescript).

6. **File > Save** and name it **"Decrypt PDF File"**.

### How to Use

Right-click a PDF in Finder > **Quick Actions** > **Decrypt PDF File**. A dialog
will prompt for the password. The decrypted file appears in the same folder as
`<filename>_decrypted.pdf`.

## <a name='Design'></a>Design

See [design.md](design.md) for details on the decryption strategy, tool-specific
notes (qpdf, mutool, ghostscript), and the cascading workflow.

## <a name='TODO'></a>TODO

- ~~Automator integration for macOS~~ (done — see [Automator Quick Action](#AutomatorQuickActionmacOS))
- ~~Create and Publish Homebrew package~~ (done — see [Install via Homebrew](#InstallviaHomebrew))





