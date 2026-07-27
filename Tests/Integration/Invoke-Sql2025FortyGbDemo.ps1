#Requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$RemoveAfterValidation
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '..\..\SqlServerLab.psd1') -Force

$runToken = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { [guid]::NewGuid().ToString('N') }
$hostRootC = "C:\SqlServerLab\Runs\$runToken\TempDbC"
$hostRootE = "E:\SqlServerLab\Runs\$runToken\TempDbE"
$stateRoot = "C:\SqlServerLab\State"

foreach ($path in @($hostRootC, $hostRootE, $stateRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$passwordPlain = "Lab!$([guid]::NewGuid().ToString('N'))aA1"
$password = ConvertTo-SecureString $passwordPlain -AsPlainText -Force
$manifestPath = Join-Path $env:RUNNER_TEMP "sql2025-40gb-$runToken.json"

$manifest = [ordered]@{
    '$schema' = '../../Schemas/lab-manifest.schema.json'
    name = "sql2025-40gb-$runToken"
    description = 'SQL Server 2025 Docker validation with 40 GB RAM, split TempDB, two samples and two trace flags.'
    resourceOverrides = [ordered]@{
        maxMemoryMB = 40960
        skipAssessment = $false
    }
    instances = @(
        [ordered]@{
            id = 'primary'
            version = '2025'
            provider = 'docker'
            profile = 'performance'
            drives = @(
                [ordered]@{ id = 'tempdb-c'; containerPath = '/tempdb-c'; hostPath = $hostRootC; type = 'ssd' },
                [ordered]@{ id = 'tempdb-e'; containerPath = '/tempdb-e'; hostPath = $hostRootE; type = 'ssd' }
            )
            serverConfig = [ordered]@{
                memory = [ordered]@{ minMB = 0; maxMB = 36864 }
                traceFlags = @(3226, 7412)
                tempdb = [ordered]@{
                    equalSize = $true
                    dataFiles = @(
                        [ordered]@{ path = '/tempdb-c/tempdev.mdf'; sizeMB = 512; growth = '128MB' },
                        [ordered]@{ path = '/tempdb-e/tempdev2.ndf'; sizeMB = 512; growth = '128MB' }
                    )
                    logFile = [ordered]@{ path = '/tempdb-e/templog.ldf'; sizeMB = 512; growth = '128MB' }
                }
            }
            databases = @(
                [ordered]@{ name = 'AdventureWorks2022'; sample = [ordered]@{ id = 'adventureworks-2022'; variant = 'full' } },
                [ordered]@{ name = 'WideWorldImporters'; sample = [ordered]@{ id = 'wideworldimporters'; variant = 'standard' } }
            )
        }
    )
}

$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8
$lab = $null

try {
    $lab = New-SqlServerLab -Manifest $manifestPath -SaPassword $password -StateRoot $stateRoot
    $instance = $lab.Instances[0]

    docker update --memory 40g $instance.ContainerName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Docker memory update auf 40 GB ist fehlgeschlagen.' }

    $inspect = docker inspect $instance.ContainerName | ConvertFrom-Json -Depth 30
    $memoryBytes = [int64]@($inspect)[0].HostConfig.Memory
    if ($memoryBytes -ne 42949672960) {
        throw "Unerwartetes Docker-Memory-Limit: $memoryBytes Bytes"
    }

    $query = @"
SET NOCOUNT ON;
SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion;
SELECT name, physical_name, type_desc FROM tempdb.sys.database_files ORDER BY file_id;
SELECT name FROM sys.databases WHERE name IN ('AdventureWorks2022','WideWorldImporters') ORDER BY name;
DBCC TRACESTATUS(-1);
"@

    $queryFile = Join-Path $env:RUNNER_TEMP "sql2025-40gb-validation-$runToken.sql"
    Set-Content -LiteralPath $queryFile -Value $query -Encoding utf8
    $output = & sqlcmd -S "127.0.0.1,$($instance.Port)" -U sa -P $passwordPlain -C -b -i $queryFile 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SQL-Validierung fehlgeschlagen:`n$($output | Out-String)" }

    $text = $output | Out-String
    foreach ($required in @('17', '/tempdb-c/tempdev.mdf', '/tempdb-e/tempdev2.ndf', '/tempdb-e/templog.ldf', 'AdventureWorks2022', 'WideWorldImporters', '3226', '7412')) {
        if ($text -notmatch [regex]::Escape($required)) {
            throw "Validierungswert fehlt: $required"
        }
    }

    $result = [ordered]@{
        status = 'PASS'
        runId = $lab.RunId
        container = $instance.ContainerName
        host = $instance.Host
        port = $instance.Port
        sqlVersion = '2025'
        dockerMemoryBytes = $memoryBytes
        sqlMaxMemoryMB = 36864
        tempdbDataFiles = @('/tempdb-c/tempdev.mdf', '/tempdb-e/tempdev2.ndf')
        tempdbLogFile = '/tempdb-e/templog.ldf'
        databases = @('AdventureWorks2022', 'WideWorldImporters')
        traceFlags = @(3226, 7412)
        retained = -not $RemoveAfterValidation.IsPresent
        stateRoot = $stateRoot
        hostPaths = @($hostRootC, $hostRootE)
    }

    $result | ConvertTo-Json -Depth 10
}
finally {
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    if ($RemoveAfterValidation -and $lab) {
        Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot
    }
    $passwordPlain = $null
}
