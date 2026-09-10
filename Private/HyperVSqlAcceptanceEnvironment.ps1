<#
.SYNOPSIS
    Direkter SQL-Windows-Abnahmepfad auf einem Hyper-V-SQL-Builder.
.DESCRIPTION
    Installiert SQL Server 2019, 2022 oder 2025 vollstaendig in der bereits
    gestarteten, OOBE-abgeschlossenen Builder-VM. Der Pfad ist bewusst
    run-lokal und publiziert kein Prepared-Image. SA-Secrets werden unter
    Windows nur DPAPI-verschluesselt im Build-Verzeichnis gespeichert;
    Gast-Credentials werden nie persistiert.
#>

function New-HyperVSqlUnattendedPassword {
    [CmdletBinding()]
    param([ValidateRange(16, 128)][int]$Length = 32)

    $classes = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!#%+-_@'
    )
    $characters = [System.Collections.Generic.List[char]]::new()
    foreach ($class in $classes) {
        $characters.Add($class[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($class.Length)])
    }
    $all = ($classes -join '')
    while ($characters.Count -lt $Length) {
        $characters.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
    }
    for ($i = $characters.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $temporary = $characters[$i]; $characters[$i] = $characters[$j]; $characters[$j] = $temporary
    }
    $plain = -join $characters
    try { return ConvertTo-SecureString $plain -AsPlainText -Force }
    finally { $plain = $null }
}

function Get-HyperVSqlGuestCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build)

    $password = Get-LabSecret -Path $Build.BuildDirectory -Name 'guest-administrator-password'
    if (-not $password) { throw 'HYPERV_SQL_GUEST_PASSWORD_NOT_FOUND' }
    return [PSCredential]::new('Administrator', $password)
}

