#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Keep a Herdr desktop tab and a Herdr TUI tab on the same agent terminal.

.DESCRIPTION
  The desktop app owns terminals in herdr-core. This script creates (or
  reuses) a desktop space/tab with an agent, then creates a TUI tab that runs
  `hc attach <terminal>` so both windows share one PTY.

  The first run creates everything. Later runs reuse the existing space, tab,
  core terminal and TUI tab, so it is safe to run after a restart.

.PARAMETER Machine
  Machine name from `hc machine ls`. Required.

.PARAMETER SpaceName
  Desktop space name. Default: agents.

.PARAMETER TabName
  Desktop tab name, also used for the TUI tab label. Default: codex.

.PARAMETER AgentArgv
  Agent command and arguments. Default: codex --no-daemon.

.PARAMETER Folder
  Starting folder on the remote machine. Default: the machine's home.

.PARAMETER RemoteHc
  Absolute path to hc on the remote, if it is not on PATH.

.PARAMETER RemoteHerdr
  Absolute path to herdr on the remote, if it is not on PATH.

.PARAMETER ReplaceTuiTab
  If a TUI tab with the label exists but is not attached, close and recreate it.

.PARAMETER SelectDesktop
  Select the desktop space when done.

.PARAMETER SkipVerify
  Skip the screen-content comparison.

.EXAMPLE
  pwsh -File scripts/sync.ps1 -Machine my-vps -SpaceName agents -TabName codex

.EXAMPLE
  pwsh -File scripts/sync.ps1 -Machine my-vps -AgentArgv "claude"
#>
[CmdletBinding()]
param(
  [string]$Machine = "",
  [string]$SpaceName = "agents",
  [string]$TabName = "codex",
  [string]$AgentArgv = "codex --no-daemon",
  [string]$Folder = "",
  [string]$RemoteHc = "",
  [string]$RemoteHerdr = "",
  [switch]$ReplaceTuiTab,
  [switch]$SelectDesktop,
  [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"

function ConvertTo-ShQuote {
  param([string]$Value)
  if ($Value -match '^[A-Za-z0-9_./:@%+=,-]+$') { return $Value }
  return "'" + ($Value -replace "'", "'\''") + "'"
}

function Get-ScreenLines {
  param([string]$Text)
  return @(
    $Text -split "\r?\n" |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_.Length -ge 3 } |
      Select-Object -Unique
  )
}

foreach ($binary in @("herdr-app", "hc")) {
  if (-not (Get-Command $binary -ErrorAction SilentlyContinue)) {
    throw "$binary was not found in PATH"
  }
}

if (-not $Machine) {
  throw "Pass -Machine with a name from ``hc machine ls``."
}

$setupScript = Join-Path $PSScriptRoot "setup-desktop.ps1"
$attachScript = Join-Path $PSScriptRoot "attach-tui.sh"

if (-not (Test-Path -LiteralPath $setupScript)) {
  throw "missing $setupScript"
}
if (-not (Test-Path -LiteralPath $attachScript)) {
  throw "missing $attachScript"
}

# --- Desktop side ---------------------------------------------------------

$setupArgs = @{
  Machine   = $Machine
  SpaceName = $SpaceName
  TabName   = $TabName
  AgentArgv = $AgentArgv
  Folder    = $Folder
  Json      = $true
}
if ($SelectDesktop) {
  $setupArgs["SelectDesktop"] = $true
}

$desktop = (& $setupScript @setupArgs) | ConvertFrom-Json

# --- TUI side -------------------------------------------------------------

$remoteScript = "/tmp/herdr-sync-attach-$PID.sh"
$scriptText = (Get-Content -Raw -LiteralPath $attachScript) -replace "`r`n", "`n"
if (-not $scriptText.EndsWith("`n")) {
  $scriptText += "`n"
}

$writeOutput = $scriptText | hc file write --on $Machine $remoteScript 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "could not copy attach-tui.sh to ${Machine}: $($writeOutput | Out-String)"
}

