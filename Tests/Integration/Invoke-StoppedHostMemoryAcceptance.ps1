#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Stop und WSL-Dateicachefreigabe mit eigenem Lab und synthetischem Druck.
.DESCRIPTION
    Benoetigt Windows und einen bereits laufenden lokalen WSL2-Backend.
    Erzeugt einen eigenen 5-GiB-Cachefueller, stoppt ein eigenes SQL-Lab und
    prueft unveraenderte laufende Nachbarn. Nur die Gesamtkapazitaetsmessung
    wird zur Drucksimulation angehoben; freie RAM-Werte bleiben echte Messungen.
    Die Cachefreigabe wirkt auf den gemeinsam verwendeten WSL-Kernel.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText','',Justification='Generated synthetic acceptance password.')]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [Parameter(Mandatory)][string]$EvidenceRoot
)
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'STOP_MEMORY_WINDOWS_REQUIRED'}
$root=(Resolve-Path "$PSScriptRoot/../..").Path
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke')
$locked=$false; $lab=$null; $module=$null; $originalMeasurement=$null; $cacheFile=$null; $target=$null; $stateRoot=$null
$priorState=$env:SQL_SERVER_LAB_STATE; $failure=$null; $cleanupFailure=$null; $result=$null
try {
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'STOP_MEMORY_RUNTIME_RESERVED'}
    if(Test-Path -LiteralPath $EvidenceRoot){throw 'STOP_MEMORY_EVIDENCE_EXISTS'}
    $null=New-Item -ItemType Directory -Path $EvidenceRoot
    $EvidenceRoot=(Resolve-Path $EvidenceRoot).Path
    $stateRoot=Join-Path $EvidenceRoot state; $env:SQL_SERVER_LAB_STATE=$stateRoot
    $tool=& "$root/Tools/Initialize-SqlServerLabHostTools.ps1" -Name $Provider
    if(-not $tool.Available){throw 'STOP_MEMORY_PROVIDER_UNAVAILABLE'}
    $module=Import-Module "$root/SqlServerLab.psd1" -Force -PassThru
    $target=& $module {param($p) Get-LabStopMemoryTarget $p} $Provider
    if(-not $target){throw 'STOP_MEMORY_BACKEND_UNSUPPORTED'}
    $neighbors=@(& $tool.Invocation ps --format '{{.ID}} {{.Status}}')
    if($LASTEXITCODE -ne 0){throw 'STOP_MEMORY_NEIGHBOR_INSPECTION_FAILED'}
    $token=[guid]::NewGuid().ToString('N')
    $password=ConvertTo-SecureString "StopMemory_$token!Aa7" -AsPlainText -Force
    $lab=New-SqlServerLab -Provider $Provider -Version 2025 -MemoryMB 8192 -SaPassword $password -StateRoot $stateRoot -NonInteractive
    # The cache filler lives only in this run's volume and is removed by its cleanup plan.
    $containerIds=@(& $tool.Invocation ps -q --filter "label=sql-server-lab.run-id=$($lab.RunId)")
    if($LASTEXITCODE -ne 0 -or $containerIds.Count -ne 1){throw 'STOP_MEMORY_OWN_CONTAINER_AMBIGUOUS'}
    $cacheFile="/var/opt/mssql/stop-memory-$token.bin"
    $seedResult=& $module {param($invocation,$id,$path) Invoke-LabProgressNativeCommand -FilePath $invocation -ArgumentList @('exec',$id,'dd','if=/dev/zero',"of=$path",'bs=1M','count=5120','status=none') -Phase Cleanup -TimeoutSeconds 120} $tool.Invocation $containerIds[0] $cacheFile
    if($seedResult.ExitCode -ne 0){throw 'STOP_MEMORY_CACHE_SEED_FAILED'}
    $originalMeasurement=& $module {${function:Get-LabStopHostMemory}}
    & $module { Set-Item function:script:Get-LabStopHostMemory {
        $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        [pscustomobject]@{TotalMB=[long]($os.TotalVisibleMemorySize/1024)*10;AvailableMB=[long]($os.FreePhysicalMemory/1024)}
    } }
    $result=Stop-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false
    if($result.Status -ne 'STOPPED' -or -not $result.HostMemory.CacheReleaseRequested -or
        $result.HostMemory.CacheAfterMB -ge $result.HostMemory.CacheBeforeMB){throw 'STOP_MEMORY_NATIVE_POSTCONDITION_FAILED'}
    & $module {param($original) Set-Item function:script:Get-LabStopHostMemory $original} $originalMeasurement
    $originalMeasurement=$null
    $afterIds=@(& $tool.Invocation ps --format '{{.ID}}')
    if($LASTEXITCODE -ne 0){throw 'STOP_MEMORY_NEIGHBOR_INSPECTION_FAILED'}
    foreach($neighbor in $neighbors){if(($neighbor -split ' ')[0] -notin $afterIds){throw 'STOP_MEMORY_NEIGHBOR_STOPPED'}}
    # A second public stop is a no-op and must not repeat shared cache maintenance.
    $again=Stop-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false
    if($again.Action -ne 'SKIPPED'){throw 'STOP_MEMORY_NOOP_FAILED'}
} catch {$failure=$_}
finally {
    if($originalMeasurement -and $module){& $module {param($original) Set-Item function:script:Get-LabStopHostMemory $original} $originalMeasurement}
    try {
        if($stateRoot -and (Test-Path "$stateRoot/runs")){
            foreach($run in Get-ChildItem "$stateRoot/runs" -Directory){
                $cleanup=Remove-SqlServerLab -RunId $run.Name -StateRoot $stateRoot -Force -Confirm:$false
                $state=Get-Content (Join-Path $run.FullName 'run-state.json') -Raw | ConvertFrom-Json
                if($state.state -ne 'REMOVED'){throw 'STOP_MEMORY_CLEANUP_FAILED'}
            }
        }
    } catch {$cleanupFailure=$_}
    $env:SQL_SERVER_LAB_STATE=$priorState
    if($locked){$mutex.ReleaseMutex()}; $mutex.Dispose()
}
if($cleanupFailure){throw $cleanupFailure}
if($failure){throw $failure}
[pscustomobject]@{Status='PASS';Provider=$Provider;Pressure='SYNTHETIC_TOTAL_CAPACITY';HostMemory=$result.HostMemory;NeighborsPreserved=$true;Cleanup='PASS'} |
    ConvertTo-Json -Depth 6 | Set-Content (Join-Path $EvidenceRoot 'result.json')
Write-Host "PASS: $Provider public Stop, native cache release, neighbor preservation, no-op and cleanup"
