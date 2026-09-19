#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prueft SQL-2025-Reconnect an einem neuen, operationseigenen Windows-Clone.
.DESCRIPTION
    Verwendet ausschliesslich vorhandene hostOnly-Infrastruktur. Der Parent
    haelt den gemeinsamen Runtime-Lock, begrenzt den Kindprozess und bereinigt
    nur seine Operation nach bestaetigtem Prozessende. Die Quelle bleibt erhalten.
    Bei unbestaetigter Terminierung bleibt Recovery explizit erforderlich.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$CloneSourceRunId,
    [Parameter(Mandatory)][string]$MediaRoot,
    [ValidateSet('Enterprise','Standard','Eval')][string]$MediaEdition='Enterprise',
    [string]$StateRoot,
    [ValidateRange(60,10800)][int]$TimeoutSeconds=5400
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/HyperVNetworkReconnectSupervisor.ps1')
$operationId='local-hv-network-'+[guid]::NewGuid().ToString('N')
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-network-'+[guid]::NewGuid().ToString('N'))
$workerLog=Join-Path $repoRoot ('.artifacts/test-runs/hyperv-network-worker-'+$operationId+'.log')
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke')
$acquired=$false;$ownsOperation=$false;$terminated=$true;$child=$null;$module=$null
$primary=$null;$cleanupFailures=[Collections.Generic.List[Exception]]::new()
try {
    try {$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(1))} catch [Threading.AbandonedMutexException] {$acquired=$true}
    if(-not $acquired){throw 'HYPERV_NETWORK_ACCEPTANCE_HOST_LOCK_TIMEOUT'}
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    if(-not $StateRoot){$StateRoot=& $module {Get-LabStateRoot}}
    if(& $module {param($Op,$Root)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $Root} $operationId $StateRoot){throw 'HYPERV_NETWORK_ACCEPTANCE_OPERATION_ALREADY_OWNED'}
    $ownsOperation=$true
    $null=New-Item -ItemType Directory -Path $tempRoot
    $manifest=Join-Path $tempRoot 'manifest.json'
    [ordered]@{
        name='network-acceptance';automation=@{mode='unattended'}
        instances=@(@{id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off'
            network=@{intent='hostOnly';exposure='host'}
            windowsActivation=@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='VerifyOnly';EgressPolicy='Denied'}
            hyperv=@{memoryStartupMB=6144;processorCount=4;sqlPort=1433;guestPasswordMode='prompt'}})
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifest -Encoding utf8
    if(-not (Test-SqlServerLabManifest -Path $manifest).IsValid){throw 'HYPERV_NETWORK_ACCEPTANCE_MANIFEST_INVALID'}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=Join-Path $PSHOME 'pwsh.exe';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.Environment['SQL_SERVER_LAB_STATE']=$StateRoot
    foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $repoRoot 'Tests/Common/HyperVNetworkReconnectWorker.ps1'),
        '-CloneSourceRunId',$CloneSourceRunId.ToString(),'-ManifestPath',$manifest,'-OperationId',$operationId,
        '-StateRoot',$StateRoot,'-MediaRoot',$MediaRoot,'-MediaEdition',$MediaEdition)){$start.ArgumentList.Add($argument)}
    $child=[Diagnostics.Process]::Start($start);$terminated=$false
    $result=Wait-HyperVNetworkAcceptanceChild -Process $child -TimeoutSeconds $TimeoutSeconds
    $workerOutput=$child.StandardOutput.ReadToEnd()
    $workerError=$child.StandardError.ReadToEnd()
    [IO.File]::WriteAllText($workerLog,($workerOutput+$workerError),[Text.UTF8Encoding]::new($false))
    $terminated=$result.Terminated
    if(-not $terminated){throw 'HYPERV_NETWORK_ACCEPTANCE_TERMINATION_UNCONFIRMED_RECOVERY_REQUIRED'}
    if($result.TimedOut){throw 'HYPERV_NETWORK_ACCEPTANCE_TIMEOUT'}
    if($null -eq $result.ExitCode -or $result.ExitCode -ne 0){throw 'HYPERV_NETWORK_ACCEPTANCE_CHILD_FAILED'}
}
catch {$primary=$_.Exception}
finally {
    if($ownsOperation -and $terminated){
        try {Remove-HyperVNetworkAcceptanceOwnedRun -Module $module -OperationId $operationId -SourceRunId $CloneSourceRunId -StateRoot $StateRoot}
        catch {$cleanupFailures.Add($_.Exception)}
    }
    if($terminated -and $cleanupFailures.Count -eq 0 -and (Test-Path -LiteralPath $tempRoot)){
        try {
            $resolved=(Resolve-Path -LiteralPath $tempRoot).Path
            if($resolved -ine [IO.Path]::GetFullPath($tempRoot) -or
                [IO.Directory]::GetParent($resolved).FullName.TrimEnd('\') -ine [IO.Path]::GetTempPath().TrimEnd('\') -or
                [IO.Path]::GetFileName($resolved) -notmatch '^sql-lab-hv-network-[a-f0-9]{32}$'){throw 'HYPERV_NETWORK_ACCEPTANCE_TEMP_SCOPE_INVALID'}
            Remove-Item -LiteralPath $resolved -Recurse -Force
        } catch {$cleanupFailures.Add($_.Exception)}
    }
    if(-not $terminated -or $cleanupFailures.Count){Write-Warning "RECOVERY_REQUIRED OperationId=$operationId"}
    if($child){$child.Dispose()}
    if($module){Remove-Module $module.Name -Force}
    if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()
}
if($primary -or $cleanupFailures.Count){
    $errors=[Collections.Generic.List[Exception]]::new()
    if($primary){$errors.Add($primary)}
    foreach($failure in $cleanupFailures){$errors.Add($failure)}
    throw [AggregateException]::new('HYPERV_NETWORK_ACCEPTANCE_FAILED',$errors.ToArray())
}
Write-Host 'PASS: Native SQL/network reconnect and operation-owned cleanup.'
