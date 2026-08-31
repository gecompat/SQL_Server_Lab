<#
.SYNOPSIS
    Verwaltet die festen, voneinander isolierten SQL_Server_Lab-Netze.
.DESCRIPTION
    Docker, Podman und Hyper-V erhalten jeweils ein langlebiges Runtime-Netz.
    Die Netze sind nicht Teil eines einzelnen Runs und werden deshalb beim
    Run-Cleanup nie entfernt. Bevor ein Netz angelegt wird, prueft die Runtime
    auf Ueberlappungen mit bekannten Host- und Runtime-Subnetzen.
#>

function ConvertTo-LabIpv4UInt32 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.IPAddress]$Address)

    if ($Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'LAB_NETWORK_IPV4_REQUIRED'
    }
    $bytes = $Address.GetAddressBytes()
    return ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor
        ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3]
}

function ConvertFrom-LabIpv4UInt32 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$Value)

    return [System.Net.IPAddress]::new([byte[]]@(
        (($Value -shr 24) -band 0xff), (($Value -shr 16) -band 0xff),
        (($Value -shr 8) -band 0xff), ($Value -band 0xff)
    ))
}

function ConvertTo-LabIpv4Subnet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Subnet)

    if ($Subnet -notmatch '^([^/]+)/(\d{1,2})$') { throw "LAB_NETWORK_CIDR_INVALID: $Subnet" }
    $address = [System.Net.IPAddress]::Parse($Matches[1])
    if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "LAB_NETWORK_IPV4_REQUIRED: $Subnet"
    }
    $prefix = [int]$Matches[2]
    if ($prefix -lt 8 -or $prefix -gt 30) { throw "LAB_NETWORK_PREFIX_INVALID: $Subnet" }
    $mask = [uint32]::MaxValue -shl (32 - $prefix)
    $network = (ConvertTo-LabIpv4UInt32 -Address $address) -band $mask
    if ((ConvertTo-LabIpv4UInt32 -Address $address) -ne $network) {
        throw "LAB_NETWORK_HOST_BITS_SET: $Subnet"
    }
    return [PSCustomObject]@{ Cidr = "$address/$prefix"; PrefixLength = $prefix; Network = [uint32]$network; Mask = [uint32]$mask }
}

function Test-LabIpv4SubnetOverlap {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)

    $leftSubnet = ConvertTo-LabIpv4Subnet -Subnet $Left
    $rightSubnet = ConvertTo-LabIpv4Subnet -Subnet $Right
    return (($leftSubnet.Network -band $rightSubnet.Mask) -eq $rightSubnet.Network) -or
        (($rightSubnet.Network -band $leftSubnet.Mask) -eq $leftSubnet.Network)
}

function Resolve-LabNetworkIntentPlan {
    <#
    .SYNOPSIS
        Loest einen portablen Network Intent ohne Hostmutation auf.
    .DESCRIPTION
        Der Plan enthaelt weder Switch-Namen noch lokale Adapter- oder
        Adresswerte. Nicht gebundene Providerkombinationen bleiben vor der
        ersten Mutation sichtbar DECLARED_UNSUPPORTED.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman', 'hyperv')][string]$Provider,
        $Network,
        [switch]$HasLegacyHyperVSwitch
    )

    $intent = if ($Network -and -not [string]::IsNullOrWhiteSpace([string]$Network.intent)) {
        [string]$Network.intent
    }
    elseif ($Provider -eq 'hyperv') { 'hostOnly' }
    else { 'nat' }
    $defaultExposure = switch ($intent) {
        'isolated' { 'none' }
        'hostOnly' { 'host' }
        'nat' { 'host' }
        'lan' { 'lan' }
        default { 'none' }
    }
    $exposure = if ($Network -and -not [string]::IsNullOrWhiteSpace([string]$Network.exposure)) {
        [string]$Network.exposure
    }
    else { $defaultExposure }
    $requiredCapability = switch ($intent) {
        'isolated' { 'isolated-network' }
        'hostOnly' { 'managed-lab-network' }
        'nat' { 'nat-network' }
        'lan' { 'external-network-binding' }
        default { 'unknown-network-intent' }
    }
    $binding = switch ($intent) {
        'isolated' { if ($Provider -eq 'hyperv') { 'private-switch' } else { 'internal-bridge' } }
        'hostOnly' { if ($Provider -eq 'hyperv') { 'internal-switch' } else { 'host-only-bridge' } }
        'nat' { if ($Provider -eq 'hyperv') { 'shared-internal-nat' } else { 'managed-bridge-nat' } }
        'lan' { if ($Provider -eq 'hyperv') { 'external-switch' } else { 'macvlan-or-ipvlan' } }
        default { 'none' }
    }

    $status = 'RESOLVED'
    $reasonCode = $null
    $reason = $null
    if ($intent -notin @('isolated', 'hostOnly', 'nat', 'lan')) {
        $status = 'DECLARED_UNSUPPORTED'
        $reasonCode = 'NETWORK_INTENT_UNKNOWN'
        $reason = "Network Intent '$intent' ist unbekannt."
    }
    elseif ($exposure -ne $defaultExposure) {
        $status = 'DECLARED_UNSUPPORTED'
        $reasonCode = 'NETWORK_EXPOSURE_CONFLICT'
        $reason = "Network Intent '$intent' verlangt derzeit Exposure '$defaultExposure', nicht '$exposure'."
    }
    elseif ($Provider -eq 'hyperv' -and $HasLegacyHyperVSwitch -and $intent -ne 'hostOnly') {
        $status = 'DECLARED_UNSUPPORTED'
        $reasonCode = 'NETWORK_LEGACY_SWITCH_CONFLICT'
        $reason = 'hyperv.switchName ist nur als Kompatibilitaetsbinding fuer hostOnly zulaessig.'
    }
    elseif (($Provider -eq 'hyperv' -and $intent -notin @('isolated', 'hostOnly', 'nat')) -or
        ($Provider -in @('docker', 'podman') -and $intent -ne 'nat')) {
        $status = 'DECLARED_UNSUPPORTED'
        $reasonCode = 'NETWORK_INTENT_PROVIDER_UNSUPPORTED'
        $reason = "Network Intent '$intent' ist fuer Provider '$Provider' noch nicht gebunden."
    }

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.NetworkIntentPlan'; Version='1.0' }
        Provider = $Provider
        Intent = $intent
        Exposure = $exposure
        Binding = $binding
        RequiredCapability = $requiredCapability
        Status = $status
        ReasonCode = $reasonCode
        Reason = $reason
    }
}

