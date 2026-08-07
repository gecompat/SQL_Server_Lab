#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$serverPath = Join-Path $repoRoot 'Tools/Start-SqlServerLabUi.ps1'
$moduleLoaderPath = Join-Path $repoRoot 'SqlServerLab.psm1'
$commonPath = Join-Path $repoRoot 'Private/Common.ps1'
$workflowPath = Join-Path $repoRoot 'Public/Get-SqlServerLabWorkflow.ps1'
$actionPath = Join-Path $repoRoot 'Public/Invoke-SqlServerLabWorkflowAction.ps1'
$consolePath = Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1'
$vmConnectPath = Join-Path $repoRoot 'Private/HyperVVmConnect.ps1'
$hyperVLabPath = Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1'
$mediaSourcePath = Join-Path $repoRoot 'Private/MediaSourceCatalog.ps1'
$htmlPath = Join-Path $repoRoot 'Ui/index.html'
$scriptPath = Join-Path $repoRoot 'Ui/app.js'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Workflow UI Checks' -ForegroundColor Cyan

$serverText = Get-Content -LiteralPath $serverPath -Raw -Encoding utf8
$moduleLoaderText = Get-Content -LiteralPath $moduleLoaderPath -Raw -Encoding utf8
$commonText = Get-Content -LiteralPath $commonPath -Raw -Encoding utf8
$workflowText = Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8
$actionText = Get-Content -LiteralPath $actionPath -Raw -Encoding utf8
$consoleText = Get-Content -LiteralPath $consolePath -Raw -Encoding utf8
$vmConnectText = Get-Content -LiteralPath $vmConnectPath -Raw -Encoding utf8
$hyperVLabText = Get-Content -LiteralPath $hyperVLabPath -Raw -Encoding utf8
$mediaSourceText = Get-Content -LiteralPath $mediaSourcePath -Raw -Encoding utf8
$htmlText = Get-Content -LiteralPath $htmlPath -Raw -Encoding utf8
$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8

