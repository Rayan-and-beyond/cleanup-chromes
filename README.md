# cleanup-chromes

**Deletes the browser binaries your coding agents leave behind.**

cleanup-chromes is a skill for AI agents that reclaims disk space on macOS from throwaway test-browser caches and macOS `code_sign_clone` leftovers — often **10–60+ GB**. It deletes only hardcoded, regenerable targets. Real browser profiles and `/Applications` are hard-refused.





## 💾 The cause

AI coding agents (Claude Code, Codex, Cursor, …) drive real browsers. To do that, Playwright, Puppeteer, Cypress, Selenium, and chrome-devtools-mcp each download their own Chromium builds, and macOS creates extra code-sign copies of Chrome, Brave, Edge, and OpenAI apps on top. None of these tools clean up after themselves. The leftovers pile up in known locations:

- `~/Library/Caches/ms-playwright`, `~/.cache/puppeteer`, `~/Library/Caches/Cypress` — downloaded browser builds, several GB each
- `/private/var/folders/.../X/com.google.Chrome.code_sign_clone` — macOS code-sign clones; these alone can silently reach **38+ GB**

If DaisyDisk, `du`, or Storage settings ("System Data") show gigabytes in places like these, this skill is the fix: it deletes exactly these agent-created leftovers — and nothing else. Every tool re-downloads what it needs on next use.





## 🗑️ What it deletes

| Location | Usually left by |
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

macOS names each clone root after the owning app's bundle identifier, so the script allowlists exact bundle IDs and maps them to an exact process-name check (`pgrep -x` — a command that merely *mentions* e.g. "Codex" in its arguments does not count as Codex running):

| Bundle ID | Owner | Process guard |
|---|---|---|
| `com.google.Chrome` | Google Chrome | `Google Chrome` |
| `com.openai.codex` | Codex | `Codex` |
| `com.openai.chat` | ChatGPT | `ChatGPT` |
| `com.brave.Browser` | Brave Browser | `Brave Browser` |
| `com.microsoft.edgemac` | Microsoft Edge | `Microsoft Edge` |

Any clone root with an unknown bundle ID is refused and reported — never deleted automatically.





## 🛡️ How it stays safe

Before anything is deleted, the script:

- considers only the hardcoded throwaway locations above
- hard-refuses real Chrome, Brave, and Edge profiles plus everything in `/Applications`
- refuses unknown clone owners by default (default-deny)
- checks open files with `lsof` and running owner apps with exact process-name matching
- re-runs all checks immediately before each individual deletion

The default mode is `scan`, so running the script with no argument is non-destructive.





## 📦 Install

### Codex

```text
/skill-installer cleanup-chromes from Rayan-and-beyond/cleanup-chromes
```

Restart Codex if it asks you to.

Manual install — copy the skill folder to `~/.agents/skills/`:

```bash
git clone https://github.com/Rayan-and-beyond/cleanup-chromes.git /tmp/cc && cp -r /tmp/cc/skills/cleanup-chromes ~/.agents/skills/ && rm -rf /tmp/cc
```

### Claude Code

```bash
npx skills add Rayan-and-beyond/cleanup-chromes -a claude-code -g
```

Or Claude Code's native plugin flow:

```text
/plugin marketplace add Rayan-and-beyond/cleanup-chromes
/plugin install cleanup-chromes@cleanup-chromes
```

Installs to `~/.claude/skills/cleanup-chromes`.

### Any agent CLI

```bash
npx skills add Rayan-and-beyond/cleanup-chromes
```

GitHub CLI:

```bash
gh skill install Rayan-and-beyond/cleanup-chromes
```

### Other agents

Anything that reads the open [Agent Skills standard](https://agentskills.io) works — copy this folder into that agent's skills directory.





## ▶️ Use

### Codex

```text
$cleanup-chromes — run a scan of agent browser leftovers
```

### Claude Code

```text
/cleanup-chromes run a scan of agent browser leftovers
```

Or just ask: *"my disk is almost full, run a cleanup-chromes scan"*. Your agent shows you the scan first and asks before deleting anything.

### Terminal (no agent)

```bash
git clone https://github.com/Rayan-and-beyond/cleanup-chromes.git && cd cleanup-chromes
./skills/cleanup-chromes/cleanup-chromes.sh scan     # read-only, shows what's reclaimable
./skills/cleanup-chromes/cleanup-chromes.sh delete   # removes only what passed every check
```

Codex runs commands in an approval sandbox: the scan is read-only — approve it, review the findings, then approve `delete`.





## 📊 What you get

The scan reports every target with a size and a verdict: `SAFE`, `IN USE`, or `REFUSED` (with the reason). Deletion reports the *measured* freed space and ends with a machine-readable line:

```text
SUMMARY mode=<scan|delete> freed_mb=<n> deleted=<n> skipped=<n> failed=<n>
```

Exit codes: `0` success · `1` one or more deletions failed · `2` invalid argument. Deletion results are appended to `cleanup.log`.





## ⚠️ Limits

cleanup-chromes is **not a general disk cleaner**. It touches only the hardcoded targets above and nothing else.

> [!NOTE]
> **If your disk is full for a different reason (Photos, Mail, Xcode, …), this skill will not help — and will not touch anything related.**

Deleted caches re-download the next time the relevant tool runs. `du` overstates clone sizes on APFS (copy-on-write shares blocks) — trust the script's measured `freed_mb`. A tiny check-then-delete race remains theoretically possible if a process starts at exactly the wrong instant; the script minimizes this by refreshing its checks immediately before each removal.





## Requirements

- macOS
- Bash (stock `/bin/bash` 3.2 is fully supported; the test suite targets it specifically)
- standard macOS utilities including `lsof`, `du`, `df`, and `pgrep`





## 🧪 Development

Run the test suite with **stock macOS bash** (newer Homebrew bash will not reproduce the Bash 3.2 empty-array bugs):

```bash
/bin/bash tests/run_tests.sh
```

Scan-mode tests are read-only. Delete-mode tests self-block unless the script-under-test supports the `CLEANUP_CHROMES_CLONE_GLOB` isolation override, so running the suite against an un-hooked older revision can never touch real data.

New cleanup targets must be regenerable caches or verified clone owners — a real bundle ID plus its exact process name, proven with `pgrep -x "<name>"` while the app is running.

---

`1.0.0` · [MIT](./LICENSE) License
