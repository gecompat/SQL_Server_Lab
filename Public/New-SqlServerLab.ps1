function Add-LabInstanceCleanupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)]$RunState,
        [AllowEmptyCollection()][object[]]$SoftwarePlans = @()
    )

    $labName = Resolve-LabRuntimeName -RunState $RunState
    $containerName = Get-LabContainerRuntimeName -LabName $labName -InstanceId ([string]$Instance.id) -RunId $RunState.RunId
    $softwareContract = if (@($SoftwarePlans).Count -gt 0) {
        [PSCustomObject]@{
            contract = [PSCustomObject]@{ name='SqlServerLab.SoftwareCleanupBinding'; version='1.0' }
            planKeys = @($SoftwarePlans.PlanKey | Where-Object { [string]$_ -match '^[a-f0-9]{64}$' } | Sort-Object -Unique)
            softwareIds = @($SoftwarePlans.SoftwareId | Sort-Object -Unique)
            artifactRetention = 'reusable-artifacts-retained'
        }
    }
    else {
        $null
    }

    foreach ($drive in @($Instance.drives | Where-Object {
        $_ -and $_.containerPath -and -not $_.hostPath -and
        $_.persistence -notin @('data-root-runtime-volume','cataloged-runtime-volume')
    })) {
        $volumeName = if ($drive.volumeName) { [string]$drive.volumeName } else { "sql-lab-${containerName}-$($drive.id)" }
        $null = Add-CleanupStep `
            -RunDir $RunState.RunDir `
            -ResourceType 'volume' `
            -ResourceId $volumeName `
            -Action 'remove' `
            -Provider $Instance.provider `
            -ProviderSubRunId "provider-$($Instance.provider)" `
            -SoftwareContract $softwareContract `
            -Compensation "$($Instance.provider) volume rm $volumeName"
    }

    # Der Container wird nach den Volumes eingetragen, damit die umgekehrte
    # Cleanup-Reihenfolge zuerst den Container und danach seine Volumes entfernt.
    $null = Add-CleanupStep `
        -RunDir $RunState.RunDir `
        -ResourceType 'container' `
        -ResourceId $containerName `
        -Action 'remove' `
        -Provider $Instance.provider `
        -ProviderSubRunId "provider-$($Instance.provider)" `
        -SoftwareContract $softwareContract `
        -Compensation "$($Instance.provider) rm -f $containerName"
}

function Resolve-LabRuntimeName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RunState
    )

    $candidate = [string]$RunState.metadata.name
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        return $candidate.Trim()
    }

    if ($RunState.RunId) {
        $safeRunId = ([string]$RunState.RunId).Replace('-', '')
        if ($safeRunId.Length -gt 8) {
            $safeRunId = $safeRunId.Substring(0, 8)
        }
        return "lab-$safeRunId"
    }

    return 'sql-server-lab'
}

function New-LabProviderContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [int]$Port = 0,
        $ContainerImageArtifact,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$')][string]$ContainerName,
        [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$')][string]$EndpointBindingIgnoreContainerName
    )

    $labName = Resolve-LabRuntimeName -RunState $RunState
    $resolvedImage = $null
    $externalRuntimeLaunchMode = 'none'
    if ($ContainerImageArtifact) {
        if (-not $ContainerImageArtifact.Contract -or
            [string]$ContainerImageArtifact.Contract.Name -ne 'SqlServerLab.ExternalRuntimeContainerImageArtifact' -or
            [string]$ContainerImageArtifact.Contract.Version -ne '1.0' -or
            [string]$ContainerImageArtifact.Provider -ne [string]$Instance.provider -or
            [string]$ContainerImageArtifact.ImageKey -notmatch '^[a-f0-9]{64}$' -or
            [string]$ContainerImageArtifact.LaunchMode -notin @('sql2019-namespace-v1','sql2022-namespace-v1','sql2025-namespace-v1') -or
            (@($ContainerImageArtifact.RequiredLinuxCapabilities) -join ',') -ne 'CHOWN,DAC_OVERRIDE,KILL,SETGID,SETUID,SYS_ADMIN,MKNOD,SETPCAP,NET_ADMIN,NET_RAW,SYS_PTRACE' -or
            (@($ContainerImageArtifact.RequiredSecurityOptions) -join ',') -ne 'apparmor=unconfined,seccomp=unconfined') {
            throw "EXTERNAL_RUNTIME_CONTAINER_IMAGE_ARTIFACT_INVALID: $($Instance.id)"
        }
        $resolvedImage = [string]$ContainerImageArtifact.Image
        $externalRuntimeLaunchMode = [string]$ContainerImageArtifact.LaunchMode
    }

    switch ($Instance.provider) {
        'docker' {
            return New-DockerInstance `
                -VersionId $Instance.version `
                -RunId $RunState.RunId `
                -ScopeId $RunState.ScopeId `
                -InstanceId $Instance.id `
                -LabName $labName `
                -ContainerName $ContainerName `
                -EndpointBindingIgnoreContainerName $EndpointBindingIgnoreContainerName `
                -Port $Port `
                -SaPassword $SaPassword `
                -Profile $Instance.profile `
                -Drives $Instance.drives `
                -NetworkName $Instance.networkName `
                -Cpu $Instance.runtimeResources.cpu `
                -MemoryMB $Instance.runtimeResources.memoryMB `
                -AutoStart $Instance.autostart `
                -Collation $Instance.collation `
                -ResolvedImage $resolvedImage `
                -ExternalRuntimeLaunchMode $externalRuntimeLaunchMode
        }
        'podman' {
            return New-PodmanInstance `
                -VersionId $Instance.version `
                -RunId $RunState.RunId `
                -ScopeId $RunState.ScopeId `
                -InstanceId $Instance.id `
                -LabName $labName `
                -ContainerName $ContainerName `
                -EndpointBindingIgnoreContainerName $EndpointBindingIgnoreContainerName `
                -Port $Port `
                -SaPassword $SaPassword `
                -Profile $Instance.profile `
                -Drives $Instance.drives `
                -NetworkName $Instance.networkName `
                -Cpu $Instance.runtimeResources.cpu `
                -MemoryMB $Instance.runtimeResources.memoryMB `
                -AutoStart $Instance.autostart `
                -Collation $Instance.collation `
                -ResolvedImage $resolvedImage `
                -ExternalRuntimeLaunchMode $externalRuntimeLaunchMode
        }
        default {
            throw "Provider '$($Instance.provider)' ist noch nicht implementiert."
        }
    }
}

function Remove-LabProviderContainerForReadinessRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Container,
        [Parameter(Mandatory)][string]$ScopeId
    )

    switch ([string]$Container.Provider) {
        'docker' { Remove-DockerInstance -ContainerIdOrName $Container.ContainerId -ExpectedScopeId $ScopeId }
        'podman' { Remove-PodmanInstance -ContainerIdOrName $Container.ContainerId -ExpectedScopeId $ScopeId }
        default { throw "Readiness-Retry ist für Provider '$($Container.Provider)' nicht unterstützt." }
    }
}