Add-CheckResult -Name 'UI lauscht ausschliesslich auf Loopback' -Success (
    $serverText.Contains('http://127.0.0.1:$Port/') -and
    $serverText.Contains('[Net.IPAddress]::IsLoopback')
)
Add-CheckResult -Name 'UI stellt Workflow- und Hintergrundjob-API bereit' -Success (
    $serverText -match "/api/workflow" -and
    $serverText -match "/api/jobs" -and
    $serverText -match "/api/actions" -and
    $serverText -match 'Start-ThreadJob'
)
Add-CheckResult -Name 'Workflow fasst Baselines, SQL-Images und offene Builds zusammen' -Success (
    $workflowText -match 'WindowsBaselines' -and
    $workflowText -match 'SqlPreparedImages' -and
    $workflowText -match 'PendingSqlBuilds' -and
    $workflowText -match 'NextStep'
)
Add-CheckResult -Name 'UI-Aktionen halten Gastpasswoerter nur fluechtig' -Success (
    $actionText.Contains('[SecureString]$GuestPassword') -and
    $actionText.Contains('[SecureString]$SaPassword') -and
    $serverText -match 'ConvertTo-SecureString' -and
    $serverText -notmatch 'Write-Output.*GuestPassword' -and
    $serverText -notmatch 'Write-Output.*SaPassword'
)
Add-CheckResult -Name 'VMConnect erhält lokalen Hyper-V-Host und VM-Namen' -Success (
    $actionText -match 'Start-LabVmConnect -VMName' -and
    $vmConnectText -match 'function Start-LabVmConnect' -and
    $vmConnectText -match 'System32\\vmconnect\.exe' -and
    $vmConnectText -match 'ArgumentList @\(\$hostName, \$VMName\)' -and
    $vmConnectText -match 'function Show-LabVmConnectWindow' -and
    $vmConnectText -match 'SetForegroundWindow' -and
    $vmConnectText -match 'SetWindowPos' -and
    $vmConnectText -match 'BringWindowToTop' -and
    $vmConnectText -match 'Reused = \$reused' -and
    $actionText -match 'OpenWindowsConsole' -and
    $actionText -match 'OpenSqlConsole'
)
Add-CheckResult -Name 'Browser-Oberflaeche zeigt Workflow und Live-Log' -Success (
    $htmlText -match 'GEFÜHRTER WORKFLOW' -and
    $htmlText -match 'Live-Log' -and
    $scriptText -match 'Nächster Schritt' -and
    $scriptText -match 'refreshJobs' -and
    $scriptText -match 'SQL-PrepareImage fortsetzen' -and
    $htmlText -match 'Neue Container-Umgebung' -and
    $scriptText -match 'CreateContainerDatabase' -and
    $scriptText -match 'dateToGerman'
)
Add-CheckResult -Name 'UI bietet erkannte Windows- und SQL-Medien ohne manuelle Editionsauswahl an' -Success (
    $workflowText -match 'WindowsInstallationMedia' -and
    $htmlText -match 'id="windows-media"' -and
    $htmlText -match 'Erkannte SQL-Medienedition' -and
    $htmlText -notmatch '<select id="sql-edition"' -and
    $scriptText -match 'renderWindowsInstallationMedia' -and
    $scriptText -match 'function windowsMediaSelectionKey' -and
    $scriptText -match 'data-media-id' -and
    $scriptText -match 'function selectedWindowsMediaPath' -and
    $scriptText -match 'WindowsMediaPath' -and
    $scriptText -match 'delete parameters\.SqlEdition' -and
    $scriptText -match "OperatingSystemId === 'windows-server-2025'"
)
Add-CheckResult -Name 'SQL-Prepared-Images verwenden standardmäßig frische Windows- und SQL-ISOs' -Success (
    $actionText -match 'NewSqlBuild' -and
    $actionText -match 'Initialize-HyperVSqlFreshPreparedImageBuild' -and
    $workflowText -match 'WindowsBaselines = @\(' -and
    $workflowText -match 'ProvisioningMode = \[string\]\$_.provisioningMode' -and
    $htmlText -match 'data-open-build="sql-fresh">Neues SQL-Prepared-Image' -and
    $htmlText -match 'id="sql-parent-artifact"' -and
    $htmlText -match 'Erweitert: SQL-Builder aus OS-Baseline' -and
    $scriptText -match 'renderSqlParentOptions' -and
    $scriptText -match 'NewSqlBuildFromBaseline' -and
    $scriptText -match "kind === 'sql-fresh'" -and
    $scriptText -match "ProvisioningMode === 'fresh-windows-media'"
)
Add-CheckResult -Name 'UI prüft und speichert explizit eingegebene ISO-Hashes vor dem Build' -Success (
    $actionText -match 'SetWindowsMediaHash' -and
    $actionText -match 'SetSqlMediaHash' -and
    $actionText -match 'WindowsMediaSha256' -and
    $actionText -match 'SqlMediaSha256' -and
    $htmlText -match 'id="windows-media-sha256"' -and
    $htmlText -match 'id="sql-media-sha256"' -and
    $htmlText -match 'id="set-windows-media-hash"' -and
    $htmlText -match 'id="set-sql-media-hash"' -and
    $scriptText -match 'SetWindowsMediaHash' -and
    $scriptText -match 'SetSqlMediaHash'
)
Add-CheckResult -Name 'Media Root und Quellen trennen Portalseiten von Bootstrapper-ISOs' -Success (
    $workflowText -match 'MediaSources = \$mediaSources' -and
    $actionText -match 'SetMediaRoot' -and
    $mediaSourceText -match 'BOOTSTRAPPER_MANUAL_ISO' -and
    $mediaSourceText -match 'DOWNLOAD_ON_INSTALL' -and
    $htmlText -match 'id="media-sources"' -and
    $htmlText -match 'id="sources-media-root"' -and
    $scriptText -match 'renderMediaSources' -and
    $scriptText -match 'sourceMediaRoot\.value = data\.Defaults\.MediaRoot' -and
    $scriptText -match 'safeExternalUrl'
)
Add-CheckResult -Name 'Datenbankdialog bietet katalogisierte Testdatenbanken mit explizitem Trust an' -Success (
    $workflowText -match 'SampleDatabases = \$sampleDatabases' -and
    $workflowText -match 'Get-LabExecutableSampleVariant' -and
    $actionText -match 'InstallContainerSampleDatabase' -and
    $actionText -match 'Resolve-LabRunInstance' -and
    $actionText -match 'CONTAINER_WORKFLOW_SAMPLE_TRUST_REQUIRED' -and
    $htmlText -match 'id="container-sample"' -and
    $htmlText -match 'id="container-sample-trust"' -and
    $htmlText -match 'id="container-sample-sha256"' -and
    $actionText -match '\[string\]\$SampleSha256' -and
    $scriptText -match 'renderContainerSampleOptions' -and
    $scriptText -match 'TrustUnknownSample' -and
    $scriptText -match 'SampleSha256' -and
    $scriptText -match "container-sample-trust'\)\.checked = false"
)
Add-CheckResult -Name 'UI und Workflow unterstützen Mehrfachauswahl von Testdatenbanken' -Success (
    $actionText -match 'InstallContainerSampleDatabases' -and
    $actionText -match '\[string\[\]\]\$SampleSelections' -and
    $htmlText -match 'id="container-sample" multiple' -and
    $scriptText -match 'SampleSelections = samples'
)
Add-CheckResult -Name 'UI bietet bestätigten globalen Cleanup und Manifest-Erstellung' -Success (
    $actionText -match 'ClearAllLabs' -and
    $actionText -match 'CreateContainerManifest' -and
    $actionText -match 'NewContainerLabFromManifest' -and
    $actionText -match 'New-SqlServerLabManifest -Path \$ManifestPath -InputObject \$draft' -and
    $htmlText -match 'id="clear-all-labs"' -and
    $htmlText -match 'id="manifest-dialog"' -and
    $htmlText -match 'id="manifest-run-dialog"' -and
    $scriptText -match "'ClearAllLabs'" -and
    $scriptText -match "'CreateContainerManifest'"
)
Add-CheckResult -Name 'Evaluationdatum ist lesbar vorausgefüllt und Abbruch bleibt möglich' -Success (
    $htmlText -match 'type="text"' -and
    $htmlText -match 'TT\.MM\.JJJJ' -and
    $htmlText -match 'type="button".*formnovalidate' -and
    $scriptText -match "event\.submitter\?\.value === 'cancel'" -and
    $scriptText -match 'closest' -and
    $scriptText -match 'value="cancel"' -and
    $scriptText -match 'parseGermanDate'
)
Add-CheckResult -Name 'Container-Labs zeigen alle Instanzen inklusive Provider' -Success (
    $scriptText -match 'container-instance' -and
    $scriptText -match 'instance\.Provider' -and
    $workflowText -match 'if \(\$_\.sqlVersion\)' -and
    $workflowText -match '\[string\]\$_.version' -and
    $scriptText -notmatch '\(item\.Instances \|\| \[\]\)\[0\]'
)
Add-CheckResult -Name 'UI bildet Hyper-V-SQL-Abnahmeschritte zustandsgeführt ab' -Success (
    $workflowText -match 'AcceptanceEnvironments = \$acceptanceItems' -and
    $workflowText -match 'ProvisioningMode' -and
    $actionText -match 'RunSqlAcceptanceSetup' -and
    $actionText -match 'RunSqlAcceptanceTests' -and
    $scriptText -match 'renderAcceptance' -and
    $scriptText -match 'SQL-Abnahme ausführen' -and
    $scriptText -match "\[data-open-build\], \[data-action\]"
)
Add-CheckResult -Name 'Frische SQL-Images prüfen Windows-Edition vor PrepareImage und Sysprep' -Success (
    $actionText -match 'ConfirmSqlWindowsInstall' -and
    $actionText -match 'Confirm-HyperVSqlFreshWindowsInstallation' -and
    $workflowText -match 'InstallationVerified = \[bool\]\(\$_\.installationEvidence' -and
    $scriptText -match 'Windows-Edition prüfen' -and
    $scriptText -match "action === 'ConfirmSqlWindowsInstall'" -and
    $consoleText -match 'Confirm-LabHyperVSqlWindowsInstallationInteractive' -and
    $consoleText -match "'2' \{ Invoke-LabHyperVMenuAction -Title 'Windows-Installation bestätigen' -Action \{ Confirm-LabHyperVSqlWindowsInstallationInteractive \} \}"
)
Add-CheckResult -Name 'UI erstellt reguläre Hyper-V-Labs nur aus SQL-Prepared-Images' -Success (
    $hyperVLabText -match 'SQL_PREPARED_SEALED' -and
    $hyperVLabText -match 'New-HyperVInstance' -and
    $hyperVLabText -match 'Start-HyperVLabEnvironment' -and
    $hyperVLabText -match 'Complete-HyperVLabSqlImage' -and
    $hyperVLabText -match '/ACTION=CompleteImage' -and
    $hyperVLabText -match 'ConvertTo-HyperVSqlMediaEdition' -and
    $hyperVLabText -match 'Get-HyperVSqlInstallationMediaCandidates' -and
    $hyperVLabText -match 'HYPERV_LAB_SQL_COMPLETE_MEDIA_AMBIGUOUS' -and
    $hyperVLabText -match 'Open-HyperVLabEnvironmentConsole' -and
    $actionText -match 'NewHyperVLab' -and
    $actionText -match 'CompleteHyperVLabSql' -and
    $actionText -match 'InspectHyperVLabSqlInstances' -and
    $actionText -match 'RemoveHyperVLab' -and
    $workflowText -match 'HyperVLabs = \$hyperVLabs' -and
    $workflowText -match 'HyperVSwitches = \$hyperVSwitches' -and
    $htmlText -match 'id="new-hyperv-lab"' -and
    $htmlText -match 'id="hyperv-artifact"' -and
    $scriptText -match 'renderHyperVLabs' -and
    $scriptText -match 'SQL CompleteImage ausführen' -and
    $scriptText -match 'SQL-Instanzen prüfen' -and
    $scriptText -match 'Connection String' -and
    $scriptText -match 'data-hyperv-remove'
)
Add-CheckResult -Name 'Prepared-Image-Klone erlauben getrennte Gast- und SA-Passwörter für automatische OOBE' -Success (
    $hyperVLabText -match 'Invoke-HyperVLabUnattendedProvision' -and
    $hyperVLabText -match 'run-child-vhdx' -and
    $hyperVLabText -match 'Save-LabSecret' -and
    $hyperVLabText -match 'guest-administrator-password' -and
    $hyperVLabText -match 'Complete-HyperVLabSqlImage' -and
    $actionText -match 'ProvisionUnattended' -and
    $actionText -match 'GuestPasswordSource' -and
    $actionText -match '\[SecureString\]\$SaPassword' -and
    $htmlText -match 'id="hyperv-password-mode"' -and
    $htmlText -match 'id="hyperv-guest-password"' -and
    $htmlText -match 'id="hyperv-sa-password"' -and
    $htmlText -match 'id="credential-sa-password"' -and
    $htmlText -match 'id="hyperv-copy-password"' -and
    $scriptText -match 'generateHyperVGuestPassword' -and
    $scriptText -match 'navigator\.clipboard' -and
    $scriptText -match 'updateHyperVSaPasswordMode'
)
Add-CheckResult -Name 'Konsole spiegelt Data-VHDX, SQL-CompleteImage, WMI-Reparatur und SQL-Instanzprüfung für reguläre Hyper-V-Labs' -Success (
    $consoleText -match 'Enable-HyperVLabPersistentData' -and
    $consoleText -match 'Initialize-HyperVLabPersistentData' -and
    $consoleText -match 'Complete-HyperVLabSqlImage' -and
    $consoleText -match 'Inspect-HyperVLabSqlInstances' -and
    $consoleText -match 'Repair-HyperVLabSqlWmiProvider' -and
    $consoleText -match 'Enable-HyperVLabHostSqlAccess' -and
    $consoleText -match 'Connection String \(Host-SSMS\)'
)
Add-CheckResult -Name 'UI bietet einen getrennten, sicheren Schnellstart aus vorhandener Windows-VM' -Success (
    $hyperVLabText -match 'Get-HyperVExistingVmLabSource' -and
    $hyperVLabText -match 'New-HyperVLabEnvironmentFromExistingVm' -and
    $hyperVLabText -match 'Convert-VHD' -and
    $hyperVLabText -match 'HYPERV_EXISTING_VM_LICENSE_CONFIRMATION_REQUIRED' -and
    $actionText -match 'NewHyperVLabFromExistingVm' -and
    $workflowText -match 'HyperVExistingVmSources' -and
    $htmlText -match 'id="new-hyperv-existing-vm-lab"' -and
    $htmlText -match 'id="hyperv-existing-vm-source"' -and
    $htmlText -match 'id="hyperv-existing-vm-license-confirm"' -and
    $scriptText -match 'renderHyperVExistingVmSourceOptions' -and
    $scriptText -match 'ConfirmSourceLicense' -and
    $consoleText -match 'New-LabHyperVEnvironmentFromExistingVmInteractive' -and
    $consoleText -match 'ConfirmSourceLicense'
)
Add-CheckResult -Name 'Prepared-Images erhalten lesbare Namen und zeigen vollständige Auswahl-Details' -Success (
    $actionText -match '\[string\]\$ImageName' -and
    $actionText -match 'RenameHyperVImageArtifact' -and
    $htmlText -match 'id="sql-image-name"' -and
    $htmlText -match 'id="hyperv-artifact-details"' -and
    $htmlText -match 'id="artifact-name-dialog"' -and
    $htmlText -match 'id="artifact-current-name"' -and
    $scriptText -match 'renderHyperVArtifactDetails' -and
    $scriptText -match 'data-artifact-rename' -and
    $scriptText -match 'artifact-current-name' -and
    $scriptText -match 'DisplayName' -and
    $scriptText -match 'ArtifactId:'
)
Add-CheckResult -Name 'Docker-, Podman- und Hyper-V-Labs können nachträglich umbenannt werden' -Success (
    $actionText -match "'RenameLab'" -and
    $actionText -match 'Rename-HyperVLabEnvironment' -and
    $actionText -match 'Rename-ContainerLabEnvironment' -and
    $htmlText -match 'id="lab-name-dialog"' -and
    $htmlText -match 'id="lab-current-name"' -and
    $scriptText -match 'data-lab-rename' -and
    $scriptText -match "startAction\('RenameLab'" -and
    $consoleText -match 'Rename-LabEnvironmentInteractive' -and
    $consoleText -match "\[n\] Umgebung umbenennen" -and
    $htmlText -match 'Projektname-Instanz-Run-ID'
)
Add-CheckResult -Name 'Konsolenübersicht zeigt Live-Status und passwortmaskierte Connection-Strings statt Workflow-Interna' -Success (
    $consoleText -match 'Sync-LabRunRuntimeState' -and
    $consoleText -match 'Get-LabRunConnectionStrings' -and
    $consoleText -match 'Connection String noch nicht ermittelt' -and
    $consoleText -match 'Get-LabRunsByRuntimeState' -and
    $consoleText -notmatch '\(Workflow:'
)
Add-CheckResult -Name 'Hyper-V-Switches und sofortige Browser-Rückmeldung sind sichtbar' -Success (
    $htmlText -match 'id="hyperv-switch"' -and
    $scriptText -match 'renderHyperVSwitchOptions' -and
    $htmlText -match 'id="action-feedback"' -and
    $scriptText -match '\[ANFORDERUNG\]' -and
    $scriptText -match '\[HEARTBEAT\]' -and
    $serverText -notmatch 'Eine Hintergrundaktion läuft bereits'
)
Add-CheckResult -Name 'Windows-Generalisierung fordert sichtbar das Gastpasswort an' -Success (
    $scriptText -match 'Windows generalisieren · Gastpasswort erforderlich' -and
    $scriptText -match "action === 'GeneralizeWindowsBuild'" -and
    $scriptText -match "\$\('#credential-note'\)" -and
    $htmlText -match 'id="credential-note"'
)
Add-CheckResult -Name 'UI räumt offene Hyper-V-Builder nur nach Bestätigung auf' -Success (
    $actionText -match 'CleanupWindowsBuild' -and
    $actionText -match 'CleanupSqlBuild' -and
    $actionText -match 'Remove-HyperVWindowsImageBuild' -and
    $actionText -match 'Remove-HyperVSqlImageBuild' -and
    $scriptText -match 'data-build-cleanup' -and
    $scriptText -match 'Build-Verlauf entfernen' -and
    $scriptText -match 'data-artifact-remove' -and
    $actionText -match 'RemoveHyperVImageArtifact' -and
    $scriptText -match 'Image löschen' -and
    $scriptText -match 'wirklich aufräumen' -and
    $scriptText -match 'Veröffentlichte Images bleiben unverändert' -and
    $htmlText -match 'confirmation-dialog' -and
    $scriptText -match 'openConfirmation' -and
    $scriptText -notmatch 'window\.confirm'
)
Add-CheckResult -Name 'UI-Jobs unterdrücken Modul-Ladeausgaben und zeigen Laufzeit' -Success (
    $serverText -match "InformationPreference = 'SilentlyContinue'" -and
    $serverText -match 'ElapsedSeconds' -and
    $serverText -match 'DateTimeOffset\]::Parse' -and
    $serverText -match 'RoundtripKind' -and
    $scriptText -match 'job-progress' -and
    $scriptText -match 'Array\.isArray\(payload\)'
)
Add-CheckResult -Name 'UI-Jobs leiten Labmeldungen ins Live-Log statt ins Terminal' -Success (
    $serverText -match 'SqlServerLabUiCaptureOutput' -and
    $serverText -match '6>&1' -and
    $commonText -match 'Write-Information "\[INFO\]' -and
    $commonText -match 'Write-Information "\[AKTION\]' -and
    $commonText -match 'Write-Information "\[STATUS\]' -and
    $moduleLoaderText -match 'Write-Verbose "\[LOAD\]'
)

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
