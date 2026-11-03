#!/usr/bin/env bash
# attach-tui.sh - attach a Herdr TUI tab to a herdr-core terminal.
#
# Run this ON the machine that hosts the Herdr TUI (usually the same machine
# as herdr-core). The terminal must already exist in herdr-core; create it
# from the desktop app or with `hc run`.
#
# Usage:
#   attach-tui.sh <terminal> [tab-label] [options]
#
# Arguments:
#   terminal    Local herdr-core address, e.g. t1 (not machine/t1)
#   tab-label   TUI tab label; default: the terminal address
#
# Options:
#   --hc PATH       hc binary (default: PATH, then ~/.local/bin/hc)
#   --herdr PATH    herdr binary (default: PATH, then ~/.local/bin/herdr)
#   --focus         Focus the created/reused tab (default: keep current focus)
#   --replace       Close and recreate a same-label tab that is not attached
#   --json          Print one JSON object
#   -h, --help      Show this help

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: attach-tui.sh <terminal> [tab-label] [options]

Arguments:
  terminal    Local herdr-core address, e.g. t1 (not machine/t1)
  tab-label   TUI tab label; default: the terminal address

Options:
  --hc PATH       hc binary (default: PATH, then ~/.local/bin/hc)
  --herdr PATH    herdr binary (default: PATH, then ~/.local/bin/herdr)
  --focus         Focus the created/reused tab (default: keep current focus)
  --replace       Close and recreate a same-label tab that is not attached
  --json          Print one JSON object
  -h, --help      Show this help
EOF
}

terminal=""
label=""
hc_bin=""
herdr_bin=""
focus=0
replace=0
json=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hc)
      hc_bin="${2:?--hc needs a path}"
      shift 2
      ;;
    --herdr)
      herdr_bin="${2:?--herdr needs a path}"
      shift 2
      ;;
    --focus)
      focus=1
      shift
      ;;
    --replace)
      replace=1
      shift
      ;;
    --json)
      json=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      exit 2
      ;;
    *)
      if [[ -z "$terminal" ]]; then
        terminal="$1"
      elif [[ -z "$label" ]]; then
        label="$1"
      else
        echo "unexpected argument: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$terminal" ]]; then
  usage >&2
  exit 2
fi

label="${label:-$terminal}"

if [[ ! "$terminal" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "invalid terminal address: $terminal" >&2
  exit 2
fi

if [[ -z "$hc_bin" ]]; then
  hc_bin="$(command -v hc || true)"
  [[ -n "$hc_bin" ]] || hc_bin="$HOME/.local/bin/hc"
fi
if [[ ! -x "$hc_bin" ]]; then
  echo "hc not found: $hc_bin (pass --hc)" >&2
  exit 1
fi

if [[ -z "$herdr_bin" ]]; then
  herdr_bin="$(command -v herdr || true)"
  [[ -n "$herdr_bin" ]] || herdr_bin="$HOME/.local/bin/herdr"
fi
if [[ ! -x "$herdr_bin" ]]; then
  echo "herdr not found: $herdr_bin (pass --herdr)" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required (install it, then re-run)" >&2
  exit 1
fi

if ! "$hc_bin" get "$terminal" --json >/dev/null 2>&1; then
  echo "herdr-core terminal not found: $terminal" >&2
  echo "Create it first, or pass the local address of an existing terminal." >&2
  exit 1
fi

find_tab() {
  if [[ -n "$workspace_id" ]]; then
    "$herdr_bin" tab list --workspace "$workspace_id" 2>/dev/null
  else
    "$herdr_bin" tab list 2>/dev/null
  fi |
    jq -r --arg label "$label" '[.result.tabs[] | select(.label == $label) | .tab_id] | first // empty'
}

find_pane() {
  "$herdr_bin" pane list 2>/dev/null |
    jq -r --arg tab "$1" '[.result.panes[] | select(.tab_id == $tab) | .pane_id] | first // empty'
}

pane_is_attached() {
  local pane="$1"
  local terminal_re="${terminal//./\\.}"
  "$herdr_bin" pane process-info --pane "$pane" 2>/dev/null |
    jq -r '.result.process_info.foreground_processes[]?.cmdline // empty' |
    grep -E "(^|[/ ])hc attach ${terminal_re}( |$)" >/dev/null 2>&1
}

workspace_id="$("$herdr_bin" workspace list 2>/dev/null |
  jq -r '[.result.workspaces[] | select(.focused == true) | .workspace_id] | first // empty' || true)"

existing_tab="$(find_tab)"
reused=0
tab_id=""
pane_id=""

if [[ -n "$existing_tab" ]]; then
  existing_pane="$(find_pane "$existing_tab")"
  if [[ -n "$existing_pane" ]] && pane_is_attached "$existing_pane"; then
    tab_id="$existing_tab"
    pane_id="$existing_pane"
    reused=1
  elif (( replace )); then
    "$herdr_bin" tab close "$existing_tab" >/dev/null
    sleep 0.3
  else
    echo "tab '$label' exists but is not attached; pass --replace to recreate it" >&2
    exit 3
  fi
fi

if [[ -z "$tab_id" ]]; then
  focus_flag="--no-focus"
  if (( focus )); then
    focus_flag="--focus"
  fi

  create_args=(--label "$label" "$focus_flag")
  if [[ -n "$workspace_id" ]]; then
    create_args+=(--workspace "$workspace_id")
  fi

  created="$("$herdr_bin" tab create "${create_args[@]}")"
  tab_id="$(jq -r '.result.tab.tab_id // empty' <<<"$created")"
  pane_id="$(jq -r '.result.root_pane.pane_id // empty' <<<"$created")"

  if [[ -z "$tab_id" || -z "$pane_id" ]]; then
    echo "could not create TUI tab: $created" >&2
    exit 1
  fi

  # pane run queues the command and Enter. Retry briefly in case the shell is
  # still starting.
  queued=0
  for _ in $(seq 1 20); do
    if "$herdr_bin" pane run "$pane_id" "$hc_bin attach $terminal" >/dev/null 2>&1; then
      queued=1
      break
    fi
    sleep 0.25
  done

  if (( ! queued )); then
    echo "could not run 'hc attach $terminal' in pane $pane_id" >&2
    exit 1
  fi

  for _ in $(seq 1 40); do
    if pane_is_attached "$pane_id"; then
      break
    fi
    sleep 0.25
  done

  if ! pane_is_attached "$pane_id"; then
    echo "attach did not start in pane $pane_id" >&2
    exit 1
  fi
fi

if (( focus )); then
  "$herdr_bin" tab select "$tab_id" >/dev/null 2>&1 || true
fi

if (( json )); then
  reused_json="false"
  if (( reused )); then
    reused_json="true"
  fi

  jq -n \
    --arg tab "$tab_id" \
    --arg pane "$pane_id" \
    --arg terminal "$terminal" \
    --arg label "$label" \
    --arg hc "$hc_bin" \
    --arg herdr "$herdr_bin" \
    --argjson reused "$reused_json" \
    '{tab:$tab, pane:$pane, terminal:$terminal, label:$label, hc:$hc, herdr:$herdr, reused:$reused}'
else
  echo "TAB=$tab_id"
  echo "PANE=$pane_id"
  echo "HC=$hc_bin"
  echo "HERDR=$herdr_bin"
  echo "ATTACHED=yes"
  if (( reused )); then
    echo "REUSED=yes"
  else
    echo "REUSED=no"
  fi
fi
