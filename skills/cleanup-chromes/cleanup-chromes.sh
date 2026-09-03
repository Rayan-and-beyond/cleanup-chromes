#!/bin/bash
# cleanup-chromes.sh — safely remove agent-left test browsers + macOS code_sign_clones,
# and terminate orphaned automation browser process trees.
#
# Usage: cleanup-chromes.sh [scan|delete|kill-orphans [--do-it]]
#                          (default: scan = read-only, non-destructive)
#
# SAFE by design:
#   - only the hardcoded throwaway paths below are ever considered
#   - code_sign_clones are allowlisted by owning bundle ID (taken from the
#     directory name); any other bundle ID is REFUSEd — default-deny
#   - a known-but-running owner app marks its clone IN USE (pgrep), because a
#     running app can own an active clone without holding files open (lsof
#     alone is NOT sufficient for clones)
#   - anything a running process holds open (lsof) is skipped
#   - real browser profiles / /Applications are hard-refused
#   - "delete" re-runs the same safety checks as "scan" — it does not depend on
#     scan having been run first, so either mode is safe to call on its own
#   - "kill-orphans" terminates headless automation browser trees only after
#     ALL of its gates pass (headless+temp profile, dead launcher, no driver,
#     known fingerprint) — see the kill-orphans section below; without
#     --do-it it is a read-only dry-run
#
# Exit codes: 0 = success (nothing to do, or all deletions succeeded)
#             1 = one or more deletions failed
#             2 = bad usage (invalid argument)
#
# Notes for anyone extending this script:
#   - macOS ships bash 3.2 system-wide (licensing, not a version choice) — avoid
#     bash 4+ syntax (associative arrays, ${var,,}, mapfile, etc.), and note
#     that `set -u` + expanding an EMPTY array crashes on 3.2: always use the
#     "${arr[@]+"${arr[@]}"}" idiom for any array that can be empty
#   - if you've overridden du/df/lsof/pgrep with GNU coreutils (e.g. via
#     `brew install coreutils` with default names), output parsing may differ
#     slightly from the BSD tools this was written against
#   - delete refreshes lsof and process guards immediately before each rm; as
#     with any filesystem check, an extremely small check-to-delete race can
#     still exist if another process starts at exactly that instant
#   - tests live in tests/ — run them with stock bash: /bin/bash tests/run_tests.sh
#   - CLEANUP_CHROMES_CLONE_GLOB overrides the clone glob (test isolation hook;
#     leave unset for normal use)
#   - CLEANUP_CHROMES_PS_HOOK overrides the process-listing command for
#     kill-orphans (test isolation hook; leave unset for normal use). It must
#     output lines of: PID<TAB>PPID<TAB>ELAPSED<TAB>COMMAND
#   - CLEANUP_CHROMES_LSOF_HOOK overrides the `lsof -i` port-check command for
#     kill-orphans (test isolation hook; leave unset for normal use)
set -u
shopt -s nullglob 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/cleanup.log"

usage() {
  echo "Usage: $(basename "$0") [scan|delete|kill-orphans [--do-it]]" >&2
  echo "  scan          (default) — read-only, lists what would be removed" >&2
  echo "  delete                  — removes everything the scan marks SAFE" >&2
  echo "  kill-orphans            — reports orphaned automation browser trees" >&2
  echo "     [--do-it]              with --do-it: actually kills them" >&2
}

