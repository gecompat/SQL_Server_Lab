function Assert-OnlyExpectedTopLevelEntries {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string[]] $ExpectedNames
    )

    $unexpected = @(Get-ChildItem -LiteralPath $Root -Force | Where-Object { $_.Name -notin $ExpectedNames })
    if ($unexpected.Count -gt 0) {
        $names = ($unexpected.Name -join ', ')
        throw "Unter '$Root' wurden unerwartete Einträge gefunden: $names. Der Pfad wird nicht gelöscht."
    }
}

function Get-OwnedProjectVolumeNames {
    param([Parameter(Mandatory)][hashtable] $Env)

    $projectName = [string] $Env.COMPOSE_PROJECT_NAME
    $scopeId = [string] $Env.QUICKSTART_SCOPE_ID
    $volumeNames = @(
        Invoke-ExternalCommand -FilePath 'docker' -Arguments @(
            'volume', 'ls',
            '--filter', "label=com.docker.compose.project=$projectName",
            '--format', '{{.Name}}'
        ) -Quiet | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }
    )

    foreach ($volumeName in $volumeNames) {
        $name = ([string] $volumeName).Trim()
        $labels = Get-FirstOutputLine -InputObject @(
            Invoke-ExternalCommand -FilePath 'docker' -Arguments @(
                'volume', 'inspect', '--format',
                '{{ index .Labels "quickstart.owner" }}|{{ index .Labels "quickstart.scope" }}',
                $name
            ) -Quiet
        )
        if ($labels -ne "SQL_SERVER_ANALYZE_QUICKSTART|$scopeId") {
            throw "Volume '$name' trägt nicht den erwarteten QuickStart-Owner- und Scope-Marker. Es erfolgt keine Löschung."
        }
        $name
    }
}