function New-SqlServerLab {
    <#
    .SYNOPSIS
        Erstellt eine neue SQL-Server-Testumgebung.
    .DESCRIPTION
        Provisioniert eine reproduzierbare SQL-Server-Labumgebung entweder aus
        direkten Parametern oder aus einer Manifestdatei. Das Cmdlet prueft
        Ressourcen, erzeugt Run-State und Cleanup-Plan, startet die Instanzen,
        wartet auf SQL-Bereitschaft und fuehrt konfigurierte Datenbank-, Restore-
        und Post-Provision-Schritte aus.
    .PARAMETER Version
        SQL-Server-Version aus dem Versionskatalog. Standard ist 2025. Zulassige
        Formate umfassen beispielsweise 2022, 2022-CU16 und exakte Katalog-Tags.
    .PARAMETER Provider
        Ausfuehrungsprovider. Standard ist docker. Docker und Podman sind
        implementiert; Hyper-V ist als Vertragswert vorbereitet.
    .PARAMETER Profile
        Ressourcenprofil compact, standard oder performance. Standard ist
        standard.
    .PARAMETER Port
        Host-Port der Ad-hoc-Instanz. Der Wert 0, zugleich der Standard, aktiviert
        die automatische Vergabe im konfigurierten Lab-Portbereich.
    .PARAMETER InstanceId
        Eindeutige ID der Ad-hoc-Instanz. Standard ist primary.
    .PARAMETER Sample
        Optionale Liste katalogisierter Testdatenbanken fuer die Ad-hoc-Instanz.
        Jeder Eintrag verwendet das Format 'sampleId' oder 'sampleId:variante',
        beispielsweise 'adventureworks-2022:lightweight'. Nur executable
        direkte Backups, sichere ZIP-Backups und einzelne SQL-Skript-Varianten
        aus Catalogs/sample-databases.json sind zulaessig; die Zieldatenbanknamen
        ergeben sich aus den erwarteten Katalog-Outputs.
    .PARAMETER Cpu
        Explizite Anzahl virtueller CPUs fuer die Ad-hoc-Instanz. Der Wert 0
        verwendet die Vorgabe des gewaehlten Ressourcenprofils.
    .PARAMETER MemoryMB
        Expliziter Arbeitsspeicher in MB fuer die Ad-hoc-Instanz. Der Wert 0
        verwendet die Vorgabe des gewaehlten Ressourcenprofils.
    .PARAMETER Collation
        SQL-Server-Collation der neuen Ad-hoc-Instanz. Standard ist
        SQL_Latin1_General_CP1_CI_AS.
    .PARAMETER ServerConfig
        Optionale typisierte SQL-Server-Konfiguration, beispielsweise fuer
        Max Server Memory, MAXDOP, Cost Threshold und TempDB-Dateien.
    .PARAMETER Drives
        Optionale Laufwerks- und Volume-Definitionen fuer Daten, Log,
        TempDB und Backups. Die Provider pruefen die jeweils unterstuetzten
        Pfade, Groessen und I/O-Grenzen.
    .PARAMETER NetworkName
        Optionaler Name des Docker-, Podman- oder Hyper-V-Netzes, an das die
        Ad-hoc-Instanz gebunden wird.
    .PARAMETER AutoStart
        `on` startet die verwaltete Ad-hoc-Instanz nach einem Host-Neustart
        automatisch. Docker und Podman verwenden Restart-Policies sowie bei
        Desktop-/Machine-Runtimes einen Host-Startkoordinator; Hyper-V verwendet
        die native AutomaticStartAction. Standard ist `off`.
    .PARAMETER Manifest
        Pfad zu einer vorhandenen JSON-Manifestdatei. Relative lokale Pfade im
        Manifest werden relativ zu deren Verzeichnis aufgeloest. Manifeste
        laufen standardmäßig unbeaufsichtigt; Passwörter werden über SecureString
        oder eng benannte externe Prozess-Umgebungsvariablen bereitgestellt.
    .PARAMETER SaPassword
        SA-Passwort als SecureString. Ohne Angabe wird es interaktiv abgefragt.
    .PARAMETER StateRoot
        Optionales State-Stammverzeichnis. Ohne Angabe wird der Framework-Default
        fuer das aktuelle Betriebssystem verwendet.
    .PARAMETER LabName
        Stabiler logischer Name eines Ad-hoc-Labs. Er bestimmt bei aktivierten
        persistenten Daten den Unterordner im Data Root.
    .PARAMETER DataRoot
        Optionaler, zuvor initialisierter langlebiger Data Root. Er wird nur
        bei PersistentData verwendet und nie vom normalen Run-Cleanup gelöscht.
    .PARAMETER PersistentData
        Bindet /var/opt/mssql der Docker- oder Podman-Instanz an einen
        katalogisierten langlebigen Runtime-Store; Backups bleiben im Data Root.
    .PARAMETER PersistentStorageId
        Optionale stabile ID eines detached Container-Instanzstores. Nur für
        eine einzelne Ad-hoc-Docker-/Podman-Instanz mit PersistentData.
    .PARAMETER PersistentStorageAction
        CONTINUE bindet denselben kompatiblen Store an den neuen Run. CLONE
        erstellt unter exklusiver Operations-Lease eine unabhängige Kopie und
        bindet ausschließlich das verifizierte Clone-Ziel.
    .PARAMETER GuestPassword
        Optionales lokales Administratorpasswort für eine Hyper-V-Manifest-
        Bereitstellung. Der Wert wird nur run-lokal DPAPI-geschützt abgelegt.
        Ohne Angabe folgt die sichere Passwortstrategie aus dem Manifest.
    .PARAMETER SqlSaPassword
        Optionales separates SQL-SA-Passwort für eine Hyper-V-Manifest-
        Bereitstellung. Es wird nie in das Manifest oder den Run-State geschrieben.
    .PARAMETER Region
        Zwei- oder vierstelliger Regions-Schlüssel für die Windows-OOBE
        (z. B. DE, DE-DE oder AT).
    .PARAMETER SystemLocale
        Windows-System-Locale für die OOBE-Konfiguration (z. B. de-DE).
    .PARAMETER UiLanguage
        Windows-UI-Language für die OOBE-Konfiguration (z. B. en-US).
    .PARAMETER InputLocale
        Keyboard Input Locale, z. B. 0407:00000407.
    .PARAMETER TimeZone
        Windows-Zeitzone für die OOBE-Konfiguration (z. B. W. Europe Standard
        Time).
    .PARAMETER NonInteractive
        Unterbindet Kennwortabfragen. Fehlende, erforderliche Secrets werden
        stattdessen mit einem klaren Fehler abgelehnt; gedacht für CI/CD und
        deklarative Manifestbereitstellungen.
    .PARAMETER AllowExpertHostWriteMounts
        Zweite, absichtliche Freigabe für im Manifest deklarierte schreibende
        beliebige Host-Mounts. Standard-Manifeste verwenden ausschließlich
        schreibgeschützte Host-Mounts, verwaltete Wegwerf-Volumes oder den
        expliziten Data Root.
    .PARAMETER SkipAssessment
        Ueberspringt das Resource Assessment vor der Provisionierung. Die
        spaeteren Provider- und SQL-Pruefungen bleiben aktiv.
    .OUTPUTS
        System.Management.Automation.PSCustomObject. Liefert RunId, State,
        StateRoot und die aufgeloesten Instanz- und Verbindungsinformationen.
    .EXAMPLE
        $lab = New-SqlServerLab -Version '2025' -Provider docker

        Erstellt eine einzelne Ad-hoc-Instanz mit den Standardwerten fuer Profil,
        Instanz-ID und automatische Portvergabe.
    .EXAMPLE
        $lab = New-SqlServerLab -Version '2022' -Provider docker -Sample 'adventureworks-2022:lightweight', 'wideworldimporters:standard'

        Erstellt eine Ad-hoc-Instanz und installiert zwei katalogisierte
        Testdatenbanken ueber den typisierten Sample-Handler. Fehlt eine bekannte
        SHA-256-Pruefsumme, fragt der Lauf einmalig nach Vertrauen.
    .EXAMPLE
        $env:SQL_SERVER_LAB_SECRET_SA_PASSWORD = '<aus Secret Store oder CI-Injection>'
        $lab = New-SqlServerLab -Manifest './Schemas/example-performance-lab.json'

        Validiert und provisioniert die im Manifest beschriebene Umgebung ohne
        Passwortabfrage. Das Manifest referenziert nur den Variablennamen, nie
        den Passwortwert.
    .EXAMPLE
        $lab = New-SqlServerLab -Version '2025' -Provider docker -LabName 'training' -PersistentData -DataRoot 'D:\Lab_Data'

        Erstellt ein Container-Lab, dessen SQL-System- und Datenbanken nach
        Entfernen des Container-Runs im Data Root erhalten bleiben.
    .NOTES
        Das Cmdlet veraendert Container-Runtime, Dateisystem und SQL Server. Der
        zurueckgegebene Run kann mit den SqlServerLab-Lifecycle-Commands verwaltet
        und mit Remove-SqlServerLab wieder entfernt werden.
    #>
    [CmdletBinding(DefaultParameterSetName = 'AdHoc')]
    param(
        [Parameter(ParameterSetName = 'AdHoc')]
        [string]$Version = '2025',

        [Parameter(ParameterSetName = 'AdHoc')]
        [ValidateSet('docker', 'podman', 'hyperv')]
        [string]$Provider = 'docker',

        [Parameter(ParameterSetName = 'AdHoc')]
        [ValidateSet('compact', 'standard', 'performance')]
        [string]$Profile = 'standard',

        [Parameter(ParameterSetName = 'AdHoc')]
        [int]$Port = 0,

        [Parameter(ParameterSetName = 'AdHoc')]
        [string]$InstanceId = 'primary',

        [Parameter(ParameterSetName = 'AdHoc')]
        [string[]]$Sample = @(),

        [Parameter(ParameterSetName = 'AdHoc')][ValidateRange(0, 64)][decimal]$Cpu = 0,
        [Parameter(ParameterSetName = 'AdHoc')][ValidateRange(0, 1048576)][int]$MemoryMB = 0,
        [Parameter(ParameterSetName = 'AdHoc')][ValidatePattern('^[A-Za-z0-9_]{1,128}$')][string]$Collation = 'SQL_Latin1_General_CP1_CI_AS',
        [Parameter(ParameterSetName = 'AdHoc')]$ServerConfig,
        [Parameter(ParameterSetName = 'AdHoc')][object[]]$Drives = @(),
        [Parameter(ParameterSetName = 'AdHoc')][string]$NetworkName,
        [Parameter(ParameterSetName = 'AdHoc')][ValidateSet('on', 'off')][string]$AutoStart = 'off',

        [Parameter(ParameterSetName = 'Manifest', Mandatory)]
        [string]$Manifest,

        [SecureString]$SaPassword,
        [string]$StateRoot,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')][string]$LabName,
        [string]$DataRoot,
        [switch]$PersistentData,
        [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$PersistentStorageId,
        [ValidateSet('CONTINUE','CLONE')][string]$PersistentStorageAction = 'CONTINUE',
        [SecureString]$GuestPassword,
        [SecureString]$SqlSaPassword,
        [ValidatePattern('^[A-Za-z]{2}(-[A-Za-z]{2})?$')][string]$Region = 'DE',
        [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')][string]$SystemLocale = 'de-DE',
        [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')][string]$UiLanguage = 'en-US',
        [ValidatePattern('^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}$')][string]$InputLocale = '0407:00000407',
        [string]$TimeZone = 'W. Europe Standard Time',
        [switch]$NonInteractive,
        [switch]$AllowExpertHostWriteMounts,
        [switch]$SkipAssessment
    )

    $ErrorActionPreference = 'Stop'
    Write-LabHeader 'SQL Server Lab - Neue Umgebung'

    if ($PSCmdlet.ParameterSetName -eq 'Manifest') {
        Write-LabInfo "Manifest: $Manifest"
        $resolved = Read-LabManifest -Path $Manifest

        $writeHostMounts = @(
            $resolved.instances | ForEach-Object {
                @($_.drives | Where-Object { $_.hostPath -and $_.readOnly -ne $true })
            }
        )
        if ($writeHostMounts.Count -gt 0 -and -not $AllowExpertHostWriteMounts) {
            throw 'LAB_MANIFEST_HOST_WRITE_EXPERT_ACTION_REQUIRED: Schreibende Host-Mounts benötigen zusätzlich -AllowExpertHostWriteMounts.'
        }
    }
    else {
        $sampleDatabases = @()
        $selectedSampleOutputs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($sampleSpec in @($Sample | Where-Object { $_ })) {
            $specParts = ([string]$sampleSpec).Split(':', 2)
            $sampleDefinition = [PSCustomObject]@{
                id      = $specParts[0].Trim()
                variant = if ($specParts.Count -gt 1 -and $specParts[1].Trim()) { $specParts[1].Trim() } else { 'full' }
            }

            $sampleArtifact = Resolve-LabSampleArtifact `
                -SampleDefinition $sampleDefinition `
                -SqlVersion $Version
            $targetDatabaseNames = @(
                $sampleArtifact.expectedOutputs |
                    Where-Object { $_.kind -eq 'database' } |
                    ForEach-Object { [string]$_.name }
            )
            if ($targetDatabaseNames.Count -eq 0 -or $targetDatabaseNames.Count -ne @($sampleArtifact.expectedOutputs).Count) {
                throw "SAMPLE_OUTPUTS_INVALID: '$sampleSpec' besitzt keine eindeutige Datenbank-Outputliste."
            }
            foreach ($outputName in $targetDatabaseNames) {
                if ($selectedSampleOutputs.Contains($outputName)) {
                    throw "SAMPLE_OUTPUT_CONFLICT: Die Auswahl erzeugt die Datenbank '$outputName' mehrfach."
                }
            }
            $targetDatabaseName = $targetDatabaseNames[0]
            $restoreDefinition = Resolve-LabSampleRestore `
                -SampleDefinition $sampleDefinition `
                -SqlVersion $Version `
                -TargetDatabaseName $targetDatabaseName
            foreach ($outputName in $targetDatabaseNames) { $null = $selectedSampleOutputs.Add($outputName) }

            $sampleDatabases += [PSCustomObject]@{
                name      = $targetDatabaseName
                collation = 'SQL_Latin1_General_CP1_CI_AS'
                options   = $null
                files     = $null
                restore   = $restoreDefinition
                sample    = $sampleDefinition
            }
        }

        $profileDefinition = Get-LabResourceProfile -Name $Profile
        $resolved = [PSCustomObject]@{
            name      = if ($LabName) { $LabName } else { "adhoc-$Version-$Provider" }
            instances = @(
                [PSCustomObject]@{
                    id            = $InstanceId
                    version       = $Version
                    provider      = $Provider
                    os            = 'linux'
                    profile       = $Profile
                    autostart     = $AutoStart
                    collation     = $Collation
                    databases     = $sampleDatabases
                    drives        = @($Drives)
                    serverConfig  = $ServerConfig
                    networkName   = $NetworkName
                    runtimeResources = [PSCustomObject]@{
                        cpu = if ($Cpu -gt 0) { $Cpu } else { [decimal]$profileDefinition.maxCpus }
                        memoryMB = if ($MemoryMB -gt 0) { $MemoryMB } else { [int]$profileDefinition.maxMemoryMB }
                    }
                    software      = @()
                    postProvision = @()
                }
            )
            resourceOverrides = $null
            manifestPath      = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$resolved.name)) {
        $resolved.name = "adhoc-$Version-$Provider"
    }

    # Manifeste sind der primäre Automationspfad. Sie laufen standardmäßig
    # unbeaufsichtigt und akzeptieren Geheimnisse nur über sichere externe
    # Übergabewege – nie aus dem JSON oder einem Lock/State.
    $effectiveNonInteractive = $NonInteractive.IsPresent
    if ($PSCmdlet.ParameterSetName -eq 'Manifest') {
        if ($resolved.automation.mode -eq 'unattended') { $effectiveNonInteractive = $true }
        if (-not $SaPassword -and $resolved.automation.saPasswordEnvironmentVariable) {
            $SaPassword = Get-LabManifestEnvironmentSecret -Name $resolved.automation.saPasswordEnvironmentVariable
        }
        if (-not $GuestPassword -and $resolved.automation.guestPasswordEnvironmentVariable) {
            $GuestPassword = Get-LabManifestEnvironmentSecret -Name $resolved.automation.guestPasswordEnvironmentVariable
        }
        if (-not $SqlSaPassword -and $resolved.automation.sqlSaPasswordEnvironmentVariable) {
            $SqlSaPassword = Get-LabManifestEnvironmentSecret -Name $resolved.automation.sqlSaPasswordEnvironmentVariable
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'Manifest' -and $resolved.persistentData.enabled) {
        $PersistentData = $true
        if (-not $DataRoot -and $resolved.persistentData.dataRoot) { $DataRoot = $resolved.persistentData.dataRoot }
    }

    if ($PersistentData) {
        if (-not $DataRoot) { $DataRoot = Get-LabDataRootDefault }
        if (-not $DataRoot) { throw 'LAB_DATA_ROOT_REQUIRED: PersistentData benötigt einen konfigurierten Data Root.' }
        $DataRoot = Resolve-LabDataRootForUse -DataRoot $DataRoot
    }
    if ($PersistentStorageId -and -not $PersistentData) {
        throw 'CONTAINER_INSTANCE_STORE_PERSISTENT_DATA_REQUIRED'
    }
    if ($PersistentStorageId -and ($PSCmdlet.ParameterSetName -ne 'AdHoc' -or @($resolved.instances).Count -ne 1 -or
        [string]$resolved.instances[0].provider -notin @('docker','podman'))) {
        throw 'CONTAINER_INSTANCE_STORE_ADHOC_SINGLE_CONTAINER_REQUIRED'
    }

    Write-LabInfo "Umgebung: $($resolved.name) ($($resolved.instances.Count) Instanz(en))"

    $providers = @($resolved.instances | ForEach-Object { $_.provider } | Sort-Object -Unique)
    $externalRuntimePlansByInstance = @{}
    $externalRuntimeImagePlansByInstance = @{}
    foreach ($instance in $resolved.instances) {
        $softwarePlans = @(Resolve-LabExternalRuntimePlansForInstance -Instance $instance)
        $externalRuntimePlansByInstance[[string]$instance.id] = $softwarePlans
        $rejectedPlans = @($softwarePlans | Where-Object { [string]$_.Status -ne 'RESOLVED' })
        if ($rejectedPlans.Count -gt 0) {
            $rejected = $rejectedPlans[0]
            throw "EXTERNAL_RUNTIME_PLAN_REJECTED: $($instance.id) / $($rejected.SoftwareId) / $($rejected.ReasonCode) - $($rejected.Reason)"
        }
        if ($softwarePlans.Count -gt 0 -and [string]$instance.provider -in @('docker', 'podman')) {
            $imagePlan = New-LabExternalRuntimeContainerImagePlan -Provider ([string]$instance.provider) `
                -SqlVersion ([string]$instance.version) -SoftwarePlans $softwarePlans
            $hostStatus = Test-LabExternalRuntimeContainerHost -Provider ([string]$instance.provider) -ImagePlan $imagePlan
            if ([string]$hostStatus.Status -ne 'READY') {
                throw "EXTERNAL_RUNTIME_CONTAINER_HOST_REJECTED: $($instance.id) / $($hostStatus.Status) - $($hostStatus.Reason)"
            }
            $externalRuntimeImagePlansByInstance[[string]$instance.id] = $imagePlan
        }
    }

    # Ein Manifest kann eine reguläre Hyper-V-Lab-VM vollständig aus einem
    # bereits veröffentlichten OS_SEALED- oder SQL_PREPARED_SEALED-Image
    # bereitstellen. Image-Builds selbst bleiben absichtlich außerhalb des
    # Manifests, damit keine ISO- oder Passwortdetails in der deklarativen
    # Labbeschreibung landen.
    if ($providers.Count -eq 1 -and $providers[0] -eq 'hyperv') {
        if ($resolved.instances.Count -ne 1) { throw 'HYPERV_MANIFEST_SINGLE_INSTANCE_REQUIRED' }
        $instance = $resolved.instances[0]
        $hyperVStorageDatabases = @($instance.databases)
        if ($hyperVStorageDatabases.Count -gt 0) {
            if (-not $instance.storageIntent) {
                throw 'HYPERV_MANIFEST_DATABASE_STORAGE_INTENT_REQUIRED'
            }
            $null = Assert-LabStorageManifestDatabaseCoverage -StorageIntent $instance.storageIntent `
                -Databases $hyperVStorageDatabases
        }
        $hyperVSettings = if ($instance.PSObject.Properties['hyperv']) { $instance.hyperv } else { $null }
        $artifactId = if ($hyperVSettings -and $hyperVSettings.PSObject.Properties['preparedImageId']) {
            [string]$hyperVSettings.preparedImageId
        } else { $null }
        $artifact = if ($artifactId) {
            Get-HyperVImageArtifact -ArtifactId $artifactId -StateRoot $StateRoot
        }
        else {
            Resolve-HyperVManifestFallbackArtifact -SqlVersion ([string]$instance.version) -StateRoot $StateRoot
        }
        if (-not $artifact -and -not $artifactId) {
            throw 'HYPERV_MANIFEST_FALLBACK_IMAGE_NOT_FOUND: Keine lokale SQL_PREPARED_SEALED-Vorlage für die angeforderte SQL-Version auf Windows Server Standard Evaluation mit Desktop Experience und mindestens 30 verbleibenden Evaluationstagen gefunden.'
        }
        $artifactState = [string]$artifact.artifactState
        if (-not $artifact -or $artifactState -notin @('SQL_PREPARED_SEALED', 'OS_SEALED')) {
            throw 'HYPERV_MANIFEST_HYPERV_IMAGE_REQUIRED'
        }
        if ($artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$artifact.sql.version -ne [string]$instance.version) {
            throw "HYPERV_MANIFEST_SQL_VERSION_MISMATCH: Manifest $($instance.version), Image $($artifact.sql.version)"
        }
        $hyperVExternalRuntimePlans = @($externalRuntimePlansByInstance[[string]$instance.id])
        if ($hyperVExternalRuntimePlans.Count -gt 0) {
            if ($artifactState -ne 'SQL_PREPARED_SEALED') {
                throw 'HYPERV_EXTERNAL_RUNTIME_SQL_PREPARED_IMAGE_REQUIRED'
            }
            $preparedFeatures = @($artifact.sql.features | ForEach-Object { ([string]$_).ToUpperInvariant() })
            if ($preparedFeatures -notcontains 'ADVANCEDANALYTICS') {
                throw 'HYPERV_EXTERNAL_RUNTIME_ADVANCED_ANALYTICS_REQUIRED'
            }
        }

        $guestPasswordMode = if ($hyperVSettings -and $hyperVSettings.PSObject.Properties['guestPasswordMode']) {
            [string]$hyperVSettings.guestPasswordMode
        } else { 'generated' }
        $passwordSource = if ($GuestPassword) { 'user' } elseif ($guestPasswordMode -eq 'prompt') { 'user' } else { 'generated' }
        if (-not $GuestPassword -and $passwordSource -eq 'generated') {
            if ($effectiveNonInteractive) { throw 'HYPERV_MANIFEST_GUEST_PASSWORD_REQUIRED_NONINTERACTIVE' }
            $GuestPassword = New-HyperVSqlUnattendedPassword
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($GuestPassword)
            try {
                Write-LabWarning "Einmaliges Gast-Administratorpasswort für diese Manifestbereitstellung: $([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr))"
            }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        elseif (-not $GuestPassword) {
            if ($effectiveNonInteractive) { throw 'HYPERV_MANIFEST_GUEST_PASSWORD_REQUIRED_NONINTERACTIVE' }
            $first = Read-Host '  Gastpasswort für Administrator' -AsSecureString
            $second = Read-Host '  Gastpasswort bestätigen' -AsSecureString
            $firstBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
            $secondBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
            try {
                if ([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstBstr) -cne [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondBstr)) {
                    throw 'HYPERV_MANIFEST_GUEST_PASSWORD_MISMATCH'
                }
                $GuestPassword = $first
            }
            finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstBstr)
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondBstr)
            }
        }

        $hyperVAdditionalDrives = @($instance.drives | Where-Object { $_ } | ForEach-Object {
            [PSCustomObject]@{
                id = [string]$_.id
                role = Get-LabDriveIntentRole -DriveId ([string]$_.id)
                sizeBytes = [long]([double]$_.sizeLimitGB * 1GB)
                vhdType = if ([string]$instance.profile -eq 'performance') { 'fixed' } else { 'dynamic' }
                guestPath = [string]$_.containerPath
                allocationUnitKB = 64
                fileSystem = 'NTFS'
            }
        })
        $hyperVDesiredState = New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode manifest -PersistentData ([bool]$PersistentData)
        $hyperVMemoryStartupMB = if ($hyperVSettings -and $hyperVSettings.PSObject.Properties['memoryStartupMB']) { [int]$hyperVSettings.memoryStartupMB } else { 4096 }
        $hyperVDynamicMemoryEnabled = if ($hyperVSettings -and $hyperVSettings.PSObject.Properties['dynamicMemoryEnabled']) { [bool]$hyperVSettings.dynamicMemoryEnabled } else { $true }
        $hyperVMemoryMinimumMB = if ($hyperVSettings -and $hyperVSettings.PSObject.Properties['memoryMinimumMB']) { [int]$hyperVSettings.memoryMinimumMB } else { 0 }
        $hyperVMemoryMaximumMB = if ($hyperVSettings -and $hyperVSettings.PSObject.Properties['memoryMaximumMB']) { [int]$hyperVSettings.memoryMaximumMB } else { 0 }
        $hyperVProcessorCount = if ($hyperVSettings -and $hyperVSettings.PSObject.Properties['processorCount']) { [int]$hyperVSettings.processorCount } else { 4 }
        $hyperVSqlPort = if ($hyperVSettings -and $hyperVSettings.PSObject.Properties['sqlPort']) { [int]$hyperVSettings.sqlPort } else { 1433 }
        $hyperVAutoStart = [string]$instance.autostart
        $hyperVSwitchName = if ($hyperVSettings -and $hyperVSettings.PSObject.Properties['switchName']) { [string]$hyperVSettings.switchName } else { $null }
        $hyperVIsolated = [string]$instance.network.Intent -eq 'isolated'
        $hyperVNetworkIntent = if ($hyperVIsolated) { 'hostOnly' } else { [string]$instance.network.Intent }
        $lab = New-HyperVLabEnvironment -ArtifactId ([string]$artifact.artifactId) -LabName ([string]$resolved.name) -InstanceId ([string]$instance.id) `
            -MemoryStartupMB $hyperVMemoryStartupMB -DynamicMemoryEnabled $hyperVDynamicMemoryEnabled `
            -MemoryMinimumMB $hyperVMemoryMinimumMB -MemoryMaximumMB $hyperVMemoryMaximumMB `
            -ProcessorCount $hyperVProcessorCount -AutoStart $hyperVAutoStart `
            -SwitchName $hyperVSwitchName -Isolated:$hyperVIsolated -NetworkIntent $hyperVNetworkIntent -AdditionalDrives $hyperVAdditionalDrives -StorageIntent $instance.storageIntent `
            -DesiredState $hyperVDesiredState -StateRoot $StateRoot
        $hyperVLab = Get-HyperVLabWorkflowRun -RunId $lab.RunId -StateRoot $StateRoot
        if ($PersistentData) {
            $null = Enable-HyperVLabPersistentData -RunId $lab.RunId -DataRoot $DataRoot -SizeGB ([int]$resolved.persistentData.dataDiskGB) -StateRoot $hyperVLab.StateRoot
        }
        $effectiveHyperVSqlSaPassword = if ($SqlSaPassword) { $SqlSaPassword } else { $GuestPassword }
        $provisioning = Invoke-HyperVLabUnattendedProvision -RunId $lab.RunId -AdministratorPassword $GuestPassword -SqlSaPassword $SqlSaPassword `
            -SqlPort $hyperVSqlPort -PasswordSource $passwordSource -Region $Region -SystemLocale $SystemLocale -UiLanguage $UiLanguage `
            -InputLocale $InputLocale -TimeZone $TimeZone -StateRoot $hyperVLab.StateRoot
        $hyperVLab = Get-HyperVLabWorkflowRun -RunId $lab.RunId -StateRoot $hyperVLab.StateRoot
        $testDatabaseOwnership = Initialize-LabHyperVTestDatabaseOwnershipReceipt -Lab $hyperVLab
        if ($hyperVExternalRuntimePlans.Count -gt 0) {
            $mediaRoot = Get-LabMediaRootDefault
            if (-not $mediaRoot) { throw 'HYPERV_EXTERNAL_RUNTIME_MEDIA_ROOT_REQUIRED' }
            Write-LabInfo "External Runtimes auf '$($instance.id)' im Windows-Gast installieren und über SQL verifizieren..."
            $guestCredential = [PSCredential]::new('Administrator', $GuestPassword)
            $null = Install-LabHyperVExternalRuntimes -SoftwarePlans $hyperVExternalRuntimePlans -RunId $lab.RunId `
                -Credential $guestCredential -SqlSaPassword $effectiveHyperVSqlSaPassword -MediaRoot $mediaRoot `
                -ResourceGovernorConfig $instance.serverConfig.externalScripts.resourceGovernor `
                -StateRoot $hyperVLab.StateRoot
            $hyperVLab = Get-HyperVLabWorkflowRun -RunId $lab.RunId -StateRoot $hyperVLab.StateRoot
        }
        if ($hyperVStorageDatabases.Count -gt 0) {
            $hyperVLab = Get-HyperVLabWorkflowRun -RunId $lab.RunId -StateRoot $hyperVLab.StateRoot
            if (-not $hyperVLab.Instance.host -or -not $hyperVLab.Instance.port) {
                throw 'HYPERV_STORAGE_DATABASE_HOST_SQL_ACCESS_REQUIRED'
            }
            $guestCredential = [PSCredential]::new('Administrator', $GuestPassword)
            $installedDatabases = [Collections.Generic.List[string]]::new()
            foreach ($database in @($hyperVStorageDatabases | Where-Object { -not $_.restore })) {
                Write-LabInfo "Storage-gebundene Datenbank '$($database.name)' auf '$($instance.id)' anlegen und verifizieren..."
                $databaseResult = New-SqlServerLabDatabase -HostName ([string]$hyperVLab.Instance.host) `
                    -Port ([int]$hyperVLab.Instance.port) -SaPassword $effectiveHyperVSqlSaPassword `
                    -DatabaseName ([string]$database.name) -Collation ([string]$database.collation) `
                    -DataFiles @($database.files.data) -LogFiles @($database.files.log) -Options $database.options `
                    -RunId $lab.RunId -InstanceId ([string]$instance.id) -StateRoot $hyperVLab.StateRoot
                if (-not $databaseResult.Success) { throw "HYPERV_STORAGE_DATABASE_CREATE_FAILED: $($database.name)" }
                $installedDatabases.Add([string]$database.name)
            }
            foreach ($database in @($hyperVStorageDatabases | Where-Object { $_.restore })) {
                $databaseNamesToRecord = @([string]$database.name)
                if ($database.restore.sampleId) {
                    Write-LabInfo "Storage-gebundenes Sample '$($database.restore.sampleId):$($database.restore.sampleVariant)' auf '$($instance.id)' installieren und verifizieren..."
                    $sampleResult = Install-LabSampleDatabase `
                        -Provider hyperv `
                        -HostName ([string]$hyperVLab.Instance.host) `
                        -Port ([int]$hyperVLab.Instance.port) `
                        -SaPassword $effectiveHyperVSqlSaPassword `
                        -RunId $lab.RunId `
                        -InstanceId ([string]$instance.id) `
                        -GuestCredential $guestCredential `
                        -RestoreDefinition $database.restore `
                        -SqlVersion ([string]$instance.version) `
                        -NonInteractive:$effectiveNonInteractive `
                        -RunDirectory $hyperVLab.RunDirectory `
                        -StateRoot $hyperVLab.StateRoot
                    if (-not $sampleResult.Success) {
                        throw "HYPERV_STORAGE_SAMPLE_INSTALL_FAILED: $($database.restore.sampleId)/$($sampleResult.Status)"
                    }
                    $ownershipEntry = New-LabHyperVTestDatabaseOwnershipEntry -RestoreDefinition $database.restore -SampleResult $sampleResult
                    $testDatabaseOwnership = Add-LabHyperVTestDatabaseOwnershipEntry -Receipt $testDatabaseOwnership `
                        -Entry $ownershipEntry -RunDirectory $hyperVLab.RunDirectory
                    $databaseNamesToRecord = @($sampleResult.DatabaseNames)
                }
                else {
                    Write-LabInfo "Storage-gebundener Restore '$($database.name)' auf '$($instance.id)' ausführen und verifizieren..."
                    $restoreArguments = @{
                        RunId=$lab.RunId; InstanceId=[string]$instance.id; SaPassword=$effectiveHyperVSqlSaPassword
                        GuestCredential=$guestCredential; BackupSource=[string]$database.restore.source
                        DatabaseName=[string]$database.name; Replace=[bool]$database.restore.replace
                        NonInteractive=$effectiveNonInteractive; StateRoot=$hyperVLab.StateRoot
                    }
                    if ($database.restore.expectedSha256) { $restoreArguments.ExpectedSha256=[string]$database.restore.expectedSha256 }
                    $restoreResult = Restore-SqlServerLabDatabase @restoreArguments
                    if (-not $restoreResult.Success) { throw "HYPERV_STORAGE_DATABASE_RESTORE_FAILED: $($database.name)" }
                }
                foreach ($installedDatabaseName in $databaseNamesToRecord) {
                    if ($database.options) {
                        $null = Set-LabDatabaseOptions -DatabaseName ([string]$installedDatabaseName) -Options $database.options `
                            -HostName ([string]$hyperVLab.Instance.host) -Port ([int]$hyperVLab.Instance.port) `
                            -SaPassword $effectiveHyperVSqlSaPassword
                    }
                    $installedDatabases.Add([string]$installedDatabaseName)
                }
            }
            $hyperVLab = Get-HyperVLabWorkflowRun -RunId $lab.RunId -StateRoot $hyperVLab.StateRoot
            $hyperVLab.Instance | Add-Member -NotePropertyName databases -NotePropertyValue @($installedDatabases) -Force
            Write-LabArtifactJsonAtomic -Path (Join-Path $hyperVLab.RunDirectory 'connection-info.json') -InputObject $hyperVLab.Connection
        }
        return [PSCustomObject]@{
            RunId = $lab.RunId; ScopeId = $lab.ScopeId; State = 'RUNNING'; Name = $resolved.name; Instances = @($hyperVLab.Instance)
            StateRoot = $hyperVLab.StateRoot; DataRoot = if ($PersistentData) { $DataRoot } else { $null }; Provisioning = $provisioning
            GeneratedSqlAccess = if ($provisioning.PSObject.Properties['GeneratedSqlAccess']) { $provisioning.GeneratedSqlAccess } else { $null }
        }
    }

    $notImplementedProviders = @($providers | Where-Object { $_ -notin @('docker', 'podman') })
    if ($notImplementedProviders.Count -gt 0) {
        throw "Provider nicht implementiert: $($notImplementedProviders -join ', ')."
    }

    foreach ($instance in $resolved.instances) {
        $versionCheck = Test-SqlServerVersionSupported -VersionId $instance.version
        if (-not $versionCheck.Supported) {
            throw "Version $($instance.version): $($versionCheck.Message)"
        }
        if ($versionCheck.Message) {
            Write-LabWarning $versionCheck.Message
        }

        # Imageauflösung vor State und Mutation verifizieren.
        $null = Get-SqlServerDockerImage -VersionId $instance.version
    }

    $skipAssessmentEffective = $SkipAssessment.IsPresent -or
        ($resolved.resourceOverrides -and $resolved.resourceOverrides.skipAssessment -eq $true)

    if (-not $skipAssessmentEffective) {
        Write-LabInfo 'Resource Assessment...'
        $assessment = Test-SqlServerLabPrerequisite `
            -Instances $resolved.instances `
            -Provider $providers

        foreach ($detail in $assessment.Details) {
            $color = switch ($detail.Status) {
                'RESOURCE_OK'      { 'Green' }
                'RESOURCE_WARNING' { 'Yellow' }
                default            { 'Red' }
            }
            Write-LabStatus `
                -Label $detail.Category `
                -Value "$($detail.Status): $($detail.Message)" `
                -Color $color
        }

        if ($assessment.Status -eq 'RESOURCE_HARD_BLOCK') {
            throw 'Resource Assessment HARD_BLOCK: Umgebung kann nicht erstellt werden.'
        }
    }

    if (-not $SaPassword) {
        if ($effectiveNonInteractive) { throw 'SA_PASSWORD_REQUIRED_NONINTERACTIVE' }
        Write-LabInfo 'SA-Passwort wird benoetigt.'
        $SaPassword = Read-SaPassword
    }

    $providerSubRuns = @(
        $resolved.instances |
            Group-Object -Property provider |
            Sort-Object Name |
            ForEach-Object {
                [PSCustomObject]@{
                    id          = "provider-$($_.Name)"
                    provider    = $_.Name
                    instanceIds = @($_.Group | ForEach-Object { $_.id })
                }
            }
    )

    $desiredProvisioningMode = if ($PSCmdlet.ParameterSetName -eq 'Manifest') { 'manifest' } else { 'adhoc' }
    $desiredState = New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode $desiredProvisioningMode -PersistentData ([bool]$PersistentData)
    $runMetadata = @{
        name = $resolved.name
        persistentData = [bool]$PersistentData
        dataRoot = if ($PersistentData) { $DataRoot } else { $null }
        desiredState = $desiredState
    }
    $workflowOperationId = Get-LabWorkflowOperationContext
    if (-not [string]::IsNullOrWhiteSpace($workflowOperationId)) {
        $runMetadata['workflowOperationId'] = $workflowOperationId
    }
    $runState = New-LabRunState `
        -StateRoot $StateRoot `
        -Metadata $runMetadata `
        -ProviderSubRuns $providerSubRuns
    $effectiveStateRoot = $runState.StateRoot
    $cleanupStatus = 'NOT_STARTED'

    Write-LabStatus -Label 'RunId' -Value $runState.RunId
    Write-LabStatus -Label 'ScopeId' -Value $runState.ScopeId

    try {
        $null = New-CleanupPlan `
            -RunDir $runState.RunDir `
            -RunId $runState.RunId `
            -ScopeId $runState.ScopeId `
            -ProviderSubRuns $providerSubRuns

        if ($PersistentData) {
            foreach ($instance in $resolved.instances) {
                $storage = Get-LabPersistentInstanceStorage -DataRoot $DataRoot -LabName $resolved.name -Provider $instance.provider -InstanceId $instance.id -SqlVersion $instance.version -Create
                $hasExternalRuntime = $instance.provider -in @('docker', 'podman') -and
                    @($externalRuntimePlansByInstance[[string]$instance.id]).Count -gt 0
                $instanceStorePlan = $null
                if ($PersistentStorageId) {
                    $storageConfiguration = Get-LabStorageConfiguration -DataRoot $DataRoot
                    $instanceStorePlan = New-LabContainerInstanceStoreSelectionPlan `
                        -SourcePersistentStorageId $PersistentStorageId `
                        -Action $PersistentStorageAction `
                        -Provider ([string]$instance.provider) `
                        -TargetRunId $runState.RunId `
                        -TargetScopeId $runState.ScopeId `
                        -TargetSqlVersion ([string]$instance.version) `
                        -Configuration $storageConfiguration `
                        -IncludeExternalRuntimeSidecars:$hasExternalRuntime
                    if ([string]$instanceStorePlan.Status -ne 'READY') {
                        throw "CONTAINER_INSTANCE_STORE_PLAN_BLOCKED: $(@($instanceStorePlan.Blockers) -join ',')"
                    }
                    if ($PersistentStorageAction -eq 'CLONE') {
                        $operationDirectory = Join-Path $DataRoot (Join-Path 'Operations' (Join-Path 'ContainerInstanceStores' ([string]$instanceStorePlan.OperationId)))
                        $null = Invoke-LabContainerInstanceStoreClone -Plan $instanceStorePlan `
                            -OperationDirectory $operationDirectory -Configuration $storageConfiguration
                    }
                    $null = Add-LabSelectedPersistentContainerDrive -Instance $instance -Plan $instanceStorePlan -Storage $storage `
                        -IncludeExternalRuntimeState:$hasExternalRuntime
                }
                else {
                    $null = Add-LabPersistentContainerDrive -Instance $instance -Storage $storage `
                        -IncludeExternalRuntimeState:$hasExternalRuntime
                }
                $persistentDrive = @($instance.drives | Where-Object { $_.id -eq 'persistent-mssql' })[0]
                # Die Kompensation wird vor der Katalogmutation persistiert. Hat
                # der Acquire-Schritt noch keine eigene Lease erzeugt, ist der
                # Release-Schritt bewusst ein idempotentes No-op.
                $null = Add-CleanupStep `
                    -RunDir $runState.RunDir `
                    -ResourceType 'persistent-storage-lease' `
                    -ResourceId ([string]$persistentDrive.volumeName) `
                    -Action 'release' `
                    -Provider ([string]$instance.provider) `
                    -ProviderSubRunId "provider-$($instance.provider)" `
                    -Compensation "release persistent storage lease for $([string]$persistentDrive.volumeName)"
                $lease = Register-LabContainerInstanceStoreLease `
                    -Provider ([string]$instance.provider) `
                    -VolumeName ([string]$persistentDrive.volumeName) `
                    -RunId $runState.RunId `
                    -ScopeId $runState.ScopeId `
                    -SqlVersion ([string]$instance.version) `
                    -DisplayName "$($resolved.name) / $($instance.id) / SQL $($instance.version)" `
                    -DataRoot $DataRoot
                $persistentDrive | Add-Member -NotePropertyName persistentStorageId `
                    -NotePropertyValue ([string]$lease.Store.PersistentStorageId) -Force
                foreach ($sidecarDrive in @($instance.drives | Where-Object {
                    $_.persistentStorageRole -in @('EXTERNAL_LANGUAGES','EXTERNAL_LIBRARIES')
                })) {
                    $sidecarDrive | Add-Member -NotePropertyName persistentStorageId `
                        -NotePropertyValue ([string]$lease.Store.PersistentStorageId) -Force
                }
                $instance | Add-Member -NotePropertyName persistentStorage -NotePropertyValue ([PSCustomObject]@{
                    mode = if ($PersistentStorageId) { 'cataloged-runtime-volume' } else { 'data-root-runtime-volume' }
                    root = if ($PersistentStorageId) { $null } else { [string]$storage.SqlRoot }
                    persistentStorageId = [string]$lease.Store.PersistentStorageId
                    containerVolume = [string]$persistentDrive.volumeName
                    backupHostPath = [string]$storage.BackupRoot
                }) -Force
            }
            Write-LabInfo "Persistenter Data Root wird eingebunden: $DataRoot"
        }

        foreach ($instance in @($resolved.instances | Where-Object { $_.provider -in @('docker', 'podman') })) {
            $hasExternalRuntime = @($externalRuntimePlansByInstance[[string]$instance.id]).Count -gt 0
            $null = Add-LabRunScopedContainerSystemDrive -Instance $instance `
                -IncludeExternalRuntimeState:$hasExternalRuntime
        }

        foreach ($instance in $resolved.instances) {
            Add-LabInstanceCleanupPlan -Instance $instance -RunState $runState `
                -SoftwarePlans @($externalRuntimePlansByInstance[[string]$instance.id])
        }

        $null = Save-LabSecret `
            -Path $runState.RunDir `
            -Name 'sa-password' `
            -Secret $SaPassword

        $null = Set-LabRunState `
            -RunId $runState.RunId `
            -NewState 'PROVISIONING' `
            -Reason 'Provider-Start' `
            -StateRoot $effectiveStateRoot
        Set-LabProviderSubRunsState `
            -RunId $runState.RunId `
            -Providers $providers `
            -NewState 'PROVISIONING' `
            -Reason 'Provider-Start' `
            -StateRoot $effectiveStateRoot

        $containerImageArtifactsByInstance = @{}
        foreach ($instance in @($resolved.instances | Where-Object {
            $externalRuntimeImagePlansByInstance.ContainsKey([string]$_.id)
        })) {
            Write-LabInfo "Derived External-Runtime-Image für '$($instance.id)' aufbauen oder wiederverwenden..."
            $containerImageArtifactsByInstance[[string]$instance.id] = Invoke-LabExternalRuntimeContainerImageBuild `
                -ImagePlan $externalRuntimeImagePlansByInstance[[string]$instance.id] `
                -StateRoot $effectiveStateRoot
        }

        $labInstances = @()

        foreach ($instance in $resolved.instances) {
            Write-LabInfo "Instanz '$($instance.id)' erstellen ($($instance.version), $($instance.provider))..."

            $versionDefinition = Get-SqlServerVersion -VersionId $instance.version
            $container = $null
            $readiness = $null
            $containerHost = '127.0.0.1'
            foreach ($readinessAttempt in 1..2) {
                $container = New-LabProviderContainer `
                    -Instance $instance `
                    -RunState $runState `
                    -SaPassword $SaPassword `
                    -Port $Port `
                    -ContainerImageArtifact $containerImageArtifactsByInstance[[string]$instance.id]

                $containerHost = if ([string]$container.Provider -eq 'podman') {
                    Resolve-PodmanWindowsHostName
                }
                else {
                    '127.0.0.1'
                }

                if ([string]$instance.autostart -eq 'on') {
                    $null = Enable-LabContainerHostAutoStart -Provider ([string]$instance.provider)
                }

                $readiness = Wait-SqlReady `
                    -HostName $containerHost `
                    -Port $container.Port `
                    -SaPassword $SaPassword `
                    -TimeoutSeconds 300 `
                    -ExpectedMajorVersion $versionDefinition.major `
                    -Provider $container.Provider `
                    -ContainerIdOrName $container.ContainerId

                if ($readiness.Ready) { break }

                $retryableSql2025State = (
                    [string]$instance.version -match '^2025(?:$|-)' -and
                    [string]$readiness.Message -match '^LAB_SQL_TRANSIENT_LOGIN_STATE_115:'
                )
                if (-not $retryableSql2025State -or $readinessAttempt -ge 2) {
                    throw "SQL Server nicht bereit: $($readiness.Message)"
                }

                Write-LabWarning 'SQL Server 2025 meldet den transienten Loginzustand 115. Der scopegebundene Container wird einmal neu erstellt.'
                Remove-LabProviderContainerForReadinessRetry -Container $container -ScopeId $runState.ScopeId
                $container = $null
                Start-Sleep -Seconds 2
            }

            $labInstances += [PSCustomObject]@{
                Id               = $instance.id
                Version          = $instance.version
                Provider         = $instance.provider
                AutoStart        = [string]$instance.autostart
                Host             = $containerHost
                Port             = $container.Port
                ContainerId      = $container.ContainerId
                ContainerName    = $container.ContainerName
                ConnectionString = New-SqlConnectionString -HostName $containerHost -Port $container.Port
                Databases        = @()
                PersistentStorage = $instance.persistentStorage
                ExternalRuntime  = if ($containerImageArtifactsByInstance.ContainsKey([string]$instance.id)) {
                    $artifact = $containerImageArtifactsByInstance[[string]$instance.id]
                    $imagePlan = $externalRuntimeImagePlansByInstance[[string]$instance.id]
                    [PSCustomObject]@{
                        ImageKey = [string]$artifact.ImageKey
                        SoftwarePlanKeys = @($imagePlan.SoftwarePlanKeys)
                        LaunchMode = [string]$artifact.LaunchMode
                        VariantIds = @($imagePlan.VariantIds)
                        Languages = @($imagePlan.Languages)
                        Status = 'IMAGE_READY'
                        Receipts = @()
                    }
                }
                else { $null }
                Status           = 'Running'
            }
        }

        $null = Set-LabRunState `
            -RunId $runState.RunId `
            -NewState 'SQL_READY' `
            -Reason 'Alle Instanzen bereit' `
            -StateRoot $effectiveStateRoot
        Set-LabProviderSubRunsState `
            -RunId $runState.RunId `
            -Providers $providers `
            -NewState 'SQL_READY' `
            -Reason 'Alle Instanzen bereit' `
            -StateRoot $effectiveStateRoot

        foreach ($instance in ($resolved.instances | Where-Object { $_.serverConfig })) {
            $labInstance = $labInstances |
                Where-Object { $_.Id -eq $instance.id } |
                Select-Object -First 1

            Write-LabInfo "Server-Konfiguration auf '$($instance.id)' anwenden..."
            $null = Set-LabServerConfig `
                -Config $instance.serverConfig `
                -HostName $labInstance.Host `
                -Port $labInstance.Port `
                -SaPassword $SaPassword `
                -ContainerName $labInstance.ContainerName

        }

        $createdDatabaseCount = 0
        foreach ($instance in $resolved.instances) {
            $labInstance = $labInstances |
                Where-Object { $_.Id -eq $instance.id } |
                Select-Object -First 1

            foreach ($database in @($instance.databases | Where-Object { -not $_.restore })) {
                Write-LabInfo "Datenbank '$($database.name)' auf '$($instance.id)' anlegen..."

                $databaseResult = New-SqlServerLabDatabase `
                    -HostName $labInstance.Host `
                    -Port $labInstance.Port `
                    -SaPassword $SaPassword `
                    -DatabaseName $database.name `
                    -Collation $database.collation `
                    -DataFiles $database.files.data `
                    -LogFiles $database.files.log `
                    -Options $database.options

                if (-not $databaseResult.Success) {
                    throw "Datenbank-Erstellung fehlgeschlagen: $($database.name)"
                }

                if ($database.options) {
                    $null = Set-LabDatabaseOptions `
                        -DatabaseName $database.name `
                        -Options $database.options `
                        -HostName $labInstance.Host `
                        -Port $labInstance.Port `
                        -SaPassword $SaPassword
                }

                if ($labInstance.Databases -notcontains $database.name) {
                    $labInstance.Databases += $database.name
                }
                $createdDatabaseCount++
            }
        }

        $createReason = if ($createdDatabaseCount -gt 0) {
            "$createdDatabaseCount Datenbank(en) angelegt"
        }
        else {
            'Keine CREATE-DATABASE-Arbeit angefordert'
        }

        $null = Set-LabRunState `
            -RunId $runState.RunId `
            -NewState 'DATABASES_CREATED' `
            -Reason $createReason `
            -StateRoot $effectiveStateRoot
        Set-LabProviderSubRunsState `
            -RunId $runState.RunId `
            -Providers $providers `
            -NewState 'DATABASES_CREATED' `
            -Reason $createReason `
            -StateRoot $effectiveStateRoot

        foreach ($instance in $resolved.instances) {
            $labInstance = $labInstances |
                Where-Object { $_.Id -eq $instance.id } |
                Select-Object -First 1

            foreach ($database in @($instance.databases | Where-Object { $_.restore })) {
                $databaseNamesToRecord = @($database.name)
                if ($database.restore.sampleId) {
                    Write-LabInfo "Sample '$($database.restore.sampleId):$($database.restore.sampleVariant)' auf '$($instance.id)' installieren..."

                    $sampleResult = Install-LabSampleDatabase `
                        -HostName $labInstance.Host `
                        -Port $labInstance.Port `
                        -SaPassword $SaPassword `
                        -ContainerName $labInstance.ContainerName `
                        -RestoreDefinition $database.restore `
                        -SqlVersion ([string]$instance.version) `
                        -NonInteractive:$effectiveNonInteractive `
                        -RunDirectory $runState.RunDir `
                        -StateRoot $effectiveStateRoot

                    if (-not $sampleResult.Success) {
                        throw "Sample-Installation fehlgeschlagen ($($sampleResult.Status)): $($sampleResult.Message)"
                    }
                    if (@($sampleResult.DatabaseNames).Count -gt 0) {
                        $databaseNamesToRecord = @($sampleResult.DatabaseNames)
                    }
                    Write-LabSuccess "  $($sampleResult.Status): $($sampleResult.Message)"
                }
                else {
                    Write-LabInfo "Restore '$($database.name)' auf '$($instance.id)' von: $($database.restore.source)"

                    $restoreResult = Restore-SqlServerLabDatabase `
                        -HostName $labInstance.Host `
                        -Port $labInstance.Port `
                        -SaPassword $SaPassword `
                        -BackupSource $database.restore.source `
                        -ExpectedSha256 $database.restore.expectedSha256 `
                        -DatabaseName $database.name `
                        -ContainerName $labInstance.ContainerName `
                        -Replace:($database.restore.replace) `
                        -NonInteractive:$effectiveNonInteractive `
                        -StateRoot $effectiveStateRoot `
                        -RunDirectory $runState.RunDir

                    if (-not $restoreResult.Success) {
                        throw "Restore fehlgeschlagen: $($restoreResult.Message)"
                    }
                }

                if ($database.options) {
                    $null = Set-LabDatabaseOptions `
                        -DatabaseName $database.name `
                        -Options $database.options `
                        -HostName $labInstance.Host `
                        -Port $labInstance.Port `
                        -SaPassword $SaPassword
                }

                foreach ($installedDatabaseName in $databaseNamesToRecord) {
                    if ($labInstance.Databases -notcontains $installedDatabaseName) {
                        $labInstance.Databases += $installedDatabaseName
                    }
                }
            }
        }

        foreach ($labInstance in @($labInstances | Where-Object { $_.PersistentStorage })) {
            $storageConfiguration = Get-LabStorageConfiguration -DataRoot $DataRoot
            $null = Sync-LabContainerInstanceStoreDatabaseReference `
                -PersistentStorageId ([string]$labInstance.PersistentStorage.persistentStorageId) `
                -RunId $runState.RunId `
                -ScopeId $runState.ScopeId `
                -DatabaseName @($labInstance.Databases) `
                -Configuration $storageConfiguration
        }

        foreach ($instance in @($resolved.instances | Where-Object {
            @($externalRuntimePlansByInstance[[string]$_.id]).Count -gt 0
        })) {
            $labInstance = $labInstances |
                Where-Object { $_.Id -eq $instance.id } |
                Select-Object -First 1
            Write-LabInfo "External Runtimes auf '$($instance.id)' aktivieren und über SQL verifizieren..."
            $softwareReceipts = @(Initialize-LabExternalRuntimes `
                -SoftwarePlans @($externalRuntimePlansByInstance[[string]$instance.id]) `
                -LabInstance $labInstance `
                -ImageArtifact $containerImageArtifactsByInstance[[string]$instance.id] `
                -SaPassword $SaPassword `
                -ResourceGovernorConfig $instance.serverConfig.externalScripts.resourceGovernor `
                -RunDirectory $runState.RunDir)
            $labInstance.ExternalRuntime.Status = 'EXTENSIONS_READY_RUN'
            $labInstance.ExternalRuntime.Receipts = @($softwareReceipts | ForEach-Object {
                [PSCustomObject]@{
                    SoftwareId = [string]$_.SoftwareId
                    PlanKey = [string]$_.PlanKey
                    VariantId = [string]$_.VariantId
                    RuntimeVersion = [string]$_.RuntimeVersion
                    Status = [string]$_.Status
                    CompletedAt = [string]$_.CompletedAt
                }
            })
        }

        $hasPostProvision = $resolved.instances |
            Where-Object { $_.postProvision.Count -gt 0 }
        if ($hasPostProvision) {
            foreach ($instance in $resolved.instances) {
                $labInstance = $labInstances |
                    Where-Object { $_.Id -eq $instance.id } |
                    Select-Object -First 1
                $postDatabase = if ($instance.databases.Count -gt 0) {
                    $instance.databases[0].name
                }
                else {
                    'master'
                }

                foreach ($scriptPath in $instance.postProvision) {
                    Write-LabInfo "PostProvision: $(Split-Path $scriptPath -Leaf) auf '$($instance.id)/$postDatabase'..."
                    $scriptResult = Invoke-LabSqlScript `
                        -ScriptPath $scriptPath `
                        -HostName $labInstance.Host `
                        -Port $labInstance.Port `
                        -SaPassword $SaPassword `
                        -Database $postDatabase `
                        -KeepConnection

                    if (-not $scriptResult.Success) {
                        throw $scriptResult.Message
                    }

                    Write-LabSuccess "  $($scriptResult.Message) ($($scriptResult.Batches) Batches, $($scriptResult.Duration.TotalSeconds.ToString('F1'))s)"
                }
            }

            $null = Set-LabRunState `
                -RunId $runState.RunId `
                -NewState 'POST_PROVISIONED' `
                -Reason 'Skripte ausgefuehrt' `
                -StateRoot $effectiveStateRoot
            Set-LabProviderSubRunsState `
                -RunId $runState.RunId `
                -Providers $providers `
                -NewState 'POST_PROVISIONED' `
                -Reason 'Skripte ausgefuehrt' `
                -StateRoot $effectiveStateRoot
        }

        $connectionInfo = [PSCustomObject]@{
            runId     = $runState.RunId
            scopeId   = $runState.ScopeId
            instances = @($labInstances | ForEach-Object {
                [PSCustomObject]@{
                    id               = $_.Id
                    host             = $_.Host
                    port             = $_.Port
                    version          = $_.Version
                    provider         = $_.Provider
                    autostart        = $_.AutoStart
                    containerId      = $_.ContainerId
                    containerName    = $_.ContainerName
                    connectionString = $_.ConnectionString
                    databases        = @($_.Databases)
                    persistentStorage = $_.PersistentStorage
                    externalRuntime  = $_.ExternalRuntime
                }
            })
        }

        $connectionInfo |
            ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath (Join-Path $runState.RunDir 'connection-info.json') -Encoding utf8

        $null = Set-LabRunState `
            -RunId $runState.RunId `
            -NewState 'RUNNING' `
            -Reason 'Umgebung bereit' `
            -StateRoot $effectiveStateRoot
        Set-LabProviderSubRunsState `
            -RunId $runState.RunId `
            -Providers $providers `
            -NewState 'RUNNING' `
            -Reason 'Umgebung bereit' `
            -StateRoot $effectiveStateRoot

        Write-Host ''
        Write-LabHeader 'Umgebung bereit'
        Write-LabStatus -Label 'RunId' -Value $runState.RunId -Color 'Green'
        foreach ($labInstance in $labInstances) {
            Write-LabStatus `
                -Label $labInstance.Id `
                -Value "$($labInstance.Host):$($labInstance.Port) (SQL $($labInstance.Version), $($labInstance.Provider))" `
                -Color 'Green'
        }
        Write-Host ''

        return [PSCustomObject]@{
            RunId     = $runState.RunId
            ScopeId   = $runState.ScopeId
            State     = 'Running'
            Name      = $resolved.name
            Instances = $labInstances
            StateRoot = $effectiveStateRoot
            DataRoot = if ($PersistentData) { $DataRoot } else { $null }
        }
    }
    catch {
        $provisioningError = $_
        Write-LabError "Provisionierung fehlgeschlagen: $($provisioningError.Exception.Message)"

        try {
            $null = Add-LabRunError `
                -RunId $runState.RunId `
                -Message $provisioningError.Exception.Message `
                -Component 'New-SqlServerLab' `
                -StateRoot $effectiveStateRoot

            $currentState = Get-LabRunState `
                -RunId $runState.RunId `
                -StateRoot $effectiveStateRoot

            if ($currentState.state -notin @('PROVISION_FAILED', 'CLEANUP_PENDING', 'CLEANUP_RUNNING', 'CLEANED_UP', 'RECOVERY_REQUIRED', 'REMOVED')) {
                $null = Set-LabRunState `
                    -RunId $runState.RunId `
                    -NewState 'PROVISION_FAILED' `
                    -Reason $provisioningError.Exception.Message `
                    -StateRoot $effectiveStateRoot

                foreach ($providerSubRun in @(Get-LabProviderSubRuns -RunId $runState.RunId -StateRoot $effectiveStateRoot)) {
                    if ($providerSubRun.state -notin @('PROVISION_FAILED', 'CLEANUP_PENDING', 'CLEANUP_RUNNING', 'CLEANED_UP', 'RECOVERY_REQUIRED', 'REMOVED')) {
                        Set-LabProviderSubRunState `
                            -RunId $runState.RunId `
                            -Provider $providerSubRun.provider `
                            -NewState 'PROVISION_FAILED' `
                            -Reason $provisioningError.Exception.Message `
                            -StateRoot $effectiveStateRoot
                    }
                }
            }

            $currentState = Get-LabRunState -RunId $runState.RunId -StateRoot $effectiveStateRoot
            if ($currentState.state -eq 'PROVISION_FAILED') {
                $null = Set-LabRunState `
                    -RunId $runState.RunId `
                    -NewState 'CLEANUP_PENDING' `
                    -Reason 'Auto-Cleanup nach Fehler' `
                    -StateRoot $effectiveStateRoot
                Set-LabProviderSubRunsState `
                    -RunId $runState.RunId `
                    -Providers $providers `
                    -NewState 'CLEANUP_PENDING' `
                    -Reason 'Auto-Cleanup nach Fehler' `
                    -StateRoot $effectiveStateRoot
            }

            $currentState = Get-LabRunState -RunId $runState.RunId -StateRoot $effectiveStateRoot
            if ($currentState.state -eq 'CLEANUP_PENDING') {
                $null = Set-LabRunState `
                    -RunId $runState.RunId `
                    -NewState 'CLEANUP_RUNNING' `
                    -Reason 'Auto-Cleanup gestartet' `
                    -StateRoot $effectiveStateRoot
                Set-LabProviderSubRunsState `
                    -RunId $runState.RunId `
                    -Providers $providers `
                    -NewState 'CLEANUP_RUNNING' `
                    -Reason 'Auto-Cleanup gestartet' `
                    -StateRoot $effectiveStateRoot
            }

            Write-LabInfo 'Automatischer Cleanup...'
            $cleanupResult = Invoke-CleanupPlan `
                -RunDir $runState.RunDir `
                -ScopeId $runState.ScopeId
            $cleanupStatus = $cleanupResult.Status
            Write-LabStatus -Label 'Cleanup' -Value $cleanupStatus

            if ($cleanupResult.Errors -eq 0) {
                $null = Set-LabRunState `
                    -RunId $runState.RunId `
                    -NewState 'CLEANED_UP' `
                    -Reason "Cleanup: $cleanupStatus" `
                    -StateRoot $effectiveStateRoot
                Set-LabProviderSubRunsState `
                    -RunId $runState.RunId `
                    -Providers $providers `
                    -NewState 'CLEANED_UP' `
                    -Reason "Cleanup: $cleanupStatus" `
                    -StateRoot $effectiveStateRoot
                $null = Remove-LabSecrets -Path $runState.RunDir
            }
            else {
                $null = Set-LabRunState `
                    -RunId $runState.RunId `
                    -NewState 'RECOVERY_REQUIRED' `
                    -Reason "Cleanup: $cleanupStatus" `
                    -StateRoot $effectiveStateRoot
                foreach ($providerCleanup in @($cleanupResult.ProviderSubRuns)) {
                    $providerState = if ($providerCleanup.Errors -eq 0) { 'CLEANED_UP' } else { 'RECOVERY_REQUIRED' }
                    Set-LabProviderSubRunState `
                        -RunId $runState.RunId `
                        -Provider $providerCleanup.Provider `
                        -NewState $providerState `
                        -Reason "Cleanup: $($providerCleanup.Status)" `
                        -StateRoot $effectiveStateRoot
                }
                $cleanupStatus = 'RECOVERY_REQUIRED'
            }
        }
        catch {
            $cleanupFailure = $_
            $cleanupStatus = 'RECOVERY_REQUIRED'
            Write-LabError "Cleanup fehlgeschlagen: $($cleanupFailure.Exception.Message)"

            try {
                $cleanupState = Get-LabRunState `
                    -RunId $runState.RunId `
                    -StateRoot $effectiveStateRoot
                if ($cleanupState.state -eq 'CLEANUP_RUNNING') {
                    $null = Set-LabRunState `
                        -RunId $runState.RunId `
                        -NewState 'RECOVERY_REQUIRED' `
                        -Reason $cleanupFailure.Exception.Message `
                        -StateRoot $effectiveStateRoot
                }
            }
            catch {
                Write-LabError "Recovery-State konnte nicht gespeichert werden: $($_.Exception.Message)"
            }
        }

        throw "Lab-Erstellung fehlgeschlagen. Cleanup-Status: $cleanupStatus. Ursache: $($provisioningError.Exception.Message)"
    }
}