# --- Targets ---------------------------------------------------------------
CACHE_TARGETS=(
  "$HOME/Library/Caches/ms-playwright"
  "$HOME/Library/Caches/ms-playwright-go"
  "$HOME/.cache/ms-playwright"
  "$HOME/.cache/puppeteer"
  "$HOME/Library/Caches/Cypress"
  "$HOME/.cache/rebrowser-puppeteer"
  "$HOME/.cache/selenium"
  "$HOME/.cache/chrome-devtools-mcp"
  "$HOME/Library/Caches/chromium"
)
# Unquoted $CLONE_GLOB on purpose: the glob must expand here (nullglob applies).
# The ${arr[@]+"${arr[@]}"} idiom below is REQUIRED: with `set -u`, expanding an
# empty array crashes bash 3.2 (stock macOS) when no clone roots match.
CLONE_GLOB="${CLEANUP_CHROMES_CLONE_GLOB:-/private/var/folders/*/*/X/*.code_sign_clone}"
CLONE_TARGETS=( ${CLONE_GLOB} )
TARGETS=( "${CACHE_TARGETS[@]}" ${CLONE_TARGETS[@]+"${CLONE_TARGETS[@]}"} )

is_in_use() {  # true if any open file path lives inside dir "$1"
  printf '%s\n' "$OPEN" | grep -qF -- "$1/"
}

human() { du -sh "$1" 2>/dev/null | cut -f1; }

refresh_open_files() {
  OPEN="$(lsof -w -Fn 2>/dev/null | sed -n 's/^n//p')"
}

# macOS names each clone root after the bundle identifier of the app that owns
# it (com.google.Chrome.code_sign_clone belongs to Google Chrome), so the exact
# bundle ID is allowlisted and mapped to the process pattern proving the owner
# runs. Bundle IDs and process names differ (Chrome's CFBundleName is "Chrome",
# its process is "Google Chrome"), so a lookup table is unavoidable — keep it
# exact. Anything not listed is refused: default-deny means newly appearing
# apps are never auto-deleted.
#
# IMPORTANT: these patterns must be the app's real PROCESS name, verified with
# `pgrep -x "<name>"` while the app runs (clone guards match exactly via -x —
# see classify_target).
clone_guard_pattern() {
  case "$1" in
    com.google.Chrome)     echo "Google Chrome" ;;
    com.openai.codex)      echo "Codex" ;;
    com.openai.chat)       echo "ChatGPT" ;;
    com.brave.Browser)     echo "Brave Browser" ;;
    com.microsoft.edgemac) echo "Microsoft Edge" ;;
    *) echo "" ;;
  esac
}

# Some tools keep a long-lived server/process alive that will use its
# cache/profile at any moment without holding a file open right now. lsof
# can't see that, so map such targets to a process pattern that also marks
# them in-use.
guard_proc_for() {
  case "$1" in
    *chrome-devtools-mcp*) echo "chrome-devtools" ;;
    *puppeteer*)           echo "puppeteer" ;;
    *Cypress*)             echo "Cypress" ;;
    *playwright*)          echo "playwright" ;;
    *selenium*)             echo "selenium" ;;
    *) echo "" ;;
  esac
}

