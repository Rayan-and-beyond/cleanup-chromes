#!/bin/bash
# run_tests.sh — test harness for cleanup-chromes.sh
#
# ALWAYS run via stock macOS bash:  /bin/bash tests/run_tests.sh
# Homebrew/newer bash will NOT reproduce the Bash 3.2 empty-array bugs.
#
# SAFETY MODEL:
#   - scan-mode tests are read-only and always safe to run
#   - delete-mode tests are BLOCKED unless the script-under-test supports the
#     CLEANUP_CHROMES_CLONE_GLOB override; without it, a delete run could act
#     on the real machine's caches/clones, so the harness refuses to proceed
#   - integration tests create fake clone roots named after FAKE bundle IDs
#     (or a fake com.microsoft.edgemac root) inside the real per-user X temp
#     dir — harmless — and remove them again on exit
#
# Exit codes: 0 = all tests passed/skipped-safely, 1 = at least one failure.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/cleanup-chromes.sh"
BASH_BIN="/bin/bash"

pass=0; fail=0; blocked=0
RC=0; OUT=""; ERR=""
X_DIR=""
FAKE_HOME=""

note() { printf '%s\n' "$*"; }
record_pass() { pass=$((pass+1)); note "  ✅ PASS: $1"; }
record_fail() { fail=$((fail+1)); note "  ❌ FAIL: $1"; }
record_blocked() { blocked=$((blocked+1)); note "  ⛔ BLOCKED-UNSAFE: $1"; }

cleanup_traps() {
  [ -n "$X_DIR" ] || return 0
  remove_test_clone "com.definitely.not.real.app42"
  remove_test_clone "com.microsoft.edgemac"
  remove_test_clone "com.openai.codex"
  [ -n "$FAKE_HOME" ] && rm -rf "$FAKE_HOME"
  return 0
}

# Remove ONLY clones this harness created (they carry our marker subdir);
# a same-named real-world clone without the marker is left alone.
remove_test_clone() {
  local d="$X_DIR/$1.code_sign_clone"
  [ -d "$d/code_sign_clone.testbundle" ] && rm -rf "$d"
  return 0
}
trap cleanup_traps EXIT

# --- Environment sanity -----------------------------------------------------
bash_major="$($BASH_BIN -c 'echo "${BASH_VERSION%%.*}"')"
if [ "$bash_major" -ge 4 ] 2>/dev/null; then
  note "WARNING: $BASH_BIN is version $BASH_VERSION — Bash 3.2 crash bugs won't reproduce here."
fi

if $BASH_BIN -c 'set -u; arr=(); for i in "${arr[@]}"; do :; done' >/dev/null 2>&1; then
  note "NOTE: this bash does NOT crash on empty arrays — array-crash tests lose teeth here."
else
  note "NOTE: $BASH_BIN crashes on empty-array expansion (Bash < 4.4) — bugs are reproducible."
fi

for d in /private/var/folders/*/*/X; do
  [ -d "$d" ] && X_DIR="$d" && break
done

FAKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cleanup-chromes-test.XXXXXX")"

make_fake_clone() { # $1 = basename without .code_sign_clone suffix
  if [ -z "$X_DIR" ]; then note "  (no X_DIR found — cannot create fake clone)"; return 1; fi
  mkdir -p "$X_DIR/$1.code_sign_clone/code_sign_clone.testbundle" 2>/dev/null
}

script_supports_glob_hook() {
  grep -q 'CLEANUP_CHROMES_CLONE_GLOB' "$SCRIPT"
}

# run_script <mode> <clone-glob-or-empty> ; fills RC/OUT/ERR globals
run_script() {
  local mode="$1" glob="$2"
  local tf
  tf="$(mktemp)"
  HOME="$FAKE_HOME" CLEANUP_CHROMES_CLONE_GLOB="$glob" \
    $BASH_BIN "$SCRIPT" "$mode" >"$tf.out" 2>"$tf.err"
  RC=$?
  OUT="$(cat "$tf.out")"
  ERR="$(cat "$tf.err")"
  rm -f "$tf" "$tf.out" "$tf.err"
}

