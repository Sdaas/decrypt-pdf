# PDF Decryption

To create a command-line tool that can reliably open a
password-protected PDF file. This is not a password cracker - it assumes that the 
user knows the password

## Context
The most common command-line tools are

- `qpdf`
- `mupdf-tools`
- `ghostscript`

### QPDF

This works for **most** PDF files and should be the first thing to try

`qpdf input.pdf --password='mypassword' output.pdf` 

Sometimes the decryption fails because the PDF passwords are not simple strings. In 
that case, use a hex-encoded version. First run

`echo -n 'yourpassword' | xxd -p` 

This will return a hex-encoded string that is given to qpdf

`qpdf input.pdf --password=HEXENCODED --password-is-hex-key out2.pdf`

In some cases, there may be a problem in the PDF file itself unrelated to encryption
( e.g., Corrupt compressed streams, broken or inconsistent page tree, etc.). Browsers like Chrome are more forgiving and can reconstruct enough of the structure to display the document, but qpdf is stricter and fails to build a valid page tree. 

In this case we can try

```bash
qpdf input.pdf --password='mypassword' \
     --decrypt \
     --object-streams=disable \
     --linearize \
    output.pdf
```

`--decrypt` makes it explicitly decrypt,
`--object-streams=disable` can sometimes work around stream‑level issues by forcing object streams to be written as plain objects,
`--linearize` rewrites the file, sometimes fixing certain layout issues.

Other useful commands/flags

- `--verbose` 
- `--progress` : reports progress of the process
- `--version` : returns the version number
- `--show-encryption` : What kind of encryption is being used 

For example
- `qpdf input.pdf --password='mypassword' --verbose --progress output.pdf` 
- `qpdf --version`
- `qpdf --show-encryption input.pdf`

Exit codes
- 0 : no errors or warnings were found
- 1 : not used
- 2 : errors were found; the file was not processed
- 3 : warnings were found without errors

Use the following command to determine if a PDF file is encrypted

```bash 
qpdf --show-encryption xxx.pdf
File is not encrypted
```

Also see https://qpdf.readthedocs.io/en/stable/

### MU PDF

The basic command is

`mutool clean -p 'password' input.pdf output.pdf`

### Ghostscript

```bash
gs -sDEVICE=pdfwrite \
   -sOutputFile=output.pdf \
   -sPDFPassword='mypassword' \
   -dCompatibilityLevel=1.4 \
   -dNOPAUSE -dBATCH -dQUIET \
   input.pdf
```


Breakdown of the flags

- `-sDEVICE=pdfwrite` : the output is a PDF. Otherwise `gs` will return to screen or image.
- `-sOutputFile=output.pdf` : output file name
- `-sPDFPassword=mypassword` : the password
- `-dNOPAUSE` : don't pause between pages. **IMPORTANT** `gs` pauses between pages by default
- `-dBATCH` : exit after processing. By default `gs` stays in interactive mode
- `-dQUIET` or `-q`: suppress logs and output. run quietly
- `-dCompatibilityLevel=1.4` : PDF compatibility level. Lower versions are more compatible
and have simpler structure. higher versions support modern features like transparency, layers, etc.
    - `1.3` : Acrobat 4. Very old. avoid
    - `1.4` : Acrobat 5. Widely compatible
    - `1.5` : supports object streams
    - `1.7` : modern PDF

BTW, when we run `-sDEVICE=pdfwrite` Ghostscript is not actually "decrypting" the file - it is actually rendering the input PDF and creating a new one. So it while the encryption is removed, and structure is rebuilt, some metadata may be lost. Think of it as “print to PDF via CLI”

## High-Level Workflow

- Check if all dependencies are installed
- Check if the file is actually encrypted
- Create a backup copy of the file
- Try decryption using a 6-step cascade:
  1. `qpdf` basic — simple password decryption
  2. `qpdf` hex-encoded password — for non-ASCII or special passwords
  3. `qpdf` advanced — decrypt + disable object-streams + linearize (fixes structural issues)
  4. `mutool` — alternative tool with different PDF parser
  5. `gs` without `CompatibilityLevel` — Ghostscript re-renders the PDF
  6. `gs` with `CompatibilityLevel=1.4` — forces Acrobat 5 compatible output
- After each step, verify decryption succeeded using `qpdf --show-encryption`
- Stop at the first strategy that succeeds

Notes
- do not rely on the exit code to determine if the decryption succeeded
- always use the `qpdf --show-encryption xxx.pdf` command for this. If the file is not
  password protected, this will return `File is not encrypted` 

## Bulk decryption (`decrypt-pdfs`)

`decrypt-pdfs` is a thin batch wrapper around the single-file `decrypt-pdf`
engine. It exists so a directory full of statements can be unlocked in one
command without reinventing the decryption cascade.

Workflow:

