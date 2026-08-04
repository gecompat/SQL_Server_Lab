#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt einen realen, resumierbaren Hyper-V-SQL-Abnahmelauf aus.
.DESCRIPTION
    Der Lauf verwendet einen bestehenden SQL-Image-Build und dessen lokal per
    DPAPI geschuetzte Credentials. Er schliesst OOBE ab, installiert SQL,
    prueft die Gastabnahme und verifiziert anschliessend den SQL-Zugriff vom
    Windows-Host auf die feste Hyper-V-Lab-IP.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildId,
    [ValidateRange(60, 3600)][int]$OobeTimeoutSeconds = 900,
    [ValidateRange(60, 10800)][int]$SetupTimeoutSeconds = 7200,
    [ValidateRange(60, 3600)][int]$ReadinessTimeoutSeconds = 600,
    [string]$StateRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru

function Invoke-PrivateLabCommand {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$Arguments = @())
    return & $module $ScriptBlock @Arguments
}

$build = Invoke-PrivateLabCommand {
    param($Id,$Root,$OobeTimeout)
    $current = Get-HyperVSqlImageBuildPlan -BuildId $Id -StateRoot $Root
    if (-not $current) { throw 'HYPERV_SQL_ACCEPTANCE_BUILD_NOT_FOUND' }
    if ($current.state -in @('MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING')) {
        $current = Invoke-HyperVSqlUnattendedOobe -BuildId $Id -TimeoutSeconds $OobeTimeout -StateRoot $Root
    }
    return $current
} @($BuildId, $StateRoot, $OobeTimeoutSeconds)

if ($build.state -notin @('OOBE_COMPLETED', 'SQL_INSTALL_REBOOT_REQUIRED', 'SQL_INSTALL_RUNNING', 'SQL_READY_RUN', 'TESTS_PASSED')) {
    throw "HYPERV_SQL_ACCEPTANCE_OOBE_INCOMPLETE: $($build.state)"
}

$secrets = Invoke-PrivateLabCommand {
    param($Build)
    $credential = Get-HyperVSqlGuestCredential -Build $Build
    $saPassword = Get-LabSecret -Path $Build.BuildDirectory -Name 'sa-password'
    if (-not $saPassword) {
        $saPassword = New-HyperVSqlUnattendedPassword
        Save-LabSecret -Path $Build.BuildDirectory -Name 'sa-password' -Secret $saPassword
    }
    [PSCustomObject]@{ Credential = $credential; SaPassword = $saPassword }
} @($build)

$build = Invoke-PrivateLabCommand {
    param($Id,$Credential,$SaPassword,$Root,$SetupTimeout,$ReadinessTimeout)
    $result = Invoke-HyperVSqlTestEnvironmentInstall -BuildId $Id -Credential $Credential -SaPassword $SaPassword `
        -SetupTimeoutSeconds $SetupTimeout -ReadinessTimeoutSeconds $ReadinessTimeout -StateRoot $Root
    if ($result.state -eq 'SQL_INSTALL_REBOOT_REQUIRED') {
        $result = Invoke-HyperVSqlTestEnvironmentInstall -BuildId $Id -Credential $Credential -SaPassword $SaPassword `
            -SetupTimeoutSeconds $SetupTimeout -ReadinessTimeoutSeconds $ReadinessTimeout -StateRoot $Root
    }
    return $result
} @($BuildId, $secrets.Credential, $secrets.SaPassword, $StateRoot, $SetupTimeoutSeconds, $ReadinessTimeoutSeconds)

if ($build.state -notin @('SQL_READY_RUN', 'TESTS_PASSED')) {
    throw "HYPERV_SQL_ACCEPTANCE_SQL_INCOMPLETE: $($build.state)"
}

$build = Invoke-PrivateLabCommand {
    param($Id,$Credential,$SaPassword,$Root)
    Test-HyperVSqlAcceptanceEnvironment -BuildId $Id -Credential $Credential -SaPassword $SaPassword -StateRoot $Root
} @($BuildId, $secrets.Credential, $secrets.SaPassword, $StateRoot)

$address = [string]$build.testEnvironment.address
if ([string]::IsNullOrWhiteSpace($address)) { throw 'HYPERV_SQL_ACCEPTANCE_HOST_ADDRESS_MISSING' }
$tcp = Test-NetConnection -ComputerName $address -Port 1433 -WarningAction SilentlyContinue
if (-not $tcp.TcpTestSucceeded) { throw "HYPERV_SQL_ACCEPTANCE_HOST_TCP_FAILED: $address`:,1433" }

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secrets.SaPassword)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $major = sqlcmd -S "${address},1433" -U sa -P $plain -C -b -h -1 -W -Q "SET NOCOUNT ON; SELECT CONVERT(varchar(10), SERVERPROPERTY('ProductMajorVersion'));" 2>&1
    if ($LASTEXITCODE -ne 0 -or (($major | Out-String).Trim() -notmatch '^\d+$')) {
        throw 'HYPERV_SQL_ACCEPTANCE_HOST_SQLCMD_FAILED'
    }
}
finally {
    $plain = $null
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

[PSCustomObject]@{
    BuildId = $build.buildId; State = $build.state; SqlVersion = $build.sql.version
    HostAddress = $address; HostTcpReachable = $true; HostSqlMajorVersion = ($major | Out-String).Trim()
    ObservedAt = [datetime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 4
