# Changelog

## 0.2.0 - 2026-11-02

### Fixed

- **`--focus` used the wrong command.** `attach-tui.sh` called the nonexistent
  `herdr tab select` and swallowed the error with `|| true`, so a requested
  focus never happened. It now uses `herdr tab focus` and reports a failure on
  stderr (the JSON result carries `focused` and `focus_error`).
- **Predictable remote temp file.** `sync.ps1` no longer writes
  `/tmp/herdr-sync-attach-$PID.sh`. The script is streamed over stdin
  (`hc exec -i ... 'tr -d "\r" | bash -s -- ...'`), which removes the
  race/symlink risk and the separate `hc file write` step.
- **Agent detection no longer kills live sessions.** `setup-desktop.ps1` used to
  compare `foreground.name` with the first word of `-AgentArgv` and recreate the
  tab on a mismatch. A wrapper (`npx`, `uv run`, `node script.js`) therefore
  looked like a dead agent. The new rules are:
  - agent reported over OSC 7501, or a matching foreground name/argv: reuse;
  - live terminal sitting at a shell prompt: the agent exited, restart it;
  - live terminal running anything else: keep it and warn; `-Replace` is
    required to restart it.
- **Duplicate tabs.** A space can contain several tabs with the same name. The
  scripts now see all of them, reuse the first attached/live one, warn, and
  close stale duplicates only when `--replace`/`-Replace` was requested.
- **Quoting in the TUI pane.** `hc attach` is now written to the pane with
  shell-quoted paths, so an `hc` path or terminal name containing spaces or
  quotes cannot break the command.
- **Attach detection.** `pane_is_attached` no longer greps a partially escaped
  regex. It checks the foreground process's `argv` array, so `t1` cannot match
  `t10` and paths with spaces work.
- **`Split-CommandLine` treated commas as separators.** `a,b` is now one
  argument.
- **`sync.ps1` parsed `KEY=VALUE`.** It now asks `attach-tui.sh` for `--json`
  and parses that, with the text format kept as a fallback.
- **CRLF on stdin.** Windows PowerShell appends CRLF when piping to a native
  process; the remote wrapper strips CR before `bash -s`.

### Added

- **`sync.json` / `-All`** for syncing several agents in one run, with
  per-target and default options.
- **`-Observe`** to attach in read-only mode (`hc attach --observe`).
- **`-Focus`**, **`-Restart`**, **`-DryRun`**, **`-Json`**, **`-NoReplace`** and
  **`-Replace`**.
- **Verification improvements:** `hc get` live-state check, `hc attach` argv
  check and a normalized screen comparison; the unmatched-line case is
  explained instead of being treated as success.
- **`scripts/lib/herdr-sync.psm1`** with the shared parsers and helpers.
- **Tests:** 30 mock-driven shell tests for `attach-tui.sh` and 26 Pester tests
  for the PowerShell helpers.
- **CI:** shellcheck + shell tests on Linux, PSScriptAnalyzer + Pester on
  Windows.
- **`PSScriptAnalyzerSettings.psd1`**, **`.editorconfig`** and
  **`sync.example.json`**.

### Changed

- `attach-tui.sh` documents exit codes (0 ok, 1 failure, 2 usage, 3 stale tab
  needs `--replace`).
- Warnings from `setup-desktop.ps1` are collected in the JSON result.
- README and `docs/how-it-works.md` now match the commands verified against
  herdr 0.9.5 / hc 0.1.17 / herdr-app 0.1.12.

## 0.1.0 - 2026-11-01

- Initial scripts and documentation: one shared agent terminal between the
  Herdr desktop app and the Herdr TUI.
