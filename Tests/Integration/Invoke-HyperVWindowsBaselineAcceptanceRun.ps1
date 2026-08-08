#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt eine reale Cold-Path-Abnahme fuer eine Windows-OS-Baseline aus.
.DESCRIPTION
    Erstellt aus einem veroeffentlichten OS_SEALED-Artifact eine neue
    differenzierende Hyper-V-VM, schliesst die Windows-OOBE unbeaufsichtigt ab
    und prueft den Gast ueber PowerShell Direct. Anschliessend werden Stop und
    Start ueber den gemeinsamen Reconcile-Vertrag ausgefuehrt, der Gast nach
    dem Cold Start erneut erreicht und der Run scopegebunden entfernt.

    Der Test veraendert niemals die immutable Parent-VHDX. Bei einem Fehler
    wird der Run standardmaessig ebenfalls entfernt. -KeepOnFailure behaelt nur
    fehlgeschlagene Testressourcen fuer eine bewusste lokale Diagnose.
.PARAMETER ArtifactId
    Artifact-ID einer veroeffentlichten OS_SEALED-Windows-Baseline.
.PARAMETER AdministratorPassword
    Kennwort fuer das lokale Administratorkonto des neuen Windows-Klons.
.PARAMETER KeepOnFailure
    Behaelt VM, Child-VHDX, State und DPAPI-Secret ausschliesslich bei Fehlern.
.EXAMPLE
    $password = Read-Host 'Gast-Administratorpasswort' -AsSecureString
    .\Tests\Integration\Invoke-HyperVWindowsBaselineAcceptanceRun.ps1 `
        -ArtifactId 'hyperv-os-sealed-<sha256>' `
        -AdministratorPassword $password
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs,
    [ValidatePattern('^hyperv-os-sealed-[a-f0-9]{64}$')]
    [string]$ArtifactId,
    [SecureString]$AdministratorPassword,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')]
    [string]$LabName = 'Windows Baseline Acceptance',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')]
    [string]$InstanceId = 'windows',
    [ValidateRange(512, 1048576)][int]$MemoryStartupMB = 4096,
    [ValidateRange(1, 64)][int]$ProcessorCount = 2,
    [string]$SwitchName,
    [switch]$Isolated,
    [ValidateRange(60, 3600)][int]$TimeoutSeconds = 900,
    [ValidatePattern('^[A-Za-z]{2}(-[A-Za-z]{2})?$')][string]$Region = 'DE',
    [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')][string]$SystemLocale = 'de-DE',
    [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')][string]$UiLanguage = 'en-US',
    [ValidatePattern('^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}$')][string]$InputLocale = '0407:00000407',
    [string]$TimeZone = 'W. Europe Standard Time',
    [string]$StateRoot,
    [switch]$KeepOnFailure
)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or
    @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or
    @($RemainingArgs) -contains '--help'
if ($showHelpRequested) {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ArtifactId)) { throw 'HYPERV_WINDOWS_ACCEPTANCE_ARTIFACT_ID_REQUIRED' }
if (-not $AdministratorPassword) { throw 'HYPERV_WINDOWS_ACCEPTANCE_ADMINISTRATOR_PASSWORD_REQUIRED' }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$module = $null
$lab = $null
$artifact = $null
$receipt = $null
$acceptanceResult = $null
$cleanupResult = $null
$failure = $null
$cleanupFailure = $null
$mutexName = 'Global\SQL_Server_Lab_HyperV_Windows_Acceptance'
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
$mutexAcquired = $false

function Write-AcceptanceProgress {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("[{0}] [HYPERV-WINDOWS] {1}" -f ([datetime]::UtcNow.ToString('o')), $Message)
}