function New-HyperVSqlGuestNetworkBootstrapScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Network,
        [string]$Address
    )

    $addressMode = if (($Network.PSObject.Properties['AddressMode'] -and [string]$Network.AddressMode -eq 'dhcp') -or
        ($Network.PSObject.Properties['Intent'] -and [string]$Network.Intent -eq 'lan')) { 'dhcp' } else { 'static' }
    if ($addressMode -eq 'dhcp') {
        return @"
`$ErrorActionPreference = 'Stop'
`$adapter = @(Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1)[0]
if (-not `$adapter) { throw 'SQL_LAB_OOBE_NETWORK_ADAPTER_NOT_FOUND' }
Set-NetIPInterface -InterfaceIndex `$adapter.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
Set-DnsClientServerAddress -InterfaceIndex `$adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
ipconfig.exe /renew `$adapter.InterfaceAlias | Out-Null
`$deadline = [datetime]::UtcNow.AddSeconds(30)
do {
    `$observed = @(Get-NetIPAddress -InterfaceIndex `$adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { `$_.IPAddress -notlike '169.254.*' -and `$_.IPAddress -ne '127.0.0.1' -and [string]`$_.AddressState -eq 'Preferred' } |
        Select-Object -First 1)
    if (`$observed.Count -eq 1) { break }
    Start-Sleep -Milliseconds 500
} while ([datetime]::UtcNow -lt `$deadline)
if (`$observed.Count -ne 1) { throw 'SQL_LAB_OOBE_DHCP_ADDRESS_NOT_READY' }
`$gateway = [string]@(Get-NetRoute -InterfaceIndex `$adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric | Select-Object -First 1).NextHop
`$dnsServers = @(Get-DnsClientServerAddress -InterfaceIndex `$adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
Set-NetConnectionProfile -InterfaceIndex `$adapter.ifIndex -NetworkCategory Private -ErrorAction SilentlyContinue
Set-Service -Name WinRM -StartupType Automatic -ErrorAction Stop
`$winRmReady = (Get-Service -Name WinRM -ErrorAction SilentlyContinue).Status -eq 'Running' -and
    @(Get-ChildItem -LiteralPath WSMan:\localhost\Listener -ErrorAction SilentlyContinue).Count -gt 0
if (-not `$winRmReady) { Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop }
`$ruleName = 'SQL_Server_Lab WinRM LAN'
if (-not (Get-NetFirewallRule -DisplayName `$ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName `$ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 -RemoteAddress LocalSubnet | Out-Null
}
`$receiptDirectory = Join-Path `$env:ProgramData 'SqlServerLab'
New-Item -Path `$receiptDirectory -ItemType Directory -Force | Out-Null
[PSCustomObject]@{ contractVersion = '1'; network = '$($Network.Name)'; addressMode = 'dhcp'; address = [string]`$observed[0].IPAddress; prefixLength = [int]`$observed[0].PrefixLength; hostAddress = `$null; gateway = `$gateway; dnsServers = `$dnsServers; observedAt = [datetime]::UtcNow.ToString('o') } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path `$receiptDirectory 'oobe-network.json') -Encoding UTF8
"@
    }
    if ([string]::IsNullOrWhiteSpace($Address)) { throw 'LAB_NETWORK_STATIC_ADDRESS_REQUIRED' }

    $prefixLength = [int]$Network.PrefixLength
    $hostAddress = [string]$Network.HostAddress
    $gateway = if ($Network.PSObject.Properties['gateway']) { [string]$Network.gateway } else { '' }
    $dnsLiteral = if ($Network.PSObject.Properties['dnsServers']) {
        "@(" + ((@($Network.dnsServers) | ForEach-Object { "'$([string]$_)'" }) -join ',') + ")"
    } else { '@()' }
    return @"
`$ErrorActionPreference = 'Stop'
`$adapter = @(Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1)[0]
if (-not `$adapter) { throw 'SQL_LAB_OOBE_NETWORK_ADAPTER_NOT_FOUND' }
`$existing = @(Get-NetIPAddress -InterfaceIndex `$adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { `$_.IPAddress -notlike '169.254.*' -and `$_.IPAddress -ne '127.0.0.1' })
if (-not @(`$existing | Where-Object { `$_.IPAddress -eq '$Address' -and `$_.PrefixLength -eq $prefixLength })) {
    `$existing | Remove-NetIPAddress -Confirm:`$false -ErrorAction SilentlyContinue
    `$newAddress = @{ InterfaceIndex=`$adapter.ifIndex; IPAddress='$Address'; PrefixLength=$prefixLength; ErrorAction='Stop' }
    if ('$gateway') { `$newAddress.DefaultGateway = '$gateway' }
    New-NetIPAddress @newAddress | Out-Null
}
if ('$gateway') {
    `$defaultRoutes = @(Get-NetRoute -InterfaceIndex `$adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    if (-not @(`$defaultRoutes | Where-Object { [string]`$_.NextHop -eq '$gateway' })) {
        `$defaultRoutes | Remove-NetRoute -Confirm:`$false -ErrorAction SilentlyContinue
        New-NetRoute -InterfaceIndex `$adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop '$gateway' -ErrorAction Stop | Out-Null
    }
}
`$dnsServers = $dnsLiteral
if (`$dnsServers.Count -gt 0) { Set-DnsClientServerAddress -InterfaceIndex `$adapter.ifIndex -ServerAddresses `$dnsServers -ErrorAction Stop }
Set-NetConnectionProfile -InterfaceIndex `$adapter.ifIndex -NetworkCategory Private -ErrorAction SilentlyContinue
Set-Service -Name WinRM -StartupType Automatic -ErrorAction Stop
`$winRmReady = (Get-Service -Name WinRM -ErrorAction SilentlyContinue).Status -eq 'Running' -and
    @(Get-ChildItem -LiteralPath WSMan:\localhost\Listener -ErrorAction SilentlyContinue).Count -gt 0
if (-not `$winRmReady) { Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop }
`$ruleName = 'SQL_Server_Lab WinRM Host'
if (-not (Get-NetFirewallRule -DisplayName `$ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName `$ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 -RemoteAddress '$hostAddress' | Out-Null
}
`$receiptDirectory = Join-Path `$env:ProgramData 'SqlServerLab'
New-Item -Path `$receiptDirectory -ItemType Directory -Force | Out-Null
[PSCustomObject]@{ contractVersion = '1'; network = '$($Network.Name)'; address = '$Address'; prefixLength = $prefixLength; hostAddress = '$hostAddress'; gateway = '$gateway'; dnsServers = `$dnsServers; observedAt = [datetime]::UtcNow.ToString('o') } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path `$receiptDirectory 'oobe-network.json') -Encoding UTF8
"@
}

function New-HyperVSqlLegacyGuestNetworkBootstrapScript {
    <# .SYNOPSIS Erzeugt einen Windows-Server-2008-R2/PowerShell-2-kompatiblen Labnetz-Bootstrap. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Network,
        [Parameter(Mandatory)][string]$Address
    )

    if ([string]::IsNullOrWhiteSpace($Address)) { throw 'LAB_NETWORK_STATIC_ADDRESS_REQUIRED' }
    $prefixLength = [int]$Network.PrefixLength
    if ($prefixLength -lt 1 -or $prefixLength -gt 32) { throw 'LAB_NETWORK_PREFIX_INVALID' }
    $remainingBits = $prefixLength
    $mask = @(foreach ($octet in 1..4) {
        $bits = [Math]::Min(8, [Math]::Max(0, $remainingBits))
        if ($bits -eq 0) { '0' } elseif ($bits -eq 8) { '255' } else { [string](256 - [Math]::Pow(2, 8 - $bits)) }
        $remainingBits -= $bits
    }) -join '.'
    $hostAddress = [string]$Network.HostAddress
    $gateway = if ($Network.PSObject.Properties['gateway']) { [string]$Network.gateway } else { '' }
    $dnsLiteral = if ($Network.PSObject.Properties['dnsServers']) {
        '@(' + ((@($Network.dnsServers) | ForEach-Object { "'$([string]$_)'" }) -join ',') + ')'
    } else { '@()' }
    return @"
`$ErrorActionPreference = 'Stop'
`$adapter = @(Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { `$_.IPEnabled } | Sort-Object Index | Select-Object -First 1)[0]
if (-not `$adapter) { throw 'SQL_LAB_OOBE_NETWORK_ADAPTER_NOT_FOUND' }
`$staticResult = `$adapter.EnableStatic(@('$Address'), @('$mask'))
if (@(0, 1) -notcontains [int]`$staticResult.ReturnValue) { throw "SQL_LAB_OOBE_ENABLE_STATIC_FAILED: `$(`$staticResult.ReturnValue)" }
if ('$gateway') {
    `$gatewayResult = `$adapter.SetGateways(@('$gateway'), @(1))
    if (@(0, 1) -notcontains [int]`$gatewayResult.ReturnValue) { throw "SQL_LAB_OOBE_GATEWAY_FAILED: `$(`$gatewayResult.ReturnValue)" }
}
`$dnsServers = $dnsLiteral
if (`$dnsServers.Count -gt 0) {
    `$dnsResult = `$adapter.SetDNSServerSearchOrder([string[]]`$dnsServers)
    if (@(0, 1) -notcontains [int]`$dnsResult.ReturnValue) { throw "SQL_LAB_OOBE_DNS_FAILED: `$(`$dnsResult.ReturnValue)" }
}
`$null = & reg.exe add 'HKU\.DEFAULT\Keyboard Layout\Preload' /v 1 /t REG_SZ /d 00000407 /f
if (`$LASTEXITCODE -ne 0) { throw 'SQL_LAB_OOBE_DEFAULT_KEYBOARD_FAILED' }
`$null = & reg.exe add 'HKCU\Keyboard Layout\Preload' /v 1 /t REG_SZ /d 00000407 /f
if (`$LASTEXITCODE -ne 0) { throw 'SQL_LAB_OOBE_USER_KEYBOARD_FAILED' }
`$receiptDirectory = Join-Path `$env:ProgramData 'SqlServerLab'
New-Item -Path `$receiptDirectory -ItemType Directory -Force | Out-Null
Set-Content -LiteralPath (Join-Path `$receiptDirectory 'oobe-network.txt') -Encoding ASCII -Value "contractVersion=1`r`nnetwork=$($Network.Name)`r`naddress=$Address`r`nprefixLength=$prefixLength`r`nhostAddress=$hostAddress"
"@
}

function New-HyperVSqlOobeUnattendXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][SecureString]$AdministratorPassword,
        $Network,
        [string]$Identity,
        [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')][string]$SystemLocale = 'de-DE',
        [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')][string]$UiLanguage = 'en-US',
        [ValidatePattern('^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}$')][string]$InputLocale = '0407:00000407',
        [ValidateNotNullOrEmpty()][string]$TimeZone = 'W. Europe Standard Time'
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdministratorPassword)
    $plain = $null
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $escapedPassword = [System.Security.SecurityElement]::Escape($plain)
        $escapedSystemLocale = [System.Security.SecurityElement]::Escape($SystemLocale.Trim())
        $escapedUiLanguage = [System.Security.SecurityElement]::Escape($UiLanguage.Trim())
        $escapedInputLocale = [System.Security.SecurityElement]::Escape($InputLocale.Trim())
        $escapedTimeZone = [System.Security.SecurityElement]::Escape($TimeZone.Trim())
        return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Disable interactive privacy experience</Description>
          <Path>reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE" /v DisablePrivacyExperience /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>$escapedInputLocale</InputLocale>
      <SystemLocale>$escapedSystemLocale</SystemLocale>
      <UILanguage>$escapedUiLanguage</UILanguage>
      <UserLocale>$escapedSystemLocale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <UserAccounts>
        <AdministratorPassword><Value>$escapedPassword</Value><PlainText>true</PlainText></AdministratorPassword>
      </UserAccounts>
      <AutoLogon><Password><Value>$escapedPassword</Value><PlainText>true</PlainText></Password><Enabled>true</Enabled><LogonCount>1</LogonCount><Username>Administrator</Username></AutoLogon>
      <RegisteredOwner>SQL_Server_Lab</RegisteredOwner>
      <TimeZone>$escapedTimeZone</TimeZone>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
    </component>
  </settings>
</unattend>
"@
    }
    finally {
        $plain = $null
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Set-HyperVSqlOfflineUnattend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][string]$MountRoot,
        [Parameter(Mandatory)][string]$UnattendXml,
        [string]$BootstrapScript
    )

    New-Item -Path $MountRoot -ItemType Directory -Force | Out-Null
    $mounted = $null; $accessPathAdded = $false; $partition = $null
    try {
        try { $mounted = Mount-VHD -Path $VhdxPath -PassThru -ErrorAction Stop }
        catch {
            if ($_.Exception.Message -match '0x80070522|erforderliches Recht|required privilege') {
                throw 'HYPERV_SQL_OOBE_OFFLINE_MOUNT_REQUIRES_ELEVATED_RUNNER'
            }
            throw
        }
        $disk = $mounted | Get-Disk -ErrorAction Stop
        foreach ($candidate in @($disk | Get-Partition -ErrorAction Stop | Where-Object Size -GT 4GB)) {
            $candidateRoot = $null
            if ($candidate.DriveLetter) { $candidateRoot = "$($candidate.DriveLetter):\" }
            else {
                Add-PartitionAccessPath -DiskNumber $candidate.DiskNumber -PartitionNumber $candidate.PartitionNumber `
                    -AccessPath ($MountRoot.TrimEnd('\') + '\') -ErrorAction Stop
                $candidateRoot = $MountRoot.TrimEnd('\') + '\'; $accessPathAdded = $true
            }
            if (Test-Path -LiteralPath (Join-Path $candidateRoot 'Windows/System32/Config/SYSTEM') -PathType Leaf) {
                $partition = $candidate
                $panther = Join-Path $candidateRoot 'Windows/Panther'
                New-Item -Path $panther -ItemType Directory -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $panther 'Unattend.xml') -Value $UnattendXml -Encoding utf8NoBOM
                $unattendDirectory = Join-Path $panther 'Unattend'
                New-Item -Path $unattendDirectory -ItemType Directory -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $unattendDirectory 'Unattend.xml') -Value $UnattendXml -Encoding utf8NoBOM
                if ($BootstrapScript) {
                    $setupScripts = Join-Path $candidateRoot 'Windows/Setup/Scripts'
                    New-Item -Path $setupScripts -ItemType Directory -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $setupScripts 'SqlServerLabBootstrap.ps1') -Value $BootstrapScript -Encoding utf8NoBOM
                    Set-Content -LiteralPath (Join-Path $setupScripts 'SetupComplete.cmd') -Encoding ascii -Value @"
@echo off
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\SqlServerLabBootstrap.ps1" >> "%WINDIR%\Panther\SqlServerLabBootstrap.log" 2>&1
exit /b 0
"@
                }
                return
            }
            if ($accessPathAdded) {
                Remove-PartitionAccessPath -DiskNumber $candidate.DiskNumber -PartitionNumber $candidate.PartitionNumber `
                    -AccessPath ($MountRoot.TrimEnd('\') + '\') -ErrorAction Stop
                $accessPathAdded = $false
            }
        }
        throw 'HYPERV_SQL_WINDOWS_PARTITION_NOT_FOUND'
    }
    finally {
        if ($accessPathAdded -and $partition) {
            Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber `
                -AccessPath ($MountRoot.TrimEnd('\') + '\') -ErrorAction SilentlyContinue
        }
        if ($mounted) { Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $MountRoot -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-HyperVSqlUnattendedOobe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [SecureString]$AdministratorPassword,
        [ValidateRange(60, 3600)][int]$TimeoutSeconds = 900,
        [string]$StateRoot
    )

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build -or $build.state -notin @('MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING', 'OOBE_COMPLETED')) {
        throw 'HYPERV_SQL_OOBE_NOT_READY'
    }
    if ($build.state -eq 'OOBE_COMPLETED') { return $build }
    $build = Ensure-HyperVSqlBuildLabNetwork -Build $build -StateRoot $StateRoot
    if (-not $AdministratorPassword) {
        $AdministratorPassword = Get-LabSecret -Path $build.BuildDirectory -Name 'guest-administrator-password'
    }
    if (-not $AdministratorPassword) { $AdministratorPassword = New-HyperVSqlUnattendedPassword }
    Save-LabSecret -Path $build.BuildDirectory -Name 'guest-administrator-password' -Secret $AdministratorPassword
    $credential = [PSCredential]::new('Administrator', $AdministratorPassword)
    $vmName = [string]$build.builder.vmName

    if ([string]$build.parentArtifact.platform.guestControl -eq 'legacy-wmi') {
        $managed = Get-HyperVManagedVM -VMName $vmName -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
        if (-not $managed) { throw 'HYPERV_SQL_OOBE_VM_NOT_FOUND' }
        if ([string]$managed.Identity.guestTransport -ne 'lab-winrm') {
            $null = Set-HyperVManagedVMIdentityProperty -ManagedVM $managed -PropertyName guestTransport `
                -Value 'lab-winrm' -ContractVersion '0.8'
        }
    }

    $fallbackAddress = if ($build.labNetwork) {
        Get-LabNetworkGuestAddress -Network $build.labNetwork -Identity $build.buildId
    }
    $legacyGuest = [string]$build.parentArtifact.platform.guestControl -eq 'legacy-wmi'
    $bootstrapVersion = if ($legacyGuest) { 'network-winrm-legacy-v1' } else { 'network-winrm-v1' }
    $bootstrap = if ($legacyGuest) {
        New-HyperVSqlLegacyGuestNetworkBootstrapScript -Network $build.labNetwork -Address $fallbackAddress
    } else {
        New-HyperVSqlGuestNetworkBootstrapScript -Network $build.labNetwork -Address $fallbackAddress
    }
    $requiresBootstrapInjection = $build.state -eq 'MANUAL_ACTION_REQUIRED' -or
        [string]$build.oobeAutomation.bootstrapVersion -ne $bootstrapVersion
    if ($requiresBootstrapInjection) {
        Write-LabInfo "OOBE: stoppe $vmName und injiziere Unattend.xml mit Labnetz-Bootstrap"
        $null = Stop-HyperVInstance -VMName $vmName -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
        $vhdxPath = Resolve-LabHyperVBuilderDiskPath -Build $build
        $unattend = if ($legacyGuest) {
            New-HyperVLegacyWindowsOobeUnattendXml -AdministratorPassword $AdministratorPassword
        } else {
            New-HyperVSqlOobeUnattendXml -AdministratorPassword $AdministratorPassword `
                -Network $build.labNetwork -Identity $build.buildId
        }
        try {
            Set-HyperVSqlOfflineUnattend -VhdxPath $vhdxPath `
                -MountRoot (Join-Path $build.BuildDirectory 'offline-mount') -UnattendXml $unattend -BootstrapScript $bootstrap
        }
        finally { $unattend = $null }
        $build | Add-Member -NotePropertyName oobeAutomation -NotePropertyValue ([PSCustomObject]@{
            status = 'RUNNING'; region = 'DE'; systemLocale = 'de-DE'; uiLanguage = 'en-US'
            inputLocale = '0407:00000407'; timeZone = 'W. Europe Standard Time'
            passwordStorage = 'host-dpapi'; answerMedia = 'offline-vhdx'; bootstrapVersion = $bootstrapVersion
            labAddress = $fallbackAddress; startedAt = Get-LabTimestamp
        }) -Force
        Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
        $build = Set-HyperVSqlImageBuildState -BuildId $BuildId -State OOBE_AUTOMATION_RUNNING `
            -Reason 'Unattend.xml offline injiziert; Windows-OOBE wird unbeaufsichtigt abgeschlossen' -StateRoot $StateRoot
        Write-LabInfo "OOBE: starte $vmName und warte maximal $TimeoutSeconds Sekunden auf PowerShell Direct oder Lab-WinRM ($fallbackAddress)"
        $null = Start-HyperVInstance -VMName $vmName -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
    }

    if ($legacyGuest) {
        $blockingProgress = Start-LabBlockingActionProgress -Phase GuestWait
        try {
        Write-LabInfo "OOBE: pruefe Windows-Readiness per Legacy-WMI"
        $adapterName = [string]@(Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop |
            Where-Object { $_.IsLegacy } | Select-Object -First 1).Name
        if (-not $adapterName) { throw 'HYPERV_SQL_LEGACY_NETWORK_ADAPTER_NOT_FOUND' }
        $wmiReady = Wait-HyperVLegacyWindowsWmi -VMName $vmName -AdapterName $adapterName `
            -Credential $credential -TimeoutSeconds ([Math]::Min(180, $TimeoutSeconds))
        if (-not $wmiReady.Ready -and $fallbackAddress -in @(Get-HyperVLegacyWindowsGuestIPv4 -VMName $vmName -AdapterName $adapterName)) {
            Write-LabInfo 'OOBE: Legacy-Netzwerktreiber verlangt einen einmaligen Neustart; starte Gast neu.'
            $null = Restart-VM -Name $vmName -Force -ErrorAction Stop
            $wmiReady = Wait-HyperVLegacyWindowsWmi -VMName $vmName -AdapterName $adapterName `
                -Credential $credential -TimeoutSeconds ([Math]::Max(60, $TimeoutSeconds - 180))
        }
        if (-not $wmiReady.Ready) { throw "HYPERV_SQL_OOBE_TIMEOUT: $($wmiReady.LastError)" }
        $guest = Get-HyperVLegacyWindowsGuestReceipt -Scope $wmiReady.Scope
        $systemLocale = Get-HyperVLegacyWindowsRegistryValue -Scope $wmiReady.Scope `
            -SubKey 'SYSTEM\CurrentControlSet\Control\Nls\Language' -Name 'Default'
        $inputLocale = Get-HyperVLegacyWindowsRegistryValue -Scope $wmiReady.Scope `
            -SubKey '.DEFAULT\Keyboard Layout\Preload' -Name '1' -Hive HKU
        if ($inputLocale -ne '00000407') {
            Write-LabInfo 'OOBE: setze deutsche Tastatur fuer den Anmeldebildschirm per Legacy-WMI nach.'
            $null = Invoke-HyperVLegacyWindowsProcess -Scope $wmiReady.Scope `
                -CommandLine 'reg.exe add "HKU\.DEFAULT\Keyboard Layout\Preload" /v 1 /t REG_SZ /d 00000407 /f'
            $keyboardDeadline = [datetime]::UtcNow.AddSeconds(30)
            do {
                Start-Sleep -Seconds 2
                $inputLocale = Get-HyperVLegacyWindowsRegistryValue -Scope $wmiReady.Scope `
                    -SubKey '.DEFAULT\Keyboard Layout\Preload' -Name '1' -Hive HKU
            } while ($inputLocale -ne '00000407' -and [datetime]::UtcNow -lt $keyboardDeadline)
        }
        $timeZone = Get-HyperVLegacyWindowsRegistryValue -Scope $wmiReady.Scope `
            -SubKey 'SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -Name 'TimeZoneKeyName'
        $query = [Management.ObjectQuery]::new('SELECT OSLanguage FROM Win32_OperatingSystem')
        $osLanguage = [int]@([Management.ManagementObjectSearcher]::new($wmiReady.Scope, $query).Get())[0]['OSLanguage']
        if ([string]$guest.imageState -ne 'IMAGE_STATE_COMPLETE' -or $systemLocale -ne '0407' -or
            $inputLocale -ne '00000407' -or $osLanguage -ne 1033 -or $timeZone -ne 'W. Europe Standard Time') {
            throw 'HYPERV_SQL_OOBE_RECEIPT_INVALID'
        }
        $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
        $build | Add-Member -NotePropertyName oobeAutomation -NotePropertyValue ([PSCustomObject]@{
            status = 'COMPLETED'; region = 'DE'; systemLocale = 'de-DE'; uiLanguage = 'en-US'
            inputLocale = '0407:00000407'; timeZone = 'W. Europe Standard Time'
            passwordStorage = 'host-dpapi'; answerMedia = 'guest-scrubbed'; bootstrapVersion = $bootstrapVersion
            labAddress = $fallbackAddress; transport = 'legacy-wmi'; completedAt = Get-LabTimestamp
        }) -Force
        Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
        return Set-HyperVSqlImageBuildState -BuildId $BuildId -State OOBE_COMPLETED `
            -Reason 'Windows-OOBE, Region Deutschland, UI en-US und deutsche Logon-Tastatur per WMI verifiziert' -StateRoot $StateRoot
        }
        finally { Stop-LabBlockingActionProgress -Handle $blockingProgress }
    }

    Write-LabInfo "OOBE: pruefe Windows-Readiness per PowerShell Direct oder Lab-WinRM"
    try {
        $ready = Wait-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $build.buildId `
            -ExpectedScopeId $build.scopeId -Credential $credential -FallbackAddress $fallbackAddress `
            -GuestInitializationScript $bootstrap -TimeoutSeconds $TimeoutSeconds
    }
    finally { $bootstrap = $null }
    if (-not $ready.Ready) { throw "HYPERV_SQL_OOBE_TIMEOUT: $($ready.Message)" }
    $receiptScript = if ($legacyGuest) {{
            $ErrorActionPreference = 'Stop'
            $null = & reg.exe add 'HKU\.DEFAULT\Keyboard Layout\Preload' /v 1 /t REG_SZ /d 00000407 /f
            $null = & reg.exe add 'HKCU\Keyboard Layout\Preload' /v 1 /t REG_SZ /d 00000407 /f
            $null = & "$env:WINDIR\System32\tzutil.exe" /s 'W. Europe Standard Time'
            if ($LASTEXITCODE -ne 0) { throw "WINDOWS_TIME_ZONE_SET_FAILED: $LASTEXITCODE" }
            $language = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' -ErrorAction Stop
            $defaultInput = [string](Get-ItemProperty -LiteralPath 'Registry::HKEY_USERS\.DEFAULT\Keyboard Layout\Preload' -Name 1 -ErrorAction Stop).'1'
            $osLanguage = [int](Get-WmiObject Win32_OperatingSystem -ErrorAction Stop).OSLanguage
            Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend.xml" -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend\Unattend.xml" -Force -ErrorAction SilentlyContinue
            New-Object PSObject -Property @{
                contractVersion = '1'; imageState = [string](Get-ItemProperty `
                    -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState).ImageState
                systemLocale = if ([string]$language.Default -eq '0407') { 'de-DE' } else { [string]$language.Default }
                uiLanguage = if ($osLanguage -eq 1033) { 'en-US' } else { [string]$osLanguage }
                inputLocale = if ($defaultInput -eq '00000407') { '0407:00000407' } else { $defaultInput }
                timeZone = [string](& "$env:WINDIR\System32\tzutil.exe" /g)
                observedAt = [datetime]::UtcNow.ToString('o')
            }
        }} else {{
            $ErrorActionPreference = 'Stop'
            Set-WinHomeLocation -GeoId 94
            Set-WinSystemLocale -SystemLocale 'de-DE'
            Set-Culture -CultureInfo 'de-DE'
            Set-WinUILanguageOverride -Language 'en-US'
            Set-WinDefaultInputMethodOverride -InputTip '0407:00000407'
            $null = & "$env:WINDIR\System32\tzutil.exe" /s 'W. Europe Standard Time'
            if ($LASTEXITCODE -ne 0) { throw "WINDOWS_TIME_ZONE_SET_FAILED: $LASTEXITCODE" }
            Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend.xml" -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend\Unattend.xml" -Force -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                contractVersion = '1'; imageState = [string](Get-ItemProperty `
                    -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState).ImageState
                systemLocale = [string](Get-WinSystemLocale); uiLanguage = [string](Get-WinUILanguageOverride)
                inputLocale = [string](Get-WinDefaultInputMethodOverride).InputMethodTip
                timeZone = [string](& "$env:WINDIR\System32\tzutil.exe" /g)
                observedAt = [datetime]::UtcNow.ToString('o')
            }
        }}
    $receipt = Invoke-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $build.buildId `
        -ExpectedScopeId $build.scopeId -Credential $credential -FallbackAddress $fallbackAddress -ScriptBlock $receiptScript
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.contractVersion -ne '1' -or
        [string]$receipt.imageState -ne 'IMAGE_STATE_COMPLETE' -or [string]$receipt.systemLocale -ne 'de-DE' -or
        [string]$receipt.uiLanguage -ne 'en-US' -or [string]$receipt.inputLocale -ne '0407:00000407' -or
        [string]$receipt.timeZone -ne 'W. Europe Standard Time') { throw 'HYPERV_SQL_OOBE_RECEIPT_INVALID' }
    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    $build | Add-Member -NotePropertyName oobeAutomation -NotePropertyValue ([PSCustomObject]@{
        status = 'COMPLETED'; region = 'DE'; systemLocale = 'de-DE'; uiLanguage = 'en-US'
        inputLocale = '0407:00000407'; timeZone = 'W. Europe Standard Time'
        passwordStorage = 'host-dpapi'; answerMedia = 'guest-scrubbed'; bootstrapVersion = $bootstrapVersion
        labAddress = $fallbackAddress; transport = 'powershell-direct-or-lab-winrm'; completedAt = [string]$receipt.observedAt
    }) -Force
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Set-HyperVSqlImageBuildState -BuildId $BuildId -State OOBE_COMPLETED `
        -Reason 'Windows-OOBE, Region Deutschland, UI en-US und deutsche Tastatur verifiziert' -StateRoot $StateRoot
}

function Ensure-HyperVSqlBuildLabNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Build,
        [string]$StateRoot
    )

    $network = if ($Build.labNetwork) { $Build.labNetwork } else { Ensure-LabHyperVNetwork }
    $vmName = [string]$Build.builder.vmName
    $managed = Get-HyperVManagedVM -VMName $vmName -ExpectedRunId $Build.buildId -ExpectedScopeId $Build.scopeId
    if (-not $managed) { throw 'HYPERV_SQL_NETWORK_VM_NOT_FOUND' }

    $attached = @(
        Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop |
            Where-Object { [string]$_.SwitchName -eq [string]$network.Name }
    )
    if ($attached.Count -eq 0) {
        Add-VMNetworkAdapter -VMName $vmName -SwitchName $network.Name -Name 'SQL_LAB_HYPERV' -ErrorAction Stop | Out-Null
    }

    $Build | Add-Member -NotePropertyName labNetwork -NotePropertyValue $network -Force
    $Build.builder | Add-Member -NotePropertyName networkAttached -NotePropertyValue $true -Force
    Write-HyperVSqlImageBuildState -BuildDirectory $Build.BuildDirectory -State $Build
    return Get-HyperVSqlImageBuildPlan -BuildId $Build.buildId -StateRoot $StateRoot
}

function Get-HyperVSqlMajorVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SqlVersion)
    return Get-HyperVSqlMajorVersionFromVersion -SqlVersion $SqlVersion
}

function Get-HyperVSqlAcceptanceComputerName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SqlVersion)
    return ("SQLWIN$SqlVersion" -replace '[^A-Za-z0-9-]', '').Substring(0, [Math]::Min(15, ("SQLWIN$SqlVersion" -replace '[^A-Za-z0-9-]', '').Length))
}

function Invoke-HyperVLegacyGuestSystemScript {
    <# .SYNOPSIS Führt ein geheimnisfreies PowerShell-2-Skript als lokales SYSTEM aus und liest dessen CLIXML-Receipt. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$BuildId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9]{2,24}$')][string]$Action,
        [Parameter(Mandatory)][string]$ScriptContent,
        [ValidateRange(30, 10800)][int]$TimeoutSeconds = 600
    )

    $blockingProgress = Start-LabBlockingActionProgress -Phase GuestWait
    try {
    $scope = Connect-HyperVLegacyWindowsWmiScope -Address $Address -Namespace 'root\cimv2' -Credential $Credential
    $taskName = "SQL_Server_Lab_${Action}_$($BuildId.Replace('-', '').Substring(0, 8))"
    $guestRoot = "C:\ProgramData\SQL_Server_Lab\$BuildId\$Action"
    $guestScript = "$guestRoot\Run.ps1"
    $guestCommand = "$guestRoot\Run.cmd"
    $guestResult = "$guestRoot\result.csv"
    $driveName = 'SQLLAB' + (Get-Random -Minimum 1000 -Maximum 9999)
    $shareRoot = ('\' * 2) + "$Address\c$"
    $drive = $null
    try {
        $drive = New-PSDrive -Name $driveName -PSProvider FileSystem -Root $shareRoot -Credential $Credential -ErrorAction Stop
        $hostRoot = "${driveName}:\ProgramData\SQL_Server_Lab\$BuildId\$Action"
        New-Item -Path $hostRoot -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $hostRoot 'Run.ps1') -Value $ScriptContent -Encoding ascii
        $guestLog = "$guestRoot\runner.log"
        $commandContent = "@echo off`r`npowershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$guestScript`" > `"$guestLog`" 2>&1`r`nexit /b %errorlevel%`r`n"
        Set-Content -LiteralPath (Join-Path $hostRoot 'Run.cmd') -Value $commandContent -Encoding ascii
        Remove-Item -LiteralPath (Join-Path $hostRoot 'result.csv') -Force -ErrorAction SilentlyContinue

        $createCommand = "cmd.exe /c schtasks.exe /Create /TN $taskName /TR $guestCommand /SC ONSTART /RU SYSTEM /F"
        $null = Invoke-HyperVLegacyWindowsProcess -Scope $scope -CommandLine $createCommand
        Start-Sleep -Seconds 2
        $null = Invoke-HyperVLegacyWindowsProcess -Scope $scope -CommandLine "cmd.exe /c schtasks.exe /Run /TN $taskName"
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Seconds 2
            $resultPath = Join-Path $hostRoot 'result.csv'
        } while (-not (Test-Path -LiteralPath $resultPath -PathType Leaf) -and [datetime]::UtcNow -lt $deadline)
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "HYPERV_LEGACY_SYSTEM_TASK_TIMEOUT: $Action/$TimeoutSeconds"
        }
        $receipt = Import-Csv -LiteralPath $resultPath
        if (-not $receipt -or [string]$receipt.status -ne 'COMPLETED') {
            $errorCode = if ($receipt -and $receipt.errorCode) { [string]$receipt.errorCode } else { 'UNKNOWN' }
            throw "HYPERV_LEGACY_SYSTEM_TASK_FAILED: $Action/$errorCode"
        }
        return $receipt
    }
    finally {
        try { $null = Invoke-HyperVLegacyWindowsProcess -Scope $scope -CommandLine "cmd.exe /c schtasks.exe /Delete /TN $taskName /F" } catch { }
        if ($drive) { Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue }
    }
    }
    finally { Stop-LabBlockingActionProgress -Handle $blockingProgress }
}

