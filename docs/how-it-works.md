# How it works

## Two terminal registries

Herdr has two programs with separate jobs:

- **`herdr-app`** draws the desktop window: spaces, tabs, panes, layouts.
- **herdr-core (`hc`)** runs the terminals and agents. Terminals keep running when the window closes.

The desktop app's tabs point at terminals owned by herdr-core. The Herdr TUI, on the other hand, is its own terminal server: its tabs own their PTYs directly. The two registries do not share a PTY, and there is no built-in "mirror this tab" command.

That is the whole problem this repo works around.

## One owner, two clients

The fix is to stop treating the desktop and the TUI as two terminal owners. Make herdr-core the only owner, and make both frontends clients of the same core terminal.

```
desktop pane ─┐
              ├──► herdr-core terminal (one PTY, one agent process)
TUI pane ─────┘
```

- The desktop app already works this way: its pane is a view of a core terminal.
- The TUI pane is made to work this way by running `hc attach <terminal>` instead of starting a shell or an agent.

`hc attach` connects to an existing core terminal through the local herdr-core socket. It forwards input, output and resize events. The core terminal does not know or care how many clients are attached.

The result is one agent process and two views. Typing in either view reaches the same PTY; output from the agent reaches both.

## Why not tmux?

tmux can also share a session between two terminals, and it is a reasonable fallback. But it is a worse fit for this specific case:

- **An extra layer.** The desktop terminal would run a tmux client, the TUI would run another tmux client, and the agent would run inside tmux. herdr-core would see `tmux`, not the agent.
- **Status detection.** Herdr agents report lifecycle state with OSC 7501. herdr-core reads that from the PTY it owns. With tmux in front, the foreground process is tmux, and the desktop Agents panel loses the direct agent identity and status.
- **The primitive already exists.** herdr-core already has `attach`, `keep`, labels, and status. Using it keeps one owner instead of adding a second multiplexer.
- **Desktop integration.** A core terminal can carry `herdr.space` / `herdr.tab` labels and appear in the desktop space exactly like a terminal the app started.

tmux remains useful when the terminal is not owned by herdr-core, or when you need tmux-specific features. For a desktop tab and a TUI tab on the same machine, `hc attach` is the smaller solution.

## What `hc attach` does

`hc attach <terminal>`:

