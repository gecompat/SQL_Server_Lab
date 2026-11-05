#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft denselben persistenten Labnamen mit zwei verschiedenen SA-Passwoertern.
.DESCRIPTION
    Erstellt zwei eigene SQL-2025-Labs seriell ueber den oeffentlichen Core.
    Der erste Store bleibt nach Remove erhalten; die zweite Neuanlage muss
    frische SQL-Systemdaten und das neue Passwort verwenden. Alle eigenen
    Container, retained Volumes und Tempdateien werden anschliessend entfernt.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$token = [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-name-reuse-$Provider-$token"
$stateRoot = Join-Path $testRoot 'State'
$dataRoot = Join-Path $testRoot 'Lab_Data'
$labName = "name-reuse-$($token.Substring(0,12))"
$previousDataRoot = $env:SQL_SERVER_LAB_DATA_ROOT
$runs = [Collections.Generic.List[string]]::new()
$volumes = [Collections.Generic.List[object]]::new()
$runtimeInvocation = $null
$module = $null
$passed = 0
$cleanupSucceeded = $false
$primaryError = $null
$mutexName = if ($IsWindows) { 'Global\SQL_Server_Lab_Runtime_Smoke' } else { 'SQL_Server_Lab_Runtime_Smoke' }
$mutex = [Threading.Mutex]::new($false, $mutexName)
$acquired = $false

function Assert-NameReuse {
    param([bool]$Condition, [string]$Description)
    if (-not $Condition) { throw "PERSISTENT_NAME_REUSE_FAILED: $Description" }
    $script:passed++
    Write-Host "PASS: $Description"
}

function Invoke-NameReuseRuntime {
    param([string[]]$Arguments)
    $output = @(& $runtimeInvocation @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'PERSISTENT_NAME_REUSE_RUNTIME_FAILED' }
    return $output
}

function Get-NameReuseSqlBinding {
    param([string]$RunId)
    $connectionPath = Join-Path $stateRoot "runs/$RunId/connection-info.json"
    if (-not (Test-Path -LiteralPath $connectionPath)) { return $null }
    $connection = Get-Content -LiteralPath $connectionPath -Raw | ConvertFrom-Json -Depth 20
    $storage = @($connection.instances)[0].persistentStorage
    if (-not $storage.containerVolume -or -not $storage.persistentStorageId) { return $null }
    $binding = [PSCustomObject]@{ RunId=$RunId; VolumeName=[string]$storage.containerVolume; StorageId=[string]$storage.persistentStorageId }
    $volumes.Add($binding)
    return $binding
}

try {
    $acquired = $mutex.WaitOne(0)
    if (-not $acquired) { throw 'PERSISTENT_NAME_REUSE_RUNTIME_BUSY' }
    $tool = & (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider
    if (-not $tool.Available) { throw 'PERSISTENT_NAME_REUSE_TOOL_UNAVAILABLE' }
    $runtimeInvocation = [string]$tool.Invocation
    $null = Invoke-NameReuseRuntime -Arguments @('image','inspect','mcr.microsoft.com/mssql/server:2025-latest')
    $beforeContainers = @(Invoke-NameReuseRuntime -Arguments @('ps','-aq','--no-trunc') | Sort-Object)
    $beforeVolumes = @(Invoke-NameReuseRuntime -Arguments @('volume','ls','--format','{{.Name}}') | Sort-Object)
    $null = & (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabDataRoot.ps1') -RootPath $dataRoot -LabId $labName
    $env:SQL_SERVER_LAB_DATA_ROOT = $dataRoot
    $module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $firstPassword = ConvertTo-SecureString ('A!7_' + [Guid]::NewGuid().ToString('N')) -AsPlainText -Force
    $secondPassword = ConvertTo-SecureString ('B!8_' + [Guid]::NewGuid().ToString('N')) -AsPlainText -Force
    $create = @{ Version='2025'; Provider=$Provider; LabName=$labName; PersistentData=$true; DataRoot=$dataRoot; StateRoot=$stateRoot; Profile='compact'; AutoStart='off' }
    $first = New-SqlServerLab @create -SaPassword $firstPassword
    $runs.Add([string]$first.RunId)
    $oldBinding = Get-NameReuseSqlBinding -RunId $first.RunId
    if (-not $oldBinding) { throw 'PERSISTENT_NAME_REUSE_BINDING_MISSING' }
    $queryPath = Join-Path $testRoot 'evidence.sql'
    [IO.File]::WriteAllText($queryPath, 'CREATE DATABASE NameReuseEvidence;')
    $sql = Invoke-SqlServerLabScript -RunId $first.RunId -StateRoot $stateRoot -SaPassword $firstPassword -ScriptPath $queryPath
    Assert-NameReuse $sql.Success 'Erstes Lab authentifiziert sich und erzeugt eigenen Datenmarker'
    $removed = Remove-SqlServerLab -RunId $first.RunId -StateRoot $stateRoot -Force
    Assert-NameReuse ($removed.Status -eq 'REMOVED') 'Erster Run ist regulaer entfernt'
    $oldInspection = (@(Invoke-NameReuseRuntime -Arguments @('volume','inspect',$oldBinding.VolumeName)) -join "`n") | ConvertFrom-Json
    Assert-NameReuse ($oldInspection[0].Labels.'sql-server-lab.persistent-storage-id' -ceq $oldBinding.StorageId) 'Alter Store bleibt mit seiner unveraenderten Speicher-ID erhalten'

    $second = New-SqlServerLab @create -SaPassword $secondPassword
    $runs.Add([string]$second.RunId)
    $newBinding = Get-NameReuseSqlBinding -RunId $second.RunId
    if (-not $newBinding) { throw 'PERSISTENT_NAME_REUSE_BINDING_MISSING' }
    Assert-NameReuse ($oldBinding.VolumeName -cne $newBinding.VolumeName -and $oldBinding.StorageId -cne $newBinding.StorageId) 'Gleicher Labname erhaelt einen eigenen neuen SQL-Systemstore'
    [IO.File]::WriteAllText($queryPath, "IF DB_ID(N'NameReuseEvidence') IS NOT NULL THROW 51000, 'Alter SQL-Systemzustand wiederverwendet', 1; SELECT 1;")
    $sql = Invoke-SqlServerLabScript -RunId $second.RunId -StateRoot $stateRoot -SaPassword $secondPassword -ScriptPath $queryPath
    Assert-NameReuse $sql.Success 'Neues Passwort funktioniert an frischen SQL-Systemdaten'
    $null = Stop-SqlServerLab -RunId $second.RunId -StateRoot $stateRoot
    $null = Start-SqlServerLab -RunId $second.RunId -StateRoot $stateRoot
    $sql = Invoke-SqlServerLabScript -RunId $second.RunId -StateRoot $stateRoot -SaPassword $secondPassword -ScriptPath $queryPath
    Assert-NameReuse $sql.Success 'Stop und Start desselben Runs behalten den neuen SQL-Systemstore und sein Passwort'
    $status = Get-SqlServerLab -RunId $second.RunId -StateRoot $stateRoot
    $endpoint = @($status.Instances)[0]
    $connection = [System.Data.SqlClient.SqlConnection]::new("Server=$($endpoint.Host),$($endpoint.Port);Database=master;Encrypt=True;TrustServerCertificate=True;Connect Timeout=5;Pooling=False")
    $connection.Credential = [System.Data.SqlClient.SqlCredential]::new('sa', $firstPassword)
    $oldPasswordRejected = $false
    try { $connection.Open() }
    catch [System.Data.SqlClient.SqlException] { $oldPasswordRejected = $_.Exception.Number -eq 18456 }
    finally { $connection.Dispose() }
    Assert-NameReuse $oldPasswordRejected 'Bisheriges SA-Passwort wird am neuen Lab abgewiesen'
    $oldInspection = (@(Invoke-NameReuseRuntime -Arguments @('volume','inspect',$oldBinding.VolumeName)) -join "`n") | ConvertFrom-Json
    Assert-NameReuse ($oldInspection[0].Labels.'sql-server-lab.persistent-storage-id' -ceq $oldBinding.StorageId) 'Neuanlage laesst den alten retained Store erhalten'
}
catch { $primaryError = $_; throw }
finally {
    try {
        if ($module -and (Test-Path -LiteralPath (Join-Path $stateRoot 'runs'))) {
            # Auch ein vor der Rueckgabe fehlgeschlagener eigener Run braucht Cleanup.
            $ownRuns = & $module {
                param($root)
                foreach ($directory in @(Get-ChildItem -LiteralPath (Join-Path $root 'runs') -Directory)) {
                    Get-LabRunState -RunId $directory.Name -StateRoot $root
                }
            } $stateRoot
            foreach ($run in @($ownRuns)) {
                if ([string]$run.metadata.name -cne $labName) { throw 'PERSISTENT_NAME_REUSE_RUN_SCOPE_INVALID' }
                if ([string]$run.runId -notin $runs) { $runs.Add([string]$run.runId) }
                if ([string]$run.runId -notin @($volumes.RunId)) { $null = Get-NameReuseSqlBinding -RunId $run.runId }
                $result = Remove-SqlServerLab -RunId $run.runId -StateRoot $stateRoot -Force
                if ($result.Status -ne 'REMOVED') { throw 'PERSISTENT_NAME_REUSE_RUN_CLEANUP_FAILED' }
            }
            foreach ($binding in $volumes) {
                if ($binding.VolumeName -in $beforeVolumes) { throw 'PERSISTENT_NAME_REUSE_PREEXISTING_VOLUME' }
                $inspection = (@(Invoke-NameReuseRuntime -Arguments @('volume','inspect',$binding.VolumeName)) -join "`n") | ConvertFrom-Json
                if ([string]$inspection[0].Labels.'sql-server-lab.persistent-storage-id' -cne $binding.StorageId) { throw 'PERSISTENT_NAME_REUSE_VOLUME_SCOPE_INVALID' }
                $currentVolumes = @(Invoke-NameReuseRuntime -Arguments @('volume','ls','--format','{{.Name}}'))
                if ($binding.VolumeName -in $currentVolumes) { $null = Invoke-NameReuseRuntime -Arguments @('volume','rm',$binding.VolumeName) }
            }
            $afterContainers = @(Invoke-NameReuseRuntime -Arguments @('ps','-aq','--no-trunc') | Sort-Object)
            $afterVolumes = @(Invoke-NameReuseRuntime -Arguments @('volume','ls','--format','{{.Name}}') | Sort-Object)
            if (($beforeContainers -join '|') -cne ($afterContainers -join '|') -or ($beforeVolumes -join '|') -cne ($afterVolumes -join '|')) {
                throw 'PERSISTENT_NAME_REUSE_INVENTORY_CHANGED'
            }
        }
        $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
        $expectedRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) "sql-lab-name-reuse-$Provider-$token"))
        if ($resolvedRoot -cne $expectedRoot) { throw 'PERSISTENT_NAME_REUSE_TEMP_SCOPE_INVALID' }
        if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
        $cleanupSucceeded = $true
    }
    catch {
        if ($primaryError) { Write-Warning ("NAME REUSE PRIMARY FAILURE: " + $primaryError.Exception.Message) }
        throw
    }
    finally {
        $env:SQL_SERVER_LAB_DATA_ROOT = $previousDataRoot
        if ($firstPassword) { $firstPassword.Dispose() }
        if ($secondPassword) { $secondPassword.Dispose() }
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        Write-Host "NAME REUSE CLEANUP: $cleanupSucceeded"
    }
}
Write-Host "PERSISTENT NAME REUSE: $passed PASS"
