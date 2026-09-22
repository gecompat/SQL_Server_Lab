#Requires -Version 7.2
<# Own temporary Podman environment; no persistent user environment is accepted as input. #>
[CmdletBinding()]
param(
    [ValidateRange(1024,65535)][int]$LocalPort=11434,
    [ValidateSet('ollama-embeddinggemma-latest','ollama-bge-m3-latest','ollama-nomic-embed-text-v2-moe')][string]$EmbeddingModelKey='ollama-embeddinggemma-latest',
    [switch]$RuntimeMutexAlreadyHeld
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-podman-acceptance-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $root 'state';$data=Join-Path $root 'Lab_Data'
$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT
$module=$null;$plan=$null;$result=$null;$mutex=$null;$acquired=$false;$passed=$false;$clean=$false;$count=0;$privateEvidence=$false
function Assert-AiSetupAcceptance([bool]$Condition){if(-not $Condition){throw 'AI_PODMAN_SETUP_ACCEPTANCE_ASSERTION_FAILED'};$script:count++}
try {
    if(-not $RuntimeMutexAlreadyHeld){
        $name=if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}
        $mutex=[Threading.Mutex]::new($false,$name)
        try{$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10))}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not $acquired){throw 'AI_PODMAN_SETUP_ACCEPTANCE_LOCKED'}
    }
    $env:SQL_SERVER_LAB_STATE=$state;$env:SQL_SERVER_LAB_DATA_ROOT=$data
    $null=New-Item -ItemType Directory -Path $root
    if($IsWindows){
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=Get-Acl -LiteralPath $root
        $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($identity)
        $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        Set-Acl -LiteralPath $root -AclObject $acl
    }else{
        $chmod=@(Get-Command chmod -CommandType Application -ErrorAction Stop)[0].Source
        & $chmod 700 $root 1>$null 2>$null
        if($LASTEXITCODE -ne 0){throw 'ACCEPTANCE_PRIVATE_EVIDENCE_FAILED'}
    }
    $privateEvidence=$true
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -WarningAction SilentlyContinue
    & $module {param($Data)$null=Initialize-LabManagedDataRoot -DataRoot $Data -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false} $data
    $before=& $module {param($Port)Get-LabAiPlanKey @((Invoke-LabAiHostMetadata -Port $Port -Path /api/tags).models|Sort-Object name -CaseSensitive)} $LocalPort
    $plan=& $module {param($Port,$ModelKey)New-LabAiPodmanSetupPlan -Name 'ai-podman-cli-acceptance' -LocalPort $Port -Cpu 1 -MemoryMB 2560 -EmbeddingModelKey $ModelKey} $LocalPort $EmbeddingModelKey
    $result=& $module {param($Plan,$State)Invoke-LabAiPodmanSetup -Plan $Plan -StateRoot $State -Confirm:$false} $plan $state
    Assert-AiSetupAcceptance ($result.Status -ceq 'READY' -and $result.RunId -and $result.CollectionId -ceq $plan.collectionId -and $result.EmbeddingModelKey -ceq $EmbeddingModelKey -and $result.Dimension -eq $plan.modelBinding.Dimension)
    $directory=& $module {param($State,$Op)Get-LabAiPodmanSetupDirectory $State $Op} $state $plan.operationId
    $record=& $module {param($State,$Op)Read-LabAiPodmanSetupRecord $State $Op} $state $plan.operationId
    $entries=@(& $module {param($State)Get-LabAiPodmanSetupEntries -StateRoot $State} $state)
    Assert-AiSetupAcceptance ($entries.Count -eq 1 -and $entries[0].RunId -ceq $result.RunId -and $entries[0].CollectionId -ceq $result.CollectionId)
    $parameters=@{RunId=$result.RunId;CollectionId=$result.CollectionId;StateRoot=$state;LocalPort=$LocalPort;EmbeddingModelKey=$EmbeddingModelKey;TimeoutSeconds=300;Confirm=$false}
    $query=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -QueryId backup
    Assert-AiSetupAcceptance ($query.Status -ceq 'QUERIED' -and $query.Generation -eq 1 -and $query.Ranked[0].ChunkId -ceq 'backup-policy')
    # Existing public restart is bounded; its normal provider text stays private.
    Restart-SqlServerLab -RunId $result.RunId -TimeoutSeconds 180 -Force -Confirm:$false *> (Join-Path $directory 'acceptance-restart.log')
    $afterBinding=& $module {param($Record,$State)Assert-LabTransferBinding -Expected $Record.binding -StateRoot $State -OperationId $Record.operationId} $record $state
    Assert-AiSetupAcceptance ($afterBinding.ContainerId -ceq $record.binding.ContainerId)
    $afterQuery=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -QueryId backup
    Assert-AiSetupAcceptance ($afterQuery.Generation -eq 1 -and $afterQuery.Ranked[0].ChunkId -ceq 'backup-policy')
    $after=& $module {param($Port)Get-LabAiPlanKey @((Invoke-LabAiHostMetadata -Port $Port -Path /api/tags).models|Sort-Object name -CaseSensitive)} $LocalPort
    Assert-AiSetupAcceptance ($before -ceq $after)
    $passed=$true
}
catch {
    $passed=$false
    if($privateEvidence){try{$_|Out-String|Set-Content -LiteralPath (Join-Path $root 'acceptance-primary-error.log')}catch{}}
}
finally {
    if($module -and $plan){
        try {
            $clean=& $module {
                param($Repo,$State,$Operation,$Result)
                $directory=Get-LabAiPodmanSetupDirectory $State $Operation
                if(-not(Test-Path (Join-Path $directory 'setup.json'))){return $true}
                $record=Read-LabAiPodmanSetupRecord $State $Operation
                # Only a completed supervisor handoff permits this extra fixture cleanup.
                # Uncertain termination must never race a surviving writer.
                if(-not $Result){return $false}
                if($Result.Status -ceq 'FAILED' -and $Result.CleanupStatus -ceq 'COMPLETED'){return $true}
                if($Result.Status -cne 'READY'){return $false}
                # This acceptance owns its isolated StateRoot and explicitly discards its successful fixture.
                $record.status='ROLLBACK_REQUIRED';Write-LabAiPodmanSetupRecord $record $State
                $arguments=@{AcceptanceRunner=(Join-Path $Repo 'Tools/Invoke-AiPodmanSetupWorker.ps1');Provider='podman';StateRoot=$State;OperationId=$Operation;EvidenceRoot=$directory}
                $control=@{TerminationConfirmed=$true}
                try{$null=Invoke-LabAiPodmanSetupChild @arguments -Stage COLLECTION_CLEANUP -TimeoutSeconds 120 -Control $control}catch{}
                if(-not $control.TerminationConfirmed){return $false}
                $cleanup=Invoke-LabAiPodmanSetupChild @arguments -Stage CLEANUP -TimeoutSeconds 600
                $record=Read-LabAiPodmanSetupRecord $State $Operation
                return ($cleanup.Status -ceq 'COMPLETED' -and $record.cleanupStatus -ceq 'COMPLETED')
            } $repoRoot $state $plan.operationId $result
        }catch{
            $clean=$false
            if($privateEvidence){try{$_|Out-String|Set-Content -LiteralPath (Join-Path $root 'acceptance-cleanup-error.log')}catch{}}
        }
    }else{$clean=$true}
    $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
    if($mutex){if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
if($passed -and $clean){Write-Host "AI_PODMAN_SETUP_ACCEPTANCE: PASS; ASSERTIONS=$count; CLEANUP=COMPLETED";exit 0}
Write-Host ('AI_PODMAN_SETUP_ACCEPTANCE: FAILED; CLEANUP='+$(if($clean){'COMPLETED'}else{'RECOVERY_REQUIRED'}))
exit 1
