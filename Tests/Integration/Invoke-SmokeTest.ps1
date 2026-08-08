#Requires -Version 7.2
<#
.SYNOPSIS
    End-to-End-Smoke-Test fuer einen implementierten SQL_Server_Lab-Provider.
.DESCRIPTION
    Testet Modulimport, Provider-Metadaten, Resource Assessment, Provisionierung,
    Datenbankerstellung, Skriptausfuehrung, Status, Stop, Start und Remove.
    Der mutierende Lifecycle verwendet genau den mit -Provider ausgewaehlten Provider.
.PARAMETER SaPassword
    Optionales synthetisches SA-Testpasswort als SecureString.
.PARAMETER Version
    SQL-Server-Version oder katalogisierter CU-Bezeichner. Default: 2025.
.PARAMETER Provider
    docker, podman oder auto. Auto waehlt Docker vor Podman.
.PARAMETER KeepOnFailure
    Lab bei einem Fehler zur lokalen Diagnose nicht automatisch entfernen.
.EXAMPLE
    .\Invoke-SmokeTest.ps1 -Provider docker
.EXAMPLE
    .\Invoke-SmokeTest.ps1 -Provider podman -Version '2022'
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs,
    [SecureString]$SaPassword,
    [string]$Version = '2025',
    [ValidateSet('docker', 'podman', 'auto')]
    [string]$Provider = 'auto',
    [switch]$KeepOnFailure
)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'
if ($showHelpRequested) {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}


$ErrorActionPreference = 'Stop'
$script:TestResults = [System.Collections.Generic.List[object]]::new()
$script:Lab = $null
$script:StartTime = Get-Date
$script:ContainerRuntime = $null
$script:TemporarySqlPath = $null

function Write-TestHeader {
    param([Parameter(Mandatory)][string]$Name)
    Write-Host "`n  [$Name]" -ForegroundColor Cyan
}

function Add-TestResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [string]$Message = ''
    )

    $script:TestResults.Add([PSCustomObject]@{
        Name    = $Name
        Pass    = $Passed
        Message = $Message
    })

    if ($Passed) {
        Write-Host "    PASS: $Name" -ForegroundColor Green
    }
    else {
        Write-Host "    FAIL: $Name - $Message" -ForegroundColor Red
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Message = ''
    )

    Add-TestResult -Name $Name -Passed $Condition -Message $Message
}

function Invoke-TestStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    try {
        $result = & $Action
        Add-TestResult -Name $Name -Passed $true
        return $result
    }
    catch {
        Add-TestResult -Name $Name -Passed $false -Message $_.Exception.Message
        return $null
    }
}

function ConvertFrom-TestSecureString {
    param([Parameter(Mandatory)][SecureString]$SecureString)

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Test-RuntimeCommand {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        return $false
    }

    & $Name info 1>$null 2>$null
    return $LASTEXITCODE -eq 0
}

Write-Host "`n====================================================================" -ForegroundColor White
Write-Host '  SQL_Server_Lab Smoke Test' -ForegroundColor White
Write-Host '====================================================================' -ForegroundColor White
Write-Host "  Version: $Version | Datum: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$modulePath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\SqlServerLab.psd1')).Path
$providersRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\Providers')).Path

