---
name: cleanup-chromes
license: MIT
description: Use on macOS when browser automation or coding agents have consumed disk space through Playwright, Puppeteer, Cypress, Selenium, Chromium, chrome-devtools-mcp caches, or transient code_sign_clone copies, OR when orphaned automation browser processes are burning CPU / making the Mac hot while idle. Trigger for agent browser leftovers, oversized browser caches, test-browser disk usage, low disk space, no-space-left-on-device errors, unexplained heat/fanless-Mac warmth, or runaway CPU from abandoned agent sessions.
---

# cleanup-chromes

Safely reclaim disk space from known throwaway browser-automation caches and transient macOS code-sign clones, and terminate orphaned automation-browser process trees that burn CPU after their owning agent died.

## Core rule

Only remove the explicit targets below after confirming they are not in use. Never touch a real browser profile or an application bundle. Never kill a process tree unless every orphan gate below passes.

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

### Disk cleanup (scan / delete)

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

### Orphaned browser processes (kill-orphans)

An automation browser becomes an ORPHAN when the agent session that launched it died without cleanup: the headless Chrome tree and its orchestrator daemons (e.g. `node …/playwright-core/lib/entry/cliDaemon.js`) keep running forever, burning CPU and heating fanless Macs. Classic symptom: "my Mac is hot/overheating while I'm doing nothing."

**Busy CPU does NOT mean "in use."** An orphan can spin at 100% CPU on queued work indefinitely, so activity is deliberately NOT a criterion.

Run a read-only report first, then kill only on user approval:

```bash
bash cleanup-chromes.sh kill-orphans            # dry-run report (default)
bash cleanup-chromes.sh kill-orphans --do-it    # terminate confirmed orphans
```

A tree is CONFIRMED only when ALL four gates pass (default-deny):

| Gate | Meaning |
|---|---|
| 1. BROWSER+PROFILE | command has `--headless` AND `--user-data-dir` under a temp dir (`/var/folders`, `/tmp`, `$TMPDIR`) — killing a temp profile can never lose personal browser data |
| 2. DEAD LAUNCHER | the ancestor chain above the browser consists only of launchd-adopted (PPID=1) or fingerprinted automation daemons; any live non-automation parent anchors it to an active session and rejects the tree |
| 3. NO DRIVER | `--remote-debugging-pipe` (far end was the dead parent → provably unusable), OR `--remote-debugging-port` with no ESTABLISHED lsof connection, OR no debugging channel at all |
| 4. KNOWN FINGERPRINT | some command in the tree matches a known automation stack (playwright, puppeteer, chrome-devtools, selenium, cypress, rebrowser). Unmatched trees are reported UNRECOGNIZED and never killed |

Kill behavior:

- Kill order: orchestrator daemons first (topmost), then browser descendants, then the browser root — so nothing respawns mid-cleanup.
- SIGTERM first, 5s grace, then SIGKILL survivors.
- PID-recycling guard: immediately before each signal the pid's live command is re-read and compared to the classified command; a recycled pid is skipped.
- Every `--do-it` run is logged to `cleanup.log` with root pid and the full kill list.
- `SUMMARY mode=kill-orphans confirmed=<n> killed=<n> grace_killed=<n> unrecognized=<n> …` is the machine-readable last line.

Agent guidance:

- The user will not run this script by hand — run the dry-run, present the CONFIRMED ORPHAN lines (pid, command, kill order) to the user, and only use `--do-it` after their approval.
- UNRECOGNIZED candidates are never auto-killed: show them to the user for manual review.
- `scan`/`delete` remain disk-only; `kill-orphans` never deletes files and `delete` never kills processes.

## Proactive use

A read-only `scan` is appropriate when:

- the user reports low disk space or `no space left on device`
- browser-driven coding agents have been used heavily
- one of the known cache directories appears unusually large

A read-only `kill-orphans` (dry-run) is appropriate when:

- the user reports heat, fanless-Mac warmth, or unexplained CPU use while idle
- a browser-automation agent session crashed or was killed
- browser helper processes appear in `ps`/Activity Monitor with no visible browsing activity

Do not perform deletion or killing merely because a scan found reclaimable data. Follow the user's intent.

## Reading the result

Exit codes:

- `0`: success
- `1`: one or more deletions failed
- `2`: invalid argument

The final output line is machine-readable:

```text
SUMMARY mode=<scan|delete|kill-orphans> …
```

- scan/delete: `SUMMARY mode=<scan|delete> freed_mb=<n> deleted=<n> skipped=<n> failed=<n>`
- kill-orphans: `SUMMARY mode=kill-orphans confirmed=<n> killed=<n> grace_killed=<n> unrecognized=<n> deleted=n/a skipped=0 failed=0`

Deletion results and kill actions are appended to `cleanup.log` beside the script.

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
- kill-orphans adds the same default-deny discipline to processes: four independent gates must all pass, self/parent/PID-1 are protected, PID recycling is guarded against, and only known automation fingerprints are ever signalled.
- Tests: run with stock macOS bash via `/bin/bash tests/run_tests.sh` (fixtures inject fake process tables via `CLEANUP_CHROMES_PS_HOOK` / `CLEANUP_CHROMES_LSOF_HOOK`).

## Notes

- **Never quote a clone root's size as expected gain.** Scan output marks clone sizes `apparent` because APFS copy-on-write shares blocks with the app bundle; the only true number is the df-measured `freed_mb` reported after `delete`. Saying "this will free 38 GB" because `du` said so is wrong and misleads the user.

- **Never treat busy CPU as proof of live use.** The motivating case: an orphaned playwright daemon + headless Chrome ran for 2.5 hours at 40-60% CPU making a MacBook Air hot while the user did nothing. The debugging pipe's far end was dead — nothing could ever consume its work again.

- Browser automation tools have their own cache-management behavior, but large persistent caches can still remain across versions, agents, and abandoned installs.
- Deleted browser binaries may re-download the next time the corresponding tool runs.
- `code_sign_clone` sizes reported by `du` are apparent sizes. APFS copy-on-write clones share blocks, so actual reclaimed space can be much smaller. Trust the script's before/after `df` measurement.
- A reboot can clear transient `code_sign_clone` entries, while the persistent browser caches listed above generally require tool-specific or manual cleanup.
- A very small check-then-delete race remains possible if another process starts at the exact instant between the final check and deletion. The same applies to kill-orphans: a process could theoretically change state between classification and signalling; the pid-recycling guard narrows this to a tiny window but cannot eliminate it.
