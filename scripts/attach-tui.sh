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
#   --replace       Close and recreate same-label tabs that are not attached
#   --observe       Attach in read-only observe mode
#   --json          Print one JSON object
#   -h, --help      Show this help
#
# Exit codes:
#   0  the tab is attached
#   1  a command failed
#   2  usage error
#   3  a same-label tab exists but is not attached; pass --replace

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
  --replace       Close and recreate same-label tabs that are not attached
  --observe       Attach in read-only observe mode
  --json          Print one JSON object
  -h, --help      Show this help
EOF
}

die() {
  printf 'attach-tui.sh: %s\n' "$*" >&2
  exit 1
}

bool() {
  if (( $1 )); then
    printf 'true'
  else
    printf 'false'
  fi
}

yesno() {
  if (( $1 )); then
    printf 'yes'
  else
    printf 'no'
  fi
}

# Quote a value for a POSIX shell command line.
shq() {
  printf '%q' "$1"
}

# resolve_bin <name> <explicit-path>
resolve_bin() {
  local name=$1 explicit=$2 fallback
  fallback="$HOME/.local/bin/$name"

  if [[ -n $explicit ]]; then
    if [[ $explicit == */* ]]; then
      [[ -x $explicit ]] && { printf '%s\n' "$explicit"; return 0; }
    else
      command -v -- "$explicit" 2>/dev/null && return 0
    fi
    return 1
  fi

  command -v -- "$name" 2>/dev/null && return 0
  if [[ -x $fallback ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  return 1
}

terminal=''
label=''
hc_bin=''
herdr_bin=''
focus=0
replace=0
json=0
observe=0

positional() {
  if [[ -z $terminal ]]; then
    terminal=$1
  elif [[ -z $label ]]; then
    label=$1
  else
    die "unexpected argument: $1"
  fi
}

while (( $# )); do
  case $1 in
    --hc)
      [[ $# -ge 2 ]] || die '--hc needs a path'
      hc_bin=$2
      shift 2
      ;;
    --herdr)
      [[ $# -ge 2 ]] || die '--herdr needs a path'
      herdr_bin=$2
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
    --observe)
      observe=1
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
    --)
      shift
      while (( $# )); do
        positional "$1"
        shift
      done
      ;;
    -*)
      printf 'attach-tui.sh: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      positional "$1"
      shift
      ;;
  esac
done

if [[ -z $terminal ]]; then
  usage >&2
  exit 2
fi

label=${label:-$terminal}

if [[ ! $terminal =~ ^[A-Za-z0-9._/-]+$ ]]; then
  die "invalid terminal address: $terminal"
fi

if ! command -v jq >/dev/null 2>&1; then
  die 'jq is required (install it, then re-run)'
fi

requested_hc=$hc_bin
requested_herdr=$herdr_bin
if ! hc_bin=$(resolve_bin hc "$requested_hc"); then
  die "hc not found${requested_hc:+: $requested_hc} (pass --hc PATH)"
fi
if ! herdr_bin=$(resolve_bin herdr "$requested_herdr"); then
  die "herdr not found${requested_herdr:+: $requested_herdr} (pass --herdr PATH)"
fi

if ! "$hc_bin" get "$terminal" --json >/dev/null 2>&1; then
  die "herdr-core terminal not found: $terminal (create it first, or pass the local address of an existing terminal)"
fi

if ! workspace_json=$("$herdr_bin" workspace list 2>&1); then
  die "herdr workspace list failed (is the TUI server running?): $workspace_json"
fi
workspace_id=$(jq -r 'first(.result.workspaces[]? | select(.focused == true) | .workspace_id) // empty' <<<"$workspace_json" | tr -d '\r')

if [[ -n $workspace_id ]]; then
  if ! tabs_json=$("$herdr_bin" tab list --workspace "$workspace_id" 2>&1); then
    die "herdr tab list failed: $tabs_json"
  fi
else
  if ! tabs_json=$("$herdr_bin" tab list 2>&1); then
    die "herdr tab list failed: $tabs_json"
  fi
fi

if ! jq -e '.result.tabs | type == "array"' <<<"$tabs_json" >/dev/null 2>&1; then
  die "unexpected tab list output from herdr: $tabs_json"
fi

if ! panes_json=$("$herdr_bin" pane list 2>&1); then
  die "herdr pane list failed: $panes_json"
fi
if ! jq -e '.result.panes | type == "array"' <<<"$panes_json" >/dev/null 2>&1; then
  die "unexpected pane list output from herdr: $panes_json"
fi

mapfile -t same_label_tabs < <(
  jq -r --arg label "$label" '.result.tabs[]? | select(.label == $label) | .tab_id' <<<"$tabs_json" | tr -d '\r'
)

tab_panes() {
  jq -r --arg tab "$1" '.result.panes[]? | select(.tab_id == $tab) | .pane_id' <<<"$panes_json" | tr -d '\r'
}

# True when the pane's foreground process is `hc attach <terminal>` (optionally
# with --observe). Uses the argv array, not a regex over cmdline, so a path
# with spaces or a terminal like t1/t10 cannot be confused.
pane_is_attached() {
  local pane=$1 info
  info=$("$herdr_bin" pane process-info --pane "$pane" 2>/dev/null) || return 1
  jq -e --arg terminal "$terminal" '
    [ .result.process_info.foreground_processes[]?
      | .argv as $argv
      | ($argv | index("attach")) as $index
      | select($index != null)
      | select((($argv[0] // "") | split("/") | last | sub("\\.exe$"; "")) == "hc")
      | select(any($argv[$index + 1:][]; . == $terminal))
    ] | length > 0
  ' <<<"$info" >/dev/null 2>&1
}

attached_tab=''
attached_pane=''
attached_count=0
stale_tabs=()

for tab in "${same_label_tabs[@]}"; do
  pane=''
  while IFS= read -r candidate; do
    [[ -n $candidate ]] || continue
    if pane_is_attached "$candidate"; then
      pane=$candidate
      break
    fi
  done < <(tab_panes "$tab")

  if [[ -n $pane ]]; then
    attached_count=$((attached_count + 1))
    if [[ -z $attached_tab ]]; then
      attached_tab=$tab
      attached_pane=$pane
    fi
  else
    stale_tabs+=("$tab")
  fi
done

duplicates=0
if (( attached_count > 1 )); then
  duplicates=$((attached_count - 1))
  printf 'attach-tui.sh: warning: %d tabs labeled "%s" are already attached; reusing %s\n' \
    "$attached_count" "$label" "$attached_tab" >&2
fi

reused=0
replaced=0
tab_id=''
pane_id=''

if [[ -n $attached_tab ]]; then
  tab_id=$attached_tab
  pane_id=$attached_pane
  reused=1
  if (( ${#stale_tabs[@]} > 0 )); then
    if (( replace )); then
      for tab in "${stale_tabs[@]}"; do
        if ! "$herdr_bin" tab close "$tab" >/dev/null 2>&1; then
          die "could not close stale tab $tab"
        fi
        replaced=$((replaced + 1))
      done
    else
      printf 'attach-tui.sh: warning: %d same-label tab(s) are not attached; pass --replace to close them\n' \
        "${#stale_tabs[@]}" >&2
    fi
  fi
else
  if (( ${#same_label_tabs[@]} > 0 )); then
    if (( ! replace )); then
      printf "attach-tui.sh: tab '%s' exists but is not attached; pass --replace to recreate it\n" "$label" >&2
      exit 3
    fi
    for tab in "${same_label_tabs[@]}"; do
      if ! "$herdr_bin" tab close "$tab" >/dev/null 2>&1; then
        die "could not close stale tab $tab"
      fi
      replaced=$((replaced + 1))
    done
  fi

  create_args=(--label "$label")
  if (( focus )); then
    create_args+=(--focus)
  else
    create_args+=(--no-focus)
  fi
  if [[ -n $workspace_id ]]; then
    create_args+=(--workspace "$workspace_id")
  fi

  if ! created=$("$herdr_bin" tab create "${create_args[@]}" 2>&1); then
    die "could not create TUI tab: $created"
  fi
  tab_id=$(jq -r '.result.tab.tab_id // empty' <<<"$created" | tr -d '\r')
  pane_id=$(jq -r '.result.root_pane.pane_id // empty' <<<"$created" | tr -d '\r')
  if [[ -z $tab_id || -z $pane_id ]]; then
    die "could not create TUI tab: $created"
  fi

  attach_command="$(shq "$hc_bin") attach"
  if (( observe )); then
    attach_command+=" --observe"
  fi
  attach_command+=" $(shq "$terminal")"

  # pane run queues the command and Enter. Retry in case the shell is starting.
  queued=0
  for _ in $(seq 1 40); do
    if "$herdr_bin" pane run "$pane_id" "$attach_command" >/dev/null 2>&1; then
      queued=1
      break
    fi
    sleep 0.25
  done
  if (( ! queued )); then
    die "could not run 'hc attach $terminal' in pane $pane_id"
  fi

  for _ in $(seq 1 80); do
    if pane_is_attached "$pane_id"; then
      break
    fi
    sleep 0.25
  done
  if ! pane_is_attached "$pane_id"; then
    printf 'attach-tui.sh: attach did not start in pane %s. Last screen:\n' "$pane_id" >&2
    "$herdr_bin" pane read "$pane_id" --source recent --lines 10 >&2 2>/dev/null || true
    exit 1
  fi
fi

focused=0
focus_error=''
if (( focus )); then
  if "$herdr_bin" tab focus "$tab_id" >/dev/null 2>&1; then
    focused=1
  else
    focus_error="could not focus tab $tab_id"
    printf 'attach-tui.sh: warning: %s\n' "$focus_error" >&2
  fi
fi

if (( json )); then
  jq -n \
    --arg tab "$tab_id" \
    --arg pane "$pane_id" \
    --arg terminal "$terminal" \
    --arg label "$label" \
    --arg hc "$hc_bin" \
    --arg herdr "$herdr_bin" \
    --arg focus_error "$focus_error" \
    --argjson reused "$(bool "$reused")" \
    --argjson replaced "$replaced" \
    --argjson duplicates "$duplicates" \
    --argjson observed "$(bool "$observe")" \
    --argjson focused "$(bool "$focused")" \
    '{
      tab: $tab,
      pane: $pane,
      terminal: $terminal,
      label: $label,
      hc: $hc,
      herdr: $herdr,
      reused: $reused,
      replaced: $replaced,
      duplicates: $duplicates,
      observed: $observed,
      attached: true,
      focused: $focused,
      focus_error: $focus_error
    }'
else
  printf 'TAB=%s\n' "$tab_id"
  printf 'PANE=%s\n' "$pane_id"
  printf 'TERMINAL=%s\n' "$terminal"
  printf 'LABEL=%s\n' "$label"
  printf 'HC=%s\n' "$hc_bin"
  printf 'HERDR=%s\n' "$herdr_bin"
  printf 'ATTACHED=yes\n'
  printf 'REUSED=%s\n' "$(yesno "$reused")"
  printf 'REPLACED=%s\n' "$replaced"
  printf 'OBSERVE=%s\n' "$(yesno "$observe")"
  printf 'FOCUSED=%s\n' "$(yesno "$focused")"
fi
