#Requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$RemoveAfterValidation
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runtimeRoot = Join-Path $repositoryRoot '.runtime'
$stateRoot = Join-Path $runtimeRoot 'state'
$secretsDirectory = Join-Path $runtimeRoot 'secrets'
$passwordFile = Join-Path $secretsDirectory 'active-test-session-sa-password.txt'
$sessionFile = Join-Path $secretsDirectory 'active-test-session.json'
$sessionMutex = [System.Threading.Mutex]::new($false, 'Global\SQL_Server_Lab_TestSessionPassword')
$sessionLockAcquired = $false

$env:SQL_SERVER_LAB_STATE = $stateRoot
Import-Module (Join-Path $repositoryRoot 'SqlServerLab.psd1') -Force

$runToken = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { [guid]::NewGuid().ToString('N') }

# Die geforderte Verteilung auf C: und E: verwendet auf jedem Laufwerk ein
# eigenes, eindeutig dem Testlauf zugeordnetes Unterverzeichnis. Niemals wird
# direkt in ein Laufwerksroot geschrieben.
$hostRootC = "C:\SQL_Server_Lab_Runtime\Runs\$runToken\TempDbC"
$hostRootE = "E:\SQL_Server_Lab_Runtime\Runs\$runToken\TempDbE"

function Test-LabRunActive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId)

    $containerId = docker ps -a -q --filter "label=sql-server-lab.run-id=$RunId" 2>$null |
        Select-Object -First 1
    return -not [string]::IsNullOrWhiteSpace([string]$containerId)
}

function New-TestSessionPassword {
    [CmdletBinding()]
    param([ValidateRange(30, 128)][int]$Length = 40)

    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digits = '23456789'
    $special = '!#%+,-.:=@_'
    $alphabet = $upper + $lower + $digits + $special
    $characters = [System.Collections.Generic.List[char]]::new()
    $characters.Add($upper[(Get-Random -Maximum $upper.Length)])
    $characters.Add($lower[(Get-Random -Maximum $lower.Length)])
    $characters.Add($digits[(Get-Random -Maximum $digits.Length)])
    $characters.Add($special[(Get-Random -Maximum $special.Length)])
    while ($characters.Count -lt $Length) {
        $characters.Add($alphabet[(Get-Random -Maximum $alphabet.Length)])
    }
    return -join ($characters | Sort-Object { Get-Random })
}

function Set-TestSessionSecretAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Paths)

    if (-not $IsWindows) { return }
    $runnerSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        & icacls $path /inheritance:r | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "ACL-Vererbung konnte fuer '$path' nicht deaktiviert werden." }
        & icacls $path /grant:r "*$runnerSid`:(F)" '*S-1-5-32-544:(F)' '*S-1-5-18:(F)' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "ACL konnte fuer '$path' nicht gesetzt werden." }
    }
}

function Get-TestSessionPassword {
    [CmdletBinding()]
    param()

    New-Item -ItemType Directory -Path $secretsDirectory -Force | Out-Null
    $session = $null
    if (Test-Path -LiteralPath $sessionFile -PathType Leaf) {
        try { $session = Get-Content -LiteralPath $sessionFile -Raw -Encoding utf8 | ConvertFrom-Json }
        catch { Write-Warning "Lokale Testsession-Metadaten werden erneuert: $($_.Exception.Message)" }
    }

    $activeRunIds = @()
    if ($session -and $session.runIds) {
        $activeRunIds = @($session.runIds | Where-Object { $_ -and (Test-LabRunActive -RunId ([string]$_)) })
    }

    $reuseExisting = $activeRunIds.Count -gt 0 -and (Test-Path -LiteralPath $passwordFile -PathType Leaf)
    if ($reuseExisting) {
        $passwordPlain = (Get-Content -LiteralPath $passwordFile -Raw -Encoding utf8).Trim()
        if ($passwordPlain.Length -lt 30) { throw 'Aktive Testsession besitzt eine ungueltige Passwortdatei.' }
    }
    else {
        $passwordPlain = New-TestSessionPassword -Length 40
        Set-Content -LiteralPath $passwordFile -Value $passwordPlain -Encoding utf8 -NoNewline
        $session = [ordered]@{
            sessionId = [guid]::NewGuid().ToString('N')
            createdAt = [DateTime]::UtcNow.ToString('o')
            runIds = @()
        }
    }

    $session.runIds = @($activeRunIds)
    $session | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $sessionFile -Encoding utf8
    Set-TestSessionSecretAcl -Paths @($secretsDirectory, $passwordFile, $sessionFile)

    return [PSCustomObject]@{
        Password = $passwordPlain
        SessionId = [string]$session.sessionId
        Reused = $reuseExisting
    }
}

