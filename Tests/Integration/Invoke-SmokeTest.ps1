#Requires -Version 7.2
<#
.SYNOPSIS
    Smoke-Test fuer SQL_Server_Lab End-to-End Lifecycle.
.DESCRIPTION
    Automatisierter Test: Import -> New-SqlServerLab -> New-LabDatabase ->
    Invoke-LabScript -> Remove-SqlServerLab. Erfordert Docker.
.PARAMETER SaPassword
    SA-Passwort als SecureString. Wird interaktiv abgefragt falls nicht angegeben.
.PARAMETER Version
    SQL-Server-Version (Default: 2025).
.PARAMETER KeepOnFailure
    Container bei Fehler NICHT entfernen (fuer Debugging).
.EXAMPLE
    .\Invoke-SmokeTest.ps1
.EXAMPLE
    $pw = ConvertTo-SecureString 'Test1234!' -AsPlainText -Force
    .\Invoke-SmokeTest.ps1 -SaPassword $pw -Version '2022'
#>
[CmdletBinding()]
param(
    [SecureString]$SaPassword,
    [string]$Version = '2025',
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$script:TestResults = @()
$script:Lab = $null
$script:StartTime = Get-Date

# =============================================================================
# Test-Infrastruktur
# =============================================================================

function Write-TestHeader { param([string]$Name)
    Write-Host "`n  [$Name]" -ForegroundColor Cyan
}

function Assert-True {
    param([string]$TestName, [bool]$Condition, [string]$Message = '')
    if ($Condition) {
        Write-Host "    PASS: $TestName" -ForegroundColor Green
        $script:TestResults += @{ Name = $TestName; Pass = $true; Message = '' }
    }
    else {
        Write-Host "    FAIL: $TestName - $Message" -ForegroundColor Red
        $script:TestResults += @{ Name = $TestName; Pass = $false; Message = $Message }
    }
    return $Condition
}

function Assert-NoThrow {
    param([string]$TestName, [scriptblock]$Block)
    try {
        $result = & $Block
        Write-Host "    PASS: $TestName" -ForegroundColor Green
        $script:TestResults += @{ Name = $TestName; Pass = $true; Message = '' }
        return $result
    }
    catch {
        Write-Host "    FAIL: $TestName - $_" -ForegroundColor Red
        $script:TestResults += @{ Name = $TestName; Pass = $false; Message = $_.ToString() }
        return $null
    }
}

# =============================================================================
# Setup
# =============================================================================

Write-Host "`n====================================================================" -ForegroundColor White
Write-Host "  SQL_Server_Lab Smoke Test" -ForegroundColor White
Write-Host "====================================================================" -ForegroundColor White
Write-Host "  Version: $Version | Datum: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# Modul laden
$modulePath = Join-Path $PSScriptRoot '..\..\SqlServerLab.psd1' | Resolve-Path
Import-Module $modulePath -Force

# Passwort
if (-not $SaPassword) {
    $SaPassword = ConvertTo-SecureString 'SmokeTest_Pwd1!' -AsPlainText -Force
    Write-Host "  SA-Passwort: (Default fuer Test)" -ForegroundColor DarkGray
}

# =============================================================================
# Test 1: Modul-Import
# =============================================================================

Write-TestHeader 'T1: Modul-Import'

Assert-True 'Modul geladen' `
    ($null -ne (Get-Module SqlServerLab)) `
    'Get-Module SqlServerLab liefert $null'

Assert-True 'New-SqlServerLab verfuegbar' `
    ($null -ne (Get-Command New-SqlServerLab -ErrorAction SilentlyContinue)) `
    'Cmdlet nicht gefunden'

Assert-True 'Test-DockerAvailable intern verfuegbar' `
    ($null -ne (Get-Module SqlServerLab | ForEach-Object { & $_.NewBoundScriptBlock({ Get-Command Test-DockerAvailable -ErrorAction SilentlyContinue }) })) `
    'Provider-Funktion nicht im Modul-Scope'

# =============================================================================
# Test 2: Resource Assessment
# =============================================================================

Write-TestHeader 'T2: Resource Assessment'

$assessment = Assert-NoThrow 'Test-LabResources laeuft' {
    Test-LabResources -Provider docker
}

if ($assessment) {
    Assert-True 'Docker verfuegbar' `
        ($assessment.Status -ne 'RESOURCE_HARD_BLOCK') `
        "Status: $($assessment.Status)"
}

# =============================================================================
# Test 3: New-SqlServerLab
# =============================================================================

Write-TestHeader 'T3: New-SqlServerLab'

$script:Lab = Assert-NoThrow 'Lab erstellen' {
    New-SqlServerLab -Version $Version -Provider docker -SaPassword $SaPassword -SkipAssessment
}

if ($script:Lab) {
    Assert-True 'Lab State = Running' `
        ($script:Lab.State -eq 'Running') `
        "State: $($script:Lab.State)"

    Assert-True 'RunId ist GUID' `
        ($script:Lab.RunId -match '^[0-9a-f]{8}-') `
        "RunId: $($script:Lab.RunId)"

    Assert-True 'Port im Lab-Bereich' `
        ($script:Lab.Instances[0].Port -ge 14330 -and $script:Lab.Instances[0].Port -le 14399) `
        "Port: $($script:Lab.Instances[0].Port)"

    Assert-True 'Container in Docker sichtbar' `
        ($null -ne (docker ps -q --filter "name=$($script:Lab.Instances[0].ContainerName)")) `
        'Container nicht in docker ps'
}
else {
    Write-Host "    SKIP: Lab nicht erstellt, ueberspringe weitere Tests" -ForegroundColor Yellow
    # Tests abgebrochen - Cleanup am Ende
}

# =============================================================================
# Test 4: New-LabDatabase
# =============================================================================

Write-TestHeader 'T4: New-LabDatabase'

$dbResult = Assert-NoThrow 'Datenbank mit 2 Data Files erstellen' {
    New-LabDatabase -Port $script:Lab.Instances[0].Port -SaPassword $SaPassword `
        -DatabaseName 'SmokeTestDB' `
        -DataFiles @(
            @{ name = 'Smoke_Data1'; sizeMB = 16 },
            @{ name = 'Smoke_Data2'; sizeMB = 16 }
        ) `
        -LogFiles @(
            @{ name = 'Smoke_Log'; sizeMB = 8 }
        )
}

if ($dbResult) {
    Assert-True 'DB-Ergebnis Success' `
        ($dbResult.Success -eq $true) `
        "Success: $($dbResult.Success)"

    # Datenbank via Query verifizieren
    $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword))
    $verifyOutput = sqlcmd -S "127.0.0.1,$($script:Lab.Instances[0].Port)" -U sa -P $saPlain `
        -Q "SELECT name FROM sys.databases WHERE name = 'SmokeTestDB'" -h -1 -W 2>&1
    $saPlain = $null

    Assert-True 'DB in sys.databases vorhanden' `
        ($verifyOutput -match 'SmokeTestDB') `
        "Output: $verifyOutput"
}

# =============================================================================
# Test 5: Invoke-LabScript
# =============================================================================

Write-TestHeader 'T5: Invoke-LabScript'

# Test-SQL erzeugen
$testSqlPath = Join-Path $PSScriptRoot 'smoke-test-query.sql'
@"
USE SmokeTestDB;
GO
CREATE TABLE dbo.SmokeTest (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Name NVARCHAR(100) NOT NULL,
    Created DATETIME2 DEFAULT GETDATE()
);
GO
INSERT INTO dbo.SmokeTest (Name) VALUES ('Erster Eintrag'), ('Zweiter Eintrag');
GO
"@ | Set-Content $testSqlPath -Encoding utf8

$scriptResult = Assert-NoThrow 'SQL-Skript ausfuehren' {
    Invoke-LabScript -ScriptPath $testSqlPath -Port $script:Lab.Instances[0].Port -SaPassword $SaPassword
}

if ($scriptResult) {
    Assert-True 'Skript-Ergebnis Success' `
        ($scriptResult.Success -eq $true) `
        "Message: $($scriptResult.Message)"

    Assert-True 'Mehrere Batches verarbeitet' `
        ($scriptResult.Batches -ge 2) `
        "Batches: $($scriptResult.Batches)"
}

# Tabelle verifizieren
$saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword))
$tableCheck = sqlcmd -S "127.0.0.1,$($script:Lab.Instances[0].Port)" -U sa -P $saPlain `
    -Q "SELECT COUNT(*) AS Cnt FROM SmokeTestDB.dbo.SmokeTest" -h -1 -W 2>&1
$saPlain = $null

$tableCheckStr = ($tableCheck | Where-Object { $_.Trim() }) -join ' // '
$rowCount = ($tableCheck | ForEach-Object { $_.Trim() } | Where-Object { $_ -and [int]::TryParse($_, [ref]$null) } | Select-Object -First 1)
Assert-True 'Tabelle hat 2 Rows' `
    ($rowCount.Trim() -eq '2') `
    "Output: $tableCheckStr"

# Temp-Datei aufraumen
if (Test-Path $testSqlPath) { Remove-Item $testSqlPath }

# =============================================================================
# Test 6: Remove-SqlServerLab
# =============================================================================

Write-TestHeader 'T6: Remove-SqlServerLab'

$removeResult = Assert-NoThrow 'Lab entfernen' {
    Remove-SqlServerLab -RunId $script:Lab.RunId -Force
}

if ($removeResult) {
    Assert-True 'Status = REMOVED' `
        ($removeResult.Status -eq 'REMOVED') `
        "Status: $($removeResult.Status)"
}

# Container weg?
Start-Sleep -Seconds 1
$containerCheck = docker ps -a -q --filter "name=$($script:Lab.Instances[0].ContainerName)" 2>$null
Assert-True 'Container nicht mehr vorhanden' `
    ([string]::IsNullOrWhiteSpace($containerCheck)) `
    "Container noch da: $containerCheck"

$script:Lab = $null  # Cleanup nicht nochmal ausfuehren

# =============================================================================
# Ergebnis
# =============================================================================

$elapsed = (Get-Date) - $script:StartTime
$passed = ($script:TestResults | Where-Object { $_.Pass }).Count
$failed = ($script:TestResults | Where-Object { -not $_.Pass }).Count
$total = $script:TestResults.Count

Write-Host "`n====================================================================" -ForegroundColor White
Write-Host "  ERGEBNIS: $passed/$total PASS, $failed FAIL ($($elapsed.TotalSeconds.ToString('F1'))s)" `
    -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host "====================================================================" -ForegroundColor White

if ($failed -gt 0) {
    Write-Host "`n  Fehlgeschlagene Tests:" -ForegroundColor Red
    $script:TestResults | Where-Object { -not $_.Pass } | ForEach-Object {
        Write-Host "    - $($_.Name): $($_.Message)" -ForegroundColor Red
    }
}

# =============================================================================
# Cleanup bei Fehler
# =============================================================================

if ($script:Lab -and -not $KeepOnFailure) {
    Write-Host "`n  Cleanup: Entferne uebrig gebliebenes Lab..." -ForegroundColor Yellow
    try {
        Remove-SqlServerLab -RunId $script:Lab.RunId -Force
    }
    catch {
        Write-Host "  Cleanup fehlgeschlagen: $_" -ForegroundColor Red
        Write-Host "  Manuell: docker rm -f $($script:Lab.Instances[0].ContainerName)" -ForegroundColor Yellow
    }
}

# Exit-Code
if ($failed -gt 0) { exit 1 }
exit 0
