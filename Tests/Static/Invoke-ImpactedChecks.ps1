#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt nur die von geaenderten Pfaden betroffenen statischen Suites aus.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$ChangedPath,
    [switch]$Development,
    [switch]$NoReuse
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$selector = Join-Path $repoRoot 'Tools/Get-CiTestSelection.ps1'
$selection = & $selector -ChangedPath $ChangedPath
$pwsh = Get-Command pwsh -ErrorAction Stop
$failures = [System.Collections.Generic.List[string]]::new()
. (Join-Path $repoRoot 'Tests/Common/LocalStaticEvidence.ps1')
$cacheEnabled = $env:GITHUB_ACTIONS -ne 'true'
$reuse = $cacheEnabled -and $Development -and -not $NoReuse
$evidenceRoot = Join-Path $repoRoot '.artifacts/test-runs/local-static-evidence'
foreach ($part in @('.artifacts','.artifacts/test-runs','.artifacts/test-runs/local-static-evidence')) {
    $directory=Join-Path $repoRoot $part
    if ((Test-Path -LiteralPath $directory) -and ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $cacheEnabled=$false; $reuse=$false }
}
if ($cacheEnabled) { $null=New-Item -ItemType Directory -Path $evidenceRoot -Force }

Write-Host "Betroffene statische Suites: $($selection.StaticChecks -join ', ')" -ForegroundColor Cyan
foreach ($check in $selection.StaticChecks) {
    Write-Host "`n=== $check ===" -ForegroundColor Cyan
    $binding=if ($cacheEnabled) { Get-LocalStaticEvidenceBinding -RepoRoot $repoRoot -Check $check -ChangedPath $ChangedPath -RunnerInvocation $pwsh.Source }
    $recordPath=Join-Path $evidenceRoot ($check+'.json')
    $lock=$null
    try {
        if ($binding) {
            # Exclusive local custody; another writer means NOT_EXECUTED.
            if (@($recordPath,$recordPath+'.lock') | Where-Object { (Test-Path -LiteralPath $_) -and ((Get-Item -LiteralPath $_ -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }) { $binding=$null }
            else { try { $lock=[IO.File]::Open($recordPath+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch { $failures.Add("$check (LOCAL_EVIDENCE_BUSY_NOT_EXECUTED)"); continue } }
        }
        if ($reuse -and $binding -and (Test-LocalStaticEvidence -Path $recordPath -Binding $binding)) {
            Write-Host "REUSED: $check (original execution retained; not a fresh PASS)"
            continue
        }
        if ($binding) { @{Schema='LOCAL_STATIC_EVIDENCE/v1';Status='RUNNING';Binding=$binding} | ConvertTo-Json | Set-Content -LiteralPath $recordPath }
        $arguments=@('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot $check))
        if ($Development -and $check -in @('Invoke-PesterChecks.ps1','Invoke-PSScriptAnalyzerChecks.ps1')) {
            # -File does not portably marshal array parameters to a new process.
            $encodedPaths=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($ChangedPath) -Compress)))
            $entry=(Join-Path $PSScriptRoot $check).Replace("'","''")
            $command="& '$entry' -ChangedPath @(([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedPaths')) | ConvertFrom-Json))"
            $arguments=@('-NoLogo','-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
        }
        if ($binding) {
            $log=Join-Path $evidenceRoot ([guid]::NewGuid().ToString('N')+'.private.log')
            & $pwsh.Source @arguments *> $log
            $code=$LASTEXITCODE
            $end=Get-LocalStaticEvidenceBinding -RepoRoot $repoRoot -Check $check -ChangedPath $ChangedPath -RunnerInvocation $pwsh.Source
            $stable=$end -ceq $binding
            $record=@{Schema='LOCAL_STATIC_EVIDENCE/v1';Status=if($code -eq 0 -and $stable){'EXECUTED_PASS'}else{'FAIL_OR_UNKNOWN'};
                Binding=$binding;ExitCode=$code;SourceStable=$stable;CompletedUtc=[datetime]::UtcNow.ToString('o');Log=$log;LogSHA256=(Get-FileHash -LiteralPath $log).Hash}
            $record | ConvertTo-Json | Set-Content -LiteralPath $recordPath
            Write-Host "$($record.Status): $check; private log: $log"
            if ($code -ne 0) { Get-Content -LiteralPath $log -Tail 20 | Out-Host }
            if (-not $stable) { $failures.Add("$check (source binding changed)") }
        } else { & $pwsh.Source @arguments; $code=$LASTEXITCODE }
        if ($code -ne 0) { $failures.Add("$check (Exitcode $code)") }
    } finally { if ($lock) { $lock.Dispose() } }
}

if ($failures.Count -gt 0) {
    throw "Betroffene statische Vertragspruefungen fehlgeschlagen: $($failures -join '; ')"
}

Write-Host "`nBETROFFENE STATISCHE VERTRAGSPRUEFUNGEN: PASS" -ForegroundColor Green
