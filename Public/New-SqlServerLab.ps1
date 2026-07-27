<#
.SYNOPSIS
    Erstellt eine neue SQL-Server-Testumgebung.
.DESCRIPTION
    End-to-End Cmdlet: Resource Assessment -> State -> Provider -> SQL-Ready ->
    Server-Konfiguration -> Datenbanken/Restore -> PostProvision.
    Unterstuetzt Ad-hoc-Parameter und Manifest-Modus.
.EXAMPLE
    $lab = New-SqlServerLab -Version '2025' -Provider docker
.EXAMPLE
    $lab = New-SqlServerLab -Manifest './Schemas/example-lab.json'
#>
function New-SqlServerLab {
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

    # =========================================================================
    # 1. Manifest oder Ad-hoc-Parameter aufloesen
    # =========================================================================
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

    # =========================================================================
    # 2. Versions-Pruefung
    # =========================================================================
    foreach ($instance in $resolved.instances) {
        $versionCheck = Test-SqlServerVersionSupported -VersionId $instance.version
        if (-not $versionCheck.Supported) {
            throw "Version $($instance.version): $($versionCheck.Message)"
        }
        if ($versionCheck.Message) {
            Write-LabWarning $versionCheck.Message
        }
    }

    # =========================================================================
    # 3. Resource Assessment
    # =========================================================================
    if (-not $SkipAssessment) {
        Write-LabInfo 'Resource Assessment...'
        $assessment = Test-LabResources `
            -Instances $resolved.instances `
            -Provider $resolved.instances[0].provider

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

    # =========================================================================
    # 4. SA-Passwort
    # =========================================================================
    if (-not $SaPassword) {
        Write-LabInfo 'SA-Passwort wird benoetigt.'
        $SaPassword = Read-SaPassword
    }

    # =========================================================================
    # 5. State und Cleanup-Plan initialisieren
    # =========================================================================
    $runState = New-LabRunState `
        -StateRoot $StateRoot `
        -Metadata @{ name = $resolved.name }

    Write-LabStatus -Label 'RunId' -Value $runState.RunId
    Write-LabStatus -Label 'ScopeId' -Value $runState.ScopeId

    $null = New-CleanupPlan `
        -RunDir $runState.RunDir `
        -RunId $runState.RunId `
        -ScopeId $runState.ScopeId

    $null = Save-LabSecret `
        -Path $runState.RunDir `
        -Name 'sa-password' `
        -Secret $SaPassword

    $null = Set-LabRunState `
        -RunId $runState.RunId `
        -NewState 'PROVISIONING' `
        -Reason 'Provider-Start' `
        -StateRoot $StateRoot

    $labInstances = @()
    $cleanupStatus = 'NOT_STARTED'

    try {
        # =====================================================================
        # 6. Instanzen provisionieren
        # =====================================================================
        foreach ($instance in $resolved.instances) {
            Write-LabInfo "Instanz '$($instance.id)' erstellen ($($instance.version), $($instance.provider))..."

            switch ($instance.provider) {
                'docker' {
                    $container = New-DockerInstance `
                        -VersionId $instance.version `
                        -RunId $runState.RunId `
                        -ScopeId $runState.ScopeId `
                        -InstanceId $instance.id `
                        -Port $Port `
                        -SaPassword $SaPassword `
                        -Profile $instance.profile `
                        -Drives $instance.drives

                    $null = Add-CleanupStep `
                        -RunDir $runState.RunDir `
                        -ResourceType 'container' `
                        -ResourceId $container.ContainerName `
                        -Action 'remove' `
                        -Compensation "docker rm -f $($container.ContainerName)"

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
                        Provider         = 'docker'
                        Host             = '127.0.0.1'
                        Port             = $container.Port
                        ContainerId      = $container.ContainerId
                        ContainerName    = $container.ContainerName
                        ConnectionString = New-SqlConnectionString -Port $container.Port
                        Databases        = @()
                        Status           = 'Running'
                    }
                }
                'podman' {
                    $container = New-PodmanInstance `
                        -VersionId $instance.version `
                        -RunId $runState.RunId `
                        -ScopeId $runState.ScopeId `
                        -InstanceId $instance.id `
                        -Port $Port `
                        -SaPassword $SaPassword `
                        -Profile $instance.profile `
                        -Drives $instance.drives

                    $null = Add-CleanupStep `
                        -RunDir $runState.RunDir `
                        -ResourceType 'container' `
                        -ResourceId $container.ContainerName `
                        -Action 'remove' `
                        -Compensation "podman rm -f $($container.ContainerName)"

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
                        Provider         = 'podman'
                        Host             = '127.0.0.1'
                        Port             = $container.Port
                        ContainerId      = $container.ContainerId
                        ContainerName    = $container.ContainerName
                        ConnectionString = New-SqlConnectionString -Port $container.Port
                        Databases        = @()
                        Status           = 'Running'
                    }
                }
                default {
                    throw "Provider '$($instance.provider)' ist noch nicht implementiert."
                }
            }
        }

        $null = Set-LabRunState `
            -RunId $runState.RunId `
            -NewState 'SQL_READY' `
            -Reason 'Alle Instanzen bereit' `
            -StateRoot $StateRoot

        # =====================================================================
        # 6b. Server-Konfiguration
        # =====================================================================
        foreach ($instance in ($resolved.instances | Where-Object { $_.serverConfig })) {
            $labInstance = $labInstances | Where-Object { $_.Id -eq $instance.id } | Select-Object -First 1
            Write-LabInfo "Server-Konfiguration auf '$($instance.id)' anwenden..."

            Set-LabServerConfig `
                -Config $instance.serverConfig `
                -HostName $labInstance.Host `
                -Port $labInstance.Port `
                -SaPassword $SaPassword `
                -ContainerName $labInstance.ContainerName

            if ($instance.serverConfig.externalScripts -and $instance.serverConfig.externalScripts.languages) {
                Write-LabInfo "External Languages auf '$($instance.id)' installieren..."
                Install-LabExternalLanguages `
                    -ContainerName $labInstance.ContainerName `
                    -Config $instance.serverConfig.externalScripts `
                    -HostName $labInstance.Host `
                    -Port $labInstance.Port `
                    -SaPassword $SaPassword
            }
        }

        # =====================================================================
        # 7. Neue Datenbanken anlegen
        # Restore- und Sample-Datenbanken werden hier bewusst uebersprungen.
        # =====================================================================
        $createdDatabaseCount = 0

        foreach ($instance in $resolved.instances) {
            $labInstance = $labInstances | Where-Object { $_.Id -eq $instance.id } | Select-Object -First 1

            foreach ($database in ($instance.databases | Where-Object { -not $_.restore })) {
                Write-LabInfo "Datenbank '$($database.name)' auf '$($instance.id)' anlegen..."

                $databaseResult = New-LabDatabase `
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
                    Set-LabDatabaseOptions `
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
            -StateRoot $StateRoot

        # =====================================================================
        # 7b. Datenbank-Restores
        # =====================================================================
        foreach ($instance in $resolved.instances) {
            $labInstance = $labInstances | Where-Object { $_.Id -eq $instance.id } | Select-Object -First 1

            foreach ($database in ($instance.databases | Where-Object { $_.restore })) {
                Write-LabInfo "Restore '$($database.name)' auf '$($instance.id)' von: $($database.restore.source)"

                $restoreResult = Restore-LabDatabase `
                    -HostName $labInstance.Host `
                    -Port $labInstance.Port `
                    -SaPassword $SaPassword `
                    -BackupSource $database.restore.source `
                    -DatabaseName $database.name `
                    -ContainerName $labInstance.ContainerName `
                    -Replace:($database.restore.replace) `
                    -StateRoot $StateRoot

                if (-not $restoreResult.Success) {
                    throw "Restore fehlgeschlagen: $($restoreResult.Message)"
                }

                if ($database.options) {
                    Set-LabDatabaseOptions `
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

        # =====================================================================
        # 8. PostProvision-Skripte
        # =====================================================================
        $hasPostProvision = $resolved.instances | Where-Object { $_.postProvision.Count -gt 0 }
        if ($hasPostProvision) {
            foreach ($instance in $resolved.instances) {
                $labInstance = $labInstances | Where-Object { $_.Id -eq $instance.id } | Select-Object -First 1
                $postDatabase = if ($instance.databases.Count -gt 0) { $instance.databases[0].name } else { 'master' }

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
                        Write-LabError "  $($scriptResult.Message)"
                        throw $scriptResult.Message
                    }

                    Write-LabSuccess "  $($scriptResult.Message) ($($scriptResult.Batches) Batches, $($scriptResult.Duration.TotalSeconds.ToString('F1'))s)"
                }
            }

            $null = Set-LabRunState `
                -RunId $runState.RunId `
                -NewState 'POST_PROVISIONED' `
                -Reason 'Skripte ausgefuehrt' `
                -StateRoot $StateRoot
        }

        # =====================================================================
        # 9. Ergebnis speichern und ausgeben
        # =====================================================================
        $null = Set-LabRunState `
            -RunId $runState.RunId `
            -NewState 'RUNNING' `
            -Reason 'Umgebung bereit' `
            -StateRoot $StateRoot

        $connectionInfo = @{
            runId     = $runState.RunId
            scopeId   = $runState.ScopeId
            instances = $labInstances | ForEach-Object {
                @{
                    id               = $_.Id
                    host             = $_.Host
                    port             = $_.Port
                    version          = $_.Version
                    provider         = $_.Provider
                    connectionString = $_.ConnectionString
                    databases        = $_.Databases
                }
            }
        }

        $connectionInfo |
            ConvertTo-Json -Depth 10 |
            Set-Content -Path (Join-Path $runState.RunDir 'connection-info.json') -Encoding utf8

        Write-Host ''
        Write-LabHeader 'Umgebung bereit'
        Write-LabStatus -Label 'RunId' -Value $runState.RunId -Color 'Green'
        foreach ($labInstance in $labInstances) {
            Write-LabStatus `
                -Label $labInstance.Id `
                -Value "$($labInstance.Host):$($labInstance.Port) (SQL $($labInstance.Version))" `
                -Color 'Green'
        }
        Write-Host ''

        return [PSCustomObject]@{
            RunId     = $runState.RunId
            ScopeId   = $runState.ScopeId
            State     = 'Running'
            Name      = $resolved.name
            Instances = $labInstances
            StateRoot = $runState.StateRoot
        }
    }
    catch {
        $provisioningError = $_
        Write-LabError "Provisionierung fehlgeschlagen: $provisioningError"

        $null = Add-LabRunError `
            -RunId $runState.RunId `
            -Message $provisioningError.ToString() `
            -Component 'New-SqlServerLab' `
            -StateRoot $StateRoot

        try {
            $null = Set-LabRunState `
                -RunId $runState.RunId `
                -NewState 'PROVISION_FAILED' `
                -Reason $provisioningError.ToString() `
                -StateRoot $StateRoot

            $null = Set-LabRunState `
                -RunId $runState.RunId `
                -NewState 'CLEANUP_PENDING' `
                -Reason 'Auto-Cleanup nach Fehler' `
                -StateRoot $StateRoot

            Write-LabInfo 'Automatischer Cleanup...'
            $cleanupResult = Invoke-CleanupPlan `
                -RunDir $runState.RunDir `
                -ScopeId $runState.ScopeId

            $cleanupStatus = $cleanupResult.Status
            Write-LabStatus -Label 'Cleanup' -Value $cleanupStatus

            $null = Set-LabRunState `
                -RunId $runState.RunId `
                -NewState 'CLEANUP_RUNNING' `
                -Reason 'Cleanup gestartet' `
                -StateRoot $StateRoot

            $null = Set-LabRunState `
                -RunId $runState.RunId `
                -NewState 'CLEANED_UP' `
                -Reason "Cleanup: $cleanupStatus" `
                -StateRoot $StateRoot
        }
        catch {
            $cleanupStatus = 'RECOVERY_REQUIRED'
            Write-LabError "Cleanup fehlgeschlagen: $_"
        }

        throw "Lab-Erstellung fehlgeschlagen. Cleanup-Status: $cleanupStatus. Ursache: $($provisioningError.Exception.Message)"
    }
}