- Resolve the engine: prefer a `decrypt-pdf` sitting next to `decrypt-pdfs` (the
  in-repo / same-`bin` case), otherwise fall back to `decrypt-pdf` on `PATH`.
- Discover PDFs under the target directory (`-maxdepth 1` unless `--recursive`),
  NUL-delimited to survive spaces/newlines. Prune the `originals/` archive
  folder and skip leftover `*_decrypted.pdf` outputs so re-runs are idempotent.
- For each file, use `qpdf --is-encrypted` to classify it (encrypted / plain /
  unreadable); plain files are skipped, unreadable ones are reported as failures.
- For each encrypted file, try every candidate password in order (from repeated
  `-p` and/or `DECRYPT_PASSWORD`) by invoking `decrypt-pdf -q [...] `, stopping at
  the first success.
- `--cleanup` is **delegated** to `decrypt-pdf --cleanup` rather than
  reimplemented — the archive-never-delete safety logic lives in exactly one
  place. `--dry-run` reports intended actions and touches nothing (and needs no
  password).
- Aggregate a summary (scanned / plain / encrypted / decrypted) and list any
  failures on stderr.

Design notes:

- Strict mode is `set -uo pipefail` **without** `-e`: a batch tool must survive a
  single file's failure, keep processing the rest, and report all failures at the
  end. Every externally-failing command is checked explicitly instead.
- Exit codes mirror the intent: `0` all decrypted / nothing to do, `1` one or
  more failures, `2` usage or environment error.

## Automator Quick Action (macOS)

A macOS Automator Quick Action allows users to right-click a PDF in Finder and
decrypt it via a GUI dialog, without using the terminal.

- The AppleScript lives in `automator/decrypt-pdf.applescript`
- It locates `decrypt-pdf` inside the workflow bundle at
  `~/Library/Services/Decrypt PDF File.workflow/Contents/decrypt-pdf`
- Prompts the user for the password via `display dialog` with hidden input
- Runs `decrypt-pdf -q -p <password> <file>` for each selected PDF
- Shows a success or failure alert after each file
- Includes commented-out `display notification` calls for optional macOS
  notification center support

## Homebrew Packaging

The tool is distributed via a Homebrew tap (`sdaas/tools`, hosted at the
`Sdaas/homebrew-tools` repository). The formula is generated at release time by
`.github/workflows/release.yml` — which stamps the tag version into the script's
`__VERSION__` placeholder and renders `Formula/decrypt-pdf.rb` — and is then
committed and pushed to the tap repository. It downloads a tarball from a GitHub
release, installs both the `decrypt-pdf` and `decrypt-pdfs` scripts into the
Homebrew `bin/` directory (stamping the tag version into each script's
`__VERSION__` placeholder), and declares `qpdf`, `mupdf-tools`, and
`ghostscript` as dependencies.

## General Behavior

- provide a `--help` option so that the command line usage is clear
- provide a `--verbose` mode. In this, all commands should be invoked with a "verbose" option so that user can see exactly what is happening.
- provide a `--quiet` and `-q` option - where there is no output message. If the process
succeeds a new decrypted file is created and program exits with code 0. A non 0 exit code
signals some kind of error
- if user does not specify either quiet or verbose mode, then print some informational 
  messages
    - file is not encrypted
    - trying qpdf basic
    - trying qpdf with hex-encoded password
    - trying qpdf advanced (decrypt + object-streams + linearize)
    - trying mutool
    - trying ghostscript
    - trying ghostscript with CompatibilityLevel=1.4
    - decryption succeeded (zero exit code)
    - decryption failed (non-zero exit code)
- provide a `--cleanup` option for **in-place replacement**. By default the tool
  writes a new `<input>_decrypted.pdf` and leaves the original alone. With
  `--cleanup`, on a *verified-successful* decryption it archives the original
  into an `originals/` folder beside it and renames the decrypted file to the
  original's name, so the plain filename ends up holding the decrypted PDF. This
  is the per-file primitive that the batch `decrypt-pdfs` tool reuses.

### `--cleanup` safety design

The original is **archived, never deleted** — no failure path can lose it:

- `--cleanup` runs **only after** `run_cascade` succeeds, i.e. `verify_decryption`
  has confirmed the output is a valid, non-empty, unencrypted PDF (re-checked
  once more immediately before any move).
- It **refuses to overwrite** an existing `originals/<name>` backup.
- The two moves are ordered *archive-then-promote*: `mv INPUT originals/<name>`
  first, then `mv OUTPUT INPUT`. If the archive fails the original is untouched;
  if the promote fails the original is safely archived and the decrypted file
  still exists at its staged name (reported to the user, and shielded from the
  EXIT-trap cleanup so it isn't deleted).
- `--cleanup` is **incompatible with an explicit `OUTPUT_FILE`** (usage error,
  exit 1) and is a **no-op on an already-unencrypted file** (exit 0), which
  makes it safely **idempotent**.