#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$passed=0;$failures=[Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
. (Join-Path $PSScriptRoot '../Common/AiPodmanSamplesReferenceSupervisor.ps1')
$helper=Join-Path $PSScriptRoot '../Common/AiPodmanSamplesReferenceScenario.ps1'
$root=New-AiPodmanSamplesReferenceRoot
function Assert-Rejected {
    param([scriptblock]$Action,[string]$Code,[string]$Name)
    $rejected=$false
    try {& $Action}catch{$rejected=$_.Exception.Message -ceq $Code}
    Add-CheckResult -Name $Name -Success $rejected
}
try {
    $workerPath=Join-Path $PSScriptRoot '../Integration/Support/Invoke-AiPodmanSamplesReferenceWorker.ps1'
    foreach($path in @($helper,(Join-Path $PSScriptRoot '../Common/AiPodmanSamplesReferenceSupervisor.ps1'),
        (Join-Path $PSScriptRoot '../Integration/Invoke-AiPodmanSamplesReferenceAcceptance.ps1'),
        $workerPath)){
        $tokens=$null;$errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        Add-CheckResult -Name ('Syntax '+[IO.Path]::GetFileName($path)) -Success ($errors.Count -eq 0)
    }
    $tokens=$null;$errors=$null
    $workerAst=[Management.Automation.Language.Parser]::ParseFile($workerPath,[ref]$tokens,[ref]$errors)
    $restartCommands=@($workerAst.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Restart-SqlServerLab'},$true))
    $restartParameters=@($restartCommands[0].CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst]}|ForEach-Object ParameterName)
    Add-CheckResult -Name 'Restart verwendet nur den öffentlichen StateRoot-losen Vertrag' -Success ($restartCommands.Count -eq 1 -and $restartParameters -cnotcontains 'StateRoot' -and $restartParameters -ccontains 'RunId')
    $module=New-Module -ArgumentList $helper -ScriptBlock {
        param($Helper)
        . $Helper
        function Assert-LabAiPersistentPath {param($Path)}
        function Get-LabAiPodmanSetupRuntimeScope {[pscustomobject]@{Status='AVAILABLE';RuntimeId=$script:Runtime}}
        function Get-CleanupPlan {param($RunDir) $script:Plan}
        function Get-LabProviderSubRuns {param($RunId,$StateRoot) [pscustomobject]@{provider='podman'}}
        function Remove-SqlServerLab {
            [CmdletBinding(SupportsShouldProcess)]
            param($RunId,$StateRoot,[switch]$Force)
            if($PSCmdlet.ShouldProcess($RunId,'Remove synthetic fixture')){
                $script:Removals++
                if(-not $script:Retain){$script:Present=$false}
            }
            [pscustomobject]@{Status='REMOVED';Errors=0}
        }
        function Invoke-LabTransferNative {
            param($Provider,$Arguments,$TimeoutSeconds)
            if($Provider -cne 'podman' -or $TimeoutSeconds -ne 20){throw 'TEST_BOUNDARY_FAILED'}
            if(-not $script:Present){return}
            if($Arguments[0] -ceq 'inspect'){
                return (@([pscustomobject]@{Id=('a'*64);Config=@{Labels=$script:Labels}})|ConvertTo-Json -Depth 6 -Compress)
            }
            if($Arguments[0] -ceq 'volume' -and $Arguments[1] -ceq 'inspect'){
                return (@([pscustomobject]@{Name='sample-volume';Labels=$script:Labels})|ConvertTo-Json -Depth 6 -Compress)
            }
            if($Arguments[0] -ceq 'volume'){return 'sample-volume'}
            if($Arguments -contains 'volume=sample-volume' -and $script:Shared){return ('b'*64)}
            if($Arguments -contains '{{.ID}}|{{.Names}}'){return (('a'*64)+'|sample-container')}
            return ('a'*64)
        }
    }
    $operation=[guid]::NewGuid().ToString('D');$runId=[guid]::NewGuid().ToString('D');$scopeId=[guid]::NewGuid().ToString('D')
    $record=[pscustomobject]@{OperationId=$operation;RuntimeScopeId=('runtime-scope-'+('a'*24));StateRoot=(Join-Path $root 'state');DataRoot=(Join-Path $root 'Lab_Data');CollectionId=[guid]::NewGuid().ToString('D');LocalPort=11434;NewStarted=$true}
    $directory=Join-Path $record.StateRoot ('runs/'+$runId)
    $null=New-Item -ItemType Directory -Path $directory -Force
    $run=[pscustomobject]@{runId=$runId;scopeId=$scopeId;state='PROVISIONING';metadata=@{workflowOperationId=$operation;persistentData=$false}}
    $run|ConvertTo-Json -Depth 5|Set-Content (Join-Path $directory 'run-state.json')
    $plan=[pscustomobject]@{runId=$runId;scopeId=$scopeId;steps=@(
        @{provider='podman';resourceType='container';resourceId='sample-container'},
        @{provider='podman';resourceType='volume';resourceId='sample-volume'})}
    & $module {param($Record,$Plan,$Run)
        $script:Runtime=$Record.RuntimeScopeId;$script:Plan=$Plan;$script:Present=$true;$script:Removals=0;$script:Retain=$false;$script:Shared=$false
        $script:Labels=@{'sql-server-lab.run-id'=$Run.runId;'sql-server-lab.scope-id'=$Run.scopeId;'sql-server-lab.instance-id'='primary'}
    } $record $plan $run
    & $module {param($Record) Remove-AiPodmanSamplesOwnedRun $Record} $record
    Add-CheckResult -Name 'Partielles New ohne SQL-Binding wird besitzgebunden bereinigt' -Success (& $module {$script:Removals -eq 1 -and -not $script:Present})
    & $module {$script:Present=$true;$script:Removals=0;$script:Runtime='runtime-scope-bbbbbbbbbbbbbbbbbbbbbbbb'}
    Assert-Rejected {& $module {param($Record) Remove-AiPodmanSamplesOwnedRun $Record} $record} 'SAMPLES_RUNTIME_CHANGED' 'Runtimewechsel blockiert vor Mutation'
    & $module {param($Record) $script:Runtime=$Record.RuntimeScopeId;$script:Labels['sql-server-lab.scope-id']='foreign'} $record
    Assert-Rejected {& $module {param($Record) Remove-AiPodmanSamplesOwnedRun $Record} $record} 'SAMPLES_RESOURCE_OWNERSHIP_INVALID' 'Fremde Labels blockieren vor Mutation'
    & $module {param($Scope) $script:Labels['sql-server-lab.scope-id']=$Scope;$script:Shared=$true} $scopeId
    Assert-Rejected {& $module {param($Record) Remove-AiPodmanSamplesOwnedRun $Record} $record} 'SAMPLES_VOLUME_SHARED' 'Fremdes Volume-Attachment blockiert vor Mutation'
    Add-CheckResult -Name 'Negative Ownership-Probes entfernen nichts' -Success (& $module {$script:Removals -eq 0})
    & $module {$script:Shared=$false;$script:Retain=$true}
    $run.state='REMOVED';$run|ConvertTo-Json -Depth 5|Set-Content (Join-Path $directory 'run-state.json')
    Assert-Rejected {& $module {param($Record) Remove-AiPodmanSamplesOwnedRun $Record} $record} 'SAMPLES_CLEANUP_RESIDUE' 'Terminaler State allein ist kein Restnachweis'
    $other=Join-Path $record.StateRoot ('runs/'+[guid]::NewGuid().ToString('D'));$null=New-Item -ItemType Directory -Path $other
    $second=$run.PSObject.Copy();$second.runId=[IO.Path]::GetFileName($other);$second|ConvertTo-Json -Depth 5|Set-Content (Join-Path $other 'run-state.json')
    Assert-Rejected {& $module {param($Record) Remove-AiPodmanSamplesOwnedRun $Record} $record} 'SAMPLES_OWNERSHIP_AMBIGUOUS' 'Mehrdeutige Lost-New-Operation blockiert'
    $missing=$record.PSObject.Copy();$missing.OperationId=[guid]::NewGuid().ToString('D')
    Assert-Rejected {& $module {param($Record) Remove-AiPodmanSamplesOwnedRun $Record} $missing} 'SAMPLES_NEW_OUTCOME_UNVERIFIABLE' 'Verlorenes New ohne Run bleibt Recovery'
    $record|ConvertTo-Json|Set-Content (Join-Path $root 'operation.json')
    $read=& $module {param($Root,$Operation) Read-AiPodmanSamplesOperation $Root $Operation} $root $operation
    Add-CheckResult -Name 'Dauerhafte Operation bindet private Roots und Runtime' -Success ($read.RuntimeScopeId -ceq $record.RuntimeScopeId)
    Assert-Rejected {& $module {param($Root) Read-AiPodmanSamplesOperation $Root ([guid]::NewGuid().ToString('D'))} $root} 'SAMPLES_OPERATION_INVALID' 'Fremde Operation kann Worker nicht übernehmen'

    $table=[Data.DataTable]::new();foreach($name in @('Northwind','Chinook','Online','Major')){$null=$table.Columns.Add($name,[long])}
    $null=$table.Rows.Add(830,275,2,17)
    $empty=$table.Clone();$data=[Data.DataSet]::new();$data.Tables.Add($table);$data.Tables.Add($empty)
    $reader=$data.CreateDataReader()
    try{$row=& $module {param($Reader) Read-AiPodmanSamplesSqlResults $Reader} $reader
        Add-CheckResult -Name 'SQL-Reader leert weitere Resultsets vollständig' -Success ($row.NorthwindOrders -eq 830 -and -not $reader.NextResult())
    }finally{$reader.Dispose()}
    Add-CheckResult -Name 'Katalogreferenz verlangt exakte Sample-Zählungen' -Success (& $module {param($Evidence) Test-AiPodmanSamplesContentEvidence $Evidence} $row)
    foreach($changedCount in @(@{Name='NorthwindOrders';Value=829},@{Name='NorthwindOrders';Value=831},@{Name='ChinookArtists';Value=274},@{Name='ChinookArtists';Value=276})){
        $drift=$row.PSObject.Copy();$drift.($changedCount.Name)=$changedCount.Value
        Add-CheckResult -Name ('Positive abweichende Sample-Zählung blockiert: '+$changedCount.Name+'/'+$changedCount.Value) -Success (-not (& $module {param($Evidence) Test-AiPodmanSamplesContentEvidence $Evidence} $drift))
    }
    $null=$empty.Rows.Add(1,1,2,17);$reader=$data.CreateDataReader()
    try{Assert-Rejected {& $module {param($Reader) Read-AiPodmanSamplesSqlResults $Reader} $reader} 'SAMPLES_SQL_ROW_COUNT_INVALID' 'Zusätzlicher SQL-Resultset wird abgewiesen'}finally{$reader.Dispose()}

    $sqlModule=New-Module -ArgumentList $helper -ScriptBlock {
        param($Helper)
        . $Helper
        function Get-LabRelationalCoreSecret {param($RunId,$StateRoot) return $script:Secret}
        function New-LabRelationalCoreConnection {param($Binding,$DatabaseName,$Secret) return $script:Connection}
    }
    $secret=[pscustomobject]@{Disposed=$false};$secret|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $command=[pscustomobject]@{Disposed=$false;CommandTimeout=0;CommandText=''}
    $command|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $command|Add-Member ScriptMethod ExecuteReader {param($Behavior) throw 'SYNTHETIC_SQL_FAILURE'}
    $connection=[pscustomobject]@{Disposed=$false;Command=$command}
    $connection|Add-Member ScriptMethod Open {}
    $connection|Add-Member ScriptMethod CreateCommand {return $this.Command}
    $connection|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    & $sqlModule {param($Secret,$Connection) $script:Secret=$Secret;$script:Connection=$Connection} $secret $connection
    try{& $sqlModule {Get-AiPodmanSamplesContentEvidence -Binding @{RunId='synthetic'} -StateRoot 'synthetic'} }catch{}
    Add-CheckResult -Name 'SQL-Fehler verwirft Credential, Connection und begrenzten Command' -Success ($secret.Disposed -and $connection.Disposed -and $command.Disposed -and $command.CommandTimeout -eq 45)

    $sequenceModule=New-Module -ArgumentList (Join-Path $PSScriptRoot '../Common/AiPodmanSamplesReferenceSupervisor.ps1') -ScriptBlock {
        param($Helper)
        . $Helper
        $script:Calls=0
        function Invoke-AiPodmanSamplesReferenceChild {
            param($EvidenceRoot,$OperationId,$WorkerPath,$Stage,$TimeoutSeconds,$Control)
            $script:Calls++;$Control.TerminationConfirmed=$false
            [pscustomobject]@{Status='FAILED';Reason='TERMINATION_UNCONFIRMED';TerminationConfirmed=$false;Assertions=0}
        }
        Export-ModuleMember -Function @()
    }
    $blocked=& $sequenceModule {param($Root,$Operation) Invoke-AiPodmanSamplesReferenceSequence -EvidenceRoot $Root -OperationId $Operation -WorkerPath 'unused' -TimeoutSeconds 1 -CleanupTimeoutSeconds 1} $root $operation
    Add-CheckResult -Name 'Unbestätigte Child-Beendigung sperrt Cleanup' -Success ($blocked.Cleanup.Status -ceq 'NOT_EXECUTED' -and (& $sequenceModule {$script:Calls -eq 1}))

    $worker=Join-Path $root 'fixture.ps1'
    @'