# --- Tests ------------------------------------------------------------------

t1_scan_with_zero_targets_does_not_crash() {
  note "T1: scan with zero matching targets survives stock Bash 3.2 (empty arrays)"
  run_script scan "/nonexistent/*.code_sign_clone"
  if [ "$RC" -ne 0 ]; then record_fail "T1 (exit=$RC)"; return; fi
  case "$ERR" in *unbound*) record_fail "T1 (crashed: $ERR)"; return;; esac
  case "$OUT" in
    *"Nothing safe"*) ;;
    *) record_fail "T1 (missing 'Nothing safe' — glob override not honored?)"; return;;
  esac
  case "$OUT" in *SUMMARY\ mode=scan*) ;; *) record_fail "T1 (missing SUMMARY line)"; return;; esac
  record_pass "T1"
}

t2_delete_with_zero_targets_does_not_crash() {
  note "T2: delete with zero matching targets survives stock Bash 3.2 (empty safe_list loop)"
  if ! script_supports_glob_hook; then
    record_blocked "T2 (script lacks CLEANUP_CHROMES_CLONE_GLOB — running delete could touch real data)"
    return
  fi
  run_script delete "/nonexistent/*.code_sign_clone"
  if [ "$RC" -ne 0 ]; then record_fail "T2 (exit=$RC)"; return; fi
  case "$ERR" in *unbound*) record_fail "T2 (crashed: $ERR)"; return;; esac
  case "$OUT" in
    *"SUMMARY mode=delete freed_mb=0 deleted=0 skipped=0 failed=0"*) ;;
    *) record_fail "T2 (unexpected SUMMARY: $(printf '%s\n' "$OUT" | grep SUMMARY))"; return;;
  esac
  record_pass "T2"
}

t3_chrome_clone_marked_in_use_while_chrome_runs() {
  note "T3: com.google.Chrome.code_sign_clone is IN USE while Google Chrome runs (real machine)"
  if ! pgrep -x "Google Chrome" >/dev/null 2>&1; then
    note "  (skipped content-check: Chrome is not running)"
    return
  fi
  run_script scan ""
  local line
  line="$(printf '%s\n' "$OUT" | grep 'com.google.Chrome.code_sign_clone' | head -1)"
  if [ -z "$line" ]; then record_fail "T3 (clone root not reported at all)"; return; fi
  case "$line" in *"SAFE"*) record_fail "T3 (marked SAFE while Chrome runs!): $line"; return;; esac
  case "$line" in
    *"IN USE"*"Google Chrome"*) record_pass "T3";;
    *) record_fail "T3 (expected IN USE + 'Google Chrome'): $line";;
  esac
}

t4_brave_clone_follows_live_brave_state() {
  note "T4: com.brave.Browser.code_sign_clone tracks whether Brave Browser is running"
  run_script scan ""
  local line
  line="$(printf '%s\n' "$OUT" | grep 'com.brave.Browser.code_sign_clone' | head -1)"
  if [ -z "$line" ]; then note "  (skipped: no Brave clone root present)"; return; fi
  if pgrep -x "Brave Browser" >/dev/null 2>&1; then
    case "$line" in *"IN USE"*) record_pass "T4";; *) record_fail "T4 ($line)";; esac
  else
    case "$line" in *"SAFE"*) record_pass "T4";; *) record_fail "T4 ($line)";; esac
  fi
}

t5_unknown_owner_clone_is_refused_in_scan() {
  note "T5: unknown-bundle-ID clone root is REFUSEd in scan (default-deny)"
  make_fake_clone "com.definitely.not.real.app42" || { note "  (setup failed)"; return; }
  run_script scan ""
  local line
  line="$(printf '%s\n' "$OUT" | grep 'com.definitely.not.real.app42.code_sign_clone' | head -1)"
  case "$line" in
    *REFUSE*) record_pass "T5";;
    "") record_fail "T5 (unknown-owner clone absent from output)";;
    *) record_fail "T5 (unknown owner offered as SAFE): $line";;
  esac
}

