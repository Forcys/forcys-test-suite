#requires -Version 5.1
<#
.SYNOPSIS
Public entry point for the Forcys Test Suite.

.DESCRIPTION
Thin compatibility wrapper around the suite orchestrator in scripts\. Keep this
file small so the public command stays stable while internals evolve.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$suiteScript = Join-Path -Path $PSScriptRoot -ChildPath "scripts\Invoke-ForcysTestSuite.ps1"
if (-not (Test-Path -LiteralPath $suiteScript)) {
    throw "Forcys suite orchestrator not found: $suiteScript"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $suiteScript @RemainingArguments
exit $LASTEXITCODE