function Get-LabRuntimeNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman', 'hyperv')][string]$Provider,
        [ValidateSet('hostOnly', 'nat')][string]$Intent = 'hostOnly'
    )

    $defaults = @{
        docker = @{ Name = 'SQL_LAB_DOCKER'; Subnet = '172.26.0.0/16'; EnvironmentPrefix = 'DOCKER' }
        podman = @{ Name = 'SQL_LAB_PODMAN'; Subnet = '172.27.0.0/16'; EnvironmentPrefix = 'PODMAN' }
        hyperv = if ($Intent -eq 'nat') {
            @{ Name = 'SQL_LAB_HYPERV_NAT'; Subnet = '172.29.0.0/24'; EnvironmentPrefix = 'HYPERV_NAT'; NatName = 'SQL_LAB_HYPERV_NAT' }
        }
        else { @{ Name = 'SQL_LAB_HYPERV'; Subnet = '172.28.0.0/24'; EnvironmentPrefix = 'HYPERV' } }
    }
    $definition = $defaults[$Provider]
    $prefix = "SQL_SERVER_LAB_$($definition.EnvironmentPrefix)"
    $name = [string][Environment]::GetEnvironmentVariable("${prefix}_NETWORK")
    if ($Provider -eq 'hyperv' -and $Intent -eq 'hostOnly' -and [string]::IsNullOrWhiteSpace($name)) { $name = Get-LabHyperVSwitchDefault }
    $subnet = [string][Environment]::GetEnvironmentVariable("${prefix}_SUBNET")
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$definition.Name }
    if ([string]::IsNullOrWhiteSpace($subnet)) { $subnet = [string]$definition.Subnet }
    if ($name -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,62}$') { throw "LAB_NETWORK_NAME_INVALID: $name" }
    $parsed = ConvertTo-LabIpv4Subnet -Subnet $subnet
    $natName = if ($Provider -eq 'hyperv' -and $Intent -eq 'nat') {
        [string][Environment]::GetEnvironmentVariable("${prefix}_NAME")
    }
    if ($Provider -eq 'hyperv' -and $Intent -eq 'nat' -and [string]::IsNullOrWhiteSpace($natName)) { $natName = [string]$definition.NatName }
    return [PSCustomObject]@{
        Provider = $Provider; Name = $name; Subnet = $parsed.Cidr; PrefixLength = $parsed.PrefixLength
        HostAddress = (ConvertFrom-LabIpv4UInt32 -Value ([uint32]($parsed.Network + 1))).ToString()
        Intent = if ($Provider -eq 'hyperv') { $Intent } else { 'nat' }
        NatName = $natName
    }
}

function Get-LabKnownIpv4Subnets {
    [CmdletBinding()]
    param([ValidateSet('docker', 'podman', 'hyperv')][string]$Provider)

    $subnets = [System.Collections.Generic.List[string]]::new()
    if ($IsWindows -and (Get-Command Get-NetRoute -ErrorAction SilentlyContinue)) {
        Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object {
                $prefix = [string]$_.DestinationPrefix
                if ($prefix -match '^\d+\.\d+\.\d+\.\d+/(\d+)$' -and [int]$Matches[1] -gt 0 -and
                    $prefix -notin @('127.0.0.0/8', '169.254.0.0/16')) { $subnets.Add($prefix) }
            }
    }
    if ($Provider -in @('docker', 'hyperv') -and (Get-Command docker -ErrorAction SilentlyContinue)) {
        $ids = @(docker network ls -q 2>$null)
        if ($LASTEXITCODE -eq 0 -and $ids.Count -gt 0) {
            @(docker network inspect $ids 2>$null | ConvertFrom-Json -Depth 30) | ForEach-Object {
                @($_.IPAM.Config) | ForEach-Object { if ($_.Subnet) { $subnets.Add([string]$_.Subnet) } }
            }
        }
    }
    if ($Provider -in @('podman', 'hyperv') -and (Get-Command podman -ErrorAction SilentlyContinue)) {
        $ids = @(podman network ls -q 2>$null)
        if ($LASTEXITCODE -eq 0 -and $ids.Count -gt 0) {
            @(podman network inspect $ids 2>$null | ConvertFrom-Json -Depth 30) | ForEach-Object {
                @($_.subnets) | ForEach-Object { if ($_.subnet) { $subnets.Add([string]$_.subnet) } }
            }
        }
    }
    return @($subnets | Sort-Object -Unique)
}