looks_dangerous() {  # refuse anything that resembles real user data
  case "$1" in
    *"/Application Support/Google/Chrome"*|*"/Application Support/BraveSoftware"*|\
    *"/Application Support/Microsoft Edge"*|/Applications/*|"$HOME"|"$HOME/") return 0;;
    *) return 1;;
  esac
}

# Classify one existing target. Sets globals:
#   C_SIZE, C_STATUS (SAFE | INUSE | REFUSE), C_REASON, C_PAT
# Used by BOTH the scan listing and the per-target pre-delete re-check so the
# two code paths can never drift apart.
#
# Clone owners are matched with `pgrep -x` (exact process NAME): the table maps
# verified process names, and a substring match would let unrelated processes
# (e.g. "CodexBar", or any command whose args mention the name) block cleanup.
# Cache guards keep `pgrep -f` on purpose — there we WANT to catch any command
# line that mentions the tool.
classify_target() {
  C_SIZE="$(human "$1")"; C_STATUS="SAFE"; C_REASON=""; C_PAT=""; C_PGREP_FL=""; C_IS_CLONE=0
  if looks_dangerous "$1"; then
    C_STATUS="REFUSE"; C_REASON="looks like real data"
    return
  fi
  case "$1" in
    *.code_sign_clone)
      C_IS_CLONE=1
      C_PAT="$(clone_guard_pattern "$(basename "${1%.code_sign_clone}")")"
      if [ -z "$C_PAT" ]; then
        C_STATUS="REFUSE"
        C_REASON="unknown clone owner '$(basename "${1%.code_sign_clone}")'"
        return
      fi
      C_PGREP_FL="-ix"
      ;;
    *)
      C_PAT="$(guard_proc_for "$1")"
      C_PGREP_FL="-if"
      ;;
  esac
  if is_in_use "$1"; then
    C_STATUS="INUSE"; C_REASON="open files"
    return
  fi
  if [ -n "$C_PAT" ] && pgrep $C_PGREP_FL "$C_PAT" >/dev/null 2>&1; then
    C_STATUS="INUSE"; C_REASON="'$C_PAT' process running"
  fi
}

# =============================================================================
# kill-orphans: terminate orphaned headless automation-browser process trees
# =============================================================================
#
# An automation browser becomes an ORPHAN when the agent tool that launched it
# died without cleaning up (e.g. a crashed coding-agent session). The orphan
# keeps burning CPU forever — on fanless Macs this alone makes the chassis
# hot. Busy-ness proves nothing: an orphan can spin at 100% CPU on queued
# work, so idle time is deliberately NOT a criterion.
#
# A tree is confirmed orphaned ONLY when ALL four gates pass (default-deny):
#   Gate 1  BROWSER+PROFILE  command has --headless AND --user-data-dir points
#           into a temp location (/var/folders, /tmp, $TMPDIR). Killing a temp
#           profile can never destroy personal browser data.
#   Gate 2  DEAD LAUNCHER    every process ABOVE the browser in the tree is
#           itself orphaned (PPID=1): a dead launchd-reparented chain proves
#           no living launcher session owns the browser. Any live ancestor
#           rejects the tree — it is someone's active session.
#   Gate 3  NO DRIVER        nobody can be driving it anymore:
#           - --remote-debugging-pipe: the pipe's far end was the dead parent
#             -> provably unusable -> confirmed.
#           - --remote-debugging-port: lsof must show NO established
#             connection to that port. An established peer means live use.
#           - neither flag: not confirmed (cannot prove no driver exists).
#   Gate 4  KNOWN FINGERPRINT  some command in the tree matches a known
#           automation stack (playwright/puppeteer/selenium/cypress/
#           chrome-devtools/CDP flags). Unmatched trees are reported as
#           UNRECOGNIZED, never killed.
#
# Trees are killed descendants-first, then the browser root, then orphaned
# orchestrator daemons above it — so nothing respawns mid-cleanup. SIGTERM
# first, 5s grace, then SIGKILL.

# Test hooks. CLEANUP_CHROMES_PS_HOOK must output "PID<TAB>PPID<TAB>ELAPSED<TAB>COMMAND"
# lines; CLEANUP_CHROMES_LSOF_HOOK replaces `lsof -i -n -P`.
list_procs() {
  if [ -n "${CLEANUP_CHROMES_PS_HOOK:-}" ]; then
    "$CLEANUP_CHROMES_PS_HOOK"
  else
    ps -Ao pid=,ppid=,etime=,command= 2>/dev/null
  fi
}

lsof_inet() {
  if [ -n "${CLEANUP_CHROMES_LSOF_HOOK:-}" ]; then
    "$CLEANUP_CHROMES_LSOF_HOOK" "$@"
  else
    lsof -i -n -P 2>/dev/null
  fi
}

# Gate 4 helper: does a command line belong to a known automation stack?
# NOTE: the CDP debugging flags are deliberately NOT fingerprints — gate 3
# already requires one on the browser root, so counting them here would make
# gate 4 vacuous. Gate 4 means: a recognizable automation TOOL is involved.
known_automation_fingerprint() {
  case "$1" in
    *playwright*|*Playwright*|*puppeteer*|*Puppeteer*|\
    *chrome-devtools*|*CDPScreenshotNewSurface*|*rebrowser*|\
    *selenium*|*Selenium*|*cypress*|*Cypress*) return 0 ;;
    *) return 1 ;;
  esac
}

# Gate 1 helper: is this profile path a throwaway temp dir?
is_temp_profile() {
  case "$1" in
    /var/folders/*|/private/var/folders/*|/tmp/*|/private/tmp/*|\
    "${TMPDIR:-/__none__}"*) return 0 ;;
    *) return 1 ;;
  esac
}

extract_user_data_dir() {
  printf '%s\n' "$1" | sed -n 's/.*--user-data-dir=\([^ ]*\).*/\1/p' | head -1
}

