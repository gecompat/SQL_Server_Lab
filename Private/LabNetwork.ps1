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

function Get-LabRuntimeNetwork {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('docker', 'podman', 'hyperv')][string]$Provider)

    $defaults = @{
        docker = @{ Name = 'SQL_LAB_DOCKER'; Subnet = '172.26.0.0/16'; EnvironmentPrefix = 'DOCKER' }
        podman = @{ Name = 'SQL_LAB_PODMAN'; Subnet = '172.27.0.0/16'; EnvironmentPrefix = 'PODMAN' }
        hyperv = @{ Name = 'SQL_LAB_HYPERV'; Subnet = '172.28.0.0/24'; EnvironmentPrefix = 'HYPERV' }
    }
    $definition = $defaults[$Provider]
    $prefix = "SQL_SERVER_LAB_$($definition.EnvironmentPrefix)"
    $name = [string][Environment]::GetEnvironmentVariable("${prefix}_NETWORK")
    if ($Provider -eq 'hyperv' -and [string]::IsNullOrWhiteSpace($name)) { $name = Get-LabHyperVSwitchDefault }
    $subnet = [string][Environment]::GetEnvironmentVariable("${prefix}_SUBNET")
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$definition.Name }
    if ([string]::IsNullOrWhiteSpace($subnet)) { $subnet = [string]$definition.Subnet }
    if ($name -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,62}$') { throw "LAB_NETWORK_NAME_INVALID: $name" }
    $parsed = ConvertTo-LabIpv4Subnet -Subnet $subnet
    return [PSCustomObject]@{
        Provider = $Provider; Name = $name; Subnet = $parsed.Cidr; PrefixLength = $parsed.PrefixLength
        HostAddress = (ConvertFrom-LabIpv4UInt32 -Value ([uint32]($parsed.Network + 1))).ToString()
    }
}

function Get-LabKnownIpv4Subnets {
    [CmdletBinding()]
    param([ValidateSet('docker', 'podman', 'hyperv')][string]$Provider)

    $subnets = [System.Collections.Generic.List[string]]::new()
    if ($IsWindows -and (Get-Command Get-NetRoute -ErrorAction SilentlyContinue)) {
        Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object { if ([string]$_.DestinationPrefix -match '^\d+\.\d+\.\d+\.\d+/\d+$') { $subnets.Add([string]$_.DestinationPrefix) } }
    }
    if ($Provider -eq 'docker' -and (Get-Command docker -ErrorAction SilentlyContinue)) {
        $ids = @(docker network ls -q 2>$null)
        if ($LASTEXITCODE -eq 0 -and $ids.Count -gt 0) {
            @(docker network inspect $ids 2>$null | ConvertFrom-Json -Depth 30) | ForEach-Object {
                @($_.IPAM.Config) | ForEach-Object { if ($_.Subnet) { $subnets.Add([string]$_.Subnet) } }
            }
        }
    }
    if ($Provider -eq 'podman' -and (Get-Command podman -ErrorAction SilentlyContinue)) {
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

function Ensure-LabPodmanNetwork {
    [CmdletBinding()]
    param([string]$Name, [string]$Subnet)

    $network = Get-LabRuntimeNetwork -Provider podman
    if ($Name) { $network.Name = $Name }; if ($Subnet) { $network.Subnet = (ConvertTo-LabIpv4Subnet -Subnet $Subnet).Cidr }
    $existing = @(podman network inspect $network.Name 2>$null | ConvertFrom-Json -Depth 30)[0]
    if ($existing) {
        $actualSubnet = [string]@($existing.subnets)[0].subnet
        if ($actualSubnet -ne $network.Subnet -or [bool]$existing.internal) { throw "LAB_NETWORK_CONTRACT_MISMATCH: $($network.Name)" }
        return $network
    }
    Assert-LabRuntimeNetworkAvailable -Network $network -KnownSubnets (Get-LabKnownIpv4Subnets -Provider podman)
    $null = podman network create --subnet $network.Subnet --label sql-server-lab.network=managed $network.Name
    if ($LASTEXITCODE -ne 0) { throw "LAB_NETWORK_CREATE_FAILED: Podman $($network.Name)" }
    return $network
}

function Ensure-LabHyperVNetwork {
    [CmdletBinding()]
    param([string]$Name, [string]$Subnet)

    if (-not $IsWindows -or -not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) { throw 'LAB_NETWORK_HYPERV_UNAVAILABLE' }
    $network = Get-LabRuntimeNetwork -Provider hyperv
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

function Resolve-LabHyperVNetwork {
    <#
    .SYNOPSIS Liefert den verbindlichen Switch für reguläre Hyper-V-Labs.
    .DESCRIPTION Ohne ausdrückliche Isolation wird immer ein Internal-Switch
    mit Host-IP bereitgestellt. Bevor ein zweiter Standardswitch erstellt wird,
    wird ein vorhandener Switch mit dem Lab-Subnetz wiederverwendet.
    #>
    [CmdletBinding()]
    param([string]$SwitchName, [switch]$Isolated)

    if ($Isolated) { return $null }
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

function Initialize-HyperVGuestLabNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)]$Network,
        [Parameter(Mandatory)][string]$Identity,
        [ValidatePattern('^(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}$')][string]$FallbackAddress
    )

    $address = Get-LabNetworkGuestAddress -Network $Network -Identity $Identity
    $receipt = Invoke-HyperVPowerShellDirect -VMName $VMName -ExpectedRunId $ExpectedRunId `
        -ExpectedScopeId $ExpectedScopeId -Credential $Credential `
        -FallbackAddress $(if ($FallbackAddress) { $FallbackAddress } else { $address }) `
        -ArgumentList @($address, [int]$Network.PrefixLength, [string]$Network.Name, [string]$Network.HostAddress) `
        -ScriptBlock {
            param($Address, $PrefixLength, $NetworkName, $HostAddress)
            $ErrorActionPreference = 'Stop'
            $adapter = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1)[0]
            if (-not $adapter) { throw 'LAB_NETWORK_GUEST_ADAPTER_NOT_FOUND' }
            $existing = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' })
            if (-not @($existing | Where-Object { $_.IPAddress -eq $Address -and $_.PrefixLength -eq $PrefixLength })) {
                $existing | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Address -PrefixLength $PrefixLength -ErrorAction Stop | Out-Null
            }
            $ruleName = 'SQL_Server_Lab SQL TCP Host'
            if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -RemoteAddress $HostAddress | Out-Null
            }
            [PSCustomObject]@{ contractVersion = '1'; network = $NetworkName; address = $Address; prefixLength = $PrefixLength; observedAt = [datetime]::UtcNow.ToString('o') }
        }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.contractVersion -ne '1' -or [string]$receipt.address -ne $address) {
        throw 'LAB_NETWORK_GUEST_RECEIPT_INVALID'
    }
    return [PSCustomObject]@{ Network = [string]$Network.Name; Address = $address; PrefixLength = [int]$Network.PrefixLength; ObservedAt = [string]$receipt.observedAt }
}
