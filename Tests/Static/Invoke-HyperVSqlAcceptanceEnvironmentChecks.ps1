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
        sql = [PSCustomObject]@{ version = '2022'; edition = 'Evaluation'; features = @('SQLENGINE') }
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
                features = @('SQLENGINE'); exitCode = 0; rebootScheduled = $false; completedAt = [datetime]::UtcNow.ToString('o')
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
        $acceptanceText -match "SERVERPROPERTY\('ProductMajorVersion'\)" -and
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
    $menuText = Get-Content -LiteralPath $menuPath -Raw -Encoding utf8
    Add-CheckResult -Name 'InvokeLab-Menue bietet Installation, Abnahmetest und Matrix' -Success (
        $menuText -match "'1' \{ Invoke-LabHyperVMenuAction -Title 'OOBE und SQL-Setup' -Action \{ Invoke-LabHyperVSqlAcceptanceInstallInteractive \} \}" -and
        $menuText -match "'2' \{ Invoke-LabHyperVMenuAction -Title 'SQL-Abnahmetest' -Action \{ Test-LabHyperVSqlAcceptanceInteractive \} \}" -and
        $menuText -match "'3' \{ Invoke-LabHyperVMenuAction -Title 'SQL-Abnahmematrix' -Action \{ Show-LabHyperVSqlAcceptanceMatrix \} \}" -and
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



