#Requires -Version 7.0
<#
  Shared helpers for the sync-tabs-herdr-desktop-tui scripts.

  Kept in a module so the parsers, quoting helpers and verification code can be
  unit tested with Pester without running herdr.
#>

function Split-AgentCommandLine {
    <#
      .SYNOPSIS
        Split an agent command line into an argv array.

      .DESCRIPTION
        Whitespace separates arguments. Single and double quotes group text, and
        a backslash escapes the next character when that character is whitespace,
        a quote or another backslash. Commas are ordinary characters: `a,b` is
        one argument, not two.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line
    )

    $tokens = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $quote = [char]0
    $hasToken = $false
    $index = 0

    while ($index -lt $Line.Length) {
        $character = $Line[$index]

        if ($quote -eq [char]39) {
            if ($character -eq [char]39) {
                $quote = [char]0
            } else {
                [void]$current.Append($character)
            }
            $hasToken = $true
        } elseif ($quote -eq [char]34) {
            if ($character -eq [char]92 -and $index + 1 -lt $Line.Length) {
                $next = $Line[$index + 1]
                if ($next -eq [char]34 -or $next -eq [char]92) {
                    $index++
                    [void]$current.Append($next)
                } else {
                    [void]$current.Append($character)
                }
            } elseif ($character -eq [char]34) {
                $quote = [char]0
            } else {
                [void]$current.Append($character)
            }
            $hasToken = $true
        } else {
            if ([char]::IsWhiteSpace($character)) {
                if ($hasToken) {
                    $tokens.Add($current.ToString())
                    [void]$current.Clear()
                    $hasToken = $false
                }
            } elseif ($character -eq [char]34 -or $character -eq [char]39) {
                $quote = $character
                $hasToken = $true
            } elseif ($character -eq [char]92 -and $index + 1 -lt $Line.Length) {
                $next = $Line[$index + 1]
                if ([char]::IsWhiteSpace($next) -or $next -eq [char]34 -or $next -eq [char]39 -or $next -eq [char]92) {
                    $index++
                    [void]$current.Append($next)
                    $hasToken = $true
                } else {
                    [void]$current.Append($character)
                    $hasToken = $true
                }
            } else {
                [void]$current.Append($character)
                $hasToken = $true
            }
        }

        $index++
    }

    if ($quote -ne [char]0) {
        throw "unterminated quote in agent command: $Line"
    }
    if ($hasToken) {
        $tokens.Add($current.ToString())
    }

    return $tokens.ToArray()
}

function ConvertTo-WindowsArgument {
    <#
      .SYNOPSIS
        Quote one argument the way the Windows C runtime expects.

      .DESCRIPTION
        This is the algorithm used by CommandLineToArgvW: wrap in double quotes
        only when needed, escape embedded quotes, and double the backslashes that
        precede a quote or the closing quote.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0

    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }

        if ($character -eq [char]34) {
            [void]$builder.Append([char]92, (2 * $backslashes) + 1)
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append([char]92, $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }

    if ($backslashes -gt 0) {
        [void]$builder.Append([char]92, 2 * $backslashes)
    }
    [void]$builder.Append('"')

    return $builder.ToString()
}