function Assert-LabRuntimeNetworkAvailable {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Network, [string[]]$KnownSubnets = @())

    foreach ($candidate in @($KnownSubnets | Where-Object { $_ })) {
        try {
            if (Test-LabIpv4SubnetOverlap -Left $Network.Subnet -Right $candidate) {
                throw "LAB_NETWORK_SUBNET_CONFLICT: $($Network.Name) $($Network.Subnet) ueberlappt $candidate"
            }
        }
        catch {
            if ($_.Exception.Message -match '^LAB_NETWORK_SUBNET_CONFLICT:') { throw }
        }
    }
}

function Ensure-LabDockerNetwork {
    [CmdletBinding()]
    param([string]$Name, [string]$Subnet)

    $network = Get-LabRuntimeNetwork -Provider docker
    if ($Name) { $network.Name = $Name }; if ($Subnet) { $network.Subnet = (ConvertTo-LabIpv4Subnet -Subnet $Subnet).Cidr }
    $existing = @(docker network inspect $network.Name 2>$null | ConvertFrom-Json -Depth 30)[0]
    if ($existing) {
        $actualSubnet = [string]@($existing.IPAM.Config)[0].Subnet
        if ($actualSubnet -ne $network.Subnet -or [bool]$existing.Internal) { throw "LAB_NETWORK_CONTRACT_MISMATCH: $($network.Name)" }
        return $network
    }
    Assert-LabRuntimeNetworkAvailable -Network $network -KnownSubnets (Get-LabKnownIpv4Subnets -Provider docker)
    $null = docker network create --driver bridge --subnet $network.Subnet --label sql-server-lab.network=managed $network.Name
    if ($LASTEXITCODE -ne 0) { throw "LAB_NETWORK_CREATE_FAILED: Docker $($network.Name)" }
    return $network
}

function Get-LabPodmanCniNetworkConfigPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $fileName = "$Name.conflist"
    $candidates = [Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path '/etc/cni/net.d' $fileName))
    if (-not [string]::IsNullOrWhiteSpace([string]$env:XDG_CONFIG_HOME)) {
        $candidates.Add((Join-Path (Join-Path $env:XDG_CONFIG_HOME 'cni/net.d') $fileName))
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$HOME)) {
        $candidates.Add((Join-Path (Join-Path $HOME '.config/cni/net.d') $fileName))
    }
    $matches = @($candidates | Sort-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($matches.Count -gt 1) { throw "LAB_NETWORK_PODMAN_CNI_CONFIG_AMBIGUOUS: $Name" }
    return $(if ($matches.Count -eq 1) { [string]$matches[0] } else { $null })
}

function Repair-LabPodmanCniVersionCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NetworkConfigPath,
        [Parameter(Mandatory)][string]$NetworkName,
        [Parameter(Mandatory)][string]$PodmanVersion
    )

    if ($PodmanVersion -notmatch '^3\.4\.4(?:$|[-+])') { return $false }
    if ([IO.Path]::GetFileName($NetworkConfigPath) -cne "$NetworkName.conflist" -or
        -not (Test-Path -LiteralPath $NetworkConfigPath -PathType Leaf)) {
        throw "LAB_NETWORK_PODMAN_CNI_CONFIG_INVALID: $NetworkName"
    }
    $config = Get-Content -LiteralPath $NetworkConfigPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    if ([string]$config.name -cne $NetworkName -or @($config.plugins).Count -eq 0) {
        throw "LAB_NETWORK_PODMAN_CNI_CONFIG_INVALID: $NetworkName"
    }
    if ([string]$config.cniVersion -eq '0.4.0') { return $false }
    if ([string]$config.cniVersion -ne '1.0.0') { return $false }

    $config.cniVersion = '0.4.0'
    $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $NetworkConfigPath -Encoding utf8
    $verified = Get-Content -LiteralPath $NetworkConfigPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    if ([string]$verified.name -cne $NetworkName -or [string]$verified.cniVersion -ne '0.4.0' -or
        @($verified.plugins).Count -ne @($config.plugins).Count) {
        throw "LAB_NETWORK_PODMAN_CNI_COMPATIBILITY_FAILED: $NetworkName"
    }
    return $true
}

