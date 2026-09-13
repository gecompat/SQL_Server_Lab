#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt die SQL-seitige Instanzcollation fuer einen Containerprovider.
.DESCRIPTION
    Erstellt einen isolierten SQL-2025-Container mit einer katalogisierten
    Custom-Collation. New-SqlServerLab fuehrt nach SQL-Readiness den privaten
    parameterisierten Nachweis aus. Der Test prueft nur dessen sanitisierte
    Run-Evidence und entfernt ausschliesslich den eigenen Run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
    [switch]$RuntimeMutexAlreadyHeld,
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-server-lab-collation-$Provider-$([guid]::NewGuid().ToString('N'))"
$stateRoot = Join-Path $testRoot 'state'
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$lab = $null
$completed = $false
$mutex = $null
$acquired = $false

function Assert-CollationAcceptance {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Description)
    if (-not $Condition) { throw "CONTAINER_COLLATION_ACCEPTANCE_FAILED: $Description" }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function New-CollationAcceptanceSecureString {
    param([Parameter(Mandatory)][string]$Value)
    $secret = [Security.SecureString]::new()
    foreach ($character in $Value.ToCharArray()) { $secret.AppendChar($character) }
    $secret.MakeReadOnly()
    return $secret
}

try {
    if (-not $RuntimeMutexAlreadyHeld) {
        $mutexName = if ($IsWindows) { 'Global\SQL_Server_Lab_Runtime_Smoke' } else { 'SQL_Server_Lab_Runtime_Smoke' }
        $mutex = [Threading.Mutex]::new($false, $mutexName)
        $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(10))
        if (-not $acquired) { throw 'CONTAINER_COLLATION_RUNTIME_LOCK_TIMEOUT' }
    }

    $runtime = @(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    Assert-CollationAcceptance $runtime.Available "Runtime '$Provider' ist zentral aufloesbar"
    if ($Provider -eq 'podman') { & (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1') | Out-Null }
    & ([string]$runtime.Invocation) info 1>$null 2>$null
    Assert-CollationAcceptance ($LASTEXITCODE -eq 0) "Runtime '$Provider' ist erreichbar"

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:SQL_SERVER_LAB_STATE = $stateRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force | Out-Null
    $password = New-CollationAcceptanceSecureString "CollationAcceptance_$([guid]::NewGuid().ToString('N'))!Aa7"
    $lab = New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2048 `
        -Collation Latin1_General_100_CS_AS -LabName "collation-$Provider-$([guid]::NewGuid().ToString('N').Substring(0, 8))" `
        -SaPassword $password -StateRoot $stateRoot -SkipAssessment
    $evidence = $lab.Instances[0].Collation
    Assert-CollationAcceptance ($lab.State -eq 'Running') 'Isoliertes Lab erreicht den Running-Zustand'
    Assert-CollationAcceptance (
        $evidence.Status -eq 'VERIFIED' -and $evidence.Provider -eq $Provider -and
        $evidence.SqlVersion -eq '2025' -and $evidence.CatalogAvailable -and
        $evidence.ExpectedCollation -eq 'Latin1_General_100_CS_AS' -and
        $evidence.ActualCollation -eq 'Latin1_General_100_CS_AS'
    ) 'Katalogverfuegbarkeit und SERVERPROPERTY-Collation stimmen ueberein'
    $evidenceJson = $evidence | ConvertTo-Json -Depth 5 -Compress
    Assert-CollationAcceptance ($evidenceJson -notmatch '(?i)password|secret|connection|string|hostname|port|container') 'Run-Evidence bleibt geheimnis- und hostwertfrei'
    $connectionInfoPath = Join-Path (Join-Path (Join-Path $stateRoot 'runs') $lab.RunId) 'connection-info.json'
    $persistedEvidence = (Get-Content -LiteralPath $connectionInfoPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20).instances[0].collation
    Assert-CollationAcceptance (
        $persistedEvidence.Status -eq 'VERIFIED' -and
        $persistedEvidence.ExpectedCollation -eq 'Latin1_General_100_CS_AS' -and
        $persistedEvidence.ActualCollation -eq 'Latin1_General_100_CS_AS'
    ) 'Sanitisierte Collation-Evidence ist rungebunden persistiert'
    Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false | Out-Null
    $lab = $null
    $completed = $true
    Write-Host 'CONTAINER_COLLATION_ACCEPTANCE: PASS' -ForegroundColor Green
}
finally {
    if ($lab -and -not $KeepOnFailure) {
        try { Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false | Out-Null }
        catch { Write-Warning 'CONTAINER_COLLATION_ACCEPTANCE_CLEANUP_FAILED' }
    }
    if (($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:SQL_SERVER_LAB_STATE = $previousStateRoot
    if ($acquired) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
}
