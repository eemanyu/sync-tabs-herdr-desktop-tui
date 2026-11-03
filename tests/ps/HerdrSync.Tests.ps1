#Requires -Version 7.0
BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\..\scripts\lib\herdr-sync.psm1'
    Import-Module $modulePath -Force
}

Describe 'Split-AgentCommandLine' {
    It 'splits plain arguments' {
        Split-AgentCommandLine -Line 'codex --no-daemon' | Should -Be @('codex', '--no-daemon')
    }

    It 'keeps quoted whitespace together' {
        $result = Split-AgentCommandLine -Line 'sh -c "while :; do echo hi; sleep 1; done"'
        $result | Should -Be @('sh', '-c', 'while :; do echo hi; sleep 1; done')
    }

    It 'does not split on commas' {
        Split-AgentCommandLine -Line 'agent --tools a,b,c' | Should -Be @('agent', '--tools', 'a,b,c')
    }

    It 'keeps single-quoted text together' {
        Split-AgentCommandLine -Line "agent --task 'fix the bug'" | Should -Be @('agent', '--task', 'fix the bug')
    }

    It 'keeps an unquoted Windows path with backslashes' {
        Split-AgentCommandLine -Line 'C:\Users\emanuel\agent.exe --x' |
            Should -Be @('C:\Users\emanuel\agent.exe', '--x')
    }

    It 'rejects an unterminated quote' {
        { Split-AgentCommandLine -Line 'codex "unterminated' } | Should -Throw '*unterminated quote*'
    }
}

Describe 'ConvertTo-WindowsArgument' {
    It 'leaves a simple argument alone' {
        ConvertTo-WindowsArgument -Value 'plain' | Should -Be 'plain'
    }

    It 'quotes whitespace' {
        ConvertTo-WindowsArgument -Value 'a b' | Should -Be '"a b"'
    }

    It 'escapes an embedded quote' {
        ConvertTo-WindowsArgument -Value 'a"b' | Should -Be '"a\"b"'
    }

    It 'doubles backslashes before a closing quote' {
        ConvertTo-WindowsArgument -Value 'a b\' | Should -Be '"a b\\"'
    }
}

Describe 'ConvertTo-ShSingleQuoted' {
    It 'leaves a safe value alone' {
        ConvertTo-ShSingleQuoted -Value 't1' | Should -Be 't1'
    }

    It 'quotes a value with spaces' {
        ConvertTo-ShSingleQuoted -Value 'a b' | Should -Be "'a b'"
    }

    It 'escapes a single quote' {
        ConvertTo-ShSingleQuoted -Value "it's" | Should -Be "'it'\''s'"
    }
}

Describe 'Screen comparison helpers' {
    It 'normalizes whitespace and drops short lines' {
        $lines = Get-ScreenLines -Text "  alpha   beta  `r`n`r`n x `r`nalpha beta"
        $lines | Should -Be @('alpha beta')
    }

    It 'finds the longest shared line' {
        $left = @('one', 'two words here', 'unique left')
        $right = @('two words here', 'unique right')
        Get-SharedScreenLine -Left $left -Right $right | Should -Be 'two words here'
    }

    It 'returns null when nothing is shared' {
        Get-SharedScreenLine -Left @('a line', 'b line') -Right @('c line') | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AttachOutput' {
    It 'parses JSON output' {
        $json = '{"tab":"w1:t1","pane":"w1:p1","terminal":"t1","label":"codex","hc":"/bin/hc","herdr":"/bin/herdr","reused":false,"replaced":0,"duplicates":0,"observed":false,"attached":true,"focused":true,"focus_error":""}'
        $result = ConvertFrom-AttachOutput -Text $json
        $result.Tab | Should -Be 'w1:t1'
        $result.Reused | Should -BeFalse
        $result.Focused | Should -BeTrue
    }

    It 'ignores warning lines before the JSON object' {
        $text = "warning: something`n{`"tab`":`"w1:t2`",`"pane`":`"w1:p2`",`"terminal`":`"t1`",`"label`":`"codex`",`"hc`":`"hc`",`"herdr`":`"herdr`",`"reused`":true,`"replaced`":1,`"duplicates`":0,`"observed`":false,`"attached`":true,`"focused`":false}"
        $result = ConvertFrom-AttachOutput -Text $text
        $result.Tab | Should -Be 'w1:t2'
        $result.Reused | Should -BeTrue
        $result.Replaced | Should -Be 1
    }

    It 'parses the legacy KEY=VALUE format' {
        $text = "TAB=w1:t1`nPANE=w1:p1`nHC=/bin/hc`nHERDR=/bin/herdr`nATTACHED=yes`nREUSED=no"
        $result = ConvertFrom-AttachOutput -Text $text
        $result.Pane | Should -Be 'w1:p1'
        $result.Reused | Should -BeFalse
        $result.Attached | Should -BeTrue
    }

    It 'throws when required fields are missing' {
        { ConvertFrom-AttachOutput -Text 'TAB=w1:t1' } | Should -Throw '*could not parse*'
    }
}

Describe 'Terminal inspection helpers' {
    It 'strips the machine prefix' {
        Get-LocalTerminalAddress -Address 'pessoalvps/t1r' -Machine 'pessoalvps' | Should -Be 't1r'
        Get-LocalTerminalAddress -Address 't1r' -Machine 'pessoalvps' | Should -Be 't1r'
    }

    It 'detects the agent from OSC status' {
        $core = [pscustomobject]@{ status = [pscustomobject]@{ app = 'codex'; state = 'idle' }; foreground = $null }
        Test-AgentInTerminal -Core $core -AgentName 'codex' | Should -BeTrue
    }

    It 'detects the agent from the foreground process name' {
        $core = [pscustomobject]@{ status = $null; foreground = [pscustomobject]@{ name = 'codex'; argv = @('/usr/bin/codex') } }
        Test-AgentInTerminal -Core $core -AgentName 'codex' | Should -BeTrue
    }

    It 'does not treat a wrapper as a mismatch proof' {
        $core = [pscustomobject]@{ status = $null; foreground = [pscustomobject]@{ name = 'node'; argv = @('node', 'agent.js') } }
        Test-AgentInTerminal -Core $core -AgentName 'codex' | Should -BeFalse
    }

    It 'recognizes a shell prompt' {
        $core = [pscustomobject]@{ foreground = [pscustomobject]@{ name = 'pwsh.exe'; argv = @('pwsh.exe') } }
        Test-ShellForeground -Core $core | Should -BeTrue
    }

    It 'does not treat an agent as a shell prompt' {
        $core = [pscustomobject]@{ foreground = [pscustomobject]@{ name = 'codex'; argv = @('codex') } }
        Test-ShellForeground -Core $core | Should -BeFalse
    }
}
