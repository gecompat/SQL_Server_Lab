#Requires -Version 7.2
[CmdletBinding()] param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}
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
    $intentPlans = & $module {
        [PSCustomObject]@{
            DockerDefault = Resolve-LabNetworkIntentPlan -Provider docker
            HyperVDefault = Resolve-LabNetworkIntentPlan -Provider hyperv
            HyperVIsolated = Resolve-LabNetworkIntentPlan -Provider hyperv -Network ([PSCustomObject]@{ intent='isolated'; exposure='none' })
            HyperVNat = Resolve-LabNetworkIntentPlan -Provider hyperv -Network ([PSCustomObject]@{ intent='nat'; exposure='host' })
            DockerHostOnly = Resolve-LabNetworkIntentPlan -Provider docker -Network ([PSCustomObject]@{ intent='hostOnly'; exposure='host' })
            LegacyConflict = Resolve-LabNetworkIntentPlan -Provider hyperv -Network ([PSCustomObject]@{ intent='isolated'; exposure='none' }) -HasLegacyHyperVSwitch
            ExposureConflict = Resolve-LabNetworkIntentPlan -Provider hyperv -Network ([PSCustomObject]@{ intent='isolated'; exposure='host' })
        }
    }
    Add-CheckResult -Name 'Providerdefaults loesen Container-NAT und Hyper-V-HostOnly portabel auf' -Success (
        $intentPlans.DockerDefault.Intent -eq 'nat' -and $intentPlans.DockerDefault.Exposure -eq 'host' -and
        $intentPlans.DockerDefault.RequiredCapability -eq 'nat-network' -and $intentPlans.DockerDefault.Binding -eq 'managed-bridge-nat' -and
        $intentPlans.HyperVDefault.Intent -eq 'hostOnly' -and $intentPlans.HyperVDefault.Exposure -eq 'host' -and
        $intentPlans.HyperVDefault.RequiredCapability -eq 'managed-lab-network' -and $intentPlans.HyperVDefault.Binding -eq 'internal-switch'
    )
    Add-CheckResult -Name 'Hyper-V-Isolated-Intent bindet einen privaten Switch ohne Exposure' -Success (
        $intentPlans.HyperVIsolated.Status -eq 'RESOLVED' -and $intentPlans.HyperVIsolated.Binding -eq 'private-switch'
    )
    Add-CheckResult -Name 'Noch offene providerseitige Network-Intents werden fail-closed klassifiziert' -Success (
        $intentPlans.HyperVNat.ReasonCode -eq 'NETWORK_INTENT_PROVIDER_UNSUPPORTED' -and
        $intentPlans.DockerHostOnly.ReasonCode -eq 'NETWORK_INTENT_PROVIDER_UNSUPPORTED'
    )
    Add-CheckResult -Name 'Exposure- und Legacy-Switch-Konflikte scheitern vor Provider-Mutation' -Success (
        $intentPlans.LegacyConflict.ReasonCode -eq 'NETWORK_LEGACY_SWITCH_CONFLICT' -and
        $intentPlans.ExposureConflict.ReasonCode -eq 'NETWORK_EXPOSURE_CONFLICT'
    )
    $podmanCniRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-podman-cni-$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $podmanCniRoot -ItemType Directory -Force | Out-Null
    try {
        $podmanCniPath = Join-Path $podmanCniRoot 'SQL_LAB_TEST.conflist'
        [ordered]@{
            cniVersion='1.0.0'; name='SQL_LAB_TEST'; plugins=@([ordered]@{ type='bridge' }, [ordered]@{ type='firewall' })
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $podmanCniPath -Encoding utf8
        $podmanCniResult = & $module {
            param($Path)
            $repaired = Repair-LabPodmanCniVersionCompatibility -NetworkConfigPath $Path -NetworkName 'SQL_LAB_TEST' -PodmanVersion '3.4.4'
            $document = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
            [PSCustomObject]@{ Repaired=$repaired; Version=[string]$document.cniVersion; Plugins=@($document.plugins).Count }
        } $podmanCniPath
        Add-CheckResult -Name 'Podman 3.4.4 wird eng begrenzt auf den von Ubuntu 22.04 unterstuetzten CNI-Vertrag korrigiert' -Success (
            $podmanCniResult.Repaired -and $podmanCniResult.Version -eq '0.4.0' -and $podmanCniResult.Plugins -eq 2
        )
        $legacyPodmanContract = & $module {
            Get-LabPodmanNetworkContractFromInspect -Inspect ([PSCustomObject]@{
                name='SQL_LAB_TEST'; cniVersion='0.4.0'; plugins=@([PSCustomObject]@{
                    type='bridge'; ipam=[PSCustomObject]@{
                        ranges=@(@([PSCustomObject]@{ subnet='10.254.27.0/24'; gateway='10.254.27.1' }))
                        routes=@([PSCustomObject]@{ dst='0.0.0.0/0' })
                    }
                })
            })
        }
        Add-CheckResult -Name 'Podman-3.4-CNI-Inspect wird auf denselben Subnetz- und Internal-Vertrag normalisiert' -Success (
            $legacyPodmanContract.Subnet -eq '10.254.27.0/24' -and -not $legacyPodmanContract.Internal
        )
    }
    finally { Remove-Item -LiteralPath $podmanCniRoot -Recurse -Force -ErrorAction SilentlyContinue }
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
    $newLabSource = Get-Content (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1') -Raw
    Add-CheckResult -Name 'Docker verwendet das feste Labnetz mit reinem Host-Portzugriff' -Success (
        $docker -match 'Ensure-LabDockerNetwork' -and $docker -match '--network.*\$labNetwork\.Name' -and
        $docker -match '127\.0\.0\.1:\$\{selectedPort\}:1433'
    )
    Add-CheckResult -Name 'Podman verwendet das feste Labnetz mit reinem Host-Portzugriff' -Success (
        $podman -match 'Ensure-LabPodmanNetwork' -and $podman -match '--network.*\$labNetwork\.Name' -and
        $podman -match '127\.0\.0\.1:\$\{selectedPort\}:1433'
    )
    $containerReconcileSource = Get-Content (Join-Path $repoRoot 'Public/Update-SqlServerLabContainer.ps1') -Raw
    Add-CheckResult -Name 'Container-Recreate bewahrt die HostOnly-Exposure am Loopback-Binding' -Success (
        $containerReconcileSource -match '127\.0\.0\.1:\$\(\[int\]\$plan\.Desired\.Port\):1433'
    )
    Add-CheckResult -Name 'Hyper-V-SQL-Builder bindet SQL_LAB_HYPERV' -Success ($hyperv -match 'Ensure-LabHyperVNetwork' -and $hyperv -match '-SwitchName \$labNetwork.Name')
    Add-CheckResult -Name 'Manifestlauf reicht den aufgeloesten Hyper-V-Isolation-Intent an die Runtime weiter' -Success (
        $newLabSource -match '\$hyperVIsolated\s*=.+instance\.network\.Intent.+isolated' -and
        $newLabSource -match 'New-HyperVLabEnvironment[\s\S]+-Isolated:\$hyperVIsolated'
    )
    Add-CheckResult -Name 'Hyper-V-Gast erhaelt nach OOBE eine Lab-IP und SQL-Firewallfreigabe' -Success ($acceptance -match 'Initialize-HyperVGuestLabNetwork' -and $networkSource -match 'New-NetFirewallRule[\s\S]+LocalPort 1433')
    Add-CheckResult -Name 'Hyper-V-Gastnetz quittiert nur die tatsaechlich bevorzugte statische Adresse' -Success (
        $networkSource -match 'Get-NetIPAddress[\s\S]+AddressState[\s\S]+Preferred' -and
        $networkSource -match 'LAB_NETWORK_GUEST_ADDRESS_NOT_READY' -and
        $networkSource -match 'receipt\.addressState[\s\S]+Preferred'
    )
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
        $menuSource -match "New-LabConsoleItem -Id 'storage' -Label 'Medien, Testdaten und Speicher'.+-Shortcut '5'" -and
        $menuSource -match "New-LabConsoleItem -Id 'MediaRoot' -Label 'Lab_Base / Media-Root konfigurieren'.+-Shortcut 'p'" -and
        $menuSource -match "'MediaRoot'\s*\{"
    )
}
catch { Add-CheckResult -Name 'Labnetz-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue }
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0



