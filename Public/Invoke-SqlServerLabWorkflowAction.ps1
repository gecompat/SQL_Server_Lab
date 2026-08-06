<#
.SYNOPSIS
    Fuehrt eine explizite, UI-taugliche Workflow-Aktion aus.
.DESCRIPTION
    Der Befehl ist der schmale, nicht interaktive Adapter fuer die lokale
    Workflow-Oberflaeche. Gastpasswoerter dienen nur dem unmittelbaren Aufruf
    und werden weder in Build-State noch Log-Ausgabe gespeichert.
.PARAMETER Action
    Eindeutige, zulässige Workflow-Aktion.
.PARAMETER BuildId
Build-ID des vorhandenen Windows- oder SQL-Image-Builds.
.PARAMETER ArtifactId
Kennung eines veröffentlichten Hyper-V-Image-Registry-Eintrags, der nach
vorheriger Prüfung auf aktive Build-Referenzen entfernt werden soll.
.PARAMETER LabName
Sprechender Name einer regulären Hyper-V-Umgebung, die aus einem SQL-Prepared-
Image erzeugt wird.
.PARAMETER ManifestPath
Absoluter Zielpfad eines über die Workflow-UI zu erstellenden Container-Manifests.
.PARAMETER ManifestDescription
Optionale Beschreibung des über die Workflow-UI erstellten Container-Manifests.
.PARAMETER SourceVMName
Name einer vorhandenen, ausgeschalteten Hyper-V-VM. Sie wird nur als
unveränderte Quelle für eine run-lokale Arbeitskopie verwendet.
.PARAMETER SwitchName
Optionaler vorhandener virtueller Hyper-V-Switch für eine reguläre Hyper-V-
Umgebung. Ohne Angabe bleibt die VM bewusst isoliert.
.PARAMETER MediaRoot
    Externer Media Root für eine neue Windows- oder SQL-Vorbereitung.
.PARAMETER DataRoot
    Vorher initialisierter Data Root für optionale langlebige SQL-Daten.
.PARAMETER PersistentData
    Aktiviert die optionale Data-Root-Anbindung beim Erstellen einer Container-
    oder Hyper-V-Umgebung.
.PARAMETER PersistentDataDiskGB
    Größe der optionalen, langlebigen Hyper-V-Daten-VHDX in GB.
.PARAMETER OperatingSystemId
    Windows-Server-Version eines neu anzulegenden Builds.
.PARAMETER WindowsMediaPath
    Relativer Pfad einer automatisch erkannten Windows-ISO innerhalb von MediaRoot.
.PARAMETER WindowsEdition
    Gewünschte Windows-Evaluation-Edition für einen neuen Build.
.PARAMETER InstallationType
    Core oder Desktop Experience für einen neuen Build.
.PARAMETER SqlVersion
    Zielversion für ein neues SQL-Prepared-Image.
.PARAMETER SqlEdition
    Edition des SQL-Installationsmediums.
.PARAMETER SqlMediaPath
    Relativer Pfad einer automatisch erkannten SQL-ISO innerhalb von MediaRoot.
.PARAMETER WindowsMediaSha256
Offizieller SHA-256 der ausgewählten Windows-ISO; wird vor dem Speichern gegen
die lokale Datei geprüft.
.PARAMETER SqlMediaSha256
Offizieller SHA-256 der ausgewählten SQL-ISO; wird vor dem Speichern gegen die
lokale Datei geprüft.
.PARAMETER ImageName
    Optionaler frei wählbarer Anzeigename für ein neu zu erstellendes
    SQL-Prepared-Image.
.PARAMETER DisplayName
    Neuer Anzeigename eines bereits veröffentlichten Hyper-V-Images.
.PARAMETER Provider
    Docker oder Podman für eine neue Container-Lab-Umgebung.
.PARAMETER Profile
    Ressourcenprofil der neuen Container-Lab-Umgebung.
.PARAMETER InstanceId
    Sprechender Instanzname innerhalb einer Container-Lab-Umgebung.
.PARAMETER SaPassword
    Nicht persistiertes SA-Passwort für Containeraktionen.
.PARAMETER HostName
    SQL-Host für Datenbank- oder Skriptaktionen; Standard ist 127.0.0.1.
.PARAMETER Port
    Lokaler SQL-Port für Datenbank- oder Skriptaktionen.
.PARAMETER DatabaseName
    Name einer neu anzulegenden Datenbank.
.PARAMETER SampleId
    Katalog-ID einer ausgewählten Testdatenbank für einen Container-Run.
.PARAMETER SampleVariant
    Ausführbare Katalogvariante der ausgewählten Testdatenbank.
.PARAMETER SampleSelections
    Mehrere Katalogvarianten im Format `sampleId:variant`, die nacheinander in
    eine bereits laufende Container-Instanz installiert werden.