# Gate 3 helper: is anything ESTABLISHED against this CDP port right now?
port_has_peer() {
  lsof_inet -i ":$1" 2>/dev/null | grep -q "ESTABLISHED"
}

# ---- tiny helpers over the PS_LINES table (PID/PPID/ELAPSED/CMD) -----------
field_of() {  # $1=pid  $2=field(1..4)
  awk -F'\t' -v p="$1" -v f="$2" '$1==p{print $f; exit}' <<< "$PS_LINES"
}

# All strict descendants of pid $1 (excluding $1), space-separated in $REPLY_DESC.
descendants_of() {
  REPLY_DESC=""
  local frontier="$1" added=1
  while [ "$added" = "1" ]; do
    added=0
    local pid ppid
    while IFS=$'\t' read -r pid ppid _; do
      [ -n "${pid:-}" ] || continue
      case " $REPLY_DESC " in *" $pid "*) continue ;; esac
      [ "$pid" = "$1" ] && continue
      local f
      for f in $frontier; do
        if [ "$ppid" = "$f" ]; then
          REPLY_DESC="$REPLY_DESC $pid"
          added=1
          break
        fi
      done
    done <<< "$PS_LINES"
    frontier="$REPLY_DESC"
  done
  REPLY_DESC="${REPLY_DESC# }"
}

# Walk UP from the browser root through its ancestor chain. The chain is
# confirmed orphaned only when we reach a process whose own parent is 1/0
# (launchd adopted it — its launcher died) or that is missing from the table
# (parent exited mid-scan). We may pass THROUGH intermediate ancestors only if
# they themselves are fingerprinted automation daemons; any other live parent
# anchors the chain to an active session and REJECTS the tree.
# Sets:
#   ORPHANED_ANCESTORS  chain members (topmost-first, excludes the browser)
#   ANCHOR_LIVE         nonempty = rejected, holds the anchoring live pid
ancestor_chain() {
  ORPHANED_ANCESTORS=""; ANCHOR_LIVE=""
  local cur="$1" guard=0 ppid parent_found parent_cmd
  while [ "$guard" -lt 64 ]; do
    guard=$((guard + 1))
    ppid="$(field_of "$cur" 2)"
    [ -n "$ppid" ] || break
    if [ "$ppid" = "1" ] || [ "$ppid" = "0" ]; then
      return  # cur is launchd-adopted: chain ends, confirmed
    fi
    parent_found="$(field_of "$ppid" 1)"
    if [ -z "$parent_found" ]; then
      return  # parent absent from table: treat as dead launcher
    fi
    parent_cmd="$(field_of "$ppid" 4)"
    if known_automation_fingerprint "$parent_cmd"; then
      ORPHANED_ANCESTORS="$ppid ${ORPHANED_ANCESTORS}"  # prepend: topmost ends up first
      cur="$ppid"
      continue
    fi
    ANCHOR_LIVE="$ppid"
    return
  done
}

