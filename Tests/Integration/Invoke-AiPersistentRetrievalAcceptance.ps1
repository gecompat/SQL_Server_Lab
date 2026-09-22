#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft persistentes synthetisches Retrieval isoliert unter Docker oder Podman.
.DESCRIPTION
    Vorhandenes Host-Embeddinggemma; keine Downloads oder Host-Lifecycleaktion.
    Eigener SQL-Run, initiale Generation, SQLrestart, gezielter Stagingabbruch,
    weiterhin lesbare Altgeneration, Resume, Delta und vollständig gebundenes Cleanup.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[ValidateRange(1024,65535)][int]$LocalPort=11434,[switch]$RuntimeMutexAlreadyHeld)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-persistent-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $root 'state';$data=Join-Path $root 'Lab_Data';$operation=[guid]::NewGuid().ToString('D');$collection=[guid]::NewGuid().ToString('D');$customCollection=[guid]::NewGuid().ToString('D')
$module=$null;$binding=$null;$complete=$false;$cleanupFailed=$false;$arrangeStarted=$false;$mutex=$null;$acquired=$false
$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT
function Assert-Persistent {param([bool]$Condition,[string]$Name)if(-not $Condition){throw "AI_PERSISTENT_ACCEPTANCE_FAILED: $Name"};Write-Host "PASS: $Name"}
function Get-PersistentHostInventory {param($Module,[int]$Port)& $Module {param($Port)$tags=Invoke-LabAiHostMetadata -Port $Port -Path /api/tags;Get-LabAiPlanKey @($tags.models|Sort-Object name -CaseSensitive)} $Port}
try{
    if(-not $RuntimeMutexAlreadyHeld){$mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}));try{$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10))}catch [Threading.AbandonedMutexException]{$acquired=$true};if(-not $acquired){throw 'AI_PERSISTENT_ACCEPTANCE_LOCKED'}}
    $resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    Assert-Persistent ([bool]$resolution.Available) 'Providerwerkzeug verfügbar'
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $inventory=Get-PersistentHostInventory $module $LocalPort
    $null=& $module {param($Port)$plan=New-LabAiEndpointPlan -ModelKey ollama-embeddinggemma-latest -EndpointRef ollama-local -Lane local -LocalPort $Port;Get-LabAiHostModelBinding -Plan $plan} $LocalPort
    $env:SQL_SERVER_LAB_STATE=$state;$env:SQL_SERVER_LAB_DATA_ROOT=$data
    $null=New-Item -ItemType Directory -Path $root
    & $module {param($Data)$null=Initialize-LabManagedDataRoot -DataRoot $Data -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false} $data
    $arrangeStarted=$true
    $lab=& $module {
        param($Provider,$State,$Operation)
        Invoke-WithLabWorkflowOperationContext -OperationId $Operation -ScriptBlock {
            param($Provider,$State)
            New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Port 0 -Cpu 1 -MemoryMB 2560 -LabName 'ai-persistent-acceptance' -StateRoot $State -GenerateSaPassword -NonInteractive -Drives @([pscustomobject]@{id='retrieval-data';containerPath='/var/opt/mssql'})
        } -ArgumentList @($Provider,$State)
    } $Provider $state $operation
    Assert-Persistent ($lab.State -eq 'Running') 'Eigener SQL-2025-Run läuft'
    $binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $lab.RunId $state $operation
    $parameters=@{RunId=$lab.RunId;CollectionId=$collection;StateRoot=$state;LocalPort=$LocalPort;TimeoutSeconds=300}
    $preview=Invoke-SqlServerLabAiPersistentRetrieval @parameters -WhatIf
    Assert-Persistent ($preview.Status -eq 'PLANNED' -and -not(Test-Path -LiteralPath (Join-Path $state "runs/$($lab.RunId)/ai-persistent"))) 'WhatIf schreibt kein Journal'
    $first=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Confirm:$false
    Assert-Persistent ($first.Status -eq 'COMMITTED' -and $first.Generation -eq 1 -and $first.EmbeddingRequests -eq 3) 'Initiale Generation vollständig persistent'
    $query=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -Confirm:$false
    $initialHash=@($query.Ranked|Where-Object ChunkId -eq backup-policy)[0].ContentHash
    Assert-Persistent ($query.Generation -eq 1 -and $query.Ranked[0].ChunkId -ceq 'backup-policy' -and 'network-policy' -in $query.Ranked.ChunkId) 'Exakte Vektorsuche trifft synthetische Sicherungsrichtlinie'
    $hybrid=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -SearchMode Hybrid -Confirm:$false
    Assert-Persistent ($hybrid.Generation -eq 1 -and $hybrid.SearchMode -ceq 'Hybrid' -and $hybrid.Ranked[0].ChunkId -ceq 'backup-policy' -and [double]$hybrid.Ranked[0].LexicalScore -gt 0 -and [double]$hybrid.Ranked[0].HybridScore -gt 0) 'SQL-Termabdeckung und exakter Vektor bilden ein hybrides Ranking'
    $replay=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Confirm:$false
    Assert-Persistent ($replay.EmbeddingRequests -eq 0) 'Identischer Replay erzeugt keine neuen Embeddings'
    $null=Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 180 -Force -Confirm:$false
    $afterBinding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $lab.RunId $state $operation
    Assert-Persistent ($afterBinding.ContainerId -ceq $binding.ContainerId) 'SQLrestart erhält die gebundene Containeridentität'
    $afterRestart=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -Confirm:$false
    Assert-Persistent ($afterRestart.Generation -eq 1 -and $afterRestart.Ranked[0].ChunkId -ceq 'backup-policy') 'Aktive Generation übersteht SQLrestart'
    $hybridAfterRestart=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -SearchMode Hybrid -Confirm:$false
    Assert-Persistent ($hybridAfterRestart.Ranked[0].ChunkId -ceq 'backup-policy' -and [double]$hybridAfterRestart.Ranked[0].LexicalScore -gt 0) 'Hybridsuche übersteht SQLrestart'
    $journalPath=Join-Path $state "runs/$($lab.RunId)/ai-persistent/primary-$collection.json"
    $fileLock=[IO.File]::Open("$journalPath.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $fileBlocked=$false
    try{try{$null=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -Confirm:$false}catch{if($_.Exception.Message -ceq 'AI_PERSISTENT_LOCKED'){$fileBlocked=$true}else{throw}}}finally{$fileLock.Dispose()}
    Assert-Persistent $fileBlocked 'Zweiter Aufruf scheitert an echter exklusiver Dateisperre'
    $held=& $module {
        param($Binding,$State,$Collection)
        $secret=Get-LabRelationalCoreSecret -RunId $Binding.RunId -StateRoot $State
        $connection=$null
        try{
            $connection=New-LabRelationalCoreConnection -Binding $Binding -DatabaseName master -Secret $secret;$connection.Open()
            $rows=@(Invoke-LabTransferSqlRows -Connection $connection -Query "DECLARE @r int;EXEC @r=sys.sp_getapplock @Resource=@resource,@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;SELECT @r AS LockResult;" -Parameters @{resource="SqlServerLab.AiPersistent.$Collection"})
            if($rows.Count -ne 1 -or $rows[0].LockResult -lt 0){throw 'AI_PERSISTENT_TEST_LOCK_FAILED'}
            [pscustomobject]@{Connection=$connection;Secret=$secret}
        }catch{if($connection){$connection.Dispose()};$secret.Dispose();throw}
    } $binding $state $collection
    $sqlBlocked=$false
    try{try{$null=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -Confirm:$false}catch{if($_.Exception.Message -ceq 'AI_PERSISTENT_SQL_LOCKED'){$sqlBlocked=$true}else{throw}}}finally{$held.Connection.Dispose();$held.Secret.Dispose()}
    $afterLock=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -Confirm:$false
    Assert-Persistent ($sqlBlocked -and $afterLock.Generation -eq 1) 'Separater SQL-AppLock blockiert und erhält die aktive Generation'
    $faultSeen=$false;$faultEvidence=@{Chunk=0;Commit=0}
    try{
        & $module {
            param($Run,$Collection,$State,$Port,$FaultEvidence)
            $plan=New-LabAiPersistentPlan -RunId $Run -InstanceId primary -CollectionId $Collection -Action Apply -FixtureRevision Delta -QueryId backup -LocalPort $Port -TimeoutSeconds 300
            $fault={param($Step,$Id)if($Step -eq 'AfterChunkSql'){$FaultEvidence.Chunk++;throw 'SYNTHETIC_STAGING_ABORT'}}.GetNewClosure()
            Invoke-LabAiPersistentRetrieval -Plan $plan -StateRoot $State -FaultInjector $fault
        } $lab.RunId $collection $state $LocalPort $faultEvidence
    }catch{if($_.Exception.Message -ceq 'AI_PERSISTENT_RECOVERY_REQUIRED'){$faultSeen=$true}else{throw}}
    $during=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -Confirm:$false
    $stagingCount=& $module {
        param($Binding,$State,$JournalPath)
        $journal=Get-Content -LiteralPath $JournalPath -Raw|ConvertFrom-Json
        $secret=Get-LabRelationalCoreSecret -RunId $Binding.RunId -StateRoot $State;$connection=$null
        try{$connection=New-LabRelationalCoreConnection -Binding $Binding -DatabaseName master -Secret $secret;$connection.Open();@(Invoke-LabTransferSqlRows -Connection $connection -Query "SELECT COUNT(*) AS ChunkCount FROM [$($journal.databaseName)].dbo.LabChunks WHERE Generation=2;")[0].ChunkCount}finally{if($connection){$connection.Dispose()};$secret.Dispose()}
    } $binding $state $journalPath
    Assert-Persistent ($faultSeen -and $faultEvidence.Chunk -eq 1 -and $stagingCount -eq 1 -and $during.Generation -eq 1 -and @($during.Ranked|Where-Object ChunkId -eq backup-policy)[0].ContentHash -ceq $initialHash) 'Belegter Stagingabbruch nach einem Chunk erhält die lesbare Altgeneration'
    $commitReplyLost=$false
    try{
        & $module {
            param($Run,$Collection,$State,$Port,$FaultEvidence)
            $plan=New-LabAiPersistentPlan -RunId $Run -InstanceId primary -CollectionId $Collection -Action Apply -FixtureRevision Delta -QueryId backup -LocalPort $Port -TimeoutSeconds 300 -Resume
            $fault={param($Step,$Id)if($Step -eq 'AfterCommitSql'){$FaultEvidence.Commit++;throw 'SYNTHETIC_COMMIT_REPLY_LOST'}}.GetNewClosure()
            Invoke-LabAiPersistentRetrieval -Plan $plan -StateRoot $State -FaultInjector $fault
        } $lab.RunId $collection $state $LocalPort $faultEvidence
    }catch{if($_.Exception.Message -ceq 'AI_PERSISTENT_RECOVERY_REQUIRED'){$commitReplyLost=$true}else{throw}}
    $resumed=Invoke-SqlServerLabAiPersistentRetrieval @parameters -FixtureRevision Delta -Resume -Confirm:$false
    Assert-Persistent ($commitReplyLost -and $faultEvidence.Commit -eq 1 -and $resumed.Generation -eq 2 -and $resumed.EmbeddingRequests -eq 0) 'SQL-Commitreceipt finalisiert belegten Antwortverlust ohne erneutes Embedding'
    $copyProof=& $module {
        param($Binding,$State,$JournalPath)
        $journal=Get-Content -LiteralPath $JournalPath -Raw|ConvertFrom-Json
        $secret=Get-LabRelationalCoreSecret -RunId $Binding.RunId -StateRoot $State;$connection=$null
        try{$connection=New-LabRelationalCoreConnection -Binding $Binding -DatabaseName master -Secret $secret;$connection.Open();@(Invoke-LabTransferSqlRows -Connection $connection -Query "SELECT COUNT(*) AS GenerationCount,(SELECT COUNT(*) FROM [$($journal.databaseName)].dbo.LabChunks a JOIN [$($journal.databaseName)].dbo.LabChunks b ON a.ChunkId=b.ChunkId AND a.VectorHash=b.VectorHash WHERE a.Generation=1 AND b.Generation=2 AND a.ChunkId=N'cleanup-policy') AS UnchangedCopies FROM [$($journal.databaseName)].dbo.LabGenerations;")[0]}finally{if($connection){$connection.Dispose()};$secret.Dispose()}
    } $binding $state $journalPath
    Assert-Persistent ($copyProof.GenerationCount -eq 2 -and $copyProof.UnchangedCopies -eq 1) 'Genau zwei Generationen und unveränderter übernommener Vektor'
    $delta=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -Confirm:$false
    Assert-Persistent ($delta.Generation -eq 2 -and $delta.Ranked[0].ChunkId -ceq 'backup-policy' -and 'network-policy' -notin $delta.Ranked.ChunkId -and 'retention-policy' -in $delta.Ranked.ChunkId -and @($delta.Ranked|Where-Object ChunkId -eq backup-policy)[0].ContentHash -cne $initialHash) 'Update, Delete und Insert sind nach atomarem Cutover sichtbar'
    $hybridDelta=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -SearchMode Hybrid -Confirm:$false
    Assert-Persistent ($hybridDelta.Generation -eq 2 -and $hybridDelta.Ranked[0].ChunkId -ceq 'backup-policy' -and 'network-policy' -notin $hybridDelta.Ranked.ChunkId -and 'retention-policy' -in $hybridDelta.Ranked.ChunkId) 'Hybridsuche verwendet ausschließlich die atomar aktivierte Delta-Generation'
    $customDocuments=@(
        [pscustomobject]@{Id='restore-guide';Content='Synthetische Restore-Tests prüfen CHECKDB nach der Wiederherstellung.'},
        [pscustomobject]@{Id='index-guide';Content='Synthetische Index-Tests vergleichen reproduzierbare Abfragepläne.'},
        [pscustomobject]@{Id='security-guide';Content='Synthetische Sicherheitstests prüfen ausschließlich Testidentitäten.'}
    )
    $customParameters=@{RunId=$lab.RunId;CollectionId=$customCollection;StateRoot=$state;LocalPort=$LocalPort;TimeoutSeconds=300;Documents=$customDocuments}
    $customApplied=Invoke-SqlServerLabAiPersistentRetrieval @customParameters -Confirm:$false
    Assert-Persistent ($customApplied.Status -eq 'COMMITTED' -and $customApplied.DatasetMode -ceq 'CallerSupplied' -and $customApplied.EmbeddingRequests -eq 3) 'Drei Caller-Dokumente werden als eigene initiale Collection persistiert'
    $customQuery=Invoke-SqlServerLabAiPersistentRetrieval @customParameters -Action Query -Question 'Was prüfen synthetische Restore-Tests?' -SearchMode Hybrid -Confirm:$false
    Assert-Persistent ($customQuery.DatasetMode -ceq 'CallerSupplied' -and $customQuery.Ranked.Count -eq 3 -and 'restore-guide' -in $customQuery.Ranked.ChunkId) 'Freie Frage verwendet ausschließlich die hashgebundene Caller-Collection'
    $customDrift=$false
    $changedDocuments=@($customDocuments[0],[pscustomobject]@{Id='index-guide';Content='Geänderter synthetischer Inhalt.'})
    try{$null=Invoke-SqlServerLabAiPersistentRetrieval -RunId $lab.RunId -CollectionId $customCollection -StateRoot $state -LocalPort $LocalPort -TimeoutSeconds 300 -Documents $changedDocuments -Action Query -Question 'Welche Tests?' -Confirm:$false}catch{if($_.Exception.Message -ceq 'AI_PERSISTENT_GENERATION_DRIFT'){$customDrift=$true}else{throw}}
    Assert-Persistent $customDrift 'Abweichender Caller-Inhalt wird vor der Query abgewiesen'
    $updatedDocuments=@(
        [pscustomobject]@{Id='restore-guide';Content='Synthetische Restore-Tests prüfen CHECKDB und den Datenstatus.'},
        $customDocuments[1],
        [pscustomobject]@{Id='cleanup-guide';Content='Synthetische Testressourcen werden nach der Abnahme entfernt.'}
    )
    $syncParameters=$customParameters.Clone();$syncParameters.Action='Sync';$syncParameters.Documents=$updatedDocuments;$syncParameters.ExpectedDocuments=$customDocuments
    $customSynced=Invoke-SqlServerLabAiPersistentRetrieval @syncParameters -Confirm:$false
    Assert-Persistent ($customSynced.Generation -eq 2 -and $customSynced.EmbeddingRequests -eq 2 -and $customSynced.CopiedChunks -eq 1) 'Sync bettet Update und Insert neu ein und übernimmt den unveränderten Vektor'
    $updatedQuery=Invoke-SqlServerLabAiPersistentRetrieval -RunId $lab.RunId -CollectionId $customCollection -StateRoot $state -LocalPort $LocalPort -TimeoutSeconds 300 -Documents $updatedDocuments -Action Query -Question 'Was geschieht nach der Abnahme?' -SearchMode Hybrid -Confirm:$false
    Assert-Persistent ($updatedQuery.Generation -eq 2 -and 'cleanup-guide' -in $updatedQuery.Ranked.ChunkId -and 'security-guide' -notin $updatedQuery.Ranked.ChunkId) 'Sync macht Update, Insert und Delete erst nach atomarem Cutover sichtbar'
    $wrongExpected=@($customDocuments[0],$customDocuments[1],[pscustomobject]@{Id='security-guide';Content='Abweichender synthetischer Altinhalt.'})
    $sourceDrift=$false
    try{$null=Invoke-SqlServerLabAiPersistentRetrieval -RunId $lab.RunId -CollectionId $customCollection -StateRoot $state -LocalPort $LocalPort -TimeoutSeconds 300 -Documents $customDocuments -ExpectedDocuments $wrongExpected -Action Sync -Confirm:$false}catch{if($_.Exception.Message -ceq 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT'){$sourceDrift=$true}else{throw}}
    Assert-Persistent $sourceDrift 'Sync mit abweichendem erwartetem Ausgangsbestand wird vor Staging abgewiesen'
    $secondSyncParameters=$customParameters.Clone();$secondSyncParameters.Action='Sync';$secondSyncParameters.Documents=$customDocuments;$secondSyncParameters.ExpectedDocuments=$updatedDocuments
    $secondSync=Invoke-SqlServerLabAiPersistentRetrieval @secondSyncParameters -Confirm:$false
    Assert-Persistent ($secondSync.Generation -eq 3 -and $secondSync.EmbeddingRequests -eq 2) 'Zweite Caller-Synchronisierung erzeugt eine dritte abgeschlossene Generation'
    $pruned=Invoke-SqlServerLabAiPersistentRetrieval -RunId $lab.RunId -CollectionId $customCollection -StateRoot $state -LocalPort $LocalPort -TimeoutSeconds 300 -Action Prune -KeepGenerations 2 -Confirm:$false
    $prunedAgain=Invoke-SqlServerLabAiPersistentRetrieval -RunId $lab.RunId -CollectionId $customCollection -StateRoot $state -LocalPort $LocalPort -TimeoutSeconds 300 -Action Prune -KeepGenerations 2 -Confirm:$false
    Assert-Persistent ($pruned.Generation -eq 3 -and $pruned.DeletedGenerations -eq 1 -and $pruned.DeletedChunks -eq 3 -and $prunedAgain.DeletedGenerations -eq 0) 'Retention entfernt die älteste inaktive Generation und ist idempotent'
    $pruneProof=& $module {
        param($Binding,$State,$RunId,$Collection)
        $journal=Get-Content -LiteralPath (Join-Path $State "runs/$RunId/ai-persistent/primary-$Collection.json") -Raw|ConvertFrom-Json
        $secret=Get-LabRelationalCoreSecret -RunId $Binding.RunId -StateRoot $State;$connection=$null
        try{$connection=New-LabRelationalCoreConnection -Binding $Binding -DatabaseName master -Secret $secret;$connection.Open();@(Invoke-LabTransferSqlRows -Connection $connection -Query "SELECT COUNT(*) AS GenerationCount,SUM(CASE WHEN Generation=1 THEN 1 ELSE 0 END) AS GenerationOneCount,(SELECT COUNT(*) FROM [$($journal.databaseName)].dbo.LabChunks) AS ChunkCount,(SELECT ActiveGeneration FROM [$($journal.databaseName)].dbo.LabOwner WHERE Singleton=1) AS ActiveGeneration FROM [$($journal.databaseName)].dbo.LabGenerations;")[0]}finally{if($connection){$connection.Dispose()};$secret.Dispose()}
    } $binding $state $lab.RunId $customCollection
    Assert-Persistent ($pruneProof.GenerationCount -eq 2 -and $pruneProof.GenerationOneCount -eq 0 -and $pruneProof.ChunkCount -eq 6 -and $pruneProof.ActiveGeneration -eq 3) 'SQL belegt ausschließlich Generation 2 und 3 mit aktivem Zeiger auf 3'
    $afterPrune=Invoke-SqlServerLabAiPersistentRetrieval @customParameters -Action Query -Question 'Was prüfen synthetische Restore-Tests?' -Confirm:$false
    Assert-Persistent ($afterPrune.Generation -eq 3 -and 'restore-guide' -in $afterPrune.Ranked.ChunkId) 'Aktive Caller-Generation bleibt nach Retention abfragbar'
    $customRemoved=Invoke-SqlServerLabAiPersistentRetrieval -RunId $lab.RunId -CollectionId $customCollection -StateRoot $state -LocalPort $LocalPort -TimeoutSeconds 300 -Action Remove -Confirm:$false
    Assert-Persistent ($customRemoved.Status -eq 'REMOVED') 'Caller-Collection wird besitzgebunden entfernt'
    $removed=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Remove -Confirm:$false
    $again=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Remove -Confirm:$false
    Assert-Persistent ($removed.Status -eq 'REMOVED' -and $again.Status -eq 'REMOVED') 'Eigene Datenbank entfernt und Abwesenheit bestätigt'
    Assert-Persistent ((Get-PersistentHostInventory $module $LocalPort) -ceq $inventory) 'Hostmodellinventar unverändert'
    $complete=$true
}finally{
    if($module -and $arrangeStarted){
        try{
            $owned=& $module {param($Op,$State)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $State} $operation $state
            if($owned){
                $binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $owned.runId $state $operation
                $removedRun=Remove-SqlServerLab -RunId $owned.runId -StateRoot $state -Force -Confirm:$false
                if($removedRun.Status -ne 'REMOVED'){throw 'AI_PERSISTENT_RUN_CLEANUP_FAILED'}
            }
            if(-not $binding){throw 'AI_PERSISTENT_RUN_CLEANUP_UNVERIFIABLE'}
            & $module {param($Binding)Assert-LabTransferNoResidue -Binding $Binding} $binding
        }catch{$cleanupFailed=$true;Write-Warning 'AI_PERSISTENT_RUN_CLEANUP_RECOVERY_REQUIRED'}
    }
    $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
    if($mutex){if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
    if(-not $cleanupFailed -and (Test-Path -LiteralPath $root)){
        $absolute=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notmatch '^sql-lab-ai-persistent-[a-f0-9]{32}$'){throw 'AI_PERSISTENT_TEMP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}
if(-not $complete -or $cleanupFailed){throw 'AI_PERSISTENT_ACCEPTANCE_INCOMPLETE'}
Write-Host "AI PERSISTENT RETRIEVAL ACCEPTANCE: PASS ($Provider; vector/hybrid; caller sync/prune; SQLrestart; staging/resume; own DB/run cleanup)"
