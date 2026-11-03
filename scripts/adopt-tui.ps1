#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Mirror the Herdr TUI tabs of a machine into the Herdr desktop app.

.DESCRIPTION
  The TUI owns its panes' PTYs, so the desktop app cannot show a TUI tab
  directly. What it can show is a terminal running `herdr terminal attach
  <terminal_id>`: that attaches a herdr-core terminal to the TUI pane's stream,
  live and interactive.

  This script scans the TUI tabs on -Machine, skips tabs that are already
  `hc attach` clients, and creates one desktop tab per remaining TUI tab in a
  dedicated space (default: "<machine> TUI"). Re-running reuses the existing
  viewer tabs. -Watch polls and adopts new TUI tabs as they appear.

  Limitations:
  - One pane per TUI tab (the first pane).
  - The viewer and the TUI share the pane's terminal size; opening the viewer
    can reflow the TUI pane until either side resizes.
  - The desktop tab's foreground process is `herdr`, so the Agents panel shows
    it as unknown; the TUI tab still owns the real agent status.
  - Closing the viewer tab does not close the TUI tab or kill the agent.

.PARAMETER Machine
  Machine name from `hc machine ls`.

.PARAMETER SpaceName
  Desktop space that holds the mirrored tabs. Default: "<machine> TUI".

.PARAMETER RemoteHerdr
  Absolute path to herdr on the remote machine, when it is not on the login
  shell PATH.

.PARAMETER Watch
  Keep scanning; adopt new TUI tabs as they appear. Ctrl+C stops it.

.PARAMETER IntervalSeconds
  Watch polling interval. Default: 15.

.PARAMETER Prune
  Close viewer tabs whose TUI terminal no longer exists.

.PARAMETER DryRun
  Report what would be adopted without creating anything.

.PARAMETER Json
  Emit JSON.

.EXAMPLE
  pwsh -File scripts/adopt-tui.ps1 -Machine my-vps

.EXAMPLE
  pwsh -File scripts/adopt-tui.ps1 -Machine my-vps -Watch -Prune
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Machine,

    [string]$SpaceName = '',
    [string]$RemoteHerdr = '',
    [switch]$Watch,
    [int]$IntervalSeconds = 15,
    [switch]$Prune,
    [switch]$DryRun,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/herdr-sync.psm1') -Force

if (-not $SpaceName) {
    $SpaceName = "$Machine TUI"
}
if ($IntervalSeconds -lt 2) {
    throw '-IntervalSeconds must be at least 2'
}

$script:remoteHerdr = ''

function Resolve-RemoteHerdrPath {
    if ($RemoteHerdr) {
        return $RemoteHerdr
    }

    $raw = & hc exec --on $Machine 'bash -lic "command -v herdr"' 2>&1
    if ($LASTEXITCODE -eq 0) {
        $line = @(($raw | Out-String) -split "\r?\n" |
                Where-Object { $_ -match 'herdr$' } |
                Select-Object -First 1)
        if ($line) {
            return $line.Trim()
        }
    }
    return 'herdr'
}

function Invoke-Tui {
    param([string[]]$Arguments)

    $quoted = ($Arguments | ForEach-Object { ConvertTo-ShSingleQuoted -Value $_ }) -join ' '
    $line = "$(ConvertTo-ShSingleQuoted -Value $script:remoteHerdr) $quoted"
    $raw = & hc exec --on $Machine $line 2>&1
    $code = $LASTEXITCODE

    $text = ($raw | Out-String).Trim()
    if ($code -ne 0) {
        throw "TUI command failed ($($Arguments -join ' ')): $text"
    }

    return ($text | ConvertFrom-Json)
}

function Get-TuiPaneProcesses {
    param([string[]]$PaneIds)

    if ($PaneIds.Count -eq 0) {
        return @{}
    }

    $ids = ($PaneIds | ForEach-Object { ConvertTo-ShSingleQuoted -Value $_ }) -join ' '
    $herdr = ConvertTo-ShSingleQuoted -Value $script:remoteHerdr
    # One remote shell loop instead of one SSH round-trip per tab.
    $line = "for pane in $ids; do $herdr pane process-info --pane `"`$pane`"; done"
    $raw = & hc exec --on $Machine $line 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "TUI process-info failed: $(($raw | Out-String).Trim())"
    }

    $map = @{}
    foreach ($textLine in (($raw | Out-String) -split "\r?\n")) {
        $trimmed = $textLine.Trim()
        if (-not $trimmed.StartsWith('{')) {
            continue
        }
        try {
            $object = $trimmed | ConvertFrom-Json
            $paneId = [string]$object.result.process_info.pane_id
            if ($paneId) {
                $map[$paneId] = $object.result.process_info.foreground_processes
            }
        } catch {
            Write-Verbose "could not parse process-info line: $trimmed"
        }
    }
    return $map
}