try {
    # =========================================================================
    # T1: Modul und implementierte Provider
    # =========================================================================
    Write-TestHeader 'T1: Modul und Provider'

    $module = Invoke-TestStep -Name 'Modul importieren' -Action {
        Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
        Import-Module $modulePath -Force -PassThru
    }

    if (-not $module) {
        throw 'Modulimport fehlgeschlagen; weitere Tests sind nicht sinnvoll.'
    }

    Assert-True `
        -Name 'New-SqlServerLab exportiert' `
        -Condition ($null -ne (Get-Command New-SqlServerLab -ErrorAction SilentlyContinue)) `
        -Message 'Cmdlet nicht gefunden'

    $implementedProviders = @()
    foreach ($providerDirectory in Get-ChildItem -LiteralPath $providersRoot -Directory) {
        $definitionPath = Join-Path $providerDirectory.FullName 'provider.json'
        if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
            continue
        }

        $definition = Get-Content -LiteralPath $definitionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        if (-not $definition.module) {
            continue
        }

        $implementationPath = Join-Path $providerDirectory.FullName $definition.module
        if (Test-Path -LiteralPath $implementationPath -PathType Leaf) {
            $implementedProviders += [string]$definition.name
        }
    }

    $implementedProviders = @($implementedProviders | Sort-Object -Unique)
    Write-Host "    Implementierte Provider: $($implementedProviders -join ', ')" -ForegroundColor DarkGray

    Assert-True `
        -Name 'Docker-Provider registriert' `
        -Condition ('docker' -in $implementedProviders) `
        -Message 'Providers/Docker/provider.json oder Implementierung fehlt'

    Assert-True `
        -Name 'Podman-Provider registriert' `
        -Condition ('podman' -in $implementedProviders) `
        -Message 'Providers/Podman/provider.json oder Implementierung fehlt'

    if ($Provider -eq 'auto') {
        if (Test-RuntimeCommand -Name 'docker') {
            $Provider = 'docker'
        }
        elseif (Test-RuntimeCommand -Name 'podman') {
            $Provider = 'podman'
        }
        else {
            throw 'Weder Docker noch Podman ist installiert und erreichbar.'
        }
    }

    if ($Provider -notin $implementedProviders) {
        throw "Provider '$Provider' besitzt keinen vollständigen Providervertrag."
    }

    if (-not (Test-RuntimeCommand -Name $Provider)) {
        throw "Runtime '$Provider' ist nicht erreichbar."
    }

    $script:ContainerRuntime = $Provider
    Write-Host "    Gewaehlter Provider: $Provider" -ForegroundColor DarkGray

    if (-not $SaPassword) {
        $SaPassword = ConvertTo-SecureString 'SmokeTest_Pwd1!' -AsPlainText -Force
        Write-Host '    SA-Passwort: synthetischer Testwert' -ForegroundColor DarkGray
    }

    # =========================================================================
    # T2: Resource Assessment
    # =========================================================================
    Write-TestHeader 'T2: Resource Assessment'

    foreach ($implementedProvider in $implementedProviders) {
        if (-not (Test-RuntimeCommand -Name $implementedProvider)) {
            Write-Host "    SKIP: $implementedProvider ist nicht erreichbar" -ForegroundColor Yellow
            continue
        }

        $assessment = Invoke-TestStep -Name "Test-SqlServerLabPrerequisite ($implementedProvider)" -Action {
            Test-SqlServerLabPrerequisite -Provider $implementedProvider
        }

        if ($assessment) {
            Assert-True `
                -Name "$implementedProvider nicht HARD_BLOCK" `
                -Condition ($assessment.Status -ne 'RESOURCE_HARD_BLOCK') `
                -Message "Status: $($assessment.Status)"
        }
    }

    $selectedAssessment = Test-SqlServerLabPrerequisite -Provider $Provider
    if ($selectedAssessment.Status -eq 'RESOURCE_HARD_BLOCK') {
        throw "Gewaehlter Provider '$Provider' ist im Resource Assessment blockiert."
    }

    # =========================================================================
    # T3: Provisionierung
    # =========================================================================
    Write-TestHeader 'T3: New-SqlServerLab'

    $script:Lab = Invoke-TestStep -Name 'Lab erstellen' -Action {
        New-SqlServerLab `
            -Version $Version `
            -Provider $Provider `
            -SaPassword $SaPassword `
            -SkipAssessment
    }

    if (-not $script:Lab) {
        throw 'Lab konnte nicht erstellt werden; weitere Runtime-Tests werden abgebrochen.'
    }

    Assert-True `
        -Name 'Lab State = Running' `
        -Condition ($script:Lab.State -eq 'Running') `
        -Message "State: $($script:Lab.State)"

    Assert-True `
        -Name 'RunId ist GUID' `
        -Condition ($script:Lab.RunId -match '^[0-9a-fA-F]{8}-') `
        -Message "RunId: $($script:Lab.RunId)"

    Assert-True `
        -Name 'Provider im Ergebnis stimmt' `
        -Condition ($script:Lab.Instances[0].Provider -eq $Provider) `
        -Message "Ergebnis: $($script:Lab.Instances[0].Provider)"

    Assert-True `
        -Name 'Port im Lab-Bereich' `
        -Condition ($script:Lab.Instances[0].Port -ge 14330 -and $script:Lab.Instances[0].Port -le 14399) `
        -Message "Port: $($script:Lab.Instances[0].Port)"

    $visibleContainer = & $script:ContainerRuntime ps -q --filter "name=$($script:Lab.Instances[0].ContainerName)" 2>$null
    Assert-True `
        -Name "Container in $Provider sichtbar" `
        -Condition (-not [string]::IsNullOrWhiteSpace(($visibleContainer | Out-String))) `
        -Message "Container nicht in '$Provider ps' gefunden"

    # =========================================================================
    # T4: Datenbankerstellung
    # =========================================================================
    Write-TestHeader 'T4: New-SqlServerLabDatabase'

    $databaseResult = Invoke-TestStep -Name 'Datenbank mit zwei Data-Files erstellen' -Action {
        New-SqlServerLabDatabase `
            -Port $script:Lab.Instances[0].Port `
            -SaPassword $SaPassword `
            -DatabaseName 'SmokeTestDB' `
            -DataFiles @(
                @{ name = 'Smoke_Data1'; sizeMB = 16; filegrowthMB = 16 },
                @{ name = 'Smoke_Data2'; sizeMB = 16; filegrowthMB = 16 }
            ) `
            -LogFiles @(
                @{ name = 'Smoke_Log'; sizeMB = 8; filegrowthMB = 8 }
            )
    }

    if ($databaseResult) {
        Assert-True `
            -Name 'DB-Ergebnis Success' `
            -Condition ($databaseResult.Success -eq $true) `
            -Message "Success: $($databaseResult.Success)"
    }

    $saPlain = ConvertFrom-TestSecureString -SecureString $SaPassword
    try {
        $databaseCheck = sqlcmd `
            -S "127.0.0.1,$($script:Lab.Instances[0].Port)" `
            -U sa `
            -P $saPlain `
            -C `
            -Q "SELECT name FROM sys.databases WHERE name = 'SmokeTestDB'" `
            -h -1 -W 2>&1
    }
    finally {
        $saPlain = $null
    }

    Assert-True `
        -Name 'Datenbank in sys.databases vorhanden' `
        -Condition ([bool](($databaseCheck | Out-String) -match 'SmokeTestDB')) `
        -Message "Output: $(($databaseCheck | Out-String).Trim())"

    # =========================================================================
    # T5: Skriptausfuehrung
    # =========================================================================
    Write-TestHeader 'T5: Invoke-SqlServerLabScript'

    $script:TemporarySqlPath = Join-Path $PSScriptRoot 'smoke-test-query.generated.sql'
    @"
CREATE TABLE dbo.SmokeTest (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Name NVARCHAR(100) NOT NULL,
    Created DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO
INSERT INTO dbo.SmokeTest (Name) VALUES (N'Erster Eintrag'), (N'Zweiter Eintrag');
GO
"@ | Set-Content -LiteralPath $script:TemporarySqlPath -Encoding utf8

    $scriptResult = Invoke-TestStep -Name 'SQL-Skript ausfuehren' -Action {
        Invoke-SqlServerLabScript `
            -ScriptPath $script:TemporarySqlPath `
            -Port $script:Lab.Instances[0].Port `
            -SaPassword $SaPassword `
            -Database 'SmokeTestDB'
    }

    if ($scriptResult) {
        Assert-True `
            -Name 'Skript-Ergebnis Success' `
            -Condition ($scriptResult.Success -eq $true) `
            -Message "Message: $($scriptResult.Message)"

        Assert-True `
            -Name 'Mehrere Batches verarbeitet' `
            -Condition ($scriptResult.Batches -ge 2) `
            -Message "Batches: $($scriptResult.Batches)"
    }

    $saPlain = ConvertFrom-TestSecureString -SecureString $SaPassword
    try {
        $tableCheck = sqlcmd `
            -S "127.0.0.1,$($script:Lab.Instances[0].Port)" `
            -U sa `
            -P $saPlain `
            -C `
            -Q 'SET NOCOUNT ON; SELECT COUNT(*) FROM SmokeTestDB.dbo.SmokeTest;' `
            -h -1 -W 2>&1
    }
    finally {
        $saPlain = $null
    }

    $tableCheckText = ($tableCheck | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join ' '
    Assert-True `
        -Name 'Tabelle hat zwei Rows' `
        -Condition ($tableCheckText -match '(^|\s)2(\s|$)') `
        -Message "Output: $tableCheckText"

    # =========================================================================
    # T6: Status
    # =========================================================================
    Write-TestHeader 'T6: Get-SqlServerLab'

    $statusResult = Invoke-TestStep -Name 'Lab-Status abfragen' -Action {
        Get-SqlServerLab -RunId $script:Lab.RunId
    }

    if ($statusResult) {
        Assert-True `
            -Name 'State = RUNNING' `
            -Condition ($statusResult.State -eq 'RUNNING') `
            -Message "State: $($statusResult.State)"

        Assert-True `
            -Name 'Instanz ContainerUp' `
            -Condition ($statusResult.Instances[0].ContainerUp -eq $true) `
            -Message "ContainerUp: $($statusResult.Instances[0].ContainerUp)"
    }

    # =========================================================================
    # T7: Stop
    # =========================================================================
    Write-TestHeader 'T7: Stop-SqlServerLab'

    $stopResult = Invoke-TestStep -Name 'Lab stoppen' -Action {
        Stop-SqlServerLab -RunId $script:Lab.RunId -Force
    }

    if ($stopResult) {
        Assert-True `
            -Name 'Stop-Status = STOPPED' `
            -Condition ($stopResult.Status -eq 'STOPPED') `
            -Message "Status: $($stopResult.Status)"

        Start-Sleep -Seconds 1
        $containerState = & $script:ContainerRuntime inspect `
            $script:Lab.Instances[0].ContainerName `
            --format '{{.State.Status}}' 2>$null

        Assert-True `
            -Name "Container in $Provider gestoppt" `
            -Condition (($containerState | Out-String) -match 'exited|stopped') `
            -Message "Container-State: $(($containerState | Out-String).Trim())"
    }

    # =========================================================================
    # T8: Start
    # =========================================================================
    Write-TestHeader 'T8: Start-SqlServerLab'

    $startResult = Invoke-TestStep -Name 'Lab starten' -Action {
        Start-SqlServerLab -RunId $script:Lab.RunId -TimeoutSeconds 60
    }

    if ($startResult) {
        Assert-True `
            -Name 'Start-Status = RUNNING' `
            -Condition ($startResult.Status -eq 'RUNNING') `
            -Message "Status: $($startResult.Status)"

        Start-Sleep -Seconds 1
        $containerState = & $script:ContainerRuntime inspect `
            $script:Lab.Instances[0].ContainerName `
            --format '{{.State.Status}}' 2>$null

        Assert-True `
            -Name "Container in $Provider wieder running" `
            -Condition (($containerState | Out-String) -match 'running') `
            -Message "Container-State: $(($containerState | Out-String).Trim())"
    }

    # =========================================================================
    # T9: Remove
    # =========================================================================
    Write-TestHeader 'T9: Remove-SqlServerLab'

    $removeResult = Invoke-TestStep -Name 'Lab entfernen' -Action {
        Remove-SqlServerLab -RunId $script:Lab.RunId -Force
    }

    if ($removeResult) {
        Assert-True `
            -Name 'Status = REMOVED' `
            -Condition ($removeResult.Status -eq 'REMOVED') `
            -Message "Status: $($removeResult.Status)"
    }

    Start-Sleep -Seconds 1
    $containerCheck = & $script:ContainerRuntime ps -a -q `
        --filter "name=$($script:Lab.Instances[0].ContainerName)" 2>$null

    Assert-True `
        -Name 'Container nicht mehr vorhanden' `
        -Condition ([string]::IsNullOrWhiteSpace(($containerCheck | Out-String))) `
        -Message "Container noch vorhanden: $(($containerCheck | Out-String).Trim())"

    $script:Lab = $null
}
catch {
    Add-TestResult -Name 'Smoke-Test Ablauf' -Passed $false -Message $_.Exception.Message
}
finally {
    if ($script:TemporarySqlPath -and (Test-Path -LiteralPath $script:TemporarySqlPath)) {
        Remove-Item -LiteralPath $script:TemporarySqlPath -Force -ErrorAction SilentlyContinue
    }

    if ($script:Lab -and -not $KeepOnFailure) {
        Write-Host "`n  Cleanup: Entferne uebrig gebliebenes Lab..." -ForegroundColor Yellow
        try {
            Remove-SqlServerLab -RunId $script:Lab.RunId -Force | Out-Null
        }
        catch {
            Add-TestResult -Name 'Cleanup nach Fehler' -Passed $false -Message $_.Exception.Message
        }
    }
}

$elapsed = (Get-Date) - $script:StartTime
$passed = @($script:TestResults | Where-Object { $_.Pass }).Count
$failed = @($script:TestResults | Where-Object { -not $_.Pass }).Count
$total = $script:TestResults.Count

Write-Host "`n====================================================================" -ForegroundColor White
Write-Host "  ERGEBNIS: $passed/$total PASS, $failed FAIL ($($elapsed.TotalSeconds.ToString('F1'))s)" `
    -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host '====================================================================' -ForegroundColor White

if ($failed -gt 0) {
    Write-Host "`n  Fehlgeschlagene Tests:" -ForegroundColor Red
    foreach ($failedResult in $script:TestResults | Where-Object { -not $_.Pass }) {
        Write-Host "    - $($failedResult.Name): $($failedResult.Message)" -ForegroundColor Red
    }
    exit 1
}

exit 0


