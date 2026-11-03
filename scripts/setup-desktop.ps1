#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Create or reuse the Herdr desktop space/tab that owns the shared agent terminal.

.DESCRIPTION
  The desktop app stores its terminals in herdr-core. This script makes sure a
  space and tab exist on the given machine, starts the agent in the tab's
  herdr-core terminal, and reports the terminal address.

  It is idempotent: an existing space, tab and live terminal are reused.

  A live terminal is only recreated when:
    - it is sitting at an interactive shell prompt (the agent exited), or
    - -Replace was passed explicitly.

  A live terminal running an unrecognized foreground process (npx, uv run,
  node script.js) is kept and reported as a warning, because recreating it would
  kill a session that may still be healthy.

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

.PARAMETER Replace
  Recreate a live tab even when the agent cannot be confirmed. This can end a
  running agent session.

.PARAMETER NoReplace
  Never close or recreate an existing tab. Fail instead.

.PARAMETER DryRun
  Report what would happen without changing anything.

.PARAMETER Json
  Emit one JSON object instead of human-readable output.

.EXAMPLE
  pwsh -File scripts/setup-desktop.ps1 -Machine my-vps -SpaceName agents -TabName codex

.EXAMPLE
  pwsh -File scripts/setup-desktop.ps1 -Machine my-vps -Json

.EXAMPLE
  pwsh -File scripts/setup-desktop.ps1 -Machine my-vps -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Machine,

    [string]$SpaceName = 'agents',
    [string]$TabName = 'codex',
    [string]$AgentArgv = 'codex --no-daemon',
    [string]$Folder = '',
    [switch]$SelectDesktop,
    [switch]$Replace,
    [switch]$NoReplace,
    [switch]$DryRun,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/herdr-sync.psm1') -Force

if ($Replace -and $NoReplace) {
    throw '-Replace and -NoReplace cannot be used together.'
}

function Write-Info {
    param([string]$Message)
    if (-not $Json) {
        Write-Host $Message
    }
}

$script:warnings = [System.Collections.Generic.List[string]]::new()

function Add-WarningMessage {
    param([string]$Message)
    $script:warnings.Add($Message)
    Write-Warning $Message
}

function Get-SpaceTabs {
    param([string]$SpaceId)

    $state = Get-HerdrState
    $space = @($state.spaces | Where-Object { $_.id -eq $SpaceId }) | Select-Object -First 1
    if (-not $space) {
        throw "desktop space '$SpaceId' disappeared while the script was running"
    }
    return @($space.tabs)
}

function Get-FirstTerminalAddress {
    param($Tab)
    $terminal = @($Tab.terminals) | Select-Object -First 1
    if ($terminal) {
        return [string]$terminal.terminal
    }
    return ''
}

function New-DesktopTab {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$SpaceId, [string]$ArgvJson)

    if (-not $PSCmdlet.ShouldProcess("space $SpaceId", "create desktop tab '$TabName'")) {
        throw "creation of tab '$TabName' was cancelled"
    }

    $arguments = @('do', 'tab.new', '--space', $SpaceId, '--name', $TabName, '--argv', $ArgvJson)
    if ($Folder) {
        $arguments += @('--folder', $Folder)
    }

    $raw = Invoke-HerdrApp -Arguments $arguments
    try {
        $created = $raw | ConvertFrom-Json
    } catch {
        throw "tab.new returned invalid JSON: $raw"
    }

    if (-not $created.tab -or -not $created.terminal) {
        throw "tab.new did not return a tab and terminal: $raw"
    }

    return $created
}

function Close-DesktopTab {
    param([string]$TabId)

    $arguments = @('do', 'tab.close', '--id', $TabId, '--confirmed', 'true')
    Invoke-HerdrApp -Arguments $arguments | Out-Null
}

function Wait-CoreTerminalLive {
    param([string]$Address, [int]$TimeoutSeconds = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $core = Get-CoreTerminal -Address $Address
        if ($core -and $core.state -eq 'live') {
            return $core
        }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)

    throw "herdr-core terminal '$Address' did not become live within $TimeoutSeconds seconds"
}

foreach ($binary in @('herdr-app', 'hc')) {
    if (-not (Get-Command $binary -ErrorAction SilentlyContinue)) {
        throw "$binary was not found in PATH"
    }
}

# Fail early with the list of valid names instead of a herdr-app error later.
$machineJson = (& hc machine ls --json 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "hc machine ls failed: $machineJson"
}
try {
    $registeredMachines = @((($machineJson | ConvertFrom-Json).machines) | ForEach-Object { [string]$_.name })
} catch {
    throw "hc machine ls returned invalid JSON: $machineJson"
}
if ($Machine -notin $registeredMachines) {
    throw "machine '$Machine' is not registered. Known machines: $($registeredMachines -join ', ')"
}

$agentArgvList = @(Split-AgentCommandLine -Line $AgentArgv)
if ($agentArgvList.Count -eq 0) {
    throw '-AgentArgv is empty'
}
$argvJson = ConvertTo-Json -InputObject $agentArgvList -Compress
$agentName = [System.IO.Path]::GetFileNameWithoutExtension($agentArgvList[0])

