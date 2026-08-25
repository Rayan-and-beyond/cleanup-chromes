#!/bin/bash
# cleanup-chromes.sh — safely remove agent-left test browsers + macOS code_sign_clones.
#
# Usage: cleanup-chromes.sh [scan|delete]   (default: scan = read-only, non-destructive)
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
set -u
shopt -s nullglob 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/cleanup.log"

usage() {
  echo "Usage: $(basename "$0") [scan|delete]" >&2
  echo "  scan   (default) — read-only, lists what would be removed" >&2
  echo "  delete            — removes everything the scan marks SAFE" >&2
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
  run_cleanup "$@"
  exit $?
fi
