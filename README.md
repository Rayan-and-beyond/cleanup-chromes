# cleanup-chromes

A macOS Agent Skill for safely reclaiming disk space left behind by browser automation and coding agents.

It targets known throwaway caches from Playwright, Puppeteer, Cypress, Selenium, Chromium, and chrome-devtools-mcp, plus transient macOS `*.code_sign_clone` copies. Real browser profiles and `/Applications` are hard-refused.

## The cause: browsers your coding agents downloaded — and never deleted

AI coding agents (Claude Code, Codex, Cursor, …) drive real browsers. To do that, Playwright, Puppeteer, Cypress, Selenium, and chrome-devtools-mcp each download their own Chromium builds, and macOS creates extra code-sign copies of Chrome, Brave, Edge, and OpenAI apps on top. None of these tools clean up after themselves. The leftovers pile up in known locations:

- `~/Library/Caches/ms-playwright`, `~/.cache/puppeteer`, `~/Library/Caches/Cypress` — downloaded browser builds, several GB each
- `/private/var/folders/.../X/com.google.Chrome.code_sign_clone` — macOS code-sign clones; these alone can silently reach **38+ GB**

If DaisyDisk, `du`, or Storage settings ("System Data") show gigabytes in places like these, this skill is the fix: it deletes exactly these agent-created leftovers — and nothing else. Every tool re-downloads what it needs on next use.

If your disk is full for a different reason (Photos, Mail, Xcode, …), this skill will not help — and will not touch anything related.

## Install

### One command, any agent

The [Agent Skills CLI](https://github.com/vercel-labs/skills) detects which agents you have installed and offers to install into each:

```bash
npx skills add Rayan-and-beyond/cleanup-chromes
```

Or with GitHub CLI v2.90+:

```bash
gh skill install Rayan-and-beyond/cleanup-chromes
```

### Claude Code

```bash
npx skills add Rayan-and-beyond/cleanup-chromes -a claude-code -g
```

Installs to `~/.claude/skills/cleanup-chromes`.

Manual install:

```bash
git clone https://github.com/Rayan-and-beyond/cleanup-chromes.git /tmp/cc && cp -r /tmp/cc/skills/cleanup-chromes ~/.claude/skills/ && rm -rf /tmp/cc
```

Ask: *"my disk is almost full, run a cleanup-chromes scan"* — or type `/cleanup-chromes`. Claude shows you the scan first and asks before deleting anything.

### Codex CLI

```bash
npx skills add Rayan-and-beyond/cleanup-chromes -a codex -g
```

Installs to `~/.agents/skills/cleanup-chromes` (Codex's user skills location).

Manual install:

```bash
git clone https://github.com/Rayan-and-beyond/cleanup-chromes.git /tmp/cc && cp -r /tmp/cc/skills/cleanup-chromes ~/.agents/skills/ && rm -rf /tmp/cc
```

Alternative — Codex's built-in installer: run `$skill-installer`, then request `cleanup-chromes` from `Rayan-and-beyond/cleanup-chromes`.

Invoke with `$cleanup-chromes` or browse via `/skills`. It also activates automatically when you describe disk-space problems. Codex runs commands in an approval sandbox: the scan is read-only — approve it, review the findings, then approve `delete`.

### Other agents

Anything that reads the open [Agent Skills standard](https://agentskills.io) works — copy this folder into that agent's skills directory.

### No agent at all

Run the script directly:

```bash
git clone https://github.com/Rayan-and-beyond/cleanup-chromes.git && cd cleanup-chromes
./skills/cleanup-chromes/cleanup-chromes.sh scan     # read-only, shows what's reclaimable
./skills/cleanup-chromes/cleanup-chromes.sh delete   # removes only what passed every safety check
```

### Verify it works

Run a **scan** (never deletes anything) and check for the `SUMMARY mode=scan ...` line at the end. Exit code `0` confirms success.

## What it does

The skill ships with `cleanup-chromes.sh`, which has two modes:

```bash
# Read-only scan
./cleanup-chromes.sh scan

# Delete only items that pass the safety checks
./cleanup-chromes.sh delete
```

Before deleting, the script:

- considers only hardcoded throwaway locations
- hard-refuses real Chrome, Brave, and Edge profiles plus anything in `/Applications`
- allows `code_sign_clones` only for a verified bundle-ID allowlist — anything unknown is refused (default-deny)
- checks open files with `lsof`
- checks known long-lived browser-tool processes, plus each clone's owner app (a running Chromium/Electron app can own an active clone without holding files open, so `lsof` alone is not sufficient)
- re-checks each target immediately before deletion using the same classification as the scan
- reports actual free-space change with `df`

The default mode is `scan`, so running the script with no argument is non-destructive.

## Targets

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
| `/private/var/folders/*/*/X/*.code_sign_clone` | transient macOS code-sign clones (allowlisted bundle IDs only) |

Everything removed from the browser-cache targets can be regenerated by the relevant tool when needed again. `code_sign_clone` entries are transient macOS temporary copies.

### Clone allowlist

macOS names each clone root after the owning app's bundle identifier, so the script allowlists exact bundle IDs and maps them to an exact process-name check (`pgrep -x` — a command that merely *mentions* e.g. "Codex" in its arguments does not count as Codex running):

| Bundle ID | Owner | Process guard |
|---|---|---|
| `com.google.Chrome` | Google Chrome | `Google Chrome` |
| `com.openai.codex` | Codex | `Codex` |
| `com.openai.chat` | ChatGPT | `ChatGPT` |
| `com.brave.Browser` | Brave Browser | `Brave Browser` |
| `com.microsoft.edgemac` | Microsoft Edge | `Microsoft Edge` |

Any clone root with an unknown bundle ID is refused and reported — never deleted automatically. This is deliberate: it keeps the behavior auditable and future-proof without guessing at app ownership.

## Safety notes

`du` can make APFS `code_sign_clone` directories look much larger than the physical space they consume because copy-on-write clones share blocks. Use the script's `Freed ~N MB` result as the useful number.

A tiny check-then-delete race is still theoretically possible if a process starts at exactly the wrong instant. The script minimizes this by refreshing its in-use checks immediately before each removal.

## Output

Exit codes:

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | One or more deletions failed |
| `2` | Invalid argument |

The final line is machine-readable:

```text
SUMMARY mode=<scan|delete> freed_mb=<n> deleted=<n> skipped=<n> failed=<n>
```

Deletion results are also appended to `cleanup.log`, which is ignored by Git.

## Requirements

- macOS
- Bash (stock `/bin/bash` 3.2 is fully supported; the test suite targets it specifically)
- standard macOS utilities including `lsof`, `du`, `df`, and `pgrep`

## Development

Run the test suite with **stock macOS bash** (newer Homebrew bash will not reproduce the Bash 3.2 empty-array bugs):

```bash
/bin/bash tests/run_tests.sh
```

Scan-mode tests are read-only. Delete-mode tests self-block unless the script-under-test supports the `CLEANUP_CHROMES_CLONE_GLOB` isolation override, so running the suite against an un-hooked older revision can never touch real data. Integration tests create fake clone roots under harmless bundle IDs in your per-user temp dir and clean them up on exit.

## Contributing

Keep new cleanup targets explicit and narrow. A target should be a known regenerable cache or transient clone, and it should follow the same in-use checks and profile protections already used by the script. New clone entries require both a verified owning bundle ID and its exact process name — verify the latter with `pgrep -x "<name>"` while the app is running before adding it.

## License

MIT. See [LICENSE](./LICENSE).
