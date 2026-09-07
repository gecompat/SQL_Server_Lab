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
$acceptancePath = Join-Path $repoRoot 'Private/HyperVSqlAcceptanceEnvironment.ps1'
$legacyAcceptanceToolPath = Join-Path $repoRoot 'Tools/New-LegacySqlServerAcceptanceEnvironment.ps1'
$nt5AcceptanceToolPath = Join-Path $repoRoot 'Tools/New-WindowsServer2003SqlAcceptanceEnvironment.ps1'
$nt5ActivationToolPath = Join-Path $repoRoot 'Tools/Invoke-WindowsServer2003LegacyActivation.ps1'
$nt5ChildToolPath = Join-Path $repoRoot 'Tools/New-WindowsServer2003LegacyChild.ps1'
$menuPath = Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-sql-acceptance-$([guid]::NewGuid().ToString('N'))"
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Hyper-V SQL Acceptance Environment Checks' -ForegroundColor Cyan

try {
    New-Item -Path $temporaryRoot -ItemType Directory -Force | Out-Null
    $module = Import-Module $modulePath -Force -PassThru

    $knownPassword = 'Offline_OOBE_42!'
    $securePassword = ConvertTo-SecureString $knownPassword -AsPlainText -Force
    $unattend = & $module { param($Password) New-HyperVSqlOobeUnattendXml -AdministratorPassword $Password } $securePassword
    [xml]$unattendDocument = $unattend
    Add-CheckResult -Name 'Unattend.xml ist wohlgeformtes XML' -Success ($null -ne $unattendDocument.unattend.settings)
    Add-CheckResult -Name 'Administratorpasswort folgt der Windows-Shell-Setup-UserAccounts-Hierarchie' -Success (
        $unattend -match '<UserAccounts>\s*<AdministratorPassword>' -and
        $unattend -notmatch '<component[^>]+>\s*<AdministratorPassword>'
    )
    Add-CheckResult -Name 'OOBE-Antwortsatz setzt Sprache, Region, Tastatur und Zeitzone' -Success (
        $unattend -match 'Microsoft-Windows-International-Core' -and
        $unattend -match '<InputLocale>0407:00000407</InputLocale>' -and
        $unattend -match '<SystemLocale>de-DE</SystemLocale>' -and
        $unattend -match '<UILanguage>en-US</UILanguage>' -and
        $unattend -match '<UserLocale>de-DE</UserLocale>' -and
        $unattend -match '<TimeZone>W\. Europe Standard Time</TimeZone>'
    )
    Add-CheckResult -Name 'Specialize unterdrueckt die interaktive Privacy Experience vor dem ersten Login' -Success (
        $unattend -match '<settings pass="specialize">' -and
        $unattend -match 'Microsoft-Windows-Deployment' -and
        $unattend -match 'DisablePrivacyExperience /t REG_DWORD /d 1 /f'
    )
    $customTimeZoneUnattend = & $module {
        param($Password)
        New-HyperVSqlOobeUnattendXml -AdministratorPassword $Password -TimeZone 'Central Europe Standard Time'
    } $securePassword
    Add-CheckResult -Name 'Unattend.xml übernimmt eine explizit gewählte Windows-Zeitzone' -Success (
        $customTimeZoneUnattend -match '<TimeZone>Central Europe Standard Time</TimeZone>'
    )
    Add-CheckResult -Name 'OOBE blendet interaktive Seiten aus und aktiviert genau einen AutoLogon' -Success (
        $unattend -match '<HideEULAPage>true</HideEULAPage>' -and
        $unattend -match '<HideLocalAccountScreen>true</HideLocalAccountScreen>' -and
        $unattend -match '<LogonCount>1</LogonCount>' -and
        $unattend -notmatch '<NetworkLocation>'
    )
    $labNetwork = [PSCustomObject]@{ Name = 'SQL_LAB_HYPERV'; Subnet = '172.28.0.0/24'; PrefixLength = 24; HostAddress = '172.28.0.1' }
    $bootstrap = & $module {
        param($Password,$Network)
        New-HyperVSqlGuestNetworkBootstrapScript -Network $Network -Address '172.28.0.42'
    } $securePassword $labNetwork
    Add-CheckResult -Name 'SetupComplete bootstrappt eine feste Lab-IP und Host-beschraenktes WinRM' -Success (
        $bootstrap -match "IPAddress='172\.28\.0\.42'" -and
        $bootstrap -match 'Enable-PSRemoting' -and
        $bootstrap -match 'Get-ChildItem -LiteralPath WSMan:\\localhost\\Listener' -and
        $bootstrap -match 'if \(-not \$winRmReady\) \{ Enable-PSRemoting' -and
        $bootstrap -match "RemoteAddress '172\.28\.0\.1'" -and
        $bootstrap -match 'Set-Content[\s\S]+-Encoding UTF8' -and
        $bootstrap -notmatch 'utf8NoBOM' -and
        $bootstrap -notmatch [regex]::Escape($knownPassword)
    )
    $natBootstrap = & $module {
        New-HyperVSqlGuestNetworkBootstrapScript -Network ([PSCustomObject]@{
            Name='SQL_LAB_HYPERV_NAT'; PrefixLength=24; HostAddress='172.29.0.1'
            gateway='172.29.0.1'; dnsServers=@('192.0.2.53', '192.0.2.54')
        }) -Address '172.29.0.42'
    }
    Add-CheckResult -Name 'Hyper-V-NAT-Bootstrap bindet Gateway und den geprüften DNS-Snapshot' -Success (
        $natBootstrap -match "DefaultGateway = '172\.29\.0\.1'" -and
        $natBootstrap -match "Set-DnsClientServerAddress" -and
        $natBootstrap -match "'192\.0\.2\.53','192\.0\.2\.54'"
    )
    $lanBootstrap = & $module {
        New-HyperVSqlGuestNetworkBootstrapScript -Network ([PSCustomObject]@{
            Name='SQL_LAB_LAN'; Intent='lan'; AddressMode='dhcp'
        })
    }
    Add-CheckResult -Name 'Hyper-V-LAN-Bootstrap bezieht DHCP und begrenzt WinRM auf das lokale Subnetz' -Success (
        $lanBootstrap -match 'Set-NetIPInterface[\s\S]+-Dhcp Enabled' -and
        $lanBootstrap -match 'Set-DnsClientServerAddress[\s\S]+-ResetServerAddresses' -and
        $lanBootstrap -match 'SQL_LAB_OOBE_DHCP_ADDRESS_NOT_READY' -and
        $lanBootstrap -match 'RemoteAddress LocalSubnet' -and
        $lanBootstrap -match "addressMode = 'dhcp'"
    )

    $buildId = [guid]::NewGuid().ToString(); $scopeId = [guid]::NewGuid().ToString()
    $buildDirectory = Join-Path $temporaryRoot "image-builds/hyperv-sql/$buildId"
    New-Item -Path (Join-Path $buildDirectory 'resources/hyperv') -ItemType Directory -Force | Out-Null
    $state = [PSCustomObject]@{
        contractVersion = '1'; buildKind = 'hyperv-sql-prepare-image'; buildId = $buildId; scopeId = $scopeId
        state = 'MANUAL_ACTION_REQUIRED'; stateHistory = @(); parentArtifact = [PSCustomObject]@{}
        sql = [PSCustomObject]@{ version = '2022'; edition = 'Evaluation'; mediaEdition = 'Eval'; features = @('SQLENGINE') }
        builder = [PSCustomObject]@{ vmName = 'mock-sql-2022'; osDiskRelativePath = 'resources/hyperv/mock.vhdx'; networkAttached = $false }
        manualAction = [PSCustomObject]@{ challenge = [guid]::NewGuid().ToString() }
        createdAt = [datetime]::UtcNow.ToString('o'); updatedAt = [datetime]::UtcNow.ToString('o')
    }
    & $module { param($Directory,$State) Write-HyperVSqlImageBuildState -BuildDirectory $Directory -State $State } $buildDirectory $state

    $oobeResult = & $module {
        param($BuildId,$Root,$Password)
        function Ensure-HyperVSqlBuildLabNetwork {
            param($Build,$StateRoot)
            $Build | Add-Member -NotePropertyName labNetwork -NotePropertyValue ([PSCustomObject]@{ Name = 'SQL_LAB_HYPERV'; Subnet = '172.28.0.0/24'; PrefixLength = 24; HostAddress = '172.28.0.1' }) -Force
            $Build
        }
        function Stop-HyperVInstance { [PSCustomObject]@{ State = 'Off' } }
        function Set-HyperVSqlOfflineUnattend {
            param($VhdxPath,$MountRoot,$UnattendXml,$BootstrapScript)
            if ($UnattendXml -notmatch 'Microsoft-Windows-International-Core' -or $BootstrapScript -notmatch 'Enable-PSRemoting') { throw 'UNATTEND_MOCK_INVALID' }
        }
        function Start-HyperVInstance { [PSCustomObject]@{ State = 'Running' } }
        function Wait-HyperVPowerShellDirect { [PSCustomObject]@{ Ready = $true; Message = 'ready' } }
        function Invoke-HyperVPowerShellDirect {
            [PSCustomObject]@{
                contractVersion = '1'; imageState = 'IMAGE_STATE_COMPLETE'; systemLocale = 'de-DE'
                uiLanguage = 'en-US'; inputLocale = '0407:00000407'; timeZone = 'W. Europe Standard Time'
                observedAt = [datetime]::UtcNow.ToString('o')
            }
        }
        Invoke-HyperVSqlUnattendedOobe -BuildId $BuildId -AdministratorPassword $Password -StateRoot $Root
    } $buildId $temporaryRoot $securePassword
    Add-CheckResult -Name 'Gemockter OOBE-Lifecycle erreicht OOBE_COMPLETED' -Success (
        $oobeResult.state -eq 'OOBE_COMPLETED' -and $oobeResult.oobeAutomation.status -eq 'COMPLETED'
    )
    $rawState = Get-Content -LiteralPath (Join-Path $buildDirectory 'build-state.json') -Raw
    Add-CheckResult -Name 'Gastpasswort erscheint nicht im portablen Build-State' -Success (
        $rawState -notmatch [regex]::Escape($knownPassword) -and
        (Test-Path -LiteralPath (Join-Path $buildDirectory 'secrets/guest-administrator-password.secret'))
    )

    $saPlain = 'Acceptance_SA_42!'; $saPassword = ConvertTo-SecureString $saPlain -AsPlainText -Force
    $credential = [PSCredential]::new('Administrator', $securePassword)
    $installed = & $module {
        param($BuildId,$Root,$Credential,$SaPassword)
        function Get-HyperVManagedVM { [PSCustomObject]@{ VM = [PSCustomObject]@{ State = 'Running' }; Identity = [PSCustomObject]@{} } }
        function Invoke-HyperVPowerShellDirect {
            param($VMName,$ExpectedRunId,$ExpectedScopeId,$Credential,$ScriptBlock,$ArgumentList)
            [PSCustomObject]@{
                contractVersion = '1'; buildId = $ArgumentList[0]; scopeId = $ArgumentList[1]; challenge = $ArgumentList[2]
                action = 'Install'; sqlVersion = '2022'; expectedMajorVersion = 16; setupVersion = '16.0.1000.6'
                mediaEdition = 'Eval'; features = @('SQLENGINE'); exitCode = 0; rebootScheduled = $false; completedAt = [datetime]::UtcNow.ToString('o')
            }
        }
        function Set-HyperVWindowsGuestSpecialization { [PSCustomObject]@{ status = 'WINDOWS_SPECIALIZED' } }
        function Initialize-HyperVGuestLabNetwork { [PSCustomObject]@{ Network = 'SQL_LAB_HYPERV'; Address = '172.28.0.58'; PrefixLength = 24; ObservedAt = [datetime]::UtcNow.ToString('o') } }
        function Wait-HyperVGuestSqlReady {
            [PSCustomObject]@{ Ready = $true; MajorVersion = 16; ProductVersion = '16.0.1000.6'; Edition = 'Enterprise Evaluation'; ObservedAt = [datetime]::UtcNow.ToString('o') }
        }
        Invoke-HyperVSqlTestEnvironmentInstall -BuildId $BuildId -Credential $Credential -SaPassword $SaPassword -StateRoot $Root
    } $buildId $temporaryRoot $credential $saPassword
    Add-CheckResult -Name 'Gemockte SQL-2022-Installation erreicht SQL_READY_RUN' -Success (
        $installed.state -eq 'SQL_READY_RUN' -and $installed.testEnvironment.majorVersion -eq 16
    )

    $accepted = & $module {
        param($BuildId,$Root,$Credential)
        function Invoke-HyperVPowerShellDirect {
            param($VMName,$ExpectedRunId,$ExpectedScopeId,$Credential,$ScriptBlock,$ArgumentList)
            [PSCustomObject]@{
                contractVersion = '1'; buildId = $ArgumentList[0]; scopeId = $ArgumentList[1]
                sqlVersion = '2022'; majorVersion = 16; rowCount = 1; databaseCreate = $true
                insertSelect = $true; backupChecksum = $true; restoreVerifyOnly = $true
                databaseDrop = $true; backupRemoved = $true; observedAt = [datetime]::UtcNow.ToString('o')
            }
        }
        Test-HyperVSqlAcceptanceEnvironment -BuildId $BuildId -Credential $Credential -StateRoot $Root
    } $buildId $temporaryRoot $credential
    Add-CheckResult -Name 'Create/Insert/Backup/Verify/Drop-Receipt erreicht TESTS_PASSED' -Success (
        $accepted.state -eq 'TESTS_PASSED' -and $accepted.acceptanceEvidence.backupChecksum -eq $true
    )
    $finalRawState = Get-Content -LiteralPath (Join-Path $buildDirectory 'build-state.json') -Raw
    Add-CheckResult -Name 'Weder Gast- noch SA-Passwort erscheinen im Abnahme-State' -Success (
        $finalRawState -notmatch [regex]::Escape($knownPassword) -and $finalRawState -notmatch [regex]::Escape($saPlain)
    )

    $acceptanceText = Get-Content -LiteralPath $acceptancePath -Raw -Encoding utf8
    Add-CheckResult -Name 'Reale Abnahme prueft SQL-Version, Backup CHECKSUM und RESTORE VERIFYONLY' -Success (
        $acceptanceText -match "PARSENAME\(CONVERT\(varchar\(128\),SERVERPROPERTY\('ProductVersion'\)\),4\)" -and
        $acceptanceText -match 'BACKUP DATABASE[\s\S]+CHECKSUM' -and $acceptanceText -match 'RESTORE VERIFYONLY'
    )
    Add-CheckResult -Name 'SQL-Abnahme verwendet Windows-PowerShell-5.1-kompatible Connection-String-Keywords' -Success (
        $acceptanceText -match "\`$builder\['Data Source'\]" -and
        $acceptanceText -match "\`$builder\['Initial Catalog'\]" -and
        $acceptanceText -notmatch '\$builder\.DataSource\s*='
    )
    Add-CheckResult -Name 'Gast-Unattend wird nach OOBE entfernt' -Success (
        $acceptanceText -match 'Panther\\Unattend\.xml[\s\S]+Remove-Item'
    )
    Add-CheckResult -Name 'OOBE nutzt bei ausgefallenem PowerShell Direct das Hyper-V-Labnetz' -Success (
        $acceptanceText -match 'bootstrapVersion.*network-winrm-v1' -and
        $acceptanceText -match 'FallbackAddress\s+\$fallbackAddress'
    )
    Add-CheckResult -Name 'SQL 2012 erhält nur versionsgültige unbeaufsichtigte Setupoptionen' -Success (
        $acceptanceText -match 'if\s*\((?:\[int\]\$config\.expectedMajor|\$expectedMajor)\s*-ge\s*13\).*SQLSVCINSTANTFILEINIT=True' -and
        $acceptanceText -match "'2012'.*'2014'.*'2016'.*'2017'.*'2019'.*'2022'.*'2025'"
    )
    Add-CheckResult -Name 'SQL Express nutzt das SFX-Vollpaket und keine nicht vorhandene Agent-Konfiguration' -Success (
        $acceptanceText -match "SQLEXPR\*_ENU\.exe" -and
        $acceptanceText -match "mediaEdition-ne 'Express'" -and
        $acceptanceText -match '\$receipt\.mediaEdition -ne \[string\]\$build\.sql\.mediaEdition' -and
        $acceptanceText -match 'mediaEdition = \[string\]\$receipt\.mediaEdition'
    )
    Add-CheckResult -Name 'Legacy-SQL-Setup läuft mit geladenem Administratorprofil und ohne Klartextpasswort im Task' -Success (
        $acceptanceText -match 'ProtectedData\]::Protect' -and
        $acceptanceText -match 'Register-ScheduledTask[\s\S]+-User ''Administrator''[\s\S]+-RunLevel Highest' -and
        $acceptanceText -match 'Unregister-ScheduledTask[\s\S]+Remove-Item -LiteralPath \$workRoot' -and
        $acceptanceText -notmatch 'New-ScheduledTaskAction[^\r\n]+SAPWD'
    )
    Add-CheckResult -Name 'SQL 2012 bezieht NetFx3 eindeutig aus dem verifizierten Windows-Medium' -Success (
        $acceptanceText -match "expectedMajor -le 12" -and
        $acceptanceText -match "sources\\sxs" -and
        $acceptanceText -match 'Install-WindowsFeature -Name NET-Framework-Core -Source \$sources\[0\]' -and
        $acceptanceText -match 'SQL_SETUP_NETFX3_SOURCE_NOT_UNIQUE'
    )
    Add-CheckResult -Name 'SQL-2012-Abnahme fällt bei fehlendem InstanceDefaultBackupPath auf die Registry zurück' -Success (
        $acceptanceText -match "SERVERPROPERTY\('InstanceDefaultBackupPath'\)" -and
        $acceptanceText -match 'Instance Names\\SQL' -and
        $acceptanceText -match 'BackupDirectory'
    )
    $legacyAcceptanceToolText = Get-Content -LiteralPath $legacyAcceptanceToolPath -Raw -Encoding utf8
    Add-CheckResult -Name 'SQL-2008-bis-2014-Abnahmetool ist hash-, OS-, Elevation- und Postcondition-gebunden' -Success (
        $legacyAcceptanceToolText -match "ValidateSet\('2008','2008R2','2012','2014'\)" -and
        $legacyAcceptanceToolText -match 'ShowHelp' -and
        $legacyAcceptanceToolText -match 'Resolve-HyperVImageArtifact' -and
        $legacyAcceptanceToolText -match 'Confirm-HyperVSqlInstallationMediaVersion' -and
        $legacyAcceptanceToolText -match 'LEGACY_SQL_ACCEPTANCE_REQUIRES_ELEVATED_RUNNER' -and
        $legacyAcceptanceToolText -match 'SQL_SERVER_LAB_ELEVATED_CHILD' -and
        $legacyAcceptanceToolText -match 'Start-Process -FilePath \$pwsh -Verb RunAs' -and
        $legacyAcceptanceToolText -match "Status='ELEVATION_STARTED'" -and
        $legacyAcceptanceToolText -match 'Invoke-HyperVSqlUnattendedOobe' -and
        $legacyAcceptanceToolText -match 'Invoke-HyperVSqlTestEnvironmentInstall' -and
        $legacyAcceptanceToolText -match 'Test-HyperVSqlAcceptanceEnvironment' -and
        $legacyAcceptanceToolText -match "state -ne 'TESTS_PASSED'" -and
        $legacyAcceptanceToolText -match 'CredentialDisclosed=\$false;PasswordDisclosed=\$false'
    )
    Add-CheckResult -Name 'SQL-2014-Abnahmetool lädt das verifizierte SP3-Paket und erzeugt ein Offline-ISO' -Success (
        $legacyAcceptanceToolText -match 'sql-server-2014-express-sp3-full' -and
        $legacyAcceptanceToolText -match 'SQLServer2014SP3Express-x64-ENU\.iso' -and
        $legacyAcceptanceToolText -match 'Save-SqlServerLabMediaSource' -and
        $legacyAcceptanceToolText -match 'New-HyperVSqlPackageMediaIso' -and
        $legacyAcceptanceToolText -match "SqlFeatures=@\('SQLENGINE'\)"
    )
    Add-CheckResult -Name 'SQL 2008 und 2008 R2 nutzen verifizierte Express-Service-Pack-Pakete auf Server 2008 R2' -Success (
        $legacyAcceptanceToolText -match 'sql-server-2008-express-sp3-archive' -and
        $legacyAcceptanceToolText -match 'SQLServer2008SP3Express-x64-ENU\.iso' -and
        $legacyAcceptanceToolText -match 'sql-server-2008r2-express-sp2-full' -and
        $legacyAcceptanceToolText -match 'SQLServer2008R2SP2Express-x64-ENU\.iso' -and
        $legacyAcceptanceToolText -match "OperatingSystemId='windows-server-2008-r2'" -and
        $legacyAcceptanceToolText -match 'MinimumEvaluationDaysRemaining=1'
    )
    Add-CheckResult -Name 'Server-2008-R2-Gastpfad bleibt PowerShell-2-kompatibel und setzt die Logon-Tastatur' -Success (
        $acceptanceText -match 'New-HyperVSqlLegacyGuestNetworkBootstrapScript' -and
        $acceptanceText -match 'Get-WmiObject Win32_NetworkAdapterConfiguration' -and
        $acceptanceText -match 'HKU\\\.DEFAULT\\Keyboard Layout\\Preload' -and
        $acceptanceText -match 'Invoke-HyperVLegacySqlSetup' -and
        $acceptanceText -match 'New-Object PSObject -Property' -and
        $acceptanceText -match 'NETWORK SERVICE' -and
        $acceptanceText -match 'Wait-HyperVLegacySqlReady' -and
        $acceptanceText -match 'Invoke-HyperVLegacySqlAcceptanceTest' -and
        $acceptanceText -match 'Integrated Security=SSPI' -and
        $acceptanceText -match 'Export-Csv -Path \$temporaryPath -NoTypeInformation' -and
        $acceptanceText -notmatch 'Export-Clixml'
    )
    $resumeStart = $legacyAcceptanceToolText.IndexOf('$resolved=if($existingBuilds.Count -eq 1)')
    $newBuildStart = $legacyAcceptanceToolText.IndexOf('}else{& $module {', $resumeStart)
    $resumeText = if ($resumeStart -ge 0 -and $newBuildStart -gt $resumeStart) {
        $legacyAcceptanceToolText.Substring($resumeStart, $newBuildStart - $resumeStart)
    } else { '' }
    Add-CheckResult -Name 'Unveränderter Legacy-SQL-Resume verwendet den Prüfbeleg statt die große ISO erneut zu hashen' -Success (
        $resumeText -match 'mediaVerification' -and
        $resumeText -match 'lengthBytes' -and
        $resumeText -match 'lastWriteTimeUtc' -and
        $resumeText -match 'LEGACY_SQL_ACCEPTANCE_MEDIA_CHANGED_REVERIFY_REQUIRED' -and
        $resumeText -match 'LEGACY_SQL_ACCEPTANCE_MEDIA_HASH_BINDING_CHANGED' -and
        $resumeText -notmatch 'Get-FileHash'
    )
    Add-CheckResult -Name 'Legacy-SQL-Tool bindet den NetFx3-Quell-Datenträger an vorhandene Verifikationsevidenz' -Success (
        $legacyAcceptanceToolText -match 'windows-server-evaluation-media-validation\.json' -and
        $legacyAcceptanceToolText -match 'WINDOWS_FEATURE_SOURCE_CHANGED_REVERIFY_REQUIRED' -and
        $legacyAcceptanceToolText -match 'Add-VMDvdDrive[\s\S]+WindowsFeatureSource\.IsoPath'
    )
    $nt5AcceptanceToolText = Get-Content -LiteralPath $nt5AcceptanceToolPath -Raw -Encoding utf8
    $nt5ActivationToolText = Get-Content -LiteralPath $nt5ActivationToolPath -Raw -Encoding utf8
    $nt5ChildToolText = Get-Content -LiteralPath $nt5ChildToolPath -Raw -Encoding utf8
    Add-CheckResult -Name 'SQL-2005-Abnahme staged offline und startet den lokalen Job gezielt über Legacy-WMI' -Success (
        $nt5AcceptanceToolText -match 'function Set-Ws2003SqlOfflineJob' -and
        $nt5AcceptanceToolText -match 'function Get-Ws2003SqlOfflineReceipt' -and
        $nt5AcceptanceToolText -match 'SQL Server x86\\Servers\\setup\.exe' -and
        $nt5AcceptanceToolText -match 'SQL Server\\90\\Tools\\Binn\\sqlcmd\.exe' -and
        $nt5AcceptanceToolText -match 'SQLBROWSERACCOUNT="NT AUTHORITY\\SYSTEM"' -and
        $nt5AcceptanceToolText -match "sqlCompletionServiceName='SqlLabCompleteV\d+'" -and
        $nt5AcceptanceToolText -match "sqlResumeTaskName='SqlLabSql2005V\d+'" -and
        $nt5AcceptanceToolText -match 'schtasks\.exe /Create /TN \$sqlResumeTaskName[\s\S]+/SC ONSTART /RU SYSTEM' -and
        $nt5AcceptanceToolText -match 'sqlcmd\.exe" goto RUN_SQL_SETUP[\s\S]+sc\.exe query MSSQLSERVER' -and
        $nt5AcceptanceToolText -match 'schtasks\.exe /Delete /TN \$sqlResumeTaskName' -and
        $nt5AcceptanceToolText -match 'function Start-Ws2003SqlStagedJob' -and
        $nt5AcceptanceToolText -match "ManagementPath\]::new\('Win32_Process'\)" -and
        $nt5AcceptanceToolText -match 'Sql2005Acceptance\.cmd' -and
        $nt5AcceptanceToolText -match 'Connect-HyperVLegacyWindowsWmiScope' -and
        $nt5AcceptanceToolText -notmatch 'New-PSDrive' -and
        $nt5AcceptanceToolText -notmatch 'Invoke-HyperVPowerShellDirect'
    )
    Add-CheckResult -Name 'Windows-Server-2003-Offlinezugriffe erzeugen keine Host-Laufwerksbuchstaben' -Success (
        $nt5AcceptanceToolText -match 'Mount-VHD -Path \$Path -NoDriveLetter' -and
        $nt5ActivationToolText -match 'Mount-VHD -Path \$Path -NoDriveLetter' -and
        $nt5ChildToolText -match 'Mount-VHD -Path \$childVhdPath -NoDriveLetter' -and
        $nt5AcceptanceToolText -match 'SqlServerLab-VhdMount-' -and
        $nt5ActivationToolText -match 'SqlServerLab-VhdMount-' -and
        $nt5ChildToolText -match 'SqlServerLab-VhdMount-' -and
        $nt5AcceptanceToolText -match 'Remove-PartitionAccessPath[\s\S]+Dismount-VHD[\s\S]+Remove-Item' -and
        $nt5ActivationToolText -match 'Remove-PartitionAccessPath[\s\S]+Dismount-VHD[\s\S]+Remove-Item' -and
        $nt5ChildToolText -notmatch 'temporaryDriveLetter'
    )
    Add-CheckResult -Name 'Server-2003-/SQL-2005-Orchestrator ist hash-, Resume-, Grace- und Geheimnis-gebunden' -Success (
        $nt5AcceptanceToolText -match "ValidateSet\('2005'\)" -and
        $nt5AcceptanceToolText -match 'Start-Process -FilePath \$pwsh -Verb RunAs' -and
        $nt5AcceptanceToolText -match 'COMMUNITY_UNVERIFIED_USER_APPROVED_FOR_LAB' -and
        $nt5AcceptanceToolText -match 'Get-FileHash[\s\S]+MEDIA_INTEGRITY_MISMATCH' -and
        $nt5AcceptanceToolText -match 'Test-Ws2003SqlFileBinding' -and
        $nt5AcceptanceToolText -match "state='OOB_GRACE'" -and
        $nt5AcceptanceToolText -match 'ActivationRequired' -and
        $nt5AcceptanceToolText -match 'Activated=\$false' -and
        $nt5AcceptanceToolText -match 'Reserve-LabHyperVNetworkAddress' -and
        $nt5AcceptanceToolText -match 'Set-Ws2003SqlOfflineJob' -and
        $nt5AcceptanceToolText -match 'Get-Ws2003SqlOfflineReceipt' -and
        $nt5AcceptanceToolText -match 'setupContractVersion' -and
        $nt5AcceptanceToolText -match 'CredentialDisclosed=\$false;PasswordDisclosed=\$false'
    )
    $menuText = Get-Content -LiteralPath $menuPath -Raw -Encoding utf8
    Add-CheckResult -Name 'InvokeLab-Menue bietet Installation, Abnahmetest und Matrix' -Success (
        $menuText -match "'1' \{ Invoke-LabHyperVMenuAction -Title 'OOBE und SQL-Setup' -Action \{ Invoke-LabHyperVSqlAcceptanceInstallInteractive \} \}" -and
        $menuText -match "'2' \{ Invoke-LabHyperVMenuAction -Title 'SQL-Abnahmetest' -Action \{ Test-LabHyperVSqlAcceptanceInteractive \} \}" -and
        $menuText -match '''3'' \{ Invoke-LabHyperVMenuAction -Title ''SQL-Abnahmematrix'' -Action \{ Show-LabHyperVSqlAcceptanceMatrix \} -RequiresAdministrator:\$false \}' -and
        $menuText -match "'4' \{ Invoke-LabHyperVMenuAction -Title 'Manuelle OOBE übernehmen' -Action \{ Invoke-LabHyperVSqlManualOobeAcceptanceInstallInteractive \} \}"
    )
}
catch { Add-CheckResult -Name 'Hyper-V-SQL-Abnahme-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0



