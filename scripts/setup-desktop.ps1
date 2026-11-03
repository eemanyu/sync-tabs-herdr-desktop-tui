#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Create or reuse the Herdr desktop space/tab that owns the shared agent terminal.

.DESCRIPTION
  The desktop app stores its terminals in herdr-core. This script makes sure a
  space and tab exist on the given machine, starts the agent in the tab's
  herdr-core terminal, and reports the terminal address.

  It is idempotent: an existing space, tab and live terminal are reused. If the
  tab exists but its terminal is no longer live, or the terminal is live but the
  agent is no longer running in it, the tab is recreated with the requested agent.

.PARAMETER Machine
  Machine name from `hc machine ls`. Required.

.PARAMETER SpaceName
  Desktop space name. Default: agents.

.PARAMETER TabName
  Desktop tab name. Default: codex.

.PARAMETER AgentArgv
  Agent command and arguments. Default: codex --no-daemon.

.PARAMETER Folder
  Starting folder on the remote machine. Default: the machine's home.

.PARAMETER SelectDesktop
  Select the space in the desktop app after ensuring it exists.

.PARAMETER Json
  Emit one JSON object instead of human-readable output.

.EXAMPLE
  pwsh -File scripts/setup-desktop.ps1 -Machine my-vps -SpaceName agents -TabName codex

.EXAMPLE
  pwsh -File scripts/setup-desktop.ps1 -Machine my-vps -Json