function Get-LabPodmanNetworkContractFromInspect {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inspect)

    if ($Inspect.PSObject.Properties.Name -contains 'subnets') {
        return [PSCustomObject]@{
            Subnet = [string]@($Inspect.subnets)[0].subnet
            Internal = [bool]$Inspect.internal
        }
    }
    $bridge = @($Inspect.plugins | Where-Object { [string]$_.type -eq 'bridge' })
    if ($bridge.Count -ne 1 -or @($bridge[0].ipam.ranges).Count -eq 0) {
        throw "LAB_NETWORK_PODMAN_INSPECT_INVALID: $($Inspect.name)"
    }
    $range = @($bridge[0].ipam.ranges)[0]
    $subnet = [string]@($range)[0].subnet
    $hasDefaultRoute = @($bridge[0].ipam.routes | Where-Object { [string]$_.dst -eq '0.0.0.0/0' }).Count -gt 0
    if ($subnet -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$') {
        throw "LAB_NETWORK_PODMAN_INSPECT_INVALID: $($Inspect.name)"
    }
    return [PSCustomObject]@{ Subnet=$subnet; Internal=(-not $hasDefaultRoute) }
}

function Ensure-LabPodmanNetwork {
    [CmdletBinding()]
    param([string]$Name, [string]$Subnet)

    $network = Get-LabRuntimeNetwork -Provider podman
    if ($Name) { $network.Name = $Name }; if ($Subnet) { $network.Subnet = (ConvertTo-LabIpv4Subnet -Subnet $Subnet).Cidr }
    $existing = @(podman network inspect $network.Name 2>$null | ConvertFrom-Json -Depth 30)[0]
    if ($existing) {
        $existingContract = Get-LabPodmanNetworkContractFromInspect -Inspect $existing
        if ($existingContract.Subnet -ne $network.Subnet -or $existingContract.Internal) { throw "LAB_NETWORK_CONTRACT_MISMATCH: $($network.Name)" }
        $podmanVersion = [string](& podman version --format '{{.Version}}' 2>$null)
        $configPath = Get-LabPodmanCniNetworkConfigPath -Name $network.Name
        if ($configPath -and (Repair-LabPodmanCniVersionCompatibility -NetworkConfigPath $configPath -NetworkName $network.Name -PodmanVersion $podmanVersion.Trim())) {
            Write-LabInfo "Podman-3.4.4-CNI-Vertrag fuer '$($network.Name)' auf 0.4.0 korrigiert."
        }
        return $network
    }
    Assert-LabRuntimeNetworkAvailable -Network $network -KnownSubnets (Get-LabKnownIpv4Subnets -Provider podman)
    $createOutput = @(podman network create --subnet $network.Subnet --label sql-server-lab.network=managed $network.Name)
    if ($LASTEXITCODE -ne 0) { throw "LAB_NETWORK_CREATE_FAILED: Podman $($network.Name)" }
    $podmanVersion = [string](& podman version --format '{{.Version}}' 2>$null)
    $configPath = @($createOutput | Where-Object { Test-Path -LiteralPath ([string]$_) -PathType Leaf } | Select-Object -First 1)
    if ($configPath.Count -eq 0) { $configPath = @(Get-LabPodmanCniNetworkConfigPath -Name $network.Name) }
    if ($configPath.Count -eq 1 -and $configPath[0] -and
        (Repair-LabPodmanCniVersionCompatibility -NetworkConfigPath ([string]$configPath[0]) -NetworkName $network.Name -PodmanVersion $podmanVersion.Trim())) {
        Write-LabInfo "Podman-3.4.4-CNI-Vertrag fuer '$($network.Name)' auf 0.4.0 korrigiert."
    }
    $created = @(podman network inspect $network.Name 2>$null | ConvertFrom-Json -Depth 30)[0]
    $createdContract = if ($created) { Get-LabPodmanNetworkContractFromInspect -Inspect $created } else { $null }
    if (-not $createdContract -or $createdContract.Subnet -ne $network.Subnet -or $createdContract.Internal) {
        throw "LAB_NETWORK_CONTRACT_MISMATCH: $($network.Name)"
    }
    return $network
}

function Ensure-LabHyperVNetwork {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Subnet,
        [ValidateSet('hostOnly', 'nat')][string]$Intent = 'hostOnly'
    )

    if (-not $IsWindows -or -not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) { throw 'LAB_NETWORK_HYPERV_UNAVAILABLE' }
    if ($Intent -eq 'nat') {
        $plan = Resolve-LabHyperVNetworkBoundPlan -Intent nat -SwitchName $Name -Subnet $Subnet
        if ($plan.Status -ne 'READY') { throw "LAB_NETWORK_HYPERV_NAT_BINDING_BLOCKED: $(@($plan.Blockers) -join ', ')" }
        return Invoke-LabHyperVNetworkBoundPlan -Plan $plan
    }
    $network = Get-LabRuntimeNetwork -Provider hyperv -Intent hostOnly
    if ($Name) { $network.Name = $Name }; if ($Subnet) { $network.Subnet = (ConvertTo-LabIpv4Subnet -Subnet $Subnet).Cidr }
    $switch = Get-VMSwitch -Name $network.Name -ErrorAction SilentlyContinue
    if ($switch -and [string]$switch.SwitchType -ne 'Internal') { throw "LAB_NETWORK_CONTRACT_MISMATCH: $($network.Name) ist nicht Internal" }
    if (-not $switch) {
        Assert-LabRuntimeNetworkAvailable -Network $network -KnownSubnets (Get-LabKnownIpv4Subnets)
        $switch = New-VMSwitch -Name $network.Name -SwitchType Internal -ErrorAction Stop
    }
    $adapterAlias = "vEthernet ($($network.Name))"
    $hostAddress = Get-NetIPAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
    if (-not $hostAddress) {
        New-NetIPAddress -InterfaceAlias $adapterAlias -IPAddress $network.HostAddress -PrefixLength $network.PrefixLength -ErrorAction Stop | Out-Null
    }
    elseif ([string]$hostAddress.IPAddress -ne $network.HostAddress -or [int]$hostAddress.PrefixLength -ne $network.PrefixLength) {
        throw "LAB_NETWORK_CONTRACT_MISMATCH: $($network.Name) Host-IP"
    }
    return $network
}

