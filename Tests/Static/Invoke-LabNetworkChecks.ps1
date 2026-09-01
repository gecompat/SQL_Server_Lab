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
            HyperVLan = Resolve-LabNetworkIntentPlan -Provider hyperv -Network ([PSCustomObject]@{ intent='lan'; exposure='lan' })
            DockerLan = Resolve-LabNetworkIntentPlan -Provider docker -Network ([PSCustomObject]@{ intent='lan'; exposure='lan' })
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
    Add-CheckResult -Name 'Hyper-V-NAT ist gebunden; offene Container-Intents bleiben fail-closed' -Success (
        $intentPlans.HyperVNat.Status -eq 'RESOLVED' -and $intentPlans.HyperVNat.Binding -eq 'shared-internal-nat' -and
        $intentPlans.DockerHostOnly.ReasonCode -eq 'NETWORK_INTENT_PROVIDER_UNSUPPORTED'
    )
    Add-CheckResult -Name 'Hyper-V-LAN wird portabel gebunden; Container-LAN bleibt fail-closed' -Success (
        $intentPlans.HyperVLan.Status -eq 'RESOLVED' -and
        $intentPlans.HyperVLan.Binding -eq 'external-switch' -and
        $intentPlans.HyperVLan.RequiredCapability -eq 'external-network-binding' -and
        $intentPlans.DockerLan.ReasonCode -eq 'NETWORK_INTENT_PROVIDER_UNSUPPORTED'
    )
    Add-CheckResult -Name 'Exposure- und Legacy-Switch-Konflikte scheitern vor Provider-Mutation' -Success (
        $intentPlans.LegacyConflict.ReasonCode -eq 'NETWORK_LEGACY_SWITCH_CONFLICT' -and
        $intentPlans.ExposureConflict.ReasonCode -eq 'NETWORK_EXPOSURE_CONFLICT'
    )
    $hyperVNatPlans = & $module {
        function Get-VMSwitch { $null }
        function Get-NetIPAddress { @() }
        function Get-DnsClientServerAddress { [PSCustomObject]@{ InterfaceAlias='Ethernet'; ServerAddresses=@('192.0.2.53') } }
        function Get-LabKnownIpv4Subnets { param($Provider) @('0.0.0.0/0') }
        function Get-NetNat { [PSCustomObject]@{ Name='FOREIGN_NAT'; InternalIPInterfaceAddressPrefix='172.30.0.0/24' } }
        $blocked = Resolve-LabHyperVNetworkBoundPlan -Intent nat
        function Get-NetNat { @() }
        $ready = Resolve-LabHyperVNetworkBoundPlan -Intent nat
        [PSCustomObject]@{ Blocked=$blocked; Ready=$ready }
    }
    Add-CheckResult -Name 'Hyper-V-NAT-Plan erkennt fremdes WinNAT mutationsfrei und ignoriert die Default-Route' -Success (
        $hyperVNatPlans.Blocked.Status -eq 'BLOCKED' -and
        $hyperVNatPlans.Blocked.Blockers -contains 'LAB_NETWORK_HYPERV_NAT_PREFIX_CONFLICT' -and
        $hyperVNatPlans.Ready.Status -eq 'READY' -and
        $hyperVNatPlans.Ready.Actions -contains 'create-shared-winnat'
    )
    $hyperVNatApply = & $module {
        $script:natApplyCalls = [Collections.Generic.List[string]]::new()
        $script:natSwitchExists = $false; $script:natAddressExists = $false; $script:natExists = $false
        function Get-VMSwitch { param($Name) if ($script:natSwitchExists) { [PSCustomObject]@{ Name=$Name; SwitchType='Internal' } } }
        function New-VMSwitch { param($Name,$SwitchType) $script:natApplyCalls.Add('switch'); $script:natSwitchExists=$true }
        function Remove-VMSwitch { }
        function Get-NetIPAddress {
            if ($script:natAddressExists) { [PSCustomObject]@{ IPAddress='172.29.0.1'; PrefixLength=24; PrefixOrigin='Manual' } }
        }
        function New-NetIPAddress { $script:natApplyCalls.Add('address'); $script:natAddressExists=$true }
        function Remove-NetIPAddress { }
        function Get-NetNat { param($Name) if ($script:natExists) { [PSCustomObject]@{ Name='SQL_LAB_HYPERV_NAT'; InternalIPInterfaceAddressPrefix='172.29.0.0/24' } } }
        function New-NetNat { $script:natApplyCalls.Add('nat'); $script:natExists=$true }
        function Remove-NetNat { }
        function Get-DnsClientServerAddress { [PSCustomObject]@{ InterfaceAlias='Ethernet'; ServerAddresses=@('192.0.2.53') } }
        function Get-LabKnownIpv4Subnets { param($Provider) @() }
        $plan = Resolve-LabHyperVNetworkBoundPlan -Intent nat
        $result = Invoke-LabHyperVNetworkBoundPlan -Plan $plan
        [PSCustomObject]@{ Status=$result.Status; Calls=@($script:natApplyCalls) }
    }
    Add-CheckResult -Name 'Revalidierter Hyper-V-NAT-Plan erstellt Switch, Hostadresse und WinNAT in sicherer Reihenfolge' -Success (
        $hyperVNatApply.Status -eq 'READY' -and ($hyperVNatApply.Calls -join ',') -eq 'switch,address,nat'
    )
    $hyperVLanPlans = & $module {
        function Get-VMSwitch { param($Name,$SwitchType) @() }
        function Get-NetAdapter {
            [PSCustomObject]@{ Name='Ethernet'; InterfaceGuid=[guid]'11111111-1111-1111-1111-111111111111'; InterfaceDescription='Approved Adapter'; Status='Up' }
        }
        $missing = Resolve-LabHyperVNetworkBoundPlan -Intent lan -LanSwitchName '' -LanAdapterId ''
        $ready = Resolve-LabHyperVNetworkBoundPlan -Intent lan -LanSwitchName 'SQL_LAB_LAN' -LanAdapterId '11111111-1111-1111-1111-111111111111'
        function Get-VMSwitch {
            param($Name,$SwitchType)
            [PSCustomObject]@{ Name='SQL_LAB_LAN'; SwitchType='External'; NetAdapterInterfaceDescription='Different Adapter' }
        }
        $mismatch = Resolve-LabHyperVNetworkBoundPlan -Intent lan -LanSwitchName 'SQL_LAB_LAN' -LanAdapterId '11111111-1111-1111-1111-111111111111'
        [PSCustomObject]@{ Missing=$missing; Ready=$ready; Mismatch=$mismatch }
    }
    Add-CheckResult -Name 'Hyper-V-LAN verlangt eine exakte lokale Switch- und Adapterfreigabe' -Success (
        $hyperVLanPlans.Missing.Status -eq 'BLOCKED' -and
        $hyperVLanPlans.Missing.Blockers -contains 'LAB_NETWORK_HYPERV_LAN_BINDING_REQUIRED' -and
        $hyperVLanPlans.Ready.Status -eq 'READY' -and
        ($hyperVLanPlans.Ready.Actions -join ',') -eq 'create-external-switch' -and
        $hyperVLanPlans.Ready.AddressMode -eq 'dhcp' -and
        $hyperVLanPlans.Mismatch.Blockers -contains 'LAB_NETWORK_HYPERV_LAN_SWITCH_CONTRACT_MISMATCH'
    )
    $hyperVLanApply = & $module {
        $script:lanSwitchExists = $false
        $script:lanApply = $null
        function Get-NetAdapter {
            [PSCustomObject]@{ Name='Ethernet'; InterfaceGuid=[guid]'11111111-1111-1111-1111-111111111111'; InterfaceDescription='Approved Adapter'; Status='Up' }
        }
        function Get-VMSwitch {
            param($Name,$SwitchType)
            if ($script:lanSwitchExists) {
                [PSCustomObject]@{ Name='SQL_LAB_LAN'; SwitchType='External'; NetAdapterInterfaceDescription='Approved Adapter' }
            }
        }
        function New-VMSwitch {
            param($Name,$NetAdapterName,$AllowManagementOS)
            $script:lanApply = [PSCustomObject]@{ Name=$Name; Adapter=$NetAdapterName; ManagementOS=$AllowManagementOS }
            $script:lanSwitchExists = $true
        }
        function Remove-VMSwitch { }
        $plan = Resolve-LabHyperVNetworkBoundPlan -Intent lan -LanSwitchName 'SQL_LAB_LAN' -LanAdapterId '11111111-1111-1111-1111-111111111111'
        $result = Invoke-LabHyperVNetworkBoundPlan -Plan $plan
        [PSCustomObject]@{ Result=$result; Apply=$script:lanApply }
    }
    Add-CheckResult -Name 'Hyper-V-LAN erstellt nur den exakt freigegebenen External Switch mit Hostanbindung' -Success (
        $hyperVLanApply.Result.Status -eq 'READY' -and
        $hyperVLanApply.Apply.Name -eq 'SQL_LAB_LAN' -and
        $hyperVLanApply.Apply.Adapter -eq 'Ethernet' -and
        $hyperVLanApply.Apply.ManagementOS
    )
    $hyperVLanGuest = & $module {
        function Invoke-HyperVPowerShellDirect {
            [PSCustomObject]@{
                contractVersion='1'; network='SQL_LAB_LAN'; addressMode='dhcp'; address='192.0.2.44'; prefixLength=24
                addressState='Preferred'; gateway='192.0.2.1'; dnsServers=@('192.0.2.53'); observedAt='2026-09-01T12:00:00Z'
            }
        }
        $mockSecret = [Security.SecureString]::new(); $mockSecret.AppendChar('x')
        $credential = [PSCredential]::new('Administrator', $mockSecret)
        Initialize-HyperVGuestLabNetwork -VMName lan-vm -ExpectedRunId run -ExpectedScopeId scope -Credential $credential `
            -Network ([PSCustomObject]@{ Name='SQL_LAB_LAN'; Intent='lan'; AddressMode='dhcp' }) -Identity run
    }
    Add-CheckResult -Name 'Hyper-V-LAN akzeptiert eine bevorzugte dynamische Gastadresse als DHCP-Evidenz' -Success (
        $hyperVLanGuest.AddressMode -eq 'dhcp' -and $hyperVLanGuest.Address -eq '192.0.2.44' -and
        $hyperVLanGuest.Gateway -eq '192.0.2.1' -and $hyperVLanGuest.DnsServers -contains '192.0.2.53'
    )
    $ipamRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-hyperv-ipam-$([guid]::NewGuid().ToString('N'))"
    try {
        $ipam = & $module {
            param($Root)
            $network = Get-LabRuntimeNetwork -Provider hyperv -Intent nat
            $first = Reserve-LabHyperVNetworkAddress -Network $network -RunId run-a -ScopeId scope-a -InstanceId primary -StateRoot $Root
            $second = Reserve-LabHyperVNetworkAddress -Network $network -RunId run-b -ScopeId scope-b -InstanceId primary -StateRoot $Root
            $again = Reserve-LabHyperVNetworkAddress -Network $network -RunId run-a -ScopeId scope-a -InstanceId primary -StateRoot $Root
            $released = Release-LabHyperVNetworkAddress -Address $first.address -RunId run-a -ScopeId scope-a -StateRoot $Root
            [PSCustomObject]@{ First=$first; Second=$second; Again=$again; Released=$released }
        } $ipamRoot
        Add-CheckResult -Name 'Hyper-V-IPAM reserviert eindeutig, idempotent und scope-gebunden freigebbar' -Success (
            $ipam.First.address -ne $ipam.Second.address -and $ipam.First.address -eq $ipam.Again.address -and $ipam.Released
        )
        $cleanup = & $module {
            param($Root)
            $run = New-LabRunState -StateRoot $Root -Metadata @{ name='ipam-cleanup' } `
                -ProviderSubRuns @([PSCustomObject]@{ id='provider-hyperv'; provider='hyperv'; instanceIds=@('cleanup') })
            $null = New-CleanupPlan -RunDir $run.RunDir -RunId $run.RunId -ScopeId $run.ScopeId `
                -ProviderSubRuns @([PSCustomObject]@{ id='provider-hyperv'; provider='hyperv'; instanceIds=@('cleanup') })
            $network = Get-LabRuntimeNetwork -Provider hyperv -Intent nat
            $lease = Reserve-LabHyperVNetworkAddress -Network $network -RunId $run.RunId -ScopeId $run.ScopeId -InstanceId cleanup -StateRoot $Root
            $null = Add-CleanupStep -RunDir $run.RunDir -ResourceType 'ipam-lease' -ResourceId $lease.address `
                -Action release -Provider hyperv -ProviderSubRunId provider-hyperv
            $result = Invoke-CleanupPlan -RunDir $run.RunDir -ScopeId $run.ScopeId
            $registry = Get-Content -LiteralPath (Get-LabHyperVIpamPath -StateRoot $Root) -Raw | ConvertFrom-Json -Depth 20
            [PSCustomObject]@{ Status=$result.Status; LeaseState=[string]@($registry.leases | Where-Object address -eq $lease.address)[0].state }
        } $ipamRoot
        Add-CheckResult -Name 'Run-Cleanup gibt die Hyper-V-IPAM-Lease nach den Run-Ressourcen frei' -Success (
            $cleanup.Status -eq 'CLEANUP_SUCCEEDED' -and $cleanup.LeaseState -eq 'RELEASED'
        )
    }
    finally { Remove-Item -LiteralPath $ipamRoot -Recurse -Force -ErrorAction SilentlyContinue }
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
    Add-CheckResult -Name 'Manifestlauf reicht den aufgeloesten Hyper-V-Network-Intent an die Runtime weiter' -Success (
        $newLabSource -match '\$hyperVIsolated\s*=.+instance\.network\.Intent.+isolated' -and
        $newLabSource -match '\$hyperVNetworkIntent' -and
        $newLabSource -match 'New-HyperVLabEnvironment[\s\S]+-NetworkIntent \$hyperVNetworkIntent'
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



