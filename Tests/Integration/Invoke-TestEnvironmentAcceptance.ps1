#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft alle exportierten automatisierten SQL-Testumgebungen und den CMS.
.DESCRIPTION
    Validiert den JSON-Vertrag, fuehrt pro READY-Ziel eine Versions- und
    Datenbankabfrage sowie einen isolierten Create/Drop-Schreibtest aus und
    vergleicht die Zieladressen mit den realen CMS-Registrierungen.
#>
[CmdletBinding()]
param(
    [string]$ContractPath = $env:SQL_SERVER_LAB_TEST_ENV_FILE,
    [string]$SchemaPath = $env:SQL_SERVER_LAB_TEST_ENV_SCHEMA_FILE,
    [string]$StateRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $ContractPath) { $ContractPath = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_TEST_ENV_FILE', 'User') }
if (-not $SchemaPath) { $SchemaPath = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_TEST_ENV_SCHEMA_FILE', 'User') }
if (-not $ContractPath -and $env:SQL_SERVER_LAB_DATA_ROOT) {
    $ContractPath = Join-Path $env:SQL_SERVER_LAB_DATA_ROOT 'Exports/TestUmgebung.json'
}
if (-not $ContractPath) {
    $userDataRoot = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', 'User')
    if ($userDataRoot) { $ContractPath = Join-Path $userDataRoot 'Exports/TestUmgebung.json' }
}
if (-not $ContractPath) { throw 'TEST_ENVIRONMENT_CONTRACT_NOT_CONFIGURED' }
$ContractPath = (Resolve-Path -LiteralPath $ContractPath -ErrorAction Stop).Path
if (-not $SchemaPath) { $SchemaPath = Join-Path (Split-Path -Parent $ContractPath) 'TestUmgebung.schema.json' }
$SchemaPath = (Resolve-Path -LiteralPath $SchemaPath -ErrorAction Stop).Path

$raw = Get-Content -LiteralPath $ContractPath -Raw -Encoding utf8
if (-not ($raw | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop)) { throw 'TEST_ENVIRONMENT_SCHEMA_INVALID' }
$contract = $raw | ConvertFrom-Json -Depth 20
if ($contract.groupStatus -ne 'READY') { throw "TEST_ENVIRONMENT_GROUP_NOT_READY: $($contract.groupStatus)" }

$sqlcmd = Get-Command sqlcmd -ErrorAction Stop
$expectedTargets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$results = [System.Collections.Generic.List[object]]::new()

foreach ($environment in @($contract.environments)) {
    if ($environment.status -ne 'READY' -or $environment.runtimeStatus -ne 'READY') {
        throw "TEST_ENVIRONMENT_NOT_READY: $($environment.key)"
    }
    if (-not $environment.host -or -not $environment.port -or -not $environment.password) {
        throw "TEST_ENVIRONMENT_CONNECTION_INCOMPLETE: $($environment.key)"
    }

    $target = "$($environment.host),$($environment.port)"
    [void]$expectedTargets.Add($target)
    $databaseName = "SqlServerLab_Nightly_$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    $query = @"
SET NOCOUNT ON;
SELECT @@VERSION AS VersionDescription;
SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS nvarchar(16)) AS ProductMajorVersion;
SELECT name, state_desc FROM sys.databases ORDER BY database_id;
DECLARE @sql nvarchar(max) = N'CREATE DATABASE ' + QUOTENAME(N'$databaseName');
EXEC sys.sp_executesql @sql;
IF DB_ID(N'$databaseName') IS NULL THROW 51000, 'Nightly database was not created.', 1;
SET @sql = N'ALTER DATABASE ' + QUOTENAME(N'$databaseName') + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(N'$databaseName') + N';';
EXEC sys.sp_executesql @sql;
"@

    Write-Host "Pruefe $($environment.key) ($target)" -ForegroundColor Cyan
    $output = & $sqlcmd.Source -S $target -U ([string]$environment.username) -P ([string]$environment.password) `
        -d master -N -C -b -l 20 -Q $query 2>&1
    $text = @($output) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        $safeDetail = ($text -replace '(?i)(password\s*[=:]\s*)\S+', '$1***').Trim()
        throw "TEST_ENVIRONMENT_SQL_FAILED: $($environment.key): $safeDetail"
    }
    if ($text -notmatch [regex]::Escape([string]$environment.sqlVersion)) {
        throw "TEST_ENVIRONMENT_VERSION_MISMATCH: $($environment.key) erwartet $($environment.sqlVersion)"
    }
    $results.Add([pscustomobject]@{ Key = $environment.key; Target = $target; Status = 'PASS' })
}

Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -ErrorAction Stop
$module = Get-Module SqlServerLab
$cmsAccess = & $module {
    param($RequestedStateRoot,$ExpectedTargets)
    $configuration = Get-LabConnectionCenterCmsConfiguration -StateRoot $RequestedStateRoot
    if (-not $configuration) { return $null }
    $root = if ($RequestedStateRoot) { $RequestedStateRoot } else { Get-LabStateRoot }
    $runDirectory = Join-Path (Join-Path $root 'runs') ([string]$configuration.RunId)
    $connection = Get-Content -LiteralPath (Join-Path $runDirectory 'connection-info.json') -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 20
    $instance = @($connection.instances) | Select-Object -First 1
    $target = ConvertFrom-LabConnectionStringTarget -ConnectionString ([string]$instance.connectionString) -Instance $instance
    [pscustomobject]@{
        Target = $target
        Password = Get-LabSecret -Path $runDirectory -Name 'sa-password'
        ExpectedTargets = @($ExpectedTargets | ForEach-Object {
            ConvertTo-LabCmsServerTarget -Server ([string]$_) -CmsProvider ([string]$configuration.Provider)
        })
    }
} $StateRoot @($expectedTargets)

if (-not $cmsAccess -or -not $cmsAccess.Target -or -not $cmsAccess.Password) {
    throw 'TEST_ENVIRONMENT_CMS_NOT_CONFIGURED'
}

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($cmsAccess.Password)
try {
    $cmsPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $cmsRows = & $sqlcmd.Source -S ([string]$cmsAccess.Target) -U sa -P $cmsPassword -d msdb -N -C -b -l 20 `
        -h -1 -W -Q 'SET NOCOUNT ON; SELECT server_name FROM msdb.dbo.sysmanagement_shared_registered_servers_internal WHERE server_type = 0;' 2>&1
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $cmsPassword = $null
}
if ($LASTEXITCODE -ne 0) { throw 'TEST_ENVIRONMENT_CMS_QUERY_FAILED' }
$registeredTargets = @($cmsRows | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
$missingTargets = @($cmsAccess.ExpectedTargets | Where-Object { $_ -notin $registeredTargets })
if ($missingTargets.Count -gt 0) {
    throw "TEST_ENVIRONMENT_CMS_TARGETS_MISSING: $($missingTargets -join ', '); registriert: $($registeredTargets -join ', ')"
}

$results | Format-Table -AutoSize | Out-Host
Write-Host "AUTOMATISIERTE TESTUMGEBUNGEN: $($results.Count) PASS; CMS konsistent" -ForegroundColor Green
