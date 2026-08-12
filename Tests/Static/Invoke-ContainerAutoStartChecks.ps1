#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
Write-Host ''
Write-Host 'SQL_Server_Lab - Container Autostart Checks' -ForegroundColor Cyan

$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$manifest = [PSCustomObject]@{
    name = 'autostart-contract'
    instances = @([PSCustomObject]@{
        id = 'primary'; version = '2025'; provider = 'docker'; autostart = 'on'
        os = 'linux'; profile = 'compact'; collation = $null; databases = @(); drives = @()
        serverConfig = $null; software = @(); postProvision = @(); hyperv = $null
    })
    persistentData = $null; resourceOverrides = $null; automation = $null; expertActions = $null
}
$resolved = & $module { param($value) Resolve-ManifestDefaults -Manifest $value } $manifest
Add-CheckResult -Name 'Providerneutraler Manifestwert wird aufgelöst' -Success (
    $resolved.instances[0].autostart -eq 'on'
)

$aliasManifest = [PSCustomObject]@{
    name = 'autostart-alias'
    instances = @([PSCustomObject]@{
        id = 'primary'; version = '2025'; provider = 'hyperv'; os = 'windows'; profile = 'compact'
        collation = $null; databases = @(); drives = @(); serverConfig = $null; software = @(); postProvision = @()
        hyperv = [PSCustomObject]@{ preparedImageId = $null; autostart = 'on' }
    })
    persistentData = $null; resourceOverrides = $null; automation = $null; expertActions = $null
}
$resolvedAlias = & $module { param($value) Resolve-ManifestDefaults -Manifest $value } $aliasManifest
Add-CheckResult -Name 'Hyper-V-Alias bleibt kompatibel' -Success (
    $resolvedAlias.instances[0].autostart -eq 'on' -and $resolvedAlias.instances[0].hyperv.autostart -eq 'on'
)

$conflict = [ordered]@{
    name = 'autostart-conflict'
    instances = @([ordered]@{
        id = 'primary'; version = '2025'; provider = 'hyperv'; os = 'windows'; autostart = 'on'
        hyperv = [ordered]@{ autostart = 'off' }
    })
}
$conflictResult = Test-SqlServerLabManifest -InputObject $conflict
Add-CheckResult -Name 'Widersprüchliche Aliaswerte werden abgelehnt' -Success (
    -not $conflictResult.IsValid -and $conflictResult.Errors -match 'widersprechen'
) -Message ($conflictResult.Errors -join '; ')

$docker = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1') -Raw -Encoding utf8
$podman = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1') -Raw -Encoding utf8
$coordinator = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ContainerAutoStart.ps1') -Raw -Encoding utf8
$newLab = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1') -Raw -Encoding utf8
$cms = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Sync-SqlServerLabConnectionCenter.ps1') -Raw -Encoding utf8
$workflow = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLabWorkflowAction.ps1') -Raw -Encoding utf8
$html = Get-Content -LiteralPath (Join-Path $repoRoot 'Ui/index.html') -Raw -Encoding utf8
$javascript = Get-Content -LiteralPath (Join-Path $repoRoot 'Ui/app.js') -Raw -Encoding utf8

Add-CheckResult -Name 'Docker und Podman setzen Restart-Policy und Autostart-Label' -Success (
    $docker -match "--restart', 'unless-stopped" -and $docker -match 'sql-server-lab\.autostart=\$AutoStart' -and
    $podman -match "--restart', 'unless-stopped" -and $podman -match 'sql-server-lab\.autostart=\$AutoStart'
)
Add-CheckResult -Name 'Hostkoordinator deckt Windows und natives Podman/Linux ab' -Success (
    $coordinator -match 'Register-ScheduledTask' -and $coordinator -match 'machine start' -and
    $coordinator -match 'podman-restart\.service' -and $coordinator -match 'enable-linger' -and
    $coordinator -match 'is-enabled docker\.service' -and $coordinator -match 'label=sql-server-lab\.autostart=on'
)
Add-CheckResult -Name 'Provisionierung aktiviert den Hostkoordinator nur bei autostart=on' -Success (
    $newLab -match "instance\.autostart -eq 'on'" -and $newLab -match 'Enable-LabContainerHostAutoStart'
)
Add-CheckResult -Name 'CMS wird immer mit Autostart erstellt' -Success (
    $cms -match "New-SqlServerLab.*-AutoStart on" -and $cms -match "AutoStart = 'on'"
)
Add-CheckResult -Name 'Workflow und UI reichen Container-Autostart durch' -Success (
    $workflow -match 'New-SqlServerLab.*-AutoStart \$AutoStart' -and $workflow -match 'autostart = \$AutoStart' -and
    $html -match 'id="container-autostart"' -and $javascript -match "container-autostart'\)\.checked"
)

Remove-Module $module -Force
if ($failures.Count -gt 0) {
    Write-Host "Container Autostart Checks: FAIL ($($failures.Count))" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Container Autostart Checks: PASS ($passed)" -ForegroundColor Green