function Get-HcAttachTerminal {
    param($Processes)

    foreach ($process in @($Processes)) {
        $argv = @($process.argv)
        if ($argv.Count -lt 2) {
            continue
        }
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension([string]$argv[0])
        if ($leaf -ne 'hc') {
            continue
        }
        for ($index = 1; $index -lt $argv.Count; $index++) {
            if ($argv[$index] -eq 'attach' -and $index + 1 -lt $argv.Count) {
                return [string]$argv[$index + 1]
            }
        }
    }
    return $null
}

function Get-AdoptedTabMap {
    param([string]$SpaceId)

    $map = @{}
    $state = Get-HerdrState
    $space = @($state.spaces | Where-Object { $_.id -eq $SpaceId }) | Select-Object -First 1
    if (-not $space) {
        return $map
    }

    foreach ($tab in @($space.tabs)) {
        foreach ($terminal in @($tab.terminals)) {
            $core = Get-CoreTerminal -Address ([string]$terminal.terminal)
            if (-not $core -or -not $core.argv) {
                continue
            }

            $argv = @($core.argv)
            for ($index = 1; $index + 2 -lt $argv.Count; $index++) {
                if ($argv[$index] -eq 'terminal' -and $argv[$index + 1] -eq 'attach') {
                    $program = [System.IO.Path]::GetFileNameWithoutExtension([string]$argv[$index - 1])
                    if ($program -ne 'herdr') {
                        continue
                    }
                    $map[[string]$argv[$index + 2]] = [pscustomobject]@{
                        id   = [string]$tab.id
                        name = [string]$tab.name
                    }
                }
            }
        }
    }

    return $map
}

function Invoke-AdoptOnce {
    $tabs = @((Invoke-Tui -Arguments @('tab', 'list')).result.tabs)
    $panes = @((Invoke-Tui -Arguments @('pane', 'list')).result.panes)

    $state = Get-HerdrState
    $space = @($state.spaces | Where-Object { $_.machine -eq $Machine -and $_.name -eq $SpaceName }) |
        Select-Object -First 1
    $spaceId = if ($space) { [string]$space.id } else { '' }
    $spaceTabs = if ($space) { @($space.tabs) } else { @() }

    $existing = if ($spaceId) { Get-AdoptedTabMap -SpaceId $spaceId } else { @{} }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($tab in $spaceTabs) {
        $names.Add([string]$tab.name)
    }

    $tuiTerminals = @{}
    foreach ($tab in $tabs) {
        foreach ($pane in @($panes | Where-Object { $_.tab_id -eq $tab.tab_id })) {
            if ($pane.terminal_id) {
                $tuiTerminals[[string]$pane.terminal_id] = $true
            }
        }
    }

    $processMap = Get-TuiPaneProcesses -PaneIds @($panes | ForEach-Object { [string]$_.pane_id })

    $results = [System.Collections.Generic.List[object]]::new()
    $pruned = 0

    if ($Prune) {
        foreach ($terminalId in @($existing.Keys)) {
            if ($tuiTerminals.ContainsKey($terminalId)) {
                continue
            }
            $tab = $existing[$terminalId]
            if (-not $tab.id) {
                continue
            }
            try {
                if (-not $DryRun) {
                    Invoke-HerdrApp -Arguments @('do', 'tab.close', '--id', [string]$tab.id, '--confirmed', 'true') | Out-Null
                }
                $pruned++
                $results.Add([pscustomobject]@{
                        label    = [string]$tab.name
                        action   = 'pruned'
                        reason   = "TUI terminal $terminalId no longer exists"
                        terminal = $null
                    })
            } catch {
                Write-Warning "could not prune $($tab.name): $($_.Exception.Message)"
            }
            $existing.Remove($terminalId)
            $names.Remove([string]$tab.name) | Out-Null
        }
    }

    $adopted = 0
    $reused = 0
    $skipped = 0

    foreach ($tab in $tabs) {
        $label = [string]$tab.label
        if (-not $label) {
            $label = [string]$tab.tab_id
        }

        $tabPanes = @($panes | Where-Object { $_.tab_id -eq $tab.tab_id })
        if ($tabPanes.Count -eq 0) {
            $skipped++
            $results.Add([pscustomobject]@{
                    label = $label; action = 'skipped'; reason = 'tab has no panes'; terminal = $null
                })
            continue
        }

        $pane = $tabPanes[0]
        $terminalId = [string]$pane.terminal_id
        if (-not $terminalId) {
            $skipped++
            $results.Add([pscustomobject]@{
                    label = $label; action = 'skipped'; reason = 'pane has no terminal id'; terminal = $null
                })
            continue
        }

        $hcTerminal = Get-HcAttachTerminal -Processes $processMap[$pane.pane_id]

        if ($hcTerminal) {
            $skipped++
            $results.Add([pscustomobject]@{
                    label    = $label
                    action   = 'skipped'
                    reason   = "already an hc attach client of $hcTerminal"
                    terminal = $null
                })
            continue
        }

        if ($existing.ContainsKey($terminalId)) {
            $reused++
            $results.Add([pscustomobject]@{
                    label    = $label
                    action   = 'reused'
                    reason   = "viewer tab '$($existing[$terminalId].name)' already exists"
                    terminal = $null
                })
            continue
        }

        if ($DryRun) {
            $skipped++
            $results.Add([pscustomobject]@{
                    label    = $label
                    action   = 'would-adopt'
                    reason   = "would create a viewer for $terminalId"
                    terminal = $terminalId
                })
            continue
        }

        $name = $label
        $suffix = 2
        while ($names.Contains($name)) {
            $name = "$label ($suffix)"
            $suffix++
        }

        $argvJson = ConvertTo-Json -InputObject @($script:remoteHerdr, 'terminal', 'attach', $terminalId) -Compress
        $arguments = @('do')
        if (-not $spaceId) {
            $arguments += @(
                'space.new',
                '--machine', $Machine,
                '--name', $SpaceName,
                '--tab', $name,
                '--argv', $argvJson
            )
        } else {
            $arguments += @('tab.new', '--space', $spaceId, '--name', $name, '--argv', $argvJson)
        }
        if ($pane.cwd) {
            $arguments += @('--folder', [string]$pane.cwd)
        }

        try {
            $raw = Invoke-HerdrApp -Arguments $arguments
            $created = $raw | ConvertFrom-Json
            if (-not $created.terminal) {
                throw "app did not return a terminal: $raw"
            }
            if (-not $spaceId) {
                $spaceId = [string]$created.space
            }
            $names.Add($name)
            $existing[$terminalId] = [pscustomobject]@{ id = [string]$created.tab; name = $name }
            $adopted++
            $results.Add([pscustomobject]@{
                    label    = $label
                    action   = 'adopted'
                    reason   = "viewer for $terminalId"
                    terminal = [string]$created.terminal
                })
        } catch {
            $skipped++
            $results.Add([pscustomobject]@{
                    label    = $label
                    action   = 'failed'
                    reason   = $_.Exception.Message
                    terminal = $null
                })
        }
    }

    return [pscustomobject]@{
        machine   = $Machine
        space     = $SpaceName
        adopted   = $adopted
        reused    = $reused
        skipped   = $skipped
        pruned    = $pruned
        tab_count = $tabs.Count
        results   = @($results)
    }
}