function Add-TestSessionRun {
    param([Parameter(Mandatory)][string]$RunId)
    $session = Get-Content -LiteralPath $sessionFile -Raw -Encoding utf8 | ConvertFrom-Json
    $activeRunIds = @($session.runIds | Where-Object { $_ -and (Test-LabRunActive -RunId ([string]$_)) })
    if ($RunId -notin $activeRunIds) { $activeRunIds += $RunId }
    $session.runIds = @($activeRunIds | Sort-Object -Unique)
    $session | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $sessionFile -Encoding utf8
    Set-TestSessionSecretAcl -Paths @($sessionFile)
}

function Remove-TestSessionRun {
    param([Parameter(Mandatory)][string]$RunId)
    if (-not (Test-Path -LiteralPath $sessionFile -PathType Leaf)) { return }
    $session = Get-Content -LiteralPath $sessionFile -Raw -Encoding utf8 | ConvertFrom-Json
    $session.runIds = @($session.runIds | Where-Object {
        $_ -and ([string]$_ -ne $RunId) -and (Test-LabRunActive -RunId ([string]$_))
    })
    $session | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $sessionFile -Encoding utf8
    Set-TestSessionSecretAcl -Paths @($sessionFile)
}

function Wait-TestSqlReady {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Password)
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    do {
        $null = & sqlcmd -S "127.0.0.1,$Port" -U sa -P $Password -C -b -Q 'SELECT 1' 2>$null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'SQL Server wurde nach dem TempDB-Neustart nicht rechtzeitig bereit.'
}

