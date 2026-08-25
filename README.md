# cleanup-chromes

[![skills.sh](https://skills.sh/b/Rayan-and-beyond/cleanup-chromes)](https://skills.sh/Rayan-and-beyond/cleanup-chromes)

Deletes the browser binaries and macOS code-sign clones that AI coding agents leave on your disk. Reclaims **10–60+ GB**. Everything removed is regenerable — tools re-download what they need.

## Sound familiar?

- DaisyDisk / `du` showing giant `/private/var/folders/.../X/com.google.Chrome.code_sign_clone` folders
- macOS Storage settings blaming tens of GBs on vague **"System Data"**
- `~/Library/Caches/ms-playwright` or `~/.cache/puppeteer` quietly holding GBs of browser builds
- `no space left on device` after heavy browser-driving agent work (Claude Code, Codex, Cursor, …)

## Claude Code

```bash
npx skills add Rayan-and-beyond/cleanup-chromes -a claude-code -g
```

Installs to `~/.claude/skills/cleanup-chromes`. Then just ask:

> My disk is almost full — run a cleanup-chromes scan

It always shows you the scan first and asks before deleting anything.

## Codex CLI

```bash
npx skills add Rayan-and-beyond/cleanup-chromes -a codex -g
```

Installs to `~/.codex/skills/cleanup-chromes`. Invoke with `$cleanup-chromes`, pick it from `/skills`, or just describe the disk problem. The scan is read-only — approve it freely, review findings, then approve `delete`.

## No agent needed

```bash
git clone https://github.com/Rayan-and-beyond/cleanup-chromes.git && cd cleanup-chromes
./skills/cleanup-chromes/cleanup-chromes.sh scan      # read-only, shows what's reclaimable
./skills/cleanup-chromes/cleanup-chromes.sh delete    # removes only what passed every check
```

Ends with a machine-readable summary: `SUMMARY mode=… freed_mb=… deleted=… skipped=… failed=…` (exit `0` = success, `1` = deletions failed, `2` = bad usage).

## What it deletes

| Target | Left by |
|---|---|
| `~/Library/Caches/ms-playwright[-go]` | Playwright |
| `~/.cache/puppeteer`, `~/.cache/rebrowser-puppeteer` | Puppeteer |
| `~/Library/Caches/Cypress` | Cypress |
| `~/.cache/selenium` | Selenium |
| `~/.cache/chrome-devtools-mcp` | chrome-devtools-mcp |
| `/private/var/folders/*/*/X/*.code_sign_clone` | macOS code-sign clones (allowlist below) |

Clone roots are only touched for verified bundle IDs — `com.google.Chrome`, `com.openai.codex`, `com.openai.chat`, `com.brave.Browser`, `com.microsoft.edgemac` — and only while their app isn't running (exact process-name match). Any other bundle ID is refused, never guessed.

## Safety guarantees

- Hardcoded target list only; nothing else is ever considered
- Real profiles (`~/Library/Application Support/…`) and `/Applications` are hard-refused
- In-use checks (`lsof` + process guards) re-run immediately before each deletion
- `du` overstates clones on APFS (shared blocks) — trust the script's measured `freed_mb`

Requires macOS with stock bash (`/bin/bash` 3.2 works). MIT — see [LICENSE](./LICENSE).

Tests: `/bin/bash tests/run_tests.sh`. New targets must be regenerable caches or verified clone owners (real bundle ID + process name proven with `pgrep -x`).
