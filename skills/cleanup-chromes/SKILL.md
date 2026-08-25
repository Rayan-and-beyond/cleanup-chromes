---
name: cleanup-chromes
license: MIT
description: Use on macOS when browser automation or coding agents have consumed disk space through Playwright, Puppeteer, Cypress, Selenium, Chromium, chrome-devtools-mcp caches, or transient code_sign_clone copies. Trigger for agent browser leftovers, oversized browser caches, test-browser disk usage, low disk space, or no-space-left-on-device errors.
---

# cleanup-chromes

Safely reclaim disk space from known throwaway browser-automation caches and transient macOS code-sign clones.

## Core rule

Only remove the explicit targets below after confirming they are not in use. Never touch a real browser profile or an application bundle.

## Targets

| Location | Left by | Lifetime |
|---|---|---|
| `~/Library/Caches/ms-playwright` | Playwright | persistent cache |
| `~/Library/Caches/ms-playwright-go` | Playwright Go | persistent cache |
| `~/.cache/ms-playwright` | Playwright | persistent cache |
| `~/.cache/puppeteer` | Puppeteer / `@puppeteer/browsers` | persistent cache |
| `~/Library/Caches/Cypress` | Cypress | persistent cache |
| `~/.cache/rebrowser-puppeteer` | rebrowser-puppeteer | persistent cache |
| `~/.cache/selenium` | Selenium | persistent cache |
| `~/.cache/chrome-devtools-mcp` | chrome-devtools-mcp | persistent profile/cache |
| `~/Library/Caches/chromium` | other Chromium test tooling | persistent cache |
| `/private/var/folders/*/*/X/*.code_sign_clone` | macOS temporary code-sign clones (only allowlisted bundle IDs, see below) | transient |

## code_sign_clone allowlist

macOS names each clone root after the owning app's bundle identifier. Only these exact bundle IDs are eligible for cleanup, and only while their owner process is not running:

| Bundle ID | Owner |
|---|---|
| `com.google.Chrome` | Google Chrome |
| `com.openai.codex` | Codex |
| `com.openai.chat` | ChatGPT |
| `com.brave.Browser` | Brave Browser |
| `com.microsoft.edgemac` | Microsoft Edge |

Any clone root with a different or unknown bundle ID is **REFUSEd** (default-deny) and reported with its bundle ID. Never add an entry to this table without verifying both the owning app's bundle ID and its real process name with `pgrep -x "<name>"` while the app runs.

## Never delete

- `~/Library/Application Support/Google/Chrome`
- `~/Library/Application Support/BraveSoftware`
- `~/Library/Application Support/Microsoft Edge`
- anything under `/Applications`
- any target currently used by a running browser or test process
- any `code_sign_clone` root whose bundle ID is not in the allowlist
- any `code_sign_clone` root while its owner app is running (a running Electron/Chromium app can own an active clone without holding files open, so lsof alone is not sufficient)

## Procedure

The script is `cleanup-chromes.sh` in this skill directory.

1. Run a read-only scan first:

   ```bash
   bash cleanup-chromes.sh scan
   ```

2. Review the output. `SAFE` means the target matched the hardcoded throwaway list and no current use was detected. `IN USE` means it was skipped. `REFUSE` means a safety guard rejected it (real profile, `/Applications`, or unknown clone owner) — never force-delete refused items.

3. Before deletion, tell the user what the scan found and obtain approval unless the user already explicitly asked for this cleanup to be performed.

4. Delete eligible targets:

   ```bash
   bash cleanup-chromes.sh delete
   ```

   `delete` repeats the safety checks and refreshes the open-file/process checks immediately before each individual removal.

5. Report the actual reclaimed space, deletion count, and anything skipped or failed.

## Proactive use

A read-only `scan` is appropriate when:

- the user reports low disk space or `no space left on device`
- browser-driven coding agents have been used heavily
- one of the known cache directories appears unusually large

Do not perform deletion merely because a scan found reclaimable data. Follow the user's deletion intent.

## Reading the result

Exit codes:

- `0`: success
- `1`: one or more deletions failed
- `2`: invalid argument

The final output line is machine-readable:

```text
SUMMARY mode=<scan|delete> freed_mb=<n> deleted=<n> skipped=<n> failed=<n>
```

Deletion results are appended to `cleanup.log` beside the script.

## Safety behavior

- Cleanup candidates come only from the hardcoded target list.
- A `looks_dangerous` guard refuses known real browser profiles, `/Applications`, and the home directory itself.
- `code_sign_clone` roots are allowlisted by exact owning bundle ID (taken from the directory name); unknown bundle IDs are REFUSEd — default-deny.
- Each allowed clone has an exact process-name `pgrep -x` guard for its owner app (a command whose arguments merely mention the name does not count), in addition to `lsof`.
- Open-file checks use `lsof`.
- Known long-lived tool processes receive an additional `pgrep` guard.
- Scan and delete share one classification function (`classify_target`), so the pre-delete re-check can never drift from what the scan reported.
- Each target is checked again immediately before `rm -rf`.
- `scan` is the default mode and is read-only.
- Unknown arguments are rejected.
- Tests: run with stock macOS bash via `/bin/bash tests/run_tests.sh` (delete-mode tests self-block unless the script supports the test-isolation override).

## Notes

- Browser automation tools have their own cache-management behavior, but large persistent caches can still remain across versions, agents, and abandoned installs.
- Deleted browser binaries may re-download the next time the corresponding tool runs.
- `code_sign_clone` sizes reported by `du` are apparent sizes. APFS copy-on-write clones share blocks, so actual reclaimed space can be much smaller. Trust the script's before/after `df` measurement.
- A reboot can clear transient `code_sign_clone` entries, while the persistent browser caches listed above generally require tool-specific or manual cleanup.
- A very small check-then-delete race remains possible if another process starts at the exact instant between the final check and deletion.