function ConvertTo-ShSingleQuoted {
    <#
      .SYNOPSIS
        Quote a string for a POSIX shell, using single quotes when needed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value -match '^[A-Za-z0-9_./:@%+=,-]+$') {
        return $Value
    }

    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Invoke-HerdrApp {
    <#
      .SYNOPSIS
        Run herdr-app and return its stdout.

      .DESCRIPTION
        herdr-app is a GUI-subsystem executable on Windows. Capturing it through
        a PowerShell pipeline can close the pipe before it finishes writing, so
        this redirects to temporary files and waits for the process instead.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$Executable = 'herdr-app'
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $argumentLine = ($Arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join ' '
        $startArguments = @{
            FilePath               = $Executable
            ArgumentList           = $argumentLine
            RedirectStandardOutput = $stdoutFile
            RedirectStandardError  = $stderrFile
            Wait                   = $true
            PassThru               = $true
        }
        if ($IsWindows) {
            $startArguments['NoNewWindow'] = $true
        }

        $process = Start-Process @startArguments
        $stdout = Get-Content -Raw -LiteralPath $stdoutFile -ErrorAction SilentlyContinue
        $stderr = Get-Content -Raw -LiteralPath $stderrFile -ErrorAction SilentlyContinue

        if ($process.ExitCode -ne 0) {
            $detail = ("$stderr$stdout").Trim()
            throw "$Executable $($Arguments -join ' ') failed (exit $($process.ExitCode)): $detail"
        }

        return ("$stdout$stderr").Trim()
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-HerdrState {
    <#
      .SYNOPSIS
        Read the desktop app's space/tab/terminal document.
    #>
    [CmdletBinding()]
    param(
        [string]$Executable = 'herdr-app'
    )

    $raw = Invoke-HerdrApp -Arguments @('ls') -Executable $Executable
    if (-not $raw) {
        throw "$Executable ls returned no output"
    }

    try {
        $state = $raw | ConvertFrom-Json
    } catch {
        throw "$Executable ls returned invalid JSON: $raw"
    }

    if ($null -eq $state.PSObject.Properties['spaces']) {
        throw "$Executable ls did not return a spaces array: $raw"
    }

    return $state
}

function Get-CoreTerminal {
    <#
      .SYNOPSIS
        Read one herdr-core terminal, or $null when it does not exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Address,

        [string]$Hc = 'hc'
    )

    $output = & $Hc get $Address --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    try {
        return (($output | Out-String).Trim() | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-LocalTerminalAddress {
    <#
      .SYNOPSIS
        Strip the machine prefix from a qualified terminal address.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Address,

        [Parameter(Mandatory)]
        [string]$Machine
    )

    if ($Address.StartsWith("$Machine/", [System.StringComparison]::Ordinal)) {
        return $Address.Substring($Machine.Length + 1)
    }
    return $Address
}

function Test-AgentInTerminal {
    <#
      .SYNOPSIS
        Best-effort check that the requested agent is the foreground process.

      .DESCRIPTION
        Uses the agent status reported over OSC 7501 when available, then the
        foreground process name, then the basenames in its argv. A wrapper such
        as `npx`, `uv run` or `node script.js` can still fail this check; callers
        must treat a false result as "unknown", not as "the agent is gone".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Core,

        [string]$AgentName = ''
    )

    if ($null -eq $Core) {
        return $false
    }
    if ($AgentName -and $Core.status -and $Core.status.app -eq $AgentName) {
        return $true
    }

    $foreground = $Core.foreground
    if ($null -eq $foreground) {
        return $false
    }
    if ($AgentName -and $foreground.name -eq $AgentName) {
        return $true
    }

    foreach ($argument in @($foreground.argv)) {
        if (-not $argument) {
            continue
        }
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension([string]$argument)
        if ($AgentName -and $leaf -eq $AgentName) {
            return $true
        }
    }

    return $false
}

function Test-ShellForeground {
    <#
      .SYNOPSIS
        True when the terminal's foreground process is an interactive shell.

      .DESCRIPTION
        A live terminal sitting at a shell prompt means the agent exited; that
        is the safe case for recreating the tab. Any other foreground process is
        treated as "unknown", so a live session is never killed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Core
    )

    if ($null -eq $Core -or $null -eq $Core.foreground) {
        return $false
    }

    $name = [System.IO.Path]::GetFileNameWithoutExtension([string]$Core.foreground.name)
    return $name -in @('sh', 'bash', 'zsh', 'dash', 'ksh', 'fish', 'pwsh', 'powershell', 'cmd', 'nu')
}

function Get-ScreenLines {
    <#
      .SYNOPSIS
        Normalize a screen capture into comparable lines.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    if (-not $Text) {
        return @()
    }

    $lines = foreach ($line in ($Text -split "\r?\n")) {
        $normalized = ($line.Trim() -replace '\s+', ' ')
        if ($normalized.Length -ge 4) {
            $normalized
        }
    }

    return @($lines | Select-Object -Unique)
}

function Get-SharedScreenLine {
    <#
      .SYNOPSIS
        Return the longest line present in both screen captures, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string[]]$Left = @(),

        [string[]]$Right = @()
    )

    if ($Left.Count -eq 0 -or $Right.Count -eq 0) {
        return $null
    }

    $rightSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$Right)
    $shared = @($Left | Where-Object { $rightSet.Contains($_) })
    if ($shared.Count -eq 0) {
        return $null
    }

    return ($shared | Sort-Object -Property Length -Descending | Select-Object -First 1)
}

