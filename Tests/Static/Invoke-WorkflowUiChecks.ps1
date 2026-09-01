#Requires -Version 7.2
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$serverPath = Join-Path $repoRoot 'Tools/Start-SqlServerLabUi.ps1'
$moduleLoaderPath = Join-Path $repoRoot 'SqlServerLab.psm1'
$commonPath = Join-Path $repoRoot 'Private/Common.ps1'
$workflowPath = Join-Path $repoRoot 'Public/Get-SqlServerLabWorkflow.ps1'
$removalPreviewPath = Join-Path $repoRoot 'Public/Get-SqlServerLabPersistentStorageRemovalPlan.ps1'
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
$removalPreviewText = Get-Content -LiteralPath $removalPreviewPath -Raw -Encoding utf8
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
    $scriptText -match 'Automatischen Image-Abschluss fortsetzen' -and
    $htmlText -match 'Neue Container-Umgebung' -and
    $scriptText -match 'CreateContainerDatabase' -and
    $scriptText -match 'dateToGerman'
)
Add-CheckResult -Name 'SQL-Aktionsdialog behaelt Passwortfeld und blendet katalogspezifische Hinweise passend ein' -Success (
    $htmlText -match 'id="container-operation-password-text"' -and
    $htmlText -match 'id="container-operation-password"' -and
    $scriptText -match "container-operation-password-text'\)\.textContent" -and
    $scriptText -notmatch "container-operation-password-label'\)\.textContent" -and
    $scriptText -match "container-sample-note'\)\.hidden = !showContainerSamples"
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
    $scriptText -match 'function isSqlPreparedCompatibleWindowsMedia' -and
    $scriptText -match 'windows-\(server-\)\?\\d\+' -and
    $scriptText -match 'function formatOperatingSystem' -and
    $scriptText -match 'Erkannt – für SQL-Prepared derzeit nicht unterstützt' -and
    $scriptText -match 'Nicht auswertbar – nicht verwendbar' -and
    $scriptText -match 'function windowsMediaGroup' -and
    $scriptText -match 'Reguläre Medien'
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
    $scriptText -match 'formatOperatingSystem\(item\.OperatingSystem\)' -and
    $scriptText -match 'NewSqlBuildFromBaseline' -and
    $scriptText -match "kind === 'sql-fresh'" -and
    $scriptText -match "ProvisioningMode === 'fresh-windows-media'"
)
Add-CheckResult -Name 'UI und Konsole erlauben jede veröffentlichte erkannte Windows-OS-Baseline' -Success (
    $consoleText -match "artifactState -eq 'OS_SEALED'.*windows-\(server-\)\?\[0-9\]\+" -and
    $workflowText -match 'Windows \$\(\$_\.operatingSystem\.version\)'
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
Add-CheckResult -Name 'Testdaten-Root ist konfigurierbar und wird als sichtbare Bibliothek verwendet' -Success (
    $actionText -match 'SetTestDataRoot' -and
    $workflowText -match 'TestDataRoot' -and
    $htmlText -match 'id="sources-test-data-root"' -and
    $scriptText -match "SetTestDataRoot" -and
    $consoleText -match 'Testdaten-Bibliothek konfigurieren'
)
Add-CheckResult -Name 'Datenbankdialog bietet katalogisierte Testdatenbanken mit explizitem Trust an' -Success (
    $workflowText -match 'SampleDatabases = \$sampleDatabases' -and
    $workflowText -match 'Get-LabExecutableSampleVariant' -and
    $workflowText -match 'ArtifactType = \$_.ArtifactType' -and
    $actionText -match 'InstallContainerSampleDatabase' -and
    $actionText -match 'Resolve-LabRunInstance' -and
    $actionText -match 'CONTAINER_WORKFLOW_SAMPLE_TRUST_REQUIRED' -and
    $htmlText -match 'id="container-sample"' -and
    $htmlText -match 'id="container-sample-trust"' -and
    $htmlText -match 'id="container-sample-sha256"' -and
    $actionText -match '\[string\]\$SampleSha256' -and
    $scriptText -match 'renderContainerSampleOptions' -and
    $scriptText -match 'data-artifact-type' -and
    $scriptText -match 'Handler: ' -and
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
Add-CheckResult -Name 'CLI und Workflow-UI restaurieren Lab_Data-Backups über dieselbe stabile BackupSetId' -Success (
    $workflowText -match 'Get-LabDatabaseBackupSelection -DataRoot \$dataRoot' -and
    $workflowText -match 'BackupLibrary = \$backupLibrary' -and
    $actionText -match 'RestoreContainerLibraryBackup' -and
    $actionText -match 'Restore-SqlServerLabDatabase @restoreArguments' -and
    $actionText -match 'BackupSetId = \$BackupSetId' -and
    $htmlText -match 'id="container-library-backup"' -and
    $scriptText -match 'renderContainerLibraryBackups' -and
    $scriptText -match "action = 'RestoreContainerLibraryBackup'" -and
    $scriptText -match 'parameters\.BackupSetId = backupSetId' -and
    $scriptText -notmatch 'parameters\.Backup(Source|Path)'
)
Add-CheckResult -Name 'CLI und Browser verwenden denselben read-only Retention-Plan-Core' -Success (
    $removalPreviewText -match 'function Get-SqlServerLabPersistentStorageRemovalPlan' -and
    $removalPreviewText -match 'Get-SqlServerLabCleanupAudit -NoWrite' -and
    $removalPreviewText -match 'Get-LabPersistentStorageRemovalPlan' -and
    $workflowText -match 'PersistentStorageRemovalCandidates = \$persistentStorageRemovalCandidates' -and
    $workflowText -notmatch 'ProviderResourceId = \[string\]\$store\.LocationBinding' -and
    $serverText -match '/api/persistent-storage/removal-plan' -and
    $serverText -match 'Get-SqlServerLabPersistentStorageRemovalPlan -RunId \$runId -Selection \$selections' -and
    $htmlText -match 'id="persistent-storage-removal-dialog"' -and
    $scriptText -match 'data-persistent-storage-removal-preview' -and
    $scriptText -match "fetch\('/api/persistent-storage/removal-plan'" -and
    $htmlText -match 'Sie entfernt weder die Umgebung noch Daten'
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
Add-CheckResult -Name 'Container-Autostart ist in UI, Workflow und Übersicht durchgängig' -Success (
    $htmlText -match 'id="container-autostart"' -and
    $scriptText -match "AutoStart: \$\('#container-autostart'\)\.checked \? 'on' : 'off'" -and
    $actionText -match 'New-SqlServerLab.*-AutoStart \$AutoStart' -and
    $workflowText -match 'AutoStart = if \(\$_\.autostart\)' -and
    $scriptText -match 'Autostart: '
)
Add-CheckResult -Name 'UI-Lifecycle-Schaltflächen gehen über Reconcile-Vertrag' -Success (
    $actionText -match 'StartLabReconcile' -and
    $actionText -match 'StopLabReconcile' -and
    $actionText -match 'Invoke-SqlServerLabReconcileAction -RunId \$BuildId -TargetState RUNNING' -and
    $actionText -match 'Invoke-SqlServerLabReconcileAction -RunId \$BuildId -TargetState STOPPED' -and
    $scriptText -match 'data-container-action' -and
    $scriptText -match 'data-hyperv-action' -and
    $scriptText -match 'StopLabReconcile' -and
    $scriptText -match 'StartLabReconcile'
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
    $scriptText -match 'Windows prüfen und Image automatisch fertigstellen' -and
    $scriptText -match "action === 'ConfirmSqlWindowsInstall'" -and
    $consoleText -match 'Confirm-LabHyperVSqlWindowsInstallationInteractive' -and
    $consoleText -match "'2' \{ Invoke-LabHyperVMenuAction -Title 'Windows bestätigen und automatisch fertigstellen' -Action \{ Confirm-LabHyperVSqlWindowsInstallationInteractive \} -ResourceClass Build,Image,Staging \}"
)
Add-CheckResult -Name 'UI trennt reine Windows-VMs von SQL-Prepared-Hyper-V-Labs' -Success (
    $hyperVLabText -match 'SQL_PREPARED_SEALED' -and
    $hyperVLabText -match "OS_SEALED" -and
    $hyperVLabText -match "workload = 'windows'" -and
    $hyperVLabText -match 'WindowsOnly' -and
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
    $scriptText -match 'Array\.isArray\(item\.SqlInstances\)' -and
    $scriptText -match 'getHyperVArtifactCandidates' -and
    $scriptText -match "item.Workload !== 'windows'" -and
    $scriptText -match 'SQL, WMI und TCP/IP automatisch einrichten' -and
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
    $actionText -match '\[string\]\$Region' -and
    $actionText -match '\[string\]\$SystemLocale' -and
    $actionText -match '\[string\]\$UiLanguage' -and
    $actionText -match '\[string\]\$InputLocale' -and
    $actionText -match '\[string\]\$TimeZone' -and
    $actionText -match '\[SecureString\]\$SaPassword' -and
    $consoleText -match 'Read-LabHyperVLocaleSettings' -and
    $hyperVLabText -match 'Resolve-HyperVLocaleGeoId' -and
    $htmlText -match 'id="hyperv-password-mode"' -and
    $htmlText -match 'id="hyperv-guest-password"' -and
    $htmlText -match 'id="hyperv-sa-password"' -and
    $htmlText -match 'id="hyperv-region"' -and
    $htmlText -match 'id="hyperv-system-locale"' -and
    $htmlText -match 'id="hyperv-ui-language"' -and
    $htmlText -match 'id="hyperv-input-locale"' -and
    $htmlText -match 'id="hyperv-time-zone"' -and
    $htmlText -match 'id="credential-sa-password"' -and
    $htmlText -match 'id="hyperv-copy-password"' -and
    $scriptText -match 'generateHyperVGuestPassword' -and
    $scriptText -match 'navigator\.clipboard' -and
    $scriptText -match 'SystemLocale: systemLocale' -and
    $scriptText -match 'UiLanguage: uiLanguage' -and
    $scriptText -match 'InputLocale: inputLocale' -and
    $scriptText -match 'TimeZone: timeZone' -and
    $scriptText -match 'updateHyperVSaPasswordMode'
)
Add-CheckResult -Name 'Reguläre Hyper-V-Klone automatisieren SQL-Neustart, WMI und TCP/IP-Hostzugriff' -Success (
    $hyperVLabText -match 'Wait-HyperVLabSqlCompletionRestart' -and
    $hyperVLabText -match 'Repair-HyperVLabSqlWmiProvider' -and
    $hyperVLabText -match 'Enable-HyperVLabHostSqlAccess' -and
    $hyperVLabText -match 'Feste Lab-IP, SQL-TCP' -and
    $actionText -match 'SQL-WMI-Provider sowie TCP/IP-Hostzugriff' -and
    $scriptText -match 'SQL, WMI und TCP/IP automatisch einrichten'
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
Add-CheckResult -Name 'Konsolenaktionen für Hyper-V-Labs werden einzeln mit Zweck erklärt' -Success (
    $consoleText -match "Label 'VM starten'" -and
    $consoleText -match "Label 'SQL CompleteImage ausführen'" -and
    $consoleText -match "Label 'Host-SSMS einrichten'" -and
    $consoleText -match 'Erforderlich, wenn MSSQLSERVER noch fehlt' -and
    $consoleText -match 'Formatiert ausschließlich die neu angehängte Lab-Datenplatte'
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
    $htmlText -match 'id="hyperv-autostart"' -and
    $htmlText -match 'id="hyperv-existing-vm-autostart"' -and
    $scriptText -match 'renderHyperVExistingVmSourceOptions' -and
    $scriptText -match "AutoStart:.*'on'.*'off'" -and
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
    $scriptText -match "queueBackgroundAction\('RenameLab'" -and
    $consoleText -match 'Rename-LabEnvironmentInteractive' -and
    $consoleText -match "New-LabConsoleItem -Id 'rename' -Label 'Umgebung umbenennen' -Shortcut 'n'" -and
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
Add-CheckResult -Name 'Escape schließt den obersten Dialog ohne Mutation und verwirft sensible Eingaben' -Success (
    $scriptText -match 'function\s+cancelDialog\s*\(' -and
    $scriptText -match 'input\[type="password"\]' -and
    $scriptText -match "event\.key\s*!==\s*'Escape'" -and
    $scriptText -match "querySelectorAll\('dialog\[open\]'\)" -and
    $scriptText -match "dialog\.close\('cancel'\)"
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
    $scriptText -match 'Array\.isArray\(payload\)' -and
    $serverText -match 'ConvertTo-Json -InputObject \$snapshot -Depth 8' -and
    $scriptText -match 'optimisticJobIds' -and
    $scriptText -match 'isOptimisticOnly \? incomingLines'
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