param($EvidenceRoot,[guid]$OperationId,$Stage)
$ErrorActionPreference='Stop'
$mode=Get-Content (Join-Path $EvidenceRoot 'mode') -Raw
$statePath=Join-Path $EvidenceRoot 'fixture-operation.json'
$state=Get-Content $statePath -Raw|ConvertFrom-Json
if($state.OperationId -cne $OperationId.ToString('D')){exit 6}
if($Stage -eq 'ACCEPTANCE'){
    $state.NewStarted=$true
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Compress))
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'arrange.started'),'synthetic-resource')
    if($mode -eq 'hang'){
        [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'child.pid'),[string]$PID)
        Start-Sleep -Seconds 60
    }
}
if($Stage -eq 'CLEANUP'){
    if(Test-Path (Join-Path $EvidenceRoot 'child.pid')){
        $previous=[int](Get-Content (Join-Path $EvidenceRoot 'child.pid'))
        if(Get-Process -Id $previous -ErrorAction SilentlyContinue){exit 5}
    }
    if(-not $state.NewStarted -or -not (Test-Path (Join-Path $EvidenceRoot 'arrange.started'))){exit 7}
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'cleanup.started'),'yes')
    if($mode -eq 'cleanup-hang'){
        [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'child.pid'),[string]$PID)
        Start-Sleep -Seconds 60
    }
    $state.NewStarted=$false
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Compress))
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'cleanup.handled'),'synthetic-resource-removed')
}
[Console]::Out.WriteLine('private-stdout-sentinel');[Console]::Error.WriteLine('private-stderr-sentinel')
$receipt=@{OperationId=$OperationId.ToString('D');Stage=$Stage;Status='COMPLETED';Assertions=1}
if($mode -eq 'forged' -and $Stage -eq 'ACCEPTANCE'){$receipt.OperationId=[guid]::NewGuid().ToString('D')}
[IO.File]::WriteAllText((Join-Path $EvidenceRoot ($Stage+'.receipt.json')),($receipt|ConvertTo-Json -Compress))
'@ | Set-Content $worker
    foreach($mode in @('success','hang','forged','cleanup-hang')){
        $case=Join-Path $root $mode;$null=New-Item -ItemType Directory -Path $case
        [IO.File]::WriteAllText((Join-Path $case 'mode'),$mode)
        [IO.File]::WriteAllText((Join-Path $case 'fixture-operation.json'),(@{OperationId=$operation;NewStarted=$false}|ConvertTo-Json -Compress))
        $watch=[Diagnostics.Stopwatch]::StartNew()
        # Allow startup before the intentional hang; its PID marker must prove
        # that the child entered the stage before the deadline killed it.
        $primaryBudget=if($mode -ceq 'hang'){10}else{15}
        $cleanupBudget=if($mode -ceq 'cleanup-hang'){10}else{15}
        $result=Invoke-AiPodmanSamplesReferenceSequence -EvidenceRoot $case -OperationId $operation -WorkerPath $worker -TimeoutSeconds $primaryBudget -CleanupTimeoutSeconds $cleanupBudget
        $watch.Stop()
        $expected= switch($mode){
            success {$result.Primary.Status -ceq 'COMPLETED' -and $result.Cleanup.Status -ceq 'COMPLETED'}
            hang {$result.Primary.Reason -ceq 'TIMEOUT' -and $result.Primary.TerminationConfirmed -and $result.Cleanup.Status -ceq 'COMPLETED'}
            forged {$result.Primary.Status -ceq 'FAILED' -and $result.Cleanup.Status -ceq 'COMPLETED'}
            cleanup-hang {$result.Primary.Status -ceq 'COMPLETED' -and $result.Cleanup.Reason -ceq 'TIMEOUT'}
        }
        Add-CheckResult -Name ('Echter Child-Prozess: '+$mode) -Success ($expected -and $watch.Elapsed.TotalSeconds -lt 50) -Message ($result.Primary.Reason+'/'+$result.Cleanup.Reason)
        if($mode -cin @('hang','cleanup-hang')){
            $marker=Join-Path $case 'child.pid'
            $childId=0
            $started=(Test-Path -LiteralPath $marker) -and [int]::TryParse([string](Get-Content -LiteralPath $marker -Raw),[ref]$childId)
            $exited=$started -and $childId -gt 0 -and -not (Get-Process -Id $childId -ErrorAction SilentlyContinue)
            Add-CheckResult -Name ('Timeout nach begonnenem Child und bestätigtem Ende: '+$mode) -Success $exited
        }
        $stateAfter=Get-Content (Join-Path $case 'fixture-operation.json') -Raw|ConvertFrom-Json
        $arranged=Test-Path (Join-Path $case 'arrange.started')
        $cleanupStarted=Test-Path (Join-Path $case 'cleanup.started')
        $cleanupHandled=Test-Path (Join-Path $case 'cleanup.handled')
        $stateExpected=if($mode -ceq 'cleanup-hang'){$stateAfter.NewStarted -and -not $cleanupHandled}else{-not $stateAfter.NewStarted -and $cleanupHandled}
        Add-CheckResult -Name ('Synthetisches Arrange und Cleanup-Zustand: '+$mode) -Success ($arranged -and $cleanupStarted -and $stateExpected)
        $saved=Get-Content (Join-Path $case 'result.json') -Raw|ConvertFrom-Json
        Add-CheckResult -Name ('Getrennte persistente Ergebnisse: '+$mode) -Success ($saved.Primary.Reason -ceq $result.Primary.Reason -and $saved.Cleanup.Reason -ceq $result.Cleanup.Reason)
    }
    Add-CheckResult -Name 'Child-Streams bleiben in privaten Dateien' -Success ((Get-Content (Join-Path $root 'success/ACCEPTANCE.stdout.log') -Raw) -match 'private-stdout-sentinel' -and (Get-Content (Join-Path $root 'success/ACCEPTANCE.stderr.log') -Raw) -match 'private-stderr-sentinel')
}
finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-ai-podman-samples-reference-*'){throw 'TEST_ROOT_INVALID'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL"
if($failures.Count){exit 1}