.PARAMETER TrustUnknownSample
    Bestätigt einmalig den Download einer Katalogvariante ohne bekannte
    SHA-256. Der ermittelte Fingerprint wird danach lokal an die Variante
    gebunden und bei späteren Installationen erneut geprüft.
.PARAMETER SampleSha256
Optionaler offizieller SHA-256 für eine Testdatenbank ohne Katalog-Prüfsumme.
Ist er angegeben, wird der Download strikt dagegen verifiziert.
.PARAMETER ScriptPath
    Absoluter Pfad zum auszuführenden SQL-Skript.
.PARAMETER Database
    Zieldatenbank einer Skriptausführung.
.PARAMETER GuestUserName
    Lokaler Administratorname im Gast für PowerShell Direct.
.PARAMETER GuestPassword
    Nicht persistiertes Gastpasswort für PowerShell Direct, etwa beim SQL
    CompleteImage in einer laufenden Hyper-V-Lab-VM.
.PARAMETER EvaluationExpiresAt
    Ablaufdatum, das beim Veröffentlichen eines Evaluation-Images gespeichert wird.
.PARAMETER MemoryStartupMB
    Startspeicher der neu anzulegenden VM in MB.
.PARAMETER ProcessorCount
Anzahl virtueller Prozessoren der neu anzulegenden VM.
.PARAMETER ConfirmSourceLicense
Bestätigt bewusst den Lizenz- und möglichen Ablaufhinweis, bevor aus einer
vorhandenen Windows-VM eine neue differenzierende Lab-VM erzeugt wird.
.PARAMETER OsDiskSizeGB
    Größe der Systemdisk einer neu anzulegenden VM in GB.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Liefert die Aktion, den
    Abschlusszeitpunkt und das Ergebnis des bestehenden Fachbefehls.
.EXAMPLE
    Invoke-SqlServerLabWorkflowAction -Action NewSqlBuild -MediaRoot D:\Lab_Base -SqlVersion 2022