$state = Get-HerdrState
$matchingSpaces = @($state.spaces | Where-Object { $_.machine -eq $Machine -and $_.name -eq $SpaceName })
if ($matchingSpaces.Count -gt 1) {
    Add-WarningMessage "more than one space is named '$SpaceName' on $Machine; using $($matchingSpaces[0].id)"
}
$space = $matchingSpaces | Select-Object -First 1

$spaceId = ''
$tabId = ''
$terminalAddress = ''
$action = 'reused'
$agentConfirmed = $false

if (-not $space) {
    if ($DryRun) {
        $result = [pscustomobject]@{
            machine        = $Machine
            space          = $null
            tab            = $null
            terminal       = $null
            local_terminal = $null
            state          = $null
            agent          = $null
            status         = $null
            action         = 'would-create'
            agent_confirmed = $false
            dry_run        = $true
            warnings       = @($script:warnings)
        }
        if ($Json) { $result | ConvertTo-Json -Compress -Depth 5 } else { Write-Host "Would create space '$SpaceName' and tab '$TabName'." }
        return
    }

    $arguments = @(
        'do', 'space.new',
        '--machine', $Machine,
        '--name', $SpaceName,
        '--tab', $TabName,
        '--argv', $argvJson
    )
    if ($Folder) {
        $arguments += @('--folder', $Folder)
    }

    $raw = Invoke-HerdrApp -Arguments $arguments
    try {
        $created = $raw | ConvertFrom-Json
    } catch {
        throw "space.new returned invalid JSON: $raw"
    }
    if (-not $created.space -or -not $created.tab -or -not $created.terminal) {
        throw "space.new did not return space, tab and terminal: $raw"
    }

    $spaceId = [string]$created.space
    $tabId = [string]$created.tab
    $terminalAddress = [string]$created.terminal
    $action = 'created'
    Write-Info "created space '$SpaceName' ($spaceId)"
} else {
    $spaceId = [string]$space.id
    Write-Info "reusing space '$SpaceName' ($spaceId)"

    $matchingTabs = @($space.tabs | Where-Object { $_.name -eq $TabName })
    $tabStates = foreach ($tab in $matchingTabs) {
        $address = Get-FirstTerminalAddress -Tab $tab
        $core = $null
        if ($address) {
            $core = Get-CoreTerminal -Address $address
        }
        [pscustomobject]@{
            Tab     = $tab
            Address = $address
            Core    = $core
        }
    }

    $liveTabs = @($tabStates | Where-Object { $_.Core -and $_.Core.state -eq 'live' })
    $chosen = $null
    if ($liveTabs.Count -gt 0) {
        $chosen = $liveTabs |
            Where-Object { Test-AgentInTerminal -Core $_.Core -AgentName $agentName } |
            Select-Object -First 1
        if (-not $chosen) {
            $chosen = $liveTabs[0]
        }
        if ($liveTabs.Count -gt 1) {
            Add-WarningMessage "multiple live tabs are named '$TabName'; reusing $($chosen.Tab.id)"
        }
    }

    if ($chosen) {
        $tabId = [string]$chosen.Tab.id
        $terminalAddress = [string]$chosen.Address

        if (Test-AgentInTerminal -Core $chosen.Core -AgentName $agentName) {
            $action = 'reused'
            Write-Info "reusing tab '$TabName' ($tabId) -> $terminalAddress"
        } elseif (Test-ShellForeground -Core $chosen.Core) {
            if ($NoReplace) {
                throw "tab '$TabName' is live but its agent is not running (shell prompt). Re-run without -NoReplace to restart it."
            }
            $action = 'replaced'
            Write-Info "tab '$TabName' is live but '$agentName' is not running; restarting the agent"
        } elseif ($Replace) {
            $action = 'replaced'
            Write-Info "tab '$TabName' is live but '$agentName' is not confirmed; recreating because -Replace was passed"
        } else {
            Add-WarningMessage ("could not confirm agent '$agentName' in $terminalAddress " +
                "(foreground: '$($chosen.Core.foreground.name)'); keeping the live tab so a running " +
                "session is not killed. Pass -Replace to restart it.")
        }
    } elseif ($tabStates.Count -gt 0) {
        if ($NoReplace) {
            throw "tab '$TabName' exists but its terminal is not live. Re-run without -NoReplace to replace it."
        }
        $action = 'replaced'
        Write-Info "tab '$TabName' exists but its terminal is not live; replacing it"
    } else {
        $action = 'created'
    }

    if ($DryRun) {
        $agentConfirmed = [bool]($chosen -and (Test-AgentInTerminal -Core $chosen.Core -AgentName $agentName))
        $reportedAgent = $null
        $reportedStatus = $null
        if ($chosen -and $chosen.Core) {
            if ($chosen.Core.status) {
                $reportedAgent = [string]$chosen.Core.status.app
                $reportedStatus = [string]$chosen.Core.status.state
            }
            if (-not $reportedAgent -and $chosen.Core.foreground) {
                $reportedAgent = [string]$chosen.Core.foreground.name
            }
        }
        $plannedAction = $action
        if ($action -ne 'reused') {
            $plannedAction = "would-$action"
        }

        $result = [pscustomobject]@{
            machine         = $Machine
            space           = $spaceId
            tab             = if ($tabId) { $tabId } else { $null }
            terminal        = if ($terminalAddress) { $terminalAddress } else { $null }
            local_terminal  = if ($terminalAddress) { Get-LocalTerminalAddress -Address $terminalAddress -Machine $Machine } else { $null }
            state           = if ($chosen) { [string]$chosen.Core.state } else { $null }
            agent           = $reportedAgent
            status          = $reportedStatus
            action          = $plannedAction
            agent_confirmed = $agentConfirmed
            dry_run         = $true
            warnings        = @($script:warnings)
        }
        if ($Json) {
            $result | ConvertTo-Json -Compress -Depth 5
        } else {
            Write-Host "Would $action tab '$TabName' in space $spaceId."
        }
        return
    }

    if ($action -eq 'replaced') {
        $created = New-DesktopTab -SpaceId $spaceId -ArgvJson $argvJson
        $newTabId = [string]$created.tab
        $terminalAddress = [string]$created.terminal

        # Close every stale tab with this name, but never the replacement.
        foreach ($candidate in $tabStates) {
            if ([string]$candidate.Tab.id -eq $newTabId) {
                continue
            }
            try {
                Close-DesktopTab -TabId ([string]$candidate.Tab.id)
            } catch {
                Add-WarningMessage "could not close stale tab $($candidate.Tab.id): $($_.Exception.Message)"
            }
        }

        $tabId = $newTabId
        Write-Info "created replacement tab '$TabName' ($tabId)"
    } elseif ($action -eq 'created') {
        $created = New-DesktopTab -SpaceId $spaceId -ArgvJson $argvJson
        $tabId = [string]$created.tab
        $terminalAddress = [string]$created.terminal
        Write-Info "created tab '$TabName' ($tabId)"
    }
}

