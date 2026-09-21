#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        $script:checks=0
        function Assert-Runtime {param([bool]$Value,[string]$Name)
            if(-not $Value){throw "RETAINED_RUNTIME_CHECK_FAILED: $Name"}
            $script:checks++;Write-Host "PASS: $Name"
        }
        $native=${function:Invoke-LabRetainedStoreNative}
        $script:calls=@();$script:mode='AVAILABLE'
        Set-Item Function:Invoke-LabRetainedStoreNative -Value {
            param($Provider,$Arguments,$TimeoutSeconds)
            $script:calls+=@([pscustomobject]@{Provider=$Provider;Arguments=$Arguments;Timeout=$TimeoutSeconds})
            if($Arguments -contains 'rm'){return [pscustomobject]@{ExitCode=0;Output=@('synthetic-volume')}}
            if($Arguments -contains 'inspect'){
                if($script:mode -cne 'AVAILABLE'){return [pscustomobject]@{ExitCode=1;Output=@('synthetic private error')}}
                return [pscustomobject]@{ExitCode=0;Output=@('[{"Name":"synthetic-volume","CreatedAt":"2026-09-21T10:01:02.1234567Z","Driver":"local","Options":null,"Labels":{}}]')}
            }
            if($Arguments -contains 'ls'){
                return [pscustomobject]@{
                    ExitCode=if($script:mode -ceq 'LIST_FAILED'){1}else{0}
                    Output=switch($script:mode){PRESENT {@('synthetic-volume')};MALFORMED {@('unexpected warning text')};default{@()}}
                }
            }
            [pscustomobject]@{ExitCode=0;Output=@()}
        }
        foreach($provider in @('docker','podman')){
            $context=[pscustomobject]@{Provider=$provider;Arguments=@($(if($provider -ceq 'docker'){'--context'}else{'--connection'}),'synthetic-selection')}
            $script:mode='AVAILABLE'
            $volume=Get-LabRetainedStoreVolume -Context $context -VolumeName synthetic-volume
            Assert-Runtime ($volume.Status -ceq 'AVAILABLE' -and $volume.CreatedAt -match '\.1234567') "$provider erhält die Erstellungspräzision"
            Remove-LabRetainedStoreVolume -Context $context -VolumeName synthetic-volume
            $call=$script:calls[-1]
            Assert-Runtime (($call.Arguments -join '|') -ceq (($context.Arguments+@('volume','rm','synthetic-volume')) -join '|') -and $call.Timeout -eq 60) "$provider löscht nur exakt gebunden und ohne force/prune"
            foreach($mode in @('MISSING','PRESENT','LIST_FAILED','MALFORMED')){
                $script:mode=$mode;$caught=$false;$result=$null
                try{$result=Get-LabRetainedStoreVolume -Context $context -VolumeName synthetic-volume}catch{$caught=$true}
                Assert-Runtime ($(if($mode -ceq 'MISSING'){$result.Status -ceq 'MISSING'}else{$caught})) "$provider Abwesenheitsklassifikation $mode"
            }
        }
        Set-Item Function:Invoke-LabRetainedStoreNative -Value {
            param($Provider,$Arguments,$TimeoutSeconds)
            $value=switch($Arguments -join '|'){
                'context|inspect' {@([pscustomobject]@{Name='synthetic-context';Endpoints=[pscustomobject]@{docker=[pscustomobject]@{Host='unix:///synthetic/docker.sock'}}})}
                'info|--format|{{json .}}' {[pscustomobject]@{OperatingSystem='Linux';ServerVersion='synthetic';Driver='overlay2';DockerRootDir='/synthetic/runtime'}}
                'info|--format|json' {[pscustomobject]@{Version=[pscustomobject]@{Version='synthetic'};Store=[pscustomobject]@{GraphDriverName='overlay';GraphRoot='/synthetic/runtime'}}}
                'machine|list|--format|json' {@()}
                'system|connection|list|--format|json' {@([pscustomobject]@{Name='synthetic-connection';URI='unix:///synthetic/podman.sock';Default=$true;IsMachine=$false})}
                default {throw 'UNEXPECTED_SYNTHETIC_COMMAND'}
            }
            [pscustomobject]@{ExitCode=0;Output=@((ConvertTo-Json -InputObject $value -Depth 15 -Compress))}
        }
        foreach($provider in @('docker','podman')){
            $context=Get-LabRetainedStoreRuntimeContext -Provider $provider
            Assert-Runtime ($context.RuntimeScopeId -cmatch '^runtime-scope-[a-f0-9]{24}$' -and
                $context.Arguments[0] -ceq $(if($provider -ceq 'docker'){'--context'}else{'--connection'})) "$provider verwendet den bestehenden Runtime-Scope-Vertrag"
        }
        Set-Item Function:Get-LabHostToolInvocation -Value {param($Name)(Get-Process -Id $PID).Path}
        $timer=[Diagnostics.Stopwatch]::StartNew();$caught=$null
        try{& $native -Provider docker -Arguments @('-NoProfile','-Command','Start-Sleep -Seconds 10') -TimeoutSeconds 1}catch{$caught=$_.Exception.Message}
        Assert-Runtime ($caught -ceq 'RETAINED_STORE_RUNTIME_COMMAND_UNVERIFIABLE' -and $timer.Elapsed.TotalSeconds -lt 8) 'Echter Prozess-Timeout ist begrenzt und veröffentlicht keine Rohdiagnose'
        Write-Host "Retained store runtime checks passed: $script:checks"
    }
    . (Join-Path $repo 'Tests/Common/RetainedStoreRemovalSupervisor.ps1')
    . (Join-Path $repo 'Tests/Common/RetainedStoreRemovalAcceptanceCleanup.ps1')
    $operation=[guid]::NewGuid().ToString('D');$runId=[guid]::NewGuid().ToString('D');$scopeId=[guid]::NewGuid().ToString('D')
    $storageId=[guid]::NewGuid().ToString('D');$now=[datetime]::UtcNow.ToString('o')
    $inputObject=[pscustomobject]@{OperationId=$operation;Provider='docker';CreatedAt=$now}
    $run=[pscustomobject]@{runId=$runId;scopeId=$scopeId;state='CLEANED_UP';metadata=[pscustomobject]@{workflowOperationId=$operation}}
    $store=[pscustomobject]@{PersistentStorageId=$storageId;Provider='docker';StorageClass='INSTANCE_STORE';Retention='RETAINED';CleanupDisposition='PRESERVE';Lease=$null;
        References=@([pscustomobject]@{Kind='RUN';State='RELEASED';TargetId=$runId});LocationBinding=[pscustomobject]@{Residency='NATIVE_RUNTIME';ProviderResourceId='synthetic-volume'}}
    $volume=[pscustomobject]@{Status='AVAILABLE';VolumeName='synthetic-volume';Driver='local';Options=$null;AttachedContainers=@();CreatedAt=$now;Labels=[pscustomobject]@{
        'sql-server-lab.run-id'=$runId;'sql-server-lab.scope-id'=$scopeId;'sql-server-lab.instance-id'='primary';'sql-server-lab.sql-major-version'='2025';
        'sql-server-lab.persistent-storage-id'=$storageId;'sql-server-lab.persistence'='data-root-runtime-volume'}}
    Assert-RetainedAcceptancePartialStore -InputObject $inputObject -Run $run -Store $store -Volume $volume
    Write-Host 'PASS: Eigener terminaler Lost-New-Fixture-Store ist exakt gebunden bereinigbar'
    foreach($fault in @('OPERATION','SCOPE','ATTACHMENT','OLD_VOLUME','PENDING_DELETE','FOREIGN_REFERENCE')){
        $testRun=$run|ConvertTo-Json -Depth 10|ConvertFrom-Json -Depth 10
        $testStore=$store|ConvertTo-Json -Depth 10|ConvertFrom-Json -Depth 10
        $testVolume=$volume|ConvertTo-Json -Depth 10|ConvertFrom-Json -Depth 10
        switch($fault){
            OPERATION {$testRun.metadata.workflowOperationId=[guid]::NewGuid().ToString('D')}
            SCOPE {$testVolume.Labels.'sql-server-lab.scope-id'=[guid]::NewGuid().ToString('D')}
            ATTACHMENT {$testVolume.AttachedContainers=@('synthetic-attached')}
            OLD_VOLUME {$testVolume.CreatedAt=[datetime]::UtcNow.AddDays(-1).ToString('o')}
            PENDING_DELETE {$testStore|Add-Member -NotePropertyName Deletion -NotePropertyValue ([pscustomobject]@{OperationId=$operation})}
            FOREIGN_REFERENCE {$testStore.References+=@([pscustomobject]@{Kind='RUN';State='ACTIVE';TargetId=[guid]::NewGuid().ToString('D')})}
        }
        $caught=$false
        try{Assert-RetainedAcceptancePartialStore -InputObject $inputObject -Run $testRun -Store $testStore -Volume $testVolume}catch{$caught=$true}
        if(-not $caught){throw "PARTIAL_CLEANUP_GUARD_FAILED: $fault"}
        Write-Host "PASS: $fault sperrt den eigenen Partial-New-Cleanup"
    }
    $root=New-RetainedStoreAcceptanceRoot
    try {
        $worker=Join-Path $root 'synthetic-worker.ps1'
        @'
param($EvidenceRoot,$OperationId,$Stage)
$mode=Get-Content -LiteralPath (Join-Path $EvidenceRoot 'mode.txt') -Raw
if($Stage -ceq 'EXERCISE'){
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'arrange-started'),'SYNTHETIC_OWN_ARRANGE')
    Write-Host 'SYNTHETIC_PRIVATE_RUNTIME_LOG'
    if($mode -eq 'TIMEOUT'){Start-Sleep -Seconds 60}
    if($mode -eq 'PARTIAL'){throw 'SYNTHETIC_PRIVATE_LOST_NEW_REPLY'}
}
else {
    if(-not(Test-Path -LiteralPath (Join-Path $EvidenceRoot 'arrange-started'))){throw 'ARRANGE_OWNERSHIP_NOT_PERSISTED'}
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'cleanup-completed'),'SYNTHETIC_OWN_CLEANUP')
}
$receipt=@{OperationId=$OperationId;Stage=$Stage;Status='COMPLETED';Assertions=1}
if($mode -eq 'BAD_RECEIPT' -and $Stage -ceq 'EXERCISE'){$receipt.OperationId=[guid]::NewGuid().ToString('D')}
[IO.File]::WriteAllText((Join-Path $EvidenceRoot ($Stage+'.receipt.json')),($receipt|ConvertTo-Json -Compress))
'@ | Set-Content -LiteralPath $worker
        foreach($mode in @('SUCCESS','PARTIAL','TIMEOUT','BAD_RECEIPT')){
            $attempt=Join-Path $root $mode;$null=New-Item -ItemType Directory -Path $attempt
            [IO.File]::WriteAllText((Join-Path $attempt 'mode.txt'),$mode)
            $result=Invoke-RetainedStoreAcceptanceSequence -EvidenceRoot $attempt -OperationId ([guid]::NewGuid()) -WorkerPath $worker `
                -TimeoutSeconds 10 -CleanupTimeoutSeconds 10
            if($result.Primary.Status -cne $(if($mode -ceq 'SUCCESS'){'COMPLETED'}else{'FAILED'}) -or
                -not $result.Primary.TerminationConfirmed -or $result.Cleanup.Status -cne 'COMPLETED' -or
                -not(Test-Path -LiteralPath (Join-Path $attempt 'cleanup-completed'))){
                throw "SUPERVISOR_SEQUENCE_FAILED: $mode $($result|ConvertTo-Json -Depth 4 -Compress)"
            }
            if(($result|ConvertTo-Json -Depth 5) -match 'SYNTHETIC_PRIVATE'){throw 'SUPERVISOR_OUTPUT_LEAK'}
            if((Get-Content -LiteralPath (Join-Path $attempt 'EXERCISE.stdout.log') -Raw) -notmatch 'SYNTHETIC_PRIVATE_RUNTIME_LOG'){throw 'SUPERVISOR_PRIVATE_LOG_MISSING'}
            Write-Host "PASS: Supervisor $mode bestätigt Prozessende vor eigenem Cleanup und hält Rohlogs privat"
        }
    }
    finally {
        $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-retained-acceptance-*'){throw 'TEST_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
finally {Remove-Module $module -Force}
