# sync-tabs-herdr-desktop-tui

Share **one live agent terminal** between the [Herdr](https://herdr.dev) desktop app and the Herdr TUI.

The desktop app and the TUI keep separate terminal registries: the desktop app owns terminals in **herdr-core** (`hc`), while the TUI server owns its own PTYs. There is no built-in "mirror this tab" command. This repo closes that gap by making herdr-core the single owner of the agent process and turning the TUI tab into an `hc attach` client of that terminal.

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
  -SelectDesktop
```

| Option | Meaning |
| --- | --- |
| `-Machine` | Machine name from `hc machine ls` (required). |
| `-SpaceName` | Desktop space name. Default: `agents`. |
| `-TabName` | Desktop tab name, also used for the TUI tab label. Default: `codex`. |
| `-AgentArgv` | Agent command and arguments. Default: `codex --no-daemon`. |
| `-Folder` | Starting folder on the remote machine. Default: the machine's home. |
| `-RemoteHc` | Absolute path to `hc` on the remote, if it is not on `PATH`. |
| `-RemoteHerdr` | Absolute path to `herdr` on the remote, if it is not on `PATH`. |
| `-ReplaceTuiTab` | If a TUI tab with the label exists but is not attached, close and recreate it. |
| `-SelectDesktop` | Select the space in the desktop app when done. |
| `-SkipVerify` | Skip the screen-content comparison. |

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
```

Use the **local** address (`t1`), not `my-vps/t1`, because `hc attach` runs on the same machine as the core terminal.

### 3. Verify

```bash
hc get t1 --json
# state: live, status: idle, foreground: codex

herdr pane process-info --pane w1:p16
# foreground_processes[0].cmdline: "hc attach t1"
```

Type in either window. Both should show the same draft and the same responses.

## Repo layout

```
.
├── README.md
├── LICENSE
├── .gitignore
├── docs/
│   └── how-it-works.md
└── scripts/
    ├── setup-desktop.ps1   # create/reuse the desktop space, tab and core terminal
    ├── attach-tui.sh       # run on the remote: create the TUI tab and hc attach
    └── sync.ps1            # orchestrate both sides and verify
```

## Scripts

### `scripts/setup-desktop.ps1`

Creates or reuses the desktop space/tab and the herdr-core terminal.

- Idempotent: finds the space by `machine` + `name`, then the tab by `name`.
- If the tab exists but its terminal is no longer live, or the terminal is live but the requested agent is not running in it, the tab is recreated.
- Waits up to 30 seconds for the core terminal to become live.
- Prints a JSON object with `-Json` (used by `sync.ps1`), otherwise a human-readable summary.

```powershell
pwsh -File scripts/setup-desktop.ps1 -Machine my-vps -SpaceName agents -TabName codex -Json
```

### `scripts/attach-tui.sh`

Runs **on the machine that hosts the TUI**. Creates a tab and attaches it to a core terminal.

```bash
./attach-tui.sh t1 codex
# TAB=w1:t16
# PANE=w1:p16
# ATTACHED=yes
# REUSED=no
```

- Reuses an existing tab if its foreground process is already `hc attach <terminal>`.
- With `--replace`, recreates a stale tab that has the right label but is not attached.
- Resolves `hc` and `herdr` from `PATH`, then `~/.local/bin`.
- `--json` emits one JSON object.

### `scripts/sync.ps1`

The one-command entry point. Calls `setup-desktop.ps1`, copies `attach-tui.sh` to `/tmp` on the remote, runs it with `hc exec`, then checks the result.

The verification is intentionally conservative:

- `hc get <terminal> --json` must report `state: live`.
- The TUI pane's foreground process must be `hc attach <terminal>`.
- The desktop and TUI screens must share at least one non-trivial line. Rendering widths differ, so a full byte-for-byte screen comparison would be misleading.

## How the pieces fit

See [docs/how-it-works.md](docs/how-it-works.md) for the longer version.

- **One owner.** herdr-core owns the PTY. The desktop app and the TUI are both clients.
- **One agent.** The agent runs once, in the core terminal. Attaching does not start a second process.
- **Status lives with the owner.** The desktop Agents panel shows the real `idle` / `working` / `blocked` / `done` status because herdr-core sees the agent's OSC 7501 reports. The TUI tab shows `unknown` because its foreground process is `hc attach`, not the agent. This is expected and harmless.
- **Lifecycle.** Closing the desktop window does not end the terminal. Restarting the TUI may leave the tab in place but drop the attach process; re-run `sync.ps1` or `hc attach` in that tab. If the core terminal dies, both views end; re-run `sync.ps1` to recreate it.

## Caveats

- **This shares one terminal, not a whole tab.** Splits, extra panes and tab layout are not mirrored. Run the script once per agent terminal you want to share.
- **Both sides can type.** There is no writer lock; herdr-core merges input from both clients. Use one side at a time for predictable results.
- **Resizes are shared.** A narrow TUI pane can reflow the agent's output. Widen the pane or the desktop window if the layout looks cramped.
- **Codex needs `--no-daemon`.** Without it, Codex talks to a background app-server and the terminal is no longer the agent process, so status detection and attach semantics break.
- **Agent-specific resume.** The shared terminal is a normal interactive agent. If it exits, the terminal returns to the shell; start the agent again or recreate the tab.
- **`hc attach` detaches with `ctrl+\`.** That returns the TUI pane to its shell without killing the agent. Re-run `hc attach t1` to reconnect.
- **Remote `PATH`.** If `hc` or `herdr` is not on the TUI shell's `PATH`, pass `-RemoteHc` / `-RemoteHerdr` (or edit `attach-tui.sh`'s defaults).

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `herdr-app: command not found` | Run the script from the desktop machine where the Herdr app is installed, or add its install folder to `PATH`. |
| `Pass -Machine` | Run `hc machine ls` and pass a name from the list. |
| `tab 'codex' exists but is not attached` | Re-run with `-ReplaceTuiTab`, or close that TUI tab manually and run again. |
| `herdr-core terminal not found: t1` | The core terminal died. Re-run `sync.ps1`; `setup-desktop.ps1` recreates a dead tab. |
| `jq: command not found` | Install jq on the remote: `sudo apt install jq` (Debian/Ubuntu) or the equivalent. |
| TUI tab shows `unknown` status | Expected: the tab runs `hc attach`. Check the desktop Agents panel for the real status. |
| Desktop shows `working` forever after the agent exits | The agent is not reporting OSC 7501. For Codex, confirm `--no-daemon`. |
| Attach works but typing in the TUI does nothing | Check that the TUI pane has keyboard focus and that `hc attach` is in the foreground (`herdr pane process-info`). |

## Possible upstream improvements

This repo is a workaround for a missing primitive. A native version in Herdr could be much smaller:

- `tab.share` / `terminal.share` on the desktop side: return an attach handle for an existing tab's terminal.
- `herdr tab attach <terminal>` on the TUI side: create a tab whose pane is already attached, with the label and status wired up.
- Status passthrough: when a pane is an `hc attach` client, show the target terminal's agent status instead of `unknown`.
- A single command that pairs both sides, so users do not need to copy terminal addresses.

Until then, the scripts here do the same thing with the public `herdr` and `hc` commands.

## License

MIT. See [LICENSE](LICENSE).