if (-not $terminalAddress) {
    # space.new and tab.new both return the terminal; this is only a fallback.
    $deadline = (Get-Date).AddSeconds(30)
    do {
        $tabs = Get-SpaceTabs -SpaceId $spaceId
        foreach ($candidate in $tabs) {
            if ($candidate.name -ne $TabName) { continue }
            $address = Get-FirstTerminalAddress -Tab $candidate
            $core = Get-CoreTerminal -Address $address
            if ($core -and $core.state -eq 'live') {
                $terminalAddress = $address
                $tabId = [string]$candidate.id
                break
            }
        }
        if ($terminalAddress) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    if (-not $terminalAddress) {
        throw "could not find a live desktop terminal for tab '$TabName' in space $spaceId"
    }
}

$core = Wait-CoreTerminalLive -Address $terminalAddress

$deadline = (Get-Date).AddSeconds(20)
while (-not (Test-AgentInTerminal -Core $core -AgentName $agentName) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $core = Get-CoreTerminal -Address $terminalAddress
}
$agentConfirmed = [bool](Test-AgentInTerminal -Core $core -AgentName $agentName)
if (-not $agentConfirmed) {
    Add-WarningMessage "agent '$agentName' did not appear in $terminalAddress within 20 seconds"
}

if ($SelectDesktop) {
    Invoke-HerdrApp -Arguments @('do', 'space.select', '--id', $spaceId) | Out-Null
}

$tabEntry = $null
foreach ($candidate in (Get-SpaceTabs -SpaceId $spaceId)) {
    if ((Get-FirstTerminalAddress -Tab $candidate) -eq $terminalAddress) {
        $tabEntry = @($candidate.terminals) | Select-Object -First 1
        break
    }
}

$result = [pscustomobject]@{
    machine         = $Machine
    space           = $spaceId
    tab             = $tabId
    terminal        = $terminalAddress
    local_terminal  = Get-LocalTerminalAddress -Address $terminalAddress -Machine $Machine
    state           = [string]$core.state
    agent           = if ($tabEntry) { [string]$tabEntry.app } else { $null }
    status          = if ($tabEntry) { [string]$tabEntry.status } else { $null }
    action          = $action
    agent_confirmed = $agentConfirmed
    warnings        = @($script:warnings)
}

if ($Json) {
    $result | ConvertTo-Json -Compress -Depth 5
    return
}

Write-Host ''
Write-Host "Desktop space : $SpaceName ($action)"
Write-Host "Desktop tab   : $TabName"
Write-Host "Space id      : $($result.space)"
Write-Host "Tab id        : $($result.tab)"
Write-Host "Terminal      : $($result.terminal) ($($result.state))"
Write-Host "Local address : $($result.local_terminal)"
Write-Host "Agent         : $($result.agent) / $($result.status)"
if ($script:warnings.Count -gt 0) {
    Write-Host "Warnings      : $($script:warnings.Count) (see above)"
}
Write-Host ''
Write-Host "Next: run scripts/attach-tui.sh $($result.local_terminal) $TabName on the remote machine."
