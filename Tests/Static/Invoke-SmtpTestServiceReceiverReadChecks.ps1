[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$summary = & (Join-Path $PSScriptRoot 'Fixtures/SmtpTestServiceReceiverReadChecks.ps1')
$summary | ConvertTo-Json -Depth 8 -Compress
if ($summary.Failed -ne 0) { exit 1 }
