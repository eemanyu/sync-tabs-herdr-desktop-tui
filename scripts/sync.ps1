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

  -Adopt (or -Watch) switches to the other direction: every TUI tab on the
  machine is mirrored into a desktop space as a `herdr terminal attach` viewer.

  The TUI side is sent over stdin (`hc exec -i ... bash -s --`), so no
  predictable temporary file is written on the remote machine.

.PARAMETER Machine
  Machine name from `hc machine ls`. Required unless -Config/-All is used.

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
  Close and recreate TUI tabs with the label that are not attached.

.PARAMETER Restart
  Recreate a live desktop tab even when the agent cannot be confirmed. This can
  end a running agent session.

.PARAMETER SelectDesktop
  Select the desktop space when done.

.PARAMETER SkipVerify
  Skip the screen-content comparison.

.PARAMETER Observe
  Attach in read-only observe mode.

.PARAMETER Focus
  Focus the TUI tab after attaching.

.PARAMETER Config
  Path to a sync.json file with defaults and targets.

.PARAMETER Target
  With -Config, run only the target with this name.

.PARAMETER All
  Run every target in ./sync.json.

.PARAMETER Adopt
  Mirror every TUI tab of -Machine into the desktop (TUI -> desktop), then exit.

.PARAMETER Watch
  With -Adopt, keep scanning and adopt new TUI tabs as they appear.

.PARAMETER AdoptSpace
  Desktop space that holds the mirrored tabs. Default: "<machine> TUI".

.PARAMETER AdoptIntervalSeconds
  Watch poll interval. Default: 15.

.PARAMETER Prune
  With -Adopt, close viewer tabs whose TUI terminal no longer exists.

.PARAMETER DryRun
  Show what would happen without changing anything.

.PARAMETER Json
  Emit one JSON object per target.

.EXAMPLE
  pwsh -File scripts/sync.ps1 -Machine my-vps -SpaceName agents -TabName codex

.EXAMPLE
  pwsh -File scripts/sync.ps1 -Machine my-vps -AgentArgv "claude"

.EXAMPLE
  pwsh -File scripts/sync.ps1 -All -Config ./sync.json

.EXAMPLE
  pwsh -File scripts/sync.ps1 -Machine my-vps -Adopt

.EXAMPLE
  pwsh -File scripts/sync.ps1 -Machine my-vps -Watch -Prune