function Invoke-HyperVLegacySqlSetup {
    <# .SYNOPSIS Installiert SQL 2008/2008 R2 in einem PowerShell-2-Gast. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][string]$FallbackAddress,
        [Parameter(Mandatory)][string]$Challenge,
        [Parameter(Mandatory)][string]$ExpectedSqlVersion,
        [Parameter(Mandatory)][string]$ExpectedSetupVersionPattern,
        [Parameter(Mandatory)][string]$FeaturesCsv,
        [Parameter(Mandatory)][string]$MediaEdition,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $resultPath = "C:\ProgramData\SQL_Server_Lab\$ExpectedRunId\SqlSetup\result.csv"
    $script = @'
$ErrorActionPreference = 'Stop'
$resultPath = '__RESULT_PATH__'
$receipt = New-Object PSObject -Property @{ status = 'FAILED'; errorCode = 'UNEXPECTED' }
try {
            $allSetup = @(Get-WmiObject Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object {
                $volumeRoot = [string]$_.DeviceID + '\'
                $candidate = Join-Path $volumeRoot 'setup.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
                @(Get-ChildItem -LiteralPath $volumeRoot -Filter 'SQLEXPR*_ENU.exe' -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.PSIsContainer })
            })
            $setup = @($allSetup | Where-Object {
                $candidateVersion = [string]$_.VersionInfo.ProductVersion
                if (-not $candidateVersion) { $candidateVersion = [string]$_.VersionInfo.FileVersion }
                $candidateVersion -match '__SETUP_PATTERN__'
            })
            if ($setup.Count -ne 1) { throw "SQL_SETUP_MEDIA_NOT_UNIQUE: passendeSQLSetups=$($setup.Count); gefunden=$($allSetup.Count)" }
            $setupVersion = [string]$setup[0].VersionInfo.ProductVersion
            if (-not $setupVersion) { $setupVersion = [string]$setup[0].VersionInfo.FileVersion }
            if ([string]::IsNullOrEmpty($setupVersion) -or $setupVersion -notmatch '__SETUP_PATTERN__') {
                throw "SQL_SETUP_VERSION_MISMATCH: erwartet __SQL_VERSION__, erkannt $setupVersion"
            }
            $expectedMajor = 10
            $features = @('__FEATURES__' -split ',' | Where-Object { $_ })
                $arguments = @(
                    '/Q', '/ACTION=Install', ("/FEATURES=" + ($features -join ',')),
                    '/INSTANCENAME=MSSQLSERVER', '/INSTANCEID=MSSQLSERVER',
                    '/SQLSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE"',
                    '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"', '/ADDCURRENTUSERASSQLADMIN=True',
                    '/TCPENABLED=0', '/INDICATEPROGRESS'
                )
                if ('__SQL_VERSION__' -ne '2008') {
                    $arguments += @('/ENU=True', '/IACCEPTSQLSERVERLICENSETERMS')
                }
                if ('__MEDIA_EDITION__' -ne 'Express') {
                    $arguments += @('/AGTSVCACCOUNT="NT AUTHORITY\NETWORK SERVICE"', '/AGTSVCSTARTUPTYPE=Automatic')
                }
                $process = Start-Process -FilePath ([string]$setup[0].FullName) -ArgumentList $arguments -PassThru -WindowStyle Hidden
                $completed = $process.WaitForExit(__TIMEOUT_SECONDS__ * 1000)
                if (-not $completed) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    throw 'SQL_SETUP_INSTALL_TIMEOUT'
                }
                $exitCode = [int]$process.ExitCode
                if ('__SQL_VERSION__' -eq '2008' -and $exitCode -eq 0) {
                    # Das SQL-2008-SFX beendet sich nach dem Entpacken, während
                    # setup.exe asynchron weiterläuft. Erst der Dienst ist die
                    # belastbare Installations-Postcondition.
                    Start-Sleep -Seconds 5
                    $setupDeadline = [datetime]::UtcNow.AddSeconds(__TIMEOUT_SECONDS__)
                    do {
                        $setupProcesses = @(Get-WmiObject Win32_Process | Where-Object {
                            @('setup.exe', 'setup100.exe', 'msiexec.exe') -contains $_.Name -and
                            ([string]$_.CommandLine -match '(?i)SQL Server|Setup Bootstrap|MSSQL')
                        })
                        if ($setupProcesses.Count -eq 0) { break }
                        Start-Sleep -Seconds 5
                    } while ([datetime]::UtcNow -lt $setupDeadline)
                    if ($setupProcesses.Count -gt 0) { throw 'SQL_SETUP_INSTALL_TIMEOUT' }
                    $sqlService = Get-WmiObject Win32_Service -Filter "Name='MSSQLSERVER'"
                    if (-not $sqlService) { $exitCode = -1 }
                }
                if (@(0, 3010) -notcontains $exitCode) {
                    $summary = @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'Microsoft SQL Server') `
                        -Filter 'Summary*.txt' -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { -not $_.PSIsContainer } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)[0]
                    $detail = 'Summary.txt nicht gefunden'
                    if ($summary) {
                        $lines = @(Get-Content -LiteralPath $summary.FullName -ErrorAction SilentlyContinue | Select-Object -Last 80)
                        $relevant = @($lines | Where-Object { $_ -match '(?i)error|failed|failure|exit code|result|exception|access is denied' } | Select-Object -Last 10)
                        if ($relevant.Count -eq 0) { $relevant = @($lines | Select-Object -Last 8) }
                        $detail = (($relevant -join ' ') -replace '\s+', ' ').Trim()
                        if ($detail.Length -gt 1200) { $detail = $detail.Substring(0, 1200) }
                    }
                    throw "SQL_SETUP_INSTALL_FAILED: ExitCode=$exitCode; $detail"
                }
                $receipt = New-Object PSObject -Property @{
                    status = 'COMPLETED'; contractVersion = '1'; buildId = '__BUILD_ID__'; scopeId = '__SCOPE_ID__'
                    challenge = '__CHALLENGE__'; action = 'Install'; sqlVersion = '__SQL_VERSION__'
                    expectedMajorVersion = $expectedMajor; setupVersion = $setupVersion
                    mediaEdition = '__MEDIA_EDITION__'; features = ($features -join ',')
                    netFx3Installed = $true; exitCode = $exitCode
                    rebootScheduled = ($exitCode -eq 3010); completedAt = [datetime]::UtcNow.ToString('o')
                }
}
catch {
    $message = (($_.Exception.Message -replace '\s+', ' ').Trim())
    if ($message.Length -gt 1200) { $message = $message.Substring(0, 1200) }
    $receipt = New-Object PSObject -Property @{ status = 'FAILED'; errorCode = $message }
}
finally {
    $temporaryPath = $resultPath + '.tmp'
    $receipt | Export-Csv -Path $temporaryPath -NoTypeInformation
    Move-Item -Path $temporaryPath -Destination $resultPath -Force
}
'@
    $script = $script.Replace('__RESULT_PATH__', $resultPath).Replace('__SETUP_PATTERN__', $ExpectedSetupVersionPattern).
        Replace('__SQL_VERSION__', $ExpectedSqlVersion).Replace('__FEATURES__', $FeaturesCsv).
        Replace('__MEDIA_EDITION__', $MediaEdition).Replace('__TIMEOUT_SECONDS__', [string]$TimeoutSeconds).
        Replace('__BUILD_ID__', $ExpectedRunId).Replace('__SCOPE_ID__', $ExpectedScopeId).Replace('__CHALLENGE__', $Challenge)
    return Invoke-HyperVLegacyGuestSystemScript -Address $FallbackAddress -Credential $Credential `
        -BuildId $ExpectedRunId -Action SqlSetup -ScriptContent $script -TimeoutSeconds ([Math]::Min(10800, $TimeoutSeconds + 60))
}

