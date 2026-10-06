#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$providers = @{
    docker = Get-Content (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1') -Raw -Encoding utf8
    podman = Get-Content (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1') -Raw -Encoding utf8
}
$passed = 0

function Assert-VolumeContract {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Description)
    if (-not $Condition) { throw "CONTAINER_VOLUME_CONTRACT_FAILED: $Description" }
    $script:passed++
    Write-Host "PASS: $Description" -ForegroundColor Green
}

foreach ($entry in $providers.GetEnumerator()) {
    $name = $entry.Key
    $text = $entry.Value
    Assert-VolumeContract ($text -match "function Initialize-$($name.Substring(0,1).ToUpperInvariant())$($name.Substring(1))SqlNamedVolume") "$name besitzt eine explizite SQL-Volume-Initialisierung"
    Assert-VolumeContract ($text -match '10001:0 /sql-lab-volume-init') "$name setzt die SQL-Server-UID auf neuen Named Volumes"
    Assert-VolumeContract ($text -match "(?s)if \(-not \`$drive\.hostPath\).*?Initialize-$($name.Substring(0,1).ToUpperInvariant())$($name.Substring(1))SqlNamedVolume") "$name veraendert keine Host-Bind-Mounts"
    Assert-VolumeContract ($text -match '(?s)-ArgumentList.*?''volume''.*?''inspect''.*?return \$false') "$name initialisiert bestehende Volumes nicht erneut"
    Assert-VolumeContract (
        $text -match 'sql-server-lab\.sql-major-version=' -and
        $text -match 'sql-server-lab\.persistent-storage-id=' -and
        $text -match '(?s)if \(\$volumeExists -and \$PersistentStorageId\).*?SQL_VOLUME_STABLE_ID_MISMATCH'
    ) "$name bindet explizit ausgewaehlte Stores nur bei stabiler ID und gleicher SQL-Major-Version"
    Assert-VolumeContract (
        $text -match "SyncImageContent:\(\`$ExternalRuntimeLaunchMode -in @\('sql2019-namespace-v1','sql2022-namespace-v1','sql2025-namespace-v1','sql2025-shared-user-v2'\) -and" -and
        $text -match "\[string\]\`$drive\.containerPath -in" -and
        $text -match '/var/opt/mssql-extensibility/externallanguages' -and
        $text -match '/var/opt/mssql-extensibility/externallibraries' -and
        $text -match "cp -a '\`$ContainerPath'/\. /sql-lab-volume-init/" -and
        $text -match "chown --reference='\`$ContainerPath' /sql-lab-volume-init" -and
        $text -match "chmod --reference='\`$ContainerPath' /sql-lab-volume-init"
    ) "$name synchronisiert Image-Inhalt und dessen Wurzelrechte nur in die External-Artefakt-Volumes"
}

Assert-VolumeContract ($providers.podman -match "if \(-not \`$drive\.hostPath -and \`$ExternalRuntimeLaunchMode -eq 'none'\) \{ \`$volumeOptions \+= 'U' \}") 'podman verwendet die user-namespace-sichere U-Option nur fuer normale rootless Named Volumes'
Assert-VolumeContract (
    $providers.podman -match "cp -a '\`$ContainerPath'/\. /sql-lab-volume-init/" -and
    $providers.podman -match '-ContainerPath \(\[string\]\$drive\.containerPath\)' -and
    $providers.podman -match "chown --reference='\`$ContainerPath' /sql-lab-volume-init"
) 'Podman-Named-Volumes uebernehmen den Inhalt ihres exakten Containerzielpfads'
. (Join-Path $repoRoot 'Private/ContainerReconcile.ps1')
$inspect=[pscustomobject]@{Mounts=@(
    [pscustomobject]@{Type='volume';Name='synthetic-volume';Destination='/data';RW=$false},
    [pscustomobject]@{Type='bind';Source='/synthetic/source';Destination='/backup';RW=$true}
)}
$podmanArguments=@(Get-LabContainerRecreateMountArguments -Inspect $inspect -Provider podman)
$dockerArguments=@(Get-LabContainerRecreateMountArguments -Inspect $inspect -Provider docker)
Assert-VolumeContract (($podmanArguments -join '|') -ceq '-v|synthetic-volume:/data:U,ro|-v|/synthetic/source:/backup') 'Podman-Reconcile erhaelt U und Schreibrechte nur fuer Named Volumes'
Assert-VolumeContract (($dockerArguments -join '|') -ceq '-v|synthetic-volume:/data:ro|-v|/synthetic/source:/backup') 'Docker-Reconcile verwendet keine Podman-U-Option'

Write-Host "CONTAINER VOLUME CONTRACT CHECKS: $passed PASS" -ForegroundColor Green