# Classify the tree rooted at a headless-browser process $1.
# Sets globals: K_STATUS (CONFIRMED|UNRECOGNIZED|REJECT), K_REASON,
#   KILL_PIDS (ordered: orphaned orchestrators topmost-first, then browser
#   descendants, then the browser root — daemons die first so nothing can
#   respawn the browser mid-cleanup), K_ELAPSED, K_CMD.
classify_orphan_tree() {
  K_STATUS="REJECT"; K_REASON=""; KILL_PIDS=""; K_ELAPSED=""; K_CMD=""
  local root="$1"
  K_CMD="$(field_of "$root" 4)"
  K_ELAPSED="$(field_of "$root" 3)"
  [ -n "$K_CMD" ] || { K_REASON="process vanished"; return; }

  # Self-protection: never classify/kill PID 1, our own pid, or our parents.
  case "$root" in
    1|"$$"|"${PPID:-0}") K_REASON="protected process"; return ;;
  esac

  # Gate 1: headless + temp profile.
  case "$K_CMD" in
    *--headless*) : ;;
    *) K_REASON="not headless"; return ;;
  esac
  local udd
  udd="$(extract_user_data_dir "$K_CMD")"
  if [ -z "$udd" ] || ! is_temp_profile "$udd"; then
    K_REASON="profile not a temp dir"
    return
  fi

  # Gate 3: driver-channel check.
  case "$K_CMD" in
    *--remote-debugging-pipe*) : ;;
    *--remote-debugging-port=*)
      local port
      port="$(printf '%s\n' "$K_CMD" | sed -n 's/.*--remote-debugging-port=\([0-9][0-9]*\).*/\1/p' | head -1)"
      if [ -n "$port" ] && port_has_peer "$port"; then
        K_REASON="live CDP connection on port $port"
        return
      fi
      ;;
    *) K_REASON="no debugging channel; cannot prove absence of a driver"
       return ;;
  esac

  # Gate 2: ancestor walk (see ancestor_chain).
  ancestor_chain "$root"
  if [ -n "$ANCHOR_LIVE" ]; then
    K_REASON="launcher chain anchored by live pid $ANCHOR_LIVE"
    return
  fi

  # Gate 4: some command in the tree (browser, descendants, or orphaned
  # orchestrators) must carry a known automation fingerprint.
  descendants_of "$root"
  local tree_pids="$REPLY_DESC"
  local fp="" p c
  for p in $root $tree_pids ${ORPHANED_ANCESTORS}; do
    c="$(field_of "$p" 4)"
    if known_automation_fingerprint "$c"; then fp=1; break; fi
  done
  if [ -z "$fp" ]; then
    K_STATUS="UNRECOGNIZED"
    K_REASON="no known automation fingerprint in tree"
    return
  fi

  # All gates passed. Record expected commands for the pid-recycling guard.
  KILL_PIDS="${ORPHANED_ANCESTORS#${ORPHANED_ANCESTORS%%[! ]*}} ${tree_pids} ${root}"
  KILL_PIDS="${KILL_PIDS# }"
  K_STATUS="CONFIRMED"
}

