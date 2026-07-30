function Add-LabInstanceCleanupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)]$RunState
    )

    $containerName = "sql-lab-$($Instance.id)-$($RunState.RunId.Substring(0, 8))"

    foreach ($drive in @($Instance.drives | Where-Object { $_ -and $_.containerPath -and -not $_.hostPath })) {
        $volumeName = "sql-lab-${containerName}-$($drive.id)"
        $null = Add-CleanupStep `
            -RunDir $RunState.RunDir `
            -ResourceType 'volume' `
            -ResourceId $volumeName `
            -Action 'remove' `
            -Provider $Instance.provider `
            -ProviderSubRunId "provider-$($Instance.provider)" `
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
        -Compensation "$($Instance.provider) rm -f $containerName"
}

function New-LabProviderContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [int]$Port = 0
    )

    switch ($Instance.provider) {
        'docker' {
            return New-DockerInstance `
                -VersionId $Instance.version `
                -RunId $RunState.RunId `
                -ScopeId $RunState.ScopeId `
                -InstanceId $Instance.id `
                -Port $Port `
                -SaPassword $SaPassword `
                -Profile $Instance.profile `
                -Drives $Instance.drives
        }
        'podman' {
            return New-PodmanInstance `
                -VersionId $Instance.version `
                -RunId $RunState.RunId `
                -ScopeId $RunState.ScopeId `
                -InstanceId $Instance.id `
                -Port $Port `
                -SaPassword $SaPassword `
                -Profile $Instance.profile `
                -Drives $Instance.drives
        }
        default {
            throw "Provider '$($Instance.provider)' ist noch nicht implementiert."
        }
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
    .PARAMETER Manifest
        Pfad zu einer vorhandenen JSON-Manifestdatei. Relative lokale Pfade im
        Manifest werden relativ zu deren Verzeichnis aufgeloest.
    .PARAMETER SaPassword
        SA-Passwort als SecureString. Ohne Angabe wird es interaktiv abgefragt.
    .PARAMETER StateRoot
        Optionales State-Stammverzeichnis. Ohne Angabe wird der Framework-Default
        fuer das aktuelle Betriebssystem verwendet.
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
        $lab = New-SqlServerLab -Manifest './Schemas/example-performance-lab.json'

        Validiert und provisioniert die im Manifest beschriebene Umgebung.
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

        [Parameter(ParameterSetName = 'Manifest', Mandatory)]
        [string]$Manifest,

        [SecureString]$SaPassword,
        [string]$StateRoot,
        [switch]$SkipAssessment
    )

    $ErrorActionPreference = 'Stop'
    Write-LabHeader 'SQL Server Lab - Neue Umgebung'

    if ($PSCmdlet.ParameterSetName -eq 'Manifest') {
        Write-LabInfo "Manifest: $Manifest"
        $resolved = Read-LabManifest -Path $Manifest
    }
    else {
        $resolved = [PSCustomObject]@{
            name      = "adhoc-$Version-$Provider"
            instances = @(
                [PSCustomObject]@{
                    id            = $InstanceId
                    version       = $Version
                    provider      = $Provider
                    os            = 'linux'
                    profile       = $Profile
                    collation     = 'SQL_Latin1_General_CP1_CS_AS'
                    databases     = @()
                    drives        = @()
                    serverConfig  = $null
                    software      = @()
                    postProvision = @()
                }
            )
            resourceOverrides = $null
            manifestPath      = $null
        }
    }

    Write-LabInfo "Umgebung: $($resolved.name) ($($resolved.instances.Count) Instanz(en))"

    $providers = @($resolved.instances | ForEach-Object { $_.provider } | Sort-Object -Unique)
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

    $runState = New-LabRunState `
        -StateRoot $StateRoot `
        -Metadata @{ name = $resolved.name } `
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

        foreach ($instance in $resolved.instances) {
            Add-LabInstanceCleanupPlan -Instance $instance -RunState $runState
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

        $labInstances = @()

        foreach ($instance in $resolved.instances) {
            Write-LabInfo "Instanz '$($instance.id)' erstellen ($($instance.version), $($instance.provider))..."

            $container = New-LabProviderContainer `
                -Instance $instance `
                -RunState $runState `
                -SaPassword $SaPassword `
                -Port $Port

            $versionDefinition = Get-SqlServerVersion -VersionId $instance.version
            $readiness = Wait-SqlReady `
                -Port $container.Port `
                -SaPassword $SaPassword `
                -TimeoutSeconds 120 `
                -ExpectedMajorVersion $versionDefinition.major

            if (-not $readiness.Ready) {
                throw "SQL Server nicht bereit: $($readiness.Message)"
            }

            $labInstances += [PSCustomObject]@{
                Id               = $instance.id
                Version          = $instance.version
                Provider         = $instance.provider
                Host             = '127.0.0.1'
                Port             = $container.Port
                ContainerId      = $container.ContainerId
                ContainerName    = $container.ContainerName
                ConnectionString = New-SqlConnectionString -Port $container.Port
                Databases        = @()
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

            if ($instance.serverConfig.externalScripts -and $instance.serverConfig.externalScripts.languages) {
                Write-LabInfo "External Languages auf '$($instance.id)' installieren..."
                $null = Install-LabExternalLanguages `
                    -ContainerName $labInstance.ContainerName `
                    -Config $instance.serverConfig.externalScripts `
                    -HostName $labInstance.Host `
                    -Port $labInstance.Port `
                    -SaPassword $SaPassword
            }
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
                    -StateRoot $effectiveStateRoot `
                    -RunDirectory $runState.RunDir

                if (-not $restoreResult.Success) {
                    throw "Restore fehlgeschlagen: $($restoreResult.Message)"
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
            }
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
                    containerId      = $_.ContainerId
                    containerName    = $_.ContainerName
                    connectionString = $_.ConnectionString
                    databases        = @($_.Databases)
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