# Windows PowerShell can append CRLF to the piped content. Strip CR so bash
# does not try to execute a trailing carriage return as a command.
$stripCr = "tr -d '\015' < $(ConvertTo-ShQuote $remoteScript) > $(ConvertTo-ShQuote "$remoteScript.tmp") && mv $(ConvertTo-ShQuote "$remoteScript.tmp") $(ConvertTo-ShQuote $remoteScript)"
hc exec --on $Machine $stripCr 2>&1 | Out-Null

$remoteCommand = "bash $(ConvertTo-ShQuote $remoteScript) $(ConvertTo-ShQuote $desktop.local_terminal) $(ConvertTo-ShQuote $TabName)"
if ($ReplaceTuiTab) {
  $remoteCommand += " --replace"
}
if ($RemoteHc) {
  $remoteCommand += " --hc $(ConvertTo-ShQuote $RemoteHc)"
}
if ($RemoteHerdr) {
  $remoteCommand += " --herdr $(ConvertTo-ShQuote $RemoteHerdr)"
}

$attachOutput = @()
try {
  $attachOutput = @(hc exec --on $Machine $remoteCommand 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "attach-tui.sh failed on ${Machine}:`n$($attachOutput -join "`n")"
  }
} finally {
  hc exec --on $Machine "rm -f $(ConvertTo-ShQuote $remoteScript)" 2>&1 | Out-Null
}

$attach = @{}
foreach ($line in (($attachOutput | Out-String) -split "\r?\n")) {
  if ($line -match '^([A-Z_]+)=(.*)$') {
    $attach[$matches[1]] = $matches[2].Trim()
  }
}

foreach ($key in @("TAB", "PANE", "HC", "HERDR", "REUSED")) {
  if (-not $attach.ContainsKey($key)) {
    throw "could not parse attach-tui.sh output:`n$($attachOutput -join "`n")"
  }
}

# --- Verify ---------------------------------------------------------------

$core = ((hc get $desktop.terminal --json 2>&1 | Out-String).Trim()) | ConvertFrom-Json
if ($core.state -ne "live") {
  throw "herdr-core terminal $($desktop.terminal) is not live (state=$($core.state))"
}

$sharedLine = $null
if (-not $SkipVerify) {
  $desktopText = (hc read $desktop.terminal --lines 200 2>&1 | Out-String)
  $tuiReadCommand = "$(ConvertTo-ShQuote $attach['HERDR']) pane read $(ConvertTo-ShQuote $attach['PANE']) --source recent --lines 200"
  $tuiText = (hc exec --on $Machine $tuiReadCommand 2>&1 | Out-String)

  $desktopLines = @(Get-ScreenLines $desktopText)
  $tuiLines = @(Get-ScreenLines $tuiText)

  $sharedLine = Compare-Object `
    -ReferenceObject $desktopLines `
    -DifferenceObject $tuiLines `
    -IncludeEqual `
    -ExcludeDifferent |
    ForEach-Object { $_.InputObject } |
    Sort-Object Length -Descending |
    Select-Object -First 1
}

# --- Report ---------------------------------------------------------------

Write-Host ""
Write-Host "Herdr desktop"
Write-Host "  space    : $SpaceName"
Write-Host "  tab      : $TabName"
Write-Host "  space id : $($desktop.space)"
Write-Host "  tab id   : $($desktop.tab)"
Write-Host "  terminal : $($desktop.terminal) (state=$($core.state), agent=$($desktop.agent), status=$($desktop.status))"
Write-Host ""
Write-Host "Herdr TUI"
Write-Host "  tab      : $($attach['TAB'])"
Write-Host "  pane     : $($attach['PANE'])"
Write-Host "  attach   : $($attach['HC']) attach $($desktop.local_terminal)"
Write-Host "  reused   : $($attach['REUSED'])"
Write-Host ""

if ($SkipVerify) {
  Write-Host "Shared content: verification skipped."
} elseif ($sharedLine) {
  Write-Host "Shared content: yes (matched line: $sharedLine)"
} else {
  Write-Host "Shared content: attach is confirmed, but no identical rendered line was found."
  Write-Host "This can happen when the two panes have very different widths."
}