foreach ($path in @($runtimeRoot, $stateRoot, $hostRootC, $hostRootE)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

try {
    $sessionLockAcquired = $sessionMutex.WaitOne([TimeSpan]::FromMinutes(5))
    if (-not $sessionLockAcquired) { throw 'Testsession-Passwortlock konnte nicht erworben werden.' }
    $testSession = Get-TestSessionPassword
}
finally {
    if ($sessionLockAcquired) {
        $sessionMutex.ReleaseMutex()
        $sessionLockAcquired = $false
    }
}

$passwordPlain = $testSession.Password
$password = ConvertTo-SecureString $passwordPlain -AsPlainText -Force
$manifestPath = Join-Path $env:RUNNER_TEMP "sql2025-40gb-$runToken.json"

$manifest = [ordered]@{
    '$schema' = '../../Schemas/lab-manifest.schema.json'
    name = "sql2025-40gb-$runToken"
    description = 'SQL Server 2025 Docker validation with 40 GB RAM, split TempDB, two samples and two trace flags.'
    resourceOverrides = [ordered]@{ maxMemoryMB = 40960; skipAssessment = $false }
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
                        [ordered]@{ path = '/tempdb-c/tempdev.mdf'; sizeMB = 8; growth = '128MB' },
                        [ordered]@{ path = '/tempdb-e/tempdev2.ndf'; sizeMB = 8; growth = '128MB' }
                    )
                    logFile = [ordered]@{ path = '/tempdb-e/templog.ldf'; sizeMB = 8; growth = '128MB' }
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

    $sessionLockAcquired = $sessionMutex.WaitOne([TimeSpan]::FromMinutes(5))
    if (-not $sessionLockAcquired) { throw 'Testsession-Passwortlock fuer Run-Registrierung nicht erhalten.' }
    try { Add-TestSessionRun -RunId $lab.RunId }
    finally {
        $sessionMutex.ReleaseMutex()
        $sessionLockAcquired = $false
    }

    docker update --memory 40g $instance.ContainerName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Docker memory update auf 40 GB ist fehlgeschlagen.' }

    # Erst nach einem Neustart verwendet tempdb die neuen physischen Pfade.
    docker restart $instance.ContainerName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Container-Neustart fuer TempDB-Aktivierung ist fehlgeschlagen.' }
    Wait-TestSqlReady -Port $instance.Port -Password $passwordPlain

    # DBCC TRACEON ist nicht neustartpersistent und wird fuer den aktiven Testzustand erneut gesetzt.
    $query = @"
SET NOCOUNT ON;
DBCC TRACEON (3226, 7412, -1) WITH NO_INFOMSGS;
SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion;
SELECT name, physical_name, type_desc FROM tempdb.sys.database_files ORDER BY file_id;
SELECT name FROM sys.databases WHERE name IN ('AdventureWorks2022','WideWorldImporters') ORDER BY name;
DBCC TRACESTATUS(-1);
"@
    $queryFile = Join-Path $env:RUNNER_TEMP "sql2025-40gb-validation-$runToken.sql"
    Set-Content -LiteralPath $queryFile -Value $query -Encoding utf8
    $output = & sqlcmd -S "127.0.0.1,$($instance.Port)" -U sa -P $passwordPlain -C -b -i $queryFile 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SQL-Validierung fehlgeschlagen:`n$($output | Out-String)" }

    $inspect = docker inspect $instance.ContainerName | ConvertFrom-Json -Depth 30
    $memoryBytes = [int64]@($inspect)[0].HostConfig.Memory
    if ($memoryBytes -ne 42949672960) { throw "Unerwartetes Docker-Memory-Limit: $memoryBytes Bytes" }

    $text = $output | Out-String
    foreach ($required in @('17', '/tempdb-c/tempdev.mdf', '/tempdb-e/tempdev2.ndf', '/tempdb-e/templog.ldf', 'AdventureWorks2022', 'WideWorldImporters', '3226', '7412')) {
        if ($text -notmatch [regex]::Escape($required)) { throw "Validierungswert fehlt: $required" }
    }

    [ordered]@{
        status = 'PASS'
        runId = $lab.RunId
        container = $instance.ContainerName
        port = $instance.Port
        sqlVersion = '2025'
        dockerMemoryBytes = $memoryBytes
        sqlMaxMemoryMB = 36864
        dataRoot = $runtimeRoot
        stateRoot = $stateRoot
        tempdbDataFiles = @('/tempdb-c/tempdev.mdf', '/tempdb-e/tempdev2.ndf')
        tempdbLogFile = '/tempdb-e/templog.ldf'
        hostPaths = @($hostRootC, $hostRootE)
        databases = @('AdventureWorks2022', 'WideWorldImporters')
        traceFlags = @(3226, 7412)
        retained = -not $RemoveAfterValidation.IsPresent
        passwordSessionId = $testSession.SessionId
        passwordReused = $testSession.Reused
        passwordFile = $passwordFile
    } | ConvertTo-Json -Depth 10
}
finally {
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    if ($RemoveAfterValidation -and $lab) {
        Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot
        $sessionLockAcquired = $sessionMutex.WaitOne([TimeSpan]::FromMinutes(5))
        if ($sessionLockAcquired) {
            try { Remove-TestSessionRun -RunId $lab.RunId }
            finally {
                $sessionMutex.ReleaseMutex()
                $sessionLockAcquired = $false
            }
        }
    }
    $passwordPlain = $null
    $password = $null
    $testSession = $null
    $sessionMutex.Dispose()
}
