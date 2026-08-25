# cleanup-chromes

[![skills.sh](https://skills.sh/b/Rayan-and-beyond/cleanup-chromes)](https://skills.sh/Rayan-and-beyond/cleanup-chromes)

A macOS Agent Skill that safely reclaims disk space left behind by browser automation and AI coding agents. It deletes throwaway test-browser caches (Playwright, Puppeteer, Cypress, Selenium, chrome-devtools-mcp) and macOS `code_sign_clone` leftovers — often **10–60+ GB** worth. Everything removed is regenerable; your real browser profiles are never touched.

## Sound familiar?

If you ended up here after seeing any of these, you're in the right place:

- DaisyDisk / `du` showing giant folders like `/private/var/folders/.../X/com.google.Chrome.code_sign_clone`
- macOS Storage settings blaming tens of GBs on vague **"System Data"**
- `~/Library/Caches/ms-playwright`, `~/.cache/puppeteer`, or `~/Library/Caches/Cypress` quietly holding many GB of browser builds
- `Your startup disk is almost full` after heavy agent work (Claude Code, Codex, Cursor, …)

## Install — Claude Code

```bash
npx skills add Rayan-and-beyond/cleanup-chromes -a claude-code -g
```

Installs to `~/.claude/skills/cleanup-chromes`. Prefer manual?

```bash
git clone https://github.com/Rayan-and-beyond/cleanup-chromes.git /tmp/cc && cp -r /tmp/cc/skills/cleanup-chromes ~/.claude/skills/ && rm -rf /tmp/cc
```

Then just ask naturally — *"my disk is almost full, run a cleanup-chromes scan"* — or explicitly *"use the cleanup-chromes skill"*. It always shows you the scan first and asks before deleting anything.

## Install — Codex CLI

```bash
npx skills add Rayan-and-beyond/cleanup-chromes -a codex -g
```

Installs to `~/.codex/skills/cleanup-chromes`. Prefer manual? Same as above but copy into `~/.codex/skills/`.

Invoke with `$cleanup-chromes`, pick it from `/skills`, or just describe the disk problem — it activates automatically. Tip: Codex runs commands in an approval sandbox — the scan is read-only, so approve it freely, review findings, then approve `delete`.

## Usage without an agent

It's also just a safe bash script:

```bash
git clone https://github.com/Rayan-and-beyond/cleanup-chromes.git && cd cleanup-chromes
./skills/cleanup-chromes/cleanup-chromes.sh scan      # read-only, lists what's reclaimable
./skills/cleanup-chromes/cleanup-chromes.sh delete    # removes only what passed every check
```

Exit codes: `0` success · `1` one or more deletions failed · `2` bad usage.
The final line is machine-readable: `SUMMARY mode=<scan|delete> freed_mb=<n> deleted=<n> skipped=<n> failed=<n>`

## What it deletes

| Location | Left by |
|---|---|
| `~/Library/Caches/ms-playwright` | Playwright |
| `~/Library/Caches/ms-playwright-go` | Playwright Go |
| `~/.cache/ms-playwright` | Playwright |
| `~/.cache/puppeteer` | Puppeteer / Chrome for Testing |
| `~/Library/Caches/Cypress` | Cypress |
| `~/.cache/rebrowser-puppeteer` | rebrowser-puppeteer |
| `~/.cache/selenium` | Selenium |
| `~/.cache/chrome-devtools-mcp` | chrome-devtools-mcp |
| `~/Library/Caches/chromium` | Chromium-based test tooling |
| `/private/var/folders/*/*/X/*.code_sign_clone` | transient macOS code-sign clones |

### Clone allowlist

macOS names each clone root after the owning app's bundle identifier, so only these exact bundle IDs are eligible for cleanup — and only while their app is not running:

| Bundle ID | Owner |
|---|---|
| `com.google.Chrome` | Google Chrome |
| `com.openai.codex` | Codex |
| `com.openai.chat` | ChatGPT |
| `com.brave.Browser` | Brave Browser |
| `com.microsoft.edgemac` | Microsoft Edge |

Any clone root with a different bundle ID is refused and reported — never deleted automatically.

## Safety guarantees

Before anything is deleted, the script:

- considers only the hardcoded throwaway locations above
- hard-refuses real Chrome, Brave, and Edge profiles plus everything in `/Applications`
- refuses unknown clone owners by default (default-deny)
- checks open files with `lsof` and running owner apps with exact process-name matching (`pgrep -x`)
- re-runs all checks immediately before each individual deletion
- reports the *actual* freed space via `df` — APFS makes `du` overstate clone sizes

Requires macOS with stock bash (`/bin/bash` 3.2 works). MIT — see [LICENSE](./LICENSE).

Tests: `/bin/bash tests/run_tests.sh`. New cleanup targets must be regenerable caches or verified clone owners (real bundle ID + process name proven with `pgrep -x`).
