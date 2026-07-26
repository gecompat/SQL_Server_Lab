<#
.SYNOPSIS
    Erstellt eine neue SQL-Server-Testumgebung.
.DESCRIPTION
    End-to-End Cmdlet: Resource Assessment -> State -> Provider -> SQL-Ready -> Datenbanken -> PostProvision.
    Unterstuetzt Ad-hoc-Parameter und Manifest-Modus.
.EXAMPLE
    $lab = New-SqlServerLab -Version '2025' -Provider Docker
.EXAMPLE
    $lab = New-SqlServerLab -Manifest './scenarios/my-lab.json'
#>
function New-SqlServerLab {
    [CmdletBinding(DefaultParameterSetName = 'AdHoc')]
    param(
        # --- Ad-hoc Parameter ---
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

        # --- Manifest Parameter ---
        [Parameter(ParameterSetName = 'Manifest', Mandatory)]
        [string]$Manifest,

        # --- Gemeinsame Parameter ---
        [SecureString]$SaPassword,
        [string]$StateRoot,
        [switch]$SkipAssessment
    )

    $ErrorActionPreference = 'Stop'

    Write-LabHeader 'SQL Server Lab - Neue Umgebung'

    # =========================================================================
    # 1. Manifest oder Ad-hoc aufloesen
    # =========================================================================
    if ($PSCmdlet.ParameterSetName -eq 'Manifest') {
        Write-LabInfo "Manifest: $Manifest"
        $resolved = Read-LabManifest -Path $Manifest
    }
    else {
        # Ad-hoc zu internem Manifest-Objekt konvertieren
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
    foreach ($inst in $resolved.instances) {
        $vCheck = Test-SqlServerVersionSupported -VersionId $inst.version
        if (-not $vCheck.Supported) {
            throw "Version $($inst.version): $($vCheck.Message)"
        }
        if ($vCheck.Message) { Write-LabWarning $vCheck.Message }
    }

    # =========================================================================
    # 3. Resource Assessment
    # =========================================================================
    if (-not $SkipAssessment) {
        Write-LabInfo 'Resource Assessment...'
        $assessment = Test-LabResources -Instances $resolved.instances -Provider $resolved.instances[0].provider

        foreach ($detail in $assessment.Details) {
            $color = switch ($detail.Status) {
                'RESOURCE_OK'      { 'Green' }
                'RESOURCE_WARNING' { 'Yellow' }
                default            { 'Red' }
            }
            Write-LabStatus -Label $detail.Category -Value "$($detail.Status): $($detail.Message)" -Color $color
        }

        if ($assessment.Status -eq 'RESOURCE_HARD_BLOCK') {
            throw "Resource Assessment HARD_BLOCK: Umgebung kann nicht erstellt werden."
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
    # 5. State initialisieren
    # =========================================================================
    $runState = New-LabRunState -StateRoot $StateRoot -Metadata @{ name = $resolved.name }
    Write-LabStatus -Label 'RunId' -Value $runState.RunId
    Write-LabStatus -Label 'ScopeId' -Value $runState.ScopeId

    # Cleanup-Plan vorbereiten
    $null = New-CleanupPlan -RunDir $runState.RunDir -RunId $runState.RunId -ScopeId $runState.ScopeId

    # SA-Passwort speichern
    $null = Save-LabSecret -Path $runState.RunDir -Name 'sa-password' -Secret $SaPassword

    # =========================================================================
    # 6. Instanzen provisionieren
    # =========================================================================
    $null = Set-LabRunState -RunId $runState.RunId -NewState 'PROVISIONING' -Reason 'Provider-Start' -StateRoot $StateRoot

    $labInstances = @()

    try {
        foreach ($inst in $resolved.instances) {
            Write-LabInfo "Instanz '$($inst.id)' erstellen ($($inst.version), $($inst.provider))..."

            switch ($inst.provider) {
                'docker' {
                    $container = New-DockerInstance `
                        -VersionId $inst.version `
                        -RunId $runState.RunId `
                        -ScopeId $runState.ScopeId `
                        -InstanceId $inst.id `
                        -Port $Port `
                        -SaPassword $SaPassword `
                        -Profile $inst.profile `
                        -Drives $inst.drives

                    # Cleanup-Plan aktualisieren
                    $null = Add-CleanupStep -RunDir $runState.RunDir `
                        -ResourceType 'container' `
                        -ResourceId $container.ContainerName `
                        -Action 'remove' `
                        -Compensation "docker rm -f $($container.ContainerName)"

                    # SQL-Readiness abwarten
                    $version = Get-SqlServerVersion -VersionId $inst.version
                    $readiness = Wait-SqlReady `
                        -Port $container.Port `
                        -SaPassword $SaPassword `
                        -TimeoutSeconds 120 `
                        -ExpectedMajorVersion $version.major

                    if (-not $readiness.Ready) {
                        throw "SQL Server nicht bereit: $($readiness.Message)"
                    }

                    $labInstances += [PSCustomObject]@{
                        Id               = $inst.id
                        Version          = $inst.version
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
                        -VersionId $inst.version `
                        -RunId $runState.RunId `
                        -ScopeId $runState.ScopeId `
                        -InstanceId $inst.id `
                        -Port $Port `
                        -SaPassword $SaPassword `
                        -Profile $inst.profile `
                        -Drives $inst.drives

                    # Cleanup-Plan aktualisieren
                    $null = Add-CleanupStep -RunDir $runState.RunDir `
                        -ResourceType 'container' `
                        -ResourceId $container.ContainerName `
                        -Action 'remove' `
                        -Compensation "podman rm -f $($container.ContainerName)"

                    # SQL-Readiness abwarten
                    $version = Get-SqlServerVersion -VersionId $inst.version
                    $readiness = Wait-SqlReady `
                        -Port $container.Port `
                        -SaPassword $SaPassword `
                        -TimeoutSeconds 120 `
                        -ExpectedMajorVersion $version.major

                    if (-not $readiness.Ready) {
                        throw "SQL Server nicht bereit: $($readiness.Message)"
                    }

                    $labInstances += [PSCustomObject]@{
                        Id               = $inst.id
                        Version          = $inst.version
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
                    throw "Provider '$($inst.provider)' nicht implementiert."
                }
            }
        }

        $null = Set-LabRunState -RunId $runState.RunId -NewState 'SQL_READY' -Reason 'Alle Instanzen bereit' -StateRoot $StateRoot

        # =====================================================================
        # 6b. Server-Konfiguration anwenden (Memory, TempDB, MaxDOP, etc.)
        # =====================================================================
        $hasServerConfig = $resolved.instances | Where-Object { $_.serverConfig }
        if ($hasServerConfig) {
            foreach ($inst in ($resolved.instances | Where-Object { $_.serverConfig })) {
                $labInst = $labInstances | Where-Object { $_.Id -eq $inst.id }
                Write-LabInfo "Server-Konfiguration auf '$($inst.id)' anwenden..."
                Set-LabServerConfig `
                    -Config $inst.serverConfig `
                    -HostName $labInst.Host `
                    -Port $labInst.Port `
                    -SaPassword $SaPassword `
                    -ContainerName $labInst.ContainerName

                # External Languages (R, Python, Java) installieren
                if ($inst.serverConfig.externalScripts -and $inst.serverConfig.externalScripts.languages) {
                    Write-LabInfo "External Languages auf '$($inst.id)' installieren..."
                    Install-LabExternalLanguages `
                        -ContainerName $labInst.ContainerName `
                        -Config $inst.serverConfig.externalScripts `
                        -HostName $labInst.Host `
                        -Port $labInst.Port `
                        -SaPassword $SaPassword
                }
            }
        }

        # =====================================================================
        # 7. Datenbanken anlegen
        # =====================================================================
        $hasDbWork = $resolved.instances | Where-Object { $_.databases.Count -gt 0 }
        if ($hasDbWork) {
            foreach ($inst in $resolved.instances) {
                $labInst = $labInstances | Where-Object { $_.Id -eq $inst.id }
                foreach ($db in $inst.databases) {
                    Write-LabInfo "Datenbank '$($db.name)' auf '$($inst.id)' anlegen..."
                    $dbResult = New-LabDatabase `
                        -HostName $labInst.Host `
                        -Port $labInst.Port `
                        -SaPassword $SaPassword `
                        -DatabaseName $db.name `
                        -Collation $db.collation `
                        -DataFiles $db.files.data `
                        -LogFiles $db.files.log `
                        -Options $db.options

                    $labInst.Databases += $db.name

                    # DB-Optionen anwenden (Recovery Model, RCSI, Query Store, etc.)
                    if ($db.options) {
                        Set-LabDatabaseOptions `
                            -DatabaseName $db.name `
                            -Options $db.options `
                            -HostName $labInst.Host `
                            -Port $labInst.Port `
                            -SaPassword $SaPassword
                    }
                }
            }
            $null = Set-LabRunState -RunId $runState.RunId -NewState 'DATABASES_CREATED' -Reason 'Datenbanken angelegt' -StateRoot $StateRoot
        }
        else {
            # Keine Datenbanken angefordert - State trotzdem durchlaufen
            $null = Set-LabRunState -RunId $runState.RunId -NewState 'DATABASES_CREATED' -Reason 'Keine Datenbanken angefordert' -StateRoot $StateRoot
        }

        # =====================================================================
        # 7b. Datenbank-Restores (wenn im Manifest definiert)
        # =====================================================================
        $hasRestoreWork = $resolved.instances | Where-Object {
            $_.databases | Where-Object { $_.restore }
        }
        if ($hasRestoreWork) {
            foreach ($inst in $resolved.instances) {
                $labInst = $labInstances | Where-Object { $_.Id -eq $inst.id }
                foreach ($db in $inst.databases) {
                    if ($db.restore) {
                        Write-LabInfo "Restore '$($db.name)' auf '$($inst.id)' von: $($db.restore.source)"
                        $restoreResult = Restore-LabDatabase `
                            -HostName $labInst.Host `
                            -Port $labInst.Port `
                            -SaPassword $SaPassword `
                            -BackupSource $db.restore.source `
                            -DatabaseName $db.name `
                            -ContainerName $labInst.ContainerName `
                            -Replace:($db.restore.replace) `
                            -StateRoot $StateRoot

                        if (-not $restoreResult.Success) {
                            throw "Restore fehlgeschlagen: $($restoreResult.Message)"
                        }
                        $labInst.Databases += $db.name
                    }
                }
            }
        }

        # =====================================================================
        # 8. PostProvision-Skripte
        # =====================================================================
        $hasPostProvision = $resolved.instances | Where-Object { $_.postProvision.Count -gt 0 }
        if ($hasPostProvision) {
            foreach ($inst in $resolved.instances) {
                $labInst = $labInstances | Where-Object { $_.Id -eq $inst.id }
                # Zieldatenbank fuer PostProvision: erste DB der Instanz (oder master)
                $postDb = if ($inst.databases.Count -gt 0) { $inst.databases[0].name } else { 'master' }

                foreach ($script in $inst.postProvision) {
                    Write-LabInfo "PostProvision: $(Split-Path $script -Leaf) auf '$($inst.id)/$postDb'..."
                    $result = Invoke-LabSqlScript `
                        -ScriptPath $script `
                        -HostName $labInst.Host `
                        -Port $labInst.Port `
                        -SaPassword $SaPassword `
                        -Database $postDb `
                        -KeepConnection

                    if ($result.Success) {
                        Write-LabSuccess "  $($result.Message) ($($result.Batches) Batches, $($result.Duration.TotalSeconds.ToString('F1'))s)"
                    }
                    else {
                        Write-LabError "  $($result.Message)"
                        throw $result.Message
                    }
                }
            }
            $null = Set-LabRunState -RunId $runState.RunId -NewState 'POST_PROVISIONED' -Reason 'Skripte ausgefuehrt' -StateRoot $StateRoot
        }

        # =====================================================================
        # 9. Fertig
        # =====================================================================
        $null = Set-LabRunState -RunId $runState.RunId -NewState 'RUNNING' -Reason 'Umgebung bereit' -StateRoot $StateRoot

        # Connection-Info speichern
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
        $connectionInfo | ConvertTo-Json -Depth 10 |
            Set-Content -Path (Join-Path $runState.RunDir 'connection-info.json') -Encoding utf8 | Out-Null

        Write-Host ''
        Write-LabHeader 'Umgebung bereit'
        Write-LabStatus -Label 'RunId' -Value $runState.RunId -Color 'Green'
        foreach ($li in $labInstances) {
            Write-LabStatus -Label "$($li.Id)" -Value "$($li.Host):$($li.Port) (SQL $($li.Version))" -Color 'Green'
        }
        Write-Host ''

        # Rueckgabe-Objekt
        return [PSCustomObject]@{
            RunId      = $runState.RunId
            ScopeId    = $runState.ScopeId
            State      = 'Running'
            Name       = $resolved.name
            Instances  = $labInstances
            StateRoot  = $runState.StateRoot
        }
    }
    catch {
        # Fehler: State + Cleanup
        Write-LabError "Provisionierung fehlgeschlagen: $_"
        $null = Add-LabRunError -RunId $runState.RunId -Message $_.ToString() -Component 'New-SqlServerLab' -StateRoot $StateRoot

        try {
            $null = Set-LabRunState -RunId $runState.RunId -NewState 'PROVISION_FAILED' -Reason $_.ToString() -StateRoot $StateRoot
            $null = Set-LabRunState -RunId $runState.RunId -NewState 'CLEANUP_PENDING' -Reason 'Auto-Cleanup nach Fehler' -StateRoot $StateRoot

            Write-LabInfo 'Automatischer Cleanup...'
            $cleanupResult = Invoke-CleanupPlan -RunDir $runState.RunDir -ScopeId $runState.ScopeId
            Write-LabStatus -Label 'Cleanup' -Value $cleanupResult.Status

            $null = Set-LabRunState -RunId $runState.RunId -NewState 'CLEANUP_RUNNING' -Reason 'Cleanup gestartet' -StateRoot $StateRoot
            $null = Set-LabRunState -RunId $runState.RunId -NewState 'CLEANED_UP' -Reason "Cleanup: $($cleanupResult.Status)" -StateRoot $StateRoot
        }
        catch {
            Write-LabError "Cleanup fehlgeschlagen: $_"
        }

        throw "Lab-Erstellung fehlgeschlagen. Cleanup-Status: $($cleanupResult.Status). Ursache: $($_.Exception.Message)"
    }
}
