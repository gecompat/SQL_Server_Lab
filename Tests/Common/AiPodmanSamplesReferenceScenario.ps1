# Test-only helpers. Functions run in the imported module's private scope.
function Read-AiPodmanSamplesOperation {
    param([string]$EvidenceRoot,[string]$OperationId)
    Assert-LabAiPersistentPath $EvidenceRoot
    $path=Join-Path $EvidenceRoot 'operation.json'
    Assert-LabAiPersistentPath $path
    if((Get-Item -LiteralPath $path).Length -gt 4096){throw 'SAMPLES_OPERATION_INVALID'}
    $record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 5
    if($OperationId -cnotmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or
        $record.OperationId -cne $OperationId -or $record.RuntimeScopeId -cnotmatch '^runtime-scope-[a-f0-9]{24}$' -or
        $record.StateRoot -cne (Join-Path $EvidenceRoot 'state') -or $record.DataRoot -cne (Join-Path $EvidenceRoot 'Lab_Data') -or
        $record.CollectionId -cnotmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or
        $record.LocalPort -lt 1024 -or $record.LocalPort -gt 65535 -or $record.NewStarted -isnot [bool]){throw 'SAMPLES_OPERATION_INVALID'}
    return $record
}

function Assert-AiPodmanSamplesRuntime {
    param($Record)
    $scope=Get-LabAiPodmanSetupRuntimeScope
    if($scope.Status -cne 'AVAILABLE' -or $scope.RuntimeId -cne $Record.RuntimeScopeId){throw 'SAMPLES_RUNTIME_CHANGED'}
}

function Get-AiPodmanSamplesOperationRun {
    param([string]$StateRoot,[string]$OperationId)
    $runs=@(foreach($directory in @(Get-ChildItem -LiteralPath (Join-Path $StateRoot 'runs') -Directory -ErrorAction SilentlyContinue)){
        $path=Join-Path $directory.FullName 'run-state.json'
        Assert-LabAiPersistentPath $path
        if(Test-Path -LiteralPath $path){
            $run=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 30
            if($run.metadata.workflowOperationId -ceq $OperationId){
                if($run.runId -cne $directory.Name){throw 'SAMPLES_OWNERSHIP_INVALID'}
                $run
            }
        }
    })
    if($runs.Count -gt 1){throw 'SAMPLES_OWNERSHIP_AMBIGUOUS'}
    if($runs.Count){return $runs[0]}
}

function Get-AiPodmanSamplesInventory {
    param($Record,$Run,$Plan)
    Assert-AiPodmanSamplesRuntime $Record
    $containers=@(Invoke-LabTransferNative -Provider podman -Arguments @('ps','-a','--no-trunc','--format','{{.ID}}|{{.Names}}') -TimeoutSeconds 20)
    $volumes=@(Invoke-LabTransferNative -Provider podman -Arguments @('volume','ls','--format','{{.Name}}') -TimeoutSeconds 20)
    $runContainers=@(Invoke-LabTransferNative -Provider podman -Arguments @('ps','-a','--no-trunc','--filter',"label=sql-server-lab.run-id=$($Run.runId)",'--format','{{.ID}}') -TimeoutSeconds 20)
    $runVolumes=@(Invoke-LabTransferNative -Provider podman -Arguments @('volume','ls','--filter',"label=sql-server-lab.run-id=$($Run.runId)",'--format','{{.Name}}') -TimeoutSeconds 20)
    $targets=[Collections.Generic.List[object]]::new()
    foreach($step in @($Plan.steps)){
        if($step.resourceType -ceq 'container'){
            foreach($line in $containers){
                $parts=([string]$line).Split('|')
                if($parts.Count -ne 2 -or $parts[0] -cnotmatch '^[a-f0-9]{64}$'){throw 'SAMPLES_INVENTORY_INVALID'}
                if($parts[0] -ceq $step.resourceId -or $parts[1] -ceq $step.resourceId){$targets.Add([pscustomobject]@{Kind='container';Id=$parts[0]})}
            }
        }
        elseif($step.resourceId -cin $volumes){$targets.Add([pscustomobject]@{Kind='volume';Id=$step.resourceId})}
    }
    foreach($id in $runContainers){if(-not @($targets|Where-Object {$_.Kind -ceq 'container' -and $_.Id -ceq $id}).Count){$targets.Add([pscustomobject]@{Kind='container';Id=$id})}}
    foreach($id in $runVolumes){if(-not @($targets|Where-Object {$_.Kind -ceq 'volume' -and $_.Id -ceq $id}).Count){$targets.Add([pscustomobject]@{Kind='volume';Id=$id})}}
    return @($targets)
}