1. Looks up the terminal in the local herdr-core registry.
2. Connects to its PTY over the core socket.
3. Streams output to the current terminal and forwards keyboard input and resizes.
4. Detaches with `ctrl+\` without killing the terminal.

`hc attach --observe <terminal>` is the read-only variant: it watches without typing or resizing. That is useful for a monitoring tab or for a second person who should not interfere.

Because the attach client is the foreground process in the TUI pane, the TUI's own agent detection sees `hc attach`, not the agent. That is why the TUI tab reports `unknown` while the desktop Agents panel reports the real `idle` / `working` / `blocked` / `done` state.

## Status reporting

Agents that support Herdr's lifecycle protocol write OSC 7501 sequences to their terminal. herdr-core parses those sequences and stores the status on the terminal. The desktop app reads that status for its tabs, spaces and Agents panel.

For the status to be visible, the agent must be the process herdr-core sees in the foreground. Two consequences:

- **Do not wrap the agent in another program** if you want status. Run it directly in the core terminal.
- **Codex needs `--no-daemon`.** Without that flag, Codex may hand the session to a background app-server; the terminal is then a client, not the agent, and status detection no longer reflects the agent's turn. Other agents usually do not need a special flag.

## Addressing

A terminal has two forms of address:

- **Qualified:** `machine/t1`. Used by the desktop app and by `hc` commands that run on another machine.
- **Local:** `t1`. Used on the machine that owns the terminal.

`hc attach` runs on the machine that owns the terminal, so the TUI tab uses the local form. The desktop app uses the qualified form.

The desktop app also labels the terminals it starts with `herdr.space=<space id>` and `herdr.tab=<tab id>`. Those labels are what make a terminal appear in a particular desktop space and tab.

## Lifecycle

| Event | Core terminal | Desktop view | TUI view | Recovery |
| --- | --- | --- | --- | --- |
| Desktop window closes | Keeps running | Reconnects on reopen | Unaffected | None |
| Desktop app restarts | Keeps running | Reconnects from the core document | Unaffected | None |
| TUI server restarts | Keeps running | Unaffected | Tab may be restored, but the attach process is gone | Run `hc attach <terminal>` again, or re-run `sync.ps1` |
| Core terminal exits | Ends | Tab closes | `hc attach` exits to the shell | Re-run `sync.ps1` |
| Network drop between desktop and remote core | Keeps running | Reconnects | Unaffected (local socket) | None |
| Remote machine reboots | Lost | Tab is gone or shows a fresh shell | Attach fails | Re-run `sync.ps1` |

The core terminal survives the desktop window because herdr-core owns it, not the window. It does not survive a reboot of the machine that runs herdr-core.

## Implementation details

### Desktop side

`scripts/setup-desktop.ps1` uses the app commands:

- `space.new` when the space does not exist. It creates the space, its first tab and the core terminal in one step, and returns `{ space, tab, terminal }`.
- `tab.new` when the space exists but the tab does not.
- `tab.close` + `tab.new` when the tab exists but its terminal is no longer live, or when `-Replace`/`-Restart` asks for a restart. The replacement tab is created **before** the stale one is closed, because closing the last tab of a space closes the space.
- `hc get <terminal> --json` to check that the terminal is live and to read its agent status.

The script is idempotent: the space is found by `machine` + `name`, the tab by `name`, and a live terminal is reused.

Reusing a live terminal is deliberate. The old script recreated the tab whenever `foreground.name` differed from the first word of `-AgentArgv`; a wrapper such as `npx`, `uv run` or `node script.js` therefore looked like a dead agent, and the script killed a healthy session. The current rules are:

- agent reported over OSC 7501, or a matching foreground name/argv: reuse;
- foreground is an interactive shell: the agent exited, restart it;
- anything else: keep the terminal and warn; `-Replace` is required to restart it.

`-NoReplace` turns every close into a hard error, and `-DryRun` reports the plan without changing anything.


### TUI side

`scripts/attach-tui.sh` uses the TUI commands:

- `herdr workspace list` to find the focused workspace, so the tab is created in the workspace the user is looking at.
- `herdr tab list --workspace <id>` to find existing tabs by label.
- `herdr pane list` to map each tab to its pane.
- `herdr pane process-info --pane <pane>` to check whether that pane's foreground process is already `hc attach <terminal>` (also `--observe`). The check reads the process `argv` array, not a regex over `cmdline`, so `t1` cannot match `t10` and paths with spaces work.
- `herdr tab create --label <label> --no-focus` (`--focus` when `--focus` is passed) to create the tab.
- `herdr pane run <pane> "<quoted hc> attach <quoted terminal>"` to queue the attach command and Enter. The paths are shell-quoted, so spaces in `hc` paths are safe.
- `herdr tab focus <tab_id>` when focus was requested. This is the real command; `herdr tab select` does not exist.

`pane run` is used instead of typing into the pane because it submits the command and Enter atomically. The script still retries briefly, in case the shell is not ready yet, and then polls `pane process-info` until the attach process appears.

If tabs with the right label exist but are not attached, the script stops with exit code 3 unless `--replace` is passed. It never closes a tab that someone is using for something else. Duplicate attached tabs are reported and the first one is reused; stale duplicates are only closed with `--replace`.

### Sync side

`scripts/sync.ps1`:

1. Runs `setup-desktop.ps1` with `-Json` and gets the terminal address.
2. Streams `attach-tui.sh` to the remote over stdin:
   `hc exec -i --on <machine> "tr -d '\r' | bash -s -- <quoted args>"`. There is no predictable `/tmp` file on the remote and no separate `hc file write` step.
3. Runs the script with `--json` and parses that JSON (the older `KEY=VALUE` output is still understood).
4. Checks that the core terminal is still live.
5. Optionally compares a sample of the desktop terminal's text with the TUI pane's text.

The content comparison normalizes whitespace, drops lines shorter than four characters, and looks for the longest shared line. The two panes usually have different widths, so the same output wraps differently. A shared line plus the live terminal and the `hc attach` argv is enough to confirm that both views are on the same terminal. When no identical line is found, the script says so rather than reporting success.

`-DryRun` runs the same planning code without creating or closing anything.

## Limits

- **One terminal, not one tab.** Splits, extra panes, zoom and tab layout are not mirrored. Run the script once per terminal you want to share.
- **No writer lock.** Both clients can type at the same time; the PTY merges the input. `hc attach` in hc 0.1.17 has no takeover flag, so there is no arbitration to configure. Use one side at a time for predictable results.
- **Shared resize.** A resize from either client changes the PTY size, so the other view may reflow.
- **Agent-specific behavior.** Codex needs `--no-daemon`. Agents that do not report OSC 7501 will not show a status.
- **TUI status is `unknown`.** The TUI sees the attach client, not the agent. The desktop Agents panel is the source of truth.
- **Verification is heuristic.** The screen comparison looks for a shared normalized line; it proves that both views show the same terminal, not that every pixel matches. The live terminal check and the `hc attach` argv check are exact.
- **Reverse adoption is not possible.** A TUI tab that does not already run `hc attach` owns its PTY inside the TUI server; that PTY cannot be handed to herdr-core. A TUI tab that is already an `hc attach` client is exactly what `sync.ps1` creates and reuses.
- **Socket access is trust.** Anyone who can reach the herdr-core socket can attach to its terminals. Use `--observe` when you only need to watch, and rely on the operating system's user permissions for the socket.

Version note: the behavior above was verified on 2026-11-02 with herdr 0.9.5, hc 0.1.17 and herdr-app 0.1.12. `herdr tab focus`, `hc attach --observe`, `space.new`, `tab.new`, `tab.close --confirmed true`, `space.select --id`, `herdr-app ls` and `hc machine ls --json` were exercised directly; the JSON field names used by the scripts come from those runs.


## A native API?

The workaround exists because the two programs do not expose a shared-tab operation. A native version could be small:

- `tab.share` / `terminal.share` on the desktop side, returning an attach handle for an existing tab's terminal.
- `herdr tab attach <terminal>` on the TUI side, creating a tab whose pane is already attached.
- Status passthrough for attach panes, so the TUI can show the target terminal's agent status.
- A single pairing command that creates or reuses both sides.

Until then, the scripts here compose the public `herdr` and `hc` commands to get the same result.
