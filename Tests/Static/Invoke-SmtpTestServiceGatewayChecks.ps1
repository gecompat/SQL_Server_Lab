#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sourcePaths=@('Tools/SmtpTestServiceGateway.py','Tests/Static/Fixtures/SmtpTestServiceGatewayChecks.py','Tests/Static/Invoke-SmtpTestServiceGatewayChecks.ps1','Tools/Initialize-SqlServerLabHostTools.ps1','Private/HostToolResolution.ps1')
$before=@{}
try {
    foreach($path in $sourcePaths){$before[$path]=(Get-FileHash -LiteralPath (Join-Path $repoRoot $path) -Algorithm SHA256).Hash}
    $resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name python)
    if($resolution.Count -ne 1 -or -not $resolution[0].Available -or $resolution[0].Invocation -isnot [string] -or -not [IO.Path]::IsPathRooted($resolution[0].Invocation)){throw 'SMTP_GATEWAY_RUNTIME_UNAVAILABLE'}
    $output=& $resolution[0].Invocation -I -B (Join-Path $PSScriptRoot 'Fixtures/SmtpTestServiceGatewayChecks.py') 2>$null
    if($LASTEXITCODE -ne 0 -or @($output).Count -ne 7){throw 'SMTP_GATEWAY_CHECK_FAILED'}
    $rows=@($output|ForEach-Object {$_|ConvertFrom-Json})
    if($rows[0].Case -cne 'G01_STORAGE_COUNT' -or $rows[5].Case -cne 'G06_ESMTP_PATH' -or $rows[6].Passed -ne 6 -or $rows[6].Failed -ne 0 -or $rows[6].SourceSha256 -cne $before['Tools/SmtpTestServiceGateway.py'].ToLowerInvariant()){throw 'SMTP_GATEWAY_CHECK_DTO_INVALID'}
    foreach($path in $sourcePaths){if((Get-FileHash -LiteralPath (Join-Path $repoRoot $path) -Algorithm SHA256).Hash -cne $before[$path]){throw 'SMTP_GATEWAY_CHECK_SOURCE_CHANGED'}}
    Write-Host 'SMTP quota gateway: PASS (6/6)'
} catch {
    Write-Host 'SMTP quota gateway: FAIL' -ForegroundColor Red
    exit 1
}
