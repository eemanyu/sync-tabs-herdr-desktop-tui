# sync-tabs-herdr-desktop-tui

Share **one live agent terminal** between the [Herdr](https://herdr.dev) desktop app and the Herdr TUI.

The desktop app and the TUI keep separate terminal registries: the desktop app owns terminals in **herdr-core** (`hc`), while the TUI server owns its own PTYs. There is no built-in "mirror this tab" command. This repo closes that gap in both directions:

- **Desktop → TUI:** make herdr-core the single owner of the agent process and turn the TUI tab into an `hc attach` client of that terminal (one agent process, two windows).
- **TUI → desktop:** attach a herdr-core terminal to an existing TUI pane with `herdr terminal attach`, so every TUI tab can also appear in the desktop (see [Mirror every TUI tab](#mirror-every-tui-tab-in-the-desktop-tui--desktop)).

The result is one agent process, two windows, identical input and output.

```
┌──────────────────────────────┐        ┌──────────────────────────────┐
│ Herdr desktop                │        │ Herdr TUI                    │
│ space: agents                │        │ tab: codex                   │
│ tab:   codex                 │        │ pane: w1:p16                 │
│                              │        │                              │
│  pane ──► herdr-core t1     │        │  pane ──► hc attach t1      │
└───────────────┬──────────────┘        └───────────────┬──────────────┘
                │                                       │
                └───────────────────┬───────────────────┘
                                    ▼
                       herdr-core terminal `t1`
                       codex --no-daemon
```

Type in either window and the other follows. Resize either one and the shared PTY reflows.

## Why this works

- **herdr-core owns the PTY.** A terminal created with `hc run`, or by the desktop app, lives in herdr-core on the machine where it was started. It keeps running when the desktop window closes.
- **The desktop app is one client.** Its tab is just a view of that core terminal.
- **The TUI becomes a second client.** `hc attach <terminal>` connects the TUI pane to the same core terminal instead of starting a new shell. Both clients read and write the same PTY.

This is why the TUI tab must run `hc attach`, not the agent directly. Two independent agent processes would have two different conversations; one agent process with two clients has one conversation.

## Requirements

- **Herdr desktop** with the target machine registered in `hc machine ls` (an SSH machine is fine).
- **Herdr TUI** (`herdr`) and **herdr-core** (`hc`) installed on that machine.
- **`jq`** on the machine that hosts the TUI (used by `attach-tui.sh`).
- **PowerShell 7+** on the desktop for the `.ps1` scripts.
- The agent must stay in the foreground. For Codex that means `codex --no-daemon`; otherwise Codex hands the turn to its background app-server and herdr-core cannot see the agent status.

Verified on 2026-11-02 with **herdr 0.9.5**, **hc 0.1.17** and **herdr-app 0.1.12** (Windows 11 desktop driving an Ubuntu 24.04 arm64 VPS). `hc attach --observe`, `herdr tab focus`, `herdr pane run`, `space.new`, `tab.new`, `tab.close --confirmed true` and `space.select --id` all exist in those versions. Older releases may not.

## Quick start

```powershell
git clone <this-repo-url>
cd sync-tabs-herdr-desktop-tui

pwsh -File scripts/sync.ps1 `
  -Machine my-vps `
  -SpaceName agents `
  -TabName codex
```

`my-vps` is any name from `hc machine ls`. The command:

1. creates the desktop space/tab and its herdr-core terminal if they are missing;
2. creates the TUI tab and runs `hc attach <terminal>` inside it;
3. verifies that the core terminal is live and that both panes render shared content.

The first run creates everything. Later runs reuse the existing space, tab, terminal and TUI tab, so it is safe to run after a reboot or a TUI restart.

### Options

```powershell
pwsh -File scripts/sync.ps1 `
  -Machine my-vps `
  -SpaceName agents `
  -TabName codex `
  -AgentArgv "codex --no-daemon" `
  -Folder /path/to/project `
  -ReplaceTuiTab `
  -Focus
```

| Option | Meaning |
| --- | --- |
| `-Machine` | Machine name from `hc machine ls` (required unless `-Config`/`-All`). |
| `-SpaceName` | Desktop space name. Default: `agents`. |
| `-TabName` | Desktop tab name, also used for the TUI tab label. Default: `codex`. |
| `-AgentArgv` | Agent command and arguments. Default: `codex --no-daemon`. |
| `-Folder` | Starting folder on the remote machine. Default: the machine's home. |
| `-RemoteHc` | Absolute path to `hc` on the remote, if it is not on `PATH`. |
| `-RemoteHerdr` | Absolute path to `herdr` on the remote, if it is not on `PATH`. |
| `-ReplaceTuiTab` | Close and recreate same-label TUI tabs that are not attached. |
| `-Restart` | Recreate a live desktop tab even when the agent cannot be confirmed. **This can end a running session.** |
| `-Observe` | Attach in read-only mode (`hc attach --observe`). |
| `-Focus` | Focus the TUI tab after attaching. |
| `-SelectDesktop` | Select the desktop space when done. |
| `-SkipVerify` | Skip the screen-content comparison. |
| `-Config` | Path to a `sync.json` with defaults and targets. |
| `-Target` | With `-Config`, run only the target with this name. |
| `-All` | Run every target in `./sync.json`. |
| `-Adopt` | Mirror every TUI tab into the desktop (see below). |
| `-Watch` | With `-Adopt`, keep scanning and adopt new TUI tabs. |
| `-AdoptSpace` | Desktop space for mirrored tabs. Default: `<machine> TUI`. |
| `-AdoptIntervalSeconds` | Watch poll interval. Default: 15. |
| `-Prune` | With `-Adopt`, close viewers whose TUI tab is gone. |
| `-DryRun` | Show what would happen without changing anything. |
| `-Json` | Emit JSON (one object per target). |

## Several agents at once

`-All` reads `sync.json` from the current directory (or use `-Config path`):

```json
{
  "defaults": {
    "space": "agents",
    "argv": "codex --no-daemon",
    "focus": true
  },
  "targets": [
    { "name": "codex", "machine": "my-vps", "tab": "codex" },
    { "name": "claude", "machine": "my-vps", "tab": "claude", "argv": "claude" },
    {
      "name": "reviewer",
      "machine": "my-vps",
      "tab": "reviewer",
      "argv": "codex --no-daemon --model gpt-5",
      "folder": "/srv/app",
      "observe": true
    }
  ]
}
```

```powershell
Copy-Item sync.example.json sync.json
pwsh -File scripts/sync.ps1 -All
pwsh -File scripts/sync.ps1 -All -Target claude
```

Targets inherit `defaults` and override any key. Run one target with `-Target`.
Each target is attempted even if a previous one fails; the exit code is `1` if
any target failed. `-DryRun -All` is a safe way to check a config.

## Mirror every TUI tab in the desktop (TUI → desktop)

The desktop app only shows terminals owned by herdr-core. A TUI tab owns its PTY
inside the TUI server, so the public bridge is `herdr terminal attach
<terminal_id>`: it attaches a herdr-core terminal to the TUI pane's stream, live
and interactive.

`scripts/adopt-tui.ps1` scans the TUI on `-Machine` and creates one desktop tab
per TUI tab in a dedicated space (default `<machine> TUI`):

```powershell
pwsh -File scripts/adopt-tui.ps1 -Machine my-vps
```

- Skips tabs that are already `hc attach` clients (the normal `sync.ps1` path).
- Reuses viewer tabs on later runs, matched by the pane's terminal id.
- `-Watch -Prune` keeps watching: new TUI tabs appear automatically, closed ones
  are removed.

```powershell
pwsh -File scripts/adopt-tui.ps1 -Machine my-vps -Watch -Prune
```

The same switches are available on `sync.ps1`:

```powershell
pwsh -File scripts/sync.ps1 -Machine my-vps -Adopt
pwsh -File scripts/sync.ps1 -Machine my-vps -Watch -Prune
```

| Option | Meaning |
| --- | --- |
| `-Machine` | Machine name from `hc machine ls` (required). |
| `-SpaceName` | Desktop space for the mirrored tabs. Default: `<machine> TUI`. |
| `-RemoteHerdr` | Absolute path to `herdr` on the remote, when it is not on the login shell `PATH`. |
| `-Watch` | Poll and adopt new TUI tabs as they appear. |
| `-IntervalSeconds` | Poll interval. Default: 15. |
| `-Prune` | Close viewer tabs whose TUI terminal no longer exists. |
| `-DryRun` | List what would be adopted without creating anything. |
| `-Json` | Emit JSON. |

What to expect:

- The first pane of each TUI tab is mirrored; extra splits inside that tab are
  not.
- The viewer is a real terminal client: typing in the desktop tab reaches the
  TUI pane and its agent.
- Terminal size is shared. Opening a viewer can reflow the TUI pane to the
  desktop pane's size; close the viewer (or resize the desktop pane) if that
  bothers you.
- The desktop Agents panel sees `herdr`, so a mirrored tab's status is
  `unknown`; the TUI still owns the real agent status.
- Closing the viewer does not close the TUI tab or kill the agent.

Why not show the TUI tab directly? Its PTY lives in the TUI server, not in
herdr-core, and there is no public "adopt this pane" API. `herdr terminal attach`
is the public bridge.

## Manual setup

If you prefer to do it by hand, these are the exact commands.

### 1. Desktop side

```powershell
herdr-app do space.new `
  --machine my-vps `
  --name agents `
  --tab codex `
  --argv '["codex","--no-daemon"]'
```

It prints:

```json
{
  "space": "my-vps/sp1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6",
  "tab": "my-vps/tb1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6",
  "terminal": "my-vps/t1"
}
```

The terminal address is the important part. `my-vps/t1` is the desktop-qualified address; on the remote machine the same terminal is just `t1`.

### 2. TUI side (on the remote machine)

```bash
herdr tab create --label codex --no-focus
# => {"result":{"root_pane":{"pane_id":"w1:p16"},"tab":{"tab_id":"w1:t16"}},...}

herdr pane run w1:p16 'hc attach t1'

# Optional: focus the new tab with the real command.
herdr tab focus w1:t16

# Read-only instead of an interactive attach:
herdr pane run w1:p16 'hc attach --observe t1'
```

Use the **local** address (`t1`), not `my-vps/t1`, because `hc attach` runs on the same machine as the core terminal.

### 3. Verify

```bash
hc get t1 --json
# state: live, status: idle, foreground: codex

herdr pane process-info --pane w1:p16
# foreground_processes[0].argv: ["/usr/local/bin/hc","attach","t1"]
```

Type in either window. Both should show the same draft and the same responses.

## Repo layout

```
.
├── README.md
├── CHANGELOG.md
├── LICENSE
├── PSScriptAnalyzerSettings.psd1
├── sync.example.json
├── .github/workflows/ci.yml
├── docs/
│   └── how-it-works.md
├── scripts/
│   ├── lib/herdr-sync.psm1  # shared parsing/quoting/verification helpers
│   ├── setup-desktop.ps1    # create/reuse the desktop space, tab and core terminal
│   ├── attach-tui.sh        # run on the remote: create the TUI tab and hc attach
│   ├── adopt-tui.ps1        # mirror TUI tabs into the desktop (TUI -> desktop)
│   └── sync.ps1             # orchestrate both sides and verify
└── tests/
    ├── attach-tui.test.sh   # mock-driven shell tests
    ├── mocks/               # fake herdr and hc
    └── ps/                  # Pester tests for the PowerShell module
```

## Scripts

### `scripts/setup-desktop.ps1`

Creates or reuses the desktop space/tab and the herdr-core terminal.

- Idempotent: finds the space by `machine` + `name`, then the tab by `name`.
- Reuses a live terminal when the agent is reported by OSC 7501 or matches the
  foreground name/argv.
- Restarts the agent only when the terminal is sitting at a shell prompt (the
  agent exited) or when `-Replace` is passed.
- Warns and keeps a live terminal with an unrecognized foreground process
  (wrappers such as `npx`, `uv run` or `node script.js`), because recreating it
  would kill a session that may still be healthy.
- Sees duplicate tab names: reuses the first live/attached one, closes stale
  duplicates only when replacing, and creates the replacement **before** closing
  the old tab (closing the only tab of a space closes the space).
- Waits up to 30 seconds for the core terminal to become live and 20 seconds for
  the agent to report in; an agent that never reports is a warning, not an
  error.
- Prints a JSON object with `-Json`, otherwise a human-readable summary.
- `-DryRun` reports what would happen without changing anything.
- `-NoReplace` refuses to close or recreate an existing tab.

```powershell
pwsh -File scripts/setup-desktop.ps1 -Machine my-vps -SpaceName agents -TabName codex -Json
pwsh -File scripts/setup-desktop.ps1 -Machine my-vps -DryRun
```

### `scripts/attach-tui.sh`

Runs **on the machine that hosts the TUI**. Creates a tab and attaches it to a core terminal.

```bash
./attach-tui.sh t1 codex
# TAB=w1:t16
# PANE=w1:p16
# TERMINAL=t1
# LABEL=codex
# HC=/home/ubuntu/.local/bin/hc
# HERDR=/home/ubuntu/.local/bin/herdr
# ATTACHED=yes
# REUSED=no
# REPLACED=0
# OBSERVE=no
# FOCUSED=no
```

- Reuses an existing tab when its foreground process is `hc attach <terminal>`
  (also with `--observe`), detected from the process `argv` array.
- With `--replace`, recreates same-label tabs that are not attached, and closes
  stale duplicates even when a healthy tab exists.
- Resolves `hc` and `herdr` from `PATH`, then `~/.local/bin`. Override with
  `--hc` / `--herdr`.
- `--observe` attaches read-only; `--focus` focuses the tab at the end.
- `--json` emits one JSON object.
- Exit codes: `0` attached, `1` command failure, `2` usage error, `3` a
  same-label tab exists but is not attached (pass `--replace`).

### `scripts/adopt-tui.ps1`

Scans the TUI tabs on a machine and mirrors them into a desktop space. This is
the TUI → desktop direction: each viewer tab runs `herdr terminal attach
<terminal_id>` on the remote machine, in a herdr-core terminal.

- Skips tabs whose pane is already an `hc attach` client.
- Matches existing viewers by terminal id, so re-runs are idempotent.
- `-Watch` polls and adopts new tabs; `-Prune` closes viewers whose TUI tab is
  gone.
- `-DryRun` and `-Json` are available.

```powershell
pwsh -File scripts/adopt-tui.ps1 -Machine my-vps
pwsh -File scripts/adopt-tui.ps1 -Machine my-vps -Watch -Prune
```

### `scripts/sync.ps1`

The one-command entry point. Calls `setup-desktop.ps1`, streams `attach-tui.sh`
to the remote over stdin (`hc exec -i ... 'tr -d "\r" | bash -s -- ...'`), then
checks the result. No predictable `/tmp` file is written on the remote.

The verification is intentionally conservative:

- `hc get <terminal> --json` must report `state: live`.
- The TUI pane's foreground process must be `hc attach <terminal>` (or
  `hc attach --observe <terminal>`); this is checked from the `argv` array.
- The desktop and TUI screens must share at least one normalized line. Rendering
  widths differ, so a full byte-for-byte screen comparison would be misleading;
  the shared line is reported, and "no identical line" is reported as such
  instead of being called a success.

`-DryRun` prints the same plan without creating anything.

## Safety notes

- **No silent tab kills.** A live desktop tab is never closed unless `-Replace`
  or `-Restart` was passed, or the terminal is provably back at a shell prompt.
- **No remote temp script.** The TUI script travels over stdin, so there is no
  `/tmp/herdr-sync-attach-$PID.sh` race on a shared machine.
- **Duplicate-safe.** Extra same-label tabs are reused or reported, never
  silently closed unless `--replace` asks for it.
- **Replacement before close.** The new desktop tab is created before the stale
  one is closed, so the space cannot disappear mid-run.
- **Idempotent.** Re-running `sync.ps1` after a reboot reuses every healthy
  piece and only repairs what is missing.

## Caveats

- **This shares one terminal, not a whole tab.** Splits, extra panes and tab layout are not mirrored. Run the script once per agent terminal you want to share.
- **Both sides can type.** `hc attach` has no writer lock; herdr-core merges input from both clients. Use one side at a time for predictable results.
- **Resizes are shared.** A narrow TUI pane can reflow the agent's output. Widen the pane or the desktop window if the layout looks cramped.
- **Codex needs `--no-daemon`.** Without it, Codex talks to a background app-server and the terminal is no longer the agent process, so status detection and attach semantics break.
- **Agent-specific resume.** The shared terminal is a normal interactive agent. If it exits, the terminal returns to the shell; start the agent again or recreate the tab.
- **`hc attach` detaches with `ctrl+\`.** That returns the TUI pane to its shell without killing the agent. Re-run `hc attach t1` to reconnect.
- **Remote `PATH`.** If `hc` or `herdr` is not on the TUI shell's `PATH`, pass `-RemoteHc` / `-RemoteHerdr` (or edit `attach-tui.sh`'s defaults).
- **Direct adoption is not possible.** A TUI tab that does not already run
  `hc attach` owns its PTY inside the TUI server; that PTY cannot be handed to
  herdr-core. `adopt-tui.ps1` bridges it with `herdr terminal attach` instead:
  the desktop gets a live viewer, but the PTY owner stays the TUI server.
- **TUI → desktop viewers share the pane size.** A viewer created by
  `adopt-tui.ps1` is another terminal client of the TUI pane, so it can reflow
  the TUI pane while it is open. Close the viewer if the TUI layout gets
  cramped. Its status is `unknown` in the desktop Agents panel because the
  foreground process is `herdr`, not the agent.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `herdr-app: command not found` | Run the script from the desktop machine where the Herdr app is installed, or add its install folder to `PATH`. |
| `Pass -Machine` | Run `hc machine ls` and pass a name from the list. |
| `machine 'x' is not registered` | The name must match `hc machine ls`, not an SSH host alias. |
| `attach-tui.sh failed ... (exit 3)` | A TUI tab with that label exists but is not attached. Re-run with `-ReplaceTuiTab` (or `--replace`). |
| `herdr-core terminal not found: t1` | The core terminal died. Re-run `sync.ps1`; `setup-desktop.ps1` recreates a dead tab. |
| `could not confirm agent 'x' ... keeping the live tab` | Expected for wrappers. Pass `-Restart` only if you really want to end the session. |
| `jq: command not found` | Install jq on the remote: `sudo apt install jq` (Debian/Ubuntu) or the equivalent. |
| TUI tab shows `unknown` status | Expected: the tab runs `hc attach`. Check the desktop Agents panel for the real status. |
| Desktop shows `working` forever after the agent exits | The agent is not reporting OSC 7501. For Codex, confirm `--no-daemon`. |
| `warning: could not focus tab` | `herdr tab focus` failed; the attach succeeded. Check the TUI server log/version. |
| Mirrored TUI tab shows a shell and `bash: : command not found` | The viewer could not find `herdr` on the remote. Pass `-RemoteHerdr /home/you/.local/bin/herdr`. |
| New TUI tabs do not appear | Run `scripts/adopt-tui.ps1 -Machine <name>` again, or keep `-Watch -Prune` running. |
| Mirrored tab status is `unknown` | Expected: the desktop sees `herdr terminal attach`, not the agent. |
| Attach works but typing in the TUI does nothing | Check that the TUI pane has keyboard focus and that `hc attach` is in the foreground (`herdr pane process-info`). |

## Development

```powershell
# Shell tests (Git Bash, Linux or macOS; jq required)
bash tests/run.sh

# PowerShell unit tests
pwsh -File tests/run.ps1

# Lint
shellcheck scripts/*.sh tests/*.sh tests/mocks/*
Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

CI runs the same checks on Ubuntu and Windows.

## Possible upstream improvements

This repo is a workaround for a missing primitive. A native version in Herdr could be much smaller:

- `tab.share` / `terminal.share` on the desktop side: return an attach handle for an existing tab's terminal.
- `herdr tab attach <terminal>` on the TUI side: create a tab whose pane is already attached, with the label and status wired up.
- Status passthrough: when a pane is an `hc attach` client, show the target terminal's agent status instead of `unknown`.
- A single command that pairs both sides, so users do not need to copy terminal addresses.

Until then, the scripts here do the same thing with the public `herdr` and `hc` commands.

## License

MIT. See [LICENSE](LICENSE).
