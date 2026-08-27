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
        [Parameter(Mandatory)][string]$Address
    )

    $prefixLength = [int]$Network.PrefixLength
    $hostAddress = [string]$Network.HostAddress
    return @"
`$ErrorActionPreference = 'Stop'
`$adapter = @(Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1)[0]
if (-not `$adapter) { throw 'SQL_LAB_OOBE_NETWORK_ADAPTER_NOT_FOUND' }
`$existing = @(Get-NetIPAddress -InterfaceIndex `$adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { `$_.IPAddress -notlike '169.254.*' -and `$_.IPAddress -ne '127.0.0.1' })
if (-not @(`$existing | Where-Object { `$_.IPAddress -eq '$Address' -and `$_.PrefixLength -eq $prefixLength })) {
    `$existing | Remove-NetIPAddress -Confirm:`$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex `$adapter.ifIndex -IPAddress '$Address' -PrefixLength $prefixLength -ErrorAction Stop | Out-Null
}
Set-NetConnectionProfile -InterfaceIndex `$adapter.ifIndex -NetworkCategory Private -ErrorAction SilentlyContinue
Set-Service -Name WinRM -StartupType Automatic -ErrorAction Stop
Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
`$ruleName = 'SQL_Server_Lab WinRM Host'
if (-not (Get-NetFirewallRule -DisplayName `$ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName `$ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 -RemoteAddress '$hostAddress' | Out-Null
}
`$receiptDirectory = Join-Path `$env:ProgramData 'SqlServerLab'
New-Item -Path `$receiptDirectory -ItemType Directory -Force | Out-Null
[PSCustomObject]@{ contractVersion = '1'; network = '$($Network.Name)'; address = '$Address'; prefixLength = $prefixLength; hostAddress = '$hostAddress'; observedAt = [datetime]::UtcNow.ToString('o') } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path `$receiptDirectory 'oobe-network.json') -Encoding UTF8
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

    $fallbackAddress = if ($build.labNetwork) {
        Get-LabNetworkGuestAddress -Network $build.labNetwork -Identity $build.buildId
    }
    $requiresBootstrapInjection = $build.state -eq 'MANUAL_ACTION_REQUIRED' -or
        [string]$build.oobeAutomation.bootstrapVersion -ne 'network-winrm-v1'
    if ($requiresBootstrapInjection) {
        Write-LabInfo "OOBE: stoppe $vmName und injiziere Unattend.xml mit Labnetz-Bootstrap"
        $null = Stop-HyperVInstance -VMName $vmName -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
        $vhdxPath = Join-Path $build.BuildDirectory ([string]$build.builder.osDiskRelativePath)
        $unattend = New-HyperVSqlOobeUnattendXml -AdministratorPassword $AdministratorPassword `
            -Network $build.labNetwork -Identity $build.buildId
        $bootstrap = New-HyperVSqlGuestNetworkBootstrapScript -Network $build.labNetwork -Address $fallbackAddress
        try {
            Set-HyperVSqlOfflineUnattend -VhdxPath $vhdxPath `
                -MountRoot (Join-Path $build.BuildDirectory 'offline-mount') -UnattendXml $unattend -BootstrapScript $bootstrap
        }
        finally { $unattend = $null }
        $build | Add-Member -NotePropertyName oobeAutomation -NotePropertyValue ([PSCustomObject]@{
            status = 'RUNNING'; region = 'DE'; systemLocale = 'de-DE'; uiLanguage = 'en-US'
            inputLocale = '0407:00000407'; timeZone = 'W. Europe Standard Time'
            passwordStorage = 'host-dpapi'; answerMedia = 'offline-vhdx'; bootstrapVersion = 'network-winrm-v1'
            labAddress = $fallbackAddress; startedAt = Get-LabTimestamp
        }) -Force
        Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
        $build = Set-HyperVSqlImageBuildState -BuildId $BuildId -State OOBE_AUTOMATION_RUNNING `
            -Reason 'Unattend.xml offline injiziert; Windows-OOBE wird unbeaufsichtigt abgeschlossen' -StateRoot $StateRoot
        Write-LabInfo "OOBE: starte $vmName und warte maximal $TimeoutSeconds Sekunden auf PowerShell Direct oder Lab-WinRM ($fallbackAddress)"
        $null = Start-HyperVInstance -VMName $vmName -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
    }

    Write-LabInfo "OOBE: pruefe Windows-Readiness per PowerShell Direct oder Lab-WinRM"
    try {
        $ready = Wait-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $build.buildId `
            -ExpectedScopeId $build.scopeId -Credential $credential -FallbackAddress $fallbackAddress `
            -GuestInitializationScript $bootstrap -TimeoutSeconds $TimeoutSeconds
    }
    finally { $bootstrap = $null }
    if (-not $ready.Ready) { throw "HYPERV_SQL_OOBE_TIMEOUT: $($ready.Message)" }
    $receipt = Invoke-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $build.buildId `
        -ExpectedScopeId $build.scopeId -Credential $credential -FallbackAddress $fallbackAddress -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            Set-WinHomeLocation -GeoId 94
            Set-WinSystemLocale -SystemLocale 'de-DE'
            Set-Culture -CultureInfo 'de-DE'
            Set-WinUILanguageOverride -Language 'en-US'
            Set-WinDefaultInputMethodOverride -InputTip '0407:00000407'
            Set-TimeZone -Id 'W. Europe Standard Time'
            Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend.xml" -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$env:WINDIR\Panther\Unattend\Unattend.xml" -Force -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                contractVersion = '1'; imageState = [string](Get-ItemPropertyValue `
                    -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState)
                systemLocale = [string](Get-WinSystemLocale); uiLanguage = [string](Get-WinUILanguageOverride)
                inputLocale = [string](Get-WinDefaultInputMethodOverride); timeZone = [string](Get-TimeZone).Id
                observedAt = [datetime]::UtcNow.ToString('o')
            }
        }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.contractVersion -ne '1' -or
        [string]$receipt.imageState -ne 'IMAGE_STATE_COMPLETE' -or [string]$receipt.systemLocale -ne 'de-DE' -or
        [string]$receipt.uiLanguage -ne 'en-US' -or [string]$receipt.inputLocale -ne '0407:00000407' -or
        [string]$receipt.timeZone -ne 'W. Europe Standard Time') { throw 'HYPERV_SQL_OOBE_RECEIPT_INVALID' }
    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    $build | Add-Member -NotePropertyName oobeAutomation -NotePropertyValue ([PSCustomObject]@{
        status = 'COMPLETED'; region = 'DE'; systemLocale = 'de-DE'; uiLanguage = 'en-US'
        inputLocale = '0407:00000407'; timeZone = 'W. Europe Standard Time'
        passwordStorage = 'host-dpapi'; answerMedia = 'guest-scrubbed'; bootstrapVersion = 'network-winrm-v1'
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

    if ($build.state -in @('MANUAL_ACTION_REQUIRED', 'OOBE_COMPLETED')) {
        Write-LabInfo "SQL Setup: starte SQL Server $($build.sql.version) im Gast $vmName"
        $build = Set-HyperVSqlImageBuildState -BuildId $BuildId -State SQL_INSTALL_RUNNING `
            -Reason 'Vollstaendige SQL-Installation fuer run-lokale Windows-Abnahme gestartet' -StateRoot $StateRoot
        try {
            $receipt = Invoke-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $build.buildId `
                -ExpectedScopeId $build.scopeId -Credential $Credential -FallbackAddress $fallbackAddress `
                -ArgumentList @(
                    $build.buildId, $build.scopeId, $build.manualAction.challenge, $build.sql.version,
                    $setupVersionPattern, ($build.sql.features -join ','), $SaPassword, $SetupTimeoutSeconds
                ) `
                -ScriptBlock {
                    param($ExpectedBuildId, $ExpectedScopeId, $Challenge, $ExpectedSqlVersion, $ExpectedSetupVersionPattern, $FeaturesCsv, $SqlSaPassword, $TimeoutSeconds)
                    $ErrorActionPreference = 'Stop'
                    $setup = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object {
                        $candidate = Join-Path ([string]$_.DeviceID + '\') 'setup.exe'
                        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
                    })
                    if ($setup.Count -ne 1) { throw "SQL_SETUP_MEDIA_NOT_UNIQUE: $($setup.Count)" }
                    $expectedMajor = if ($ExpectedSqlVersion -match '^major-(\d+)$') { [int]$Matches[1] } else { @{ '2012' = 11; '2014' = 12; '2016' = 13; '2017' = 14; '2019' = 15; '2022' = 16; '2025' = 17 }[$ExpectedSqlVersion] }
                    $setupVersion = [string]$setup[0].VersionInfo.ProductVersion
                    if (-not $setupVersion) { $setupVersion = [string]$setup[0].VersionInfo.FileVersion }
                    if ([string]::IsNullOrWhiteSpace($setupVersion) -or $setupVersion -notmatch $ExpectedSetupVersionPattern) {
                        throw "SQL_SETUP_VERSION_MISMATCH: erwartet $ExpectedSqlVersion, erkannt $setupVersion"
                    }
                    $features = @([string]$FeaturesCsv -split ',' | Where-Object { $_ })
                    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlSaPassword)
                    $plainPassword = $null
                    try {
                        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                        if ($plainPassword -match '[\s"]') { throw 'SQL_SA_PASSWORD_COMMAND_LINE_UNSAFE' }
                        $arguments = @(
                            '/Q', '/ACTION=Install', "/FEATURES=$($features -join ',')",
                            '/INSTANCENAME=MSSQLSERVER', '/INSTANCEID=MSSQLSERVER',
                            '/SQLSVCACCOUNT="NT Service\MSSQLSERVER"',
                            '/AGTSVCACCOUNT="NT Service\SQLSERVERAGENT"', '/AGTSVCSTARTUPTYPE=Automatic',
                            '/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"', '/SECURITYMODE=SQL',
                            "/SAPWD=$plainPassword", '/TCPENABLED=0', '/SQLSVCINSTANTFILEINIT=True',
                            '/ENU=True', '/IACCEPTSQLSERVERLICENSETERMS', '/INDICATEPROGRESS'
                        )
                        $process = Start-Process -FilePath $setup[0].FullName -ArgumentList $arguments -PassThru -NoNewWindow
                        if (-not $process.WaitForExit([int]$TimeoutSeconds * 1000)) {
                            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                            throw "SQL_SETUP_INSTALL_TIMEOUT: $TimeoutSeconds"
                        }
                        if ($process.ExitCode -notin @(0, 3010)) { throw "SQL_SETUP_INSTALL_FAILED: $($process.ExitCode)" }
                        if ($process.ExitCode -eq 3010) { $null = & shutdown.exe /r /t 15 /f /d p:4:1 }
                        [PSCustomObject]@{
                            contractVersion = '1'; buildId = $ExpectedBuildId; scopeId = $ExpectedScopeId
                            challenge = $Challenge; action = 'Install'; sqlVersion = $ExpectedSqlVersion
                            expectedMajorVersion = $expectedMajor; setupVersion = $setupVersion
                            features = @($features); exitCode = [int]$process.ExitCode
                            rebootScheduled = ($process.ExitCode -eq 3010); completedAt = [datetime]::UtcNow.ToString('o')
                        }
                    }
                    finally {
                        $plainPassword = $null
                        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                    }
                }
            $receipt = @($receipt)[-1]
            if (-not $receipt -or [string]$receipt.contractVersion -ne '1' -or
                [string]$receipt.buildId -ne [string]$build.buildId -or [string]$receipt.scopeId -ne [string]$build.scopeId -or
                [string]$receipt.challenge -ne [string]$build.manualAction.challenge -or [string]$receipt.action -ne 'Install' -or
                [string]$receipt.sqlVersion -ne [string]$build.sql.version -or
                [int]$receipt.expectedMajorVersion -ne (Get-HyperVSqlMajorVersion -SqlVersion $build.sql.version) -or
                [int]$receipt.exitCode -notin @(0, 3010)) { throw 'HYPERV_SQL_INSTALL_RECEIPT_INVALID' }
            $build | Add-Member -NotePropertyName installationEvidence -NotePropertyValue ([PSCustomObject]@{
                action = 'Install'; sqlVersion = [string]$receipt.sqlVersion
                expectedMajorVersion = [int]$receipt.expectedMajorVersion; setupVersion = [string]$receipt.setupVersion
                features = @($receipt.features | ForEach-Object { [string]$_ } | Sort-Object -Unique)
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
        $ready = Wait-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $build.buildId `
            -ExpectedScopeId $build.scopeId -Credential $Credential -FallbackAddress $fallbackAddress `
            -TimeoutSeconds $ReadinessTimeoutSeconds
        if (-not $ready.Ready) { throw "HYPERV_SQL_INSTALL_RECONNECT_TIMEOUT: $($ready.Message)" }
    }
    elseif ($build.state -eq 'SQL_INSTALL_RUNNING' -and -not $build.installationEvidence) {
        throw 'HYPERV_SQL_INSTALL_RECOVERY_REQUIRES_LOG_REVIEW'
    }

    $computerName = Get-HyperVSqlAcceptanceComputerName -SqlVersion $build.sql.version
    Write-LabInfo "SQL Setup: spezialisiere Windows-Gast als $computerName"
    $null = Set-HyperVWindowsGuestSpecialization -VMName $vmName -ExpectedRunId $build.buildId `
        -ExpectedScopeId $build.scopeId -Credential $Credential -ComputerName $computerName `
        -FallbackAddress $fallbackAddress `
        -TimeoutSeconds $ReadinessTimeoutSeconds
    $labNetworkReceipt = $null
    if ($build.labNetwork) {
        Write-LabInfo "Netzwerk: konfiguriere Gastadresse im Netz $($build.labNetwork.Name)"
        $labNetworkReceipt = Initialize-HyperVGuestLabNetwork -VMName $vmName `
            -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId -Credential $Credential `
            -Network $build.labNetwork -Identity $build.buildId -FallbackAddress $fallbackAddress
    }
    $readiness = Wait-HyperVGuestSqlReady -VMName $vmName -ExpectedRunId $build.buildId `
        -ExpectedScopeId $build.scopeId -Credential $Credential -SaPassword $SaPassword `
        -FallbackAddress $fallbackAddress `
        -ExpectedMajorVersion (Get-HyperVSqlMajorVersion -SqlVersion $build.sql.version) `
        -TimeoutSeconds $ReadinessTimeoutSeconds
    if (-not $readiness.Ready) { throw 'HYPERV_SQL_TEST_ENVIRONMENT_READINESS_FAILED' }

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    $build | Add-Member -NotePropertyName testEnvironment -NotePropertyValue ([PSCustomObject]@{
        status = 'SQL_READY_RUN'; computerName = $computerName; instanceName = 'MSSQLSERVER'
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
    if (-not $SaPassword) { $SaPassword = Get-LabSecret -Path $build.BuildDirectory -Name 'sa-password' }
    if (-not $SaPassword) { throw 'HYPERV_SQL_ACCEPTANCE_SA_PASSWORD_REQUIRED' }
    $expectedMajor = Get-HyperVSqlMajorVersion -SqlVersion $build.sql.version
    $fallbackAddress = if ($build.labNetwork) {
        Get-LabNetworkGuestAddress -Network $build.labNetwork -Identity $build.buildId
    }
    $receipt = Invoke-HyperVPowerShellDirect -VMName $build.builder.vmName -ExpectedRunId $build.buildId `
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
                $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
                $builder['Data Source'] = 'localhost'; $builder['Initial Catalog'] = 'master'; $builder['User ID'] = 'sa'
                $builder['Password'] = $plainPassword; $builder['Encrypt'] = $true; $builder['TrustServerCertificate'] = $true
                $builder['Connect Timeout'] = [Math]::Min(15, [int]$Timeout)
                $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString); $connection.Open()
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
                if (-not $backupRoot) { $backupRoot = Join-Path $env:ProgramFiles 'Microsoft SQL Server\MSSQL\Backup' }
                New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
                $backupPath = Join-Path $backupRoot "$databaseName.bak"
                $escapedBackup = $backupPath.Replace("'", "''")
                $command.CommandText = "SET NOCOUNT ON; BACKUP DATABASE [$databaseName] TO DISK=N'$escapedBackup' WITH INIT,CHECKSUM; RESTORE VERIFYONLY FROM DISK=N'$escapedBackup' WITH CHECKSUM; SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int);"
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
        }
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
            Where-Object { $_.sql.version -in @('2019', '2022', '2025') } |
            Sort-Object { [int]$_.sql.version } |
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