t6_unknown_owner_clone_survives_delete_mode() {
  note "T6: delete mode refuses and preserves an unknown-bundle-ID clone root"
  if ! script_supports_glob_hook; then
    record_blocked "T6 (script lacks CLEANUP_CHROMES_CLONE_GLOB — running delete could touch real data)"
    return
  fi
  make_fake_clone "com.definitely.not.real.app42" || { note "  (setup failed)"; return; }
  run_script delete "/private/var/folders/*/*/X/com.definitely.not.real.app42.code_sign_clone"
  if [ ! -d "$X_DIR/com.definitely.not.real.app42.code_sign_clone" ]; then
    record_fail "T6 (unknown-owner clone was DELETED)"
    return
  fi
  case "$OUT" in
    *REFUSE*"com.definitely.not.real.app42"*) ;;
    *) record_fail "T6 (delete run did not report REFUSE for unknown owner)"; return;;
  esac
  case "$(printf '%s\n' "$OUT" | grep SUMMARY)" in
    *"deleted=0"*) record_pass "T6";;
    *) record_fail "T6 (deleted!=0): $(printf '%s\n' "$OUT" | grep SUMMARY)";;
  esac
}

t7_known_idle_fake_clone_is_safe_then_deleted() {
  note "T7: known bundle ID (edgemac), app idle — fake clone is SAFE in scan, removed by delete"
  if pgrep -x "Microsoft Edge" >/dev/null 2>&1; then
    note "  (skipped: Microsoft Edge is running)"
    return
  fi
  make_fake_clone "com.microsoft.edgemac" || { note "  (setup failed)"; return; }
  local glob="/private/var/folders/*/*/X/com.microsoft.edgemac.code_sign_clone"

  run_script scan "$glob"
  local line
  line="$(printf '%s\n' "$OUT" | grep 'com.microsoft.edgemac.code_sign_clone' | head -1)"
  case "$line" in
    *"SAFE"*) ;;
    "") record_fail "T7 (scan did not surface fake edgemac clone — glob override broken?)"; return;;
    *) record_fail "T7 (not SAFE while Edge idle): $line"; return;;
  esac

  if ! script_supports_glob_hook; then
    record_blocked "T7-delete (script lacks glob override; scan half passed)"
    return
  fi
  run_script delete "$glob"
  if [ "$RC" -ne 0 ]; then record_fail "T7 (delete exit=$RC)"; return; fi
  case "$(printf '%s\n' "$OUT" | grep SUMMARY)" in
    *"deleted=1"*) ;;
    *) record_fail "T7 (deleted!=1): $(printf '%s\n' "$OUT" | grep SUMMARY)"; return;;
  esac
  if [ -d "$X_DIR/com.microsoft.edgemac.code_sign_clone" ]; then
    record_fail "T7 (fake clone still present after delete)"
  else
    record_pass "T7"
  fi
}

t8_unit_bundle_id_table_and_cache_guards() {
  note "T8: unit — clone bundle-ID allowlist table + legacy cache process guards"
  local probe
  probe="$($BASH_BIN -c '
    source "'"$SCRIPT"'" >/dev/null 2>&1 || exit 97
    c1="$(clone_guard_pattern com.google.Chrome 2>/dev/null)"
    c2="$(clone_guard_pattern com.openai.codex 2>/dev/null)"
    c3="$(clone_guard_pattern com.openai.chat 2>/dev/null)"
    c4="$(clone_guard_pattern com.brave.Browser 2>/dev/null)"
    c5="$(clone_guard_pattern com.microsoft.edgemac 2>/dev/null)"
    c6="$(clone_guard_pattern com.unknown.things.app 2>/dev/null)"
    g1="$(guard_proc_for "$HOME/.cache/chrome-devtools-mcp" 2>/dev/null)"
    g2="$(guard_proc_for "$HOME/.cache/puppeteer" 2>/dev/null)"
    printf "%s|%s|%s|%s|%s|%s|%s|%s" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$g1" "$g2"
  ' 2>/dev/null)"
  case "$probe" in
    "Google Chrome|Codex|ChatGPT|Brave Browser|Microsoft Edge||chrome-devtools|puppeteer")
      record_pass "T8";;
    "")
      record_fail "T8 (could not source script / functions missing)";;
    *)
      record_fail "T8 (got: $probe)";;
  esac
}