#>
[CmdletBinding()]
param(
  [string]$Machine = "",
  [string]$SpaceName = "agents",
  [string]$TabName = "codex",
  [string]$AgentArgv = "codex --no-daemon",
  [string]$Folder = "",
  [switch]$SelectDesktop,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

function Split-CommandLine {
  param([string]$Line)

  $result = [System.Collections.Generic.List[string]]::new()
  $current = [System.Text.StringBuilder]::new()
  $quote = [char]0
  $hasToken = $false

  foreach ($character in $Line.ToCharArray()) {
    if ($quote -ne [char]0) {
      if ($character -eq $quote) {
        $quote = [char]0
      } else {
        [void]$current.Append($character)
      }
      $hasToken = $true
    } elseif ($character -eq '"' -or $character -eq "'") {
      $quote = $character
      $hasToken = $true
    } elseif ([char]::IsWhiteSpace($character) -or $character -eq ',') {
      if ($hasToken) {
        $result.Add($current.ToString())
        [void]$current.Clear()
        $hasToken = $false
      }
    } else {
      [void]$current.Append($character)
      $hasToken = $true
    }
  }

  if ($quote -ne [char]0) {
    throw "unterminated quote in agent command: $Line"
  }
  if ($hasToken) {
    $result.Add($current.ToString())
  }

  return $result.ToArray()
}

function Write-Info {
  param([string]$Message)
  if (-not $Json) { Write-Host $Message }
}

function Quote-WinArg {
  param([string]$Value)
  if ($Value -match '^[A-Za-z0-9_./:@%+=,-]+$') { return $Value }
  return '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-HerdrApp {
  param([string[]]$Arguments)

  # herdr-app is a GUI-subsystem executable. Capturing it through a
  # PowerShell pipeline can close the pipe before it finishes writing, so
  # redirect to files and wait for the process instead.
  $stdoutFile = [System.IO.Path]::GetTempFileName()
  $stderrFile = [System.IO.Path]::GetTempFileName()

  try {
    $argumentLine = ($Arguments | ForEach-Object { Quote-WinArg $_ }) -join " "
    $startArgs = @{
      FilePath               = "herdr-app"
      ArgumentList           = $argumentLine
      RedirectStandardOutput = $stdoutFile
      RedirectStandardError  = $stderrFile
      Wait                   = $true
      PassThru               = $true
    }
    if ($IsWindows) { $startArgs["NoNewWindow"] = $true }

    $process = Start-Process @startArgs
    $stdout = Get-Content -Raw -LiteralPath $stdoutFile -ErrorAction SilentlyContinue
    $stderr = Get-Content -Raw -LiteralPath $stderrFile -ErrorAction SilentlyContinue

    if ($process.ExitCode -ne 0) {
      throw "herdr-app $($Arguments -join ' ') failed (exit $($process.ExitCode)): $($stderr)$($stdout)"
    }

    return (("$stdout$stderr").Trim())
  } finally {
    Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
  }
}

function Get-HerdrState {
  $raw = Invoke-HerdrApp @("ls")
  if (-not $raw) { throw "herdr-app ls returned no output" }
  return $raw | ConvertFrom-Json
}

function Find-Space {
  param($State)
  return $State.spaces |
    Where-Object { $_.machine -eq $Machine -and $_.name -eq $SpaceName } |
    Select-Object -First 1
}

function Find-Tab {
  param($Space)
  return $Space.tabs |
    Where-Object { $_.name -eq $TabName } |
    Select-Object -First 1
}

function Find-Tabs {
  param($Space)
  return @($Space.tabs | Where-Object { $_.name -eq $TabName })
}

function Get-CoreTerminal {
  param([string]$Address)
  $output = & hc get $Address --json 2>&1
  if ($LASTEXITCODE -ne 0) { return $null }
  try {
    return ((($output | Out-String).Trim()) | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Wait-CoreTerminal {
  param([string]$SpaceId, [int]$TimeoutSeconds = 30)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $state = Get-HerdrState
    $space = Find-Space $state
    if ($space -and $space.id -eq $SpaceId) {
      foreach ($tab in (Find-Tabs $space)) {
        foreach ($candidate in $tab.terminals) {
          $live = Get-CoreTerminal $candidate.terminal
          if ($live -and $live.state -eq "live") { return $live }
        }
      }
    }
    Start-Sleep -Milliseconds 500
  }

  throw "the herdr-core terminal did not become live within $TimeoutSeconds seconds"
}

function Test-AgentRunning {
  param([string]$Address, [string]$AgentName)
  $core = Get-CoreTerminal $Address
  if (-not $core) { return $false }
  if ($core.foreground.name -eq $AgentName) { return $true }
  if ($core.status -and $core.status.app -eq $AgentName) { return $true }
  return $false
}

foreach ($binary in @("herdr-app", "hc")) {
  if (-not (Get-Command $binary -ErrorAction SilentlyContinue)) {
    throw "$binary was not found in PATH"
  }
}

if (-not $Machine) {
  throw "Pass -Machine with a name from ``hc machine ls``."
}

$agentArgvList = @(Split-CommandLine $AgentArgv)
if ($agentArgvList.Count -eq 0) {
  throw "-AgentArgv is empty"
}
$argvJson = ($agentArgvList | ConvertTo-Json -Compress -AsArray)
$agentName = [System.IO.Path]::GetFileNameWithoutExtension($agentArgvList[0])

$state = Get-HerdrState
$space = Find-Space $state
$spaceId = $null
$spaceWasCreated = $false

if (-not $space) {
  $arguments = @(
    "do", "space.new",
    "--machine", $Machine,
    "--name", $SpaceName,
    "--tab", $TabName,
    "--argv", $argvJson
  )
  if ($Folder) { $arguments += @("--folder", $Folder) }

  Invoke-HerdrApp $arguments | Out-Null
  $state = Get-HerdrState
  $space = Find-Space $state
  $spaceId = $space.id
  $spaceWasCreated = $true
  Write-Info "created space '$SpaceName' ($spaceId)"
} else {
  $spaceId = $space.id
  Write-Info "reusing space '$SpaceName' ($spaceId)"
}

# Re-read so the tab created by space.new is visible.
$state = Get-HerdrState
$space = Find-Space $state
$tab = Find-Tab $space
$needsReplacement = $false

if ($tab -and -not $spaceWasCreated) {
  $existingTerminal = $tab.terminals | Select-Object -First 1
  $live = $null
  if ($existingTerminal) {
    $live = Get-CoreTerminal $existingTerminal.terminal
  }

  if ($live -and $live.state -eq "live") {
    # Give an agent that is still starting a moment before replacing the tab.
    $deadline = (Get-Date).AddSeconds(10)
    while (-not (Test-AgentRunning $live.address $agentName) -and (Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 500
    }

    if (Test-AgentRunning $live.address $agentName) {
      Write-Info "reusing tab '$TabName' ($($tab.id)) -> $($live.address)"
    } else {
      Write-Info "tab '$TabName' is live but '$agentName' is not running; recreating it"
      $needsReplacement = $true
    }
  } else {
    Write-Info "tab '$TabName' exists but its terminal is not live; recreating it"
    $needsReplacement = $true
  }
}

if (-not $tab -or $needsReplacement) {
  $arguments = @(
    "do", "tab.new",
    "--space", $spaceId,
    "--name", $TabName,
    "--argv", $argvJson
  )
  if ($Folder) { $arguments += @("--folder", $Folder) }

  Invoke-HerdrApp $arguments | Out-Null
  Write-Info "created tab '$TabName'"

  if ($tab) {
    # Create the replacement first: closing the only tab of a space closes
    # the space itself.
    Invoke-HerdrApp @("do", "tab.close", "--id", $tab.id, "--confirmed", "true") | Out-Null
  }

  # Re-read so the replacement is found and the stale tab is gone.
  $state = Get-HerdrState
  $space = Find-Space $state
  $tab = Find-Tab $space
}

$terminal = Wait-CoreTerminal -SpaceId $spaceId

if (-not (Test-AgentRunning $terminal.address $agentName)) {
  $deadline = (Get-Date).AddSeconds(20)
  while (-not (Test-AgentRunning $terminal.address $agentName) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
  }
  if (-not (Test-AgentRunning $terminal.address $agentName)) {
    Write-Warning "agent '$agentName' did not appear in $($terminal.address) within 20 seconds"
  }
}

if ($SelectDesktop) {
  Invoke-HerdrApp @("do", "space.select", "--id", $spaceId) | Out-Null
}

$state = Get-HerdrState
$space = Find-Space $state
$tab = $null
$tabInfo = $null
foreach ($candidateTab in $space.tabs) {
  $candidateTerminal = $candidateTab.terminals |
    Where-Object { $_.terminal -eq $terminal.address } |
    Select-Object -First 1
  if ($candidateTerminal) {
    $tab = $candidateTab
    $tabInfo = $candidateTerminal
    break
  }
}

if (-not $tab) {
  throw "could not find the desktop tab for terminal $($terminal.address)"
}

$localTerminal = $terminal.address -replace "^$([regex]::Escape($Machine))/", ""

$result = [pscustomobject]@{
  machine        = $Machine
  space          = $space.id
  tab            = $tab.id
  terminal       = $terminal.address
  local_terminal = $localTerminal
  state          = $terminal.state
  agent          = $tabInfo.app
  status         = $tabInfo.status
}

if ($Json) {
  $result | ConvertTo-Json -Compress
  return
}

Write-Host ""
Write-Host "Desktop space : $SpaceName"
Write-Host "Desktop tab   : $TabName"
Write-Host "Space id      : $($result.space)"
Write-Host "Tab id        : $($result.tab)"
Write-Host "Terminal      : $($result.terminal) ($($result.state))"
Write-Host "Local address : $($result.local_terminal)"
Write-Host "Agent         : $($result.agent) / $($result.status)"
Write-Host ""
Write-Host "Next: run scripts/attach-tui.sh $($result.local_terminal) $TabName on the remote machine."
