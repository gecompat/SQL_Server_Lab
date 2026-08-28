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
    Assert-VolumeContract ($text -match '(?s)volume inspect.*?return \$false') "$name initialisiert bestehende Volumes nicht erneut"
    Assert-VolumeContract (
        $text -match "SyncImageContent:\(\`$ExternalRuntimeLaunchMode -eq 'sql2022-namespace-v1' -and" -and
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
$reconcile = Get-Content (Join-Path $repoRoot 'Public/Update-SqlServerLabContainer.ps1') -Raw -Encoding utf8
Assert-VolumeContract ($reconcile -match "(?s)if \(\`$runtime -eq 'podman'\) \{ \`$volumeOptions \+= 'U' \}") 'Podman-Reconcile erhaelt die user-namespace-sichere Volume-Eigentuemerschaft'

Write-Host "CONTAINER VOLUME CONTRACT CHECKS: $passed PASS" -ForegroundColor Green