function Remove-AiPodmanSamplesOwnedRun {
    param($Record)
    Assert-AiPodmanSamplesRuntime $Record
    $run=Get-AiPodmanSamplesOperationRun -StateRoot $Record.StateRoot -OperationId $Record.OperationId
    if(-not $run){
        if($Record.NewStarted){throw 'SAMPLES_NEW_OUTCOME_UNVERIFIABLE'}
        return
    }
    if(-not $Record.NewStarted -or $run.metadata.workflowOperationId -cne $Record.OperationId -or
        $run.metadata.persistentData -or $run.runId -cnotmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or
        $run.scopeId -cnotmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'){throw 'SAMPLES_OWNERSHIP_INVALID'}
    $runDirectory=Join-Path $Record.StateRoot ('runs/'+$run.runId)
    Assert-LabAiPersistentPath (Join-Path $runDirectory 'cleanup-plan.json')
    $plan=Get-CleanupPlan -RunDir $runDirectory
    $providers=@(Get-LabProviderSubRuns -RunId $run.runId -StateRoot $Record.StateRoot)
    if(-not $plan -or $plan.runId -cne $run.runId -or $plan.scopeId -cne $run.scopeId -or
        $providers.Count -ne 1 -or $providers[0].provider -cne 'podman' -or
        @($plan.steps|Where-Object {$_.provider -cne 'podman' -or $_.resourceType -cnotin @('container','volume') -or -not $_.resourceId}).Count){throw 'SAMPLES_CLEANUP_PLAN_INVALID'}
    $targets=@(Get-AiPodmanSamplesInventory -Record $Record -Run $run -Plan $plan)
    # Validate every candidate before removal, also after partial New. This does
    # not require RUNNING, a SQL endpoint or a complete transfer binding.
    foreach($target in $targets){
        $nativeArguments=if($target.Kind -ceq 'container'){@('inspect',$target.Id)}else{@('volume','inspect',$target.Id)}
        $observed=@((Invoke-LabTransferNative -Provider podman -Arguments $nativeArguments -TimeoutSeconds 20)-join "`n"|ConvertFrom-Json -Depth 30)
        if($observed.Count -ne 1){throw 'SAMPLES_RESOURCE_AMBIGUOUS'}
        $labels=if($target.Kind -ceq 'container'){$observed[0].Config.Labels}else{$observed[0].Labels}
        if($labels.'sql-server-lab.run-id' -cne $run.runId -or $labels.'sql-server-lab.scope-id' -cne $run.scopeId -or
            $labels.'sql-server-lab.instance-id' -cne 'primary' -or $labels.'sql-server-lab.persistent-storage-id' -or
            $labels.'sql-server-lab.persistence'){throw 'SAMPLES_RESOURCE_OWNERSHIP_INVALID'}
        if($target.Kind -ceq 'container' -and $observed[0].Id -cne $target.Id){throw 'SAMPLES_RESOURCE_OWNERSHIP_INVALID'}
        if($target.Kind -ceq 'volume'){
            if($observed[0].Name -cne $target.Id){throw 'SAMPLES_RESOURCE_OWNERSHIP_INVALID'}
            $attachments=@(Invoke-LabTransferNative -Provider podman -Arguments @('ps','-a','--no-trunc','--filter',"volume=$($target.Id)",'--format','{{.ID}}') -TimeoutSeconds 20)
            if(@($attachments|Where-Object {$_ -cnotin @($targets|Where-Object Kind -eq container|ForEach-Object Id)}).Count){throw 'SAMPLES_VOLUME_SHARED'}
        }
    }
    Assert-AiPodmanSamplesRuntime $Record
    $removed=Remove-SqlServerLab -RunId $run.runId -StateRoot $Record.StateRoot -Force -Confirm:$false
    if($removed.Status -cne 'REMOVED' -or $removed.Errors){throw 'SAMPLES_REMOVE_FAILED'}
    if(@(Get-AiPodmanSamplesInventory -Record $Record -Run $run -Plan $plan).Count){throw 'SAMPLES_CLEANUP_RESIDUE'}
}

function Read-AiPodmanSamplesSqlResults {
    param($Reader)
    $rows=[Collections.Generic.List[object]]::new()
    do {
        while($Reader.Read()){
            if($Reader.FieldCount -ne 4){throw 'SAMPLES_SQL_SHAPE_INVALID'}
            $values=@(for($i=0;$i -lt 4;$i++){if($Reader.IsDBNull($i)){throw 'SAMPLES_SQL_NULL'};[long]$Reader.GetValue($i)})
            $rows.Add([pscustomobject]@{NorthwindOrders=$values[0];ChinookArtists=$values[1];OnlineSamples=$values[2];Major=$values[3]})
        }
    }while($Reader.NextResult())
    if($rows.Count -ne 1){throw 'SAMPLES_SQL_ROW_COUNT_INVALID'}
    return $rows[0]
}

function Test-AiPodmanSamplesContentEvidence {
    param($Evidence)
    return ($Evidence.Major -eq 17 -and $Evidence.NorthwindOrders -eq 830 -and
        $Evidence.ChinookArtists -eq 275 -and $Evidence.OnlineSamples -eq 2)
}

function Get-AiPodmanSamplesContentEvidence {
    param($Binding,[string]$StateRoot)
    $secret=$null;$connection=$null;$command=$null;$reader=$null
    try {
        $secret=Get-LabRelationalCoreSecret -RunId $Binding.RunId -StateRoot $StateRoot
        $connection=New-LabRelationalCoreConnection -Binding $Binding -DatabaseName master -Secret $secret
        $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=45
        $command.CommandText=@'
SET NOCOUNT ON;
SELECT (SELECT COUNT_BIG(*) FROM Northwind.dbo.Orders),
 (SELECT COUNT_BIG(*) FROM Chinook.dbo.Artist),
 (SELECT COUNT_BIG(*) FROM sys.databases WHERE name IN (N'Northwind',N'Chinook') AND state_desc=N'ONLINE'),
 CONVERT(int,SERVERPROPERTY('ProductMajorVersion'));
'@
        $reader=$command.ExecuteReader([Data.CommandBehavior]::SequentialAccess)
        Read-AiPodmanSamplesSqlResults $reader
    }
    finally {
        if($reader){$reader.Dispose()};if($command){$command.Dispose()}
        if($connection){$connection.Dispose()};if($secret){$secret.Dispose()}
    }
}