function Get-LabHyperVDnsServers {
    [CmdletBinding()]
    param()

    if (-not $IsWindows -or -not (Get-Command Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) { return @() }
    return @(
        Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -notlike 'vEthernet (*' } |
            ForEach-Object { @($_.ServerAddresses) } |
            Where-Object { $_ -and $_ -notlike '127.*' -and $_ -ne '0.0.0.0' } |
            Sort-Object -Unique
    )
}

function Resolve-LabHyperVNetworkBoundPlan {
    <# .SYNOPSIS Bindet Hyper-V hostOnly/NAT ausschliesslich lesend an den Hostzustand. #>
    [CmdletBinding()]
    param(
        [ValidateSet('hostOnly', 'nat')][string]$Intent = 'hostOnly',
        [string]$SwitchName,
        [string]$Subnet
    )

    $network = Get-LabRuntimeNetwork -Provider hyperv -Intent $Intent
    if ($SwitchName) { $network.Name = $SwitchName }
    if ($Subnet) {
        $parsed = ConvertTo-LabIpv4Subnet -Subnet $Subnet
        $network.Subnet = $parsed.Cidr; $network.PrefixLength = $parsed.PrefixLength
        $network.HostAddress = (ConvertFrom-LabIpv4UInt32 -Value ([uint32]($parsed.Network + 1))).ToString()
    }
    $blockers = [Collections.Generic.List[string]]::new()
    $actions = [Collections.Generic.List[string]]::new()
    $switch = Get-VMSwitch -Name $network.Name -ErrorAction SilentlyContinue
    if ($switch -and [string]$switch.SwitchType -ne 'Internal') { $blockers.Add('LAB_NETWORK_HYPERV_SWITCH_CONTRACT_MISMATCH') }
    elseif (-not $switch) { $actions.Add('create-internal-switch') }

    $alias = "vEthernet ($($network.Name))"
    $addresses = @(Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' })
    if ($addresses.Count -gt 0 -and -not @($addresses | Where-Object {
        [string]$_.IPAddress -eq $network.HostAddress -and [int]$_.PrefixLength -eq $network.PrefixLength
    })) { $blockers.Add('LAB_NETWORK_HYPERV_HOST_ADDRESS_CONTRACT_MISMATCH') }
    elseif ($addresses.Count -eq 0) { $actions.Add('assign-host-address') }

    $nats = @(); $namedNat = @()
    if ($Intent -eq 'nat') {
        if (-not (Get-Command Get-NetNat -ErrorAction SilentlyContinue)) { $blockers.Add('LAB_NETWORK_HYPERV_WINNAT_UNAVAILABLE') }
        else { $nats = @(Get-NetNat -ErrorAction SilentlyContinue) }
        $namedNat = @($nats | Where-Object { [string]$_.Name -eq [string]$network.NatName })
        if ($namedNat.Count -gt 1 -or ($namedNat.Count -eq 1 -and [string]$namedNat[0].InternalIPInterfaceAddressPrefix -ne $network.Subnet)) {
            $blockers.Add('LAB_NETWORK_HYPERV_NAT_CONTRACT_MISMATCH')
        }
        $foreignNats = @($nats | Where-Object {
            [string]$_.Name -ne [string]$network.NatName -or [string]$_.InternalIPInterfaceAddressPrefix -ne $network.Subnet
        })
        if ($foreignNats.Count -gt 0) { $blockers.Add('LAB_NETWORK_HYPERV_NAT_PREFIX_CONFLICT') }
        elseif ($namedNat.Count -eq 0) { $actions.Add('create-shared-winnat') }
    }

    if ($blockers.Count -eq 0) {
        $known = @(Get-LabKnownIpv4Subnets -Provider hyperv)
        $matchingHostAddress = @($addresses | Where-Object {
            [string]$_.IPAddress -eq $network.HostAddress -and [int]$_.PrefixLength -eq $network.PrefixLength
        }).Count -eq 1
        $ownsExactPrefix = ($switch -and $matchingHostAddress) -or ($namedNat.Count -eq 1)
        foreach ($candidate in $known) {
            if ($candidate -eq $network.Subnet -and $ownsExactPrefix) { continue }
            try {
                if (Test-LabIpv4SubnetOverlap -Left $network.Subnet -Right $candidate) {
                    $blockers.Add('LAB_NETWORK_HYPERV_SUBNET_CONFLICT'); break
                }
            } catch { }
        }
    }
    $dns = if ($Intent -eq 'nat') { @(Get-LabHyperVDnsServers) } else { @() }
    if ($Intent -eq 'nat' -and $dns.Count -eq 0) { $blockers.Add('LAB_NETWORK_HYPERV_DNS_UNAVAILABLE') }
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{ Name='SqlServerLab.HyperVNetworkBoundPlan'; Version='1.0' }
        Status=if ($blockers.Count -eq 0) { 'READY' } else { 'BLOCKED' }
        Intent=$Intent; Exposure='host'; Name=$network.Name; Subnet=$network.Subnet
        PrefixLength=$network.PrefixLength; HostAddress=$network.HostAddress; Gateway=if ($Intent -eq 'nat') { $network.HostAddress } else { $null }
        DnsServers=$dns; NatName=if ($Intent -eq 'nat') { $network.NatName } else { $null }
        Actions=@($actions); Blockers=@($blockers | Sort-Object -Unique)
    }
}

function Invoke-LabHyperVNetworkBoundPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    if ([string]$Plan.Contract.Name -ne 'SqlServerLab.HyperVNetworkBoundPlan' -or [string]$Plan.Status -ne 'READY') {
        throw 'LAB_NETWORK_HYPERV_BOUND_PLAN_NOT_READY'
    }
    $revalidated = Resolve-LabHyperVNetworkBoundPlan -Intent ([string]$Plan.Intent) -SwitchName ([string]$Plan.Name) -Subnet ([string]$Plan.Subnet)
    if ([string]$revalidated.Status -ne 'READY' -or
        [string]$revalidated.HostAddress -ne [string]$Plan.HostAddress -or
        [string]$revalidated.NatName -ne [string]$Plan.NatName) {
        throw "LAB_NETWORK_HYPERV_BOUND_PLAN_STALE: $(@($revalidated.Blockers) -join ', ')"
    }
    $Plan = $revalidated
    $createdSwitch = $false; $createdAddress = $false; $createdNat = $false
    try {
        $switch = Get-VMSwitch -Name ([string]$Plan.Name) -ErrorAction SilentlyContinue
        if (-not $switch) { $null = New-VMSwitch -Name ([string]$Plan.Name) -SwitchType Internal -ErrorAction Stop; $createdSwitch = $true }
        $alias = "vEthernet ($([string]$Plan.Name))"
        $address = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.IPAddress -eq [string]$Plan.HostAddress -and [int]$_.PrefixLength -eq [int]$Plan.PrefixLength } |
            Select-Object -First 1
        if (-not $address) {
            $null = New-NetIPAddress -InterfaceAlias $alias -IPAddress ([string]$Plan.HostAddress) -PrefixLength ([int]$Plan.PrefixLength) -ErrorAction Stop
            $createdAddress = $true
        }
        if ([string]$Plan.Intent -eq 'nat' -and -not (Get-NetNat -Name ([string]$Plan.NatName) -ErrorAction SilentlyContinue)) {
            $null = New-NetNat -Name ([string]$Plan.NatName) -InternalIPInterfaceAddressPrefix ([string]$Plan.Subnet) -ErrorAction Stop
            $createdNat = $true
        }
        return $Plan
    }
    catch {
        if ($createdNat) { Remove-NetNat -Name ([string]$Plan.NatName) -Confirm:$false -ErrorAction SilentlyContinue }
        if ($createdAddress) { Remove-NetIPAddress -InterfaceAlias $alias -IPAddress ([string]$Plan.HostAddress) -Confirm:$false -ErrorAction SilentlyContinue }
        if ($createdSwitch) { Remove-VMSwitch -Name ([string]$Plan.Name) -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Resolve-LabHyperVNetwork {
    <#
    .SYNOPSIS Liefert den verbindlichen Switch für reguläre Hyper-V-Labs.
    .DESCRIPTION Ohne ausdrückliche Isolation wird immer ein Internal-Switch
    mit Host-IP bereitgestellt. Bevor ein zweiter Standardswitch erstellt wird,
    wird ein vorhandener Switch mit dem Lab-Subnetz wiederverwendet.
    #>
    [CmdletBinding()]
    param(
        [string]$SwitchName,
        [switch]$Isolated,
        [ValidateSet('hostOnly', 'nat')][string]$Intent = 'hostOnly'
    )

    if ($Isolated) { return $null }
    if ($Intent -eq 'nat') {
        return Ensure-LabHyperVNetwork -Name $SwitchName -Intent nat
    }
    if ($SwitchName) {
        $network = Ensure-LabHyperVNetwork -Name $SwitchName
        $null = Set-LabHyperVSwitchDefault -SwitchName $network.Name
        return $network
    }

    $configured = Get-LabHyperVSwitchDefault
    if ($configured) { return Ensure-LabHyperVNetwork -Name $configured }

    $expected = Get-LabRuntimeNetwork -Provider hyperv
    $matching = @(
        Get-VMSwitch -SwitchType Internal -ErrorAction SilentlyContinue | Where-Object {
            $alias = "vEthernet ($($_.Name))"
            $address = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -eq $expected.HostAddress -and $_.PrefixLength -eq $expected.PrefixLength } |
                Select-Object -First 1
            $null -ne $address
        }
    )
    if ($matching.Count -eq 1) {
        $network = Ensure-LabHyperVNetwork -Name ([string]$matching[0].Name)
        $null = Set-LabHyperVSwitchDefault -SwitchName $network.Name
        return $network
    }
    $network = Ensure-LabHyperVNetwork
    $null = Set-LabHyperVSwitchDefault -SwitchName $network.Name
    return $network
}

function Get-LabNetworkGuestAddress {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Network, [Parameter(Mandatory)][string]$Identity)

    $subnet = ConvertTo-LabIpv4Subnet -Subnet ([string]$Network.Subnet)
    $capacity = [uint32]([math]::Pow(2, 32 - $subnet.PrefixLength))
    if ($capacity -lt 32) { throw 'LAB_NETWORK_SUBNET_TOO_SMALL' }
    $hash = [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Identity))
    $offset = 10 + (([uint32]$hash[0] * 256 + [uint32]$hash[1]) % ($capacity - 20))
    return (ConvertFrom-LabIpv4UInt32 -Value ([uint32]($subnet.Network + $offset))).ToString()
}