function Wait-HyperVLegacySqlReady {
    <# .SYNOPSIS Verifiziert SQL Server 2008/2008 R2 lokal im Gast mit Windows-Authentifizierung. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$BuildId,
        [Parameter(Mandatory)][ValidateRange(1, 99)][int]$ExpectedMajorVersion,
        [ValidateRange(30, 1800)][int]$TimeoutSeconds = 600
    )

    $resultPath = "C:\ProgramData\SQL_Server_Lab\$BuildId\SqlReady\result.csv"
    $script = @'
$ErrorActionPreference = 'Stop'
$resultPath = '__RESULT_PATH__'
$receipt = New-Object PSObject -Property @{ status = 'FAILED'; errorCode = 'UNEXPECTED' }
try {
    Add-Type -AssemblyName System.Data
    $deadline = [datetime]::UtcNow.AddSeconds(__TIMEOUT_SECONDS__)
    $lastError = 'SQL service not ready'
    $ready = $false
    do {
        try {
            $service = Get-WmiObject Win32_Service -Filter "Name='MSSQLSERVER'"
            if (-not $service -or [string]$service.State -ne 'Running') { throw 'MSSQLSERVER_NOT_RUNNING' }
            $connection = New-Object System.Data.SqlClient.SqlConnection 'Data Source=localhost;Initial Catalog=master;Integrated Security=SSPI;Connect Timeout=10'
            try {
                $connection.Open()
                $command = $connection.CreateCommand()
                $command.CommandTimeout = 15
                $command.CommandText = "SELECT CONVERT(varchar(128),SERVERPROPERTY('ProductVersion')),CONVERT(nvarchar(128),SERVERPROPERTY('Edition')),(SELECT COUNT(*) FROM sys.databases WHERE name IN ('master','model','msdb','tempdb'))"
                $reader = $command.ExecuteReader()
                if (-not $reader.Read()) { throw 'SQL_READINESS_QUERY_EMPTY' }
                $productVersion = [string]$reader.GetValue(0)
                $edition = [string]$reader.GetValue(1)
                $databaseCount = [int]$reader.GetValue(2)
                $reader.Close()
                $majorVersion = [int]($productVersion.Split('.')[0])
                if ($majorVersion -ne __EXPECTED_MAJOR__ -or $databaseCount -ne 4) { throw 'SQL_READINESS_POSTCONDITION_FAILED' }
                $ready = $true
            }
            finally { if ($connection) { $connection.Dispose() } }
        }
        catch { $lastError = $_.Exception.Message; Start-Sleep -Seconds 5 }
    } while (-not $ready -and [datetime]::UtcNow -lt $deadline)
    if (-not $ready) { throw "SQL_READINESS_TIMEOUT: $lastError" }
    $computerSystem = Get-WmiObject Win32_ComputerSystem
    $receipt = New-Object PSObject -Property @{
        status = 'COMPLETED'; contractVersion = '1'; buildId = '__BUILD_ID__'
        ready = $true; majorVersion = $majorVersion; productVersion = $productVersion
        edition = $edition; databaseCount = $databaseCount; computerName = [string]$computerSystem.Name
        observedAt = [datetime]::UtcNow.ToString('o')
    }
}
catch {
    $message = (($_.Exception.Message -replace '\s+', ' ').Trim())
    if ($message.Length -gt 1200) { $message = $message.Substring(0, 1200) }
    $receipt = New-Object PSObject -Property @{ status = 'FAILED'; errorCode = $message }
}
finally {
    $temporaryPath = $resultPath + '.tmp'
    $receipt | Export-Csv -Path $temporaryPath -NoTypeInformation
    Move-Item -Path $temporaryPath -Destination $resultPath -Force
}
'@
    $script = $script.Replace('__RESULT_PATH__', $resultPath).Replace('__TIMEOUT_SECONDS__', [string]$TimeoutSeconds).
        Replace('__EXPECTED_MAJOR__', [string]$ExpectedMajorVersion).Replace('__BUILD_ID__', $BuildId)
    return Invoke-HyperVLegacyGuestSystemScript -Address $Address -Credential $Credential -BuildId $BuildId `
        -Action SqlReady -ScriptContent $script -TimeoutSeconds ([Math]::Min(1800, $TimeoutSeconds + 30))
}

function Invoke-HyperVLegacySqlAcceptanceTest {
    <# .SYNOPSIS Führt den SQL-Abnahmetest lokal als SYSTEM mit integrierter Authentifizierung aus. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$BuildId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][ValidateRange(1, 99)][int]$ExpectedMajorVersion,
        [ValidateRange(30, 1800)][int]$TimeoutSeconds = 300
    )

    $resultPath = "C:\ProgramData\SQL_Server_Lab\$BuildId\SqlAcceptance\result.csv"
    $script = @'
$ErrorActionPreference = 'Stop'
$resultPath = '__RESULT_PATH__'
$receipt = New-Object PSObject -Property @{ status = 'FAILED'; errorCode = 'UNEXPECTED' }
$connection = $null; $command = $null; $databaseName = 'SQLLAB_ACCEPTANCE'; $backupPath = $null
try {
    Add-Type -AssemblyName System.Data
    $connection = New-Object System.Data.SqlClient.SqlConnection 'Data Source=localhost;Initial Catalog=master;Integrated Security=SSPI;Connect Timeout=15'
    $connection.Open()
    $command = $connection.CreateCommand(); $command.CommandTimeout = __TIMEOUT_SECONDS__
    $command.CommandText = "IF DB_ID(N'$databaseName') IS NOT NULL BEGIN ALTER DATABASE [$databaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$databaseName]; END; CREATE DATABASE [$databaseName];"
    $null = $command.ExecuteNonQuery()
    $connection.ChangeDatabase($databaseName)
    $command.CommandText = "SET NOCOUNT ON; CREATE TABLE dbo.Acceptance(Id int NOT NULL PRIMARY KEY, Value nvarchar(100) NOT NULL); INSERT dbo.Acceptance VALUES(1,N'SQL_Server_Lab'); SELECT COUNT(*) FROM dbo.Acceptance;"
    $rowCount = [int]$command.ExecuteScalar()
    $connection.ChangeDatabase('master')
    $instanceNames = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -Name MSSQLSERVER -ErrorAction Stop
    $instanceId = [string]$instanceNames.MSSQLSERVER
    $instanceSettings = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer" -Name BackupDirectory -ErrorAction Stop
    $backupRoot = [string]$instanceSettings.BackupDirectory
    if (-not $backupRoot -or -not (Test-Path -LiteralPath $backupRoot -PathType Container)) { throw 'SQL_ACCEPTANCE_BACKUP_DIRECTORY_NOT_FOUND' }
    $backupPath = Join-Path $backupRoot "$databaseName.bak"
    $escapedBackup = $backupPath.Replace("'", "''")
    $command.CommandText = "SET NOCOUNT ON; BACKUP DATABASE [$databaseName] TO DISK=N'$escapedBackup' WITH INIT,CHECKSUM; RESTORE VERIFYONLY FROM DISK=N'$escapedBackup' WITH CHECKSUM; SELECT CONVERT(int,PARSENAME(CONVERT(varchar(128),SERVERPROPERTY('ProductVersion')),4));"
    $observedMajor = [int]$command.ExecuteScalar()
    $command.CommandText = "ALTER DATABASE [$databaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$databaseName];"
    $null = $command.ExecuteNonQuery()
    Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
    if ($rowCount -ne 1 -or $observedMajor -ne __EXPECTED_MAJOR__) { throw 'SQL_ACCEPTANCE_POSTCONDITION_FAILED' }
    $receipt = New-Object PSObject -Property @{
        status = 'COMPLETED'; contractVersion = '1'; buildId = '__BUILD_ID__'; scopeId = '__SCOPE_ID__'
        sqlVersion = '__SQL_VERSION__'; majorVersion = $observedMajor; rowCount = $rowCount
        databaseCreate = $true; insertSelect = $true; backupChecksum = $true
        restoreVerifyOnly = $true; databaseDrop = $true; backupRemoved = $true
        observedAt = [datetime]::UtcNow.ToString('o')
    }
}
catch {
    try {
        if ($connection -and $connection.State -eq 'Open') {
            $connection.ChangeDatabase('master'); $cleanup = $connection.CreateCommand()
            $cleanup.CommandText = "IF DB_ID(N'$databaseName') IS NOT NULL BEGIN ALTER DATABASE [$databaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$databaseName]; END"
            $null = $cleanup.ExecuteNonQuery(); $cleanup.Dispose()
        }
        if ($backupPath -and (Test-Path -LiteralPath $backupPath)) { Remove-Item -LiteralPath $backupPath -Force }
    } catch { }
    $message = (($_.Exception.Message -replace '\s+', ' ').Trim())
    if ($message.Length -gt 1200) { $message = $message.Substring(0, 1200) }
    $receipt = New-Object PSObject -Property @{ status = 'FAILED'; errorCode = $message }
}
finally {
    if ($command) { $command.Dispose() }; if ($connection) { $connection.Dispose() }
    $temporaryPath = $resultPath + '.tmp'
    $receipt | Export-Csv -Path $temporaryPath -NoTypeInformation
    Move-Item -Path $temporaryPath -Destination $resultPath -Force
}
'@
    $script = $script.Replace('__RESULT_PATH__', $resultPath).Replace('__TIMEOUT_SECONDS__', [string]$TimeoutSeconds).
        Replace('__EXPECTED_MAJOR__', [string]$ExpectedMajorVersion).Replace('__BUILD_ID__', $BuildId).
        Replace('__SCOPE_ID__', $ScopeId).Replace('__SQL_VERSION__', $SqlVersion)
    return Invoke-HyperVLegacyGuestSystemScript -Address $Address -Credential $Credential -BuildId $BuildId `
        -Action SqlAcceptance -ScriptContent $script -TimeoutSeconds ([Math]::Min(1800, $TimeoutSeconds + 30))
}