function Remove-ManagedData {
    param([Parameter(Mandatory)][hashtable] $Env)

    Assert-ManagedRoots -Env $Env
    $layout = [string] $Env.STORAGE_LAYOUT
    $labRoot = Get-CanonicalPath -Path ([string] $Env.LAB_ROOT)
    $dataRoot = Get-CanonicalPath -Path ([string] $Env.DATA_ROOT)
    $logRoot = Get-CanonicalPath -Path ([string] $Env.LOG_ROOT)

    if ($layout -eq 'SINGLE_ROOT') {
        Assert-OnlyExpectedTopLevelEntries -Root $labRoot -ExpectedNames @($script:MarkerFileName, 'control', 'backup', 'data', 'log')
        Remove-Item -LiteralPath $labRoot -Recurse -Force
        return
    }

    Assert-OnlyExpectedTopLevelEntries -Root $labRoot -ExpectedNames @($script:MarkerFileName, 'control', 'backup')
    Assert-OnlyExpectedTopLevelEntries -Root $dataRoot -ExpectedNames @($script:MarkerFileName, '2019', '2022', '2025')
    Assert-OnlyExpectedTopLevelEntries -Root $logRoot -ExpectedNames @($script:MarkerFileName, '2019', '2022', '2025')

    foreach ($root in @($logRoot, $dataRoot, $labRoot)) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

function Remove-Environment {
    Assert-DockerReady
    $envValues = Read-EnvFile
    Assert-ManagedRoots -Env $envValues
    Assert-DockerResourceOwnership -Env $envValues

    Write-Warning 'Remove/Uninstall entfernt ausschließlich Ressourcen dieses Compose-Projekts. Docker-Images und fremde Projekte bleiben unberührt.'
    if (-not (Read-YesNo -Prompt 'QuickStart-Container und Projektnetzwerk entfernen?' -Default $false)) {
        Write-Host 'Remove/Uninstall wurde abgebrochen.'
        return
    }

    $deleteManagedData = Read-YesNo -Prompt 'Auch Docker-Volumes und die ausschließlich markierten Lab-Datenpfade vollständig löschen?' -Default $false
    $managedVolumeNames = if ($deleteManagedData) {
        @(Get-OwnedProjectVolumeNames -Env $envValues)
    }
    else {
        @()
    }

    Invoke-Compose -Env $envValues -Arguments @('down', '--remove-orphans', '--timeout', '60') | Out-Null

    if ($deleteManagedData) {
        foreach ($volumeName in $managedVolumeNames) {
            Invoke-ExternalCommand -FilePath 'docker' -Arguments @('volume', 'rm', ([string] $volumeName)) -Quiet | Out-Null
        }
        Remove-ManagedData -Env $envValues
        Remove-Item -LiteralPath $script:EnvPath -Force
        Write-Host 'Container, Projektnetzwerk, alle scopegebundenen Docker-Volumes, markierte Lab-Daten und lokale .env wurden entfernt.'
    }
    else {
        Write-Host 'Container und Projektnetzwerk wurden entfernt. Docker-Volumes, Lab-Daten und .env bleiben für einen späteren Neustart erhalten.'
    }
}

function Invoke-Setup {
    $configuration = Get-SetupConfiguration
    try {
        Initialize-ManagedRoots `
            -ScopeId $configuration.ScopeId `
            -StorageLayout $configuration.StorageLayout `
            -LabRoot $configuration.LabRoot `
            -DataRoot $configuration.DataRoot `
            -LogRoot $configuration.LogRoot
        Write-EnvFile -Values $configuration.Values
    }
    catch {
        $rollbackRoots = if ($configuration.StorageLayout -eq 'SINGLE_ROOT') {
            @($configuration.LabRoot)
        }
        else {
            @($configuration.LabRoot, $configuration.DataRoot, $configuration.LogRoot) | Select-Object -Unique
        }
        foreach ($root in $rollbackRoots) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                continue
            }
            try {
                $wasPreExisting = [bool] $configuration.PreExistingRoots[$root]
                $markerPath = Join-Path $root $script:MarkerFileName
                if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
                    $marker = Read-RootMarker -Root $root
                    if ($marker.ScopeId -ne $configuration.ScopeId) {
                        throw 'Scope-Marker stimmt nicht mit dem aktuellen Setup überein.'
                    }
                    if ($wasPreExisting) {
                        Get-ChildItem -LiteralPath $root -Force | Remove-Item -Recurse -Force
                    }
                    else {
                        Remove-Item -LiteralPath $root -Recurse -Force
                    }
                }
                elseif (-not $wasPreExisting -and @(Get-ChildItem -LiteralPath $root -Force).Count -eq 0) {
                    Remove-Item -LiteralPath $root -Force
                }
                else {
                    throw 'Kein passender Marker vorhanden; der Pfad bleibt unverändert.'
                }
            }
            catch {
                Write-Warning "Automatisches Rollback für '$root' wurde ausgelassen: $($_.Exception.Message)"
            }
        }
        if (Test-Path -LiteralPath $script:EnvPath) {
            Remove-Item -LiteralPath $script:EnvPath -Force
        }
        throw
    }

    Write-Host "Lokale Konfiguration wurde unter '$script:EnvPath' erzeugt."
    Write-Host 'Die Datei enthält das SA-Passwort im Klartext, ist aber durch .gitignore vom Repository ausgeschlossen.'
    if (Read-YesNo -Prompt 'Docker-Testumgebung jetzt starten?' -Default $true) {
        Start-Environment
    }
}

function Invoke-Menu {
    $hasEnvironment = Test-Path -LiteralPath $script:EnvPath -PathType Leaf
    if (-not $hasEnvironment) {
        $choice = Read-MenuChoice -Prompt 'Aktion' -Choices @{
            '1' = 'Setup: sichere lokale Konfiguration erzeugen und optional starten'
            '0' = 'Beenden'
        } -DefaultKey '1'
        if ($choice -eq '1') { Invoke-Setup }
        return
    }

    $choice = Read-MenuChoice -Prompt 'Aktion' -Choices @{
        '1' = 'Start: vorhandene Umgebung starten/reparieren und Framework installieren'
        '2' = 'Status anzeigen'
        '3' = 'Stop: Container anhalten, Daten behalten'
        '4' = 'Remove/Uninstall: nur den markierten QuickStart-Scope entfernen'
        '0' = 'Beenden'
    } -DefaultKey '2'

    switch ($choice) {
        '1' { Start-Environment }
        '2' { Show-Status }
        '3' { Stop-Environment }
        '4' { Remove-Environment }
    }
}