t9_unit_looks_dangerous_still_refuses_real_profiles() {
  note "T9: unit — looks_dangerous refusals unchanged"
  local probe
  probe="$($BASH_BIN -c '
    source "'"$SCRIPT"'" >/dev/null 2>&1 || exit 97
    d1=0; looks_dangerous "$HOME/Library/Application Support/Google/Chrome" && d1=1
    d2=0; looks_dangerous "/Applications/Safari.app" && d2=1
    d3=0; looks_dangerous "$HOME" && d3=1
    d4=0; looks_dangerous "$HOME/.cache/puppeteer" && d4=1
    printf "%s%s%s%s" "$d1" "$d2" "$d3" "$d4"
  ' 2>/dev/null)"
  case "$probe" in
    "1110") record_pass "T9";;
    "")     record_fail "T9 (could not source script)";;
    *)      record_fail "T9 (got: $probe)";;
  esac
}

t10_cli_contract_unchanged() {
  note "T10: CLI contract — bad arg exits 2, --help exits 0, no-arg defaults to scan"
  $BASH_BIN "$SCRIPT" bogus >/dev/null 2>&1; local r1=$?
  $BASH_BIN "$SCRIPT" --help >/dev/null 2>&1; local r2=$?
  run_script "" "/nonexistent/*.code_sign_clone"
  case "$r1:$r2:$RC" in
    "2:0:0") record_pass "T10";;
    *)       record_fail "T10 (bogus=$r1 help=$r2 default=$RC)";;
  esac
}

t11_clone_guard_ignores_cmdline_substring_decoys() {
  note "T11: clone owner guard uses EXACT process names — a decoy whose args merely contain the name must not trigger it"
  if ! script_supports_glob_hook; then
    record_blocked "T11 (script lacks CLEANUP_CHROMES_CLONE_GLOB)"
    return
  fi
  make_fake_clone "com.openai.codex" || { note "  (setup failed)"; return; }
  local glob="/private/var/folders/*/*/X/com.openai.codex.code_sign_clone"

  # Decoy: process named "bash"/"sleep", but its ARGV contains the exact word
  # "Codex". pgrep -f would match it; pgrep -x must not.
  /bin/bash -c 'sleep 30' Codex &
  local decoy_pid=$!
  trap 'kill '"$decoy_pid"' 2>/dev/null; cleanup_traps' EXIT

  run_script scan "$glob"
  local line
  line="$(printf '%s\n' "$OUT" | grep 'com.openai.codex.code_sign_clone' | head -1)"
  kill "$decoy_pid" 2>/dev/null
  wait "$decoy_pid" 2>/dev/null

  case "$line" in
    *"SAFE"*) record_pass "T11";;
    "") record_fail "T11 (fake codex clone absent from scan output)";;
    *) record_fail "T11 (cmdline decoy triggered the guard — clone not SAFE): $line";;
  esac
}

# --- Runner -----------------------------------------------------------------
note "== cleanup-chromes test suite ($($BASH_BIN --version | head -1)) =="
note ""
t1_scan_with_zero_targets_does_not_crash
t2_delete_with_zero_targets_does_not_crash
t3_chrome_clone_marked_in_use_while_chrome_runs
t4_brave_clone_follows_live_brave_state
t5_unknown_owner_clone_is_refused_in_scan
t6_unknown_owner_clone_survives_delete_mode
t7_known_idle_fake_clone_is_safe_then_deleted
t8_unit_bundle_id_table_and_cache_guards
t9_unit_looks_dangerous_still_refuses_real_profiles
t10_cli_contract_unchanged
t11_clone_guard_ignores_cmdline_substring_decoys

note ""
note "== Results: $pass passed, $fail failed, $blocked blocked-unsafe =="

[ "$fail" -eq 0 ]
exit $?
