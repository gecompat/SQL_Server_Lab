#Requires -Version 7.2
<#
.SYNOPSIS
    End-to-End-Smoke des Project-Adapter-Pfads gegen eine echte SQL-Instanz.
.DESCRIPTION
    Provisioniert ein Lab (New-SqlServerLab), fuehrt den synthetischen
    Beispieladapter vollstaendig aus (preflight/install/validate/cleanup) und
    prueft die Kernregressionen des sqlcmd-Single-Connection-Modus: USE
    ueberlebt GO (Marker landet in SyntheticDemo, nicht in master), der
    RAISERROR-Guard bricht das restliche Skript ab, und der
    targetDatabase-Fallback erlaubt einem install-Skript, die eigene
    Zieldatenbank zu erzeugen. Raeumt Lab und Kopien am Ende wieder ab.
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs,
    [string]$Version = '2025',
    [string]$Provider = 'docker'
)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'
if ($showHelpRequested) {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}


$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

function Invoke-SmokeQuery {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Query
    )

    $output = sqlcmd -S "127.0.0.1,$Port" -U sa -P $script:plainPassword -C -b -h -1 -W -Q $Query 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Abfrage fehlgeschlagen: $(($output | ForEach-Object { [string]$_ }) -join ' ')"
    }
    return @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

Write-Host ''
Write-Host "SQL_Server_Lab - Project Adapter Smoke ($Provider, SQL Server $Version)" -ForegroundColor Cyan

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force

$script:plainPassword = 'AdapterSmoke_Pwd1!'
$saPassword = ConvertTo-SecureString $script:plainPassword -AsPlainText -Force
$exampleAdapterPath = Join-Path $repoRoot 'Adapters/Examples/synthetic-demo'
$variantRoot = Join-Path ([System.IO.Path]::GetTempPath()) "adapter-smoke-variant-$([guid]::NewGuid().ToString('N'))"
$lab = $null