#>
function Invoke-SqlServerLabWorkflowAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'Refresh',
            'SetMediaRoot', 'SetDataRoot',
            'NewContainerLab', 'CreateContainerManifest', 'NewContainerLabFromManifest', 'RenameLab', 'StartContainerLab', 'StopContainerLab', 'RestartContainerLab', 'RemoveContainerLab', 'ClearAllLabs',
            'CreateContainerDatabase', 'InstallContainerSampleDatabase', 'InstallContainerSampleDatabases', 'ExecuteContainerScript',
            'NewHyperVLab', 'NewHyperVLabFromExistingVm', 'StartHyperVLab', 'StopHyperVLab', 'EnableHyperVLabPersistentData', 'InitializeHyperVLabPersistentData', 'CompleteHyperVLabSql', 'InspectHyperVLabSqlInstances', 'OpenHyperVConsole', 'RemoveHyperVLab',
            'NewWindowsBuild', 'SetWindowsMediaHash', 'OpenWindowsConsole', 'ConfirmWindowsInstall', 'GeneralizeWindowsBuild', 'PublishWindowsBuild',
            'NewSqlBuild', 'NewSqlBuildFromBaseline', 'SetSqlMediaHash', 'OpenSqlConsole', 'ConfirmSqlWindowsInstall', 'PrepareSqlImage', 'ResumeSqlImage', 'PublishSqlImage',
            'RunSqlAcceptanceSetup', 'RunSqlAcceptanceTests',
            'CleanupWindowsBuild', 'CleanupSqlBuild', 'RenameHyperVImageArtifact', 'RemoveHyperVImageArtifact'
        )]
        [string]$Action,
        [string]$BuildId,
        [string]$ArtifactId,
        [string]$LabName,
        [string]$ManifestPath,
        [string]$ManifestDescription,
        [string]$SourceVMName,
        [string]$SwitchName,
        [string]$MediaRoot,
        [string]$DataRoot,
        [switch]$PersistentData,
        [ValidateRange(32, 4096)][int]$PersistentDataDiskGB = 128,
        [ValidatePattern('^windows-(server-)?[0-9]+$')][string]$OperatingSystemId = 'windows-server-2025',
        [string]$WindowsMediaPath,
        [ValidatePattern('^[a-z0-9-]+$')][string]$WindowsEdition = 'standard-evaluation',
        [ValidateSet('core', 'desktop-experience')][string]$InstallationType = 'desktop-experience',
        [string]$SqlVersion = '2022',
        [ValidateSet('Eval', 'Enterprise', 'Standard')][string]$SqlEdition = 'Eval',
        [string]$SqlMediaPath,
        [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$WindowsMediaSha256,
        [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$SqlMediaSha256,
        [ValidateLength(1, 80)][string]$ImageName,
        [ValidateLength(1, 80)][string]$DisplayName,
        [ValidateSet('docker', 'podman')][string]$Provider = 'docker',
        [ValidateSet('compact', 'standard', 'performance')][string]$Profile = 'standard',
        [string]$InstanceId = 'primary',
        [SecureString]$SaPassword,
        [string]$HostName = '127.0.0.1',
        [int]$Port,
        [string]$DatabaseName,
        [string]$SampleId,
        [string]$SampleVariant,
        [string[]]$SampleSelections,
        [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$SampleSha256,
        [switch]$TrustUnknownSample,
        [string]$ScriptPath,
        [string]$Database = 'master',
        [string]$GuestUserName = 'Administrator',
        [SecureString]$GuestPassword,
        [Nullable[datetime]]$EvaluationExpiresAt,
        [ValidateRange(2, 1048576)][int]$MemoryStartupMB = 4096,
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [switch]$ConfirmSourceLicense,
        [ValidateRange(32, 1048576)][int]$OsDiskSizeGB = 80
    )

    if ($Action -eq 'Refresh') {
        return [PSCustomObject]@{
            Action = $Action
            CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
            Result = Get-SqlServerLabWorkflow
        }
    }

    if ($Action -eq 'SetMediaRoot') {
        if (-not $MediaRoot -or -not (Test-Path -LiteralPath $MediaRoot -PathType Container)) {
            throw 'HYPERV_WORKFLOW_MEDIA_ROOT_REQUIRED'
        }
        return [PSCustomObject]@{
            Action = $Action
            CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
            Result = [PSCustomObject]@{ MediaRoot = (Set-LabMediaRootDefault -MediaRoot $MediaRoot) }
        }
    }

    if ($Action -eq 'SetDataRoot') {
        if (-not $DataRoot -or -not (Test-Path -LiteralPath $DataRoot -PathType Container)) {
            throw 'LAB_DATA_ROOT_REQUIRED'
        }
        return [PSCustomObject]@{
            Action = $Action
            CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
            Result = [PSCustomObject]@{ DataRoot = (Set-LabDataRootDefault -DataRoot $DataRoot) }
        }
    }

    $containerActions = @(
        'NewContainerLab', 'CreateContainerManifest', 'NewContainerLabFromManifest', 'RenameLab', 'StartContainerLab', 'StopContainerLab', 'RestartContainerLab', 'RemoveContainerLab',
        'ClearAllLabs', 'CreateContainerDatabase', 'InstallContainerSampleDatabase', 'InstallContainerSampleDatabases', 'ExecuteContainerScript'
    )
    if ($Action -notin $containerActions) {
        if (-not $IsWindows) { throw 'HYPERV_WORKFLOW_WINDOWS_HOST_REQUIRED' }
        $availability = Test-HyperVAvailable
        if (-not $availability.Available) { throw "HYPERV_WORKFLOW_UNAVAILABLE: $($availability.Message)" }
    }

    $credential = $null
    $credentialRequired = $Action -in @('ConfirmWindowsInstall', 'ConfirmSqlWindowsInstall', 'PrepareSqlImage', 'CompleteHyperVLabSql', 'InspectHyperVLabSqlInstances', 'InitializeHyperVLabPersistentData')
    if ($Action -eq 'GeneralizeWindowsBuild') {
        $existingWindowsBuild = Get-HyperVImageBuildPlan -BuildId $BuildId
        $credentialRequired = $existingWindowsBuild -and [string]$existingWindowsBuild.state -eq 'MANUAL_ACTION_REQUIRED'
    }
    if ($credentialRequired) {
        if (-not $GuestPassword) { throw 'HYPERV_WORKFLOW_GUEST_PASSWORD_REQUIRED' }
        $credential = [PSCredential]::new($GuestUserName, $GuestPassword)
    }
    if ($Action -in @('NewContainerLab', 'NewContainerLabFromManifest', 'CreateContainerDatabase', 'InstallContainerSampleDatabase', 'InstallContainerSampleDatabases', 'ExecuteContainerScript') -and -not $SaPassword) {
        throw 'CONTAINER_WORKFLOW_SA_PASSWORD_REQUIRED'
    }
    if ($Action -eq 'RemoveHyperVImageArtifact' -and [string]::IsNullOrWhiteSpace($ArtifactId)) {
        throw 'HYPERV_WORKFLOW_ARTIFACT_ID_REQUIRED'
    }
    if ($Action -eq 'RenameHyperVImageArtifact' -and ([string]::IsNullOrWhiteSpace($ArtifactId) -or [string]::IsNullOrWhiteSpace($DisplayName))) {
        throw 'HYPERV_WORKFLOW_ARTIFACT_AND_DISPLAY_NAME_REQUIRED'
    }
    if ($Action -eq 'RenameLab' -and ([string]::IsNullOrWhiteSpace($BuildId) -or [string]::IsNullOrWhiteSpace($LabName))) {
        throw 'LAB_WORKFLOW_RUN_AND_NAME_REQUIRED'
    }
    if ($Action -eq 'NewHyperVLab' -and ([string]::IsNullOrWhiteSpace($ArtifactId) -or [string]::IsNullOrWhiteSpace($LabName))) {
        throw 'HYPERV_LAB_ARTIFACT_AND_NAME_REQUIRED'
    }
    if ($Action -eq 'NewHyperVLabFromExistingVm' -and ([string]::IsNullOrWhiteSpace($SourceVMName) -or [string]::IsNullOrWhiteSpace($LabName))) {
        throw 'HYPERV_EXISTING_VM_SOURCE_AND_NAME_REQUIRED'
    }

    if (($PersistentData -and $Action -in @('NewHyperVLab', 'NewHyperVLabFromExistingVm')) -or $Action -eq 'EnableHyperVLabPersistentData') {
        if (-not $DataRoot) { $DataRoot = Get-LabDataRootDefault }
        if (-not $DataRoot) { throw 'LAB_DATA_ROOT_REQUIRED: Persistente Hyper-V-Daten benötigen einen konfigurierten Data Root.' }
        $DataRoot = Set-LabDataRootDefault -DataRoot $DataRoot
    }

    if ($Action -in @('NewWindowsBuild', 'NewSqlBuild', 'NewSqlBuildFromBaseline', 'SetWindowsMediaHash', 'SetSqlMediaHash')) {
        if (-not $MediaRoot) { $MediaRoot = Get-LabMediaRootDefault }
        if (-not $MediaRoot) { throw 'HYPERV_WORKFLOW_MEDIA_ROOT_REQUIRED' }
        $MediaRoot = Set-LabMediaRootDefault -MediaRoot $MediaRoot
    }

    $progress = switch ($Action) {
        'NewHyperVLab' { 'Validierung und Erstellung der Hyper-V-Umgebung werden vorbereitet.' }
        'NewHyperVLabFromExistingVm' { 'Die Quell-VM wird geprüft; danach wird eine geschützte Arbeitskopie für die neue Lab-VM erstellt.' }
        'StartHyperVLab' { 'Der sichtbare Start der Hyper-V-VM wird vorbereitet.' }
        'StopHyperVLab' { 'Der saubere Stopp der Hyper-V-VM wird vorbereitet.' }
        'OpenHyperVConsole' { 'VMConnect wird vorbereitet.' }
        'CompleteHyperVLabSql' { 'SQL Server wird mit CompleteImage in der laufenden Lab-VM vervollständigt.' }
        'EnableHyperVLabPersistentData' { 'Eine langlebige Daten-VHDX wird für die ausgeschaltete Lab-VM vorbereitet.' }
        'InitializeHyperVLabPersistentData' { 'Der langlebige Daten-VHDX wird einmalig im laufenden Gast initialisiert.' }
        'InspectHyperVLabSqlInstances' { 'SQL-Instanzen, Dienste und TCP-Ports werden ausschließlich lesend in der laufenden Lab-VM geprüft.' }
        'ConfirmSqlWindowsInstall' { 'Die manuell installierte Windows-Edition wird vor dem SQL-Setup geprüft.' }
        'NewSqlBuild' { 'Windows- und SQL-Medien werden für den Build geprüft.' }
        'NewSqlBuildFromBaseline' { 'OS-Baseline und SQL-Medium werden für einen differenzierenden SQL-Builder geprüft.' }
        'SetWindowsMediaHash' { 'Der eingegebene Windows-ISO-Hash wird geprüft und gespeichert.' }
        'SetSqlMediaHash' { 'Der eingegebene SQL-ISO-Hash wird geprüft und gespeichert.' }
        'NewWindowsBuild' { 'Windows-Installationsmedium wird für den Build geprüft.' }
        default { "Aktion $Action wird ausgeführt." }
    }
    Write-LabInfo "Auftrag angenommen: $progress"
    $result = switch ($Action) {
        'NewContainerLab' {
            New-SqlServerLab -Version $SqlVersion -Provider $Provider -Profile $Profile -InstanceId $InstanceId -LabName $LabName -DataRoot $DataRoot -PersistentData:$PersistentData -SaPassword $SaPassword
        }
        'CreateContainerManifest' {
            if ([string]::IsNullOrWhiteSpace($ManifestPath) -or [string]::IsNullOrWhiteSpace($LabName)) { throw 'CONTAINER_WORKFLOW_MANIFEST_PATH_AND_NAME_REQUIRED' }
            $draft = [ordered]@{
                name = $LabName
                description = if ($ManifestDescription) { $ManifestDescription } else { 'Über die lokale SQL Server Lab Workflow-UI erstellt.' }
                instances = @([ordered]@{ id = $InstanceId; version = $SqlVersion; provider = $Provider; profile = $Profile })
            }
            $manifest = New-SqlServerLabManifest -Path $ManifestPath -InputObject $draft -PassThru
            [PSCustomObject]@{ Path = [IO.Path]::GetFullPath($ManifestPath); Name = $manifest.name; InstanceCount = @($manifest.instances).Count }
        }
        'NewContainerLabFromManifest' {
            if ([string]::IsNullOrWhiteSpace($ManifestPath) -or -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw 'CONTAINER_WORKFLOW_MANIFEST_PATH_REQUIRED' }
            New-SqlServerLab -Manifest $ManifestPath -SaPassword $SaPassword
        }
        'RenameLab' { Rename-LabRunDisplayName -RunId $BuildId -DisplayName $LabName }
        'NewHyperVLab' {
            $lab = New-HyperVLabEnvironment -ArtifactId $ArtifactId -LabName $LabName -InstanceId $InstanceId -MemoryStartupMB $MemoryStartupMB -ProcessorCount $ProcessorCount -SwitchName $SwitchName
            if ($PersistentData) { $null = Enable-HyperVLabPersistentData -RunId $lab.RunId -DataRoot $DataRoot -SizeGB $PersistentDataDiskGB }
            $lab
        }
        'NewHyperVLabFromExistingVm' {
            $lab = New-HyperVLabEnvironmentFromExistingVm -SourceVMName $SourceVMName -LabName $LabName -InstanceId $InstanceId -MemoryStartupMB $MemoryStartupMB -ProcessorCount $ProcessorCount -SwitchName $SwitchName -ConfirmSourceLicense:$ConfirmSourceLicense
            if ($PersistentData) { $null = Enable-HyperVLabPersistentData -RunId $lab.RunId -DataRoot $DataRoot -SizeGB $PersistentDataDiskGB }
            $lab
        }
        'StartHyperVLab' { Start-HyperVLabEnvironment -RunId $BuildId }
        'StopHyperVLab' { Stop-HyperVLabEnvironment -RunId $BuildId }
        'EnableHyperVLabPersistentData' { Enable-HyperVLabPersistentData -RunId $BuildId -DataRoot $DataRoot -SizeGB $PersistentDataDiskGB }
        'InitializeHyperVLabPersistentData' { Initialize-HyperVLabPersistentData -RunId $BuildId -Credential $credential }
        'CompleteHyperVLabSql' { Complete-HyperVLabSqlImage -RunId $BuildId -Credential $credential }
        'InspectHyperVLabSqlInstances' { Inspect-HyperVLabSqlInstances -RunId $BuildId -Credential $credential }
        'OpenHyperVConsole' { Open-HyperVLabEnvironmentConsole -RunId $BuildId }
        'RemoveHyperVLab' { Remove-SqlServerLab -RunId $BuildId -Force -Confirm:$false }
        'StartContainerLab' { Start-SqlServerLab -RunId $BuildId }
        'StopContainerLab' { Stop-SqlServerLab -RunId $BuildId -Force -Confirm:$false }
        'RestartContainerLab' { Restart-SqlServerLab -RunId $BuildId -Force -Confirm:$false }
        'RemoveContainerLab' { Remove-SqlServerLab -RunId $BuildId -Force -Confirm:$false }
        'ClearAllLabs' { Clear-SqlServerLab -Force }
        'CreateContainerDatabase' {
            if ($Port -lt 1 -or -not $DatabaseName) { throw 'CONTAINER_WORKFLOW_DATABASE_TARGET_REQUIRED' }
            New-SqlServerLabDatabase -HostName $HostName -Port $Port -SaPassword $SaPassword -DatabaseName $DatabaseName
        }
        'InstallContainerSampleDatabase' {
            if (-not $BuildId -or -not $SampleId -or -not $SampleVariant) { throw 'CONTAINER_WORKFLOW_SAMPLE_TARGET_REQUIRED' }
            $target = Resolve-LabRunInstance -RunId $BuildId -InstanceId $InstanceId
            $sample = Get-LabSampleDatabase -Id $SampleId
            if (-not $sample) { throw "CONTAINER_WORKFLOW_SAMPLE_NOT_FOUND: $SampleId" }
            $variant = @($sample.versions.PSObject.Properties | Where-Object Name -eq $SampleVariant | Select-Object -First 1)
            if ($variant.Count -ne 1) { throw "CONTAINER_WORKFLOW_SAMPLE_VARIANT_NOT_FOUND: ${SampleId}:$SampleVariant" }
            $expectedOutputs = @($variant[0].Value.expectedOutputs)
            if ($expectedOutputs.Count -ne 1 -or -not $expectedOutputs[0].name) { throw "CONTAINER_WORKFLOW_SAMPLE_OUTPUT_INVALID: ${SampleId}:$SampleVariant" }
            $restoreDefinition = Resolve-LabSampleRestore -SampleDefinition ([PSCustomObject]@{ id = $SampleId; variant = $SampleVariant }) -SqlVersion $target.Version -TargetDatabaseName ([string]$expectedOutputs[0].name)
            if ($SampleSha256) { $restoreDefinition | Add-Member -NotePropertyName expectedSha256 -NotePropertyValue $SampleSha256.ToLowerInvariant() -Force }
            $localStatus = Get-LabSampleArtifactLocalStatus -Source $restoreDefinition.source -SampleId $restoreDefinition.sampleId -SampleVariant $restoreDefinition.sampleVariant -ExpectedSha256 $restoreDefinition.expectedSha256
            if (-not $localStatus.KnownSha256 -and -not $TrustUnknownSample) { throw 'CONTAINER_WORKFLOW_SAMPLE_TRUST_REQUIRED: Unbekannte SHA-256 muss vor dem Download ausdrücklich bestätigt werden.' }
            $runDirectory = Join-Path (Join-Path (Get-LabStateRoot) 'runs') $BuildId
            $sampleResult = Install-LabSampleDatabase -HostName $target.HostName -Port $target.Port -SaPassword $SaPassword -ContainerName $target.ContainerName -RestoreDefinition $restoreDefinition -TrustUnknownArtifact:$TrustUnknownSample -RunDirectory $runDirectory
            if (-not $sampleResult.Success) { throw "CONTAINER_WORKFLOW_SAMPLE_INSTALLATION_FAILED ($($sampleResult.Status)): $($sampleResult.Message)" }
            $sampleResult
        }
        'InstallContainerSampleDatabases' {
            if (-not $BuildId -or @($SampleSelections | Where-Object { $_ }).Count -eq 0) { throw 'CONTAINER_WORKFLOW_SAMPLE_TARGET_REQUIRED' }
            $target = Resolve-LabRunInstance -RunId $BuildId -InstanceId $InstanceId
            $runDirectory = Join-Path (Join-Path (Get-LabStateRoot) 'runs') $BuildId
            $results = @()
            foreach ($selection in @($SampleSelections | Where-Object { $_ })) {
                $parts = ([string]$selection).Split(':', 2)
                if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { throw "CONTAINER_WORKFLOW_SAMPLE_SELECTION_INVALID: $selection" }
                $sample = Get-LabSampleDatabase -Id $parts[0]
                if (-not $sample) { throw "CONTAINER_WORKFLOW_SAMPLE_NOT_FOUND: $($parts[0])" }
                $variant = @($sample.versions.PSObject.Properties | Where-Object Name -eq $parts[1] | Select-Object -First 1)
                if ($variant.Count -ne 1) { throw "CONTAINER_WORKFLOW_SAMPLE_VARIANT_NOT_FOUND: $selection" }
                $expectedOutputs = @($variant[0].Value.expectedOutputs)
                if ($expectedOutputs.Count -ne 1 -or -not $expectedOutputs[0].name) { throw "CONTAINER_WORKFLOW_SAMPLE_OUTPUT_INVALID: $selection" }
                $restoreDefinition = Resolve-LabSampleRestore -SampleDefinition ([PSCustomObject]@{ id = $parts[0]; variant = $parts[1] }) -SqlVersion $target.Version -TargetDatabaseName ([string]$expectedOutputs[0].name)
                $localStatus = Get-LabSampleArtifactLocalStatus -Source $restoreDefinition.source -SampleId $restoreDefinition.sampleId -SampleVariant $restoreDefinition.sampleVariant -ExpectedSha256 $restoreDefinition.expectedSha256
                if (-not $localStatus.KnownSha256 -and -not $TrustUnknownSample) { throw "CONTAINER_WORKFLOW_SAMPLE_TRUST_REQUIRED: $selection" }
                $sampleResult = Install-LabSampleDatabase -HostName $target.HostName -Port $target.Port -SaPassword $SaPassword -ContainerName $target.ContainerName -RestoreDefinition $restoreDefinition -TrustUnknownArtifact:$TrustUnknownSample -RunDirectory $runDirectory
                if (-not $sampleResult.Success) { throw "CONTAINER_WORKFLOW_SAMPLE_INSTALLATION_FAILED ($($sampleResult.Status)): $($sampleResult.Message)" }
                $results += $sampleResult
            }
            @($results)
        }
        'ExecuteContainerScript' {
            if ($Port -lt 1 -or -not $ScriptPath) { throw 'CONTAINER_WORKFLOW_SCRIPT_TARGET_REQUIRED' }
            Invoke-SqlServerLabScript -ScriptPath $ScriptPath -HostName $HostName -Port $Port -SaPassword $SaPassword -Database $Database
        }
        'NewWindowsBuild' {
            if (-not $WindowsMediaPath) { throw 'HYPERV_WORKFLOW_WINDOWS_MEDIA_REQUIRED' }
            $windowsMedia = Resolve-HyperVWindowsInstallationMedia -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -WindowsMediaPath $WindowsMediaPath -WindowsEdition $WindowsEdition -InstallationType $InstallationType
            if ($windowsMedia.HashStatus -ne 'SIDECAR_READY' -and $WindowsMediaSha256) { $null = Set-HyperVWindowsMediaHashSidecar -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -WindowsMediaPath $WindowsMediaPath -WindowsEdition $WindowsEdition -InstallationType $InstallationType -ExpectedSha256 $WindowsMediaSha256 }
            Initialize-HyperVWindowsImageBuild -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -Edition $WindowsEdition -InstallationType $InstallationType -WindowsMediaPath $WindowsMediaPath -LicenseType evaluation -MemoryStartupBytes ($MemoryStartupMB * 1MB) -ProcessorCount $ProcessorCount -OsDiskSizeBytes ($OsDiskSizeGB * 1GB)
        }
        'SetWindowsMediaHash' {
            if (-not $WindowsMediaPath) { throw 'HYPERV_WORKFLOW_WINDOWS_MEDIA_REQUIRED' }
            if ($WindowsMediaSha256) {
                Set-HyperVWindowsMediaHashSidecar -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -WindowsMediaPath $WindowsMediaPath -WindowsEdition $WindowsEdition -InstallationType $InstallationType -ExpectedSha256 $WindowsMediaSha256
            }
            else {
                New-HyperVWindowsMediaHashSidecar -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -WindowsMediaPath $WindowsMediaPath -WindowsEdition $WindowsEdition -InstallationType $InstallationType -Confirm:$false
            }
        }
        'OpenWindowsConsole' {
            $build = Get-HyperVImageBuildPlan -BuildId $BuildId
            if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
            if ((Get-VM -Name $build.builder.vmName -ErrorAction Stop).State -eq 'Off') {
                $null = Start-HyperVWindowsImageBuildVM -BuildId $BuildId
            }
            Start-LabVmConnect -VMName ([string]$build.builder.vmName)
        }
        'ConfirmWindowsInstall' { Confirm-HyperVWindowsImageInstallation -BuildId $BuildId -Credential $credential }
        'GeneralizeWindowsBuild' { Invoke-HyperVWindowsImageGeneralization -BuildId $BuildId -Credential $credential }
        'PublishWindowsBuild' { Publish-HyperVWindowsImageBuild -BuildId $BuildId -EvaluationExpiresAt $EvaluationExpiresAt }
        'NewSqlBuild' {
            if ($OperatingSystemId -ne 'windows-server-2025') { throw 'HYPERV_WORKFLOW_SQL_PREPARED_REQUIRES_WINDOWS_SERVER_2025' }
            if (-not $SqlMediaPath) { throw 'HYPERV_WORKFLOW_SQL_MEDIA_REQUIRED' }
            $windowsMedia = Resolve-HyperVWindowsInstallationMedia -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -WindowsMediaPath $WindowsMediaPath -WindowsEdition $WindowsEdition -InstallationType $InstallationType
            if ($windowsMedia.HashStatus -ne 'SIDECAR_READY' -and $WindowsMediaSha256) { $null = Set-HyperVWindowsMediaHashSidecar -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -WindowsMediaPath $WindowsMediaPath -WindowsEdition $WindowsEdition -InstallationType $InstallationType -ExpectedSha256 $WindowsMediaSha256 }
            $sqlMedia = Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $SqlEdition -SqlMediaPath $SqlMediaPath
            if ($sqlMedia.HashStatus -ne 'SIDECAR_READY' -and $SqlMediaSha256) { $null = Set-HyperVSqlMediaHashSidecar -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $SqlEdition -SqlMediaPath $SqlMediaPath -ExpectedSha256 $SqlMediaSha256 }
            Initialize-HyperVSqlFreshPreparedImageBuild -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -WindowsEdition $WindowsEdition -InstallationType $InstallationType -WindowsMediaPath $WindowsMediaPath -SqlVersion $SqlVersion -MediaEdition $SqlEdition -SqlMediaPath $SqlMediaPath -ImageName $ImageName -MemoryStartupBytes ($MemoryStartupMB * 1MB) -ProcessorCount $ProcessorCount -OsDiskSizeBytes ($OsDiskSizeGB * 1GB)
        }
        'NewSqlBuildFromBaseline' {
            if (-not $ArtifactId) { throw 'HYPERV_WORKFLOW_OS_BASELINE_REQUIRED' }
            if (-not $SqlMediaPath) { throw 'HYPERV_WORKFLOW_SQL_MEDIA_REQUIRED' }
            $sqlMedia = Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $SqlEdition -SqlMediaPath $SqlMediaPath
            if ($sqlMedia.HashStatus -ne 'SIDECAR_READY' -and $SqlMediaSha256) { $null = Set-HyperVSqlMediaHashSidecar -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $SqlEdition -SqlMediaPath $SqlMediaPath -ExpectedSha256 $SqlMediaSha256 }
            Initialize-HyperVSqlPreparedImageBuild -MediaRoot $MediaRoot -ImageArtifactId $ArtifactId -SqlVersion $SqlVersion -MediaEdition $SqlEdition -SqlMediaPath $SqlMediaPath -ImageName $ImageName -MemoryStartupBytes ($MemoryStartupMB * 1MB) -ProcessorCount $ProcessorCount
        }
        'SetSqlMediaHash' {
            if (-not $SqlMediaPath) { throw 'HYPERV_WORKFLOW_SQL_MEDIA_REQUIRED' }
            if ($SqlMediaSha256) {
                Set-HyperVSqlMediaHashSidecar -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $SqlEdition -SqlMediaPath $SqlMediaPath -ExpectedSha256 $SqlMediaSha256
            }
            else {
                New-HyperVSqlMediaHashSidecar -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $SqlEdition -SqlMediaPath $SqlMediaPath -Confirm:$false
            }
        }
        'OpenSqlConsole' {
            $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId
            if (-not $build) { throw 'HYPERV_SQL_IMAGE_BUILD_NOT_FOUND' }
            if ((Get-VM -Name $build.builder.vmName -ErrorAction Stop).State -eq 'Off') {
                $null = Start-HyperVSqlImageBuildVM -BuildId $BuildId
            }
            Start-LabVmConnect -VMName ([string]$build.builder.vmName)
        }
        'ConfirmSqlWindowsInstall' {
            $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId
            if (-not $build) { throw 'HYPERV_SQL_IMAGE_BUILD_NOT_FOUND' }
            Confirm-HyperVSqlFreshWindowsInstallation -Build $build -Credential $credential
        }
        'PrepareSqlImage' { Invoke-HyperVSqlPrepareAndGeneralize -BuildId $BuildId -Credential $credential }
        'ResumeSqlImage' { Resume-HyperVSqlPreparedImageGeneralization -BuildId $BuildId }
        'PublishSqlImage' { Publish-HyperVSqlPreparedImageBuild -BuildId $BuildId -EvaluationExpiresAt $EvaluationExpiresAt }
        'RunSqlAcceptanceSetup' {
            $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId
            if (-not $build) { throw 'HYPERV_SQL_IMAGE_BUILD_NOT_FOUND' }
            if ([string]$build.provisioningMode -eq 'fresh-windows-media') {
                throw 'HYPERV_SQL_ACCEPTANCE_REQUIRES_TEST_ENVIRONMENT_BUILD'
            }
            if ([string]$build.state -in @('MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING')) {
                $build = Invoke-HyperVSqlUnattendedOobe -BuildId $BuildId
            }
            $credential = Get-HyperVSqlGuestCredential -Build $build
            $saPassword = Get-LabSecret -Path $build.BuildDirectory -Name 'sa-password'
            if (-not $saPassword) { $saPassword = New-HyperVSqlUnattendedPassword }
            Invoke-HyperVSqlTestEnvironmentInstall -BuildId $BuildId -Credential $credential -SaPassword $saPassword
        }
        'RunSqlAcceptanceTests' {
            $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId
            if (-not $build) { throw 'HYPERV_SQL_IMAGE_BUILD_NOT_FOUND' }
            if ([string]$build.provisioningMode -eq 'fresh-windows-media') {
                throw 'HYPERV_SQL_ACCEPTANCE_REQUIRES_TEST_ENVIRONMENT_BUILD'
            }
            $credential = Get-HyperVSqlGuestCredential -Build $build
            $saPassword = Get-LabSecret -Path $build.BuildDirectory -Name 'sa-password'
            Test-HyperVSqlAcceptanceEnvironment -BuildId $BuildId -Credential $credential -SaPassword $saPassword
        }
        'CleanupWindowsBuild' { Remove-HyperVWindowsImageBuild -BuildId $BuildId }
        'CleanupSqlBuild' { Remove-HyperVSqlImageBuild -BuildId $BuildId }
        'RenameHyperVImageArtifact' { Rename-HyperVImageArtifact -ArtifactId $ArtifactId -DisplayName $DisplayName }
        'RemoveHyperVImageArtifact' { Remove-HyperVImageArtifact -ArtifactId $ArtifactId }
    }

    Write-LabSuccess "Fachaktion $Action abgeschlossen."
    [PSCustomObject]@{
        Action = $Action
        CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
        Result = $result
    }
}
