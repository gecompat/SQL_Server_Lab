<#
.SYNOPSIS
    Inventarisiert alle bekannten SQL_Server_Lab-Daten und Runtime-Ressourcen.
.DESCRIPTION
    Der Audit ist read-only. Fremde, verwaiste oder wegen eines nicht erreichbaren
    Providers unpruefbare Ressourcen werden gemeldet, aber niemals entfernt.
.PARAMETER NoWrite
    Gibt den Audit nur zurueck und schreibt kein JSON-Artefakt.
#>
function Get-SqlServerLabCleanupAudit {
    [CmdletBinding()]
    param([switch]$NoWrite)

    $configuration = Get-LabStorageConfiguration
    $knownRoots = @($configuration.LabDataLocations | ForEach-Object { [string]$_.LabDataRoot } | Where-Object { $_ })
    $rootResults = @()
    foreach ($location in @($configuration.LabDataLocations)) {
        $root = [string]$location.LabDataRoot
        $marker = if ($root -and (Test-Path -LiteralPath $root -PathType Container)) { Get-LabDataRootMarker -DataRoot $root } else { $null }
        $fileCount = 0; $totalBytes = [long]0
        if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
            $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)
            $fileCount = $files.Count
            $totalBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
        }
        $rootResults += [PSCustomObject]@{
            VolumeId=[string]$location.VolumeId; DriveLetter=[string]$location.DriveLetter; LabDataRoot=$root
            Exists=[bool]($root -and (Test-Path -LiteralPath $root -PathType Container))
            Owned=[bool]($marker -and [string]$marker.ManagedBy -eq 'SQL_Server_Lab' -and [string]$marker.ControllerId -eq [string]$configuration.ControllerId)
            ContractVersion=if ($marker) { [string]$marker.ContractVersion } else { $null }
            FileCount=$fileCount; TotalBytes=$totalBytes
        }
    }

    $stateRoot = Get-LabStateRoot
    $activeRuns = @(Get-LabActiveRuns -StateRoot $stateRoot)
    $knownRunIds = @($activeRuns | ForEach-Object { [string]$_.runId })
    $runtimeResults = @(); $containers = @(); $managedVolumes = @(); $managedNetworks = @()
    foreach ($runtime in @('docker', 'podman')) {
        $command = Get-Command $runtime -ErrorAction SilentlyContinue
        if (-not $command) {
            $runtimeResults += [PSCustomObject]@{ Provider=$runtime; Status='NOT_INSTALLED'; Message=$null }
            continue
        }
        & $runtime info 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) {
            $runtimeResults += [PSCustomObject]@{ Provider=$runtime; Status='UNAVAILABLE'; Message='Runtime ist installiert, aber nicht pruefbar.' }
            continue
        }
        $runtimeResults += [PSCustomObject]@{ Provider=$runtime; Status='AVAILABLE'; Message=$null }
        $providerContainers = if ($runtime -eq 'docker') { @(Get-DockerLabContainers) } else { @(Get-PodmanLabContainers) }
        foreach ($container in $providerContainers) {
            $containers += [PSCustomObject]@{
                Provider=$runtime; Id=[string]$container.ContainerId; Name=[string]$container.Name; Status=[string]$container.Status
                RunId=[string]$container.RunId; ScopeId=[string]$container.ScopeId; Orphan=[bool](-not $container.RunId -or [string]$container.RunId -notin $knownRunIds)
            }
        }
        foreach ($name in @(& $runtime volume ls --format '{{.Name}}' 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^sql-lab-' })) {
            $managedVolumes += [PSCustomObject]@{ Provider=$runtime; Name=$name }
        }
        foreach ($name in @(& $runtime network ls --format '{{.Name}}' 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^sql-lab-' })) {
            $managedNetworks += [PSCustomObject]@{ Provider=$runtime; Name=$name }
        }
    }

    $hyperVStatus = 'NOT_INSTALLED'; $hyperVResources = @()
    if ($IsWindows -and (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        try {
            $hyperVResources = @(Get-HyperVLabVMs | ForEach-Object {
                [PSCustomObject]@{ Name=[string]$_.Name; State=[string]$_.State; RunId=[string]$_.RunId; ScopeId=[string]$_.ScopeId; Orphan=[bool](-not $_.RunId -or [string]$_.RunId -notin $knownRunIds) }
            })
            $hyperVStatus = 'AVAILABLE'
        }
        catch { $hyperVStatus = 'UNAVAILABLE' }
    }

    $externalReferences = @()
    foreach ($run in $activeRuns) {
        foreach ($candidate in @([string]$run.metadata.dataRoot) + @($run.instances | ForEach-Object { [string]$_.persistentStorage.hostPath }) + @($run.instances | ForEach-Object { @($_.drives | ForEach-Object { [string]$_.hostPath }) })) {
            if (-not $candidate -or -not [System.IO.Path]::IsPathRooted($candidate)) { continue }
            $insideKnownRoot = @($knownRoots | Where-Object {
                $root = [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/')
                $path = [System.IO.Path]::GetFullPath($candidate)
                $path.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
            if (-not $insideKnownRoot) { $externalReferences += [PSCustomObject]@{ RunId=[string]$run.runId; Path=$candidate } }
        }
    }

    $repositoryResidues = @()
    foreach ($relative in @('.local', '.runtime', '.state', '.secrets', '.artifacts', '.cache')) {
        $path = Join-Path $script:ModuleRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        $files = @(Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('.gitignore', 'README.md') })
        if ($files.Count -gt 0) { $repositoryResidues += [PSCustomObject]@{ Path=$path; FileCount=$files.Count } }
    }

    $legacyStateRoots = @()
    $legacyState = if ($IsWindows) { Join-Path $env:LOCALAPPDATA 'SqlServerLab' } else { Join-Path (Resolve-Path '~') '.sql-server-lab' }
    if ((Test-Path -LiteralPath $legacyState -PathType Container) -and -not [string]::Equals([System.IO.Path]::GetFullPath($legacyState), [System.IO.Path]::GetFullPath($stateRoot), [StringComparison]::OrdinalIgnoreCase)) {
        $legacyRunCount = @(Get-ChildItem -LiteralPath (Join-Path $legacyState 'runs') -Filter 'run-state.json' -File -Recurse -ErrorAction SilentlyContinue).Count
        $legacyStateRoots += [PSCustomObject]@{ Path=$legacyState; RunCount=$legacyRunCount }
    }

    $unverifiable = @($runtimeResults | Where-Object Status -eq 'UNAVAILABLE').Count + $(if ($hyperVStatus -eq 'UNAVAILABLE') { 1 } else { 0 })
    $residualCount = @($activeRuns).Count + @($containers).Count + @($managedVolumes).Count + @($managedNetworks).Count + @($hyperVResources).Count + @($externalReferences).Count + @($repositoryResidues).Count + @($legacyStateRoots | Where-Object RunCount -gt 0).Count + @($rootResults | Where-Object { -not $_.Exists -or -not $_.Owned }).Count
    $status = if ($residualCount -gt 0) { 'RESIDUALS' } elseif ($unverifiable -gt 0) { 'UNVERIFIABLE' } else { 'CLEAN' }
    $audit = [PSCustomObject]@{
        ContractVersion='SqlServerLab.CleanupAudit/1.0'; AuditId=[Guid]::NewGuid().ToString('D'); CreatedAt=Get-LabTimestamp; Status=$status
        ControllerId=[string]$configuration.ControllerId; StateRoot=$stateRoot; DataRoots=$rootResults; ActiveRuns=$activeRuns
        Runtimes=$runtimeResults; Containers=$containers; ManagedVolumes=$managedVolumes; ManagedNetworks=$managedNetworks
        HyperV=[PSCustomObject]@{ Status=$hyperVStatus; Resources=$hyperVResources }
        ExternalReferences=$externalReferences; RepositoryResidues=$repositoryResidues; LegacyStateRoots=$legacyStateRoots
        Summary=[PSCustomObject]@{ ResidualCount=$residualCount; UnverifiableProviders=$unverifiable }
    }
    $path = $null
    if (-not $NoWrite -and $configuration.DefaultDataRoot) {
        $directory = Join-Path (Join-Path ([string]$configuration.DefaultDataRoot) 'Catalog') 'cleanup-audits'
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }
        $path = Join-Path $directory "$($audit.AuditId).json"
        Write-LabArtifactJsonAtomic -Path $path -InputObject $audit
    }
    return [PSCustomObject]@{ Path=$path; Audit=$audit }
}