try {
    Write-Host '  Lab wird provisioniert...' -ForegroundColor DarkGray
    $lab = New-SqlServerLab -Version $Version -Provider $Provider -SaPassword $saPassword -SkipAssessment
    if (-not $lab -or $lab.State -ne 'Running') {
        throw "Lab konnte nicht provisioniert werden (State: $($lab.State))."
    }
    $port = [int]$lab.Instances[0].Port
    Write-Host "  Lab laeuft: Run $($lab.RunId), Port $port" -ForegroundColor DarkGray

    $ready = Test-SqlServerLabAdapter -Path $exampleAdapterPath -RunId $lab.RunId
    Add-CheckResult `
        -Name 'Adapter ist gegen den Run ADAPTER_READY' `
        -Success ($ready.IsReady -and $ready.Status -eq 'ADAPTER_READY') `
        -Message ("Status: {0}; Errors: {1}" -f $ready.Status, ($ready.Errors -join '; '))

    $install = Install-SqlServerLabAdapter -Path $exampleAdapterPath -RunId $lab.RunId -SaPassword $saPassword
    Add-CheckResult `
        -Name 'Install liefert ADAPTER_APPLIED' `
        -Success ($install.Status -eq 'ADAPTER_APPLIED' -and $install.Success) `
        -Message ("Status: {0}; {1}" -f $install.Status, $install.Message)

    # Kernregression Single-Connection: USE ueberlebt GO, der Marker liegt in
    # SyntheticDemo und master bleibt sauber.
    $markerCount = Invoke-SmokeQuery -Port $port -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(10), COUNT(*)) FROM SyntheticDemo.dbo.AdapterMarker WHERE ProjectId = N'synthetic-demo';"
    Add-CheckResult `
        -Name 'Ownership-Marker liegt in SyntheticDemo' `
        -Success ($markerCount -contains '1') `
        -Message ("Ausgabe: {0}" -f ($markerCount -join ' '))

    $masterState = Invoke-SmokeQuery -Port $port -Query "SET NOCOUNT ON; SELECT CASE WHEN OBJECT_ID('master.dbo.AdapterMarker') IS NULL THEN 'CLEAN' ELSE 'POLLUTED' END;"
    Add-CheckResult `
        -Name 'master enthaelt keine AdapterMarker-Tabelle' `
        -Success ($masterState -contains 'CLEAN') `
        -Message ("Ausgabe: {0}" -f ($masterState -join ' '))

    # RAISERROR-Guard: zweiter Install muss abbrechen, ohne weitere Batches
    # auszufuehren (-b im Single-Connection-Modus).
    $secondInstall = Install-SqlServerLabAdapter -Path $exampleAdapterPath -RunId $lab.RunId -SaPassword $saPassword
    Add-CheckResult `
        -Name 'Zweiter Install endet mit PROJECT_CONTENT_FAILED' `
        -Success ($secondInstall.Status -eq 'PROJECT_CONTENT_FAILED' -and -not $secondInstall.Success) `
        -Message ("Status: {0}" -f $secondInstall.Status)

    $validate = Install-SqlServerLabAdapter -Path $exampleAdapterPath -RunId $lab.RunId -SaPassword $saPassword -Entrypoint validate
    Add-CheckResult `
        -Name 'Validate liefert ADAPTER_APPLIED' `
        -Success ($validate.Status -eq 'ADAPTER_APPLIED') `
        -Message ("Status: {0}; {1}" -f $validate.Status, $validate.Message)

    $cleanup = Install-SqlServerLabAdapter -Path $exampleAdapterPath -RunId $lab.RunId -SaPassword $saPassword -Entrypoint cleanup
    $databaseState = Invoke-SmokeQuery -Port $port -Query "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'SyntheticDemo') IS NULL THEN 'ABSENT' ELSE 'PRESENT' END;"
    Add-CheckResult `
        -Name 'Cleanup entfernt SyntheticDemo' `
        -Success ($cleanup.Status -eq 'ADAPTER_APPLIED' -and $databaseState -contains 'ABSENT') `
        -Message ("Status: {0}; DB: {1}" -f $cleanup.Status, ($databaseState -join ' '))

    # targetDatabase-Fallback: deklariert der Adapter eine noch nicht
    # existierende targetDatabase, laeuft install im master-Kontext und darf
    # sie selbst erzeugen.
    Copy-Item -LiteralPath $exampleAdapterPath -Destination $variantRoot -Recurse
    $variantJsonPath = Join-Path $variantRoot 'adapter.json'
    $variantJson = Get-Content -LiteralPath $variantJsonPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $variantJson.targetDatabase = 'SyntheticDemo'
    $variantJson | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $variantJsonPath -Encoding utf8

    $fallbackInstall = Install-SqlServerLabAdapter -Path $variantRoot -RunId $lab.RunId -SaPassword $saPassword
    Add-CheckResult `
        -Name 'Install mit nicht existierender targetDatabase nutzt den master-Fallback' `
        -Success ($fallbackInstall.Status -eq 'ADAPTER_APPLIED') `
        -Message ("Status: {0}; {1}" -f $fallbackInstall.Status, $fallbackInstall.Message)

    $fallbackValidate = Install-SqlServerLabAdapter -Path $variantRoot -RunId $lab.RunId -SaPassword $saPassword -Entrypoint validate
    Add-CheckResult `
        -Name 'Validate laeuft im existierenden targetDatabase-Kontext' `
        -Success ($fallbackValidate.Status -eq 'ADAPTER_APPLIED') `
        -Message ("Status: {0}; {1}" -f $fallbackValidate.Status, $fallbackValidate.Message)

    # Cleanup ueber den Original-Adapter (targetDatabase master): eine Session
    # kann die Datenbank, in der sie selbst steht, nicht droppen.
    $fallbackCleanup = Install-SqlServerLabAdapter -Path $exampleAdapterPath -RunId $lab.RunId -SaPassword $saPassword -Entrypoint cleanup
    $finalState = Invoke-SmokeQuery -Port $port -Query "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'SyntheticDemo') IS NULL THEN 'ABSENT' ELSE 'PRESENT' END;"
    Add-CheckResult `
        -Name 'Abschliessendes Cleanup entfernt SyntheticDemo erneut' `
        -Success ($fallbackCleanup.Status -eq 'ADAPTER_APPLIED' -and $finalState -contains 'ABSENT') `
        -Message ("Status: {0}; DB: {1}" -f $fallbackCleanup.Status, ($finalState -join ' '))
}
catch {
    Add-CheckResult -Name 'Adapter-Smoke-Ausfuehrung' -Success $false -Message $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $variantRoot) {
        Remove-Item -LiteralPath $variantRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lab) {
        Write-Host '  Lab wird entfernt...' -ForegroundColor DarkGray
        try {
            Remove-SqlServerLab -RunId $lab.RunId -Force | Out-Null
        }
        catch {
            # Ein Cleanup-Fehler darf die Ergebnis-/Exit-Auswertung unterhalb des
            # finally nicht ueberspringen und keine echte Testabweichung maskieren.
            Write-Host "  WARN  Lab-Cleanup fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

exit 0