run_kill_orphans() {
  local DO_IT=0
  if [ "${1:-}" = "--do-it" ]; then DO_IT=1; shift; fi
  if [ $# -gt 0 ]; then
    echo "Error: unrecognized argument '$1' for kill-orphans" >&2
    usage
    return 2
  fi

  PS_LINES="$(list_procs)"
  SCANNED_PS_LINES="$PS_LINES"
  echo "Scanning for orphaned automation browser trees"
  echo "(headless + temp profile + dead launcher + no driver)…"
  echo

  local candidates=()
  local pid ppid etime cmd
  while IFS=$'\t' read -r pid ppid etime cmd; do
    [ -n "${pid:-}" ] || continue
    case "$cmd" in
      *--headless*) candidates+=("${candidates[@]+"${candidates[@]}"}" "$pid") ;;
    esac
  done <<< "$PS_LINES"

  local confirmed=0 unrecognized=0 killed=0 grace_killed=0
  local seen=""
  local cpid
  for cpid in ${candidates[@]+"${candidates[@]}"}; do
    case " $seen " in *" $cpid "*) continue ;; esac
    seen="$seen $cpid"

    classify_orphan_tree "$cpid"
    case "$K_STATUS" in
      CONFIRMED)
        confirmed=$((confirmed + 1))
        echo "  🎯 CONFIRMED ORPHAN: pid $cpid (up ${K_ELAPSED:-?})"
        echo "     cmd: $(printf '%s' "$K_CMD" | cut -c1-140)…"
        echo "     kill order: $(printf '%s' "$KILL_PIDS" | tr -s ' ')"
        if [ "$DO_IT" = "1" ]; then
          local kp
          for kp in $KILL_PIDS; do
            # PID-recycling guard: re-read the live process table and only
            # kill if the pid still runs the exact command we classified.
            # (field_of uses PS_LINES, so refresh it first.)
            PS_LINES="$(list_procs)"
            local live_cmd expected_cmd
            live_cmd="$(field_of "$kp" 4)"
            expected_cmd="$(awk -v p="$kp" 'BEGIN{FS="\t"} $1==p{print $4; exit}' <<< "$SCANNED_PS_LINES")"
            if [ -z "$live_cmd" ] || [ "$live_cmd" != "$expected_cmd" ]; then
              echo "     ↪ skip $kp (changed identity or exited — pid recycled?)"
              continue
            fi
            kill "$kp" 2>/dev/null && echo "     ↪ SIGTERM → $kp"
          done
          sleep 5
          for kp in $KILL_PIDS; do
            if kill -0 "$kp" 2>/dev/null; then
              if kill -9 "$kp" 2>/dev/null; then
                echo "     ↪ SIGKILL → $kp (survived TERM)"
                grace_killed=$((grace_killed + 1))
              fi
            fi
          done
          killed=$((killed + 1))
          printf '%s\tkill-orphans\troot=%s\tpids=%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$cpid" "$(printf '%s' "$KILL_PIDS" | tr -s ' ')" >> "$LOG_FILE" 2>/dev/null
        fi
        ;;
      UNRECOGNIZED)
        unrecognized=$((unrecognized + 1))
        echo "  ❓ UNRECOGNIZED (not killed — review manually): pid $cpid"
        echo "     cmd: $(printf '%s' "$K_CMD" | cut -c1-140)"
        echo
        ;;
      REJECT)
        : # gate failed; routine headless process someone still owns
        ;;
    esac
  done

  echo
  if [ "$confirmed" -eq 0 ] && [ "$unrecognized" -eq 0 ]; then
    echo "No orphaned automation browser trees found."
  fi
  echo "SUMMARY mode=kill-orphans confirmed=$confirmed killed=$killed grace_killed=$grace_killed unrecognized=$unrecognized deleted=n/a skipped=0 failed=0"
  return 0
}



main() {
  local MODE="${1:-scan}"
  case "$MODE" in
    kill-orphans)
      shift
      run_kill_orphans "$@"
      return $?
      ;;
    -h|--help|"")
      run_cleanup "$MODE"
      return $?
      ;;
    *)
      run_cleanup "$MODE"
      return $?
      ;;
  esac
}