function Write-Summary {
    param($Summary, [switch]$ChangesOnly)

    $interesting = @($Summary.results | Where-Object { $_.action -in @('adopted', 'pruned', 'failed') })
    if ($ChangesOnly -and $interesting.Count -eq 0) {
        return
    }

    Write-Host ''
    Write-Host "TUI -> desktop space '$($Summary.space)' on $($Summary.machine)"
    Write-Host "  tabs=$($Summary.tab_count) adopted=$($Summary.adopted) reused=$($Summary.reused) skipped=$($Summary.skipped) pruned=$($Summary.pruned)"
    foreach ($result in $Summary.results) {
        if ($ChangesOnly -and $result.action -notin @('adopted', 'pruned', 'failed')) {
            continue
        }
        $detail = if ($result.terminal) { " -> $($result.terminal)" } else { '' }
        Write-Host "  $($result.action.PadRight(12)) $($result.label)$detail"
        if ($result.reason -and $result.action -in @('failed', 'skipped', 'pruned')) {
            Write-Host "               $($result.reason)"
        }
    }
}

$script:remoteHerdr = Resolve-RemoteHerdrPath
Write-Verbose "viewer command uses $($script:remoteHerdr) on $Machine"

if ($Watch) {
    if (-not $Json) {
        Write-Host "Watching $Machine every $IntervalSeconds seconds; Ctrl+C stops it."
    }
    while ($true) {
        try {
            Write-Verbose "watch cycle starting"
            $summary = Invoke-AdoptOnce
            Write-Verbose "watch cycle done: adopted=$($summary.adopted) reused=$($summary.reused) skipped=$($summary.skipped) pruned=$($summary.pruned)"
            if ($Json) {
                $summary | ConvertTo-Json -Depth 6 -Compress
            } else {
                Write-Summary -Summary $summary -ChangesOnly
            }
        } catch {
            Write-Warning $_.Exception.Message
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

$summary = Invoke-AdoptOnce
if ($Json) {
    $summary | ConvertTo-Json -Depth 6
} else {
    Write-Summary -Summary $summary
}

$failed = @($summary.results | Where-Object { $_.action -eq 'failed' })
if ($failed.Count -gt 0) {
    exit 1
}