function ConvertFrom-AttachOutput {
    <#
      .SYNOPSIS
        Parse attach-tui.sh output, in JSON or in the legacy KEY=VALUE form.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    if (-not $Text) {
        throw 'attach-tui.sh produced no output'
    }

    $trimmed = $Text.Trim()
    $jsonText = $null

    if ($trimmed.StartsWith('{')) {
        $jsonText = $trimmed
    } else {
        $jsonLines = @($trimmed -split "\r?\n" | Where-Object { $_.TrimStart().StartsWith('{') })
        if ($jsonLines.Count -gt 0) {
            $jsonText = $jsonLines[-1].Trim()
        }
    }

    if ($jsonText) {
        try {
            $object = $jsonText | ConvertFrom-Json
        } catch {
            $object = $null
        }

        if ($null -ne $object -and $null -ne $object.PSObject.Properties['tab']) {
            $attached = $true
            if ($null -ne $object.PSObject.Properties['attached']) {
                $attached = [bool]$object.attached
            }
            $duplicates = 0
            if ($null -ne $object.PSObject.Properties['duplicates']) {
                $duplicates = [int]$object.duplicates
            }
            $replaced = 0
            if ($null -ne $object.PSObject.Properties['replaced']) {
                $replaced = [int]$object.replaced
            }

            return [pscustomobject]@{
                Tab        = [string]$object.tab
                Pane       = [string]$object.pane
                Terminal   = [string]$object.terminal
                Label      = [string]$object.label
                Hc         = [string]$object.hc
                Herdr      = [string]$object.herdr
                Reused     = [bool]$object.reused
                Replaced   = $replaced
                Observed   = [bool]$object.observed
                Attached   = $attached
                Focused    = [bool]$object.focused
                Duplicates = $duplicates
            }
        }
    }

    $values = @{}
    foreach ($line in ($trimmed -split "\r?\n")) {
        if ($line -match '^([A-Z][A-Z0-9_]*)=(.*)$') {
            $values[$matches[1]] = $matches[2].Trim()
        }
    }

    foreach ($key in @('TAB', 'PANE', 'HC', 'HERDR')) {
        if (-not $values.ContainsKey($key)) {
            throw "could not parse attach-tui.sh output:`n$Text"
        }
    }

    return [pscustomobject]@{
        Tab        = [string]$values['TAB']
        Pane       = [string]$values['PANE']
        Terminal   = [string]$values['TERMINAL']
        Label      = [string]$values['LABEL']
        Hc         = [string]$values['HC']
        Herdr      = [string]$values['HERDR']
        Reused     = $values['REUSED'] -eq 'yes'
        Replaced   = 0
        Observed   = $values['OBSERVE'] -eq 'yes'
        Attached   = $values['ATTACHED'] -ne 'no'
        Focused    = $values['FOCUSED'] -eq 'yes'
        Duplicates = 0
    }
}

Export-ModuleMember -Function @(
    'Split-AgentCommandLine',
    'ConvertTo-WindowsArgument',
    'ConvertTo-ShSingleQuoted',
    'Invoke-HerdrApp',
    'Get-HerdrState',
    'Get-CoreTerminal',
    'Get-LocalTerminalAddress',
    'Test-AgentInTerminal',
    'Test-ShellForeground',
    'Get-ScreenLines',
    'Get-SharedScreenLine',
    'ConvertFrom-AttachOutput'
)