run_cleanup() {
  MODE="${1:-scan}"
  case "$MODE" in
    scan|delete) ;;
    -h|--help) usage; return 0 ;;
    *) echo "Error: unrecognized argument '$MODE'" >&2; usage; return 2 ;;
  esac

  echo "Checking what's currently in use (lsof)…"
  OPEN="$(lsof -w -Fn 2>/dev/null | sed -n 's/^n//p')"

  # Derive the volume to measure free space on from $HOME itself, rather than a
  # hardcoded path — this stays correct even if $HOME lives on a secondary or
  # external volume.
  AVAIL_BEFORE="$(df -k "$HOME" | awk 'NR==2{print $4}')"
  safe_list=(); skip_list=(); fail_list=()

  echo
  echo "== Targets =="
  for t in "${TARGETS[@]}"; do
    [ -e "$t" ] || continue
    classify_target "$t"
    case "$C_STATUS" in
      REFUSE)
        echo "  ⛔ REFUSE ($C_REASON): $t"
        ;;
      INUSE)
        if [ "$C_IS_CLONE" = "1" ]; then
          echo "  ⏭  IN USE  (apparent ${C_SIZE})*: $t   [$C_REASON]"
        else
          echo "  ⏭  IN USE  ($C_SIZE): $t   [$C_REASON]"
        fi
        skip_list+=("$t")
        ;;
      *)
        if [ "$C_IS_CLONE" = "1" ]; then
          echo "  ✅ SAFE    (apparent ${C_SIZE})*: $t"
        else
          echo "  ✅ SAFE    ($C_SIZE): $t"
        fi
        safe_list+=("$t")
        ;;
    esac
  done

  echo
  if [ "${#safe_list[@]}" -eq 0 ]; then
    echo "Nothing safe to delete right now."
  else
    cache_list=(); clone_count=0
    for t in ${safe_list[@]+"${safe_list[@]}"}; do
      case "$t" in
        *.code_sign_clone) clone_count=$((clone_count + 1)) ;;
        *) cache_list+=(${cache_list[@]+"${cache_list[@]}"} "$t") ;;
      esac
    done
    if [ "${#cache_list[@]}" -gt 0 ]; then
      echo -n "Reclaimable from SAFE caches: "
      du -sch ${cache_list[@]+"${cache_list[@]}"} 2>/dev/null | tail -1 | cut -f1
    fi
    if [ "$clone_count" -gt 0 ]; then
      echo "* Clone sizes are APPARENT only: APFS shares blocks with the app bundle, so the"
      echo "  real gain cannot be known before deletion. The SUMMARY's df-measured freed_mb"
      echo "  is the only true number."
    fi
  fi

  freed_mb=0
  deleted_count=0

  if [ "$MODE" = "delete" ]; then
    echo
    echo "== Deleting SAFE items =="
    for t in ${safe_list[@]+"${safe_list[@]}"}; do
      # Re-check immediately before destructive action. A target may have been
      # idle during the initial scan and become active while the scan output
      # was being reviewed.
      refresh_open_files
      classify_target "$t"
      if [ "$C_STATUS" != "SAFE" ]; then
        echo "  ⏭  SKIP (became $C_STATUS): $t   [$C_REASON]"
        skip_list+=("$t")
        continue
      fi

      if rm -rf "$t"; then
        echo "  🗑  deleted: $t"
        deleted_count=$((deleted_count + 1))
        printf '%s\tdeleted\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$t" >> "$LOG_FILE" 2>/dev/null
      else
        echo "  ⚠️  failed to delete: $t"
        fail_list+=("$t")
        printf '%s\tfailed\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$t" >> "$LOG_FILE" 2>/dev/null
      fi
    done
    AVAIL_AFTER="$(df -k "$HOME" | awk 'NR==2{print $4}')"
    freed_mb=$(( (AVAIL_AFTER - AVAIL_BEFORE) / 1024 ))
    echo
    echo "Freed ~${freed_mb} MB. Free space now:"
    df -h "$HOME" | tail -1
  else
    echo "(scan only — re-run with 'delete' to remove the SAFE items above)"
  fi

  if [ "${#skip_list[@]}" -gt 0 ]; then
    echo
    echo "Skipped ${#skip_list[@]} in-use item(s). Quit the app/test that's using them, then re-run."
  fi

  if [ "${#fail_list[@]}" -gt 0 ]; then
    echo
    echo "${#fail_list[@]} item(s) failed to delete — check permissions on the paths listed above."
  fi

  # Machine-readable summary — safe to grep/parse regardless of the human-readable output above.
  echo
  echo "SUMMARY mode=$MODE freed_mb=$freed_mb deleted=$deleted_count skipped=${#skip_list[@]} failed=${#fail_list[@]}"

  [ "${#fail_list[@]}" -eq 0 ]
}

# Only execute when run directly; sourcing (e.g. by tests/) defines functions
# without side effects.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
