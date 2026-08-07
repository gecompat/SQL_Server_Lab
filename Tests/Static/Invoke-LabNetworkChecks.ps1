#Requires -Version 7.2
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''; Write-Host 'SQL_Server_Lab - Lab Network Checks' -ForegroundColor Cyan
try {
    $module = Import-Module $modulePath -Force -PassThru
    $defaults = & $module { @('docker', 'podman', 'hyperv') | ForEach-Object { Get-LabRuntimeNetwork -Provider $_ } }
    Add-CheckResult -Name 'Feste Docker-, Podman- und Hyper-V-Netzdefaults sind getrennt' -Success (
        @($defaults.Name | Sort-Object -Unique).Count -eq 3 -and @($defaults.Subnet | Sort-Object -Unique).Count -eq 3 -and
        ($defaults | Where-Object Provider -eq docker).Subnet -eq '172.26.0.0/16' -and
        ($defaults | Where-Object Provider -eq podman).Subnet -eq '172.27.0.0/16' -and
        ($defaults | Where-Object Provider -eq hyperv).Subnet -eq '172.28.0.0/24'
    )
    $overlap = & $module { [PSCustomObject]@{ Overlap = Test-LabIpv4SubnetOverlap -Left '172.26.0.0/16' -Right '172.26.12.0/24'; Separate = Test-LabIpv4SubnetOverlap -Left '172.26.0.0/16' -Right '172.27.0.0/16' } }
    Add-CheckResult -Name 'CIDR-Pruefung erkennt Ueberlappungen' -Success ($overlap.Overlap -and -not $overlap.Separate)
    $previous = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DOCKER_SUBNET')
    try {
        [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_DOCKER_SUBNET', '172.29.0.0/16', 'Process')
        $configured = & $module { Get-LabRuntimeNetwork -Provider docker }
        Add-CheckResult -Name 'Docker-Subnetz ist pro Prozess konfigurierbar' -Success ($configured.Subnet -eq '172.29.0.0/16')
    }
    finally { [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_DOCKER_SUBNET', $previous, 'Process') }
    $docker = Get-Content (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1') -Raw
    $podman = Get-Content (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1') -Raw
    $hyperv = Get-Content (Join-Path $repoRoot 'Private/HyperVSqlImageBuilder.ps1') -Raw
    $acceptance = Get-Content (Join-Path $repoRoot 'Private/HyperVSqlAcceptanceEnvironment.ps1') -Raw
    $networkSource = Get-Content (Join-Path $repoRoot 'Private/LabNetwork.ps1') -Raw
    $elevationSource = Get-Content (Join-Path $repoRoot 'Private/Elevation.ps1') -Raw
    $preferencesSource = Get-Content (Join-Path $repoRoot 'Private/LabPreferences.ps1') -Raw
    $menuSource = Get-Content (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1') -Raw
    Add-CheckResult -Name 'Docker verwendet das feste Labnetz mit Host-Portzugriff' -Success ($docker -match 'Ensure-LabDockerNetwork' -and $docker -match '--network.*\$labNetwork\.Name')
    Add-CheckResult -Name 'Podman verwendet das feste Labnetz mit Host-Portzugriff' -Success ($podman -match 'Ensure-LabPodmanNetwork' -and $podman -match '--network.*\$labNetwork\.Name')
    Add-CheckResult -Name 'Hyper-V-SQL-Builder bindet SQL_LAB_HYPERV' -Success ($hyperv -match 'Ensure-LabHyperVNetwork' -and $hyperv -match '-SwitchName \$labNetwork.Name')
    Add-CheckResult -Name 'Hyper-V-Gast erhaelt nach OOBE eine Lab-IP und SQL-Firewallfreigabe' -Success ($acceptance -match 'Initialize-HyperVGuestLabNetwork' -and $networkSource -match 'New-NetFirewallRule[\s\S]+LocalPort 1433')
    $hypervLab = Get-Content (Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1') -Raw
    $hypervProvider = Get-Content (Join-Path $repoRoot 'Providers/HyperV/HyperVProvider.ps1') -Raw
    Add-CheckResult -Name 'Regulärer Prepared-Image-Klon injiziert Labnetz-Bootstrap und akzeptiert leeren Fallback ohne Validierungsfehler' -Success (
        $hypervLab -match 'New-HyperVSqlGuestNetworkBootstrapScript' -and
        $hypervLab -match 'Get-LabNetworkGuestAddress[\s\S]*lab\.Run\.runId' -and
        $hypervLab -match 'Set-HyperVSqlOfflineUnattend[\s\S]+-BootstrapScript \$bootstrap'
    )
    $emptyFallbackAccepted = & $module {
        function Get-HyperVManagedVM { [PSCustomObject]@{ VM = [PSCustomObject]@{ State = 'Running' } } }
        function Invoke-Command { 'ok' }
        $password = ConvertTo-SecureString 'Test_Administrator_42!' -AsPlainText -Force
        try {
            $result = Invoke-HyperVPowerShellDirect -VMName 'mock' -ExpectedRunId 'run' -ExpectedScopeId 'scope' `
                -Credential ([PSCredential]::new('Administrator', $password)) -FallbackAddress '' -ScriptBlock { 'ok' }
            $result -eq 'ok'
        }
        catch { $false }
    }
    Add-CheckResult -Name 'Leerer Hyper-V-Fallback wird nicht als ungültige IP validiert' -Success $emptyFallbackAccepted
    Add-CheckResult -Name 'Interaktiver Hyper-V-Pfad fordert UAC automatisch an' -Success ($elevationSource -match 'Start-Process[\s\S]+-Verb RunAs' -and $menuSource -match 'Start-LabElevatedAction')
    Add-CheckResult -Name 'UAC-Prozess importiert das Modul mit gueltigem Import-Module-Aufruf' -Success ($elevationSource -match 'Import-Module\s+''\$escapedModulePath''\s+-Force' -and $elevationSource -notmatch 'Import-Module -LiteralPath')
    Add-CheckResult -Name 'Zuletzt gewaehlter Media Root wird projektlokal gespeichert und vorbelegt' -Success (
        $preferencesSource -match "\.local'\) 'preferences\.json'" -and
        $preferencesSource -match 'Get-LabProjectMediaRootDefault' -and
        $preferencesSource -match 'Write-LabArtifactJsonAtomic -Path \$preferencePath' -and
        $preferencesSource -match 'SetEnvironmentVariable\(''SQL_SERVER_LAB_MEDIA_ROOT''.+''User''' -and
        $menuSource -match 'Get-LabMediaRootDefault' -and $menuSource -match 'Set-LabMediaRootDefault' -and
        $menuSource -match '\[r\] Media Root konfigurieren' -and
        $menuSource -match "'r' \{ Invoke-LabAction -ActionName 'MediaRoot' \}"
    )
}
catch { Add-CheckResult -Name 'Labnetz-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue }
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