function Assert-WindowsAcceptance {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description
    )
    if (-not $Condition) { throw "HYPERV_WINDOWS_ACCEPTANCE_FAILED: $Description" }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function Test-CurrentAdminSession {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

try {
    $mutexAcquired = $mutex.WaitOne([TimeSpan]::FromMinutes(10))
    if (-not $mutexAcquired) { throw 'HYPERV_WINDOWS_ACCEPTANCE_HOST_LOCK_TIMEOUT' }

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module $modulePath -Force -PassThru
    if (-not (Test-CurrentAdminSession)) {
        throw 'HYPERV_WINDOWS_ACCEPTANCE_ADMIN_SESSION_REQUIRED'
    }
    if (-not $StateRoot) {
        $StateRoot = & $module { Get-LabStateRoot }
    }

    Write-AcceptanceProgress 'Hyper-V-Host und immutable OS_SEALED-Baseline pruefen.'
    $prerequisite = Test-SqlServerLabPrerequisite -Provider hyperv
    $hyperVProvider = @($prerequisite.Details | Where-Object Category -EQ 'Provider')[0]
    Assert-WindowsAcceptance -Condition ($hyperVProvider.Status -eq 'RESOURCE_OK') `
        -Description "Hyper-V-Host ist erreichbar: $($hyperVProvider.Message)"

    $artifact = & $module {
        param($Id, $Root)
        Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root
    } $ArtifactId $StateRoot
    Assert-WindowsAcceptance -Condition ($artifact -and $artifact.artifactState -eq 'OS_SEALED') `
        -Description 'Artifact ist eine veroeffentlichte Windows-OS-Baseline'
    Assert-WindowsAcceptance -Condition ([bool]$artifact.generalized) `
        -Description 'Windows-Baseline ist als generalisiert registriert'
    Assert-WindowsAcceptance -Condition ((Get-Item -LiteralPath $artifact.Path -Force).IsReadOnly) `
        -Description 'Parent-VHDX ist vor dem Lauf schreibgeschuetzt'

    Write-AcceptanceProgress 'Differenzierenden Windows-Klon bewusst ausgeschaltet erstellen.'
    $lab = & $module {
        param($Id, $Name, $Instance, $Memory, $Processors, $Switch, $UseIsolation, $Root)
        New-HyperVLabEnvironment -ArtifactId $Id -LabName $Name -InstanceId $Instance `
            -MemoryStartupMB $Memory -ProcessorCount $Processors -SwitchName $Switch `
            -Isolated:$UseIsolation -StateRoot $Root
    } $ArtifactId $LabName $InstanceId $MemoryStartupMB $ProcessorCount $SwitchName $Isolated.IsPresent $StateRoot
    Assert-WindowsAcceptance -Condition ($lab.State -eq 'STOPPED' -and $lab.Workload -eq 'windows') `
        -Description 'Windows-Klon wurde im erwarteten STOPPED-Zustand erzeugt'

    Write-AcceptanceProgress 'Windows-OOBE, Region, Sprache, Tastatur und Zeitzone ausfuehren.'
    $provisioning = & $module {
        param($RunId, $Password, $Timeout, $Region, $SystemLocale, $UiLanguage, $InputLocale, $TimeZone, $Root)
        Invoke-HyperVLabUnattendedProvision -RunId $RunId -AdministratorPassword $Password `
            -PasswordSource user -TimeoutSeconds $Timeout -Region $Region `
            -SystemLocale $SystemLocale -UiLanguage $UiLanguage -InputLocale $InputLocale `
            -TimeZone $TimeZone -StateRoot $Root
    } $lab.RunId $AdministratorPassword $TimeoutSeconds $Region $SystemLocale $UiLanguage $InputLocale $TimeZone $StateRoot
    Assert-WindowsAcceptance -Condition ($provisioning.OobeState -eq 'COMPLETED' -and $provisioning.WindowsOnly) `
        -Description 'Unbeaufsichtigte OOBE wurde als reiner Windows-Pfad abgeschlossen'

    $current = & $module {
        param($RunId, $Root)
        Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $Root
    } $lab.RunId $StateRoot
    Assert-WindowsAcceptance -Condition (
        $current.Instance.oobeAutomation.status -eq 'COMPLETED' -and
        $current.Instance.windowsProvisioning.state -eq 'COMPLETE' -and
        $current.Instance.workload -eq 'windows'
    ) -Description 'Connection-State bindet abgeschlossene Windows-Provisionierung ohne SQL-Readiness'

    Write-AcceptanceProgress 'Laufende VM ueber den gemeinsamen Reconcile-Vertrag stoppen.'
    $stopPlan = Get-SqlServerLabReconcilePlan -RunId $lab.RunId -TargetState STOPPED -StateRoot $StateRoot
    Assert-WindowsAcceptance -Condition (-not $stopPlan.IsNoOp -and $stopPlan.HighestChangeClass -eq 'restart') `
        -Description 'Read-only Reconcile-Plan erkennt den notwendigen Stop'
    $stopAction = Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -TargetState STOPPED -StateRoot $StateRoot -Confirm:$false
    Assert-WindowsAcceptance -Condition ($stopAction.ExecutionSummary.Status -eq 'SUCCEEDED') `
        -Description 'Reconcile-Executor hat die Windows-VM gestoppt'

    $stopped = & $module {
        param($RunId, $Root)
        $current = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $Root
        Get-HyperVInstanceStatus -VMName $current.Instance.vmName `
            -ExpectedRunId $current.Run.runId -ExpectedScopeId $current.Run.scopeId
    } $lab.RunId $StateRoot
    Assert-WindowsAcceptance -Condition ($stopped.Exists -and $stopped.State -eq 'Off') `
        -Description 'Hyper-V bestaetigt den ausgeschalteten Zustand'

    Write-AcceptanceProgress 'VM ueber Reconcile erneut starten und PowerShell Direct abwarten.'
    $startPlan = Get-SqlServerLabReconcilePlan -RunId $lab.RunId -TargetState RUNNING -StateRoot $StateRoot
    Assert-WindowsAcceptance -Condition (-not $startPlan.IsNoOp -and $startPlan.HighestChangeClass -eq 'restart') `
        -Description 'Read-only Reconcile-Plan erkennt den notwendigen Start'
    $startAction = Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -TargetState RUNNING -StateRoot $StateRoot -Confirm:$false
    Assert-WindowsAcceptance -Condition ($startAction.ExecutionSummary.Status -eq 'SUCCEEDED') `
        -Description 'Reconcile-Executor hat die Windows-VM erneut gestartet'

    $current = & $module {
        param($RunId, $Root)
        Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $Root
    } $lab.RunId $StateRoot
    $credential = [PSCredential]::new('Administrator', $AdministratorPassword)
    $fallbackAddress = [string]$current.Instance.oobeAutomation.labAddress
    $ready = & $module {
        param($VmName, $RunId, $ScopeId, $Credential, $Address, $Timeout)
        Wait-HyperVPowerShellDirect -VMName $VmName -ExpectedRunId $RunId `
            -ExpectedScopeId $ScopeId -Credential $Credential `
            -FallbackAddress $Address -TimeoutSeconds $Timeout
    } $current.Instance.vmName $current.Run.runId $current.Run.scopeId $credential $fallbackAddress $TimeoutSeconds
    Assert-WindowsAcceptance -Condition ([bool]$ready.Ready) `
        -Description 'PowerShell Direct ist nach dem Cold Start wieder erreichbar'

    Write-AcceptanceProgress 'Windows-Gastzustand und Abwesenheit einer SQL-Installation pruefen.'
    $receipt = & $module {
        param($VmName, $RunId, $ScopeId, $Credential, $Address)
        Invoke-HyperVPowerShellDirect -VMName $VmName -ExpectedRunId $RunId `
            -ExpectedScopeId $ScopeId -Credential $Credential -FallbackAddress $Address `
            -ArgumentList @($RunId) -ScriptBlock {
                param($ExpectedRunId)
                $windowsCurrentVersion = Get-ItemProperty `
                    -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
                    -ErrorAction Stop
                $sqlServices = @(Get-Service -ErrorAction Stop | Where-Object {
                    $_.Name -match '^(MSSQL|SQLAgent|SQLBrowser)'
                } | Select-Object Name, Status)
                $unattendArtifacts = @(
                    "$env:WINDIR\Panther\Unattend.xml"
                    "$env:WINDIR\Panther\Unattend\Unattend.xml"
                    "$env:WINDIR\Setup\Scripts\SetupComplete.cmd"
                ) | Where-Object { Test-Path -LiteralPath $_ }
                [PSCustomObject]@{
                    runId = $ExpectedRunId
                    computerName = $env:COMPUTERNAME
                    imageState = [string](Get-ItemPropertyValue `
                        -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' `
                        -Name ImageState -ErrorAction Stop)
                    productName = [string]$windowsCurrentVersion.ProductName
                    editionId = [string]$windowsCurrentVersion.EditionID
                    currentBuild = [string]$windowsCurrentVersion.CurrentBuild
                    powerShellVersion = $PSVersionTable.PSVersion.ToString()
                    geoId = [int](Get-WinHomeLocation).GeoId
                    systemLocale = [string](Get-WinSystemLocale)
                    uiLanguage = [string](Get-WinUILanguageOverride)
                    inputLocale = [string](Get-WinDefaultInputMethodOverride)
                    timeZone = [string](Get-TimeZone).Id
                    sqlServices = @($sqlServices)
                    sqlInstanceRegistryPresent = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
                    unattendArtifacts = @($unattendArtifacts)
                    observedAt = [datetime]::UtcNow.ToString('o')
                }
            }
    } $current.Instance.vmName $current.Run.runId $current.Run.scopeId $credential $fallbackAddress
    $receipt = @($receipt)[-1]
    $expectedGeoId = ([System.Globalization.RegionInfo]::new(($Region -split '-')[-1])).GeoId
    Assert-WindowsAcceptance -Condition (
        $receipt.runId -eq $lab.RunId -and
        $receipt.imageState -eq 'IMAGE_STATE_COMPLETE' -and
        -not [string]::IsNullOrWhiteSpace([string]$receipt.computerName)
    ) -Description 'Gast meldet einen abgeschlossenen Windows-Image-State'
    Assert-WindowsAcceptance -Condition (
        [int]$receipt.geoId -eq $expectedGeoId -and
        $receipt.systemLocale -eq $SystemLocale -and
        $receipt.uiLanguage -eq $UiLanguage -and
        $receipt.inputLocale -eq $InputLocale -and
        $receipt.timeZone -eq $TimeZone
    ) -Description 'Regionale Konfiguration bleibt nach dem Cold Start erhalten'
    Assert-WindowsAcceptance -Condition (
        @($receipt.sqlServices).Count -eq 0 -and
        -not [bool]$receipt.sqlInstanceRegistryPresent
    ) -Description 'Windows-OS-Baseline enthaelt keine SQL-Server-Instanz'
    Assert-WindowsAcceptance -Condition (@($receipt.unattendArtifacts).Count -eq 0) `
        -Description 'Antwortdatei und Setup-Bootstrap wurden aus dem Gast entfernt'

    $acceptanceResult = [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.HyperVWindowsBaselineAcceptance'; Version = '1.0' }
        ArtifactId = $ArtifactId
        RunId = $lab.RunId
        VMName = $current.Instance.vmName
        Workload = 'windows'
        OobeState = $provisioning.OobeState
        ReconcileStop = $stopAction.ExecutionSummary.Status
        ReconcileStart = $startAction.ExecutionSummary.Status
        PowerShellDirectAfterColdStart = [bool]$ready.Ready
        Guest = [PSCustomObject]@{
            ComputerName = $receipt.computerName
            ProductName = $receipt.productName
            EditionId = $receipt.editionId
            CurrentBuild = $receipt.currentBuild
            PowerShellVersion = $receipt.powerShellVersion
            ImageState = $receipt.imageState
            SqlServices = @($receipt.sqlServices).Count
        }
        ObservedAt = [string]$receipt.observedAt
    }
}
catch {
    $failure = $_
}
finally {
    $preserveFailedRun = $failure -and $KeepOnFailure.IsPresent
    if ($lab -and -not $preserveFailedRun) {
        try {
            Write-AcceptanceProgress 'Scopegebundenen Test-Run und sein DPAPI-Secret entfernen.'
            $cleanupResult = Remove-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Force -Confirm:$false
            if ($cleanupResult.Status -ne 'REMOVED') {
                throw "HYPERV_WINDOWS_ACCEPTANCE_CLEANUP_INCOMPLETE: $($cleanupResult.Status)"
            }
        }
        catch {
            $cleanupFailure = $_
        }
    }
    elseif ($preserveFailedRun) {
        Write-Warning "Fehlgeschlagener Acceptance-Run wurde bewusst behalten: $($lab.RunId)"
    }

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

if ($failure) {
    if ($cleanupFailure) {
        Write-Warning "Zusaetzlich ist der Cleanup fehlgeschlagen: $($cleanupFailure.Exception.Message)"
    }
    throw $failure
}
if ($cleanupFailure) { throw $cleanupFailure }

$artifactAfterCleanup = Import-Module $modulePath -Force -PassThru
try {
    $verifiedArtifact = & $artifactAfterCleanup {
        param($Id, $Root)
        Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root
    } $ArtifactId $StateRoot
    Assert-WindowsAcceptance -Condition (
        $verifiedArtifact -and
        $verifiedArtifact.sha256 -eq $artifact.sha256 -and
        (Get-Item -LiteralPath $verifiedArtifact.Path -Force).IsReadOnly
    ) -Description 'Immutable Parent-VHDX blieb nach dem Cleanup unveraendert registriert'
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
}

$acceptanceResult | Add-Member -NotePropertyName Cleanup -NotePropertyValue $cleanupResult.Status -Force
$acceptanceResult | ConvertTo-Json -Depth 8
Write-AcceptanceProgress 'Windows-Baseline-Cold-Path erfolgreich abgeschlossen.'