#>
[CmdletBinding()]
param(
    [string]$Machine = '',
    [string]$SpaceName = 'agents',
    [string]$TabName = 'codex',
    [string]$AgentArgv = 'codex --no-daemon',
    [string]$Folder = '',
    [string]$RemoteHc = '',
    [string]$RemoteHerdr = '',
    [switch]$ReplaceTuiTab,
    [switch]$Restart,
    [switch]$SelectDesktop,
    [switch]$SkipVerify,
    [switch]$Observe,
    [switch]$Focus,
    [string]$Config = '',
    [string]$Target = '',
    [switch]$All,
    [switch]$Adopt,
    [switch]$Watch,
    [int]$AdoptIntervalSeconds = 15,
    [string]$AdoptSpace = '',
    [switch]$Prune,
    [switch]$DryRun,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/herdr-sync.psm1') -Force

if ($Adopt -or $Watch) {
    if (-not $Machine) {
        throw 'Pass -Machine with a name from `hc machine ls` to adopt TUI tabs.'
    }
    $adoptArguments = @{
        Machine         = $Machine
        Watch           = [bool]$Watch
        IntervalSeconds = $AdoptIntervalSeconds
        Prune           = [bool]$Prune
        DryRun          = [bool]$DryRun
        Json            = [bool]$Json
    }
    if ($AdoptSpace) {
        $adoptArguments['SpaceName'] = $AdoptSpace
    }
    if ($RemoteHerdr) {
        $adoptArguments['RemoteHerdr'] = $RemoteHerdr
    }
    & (Join-Path $PSScriptRoot 'adopt-tui.ps1') @adoptArguments
    exit $LASTEXITCODE
}

function Get-ConfigValue {
    param($Object, [string]$Name, $Default)

    if ($null -eq $Object) {
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Get-SyncTargets {
    if (-not ($All -or $Config)) {
        if (-not $Machine) {
            throw 'Pass -Machine with a name from `hc machine ls`, or -All/-Config with a sync.json file.'
        }
        return @([pscustomobject]@{
            Name         = $TabName
            Machine      = $Machine
            SpaceName    = $SpaceName
            TabName      = $TabName
            AgentArgv    = $AgentArgv
            Folder       = $Folder
            RemoteHc     = $RemoteHc
            RemoteHerdr  = $RemoteHerdr
            ReplaceTui   = [bool]$ReplaceTuiTab
            Restart      = [bool]$Restart
            Observe      = [bool]$Observe
            Focus        = [bool]$Focus
            SkipVerify   = [bool]$SkipVerify
        })
    }

    $configPath = $Config
    if (-not $configPath) {
        $configPath = Join-Path (Get-Location) 'sync.json'
    }
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "config file not found: $configPath (create sync.json or pass -Config)"
    }

    $document = (Get-Content -Raw -LiteralPath $configPath) | ConvertFrom-Json
    $defaults = Get-ConfigValue -Object $document -Name 'defaults' -Default $null

    $items = @()
    if ($null -ne $document.PSObject.Properties['targets']) {
        $items = @($document.targets)
    } elseif ($document -is [System.Array]) {
        $items = @($document)
    }

    if ($items.Count -eq 0) {
        throw "config file has no targets: $configPath"
    }

    $targets = foreach ($item in $items) {
        [pscustomobject]@{
            Name        = [string](Get-ConfigValue -Object $item -Name 'name' -Default "$(Get-ConfigValue -Object $item -Name 'tab' -Default '')@$(Get-ConfigValue -Object $item -Name 'machine' -Default '')")
            Machine     = [string](Get-ConfigValue -Object $item -Name 'machine' -Default '')
            SpaceName   = [string](Get-ConfigValue -Object $item -Name 'space' -Default (Get-ConfigValue -Object $defaults -Name 'space' -Default 'agents'))
            TabName     = [string](Get-ConfigValue -Object $item -Name 'tab' -Default 'codex')
            AgentArgv   = [string](Get-ConfigValue -Object $item -Name 'argv' -Default (Get-ConfigValue -Object $defaults -Name 'argv' -Default 'codex --no-daemon'))
            Folder      = [string](Get-ConfigValue -Object $item -Name 'folder' -Default (Get-ConfigValue -Object $defaults -Name 'folder' -Default ''))
            RemoteHc    = [string](Get-ConfigValue -Object $item -Name 'remoteHc' -Default (Get-ConfigValue -Object $defaults -Name 'remoteHc' -Default ''))
            RemoteHerdr = [string](Get-ConfigValue -Object $item -Name 'remoteHerdr' -Default (Get-ConfigValue -Object $defaults -Name 'remoteHerdr' -Default ''))
            ReplaceTui  = [bool]$ReplaceTuiTab -or [bool](Get-ConfigValue -Object $item -Name 'replaceTui' -Default (Get-ConfigValue -Object $defaults -Name 'replaceTui' -Default $false))
            Restart     = [bool]$Restart -or [bool](Get-ConfigValue -Object $item -Name 'restart' -Default (Get-ConfigValue -Object $defaults -Name 'restart' -Default $false))
            Observe     = [bool]$Observe -or [bool](Get-ConfigValue -Object $item -Name 'observe' -Default (Get-ConfigValue -Object $defaults -Name 'observe' -Default $false))
            Focus       = [bool]$Focus -or [bool](Get-ConfigValue -Object $item -Name 'focus' -Default (Get-ConfigValue -Object $defaults -Name 'focus' -Default $false))
            SkipVerify  = [bool]$SkipVerify -or [bool](Get-ConfigValue -Object $item -Name 'skipVerify' -Default (Get-ConfigValue -Object $defaults -Name 'skipVerify' -Default $false))
        }
    }

    if ($Target) {
        $selected = @($targets | Where-Object { $_.Name -eq $Target -or $_.TabName -eq $Target })
        if ($selected.Count -eq 0) {
            throw "target '$Target' not found in $configPath (available: $((@($targets | ForEach-Object { $_.Name })) -join ', '))"
        }
        return @($selected[0])
    }

    return @($targets)
}

function Invoke-SyncTarget {
    param($Target)

    if (-not $Target.Machine) {
        throw 'target has no machine'
    }
    if (-not $Target.TabName) {
        throw 'target has no tab name'
    }

    $setupScript = Join-Path $PSScriptRoot 'setup-desktop.ps1'
    $attachScript = Join-Path $PSScriptRoot 'attach-tui.sh'

    $setupArguments = @{
        Machine   = $Target.Machine
        SpaceName = $Target.SpaceName
        TabName   = $Target.TabName
        AgentArgv = $Target.AgentArgv
        Json      = $true
    }
    if ($Target.Folder) { $setupArguments['Folder'] = $Target.Folder }
    if ($Target.Restart) { $setupArguments['Replace'] = $true }
    if ($SelectDesktop) { $setupArguments['SelectDesktop'] = $true }
    if ($DryRun) { $setupArguments['DryRun'] = $true }

    $setupOutput = & $setupScript @setupArguments
    try {
        $desktop = ($setupOutput | Out-String).Trim() | ConvertFrom-Json
    } catch {
        throw "setup-desktop.ps1 returned invalid JSON: $($setupOutput | Out-String)"
    }

    if ($DryRun) {
        return [pscustomobject]@{
            name             = $Target.Name
            machine          = $Target.Machine
            ok               = $true
            dry_run          = $true
            desktop_action   = [string]$desktop.action
            space            = [string]$desktop.space
            tab              = [string]$desktop.tab
            terminal         = [string]$desktop.terminal
            local_terminal   = [string]$desktop.local_terminal
            tui_tab          = $null
            tui_pane         = $null
            tui_reused       = $false
            tui_replaced     = 0
            observe          = [bool]$Target.Observe
            focused          = $false
            shared_line      = $null
            verified         = $false
            error            = $null
        }
    }

    $attachArguments = @($desktop.local_terminal, $Target.TabName, '--json')
    if ($Target.ReplaceTui) { $attachArguments += '--replace' }
    if ($Target.Observe) { $attachArguments += '--observe' }
    if ($Target.Focus) { $attachArguments += '--focus' }
    if ($Target.RemoteHc) { $attachArguments += @('--hc', $Target.RemoteHc) }
    if ($Target.RemoteHerdr) { $attachArguments += @('--herdr', $Target.RemoteHerdr) }

    $quotedArguments = ($attachArguments | ForEach-Object { ConvertTo-ShSingleQuoted -Value $_ }) -join ' '
    # Strip CR on the remote: Windows PowerShell appends CRLF to piped stdin.
    $remoteCommand = "tr -d '\r' | bash -s -- $quotedArguments"

    # Send the script over stdin: no predictable /tmp path, no second copy step.
    $scriptText = (Get-Content -Raw -LiteralPath $attachScript) -replace "`r`n", "`n"
    if (-not $scriptText.EndsWith("`n")) {
        $scriptText += "`n"
    }

    $output = $scriptText | & hc exec -i --on $Target.Machine $remoteCommand 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "attach-tui.sh failed on $($Target.Machine) (exit $LASTEXITCODE):`n$($output | Out-String)"
    }
    $attach = ConvertFrom-AttachOutput -Text ($output | Out-String)

    $core = Get-CoreTerminal -Address $desktop.terminal
    if (-not $core -or $core.state -ne 'live') {
        throw "herdr-core terminal $($desktop.terminal) is not live"
    }

    $sharedLine = $null
    if (-not $Target.SkipVerify) {
        $desktopText = (& hc read $desktop.terminal --lines 200 2>&1 | Out-String)
        $readCommand = "$(ConvertTo-ShSingleQuoted -Value $attach.Herdr) pane read $(ConvertTo-ShSingleQuoted -Value $attach.Pane) --source recent --lines 200"
        $tuiText = (& hc exec --on $Target.Machine $readCommand 2>&1 | Out-String)
        $sharedLine = Get-SharedScreenLine -Left (Get-ScreenLines -Text $desktopText) -Right (Get-ScreenLines -Text $tuiText)
    }

    return [pscustomobject]@{
        name             = $Target.Name
        machine          = $Target.Machine
        ok               = $true
        dry_run          = $false
        desktop_action   = [string]$desktop.action
        space            = [string]$desktop.space
        tab              = [string]$desktop.tab
        terminal         = [string]$desktop.terminal
        local_terminal   = [string]$desktop.local_terminal
        state            = [string]$core.state
        agent            = [string]$desktop.agent
        status           = [string]$desktop.status
        tui_tab          = [string]$attach.Tab
        tui_pane         = [string]$attach.Pane
        tui_reused       = [bool]$attach.Reused
        tui_replaced     = [int]$attach.Replaced
        observe          = [bool]$attach.Observed
        focused          = [bool]$attach.Focused
        shared_line      = $sharedLine
        verified         = [bool]$sharedLine
        error            = $null
    }
}

$targets = @(Get-SyncTargets)
$results = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($syncTarget in $targets) {
    try {
        $result = Invoke-SyncTarget -Target $syncTarget
        $results.Add($result)
    } catch {
        $message = $_.Exception.Message
        $failures.Add("$($syncTarget.Name): $message")
        $results.Add([pscustomobject]@{
            name     = $syncTarget.Name
            machine  = $syncTarget.Machine
            ok       = $false
            dry_run  = [bool]$DryRun
            error    = $message
        })
        Write-Error -Message "[$( $syncTarget.Name )] $message" -ErrorAction Continue
    }
}

if ($Json) {
    @($results) | ConvertTo-Json -Depth 6
} else {
    $index = 0
    foreach ($result in $results) {
        $index++
        Write-Host ''
        Write-Host "[$index/$($targets.Count)] $($result.name)"
        if (-not $result.ok) {
            Write-Host "  failed   : $($result.error)"
            continue
        }
        if ($result.dry_run) {
            Write-Host "  desktop  : $($result.desktop_action) (space=$($result.space), tab=$($result.tab))"
            Write-Host "  tui      : would attach $($result.local_terminal)"
            continue
        }
        Write-Host "  space    : $($result.space)"
        Write-Host "  tab      : $($result.tab) ($($result.desktop_action))"
        Write-Host "  terminal : $($result.terminal) (state=$($result.state), agent=$($result.agent), status=$($result.status))"
        Write-Host "  tui      : tab $($result.tui_tab), pane $($result.tui_pane), reused=$($result.tui_reused), observe=$($result.observe), focused=$($result.focused)"
        if ($result.verified) {
            Write-Host "  shared   : yes ($($result.shared_line))"
        } elseif ($SkipVerify) {
            Write-Host '  shared   : verification skipped.'
        } else {
            Write-Host '  shared   : attach confirmed, but no identical rendered line was found (very different pane widths).'
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) target(s) failed:"
    foreach ($failure in $failures) {
        Write-Host "  - $failure"
    }
    exit 1
}