function Invoke-HyperVSqlTestEnvironmentInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [SecureString]$SaPassword,
        [ValidateRange(60, 10800)][int]$SetupTimeoutSeconds = 7200,
        [ValidateRange(60, 3600)][int]$ReadinessTimeoutSeconds = 600,
        [string]$StateRoot
    )

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build -or $build.state -notin @(
        'MANUAL_ACTION_REQUIRED', 'OOBE_COMPLETED', 'SQL_INSTALL_RUNNING', 'SQL_INSTALL_REBOOT_REQUIRED', 'SQL_READY_RUN', 'TESTS_PASSED'
    )) { throw 'HYPERV_SQL_TEST_ENVIRONMENT_NOT_READY' }
    if ($build.state -in @('SQL_READY_RUN', 'TESTS_PASSED')) { return $build }
    $vmName = [string]$build.builder.vmName
    $fallbackAddress = if ($build.labNetwork) {
        Get-LabNetworkGuestAddress -Network $build.labNetwork -Identity $build.buildId
    }
    $managed = Get-HyperVManagedVM -VMName $vmName -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') {
        throw 'HYPERV_SQL_TEST_ENVIRONMENT_VM_MUST_BE_RUNNING'
    }

    if (-not $SaPassword) { $SaPassword = Get-LabSecret -Path $build.BuildDirectory -Name 'sa-password' }
    if (-not $SaPassword) { throw 'HYPERV_SQL_TEST_ENVIRONMENT_SA_PASSWORD_REQUIRED' }
    Save-LabSecret -Path $build.BuildDirectory -Name 'guest-administrator-password' -Secret $Credential.Password
    Save-LabSecret -Path $build.BuildDirectory -Name 'sa-password' -Secret $SaPassword
    $setupVersionPattern = Get-HyperVSqlSetupVersionPattern -SqlVersion $build.sql.version
    $legacyGuest = [string]$build.parentArtifact.platform.guestControl -eq 'legacy-wmi'
    $blockingProgress = if ($legacyGuest) { Start-LabBlockingActionProgress -Phase GuestWait }
    try {

    if ($build.state -in @('MANUAL_ACTION_REQUIRED', 'OOBE_COMPLETED')) {
        Write-LabInfo "SQL Setup: starte SQL Server $($build.sql.version) im Gast $vmName"
        $build = Set-HyperVSqlImageBuildState -BuildId $BuildId -State SQL_INSTALL_RUNNING `
            -Reason 'Vollstaendige SQL-Installation fuer run-lokale Windows-Abnahme gestartet' -StateRoot $StateRoot
        try {
            if ($legacyGuest) {
                $receipt = Invoke-HyperVLegacySqlSetup -VMName $vmName -ExpectedRunId $build.buildId `
                    -ExpectedScopeId $build.scopeId -Credential $Credential -FallbackAddress $fallbackAddress `
                    -Challenge $build.manualAction.challenge -ExpectedSqlVersion $build.sql.version `
                    -ExpectedSetupVersionPattern $setupVersionPattern -FeaturesCsv ($build.sql.features -join ',') `
                    -MediaEdition $build.sql.mediaEdition -TimeoutSeconds $SetupTimeoutSeconds
            }
            else {
                $receipt = Invoke-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $build.buildId `
                -ExpectedScopeId $build.scopeId -Credential $Credential -FallbackAddress $fallbackAddress `
                -ArgumentList @(
                    $build.buildId, $build.scopeId, $build.manualAction.challenge, $build.sql.version,
                    $setupVersionPattern, ($build.sql.features -join ','), $build.sql.mediaEdition,
                    $SaPassword, $Credential.Password, $SetupTimeoutSeconds
                ) `
                -ScriptBlock {
                    param($ExpectedBuildId, $ExpectedScopeId, $Challenge, $ExpectedSqlVersion, $ExpectedSetupVersionPattern, $FeaturesCsv, $MediaEdition, $SqlSaPassword, $AdministratorPassword, $TimeoutSeconds)
                    $ErrorActionPreference = 'Stop'
                    $allSetup = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object {
                        $volumeRoot = [string]$_.DeviceID + '\'
                        $candidate = Join-Path $volumeRoot 'setup.exe'
                        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
                        @(Get-ChildItem -LiteralPath $volumeRoot -File -Filter 'SQLEXPR*_ENU.exe' -ErrorAction SilentlyContinue)
                    })
                    $expectedMajor = if ($ExpectedSqlVersion -match '^major-(\d+)$') { [int]$Matches[1] } else { @{ '2012' = 11; '2014' = 12; '2016' = 13; '2017' = 14; '2019' = 15; '2022' = 16; '2025' = 17 }[$ExpectedSqlVersion] }
                    $setup = @($allSetup | Where-Object {
                        $candidateVersion = [string]$_.VersionInfo.ProductVersion
                        if (-not $candidateVersion) { $candidateVersion = [string]$_.VersionInfo.FileVersion }
                        $candidateVersion -match $ExpectedSetupVersionPattern
                    })
                    if ($setup.Count -ne 1) { throw "SQL_SETUP_MEDIA_NOT_UNIQUE: passendeSQLSetups=$($setup.Count); gefunden=$($allSetup.Count)" }
                    $setupVersion = [string]$setup[0].VersionInfo.ProductVersion
                    if (-not $setupVersion) { $setupVersion = [string]$setup[0].VersionInfo.FileVersion }
                    if ([string]::IsNullOrWhiteSpace($setupVersion) -or $setupVersion -notmatch $ExpectedSetupVersionPattern) {
                        throw "SQL_SETUP_VERSION_MISMATCH: erwartet $ExpectedSqlVersion, erkannt $setupVersion"
                    }
                    $netFx3Installed = $true
                    if ($expectedMajor -le 12) {
                        $feature = Get-WindowsFeature -Name NET-Framework-Core -ErrorAction Stop
                        if (-not $feature.Installed) {
                            $sources = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object {
                                $candidate = Join-Path ([string]$_.DeviceID + '\') 'sources\sxs'
                                if (Test-Path -LiteralPath $candidate -PathType Container) { $candidate }
                            })
                            if ($sources.Count -ne 1) { throw "SQL_SETUP_NETFX3_SOURCE_NOT_UNIQUE: $($sources.Count)" }
                            $featureResult = Install-WindowsFeature -Name NET-Framework-Core -Source $sources[0] -ErrorAction Stop
                            $netFx3Installed = [bool]$featureResult.Success -and [bool](Get-WindowsFeature -Name NET-Framework-Core).Installed
                            if (-not $netFx3Installed) { throw 'SQL_SETUP_NETFX3_INSTALL_FAILED' }
                        }
                    }
                    $features = @([string]$FeaturesCsv -split ',' | Where-Object { $_ })
                    $saBstr = [IntPtr]::Zero; $administratorBstr = [IntPtr]::Zero
                    $plainPassword = $null; $plainAdministratorPassword = $null
                    $saBytes = $null; $taskName = "SQL_Server_Lab_Setup_$($ExpectedBuildId.Replace('-', '').Substring(0, 12))"
                    $workRoot = Join-Path $env:ProgramData "SQL_Server_Lab\$ExpectedBuildId"
                    $runnerPath = Join-Path $workRoot 'Invoke-SqlSetup.ps1'
                    $configPath = Join-Path $workRoot 'setup.json'
                    $secretPath = Join-Path $workRoot 'sa-password.bin'
                    $resultPath = Join-Path $workRoot 'result.json'
                    try {
                        New-Item -Path $workRoot -ItemType Directory -Force | Out-Null
                        $saBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlSaPassword)
                        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($saBstr)
                        if ($plainPassword -match '[\s"]') { throw 'SQL_SA_PASSWORD_COMMAND_LINE_UNSAFE' }
                        Add-Type -AssemblyName System.Security -ErrorAction Stop
                        $saBytes = [Text.Encoding]::Unicode.GetBytes($plainPassword)
                        $entropy = [Text.Encoding]::UTF8.GetBytes($ExpectedBuildId)
                        $protected = [Security.Cryptography.ProtectedData]::Protect(
                            $saBytes, $entropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
                        [IO.File]::WriteAllBytes($secretPath, $protected)
                        $configuration = [pscustomobject]@{
                            setupPath = $setup[0].FullName; secretPath = $secretPath; resultPath = $resultPath
                            entropy = $ExpectedBuildId; features = @($features); expectedMajor = $expectedMajor
                            mediaEdition = [string]$MediaEdition; timeoutSeconds = [int]$TimeoutSeconds
                        }
                        $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList (,$false)
                        [IO.File]::WriteAllText($configPath, ($configuration | ConvertTo-Json -Depth 5), $utf8NoBom)
                        $runner = @'
param([Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference='Stop'
$config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8|ConvertFrom-Json
$plain=$null;$plainBytes=$null;$process=$null
try{
  Add-Type -AssemblyName System.Security -ErrorAction Stop
  $protected=[IO.File]::ReadAllBytes([string]$config.secretPath)
  $entropy=[Text.Encoding]::UTF8.GetBytes([string]$config.entropy)
  $plainBytes=[Security.Cryptography.ProtectedData]::Unprotect($protected,$entropy,[Security.Cryptography.DataProtectionScope]::LocalMachine)
  $plain=[Text.Encoding]::Unicode.GetString($plainBytes)
  $arguments=@('/Q','/ACTION=Install',("/FEATURES="+(@($config.features)-join ',')),'/INSTANCENAME=MSSQLSERVER','/INSTANCEID=MSSQLSERVER','/SQLSVCACCOUNT="NT Service\MSSQLSERVER"','/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"','/SECURITYMODE=SQL',("/SAPWD="+$plain),'/TCPENABLED=0','/ENU=True','/IACCEPTSQLSERVERLICENSETERMS','/INDICATEPROGRESS')
  if([string]$config.mediaEdition-ne 'Express'){$arguments+=@('/AGTSVCACCOUNT="NT Service\SQLSERVERAGENT"','/AGTSVCSTARTUPTYPE=Automatic')}
  if([int]$config.expectedMajor-ge 13){$arguments+='/SQLSVCINSTANTFILEINIT=True'}
  $process=Start-Process -FilePath ([string]$config.setupPath) -ArgumentList $arguments -PassThru -WindowStyle Hidden
  $completed=$process.WaitForExit([int]$config.timeoutSeconds*1000)
  if(-not $completed){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue;$receipt=[pscustomobject]@{status='TIMEOUT';exitCode=$null}}
  else{$code=$null;try{$code=[int]$process.ExitCode}catch{};$receipt=[pscustomobject]@{status='COMPLETED';exitCode=$code}}
}catch{$receipt=[pscustomobject]@{status='FAILED';exitCode=$null;errorType=$_.Exception.GetType().FullName}}
finally{
  $plain=$null
  if($plainBytes){[Array]::Clear($plainBytes,0,$plainBytes.Length)}
  $utf8NoBom=New-Object System.Text.UTF8Encoding -ArgumentList (,$false)
  [IO.File]::WriteAllText([string]$config.resultPath,($receipt|ConvertTo-Json -Compress),$utf8NoBom)
}
'@
                        [IO.File]::WriteAllText($runnerPath, $runner, $utf8NoBom)
                        $administratorBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdministratorPassword)
                        $plainAdministratorPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($administratorBstr)
                        $taskArguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runnerPath`" -ConfigPath `"$configPath`""
                        $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $taskArguments
                        Register-ScheduledTask -TaskName $taskName -Action $action -User 'Administrator' `
                            -Password $plainAdministratorPassword -RunLevel Highest -Force | Out-Null
                        Start-ScheduledTask -TaskName $taskName
                        $deadline = [datetime]::UtcNow.AddSeconds([int]$TimeoutSeconds + 60)
                        do { Start-Sleep -Seconds 2 } while (-not (Test-Path -LiteralPath $resultPath -PathType Leaf) -and [datetime]::UtcNow -lt $deadline)
                        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw "SQL_SETUP_INSTALL_TIMEOUT: $TimeoutSeconds" }
                        $runnerReceipt = Get-Content -LiteralPath $resultPath -Raw -Encoding utf8 | ConvertFrom-Json
                        if ([string]$runnerReceipt.status -eq 'TIMEOUT') { throw "SQL_SETUP_INSTALL_TIMEOUT: $TimeoutSeconds" }
                        if ([string]$runnerReceipt.status -ne 'COMPLETED') { throw "SQL_SETUP_SCHEDULED_RUNNER_FAILED: $($runnerReceipt.errorType)" }
                        $exitCode = $null
                        if ($null -ne $runnerReceipt.exitCode) { $exitCode = [int]$runnerReceipt.exitCode }
                        if ($exitCode -notin @(0, 3010)) {
                            $logRoot = Join-Path $env:ProgramFiles 'Microsoft SQL Server'
                            $summary = @(Get-ChildItem -LiteralPath $logRoot -Filter 'Summary.txt' -File -Recurse -ErrorAction SilentlyContinue |
                                Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)[0]
                            $detail = 'Summary.txt nicht gefunden'
                            if ($summary) {
                                $lines = @(Get-Content -LiteralPath $summary.FullName -Tail 80 -ErrorAction SilentlyContinue)
                                $relevant = @($lines | Where-Object { $_ -match '(?i)error|failed|failure|exit code|result|exception|access is denied' } | Select-Object -Last 10)
                                if ($relevant.Count -eq 0) { $relevant = @($lines | Select-Object -Last 8) }
                                $detail = (($relevant -join ' ') -replace '\s+', ' ').Trim()
                                $detail = $detail -replace '(?i)(/PID=|PID\s*[:=]\s*)[A-Z0-9-]+', '$1<redacted>'
                                if ($detail.Length -gt 1200) { $detail = $detail.Substring(0, 1200) }
                                $detail = "Summary=$($summary.FullName); Detail=$detail"
                            }
                            $reportedExitCode = if ($null -eq $exitCode) { 'unbekannt' } else { [string]$exitCode }
                            throw "SQL_SETUP_INSTALL_FAILED: ExitCode=$reportedExitCode; $detail"
                        }
                        if ($exitCode -eq 3010) { $null = & shutdown.exe /r /t 15 /f /d p:4:1 }
                        [PSCustomObject]@{
                            contractVersion = '1'; buildId = $ExpectedBuildId; scopeId = $ExpectedScopeId
                            challenge = $Challenge; action = 'Install'; sqlVersion = $ExpectedSqlVersion
                            expectedMajorVersion = $expectedMajor; setupVersion = $setupVersion
                            mediaEdition = [string]$MediaEdition; features = @($features)
                            netFx3Installed = $netFx3Installed; exitCode = [int]$exitCode
                            rebootScheduled = ($exitCode -eq 3010); completedAt = [datetime]::UtcNow.ToString('o')
                        }
                    }
                    finally {
                        $plainPassword = $null; $plainAdministratorPassword = $null
                        if ($saBytes) { [Array]::Clear($saBytes, 0, $saBytes.Length) }
                        if ($saBstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($saBstr) }
                        if ($administratorBstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($administratorBstr) }
                        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            $receipt = @($receipt)[-1]
            if (-not $receipt -or [string]$receipt.contractVersion -ne '1' -or
                [string]$receipt.buildId -ne [string]$build.buildId -or [string]$receipt.scopeId -ne [string]$build.scopeId -or
                [string]$receipt.challenge -ne [string]$build.manualAction.challenge -or [string]$receipt.action -ne 'Install' -or
                [string]$receipt.sqlVersion -ne [string]$build.sql.version -or
                [string]$receipt.mediaEdition -ne [string]$build.sql.mediaEdition -or
                [int]$receipt.expectedMajorVersion -ne (Get-HyperVSqlMajorVersion -SqlVersion $build.sql.version) -or
                [int]$receipt.exitCode -notin @(0, 3010)) { throw 'HYPERV_SQL_INSTALL_RECEIPT_INVALID' }
            $build | Add-Member -NotePropertyName installationEvidence -NotePropertyValue ([PSCustomObject]@{
                action = 'Install'; sqlVersion = [string]$receipt.sqlVersion
                expectedMajorVersion = [int]$receipt.expectedMajorVersion; setupVersion = [string]$receipt.setupVersion
                mediaEdition = [string]$receipt.mediaEdition
                features = @([string]$receipt.features -split ',' | Where-Object { $_ } | Sort-Object -Unique)
                exitCode = [int]$receipt.exitCode; completedAt = [string]$receipt.completedAt; acceptedAt = Get-LabTimestamp
            }) -Force
            Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
            if ([int]$receipt.exitCode -eq 3010) {
                return Set-HyperVSqlImageBuildState -BuildId $BuildId -State SQL_INSTALL_REBOOT_REQUIRED `
                    -Reason 'SQL-Installation erfolgreich; Setup-Neustart wird ausgefuehrt' -StateRoot $StateRoot
            }
        }
        catch {
            $failed = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
            $failed | Add-Member -NotePropertyName lastError -NotePropertyValue $_.Exception.Message -Force
            Write-HyperVSqlImageBuildState -BuildDirectory $failed.BuildDirectory -State $failed
            throw
        }
        $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    }

    if ($build.state -eq 'SQL_INSTALL_REBOOT_REQUIRED') {
        if ($legacyGuest) {
            $adapterName = [string]@(Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop |
                Where-Object { $_.IsLegacy } | Select-Object -First 1).Name
            $wmiReady = Wait-HyperVLegacyWindowsWmi -VMName $vmName -AdapterName $adapterName `
                -Credential $Credential -TimeoutSeconds $ReadinessTimeoutSeconds
            if (-not $wmiReady.Ready) { throw "HYPERV_SQL_INSTALL_RECONNECT_TIMEOUT: $($wmiReady.LastError)" }
        }
        else {
            $ready = Wait-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $build.buildId `
                -ExpectedScopeId $build.scopeId -Credential $Credential -FallbackAddress $fallbackAddress `
                -TimeoutSeconds $ReadinessTimeoutSeconds
            if (-not $ready.Ready) { throw "HYPERV_SQL_INSTALL_RECONNECT_TIMEOUT: $($ready.Message)" }
        }
    }
    elseif ($build.state -eq 'SQL_INSTALL_RUNNING' -and -not $build.installationEvidence) {
        if (-not $legacyGuest) { throw 'HYPERV_SQL_INSTALL_RECOVERY_REQUIRES_LOG_REVIEW' }
        Write-LabInfo 'SQL Setup: verifiziere bereits beendeten Legacy-Setup-Lauf vor der Wiederaufnahme.'
        $recovered = Wait-HyperVLegacySqlReady -Address $fallbackAddress -Credential $Credential `
            -BuildId $build.buildId -ExpectedMajorVersion (Get-HyperVSqlMajorVersion -SqlVersion $build.sql.version) `
            -TimeoutSeconds $ReadinessTimeoutSeconds
        if (-not $recovered.ready -or [int]$recovered.databaseCount -ne 4) {
            throw 'HYPERV_SQL_INSTALL_RECOVERY_REQUIRES_LOG_REVIEW'
        }
        $build | Add-Member -NotePropertyName installationEvidence -NotePropertyValue ([PSCustomObject]@{
            action = 'InstallRecovered'; sqlVersion = [string]$build.sql.version
            expectedMajorVersion = [int]$recovered.majorVersion; setupVersion = [string]$recovered.productVersion
            mediaEdition = [string]$build.sql.mediaEdition; features = @($build.sql.features)
            exitCode = 0; completedAt = [string]$recovered.observedAt; acceptedAt = Get-LabTimestamp
        }) -Force
        Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    }

    $computerName = Get-HyperVSqlAcceptanceComputerName -SqlVersion $build.sql.version
    if ($legacyGuest) {
        $scope = Connect-HyperVLegacyWindowsWmiScope -Address $fallbackAddress -Namespace 'root\cimv2' -Credential $Credential
        $computerName = [string]@([Management.ManagementObjectSearcher]::new(
            $scope, [Management.ObjectQuery]::new('SELECT Name FROM Win32_ComputerSystem')).Get())[0]['Name']
    }
    else {
        Write-LabInfo "SQL Setup: spezialisiere Windows-Gast als $computerName"
        $null = Set-HyperVWindowsGuestSpecialization -VMName $vmName -ExpectedRunId $build.buildId `
            -ExpectedScopeId $build.scopeId -Credential $Credential -ComputerName $computerName `
            -FallbackAddress $fallbackAddress `
            -TimeoutSeconds $ReadinessTimeoutSeconds
    }
    $labNetworkReceipt = $null
    if ($build.labNetwork) {
        if ($legacyGuest) {
            Write-LabInfo "Netzwerk: verifiziere Legacy-Gastadresse im Netz $($build.labNetwork.Name)"
            $scope = Connect-HyperVLegacyWindowsWmiScope -Address $fallbackAddress -Namespace 'root\cimv2' -Credential $Credential
            $networkQuery = [Management.ObjectQuery]::new("SELECT IPAddress FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled=True")
            $networkAdapters = @([Management.ManagementObjectSearcher]::new($scope, $networkQuery).Get())
            if (-not @($networkAdapters | Where-Object { @($_['IPAddress']) -contains $fallbackAddress })) {
                throw 'SQL_LAB_LEGACY_NETWORK_POSTCONDITION_FAILED'
            }
            $labNetworkReceipt = [PSCustomObject]@{
                Network = [string]$build.labNetwork.Name; Address = $fallbackAddress
                PrefixLength = [int]$build.labNetwork.PrefixLength; ObservedAt = Get-LabTimestamp
            }
        }
        else {
            Write-LabInfo "Netzwerk: konfiguriere Gastadresse im Netz $($build.labNetwork.Name)"
            $labNetworkReceipt = Initialize-HyperVGuestLabNetwork -VMName $vmName `
                -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId -Credential $Credential `
                -Network $build.labNetwork -Identity $build.buildId -FallbackAddress $fallbackAddress
        }
    }
    $readiness = if ($legacyGuest) {
        Wait-HyperVLegacySqlReady -Address $fallbackAddress -Credential $Credential -BuildId $build.buildId `
            -ExpectedMajorVersion (Get-HyperVSqlMajorVersion -SqlVersion $build.sql.version) `
            -TimeoutSeconds $ReadinessTimeoutSeconds
    }
    else {
        Wait-HyperVGuestSqlReady -VMName $vmName -ExpectedRunId $build.buildId `
            -ExpectedScopeId $build.scopeId -Credential $Credential -SaPassword $SaPassword `
            -FallbackAddress $fallbackAddress `
            -ExpectedMajorVersion (Get-HyperVSqlMajorVersion -SqlVersion $build.sql.version) `
            -TimeoutSeconds $ReadinessTimeoutSeconds
    }
    if (-not $readiness.Ready) { throw 'HYPERV_SQL_TEST_ENVIRONMENT_READINESS_FAILED' }

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    $build | Add-Member -NotePropertyName testEnvironment -NotePropertyValue ([PSCustomObject]@{
        status = 'SQL_READY_RUN'; computerName = if ($readiness.computerName) { [string]$readiness.computerName } else { $computerName }; instanceName = 'MSSQLSERVER'
        sqlVersion = [string]$build.sql.version; majorVersion = [int]$readiness.MajorVersion
        productVersion = [string]$readiness.ProductVersion; edition = [string]$readiness.Edition
        readyAt = [string]$readiness.ObservedAt; networkAttached = ($null -ne $labNetworkReceipt)
        network = if ($labNetworkReceipt) { $labNetworkReceipt.Network } else { $null }
        address = if ($labNetworkReceipt) { $labNetworkReceipt.Address } else { $null }
    }) -Force
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Set-HyperVSqlImageBuildState -BuildId $BuildId -State SQL_READY_RUN `
        -Reason 'Windows spezialisiert und SQL-Dienst, Version sowie Systemdatenbanken verifiziert' -StateRoot $StateRoot
    }
    finally { if ($blockingProgress) { Stop-LabBlockingActionProgress -Handle $blockingProgress } }
}

function Test-HyperVSqlAcceptanceEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [SecureString]$SaPassword,
        [ValidateRange(30, 1800)][int]$TimeoutSeconds = 300,
        [string]$StateRoot
    )

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build -or $build.state -notin @('SQL_READY_RUN', 'TESTS_PASSED')) {
        throw 'HYPERV_SQL_ACCEPTANCE_ENVIRONMENT_NOT_READY'
    }
    $legacyGuest = [string]$build.parentArtifact.platform.guestControl -eq 'legacy-wmi'
    if (-not $legacyGuest) {
        if (-not $SaPassword) { $SaPassword = Get-LabSecret -Path $build.BuildDirectory -Name 'sa-password' }
        if (-not $SaPassword) { throw 'HYPERV_SQL_ACCEPTANCE_SA_PASSWORD_REQUIRED' }
    }
    $expectedMajor = Get-HyperVSqlMajorVersion -SqlVersion $build.sql.version
    $fallbackAddress = if ($build.labNetwork) {
        Get-LabNetworkGuestAddress -Network $build.labNetwork -Identity $build.buildId
    }
    $receipt = if ($legacyGuest) {
        Invoke-HyperVLegacySqlAcceptanceTest -Address $fallbackAddress -Credential $Credential `
            -BuildId $build.buildId -ScopeId $build.scopeId -SqlVersion $build.sql.version `
            -ExpectedMajorVersion $expectedMajor -TimeoutSeconds $TimeoutSeconds
    }
    else { Invoke-HyperVPowerShellDirect -VMName $build.builder.vmName -ExpectedRunId $build.buildId `
        -ExpectedScopeId $build.scopeId -Credential $Credential -FallbackAddress $fallbackAddress `
        -ArgumentList @($build.buildId, $build.scopeId, $build.sql.version, $expectedMajor, $SaPassword, $TimeoutSeconds) `
        -ScriptBlock {
            param($ExpectedBuildId, $ExpectedScopeId, $ExpectedSqlVersion, $ExpectedMajor, $SqlSaPassword, $Timeout)
            $ErrorActionPreference = 'Stop'
            Add-Type -AssemblyName System.Data
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlSaPassword)
            $plainPassword = $null; $connection = $null; $command = $null
            $databaseName = 'SQLLAB_ACCEPTANCE'
            try {
                $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
                $builder['Data Source'] = 'localhost'; $builder['Initial Catalog'] = 'master'; $builder['User ID'] = 'sa'
                $builder['Password'] = $plainPassword; $builder['Encrypt'] = $true; $builder['TrustServerCertificate'] = $true
                $builder['Connect Timeout'] = [Math]::Min(15, [int]$Timeout)
                $connection = New-Object System.Data.SqlClient.SqlConnection -ArgumentList (,$builder.ConnectionString); $connection.Open()
                $command = $connection.CreateCommand(); $command.CommandTimeout = [int]$Timeout
                $command.CommandText = @"
IF DB_ID(N'$databaseName') IS NOT NULL BEGIN
  ALTER DATABASE [$databaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
  DROP DATABASE [$databaseName];
END;
CREATE DATABASE [$databaseName];
"@
                $null = $command.ExecuteNonQuery()
                $connection.ChangeDatabase($databaseName)
                $command.CommandText = 'SET NOCOUNT ON; CREATE TABLE dbo.Acceptance(Id int NOT NULL PRIMARY KEY, Value nvarchar(100) NOT NULL); INSERT dbo.Acceptance VALUES(1,N''SQL_Server_Lab''); SELECT COUNT(*) FROM dbo.Acceptance;'
                $rowCount = [int]$command.ExecuteScalar()
                $connection.ChangeDatabase('master')
                $command.CommandText = "SELECT CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(4000));"
                $backupRoot = [string]$command.ExecuteScalar()
                if (-not $backupRoot) {
                    $instanceNames = Get-ItemProperty `
                        -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' `
                        -Name MSSQLSERVER -ErrorAction Stop
                    $instanceId = [string]$instanceNames.MSSQLSERVER
                    $instanceSettings = Get-ItemProperty `
                        -LiteralPath "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer" `
                        -Name BackupDirectory -ErrorAction Stop
                    $backupRoot = [string]$instanceSettings.BackupDirectory
                }
                if (-not $backupRoot -or -not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
                    throw 'SQL_ACCEPTANCE_BACKUP_DIRECTORY_NOT_FOUND'
                }
                $backupPath = Join-Path $backupRoot "$databaseName.bak"
                $escapedBackup = $backupPath.Replace("'", "''")
                $command.CommandText = "SET NOCOUNT ON; BACKUP DATABASE [$databaseName] TO DISK=N'$escapedBackup' WITH INIT,CHECKSUM; RESTORE VERIFYONLY FROM DISK=N'$escapedBackup' WITH CHECKSUM; SELECT CONVERT(int,PARSENAME(CONVERT(varchar(128),SERVERPROPERTY('ProductVersion')),4));"
                $observedMajor = [int]$command.ExecuteScalar()
                $command.CommandText = "ALTER DATABASE [$databaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$databaseName];"
                $null = $command.ExecuteNonQuery()
                Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop
                if ($rowCount -ne 1 -or $observedMajor -ne [int]$ExpectedMajor) { throw 'SQL_ACCEPTANCE_POSTCONDITION_FAILED' }
                [PSCustomObject]@{
                    contractVersion = '1'; buildId = $ExpectedBuildId; scopeId = $ExpectedScopeId
                    sqlVersion = $ExpectedSqlVersion; majorVersion = $observedMajor; rowCount = $rowCount
                    databaseCreate = $true; insertSelect = $true; backupChecksum = $true
                    restoreVerifyOnly = $true; databaseDrop = $true; backupRemoved = $true
                    observedAt = [datetime]::UtcNow.ToString('o')
                }
            }
            finally {
                if ($command) { $command.Dispose() }; if ($connection) { $connection.Dispose() }
                $plainPassword = $null; [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        } }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.contractVersion -ne '1' -or
        [string]$receipt.buildId -ne [string]$build.buildId -or [string]$receipt.scopeId -ne [string]$build.scopeId -or
        [int]$receipt.majorVersion -ne $expectedMajor -or [int]$receipt.rowCount -ne 1 -or
        $receipt.databaseCreate -ne $true -or $receipt.backupChecksum -ne $true -or
        $receipt.restoreVerifyOnly -ne $true -or $receipt.databaseDrop -ne $true -or $receipt.backupRemoved -ne $true) {
        throw 'HYPERV_SQL_ACCEPTANCE_RECEIPT_INVALID'
    }
    $build | Add-Member -NotePropertyName acceptanceEvidence -NotePropertyValue ([PSCustomObject]@{
        sqlVersion = [string]$receipt.sqlVersion; majorVersion = [int]$receipt.majorVersion
        rowCount = [int]$receipt.rowCount; databaseCreate = $true; insertSelect = $true
        backupChecksum = $true; restoreVerifyOnly = $true; databaseDrop = $true; backupRemoved = $true
        observedAt = [string]$receipt.observedAt; acceptedAt = Get-LabTimestamp
    }) -Force
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Set-HyperVSqlImageBuildState -BuildId $BuildId -State TESTS_PASSED `
        -Reason 'SQL-Major-Version sowie Create/Insert/Backup/Verify/Drop-Abnahmetest erfolgreich' -StateRoot $StateRoot
}

function Get-HyperVSqlAcceptanceMatrix {
    [CmdletBinding()]
    param([string]$StateRoot)
    return @(
        Get-HyperVSqlImageBuildPlans -StateRoot $StateRoot |
            Where-Object { $_.sql.version -in @('2008', '2008R2', '2012', '2014', '2016', '2017', '2019', '2022', '2025') } |
            Sort-Object { if ([string]$_.sql.version -eq '2008R2') { [decimal]2008.5 } else { [decimal]$_.sql.version } } |
            ForEach-Object {
                [PSCustomObject]@{
                    BuildId = [string]$_.buildId; SqlVersion = [string]$_.sql.version
                    Edition = [string]$_.testEnvironment.edition; ProductVersion = [string]$_.testEnvironment.productVersion
                    VMName = [string]$_.builder.vmName; ComputerName = [string]$_.testEnvironment.computerName
                    State = [string]$_.state; Ready = $_.state -in @('SQL_READY_RUN', 'TESTS_PASSED')
                    TestsPassed = $_.state -eq 'TESTS_PASSED'; NetworkAttached = [bool]$_.testEnvironment.networkAttached
                    AcceptanceAt = [string]$_.acceptanceEvidence.acceptedAt
                }
            }
    )
}
