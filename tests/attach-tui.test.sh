#!/usr/bin/env bash
# Tests for scripts/attach-tui.sh using mock herdr/hc binaries.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/attach-tui.sh"
work=$(mktemp -d)
state="$work/state"
mkdir -p "$state"

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT

export PATH="$root/tests/mocks:$PATH"
# Local Windows runs keep jq/shellcheck in <workspace>/tools; CI has its own.
local_tools=$(cd "$root/../.." 2>/dev/null && pwd)/tools
if [[ -x $local_tools/jq || -x $local_tools/jq.exe ]]; then
  export PATH="$local_tools:$PATH"
fi
export MOCK_STATE="$state"
export MOCK_LOG="$work/log"

chmod +x "$root/tests/mocks/herdr" "$root/tests/mocks/hc" "$script" 2>/dev/null || true

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  printf 'ok - %s\n' "$1"
}

not_ok() {
  fail=$((fail + 1))
  printf 'not ok - %s\n' "$1"
  if [[ -s $work/err ]]; then
    printf '  stderr: %s\n' "$(tr '\n' ' ' <"$work/err")"
  fi
}

check_status() {
  if [[ $status -eq $1 ]]; then
    ok "$2"
  else
    not_ok "$2 (got $status)"
  fi
}

check_eq() {
  if [[ $1 -eq $2 ]]; then
    ok "$3"
  else
    not_ok "$3 (got $1)"
  fi
}

run() {
  "$@" >"$work/out" 2>"$work/err"
  status=$?
}

reset_state() {
  printf '[]\n' >"$state/tabs.json"
  printf '[]\n' >"$state/panes.json"
  printf '{}\n' >"$state/proc.json"
  : >"$state/last-run"
  : >"$MOCK_LOG"
  export MOCK_TERMINAL_MISSING=0
  export MOCK_FOCUS_FAIL=0
}

assert_json() {
  if jq -e "$1" "$work/out" >/dev/null 2>&1; then
    ok "$2"
  else
    not_ok "$2 (output: $(tr '\n' ' ' <"$work/out"))"
  fi
}

assert_contains() {
  if grep -Fq -- "$1" "$2"; then
    ok "$3"
  else
    not_ok "$3"
  fi
}

# --- create -----------------------------------------------------------------
reset_state
run bash "$script" t1 codex --json
check_status 0 'create exits 0'
assert_json '.tab == "w1:t1" and .pane == "w1:p1" and .reused == false and .attached == true' 'create returns new tab JSON'
assert_contains 'attach t1' "$state/last-run" 'create runs hc attach t1'

# --- reuse ------------------------------------------------------------------
run bash "$script" t1 codex --json
check_status 0 'reuse exits 0'
assert_json '.reused == true and .tab == "w1:t1"' 'reuse returns existing tab JSON'
create_count=$(grep -c 'herdr tab create' "$MOCK_LOG" || true)
check_eq "$create_count" 1 'reuse does not create a second tab'

# --- stale tab needs --replace ---------------------------------------------
reset_state
herdr tab create --label codex --no-focus >/dev/null
run bash "$script" t1 codex --json
check_status 3 'stale tab exits 3'
assert_contains 'pass --replace' "$work/err" 'stale tab explains --replace'

# --- replace ----------------------------------------------------------------
run bash "$script" t1 codex --replace --json
check_status 0 'replace exits 0'
assert_json '.reused == false and .replaced == 1 and .tab == "w1:t1"' 'replace reports one replaced tab'
tab_count=$(jq 'length' "$state/tabs.json")
check_eq "$tab_count" 1 'replace leaves one tab'

# --- duplicates -------------------------------------------------------------
reset_state
herdr tab create --label codex --no-focus >/dev/null
herdr tab create --label codex --no-focus >/dev/null
jq -n '{"w1:p1":{argv:["/mock/hc","attach","t1"]},"w1:p2":{argv:["/mock/hc","attach","t1"]}}' >"$state/proc.json"
run bash "$script" t1 codex --json
check_status 0 'duplicates exit 0'
assert_json '.reused == true and .duplicates == 1 and .tab == "w1:t1"' 'duplicates reuse the first tab'
assert_contains 'already attached' "$work/err" 'duplicates warn on stderr'

# --- focus ------------------------------------------------------------------
reset_state
run bash "$script" t1 codex --focus --json
check_status 0 'focus exits 0'
assert_json '.focused == true' 'focus reports focused'
assert_contains 'herdr tab focus' "$MOCK_LOG" 'focus calls herdr tab focus'

# --- focus failure is reported, not swallowed -------------------------------
reset_state
export MOCK_FOCUS_FAIL=1
run bash "$script" t1 codex --focus --json
check_status 0 'focus failure keeps attach success'
assert_json '.focused == false' 'focus failure is visible in JSON'
assert_contains 'could not focus' "$work/err" 'focus failure warns on stderr'

# --- observe ----------------------------------------------------------------
reset_state
run bash "$script" t1 codex --observe --json
check_status 0 'observe exits 0'
assert_json '.observed == true' 'observe is reported'
assert_contains 'attach --observe t1' "$state/last-run" 'observe passes --observe'

# --- missing terminal -------------------------------------------------------
reset_state
export MOCK_TERMINAL_MISSING=1
run bash "$script" t1 codex --json
check_status 1 'missing terminal exits 1'
assert_contains 'terminal not found' "$work/err" 'missing terminal is explained'

# --- binary path with spaces ------------------------------------------------
reset_state
mkdir -p "$work/bin dir"
cp "$root/tests/mocks/hc" "$work/bin dir/hc"
cp "$root/tests/mocks/herdr" "$work/bin dir/herdr"
chmod +x "$work/bin dir/hc" "$work/bin dir/herdr"
run bash "$script" t1 codex --hc "$work/bin dir/hc" --herdr "$work/bin dir/herdr" --json
check_status 0 'space in binary path exits 0'
assert_json '.hc | endswith("/bin dir/hc")' 'space in binary path is preserved'
assert_contains 'bin\ dir/hc attach t1' "$state/last-run" 'space in binary path is quoted'

# --- usage ------------------------------------------------------------------
run bash "$script" --help
check_status 0 'help exits 0'

run bash "$script" t1 codex --bogus
check_status 2 'unknown option exits 2'

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