function Get-LabHyperVIpamPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)
    return Join-Path (Join-Path $StateRoot 'network') 'hyperv-ipam.json'
}

function Invoke-LabHyperVIpamLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    $fullRoot = [IO.Path]::GetFullPath($StateRoot).ToLowerInvariant()
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fullRoot))).Substring(0, 24)
    $mutex = [Threading.Mutex]::new($false, "SqlServerLab.HyperVIpam.$hash")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'LAB_NETWORK_HYPERV_IPAM_LOCK_TIMEOUT' }
        return & $ScriptBlock
    }
    finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Reserve-LabHyperVNetworkAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Network,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$StateRoot
    )
    return Invoke-LabHyperVIpamLock -StateRoot $StateRoot -ScriptBlock {
        $path = Get-LabHyperVIpamPath -StateRoot $StateRoot
        $registry = if (Test-Path -LiteralPath $path -PathType Leaf) {
            Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        } else { [PSCustomObject]@{ contractVersion='1'; leases=@() } }
        $existing = @($registry.leases | Where-Object {
            [string]$_.runId -eq $RunId -and [string]$_.scopeId -eq $ScopeId -and [string]$_.instanceId -eq $InstanceId -and [string]$_.state -eq 'ACTIVE'
        })
        if ($existing.Count -eq 1) { return $existing[0] }
        if ($existing.Count -gt 1) { throw 'LAB_NETWORK_HYPERV_IPAM_DUPLICATE_IDENTITY' }
        $subnet = ConvertTo-LabIpv4Subnet -Subnet ([string]$Network.Subnet)
        $capacity = [uint32]([math]::Pow(2, 32 - $subnet.PrefixLength))
        if ($capacity -lt 32) { throw 'LAB_NETWORK_SUBNET_TOO_SMALL' }
        $used = @{}; @($registry.leases | Where-Object { [string]$_.state -eq 'ACTIVE' -and [string]$_.subnet -eq [string]$Network.Subnet }) |
            ForEach-Object { $used[[string]$_.address] = $true }
        $seed = Get-LabNetworkGuestAddress -Network $Network -Identity "$RunId/$InstanceId"
        $start = (ConvertTo-LabIpv4UInt32 -Address ([Net.IPAddress]::Parse($seed))) - $subnet.Network
        $selected = $null
        for ($probe = 0; $probe -lt ($capacity - 20); $probe++) {
            $offset = 10 + (($start - 10 + $probe) % ($capacity - 20))
            $candidate = (ConvertFrom-LabIpv4UInt32 -Value ([uint32]($subnet.Network + $offset))).ToString()
            if (-not $used.ContainsKey($candidate)) { $selected = $candidate; break }
        }
        if (-not $selected) { throw 'LAB_NETWORK_HYPERV_IPAM_EXHAUSTED' }
        $lease = [PSCustomObject]@{
            leaseId=[Guid]::NewGuid().ToString('D'); state='ACTIVE'; network=[string]$Network.Name; subnet=[string]$Network.Subnet
            address=$selected; runId=$RunId; scopeId=$ScopeId; instanceId=$InstanceId; reservedAt=Get-LabTimestamp; releasedAt=$null
        }
        $registry.leases = @($registry.leases) + $lease
        Write-LabArtifactJsonAtomic -Path $path -InputObject $registry
        return $lease
    }
}

