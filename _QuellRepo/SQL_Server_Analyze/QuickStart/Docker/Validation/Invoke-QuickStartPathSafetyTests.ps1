[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:QuickStartRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $script:QuickStartRoot '../..'))
$script:EnvPath = Join-Path $script:QuickStartRoot '.env.synthetic-test'
$script:ComposePath = Join-Path $script:QuickStartRoot 'docker-compose.yml'
$script:SlowIoComposePath = Join-Path $script:QuickStartRoot 'docker-compose.slow-io.yml'
$script:MarkerFileName = '.sql-server-analyze-quickstart.json'
$script:MarkerOwner = 'SQL_SERVER_ANALYZE_QUICKSTART'
$script:IsWindowsHost = $true
$script:PathComparison = [StringComparison]::OrdinalIgnoreCase

. (Join-Path $script:QuickStartRoot 'Internal/Common.ps1')
. (Join-Path $script:QuickStartRoot 'Internal/PathSafety.ps1')
. (Join-Path $script:QuickStartRoot 'Internal/Configuration.ps1')

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock] $ScriptBlock,
        [Parameter(Mandatory)][string] $Description
    )

    try {
        & $ScriptBlock
    }
    catch {
        return
    }
    throw "Expected failure was not raised: $Description"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ssa-quickstart-contract-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null

    $emptyRoot = Join-Path $testRoot 'empty'
    [IO.Directory]::CreateDirectory($emptyRoot) | Out-Null
    $resolvedEmptyRoot = Assert-SafeEmptyRoot -Path $emptyRoot -Purpose 'Test'
    if (-not $resolvedEmptyRoot.Equals([IO.Path]::GetFullPath($emptyRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'An empty test root was not resolved as expected.'
    }

    $nonEmptyRoot = Join-Path $testRoot 'non-empty'
    [IO.Directory]::CreateDirectory($nonEmptyRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $nonEmptyRoot 'existing.txt'), 'synthetic')
    Assert-Throws -Description 'non-empty root' -ScriptBlock {
        Assert-SafeEmptyRoot -Path $nonEmptyRoot -Purpose 'Test' | Out-Null
    }

    $driveRoot = [IO.Path]::GetPathRoot($testRoot)
    Assert-Throws -Description 'drive root' -ScriptBlock {
        Assert-SafeEmptyRoot -Path $driveRoot -Purpose 'Test' | Out-Null
    }
    Assert-Throws -Description 'Windows directory descendant' -ScriptBlock {
        Assert-SafeEmptyRoot -Path (Join-Path $env:SystemRoot 'SyntheticQuickStartProbe') -Purpose 'Test' | Out-Null
    }
    Assert-Throws -Description 'repository descendant' -ScriptBlock {
        Assert-SafeEmptyRoot -Path (Join-Path $script:RepositoryRoot 'SyntheticQuickStartProbe') -Purpose 'Test' | Out-Null
    }
    Assert-Throws -Description 'overlapping roots' -ScriptBlock {
        Assert-RootsDoNotOverlap -Paths @((Join-Path $testRoot 'a'), (Join-Path $testRoot 'a/child'))
    }

    $labRoot = Join-Path $testRoot 'managed'
    $dataRoot = Join-Path $labRoot 'data'
    $logRoot = Join-Path $labRoot 'log'
    Initialize-ManagedRoots `
        -ScopeId 'a1b2c3d4e5f6' `
        -StorageLayout 'SINGLE_ROOT' `
        -LabRoot $labRoot `
        -DataRoot $dataRoot `
        -LogRoot $logRoot

    $values = @{
        QUICKSTART_SCHEMA_VERSION = '1'
        QUICKSTART_SCOPE_ID = 'a1b2c3d4e5f6'
        QUICKSTART_RUNTIME_MODE = 'DOCKER_DESKTOP_WINDOWS'
        COMPOSE_PROJECT_NAME = 'ssa-quickstart-a1b2c3d4e5f6'
        COMPOSE_PROFILES = 'sql2019,sql2022,sql2025'
        SQL_VERSIONS = '2019,2022,2025'
        BIND_ADDRESS = '127.0.0.1'
        MSSQL_SA_PASSWORD = 'SyntheticPassword-42!'
        MSSQL_COLLATION = 'SQL_Latin1_General_CP1_CS_AS'
        MSSQL_AGENT_ENABLED = 'true'
        FRAMEWORK_DATABASE = 'LabAnalyze'
        INSTALL_FRAMEWORK = 'true'
        RESOURCE_PROFILE = 'COMPACT'
        CONTAINER_CPUS = '2.0'
        CONTAINER_MEMORY = '3g'
        SQL_MEMORY_LIMIT_MB = '2048'
        STORAGE_LAYOUT = 'SINGLE_ROOT'
        LAB_ROOT = $labRoot
        DATA_ROOT = $dataRoot
        LOG_ROOT = $logRoot
        BACKUP_ROOT = Join-Path $labRoot 'backup'
        INSTALLER_ROOT = Join-Path $labRoot 'control/installer'
        SQL2019_PORT = '14331'
        SQL2022_PORT = '14332'
        SQL2025_PORT = '14335'
        SQL2019_DATA_DIR = Join-Path $dataRoot '2019'
        SQL2019_LOG_DIR = Join-Path $logRoot '2019'
        SQL2019_BACKUP_DIR = Join-Path $labRoot 'backup/2019'
        SQL2022_DATA_DIR = Join-Path $dataRoot '2022'
        SQL2022_LOG_DIR = Join-Path $logRoot '2022'
        SQL2022_BACKUP_DIR = Join-Path $labRoot 'backup/2022'
        SQL2025_DATA_DIR = Join-Path $dataRoot '2025'
        SQL2025_LOG_DIR = Join-Path $logRoot '2025'
        SQL2025_BACKUP_DIR = Join-Path $labRoot 'backup/2025'
        SQL2019_IMAGE = 'mcr.microsoft.com/mssql/server:2019-latest'
        SQL2022_IMAGE = 'mcr.microsoft.com/mssql/server:2022-latest'
        SQL2025_IMAGE = 'mcr.microsoft.com/mssql/server:2025-latest'
        IO_PROFILE = 'NORMAL'
        SLOW_IO_DEVICE = ''
        SLOW_IO_READ_BPS = '20mb'
        SLOW_IO_WRITE_BPS = '10mb'
    }
    Assert-ManagedRoots -Env $values

    $tampered = [hashtable] $values.Clone()
    $tampered.SQL2019_DATA_DIR = Join-Path $env:SystemRoot 'SyntheticQuickStartProbe'
    Assert-Throws -Description 'tampered data path outside marker scope' -ScriptBlock {
        Assert-ManagedRoots -Env $tampered
    }

    Write-Host 'QuickStart path-safety contract: PASS'
}
finally {
    if (Test-Path -LiteralPath $script:EnvPath -PathType Leaf) {
        Remove-Item -LiteralPath $script:EnvPath -Force
    }
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
