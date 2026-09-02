#Requires -Version 7.2
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArgs
)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or
    @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or
    @($RemainingArgs) -contains '--help'
if ($showHelpRequested) { Get-Help -Full -Name $PSCommandPath | Out-Host; return }

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-initial-setup-$([guid]::NewGuid().ToString('N'))"
$mediaRoot = Join-Path $temporaryRoot 'Lab1_Base'
$dataRootOne = Join-Path $temporaryRoot 'Lab1_Data'
$dataRootTwo = Join-Path $temporaryRoot 'Lab2_Data'
$previousMediaRoot = $env:SQL_SERVER_LAB_MEDIA_ROOT
$previousDataRoot = $env:SQL_SERVER_LAB_DATA_ROOT
$previousControllerId = $env:SQL_SERVER_LAB_CONTROLLER_ID
$userMediaRoot = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_MEDIA_ROOT', 'User')
$userDataRoot = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', 'User')
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Initial Setup Checks' -ForegroundColor Cyan

try {
    $null = New-Item -Path $temporaryRoot -ItemType Directory -Force
    $env:SQL_SERVER_LAB_MEDIA_ROOT = $null
    $env:SQL_SERVER_LAB_DATA_ROOT = $null
    $env:SQL_SERVER_LAB_CONTROLLER_ID = $null
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    & $module {
        Set-Item -Path Function:script:Get-LabMediaRootDefault -Value {
            if ($env:SQL_SERVER_LAB_MEDIA_ROOT -and (Test-Path -LiteralPath $env:SQL_SERVER_LAB_MEDIA_ROOT -PathType Container)) {
                return (Resolve-Path -LiteralPath $env:SQL_SERVER_LAB_MEDIA_ROOT).Path
            }
            return $null
        }
        Set-Item -Path Function:script:Get-LabDataRootDefault -Value {
            if ($env:SQL_SERVER_LAB_DATA_ROOT -and (Test-Path -LiteralPath $env:SQL_SERVER_LAB_DATA_ROOT -PathType Container)) {
                return (Resolve-Path -LiteralPath $env:SQL_SERVER_LAB_DATA_ROOT).Path
            }
            return $null
        }
        Set-Item -Path Function:script:Get-LabVolumeIdentity -Value {
            param([string]$Path)
            $full = [IO.Path]::GetFullPath($Path)
            $id = if ($full -match 'Lab2_Data') { 'test-volume-two' } else { 'test-volume-one' }
            [PSCustomObject]@{ VolumeId=$id; DriveLetter=$id; VolumeRoot=[IO.Path]::GetPathRoot($full) }
        }
    }

    $relativeRejected = try {
        & $module { New-LabInitialSetupPlan -MediaRoot 'D:' -LabDataRoot @('D:\') -DefaultDataRoot 'D:\Lab1_Data' }
        $false
    } catch { $_.Exception.Message -match 'INITIAL_SETUP_MEDIA_ROOT_NOT_FULLY_QUALIFIED' }
    Add-CheckResult -Name 'Ersteinrichtung lehnt laufwerksrelative Root-Angaben vor jeder Mutation ab' -Success $relativeRejected

    $plan = & $module {
        param($mediaRoot, $rootOne, $rootTwo, $defaultRoot)
        New-LabInitialSetupPlan -MediaRoot $mediaRoot -LabDataRoot @($rootOne, $rootTwo) -DefaultDataRoot $defaultRoot
    } $mediaRoot $dataRootOne $dataRootTwo $dataRootTwo
    Add-CheckResult -Name 'Plan akzeptiert frei wählbare gemeinsame Media- und Datenroots' -Success (
        $plan.ContractVersion -eq 'SqlServerLab.InitialSetupPlan/1.0' -and
        $plan.MediaAction.MediaRoot -eq $mediaRoot -and
        @($plan.LocationActions).Count -eq 2 -and
        $plan.LocationActions[0].LabDataRoot -eq $dataRootOne -and
        $plan.LocationActions[1].LabDataRoot -eq $dataRootTwo
    )
    Add-CheckResult -Name 'Globaler Lab_Data-Standard ist im Plan ausdrücklich gebunden' -Success ($plan.DefaultDataRoot -eq $dataRootTwo)
    Add-CheckResult -Name 'Read-only Planung erzeugt keine gemeinsamen Host-Wurzeln' -Success (
        -not (Test-Path -LiteralPath $mediaRoot) -and -not (Test-Path -LiteralPath $dataRootOne) -and -not (Test-Path -LiteralPath $dataRootTwo)
    )
    $missingDefaultRejected = try {
        & $module {
            param($mediaRoot, $dataRoot)
            New-LabInitialSetupPlan -MediaRoot $mediaRoot -LabDataRoot $dataRoot
        } $mediaRoot $dataRootOne
        $false
    } catch { $_.Exception.Message -match 'INITIAL_SETUP_DEFAULT_DATA_ROOT_REQUIRED' }
    Add-CheckResult -Name 'Erster Setup-Plan verlangt eine ausdrückliche globale Default-Auswahl' -Success $missingDefaultRejected
    $whatIfPlan = & $module {
        param($mediaRoot, $rootOne, $rootTwo, $defaultRoot)
        Invoke-LabInitialSetup -MediaRoot $mediaRoot -LabDataRoot @($rootOne, $rootTwo) `
            -DefaultDataRoot $defaultRoot -ProcessEnvironmentOnly -WhatIf
    } $mediaRoot $dataRootOne $dataRootTwo $dataRootTwo
    Add-CheckResult -Name 'WhatIf liefert den revalidierten Plan ohne Dateisystemmutation' -Success (
        $whatIfPlan.ContractVersion -eq 'SqlServerLab.InitialSetupPlan/1.0' -and
        -not (Test-Path -LiteralPath $mediaRoot) -and -not (Test-Path -LiteralPath $dataRootOne)
    )

    $result = & $module {
        param($plan)
        Invoke-LabInitialSetupPlan -Plan $plan -ProcessEnvironmentOnly -Confirm:$false
    } $plan
    $configuration = & $module { Get-LabStorageConfiguration }
    Add-CheckResult -Name 'Gemeinsamer Core initialisiert frei benannte, controllergebundene Host-Roots' -Success (
        $result.Complete -and (Test-Path -LiteralPath (Join-Path $mediaRoot 'SQL') -PathType Container) -and
        @($configuration.LabDataLocations).Count -eq 2 -and
        (Test-Path -LiteralPath (Join-Path $dataRootOne '.sql-server-lab-root.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $dataRootTwo '.sql-server-lab-root.json') -PathType Leaf)
    )
    Add-CheckResult -Name 'Ausdrücklich gewählter zweiter Root wird globaler Standard' -Success (
        [string]$configuration.DefaultDataRoot -eq $dataRootTwo -and [string]$env:SQL_SERVER_LAB_DATA_ROOT -eq $dataRootTwo
    )
    Add-CheckResult -Name 'Prozessisolierter Testlauf verändert keine dauerhaften Benutzervariablen' -Success (
        [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_MEDIA_ROOT', 'User') -eq $userMediaRoot -and
        [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', 'User') -eq $userDataRoot
    )

    $mediaSentinel = Join-Path $mediaRoot 'existing-media.bin'
    $dataSentinel = Join-Path $dataRootOne 'existing-data.bin'
    Set-Content -LiteralPath $mediaSentinel -Value 'media-preserved' -Encoding utf8NoBOM
    Set-Content -LiteralPath $dataSentinel -Value 'data-preserved' -Encoding utf8NoBOM
    $secondResult = & $module { Invoke-LabInitialSetup -ProcessEnvironmentOnly -Confirm:$false }
    Add-CheckResult -Name 'Vollständige Ersteinrichtung ist ohne Rückfragen und Mutation idempotent' -Success (
        $secondResult.Complete -and
        (Get-Content -LiteralPath $mediaSentinel -Raw -Encoding utf8).Trim() -eq 'media-preserved' -and
        (Get-Content -LiteralPath $dataSentinel -Raw -Encoding utf8).Trim() -eq 'data-preserved'
    )

    $env:SQL_SERVER_LAB_MEDIA_ROOT = $null
    $env:SQL_SERVER_LAB_DATA_ROOT = $null
    $foreignRoot = Join-Path $temporaryRoot 'foreign-data'
    $alternateMediaRoot = Join-Path $temporaryRoot 'alternate-media'
    $null = New-Item -Path $foreignRoot -ItemType Directory -Force
    Set-Content -LiteralPath (Join-Path $foreignRoot 'do-not-touch.txt') -Value 'foreign' -Encoding utf8NoBOM
    $foreignRejected = try {
        & $module {
            param($mediaRoot, $dataRoot, $defaultRoot)
            Invoke-LabInitialSetup -MediaRoot $mediaRoot -LabDataRoot $dataRoot `
                -DefaultDataRoot $defaultRoot -ProcessEnvironmentOnly -Confirm:$false
        } $alternateMediaRoot $foreignRoot $foreignRoot
        $false
    } catch { $_.Exception.Message -match 'INITIAL_SETUP_DATA_ROOT_NOT_EMPTY' }
    Add-CheckResult -Name 'Fremder nichtleerer frei benannter Datenroot wird vor Media-Root-Mutation fail-closed abgelehnt' -Success (
        $foreignRejected -and -not (Test-Path -LiteralPath $alternateMediaRoot) -and
        (Get-Content -LiteralPath (Join-Path $foreignRoot 'do-not-touch.txt') -Raw -Encoding utf8).Trim() -eq 'foreign'
    )

    $consoleText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1') -Raw -Encoding utf8
    $setupText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/InitialSetup.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Setup ist als Direktaktion und im Storage-Menü an denselben Core gebunden' -Success (
        $consoleText -match "ValidateSet\([^\r\n]+?'Setup'" -and
        $consoleText -match "New-LabConsoleItem -Id 'Setup'.+Ersteinrichtung" -and
        $consoleText -match "'Setup'\s*\{\s*Invoke-LabInitialSetupInteractive"
    )
    Add-CheckResult -Name 'Wizard nutzt den gemeinsamen abbrechbaren Eingabeadapter' -Success (
        $setupText -match 'Read-LabConsoleTextInput' -and $setupText -notmatch 'Read-Host'
    )
}
catch { Add-CheckResult -Name 'Initial-Setup-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally {
    $env:SQL_SERVER_LAB_MEDIA_ROOT = $previousMediaRoot
    $env:SQL_SERVER_LAB_DATA_ROOT = $previousDataRoot
    $env:SQL_SERVER_LAB_CONTROLLER_ID = $previousControllerId
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