function Release-LabHyperVNetworkAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$StateRoot
    )
    return Invoke-LabHyperVIpamLock -StateRoot $StateRoot -ScriptBlock {
        $path = Get-LabHyperVIpamPath -StateRoot $StateRoot
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $registry = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        $leases = @($registry.leases | Where-Object {
            [string]$_.address -eq $Address -and [string]$_.runId -eq $RunId -and [string]$_.scopeId -eq $ScopeId -and [string]$_.state -eq 'ACTIVE'
        })
        if ($leases.Count -eq 0) { return $false }
        if ($leases.Count -ne 1) { throw 'LAB_NETWORK_HYPERV_IPAM_RELEASE_AMBIGUOUS' }
        $leases[0].state = 'RELEASED'; $leases[0].releasedAt = Get-LabTimestamp
        Write-LabArtifactJsonAtomic -Path $path -InputObject $registry
        return $true
    }
}

function Initialize-HyperVGuestLabNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)]$Network,
        [Parameter(Mandatory)][string]$Identity,
        [ValidatePattern('^(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3})?$')][string]$FallbackAddress
    )

    $address = if ($Network.PSObject.Properties['address'] -and $Network.address) { [string]$Network.address } else { Get-LabNetworkGuestAddress -Network $Network -Identity $Identity }
    $gateway = if ($Network.PSObject.Properties['gateway']) { [string]$Network.gateway } else { $null }
    $dnsServers = if ($Network.PSObject.Properties['dnsServers']) { @($Network.dnsServers) } else { @() }
    $receipt = Invoke-HyperVPowerShellDirect -VMName $VMName -ExpectedRunId $ExpectedRunId `
        -ExpectedScopeId $ExpectedScopeId -Credential $Credential `
        -FallbackAddress $(if ($FallbackAddress) { $FallbackAddress } else { $address }) `
        -ArgumentList @($address, [int]$Network.PrefixLength, [string]$Network.Name, [string]$Network.HostAddress, $gateway, $dnsServers) `
        -ScriptBlock {
            param($Address, $PrefixLength, $NetworkName, $HostAddress, $Gateway, $DnsServers)
            $ErrorActionPreference = 'Stop'
            $adapter = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1)[0]
            if (-not $adapter) { throw 'LAB_NETWORK_GUEST_ADAPTER_NOT_FOUND' }
            $existing = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' })
            if (-not @($existing | Where-Object { $_.IPAddress -eq $Address -and $_.PrefixLength -eq $PrefixLength })) {
                $existing | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                $newAddress = @{ InterfaceIndex=$adapter.ifIndex; IPAddress=$Address; PrefixLength=$PrefixLength; ErrorAction='Stop' }
                if ($Gateway) { $newAddress.DefaultGateway = $Gateway }
                New-NetIPAddress @newAddress | Out-Null
            }
            if ($Gateway) {
                $defaultRoutes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
                if (-not @($defaultRoutes | Where-Object { [string]$_.NextHop -eq [string]$Gateway })) {
                    $defaultRoutes | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                    New-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $Gateway -ErrorAction Stop | Out-Null
                }
            }
            if (@($DnsServers).Count -gt 0) { Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($DnsServers) -ErrorAction Stop }
            $deadline = [datetime]::UtcNow.AddSeconds(15)
            do {
                $observed = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -eq $Address -and $_.PrefixLength -eq $PrefixLength })
                if ($observed.Count -eq 1 -and [string]$observed[0].AddressState -eq 'Preferred') { break }
                if (@($observed | Where-Object { [string]$_.AddressState -in @('Duplicate','Invalid') }).Count -gt 0) {
                    throw "LAB_NETWORK_GUEST_ADDRESS_CONFLICT: $Address"
                }
                Start-Sleep -Milliseconds 250
            } while ([datetime]::UtcNow -lt $deadline)
            if ($observed.Count -ne 1 -or [string]$observed[0].AddressState -ne 'Preferred') {
                throw "LAB_NETWORK_GUEST_ADDRESS_NOT_READY: $Address/$PrefixLength"
            }
            if ($Gateway -and -not (Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Where-Object { [string]$_.NextHop -eq [string]$Gateway } | Select-Object -First 1)) {
                throw "LAB_NETWORK_GUEST_GATEWAY_NOT_READY: $Gateway"
            }
            $ruleName = 'SQL_Server_Lab SQL TCP Host'
            if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -RemoteAddress $HostAddress | Out-Null
            }
            [PSCustomObject]@{
                contractVersion = '1'; network = $NetworkName
                address = [string]$observed[0].IPAddress; prefixLength = [int]$observed[0].PrefixLength
                addressState = [string]$observed[0].AddressState; gateway = $Gateway; dnsServers = @($DnsServers); observedAt = [datetime]::UtcNow.ToString('o')
            }
        }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.contractVersion -ne '1' -or
        [string]$receipt.address -ne $address -or [int]$receipt.prefixLength -ne [int]$Network.PrefixLength -or
        [string]$receipt.addressState -ne 'Preferred') {
        throw 'LAB_NETWORK_GUEST_RECEIPT_INVALID'
    }
    return [PSCustomObject]@{ Network = [string]$Network.Name; Address = $address; PrefixLength = [int]$Network.PrefixLength; ObservedAt = [string]$receipt.observedAt }
}
