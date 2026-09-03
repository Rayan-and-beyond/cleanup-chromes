#!/bin/bash
# run_tests.sh — fixtures for cleanup-chromes.sh kill-orphans (and basic disk modes).
# Stock macOS bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Locate the script: sibling of tests/ (flat skill layout) or ../skills/cleanup-chromes (repo layout)
if [ -f "$SCRIPT_DIR/../cleanup-chromes.sh" ]; then
  SCRIPT="$SCRIPT_DIR/../cleanup-chromes.sh"
elif [ -f "$SCRIPT_DIR/../skills/cleanup-chromes/cleanup-chromes.sh" ]; then
  SCRIPT="$SCRIPT_DIR/../skills/cleanup-chromes/cleanup-chromes.sh"
else
  echo "error: cannot locate cleanup-chromes.sh relative to tests/" >&2
  exit 1
fi
TMP="$(mktemp -d /tmp/cleanup-chromes-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_contains() {  # $1=haystack $2=needle $3=label
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) fail "$3 — expected to contain: $2" ;;
  esac
}
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 — expected NOT to contain: $2" ;;
    *) ok "$3" ;;
  esac
}

# ---- fixture builder --------------------------------------------------------
# Each test defines PS_FIXTURE lines "PID PPID ELAPSED CMD" (spaces, converted
# to tabs; only the first 3 fields are split — the rest is the command).
make_ps_hook() {
  local f="$TMP/ps_hook_$1.sh"
  cat > "$f" <<EOF
#!/bin/bash
while IFS= read -r line; do
  [ -n "\$line" ] || continue
  pid=\${line%% *}; rest=\${line#* }
  ppid=\${rest%% *}; rest=\${rest#* }
  etime=\${rest%% *}; cmd=\${rest#* }
  printf '%s\t%s\t%s\t%s\n' "\$pid" "\$ppid" "\$etime" "\$cmd"
done < "$TMP/ps_fixture_$1.txt"
EOF
  chmod +x "$f"
  echo "$f"
}

make_lsof_hook() {
  local f="$TMP/lsof_hook_$1.sh"
  cat > "$f" <<EOF
#!/bin/bash
# args: -i :PORT  (we only emulate the port check)
if [ "\$1" = "-i" ] && [ "\$2" = ":$2" ]; then
  cat "$TMP/lsof_fixture_$1.txt" 2>/dev/null
fi
EOF
  chmod +x "$f"
  echo "$f"
}

run_scan() {   # read-only kill-orphans scan with given fixture id
  local id="$1"
  CLEANUP_CHROMES_PS_HOOK="$(make_ps_hook "$id")" \
  CLEANUP_CHROMES_LSOF_HOOK="$(make_lsof_hook "$id" 9222)" \
  /bin/bash "$SCRIPT" kill-orphans 2>&1
}

# ---- fixtures ---------------------------------------------------------------
# 1: the real-world scenario from today: orphaned node playwright daemon ->
#    headless chrome (GPU + renderer children), all reparented or daemon-rooted.
cat > "$TMP/ps_fixture_1.txt" <<'EOF'
3910 1 02:28:12 node /Users/x/.npm/_npx/abc/node_modules/playwright-core/lib/entry/cliDaemon.js photonfinish
3911 3910 02:25:36 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless --user-data-dir=/var/folders/xx/xxxxxxxxxxxxxxx/T/playwright_chromiumdev_profile-WTVyBC --remote-debugging-pipe --no-startup-window
3932 3911 02:25:30 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/152.0.7977.75/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU) --type=gpu-process --headless --user-data-dir=/var/folders/xx/xxxxxxxxxxxxxxx/T/playwright_chromiumdev_profile-WTVyBC
3944 3911 02:25:30 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/152.0.7977.75/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer) --type=renderer --headless --user-data-dir=/var/folders/xx/xxxxxxxxxxxxxxx/T/playwright_chromiumdev_profile-WTVyBC
EOF
: > "$TMP/lsof_fixture_1.txt"

# 2: live session — daemon owned by a live shell, browser under it. Must NOT kill.
cat > "$TMP/ps_fixture_2.txt" <<'EOF'
200 1 3:00:00 zsh
201 200 2:00:00 node /Users/x/.npm/_npx/abc/node_modules/playwright-core/lib/entry/cliDaemon.js
202 201 1:00:00 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless --user-data-dir=/var/folders/6_/x/T/playwright_chromiumdev_profile-AAA --remote-debugging-pipe
EOF
: > "$TMP/lsof_fixture_2.txt"

# 3: headless browser with live CDP port connection — must NOT kill.
cat > "$TMP/ps_fixture_3.txt" <<'EOF'
300 1 1:00:00 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless --user-data-dir=/var/folders/6_/x/T/someprofile --remote-debugging-port=9222
EOF
cat > "$TMP/lsof_fixture_3.txt" <<'EOF'
node    555  user  47u  IPv4 0xabc 0t0  TCP localhost:54321->localhost:9222 (ESTABLISHED)
EOF

# 4: headless browser, port open but NO established connection — killable.
cat > "$TMP/ps_fixture_4.txt" <<'EOF'
400 1 1:00:00 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless --user-data-dir=/var/folders/6_/x/T/puppeteer_dev_chrome_profile-XYZ --remote-debugging-port=9222
EOF
: > "$TMP/lsof_fixture_4.txt"

# 5: headless browser with REAL profile dir — must NOT kill.
cat > "$TMP/ps_fixture_5.txt" <<'EOF'
500 1 1:00:00 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless --user-data-dir=/Users/x/Library/Application Support/Google/Chrome --remote-debugging-pipe
EOF
: > "$TMP/lsof_fixture_5.txt"

# 6: headless browser with no fingerprint anywhere — UNRECOGNIZED.
cat > "$TMP/ps_fixture_6.txt" <<'EOF'
600 1 1:00:00 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless --user-data-dir=/var/folders/6_/x/T/unknownprofile --remote-debugging-pipe
EOF
: > "$TMP/lsof_fixture_6.txt"

# 7: not headless — silently skipped (REJECT).
cat > "$TMP/ps_fixture_7.txt" <<'EOF'
700 1 1:00:00 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/var/folders/6_/x/T/visibleprofile --remote-debugging-pipe
EOF
: > "$TMP/lsof_fixture_7.txt"

# 8: no orphans at all.
cat > "$TMP/ps_fixture_8.txt" <<'EOF'
800 1 1:00:00 WindowServer
EOF
: > "$TMP/lsof_fixture_8.txt"

echo "== kill-orphans fixture tests =="
echo

T="$(run_scan 1)"
echo "--- fixture 1 output ---"; echo "$T"; echo "------------------------"
assert_contains "$T" "CONFIRMED ORPHAN: pid 3911" "f1: browser root confirmed"
assert_contains "$T" "kill order: 3910 3932 3944 3911" "f1: daemon killed first, children before root"
assert_contains "$T" "confirmed=1" "f1: summary count"

T="$(run_scan 2)"
assert_not_contains "$T" "CONFIRMED ORPHAN" "f2: live session not killed"
assert_contains "$T" "No orphaned" "f2: reports none"

T="$(run_scan 3)"
assert_not_contains "$T" "CONFIRMED ORPHAN" "f3: live CDP connection not killed"

T="$(run_scan 4)"
assert_contains "$T" "CONFIRMED ORPHAN: pid 400" "f4: idle port (no peer) confirmed"

T="$(run_scan 5)"
assert_not_contains "$T" "CONFIRMED ORPHAN" "f5: real profile never killed"

T="$(run_scan 6)"
assert_contains "$T" "UNRECOGNIZED" "f6: fingerprintless tree reported"
assert_not_contains "$T" "CONFIRMED ORPHAN" "f6: fingerprintless tree not killed"

T="$(run_scan 7)"
assert_not_contains "$T" "CONFIRMED ORPHAN" "f7: non-headless rejected"

T="$(run_scan 8)"
assert_contains "$T" "No orphaned" "f8: clean system reports none"

echo
echo "== tests: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
