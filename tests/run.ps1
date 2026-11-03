#Requires -Version 7.0
<#
  Run the Pester unit tests for scripts/lib/herdr-sync.psm1.
#>
param(
    [string]$Path = (Join-Path $PSScriptRoot 'ps')
)

$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.0

$result = Invoke-Pester -Path $Path -PassThru
if ($result.FailedCount -gt 0) {
    Write-Error "$($result.FailedCount) Pester test(s) failed"
}
