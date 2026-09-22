#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-migration-check-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try{
    $checks=& $module {
        param($Root)
        $checks=[Collections.Generic.List[object]]::new()
        function Check {param($Name,$Value)$checks.Add([pscustomobject]@{Name=$Name;Success=[bool]$Value})}
        function Reject {param([scriptblock]$Action,[string]$Code)try{& $Action|Out-Null;$false}catch{if($_.Exception.Message -notmatch $Code){Write-Host "Unexpected: $($_.Exception.Message) at $($_.ScriptStackTrace)"};$_.Exception.Message -match $Code}}
        $originalBinding=(Get-Command Get-LabTransferBinding).ScriptBlock;$originalAssert=(Get-Command Assert-LabTransferBinding).ScriptBlock;$originalWrite=(Get-Command Write-LabArtifactJsonAtomic).ScriptBlock
        function script:Get-LabTransferBinding {param($RunId,$InstanceId,$StateRoot)$script:events.Add('Binding');[pscustomobject]@{RunId=$RunId;ScopeId='33333333-3333-4333-8333-333333333333';InstanceId=$InstanceId;Provider='docker';RuntimeScopeId='synthetic';ContainerId='a'*64;Volumes=@();HostName='127.0.0.1';Port=14331}}
        function script:Assert-LabTransferBinding {param($Expected,$StateRoot)$script:events.Add('Rebind');if($script:bindingDrift){throw 'TRANSFER_LIVE_BINDING_DRIFT'}}
        function Reset {
            $script:events=[Collections.Generic.List[string]]::new();$script:bindingDrift=$false;$script:modelDrift=$false;$script:fail='';$script:payloads=0
            $script:receipt=$null;$script:targetDrift=$false;$script:missingSource=$false;$script:requests=[Collections.Generic.List[object]]::new();$script:commitSql=''
            $script:db=$false;$script:owner=$null;$script:generations=@{};$script:chunks=@{};$script:guid='ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF'
            $script:collection=[guid]::NewGuid().ToString('D');$script:run='11111111-1111-4111-8111-111111111111'
            $script:parameters=@{RunId=$script:run;InstanceId='primary';CollectionId=$script:collection;Action='Apply';FixtureRevision='Initial';QueryId='backup';LocalPort=11434;TimeoutSeconds=300}
        }
        $metadata={param($Path,$Model)
            $script:events.Add('Metadata')
            if($script:missingSource -and $Model -eq 'embeddinggemma:latest'){throw 'source unavailable'}
            switch($Path){
                '/api/version' {@{version='0.34.2'}}
                '/api/tags' {@{models=@([pscustomobject]@{name=$Model;digest=$(if($Model -like 'nomic*'){if($script:targetDrift){'e'*64}else{'d'*64}}elseif($script:modelDrift){'b'*64}else{'a'*64})})}}
                '/api/show' {[pscustomobject]@{capabilities=@('embedding');model_info=[pscustomobject]@{'gemma.embedding_length'=768}}}
            }
        }
        $transport={param($Request)$script:payloads++;$script:requests.Add($Request);[pscustomobject]@{StatusCode=200;Body=@{embeddings=@(,@(1..768|ForEach-Object{0.01}))}}}
        $sql={param($Step,$Sql,$P)
            $script:events.Add($Step)
            if($Step -ceq $script:fail){throw 'synthetic SQL failure'}
            switch($Step){
                Lock {@{LockResult=$(if($script:fail -eq 'Locked'){-1}else{0})}}
                MigrationReceipt {if($script:receipt){$script:receipt}}
                Upgrade {$script:receipt=[pscustomobject]@{Contract='SqlServerLab.AiPersistentSql/2.0';UpgradeId=$P.operation;PlanKey=$P.plan;Receipt=$P.receipt}}
                Database {if($script:db){[pscustomobject]@{DatabaseGuid=$script:guid;State='ONLINE';IsReadOnly=$false}}}
                Create {if($script:db){throw 'collision'};$script:db=$true}
                Initialize {$script:owner=[pscustomobject]@{OwnerToken=$P.token;RunId=$P.run;ScopeId=$P.scope;InstanceId=$P.instance;CollectionId=$P.collection;DatabaseGuid=$script:guid;ActiveGeneration=0}}
                Owner {if($script:owner){$script:owner}}
                Generation {if($script:generations.ContainsKey($P.generation)){$script:generations[$P.generation]}}
                Chunks {if($script:chunks.ContainsKey($P.generation)){@($script:chunks[$P.generation].Values|Sort-Object ChunkId)}}
                Stage {$script:generations[$P.generation]=[pscustomobject]@{Generation=$P.generation;OperationId=$P.operation;PlanKey=$P.plan;Revision=$P.revision;DatasetHash=$P.dataset;ModelHash=$P.model;Status='STAGING'};$script:chunks[$P.generation]=@{}}
                Insert {if($script:chunks[$P.generation].ContainsKey($P.id)){throw 'duplicate'};$script:chunks[$P.generation][$P.id]=[pscustomobject]@{ChunkId=$P.id;Content=$P.content;ContentHash=$P.hash;VectorHash='c'*64;ActualVectorHash='c'*64}}
                Copy {$script:chunks[$P.generation][$P.id]=$script:chunks[$P.previous][$P.id].PSObject.Copy()}
                Commit {if($script:owner.ActiveGeneration -ne $P.previous -or $script:chunks[$P.generation].Count -ne $P.documentCount){throw 'cutover conflict'};$script:commitSql=$Sql;$script:generations[$P.generation].Status='COMMITTED';$script:owner.ActiveGeneration=$P.generation}
                Query {foreach($row in @($script:chunks[$script:owner.ActiveGeneration].Values|Sort-Object ChunkId)){[pscustomobject]@{ChunkId=$row.ChunkId;ContentHash=$(if($script:fail -eq 'QueryHash'){'d'*64}else{$row.ContentHash});Distance=0.1}}}
                Remove {$script:db=$false;$script:owner=$null}
                default {throw "Unexpected SQL step $Step"}
            }
        }
        function Execute {param([string]$Action='Apply',[string]$Revision='Initial',[switch]$Resume,[scriptblock]$Fault)
            $p=$script:parameters.Clone();$p.Action=$Action;$p.FixtureRevision=$Revision;$p.Resume=[bool]$Resume
            if($Action -eq 'Migrate'){$p.TargetModelKey='ollama-nomic-embed-text-v2-moe';$p.FixtureRevision='Delta'}
            $plan=New-LabAiPersistentPlan @p
            Invoke-LabAiPersistentRetrieval -Plan $plan -StateRoot $Root -SqlExecutor $sql -MetadataTransport $metadata -EmbeddingTransport $transport -FaultInjector $Fault
        }
        function ExecuteCaller {param([string]$Action,[object[]]$Documents,[object[]]$ExpectedDocuments,[switch]$Resume,[scriptblock]$Fault)
            $p=$script:parameters.Clone();$p.Action=$Action;$p.Documents=$Documents;$p.Resume=[bool]$Resume
            if($null -ne $ExpectedDocuments){$p.ExpectedDocuments=$ExpectedDocuments}
            if($Action -eq 'Query'){$p.Question='Welche synthetische Richtlinie gilt?'}
            if($Action -eq 'Migrate'){$p.TargetModelKey='ollama-nomic-embed-text-v2-moe'}
            $plan=New-LabAiPersistentPlan @p
            Invoke-LabAiPersistentRetrieval -Plan $plan -StateRoot $Root -SqlExecutor $sql -MetadataTransport $metadata -EmbeddingTransport $transport -FaultInjector $Fault
        }
        function JournalPath {Join-Path $Root "runs/$script:run/ai-persistent/primary-$script:collection.json"}
        try{
            Reset
            $preview=Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -Action Migrate -FixtureRevision Delta -TargetModelKey ollama-nomic-embed-text-v2-moe -WhatIf
            Check 'Migrate WhatIf prüft nur den festen lokalen Plan' ($preview.ModelKey -ceq 'ollama-nomic-embed-text-v2-moe' -and $script:events.Count -eq 0 -and -not(Test-Path $Root))
            $queryPreview=Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -Action Query -StateRoot $Root -WhatIf
            Check 'Query WhatIf lässt aktive Modell- und Revisionswahl ohne Statezugriff offen' ($null -eq $queryPreview.ModelKey -and $null -eq $queryPreview.Revision -and $queryPreview.ModelSelection -ceq 'ACTIVE_SQL_GENERATION' -and $script:events.Count -eq 0 -and -not(Test-Path $Root))
            $removePreview=Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -Action Remove -StateRoot $Root -WhatIf
            Check 'Remove WhatIf behauptet keine Modellabhängigkeit' ($null -eq $removePreview.ModelKey -and $null -eq $removePreview.Revision -and $removePreview.ModelSelection -ceq 'NOT_REQUIRED' -and $script:events.Count -eq 0 -and -not(Test-Path $Root))
            Check 'Migrate verlangt die explizite Zielwahl' (Reject {New-LabAiPersistentPlan @script:parameters -TargetModelKey ollama-nomic-embed-text-v2-moe} 'AI_PERSISTENT_MIGRATION_TARGET_UNEXPECTED')
            $null=Execute
            Check 'Initial ist keine zulässige Migrationsquelle' (Reject {Execute -Action Migrate} 'AI_PERSISTENT_MIGRATION_SOURCE_REQUIRED')
            $null=Execute -Revision Delta
            $before=Get-Content (JournalPath) -Raw
            $script:targetDrift=$true;$script:missingSource=$true
            Check 'Unverfügbare Quelle verhindert Upgrade vor Journaländerung' (Reject {Execute -Action Migrate} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            Check 'Vorabfehler erhält vollständiges v1-Journal' ((Get-Content (JournalPath) -Raw) -ceq $before)
            $script:targetDrift=$false;$script:missingSource=$false
            foreach($point in @('AfterUpgradeIntent','AfterUpgradeSql')){
                Reset;$null=Execute;$null=Execute -Revision Delta
                $fault={param($Step,$Id)if($Step -eq $point){throw 'lost upgrade response'}}.GetNewClosure()
                Check "$point ist ein sichtbarer Recoveryfall" (Reject {Execute -Action Migrate -Fault $fault} 'AI_PERSISTENT_RECOVERY_REQUIRED')
                $j=Get-Content (JournalPath) -Raw|ConvertFrom-Json
                Check "$point erhält alte aktive Generation und v2-Intent" ($j.contract -ceq 'SqlServerLab.AiPersistentJournal/2.0' -and $j.status -eq 'UPGRADE_PENDING' -and $script:owner.ActiveGeneration -eq 2)
                $q=Execute -Action Query
                Check "$point erlaubt alte Query ohne Upgrade-Mutation" ($q.Generation -eq 2 -and $q.ModelKey -eq 'ollama-embeddinggemma-latest' -and $script:requests[-1].Body.input[0] -notlike 'search_*')
                Check "$point verlangt explizites Resume" (Reject {Execute -Action Migrate} 'AI_PERSISTENT_RESUME_REQUIRED')
                $r=Execute -Action Migrate -Resume
                Check "$point wird genau einmal atomar upgraded und vollständig eingebettet" ($r.Generation -eq 3 -and $r.EmbeddingRequests -eq 3 -and $r.CopiedChunks -eq 0 -and @($script:events|Where-Object{$_ -eq 'Upgrade'}).Count -eq 1)
            }
            Reset;$null=Execute;$null=Execute -Revision Delta
            $originalBytes=[IO.File]::ReadAllBytes((JournalPath))
            function script:Write-LabArtifactJsonAtomic {param($Path,$InputObject)throw 'synthetic write failure'}
            Check 'Upgradeintent-Schreibfehler erreicht kein SQL-DDL' (Reject {Execute -Action Migrate} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            Check 'Upgradeintent-Schreibfehler erhält alte Bytes' ([Convert]::ToHexString([IO.File]::ReadAllBytes((JournalPath))) -ceq [Convert]::ToHexString($originalBytes) -and -not $script:receipt)
            Set-Item Function:script:Write-LabArtifactJsonAtomic $originalWrite
            $script:fail='Upgrade'
            Check 'SQL-Upgradefehler hinterlässt nur den v2-Intent ohne Zielgeneration' (Reject {Execute -Action Migrate} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            Check 'Abgewiesenes Upgrade erhält lesbare Quelle' (-not $script:receipt -and (Execute -Action Query).Generation -eq 2)
            $script:fail=''
            Check 'Resume nach Upgradefehler erreicht gezielten Stagingabbruch' (Reject {Execute -Action Migrate -Resume -Fault {param($Step,$Id)if($Step -eq 'AfterChunkSql'){throw 'lost chunk'}}} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            Check 'Zielstaging kopiert keine Quellvektoren' ($script:chunks[3].Count -eq 1 -and $script:owner.ActiveGeneration -eq 2 -and @($script:events|Where-Object{$_ -eq 'Copy'}).Count -eq 1)
            $documentRequest=$script:requests[-1]
            Check 'Ziel-Dokumentpayload enthält exakt das Dokumentpräfix' ($documentRequest.Body.model -ceq 'nomic-embed-text-v2-moe:latest' -and $documentRequest.Body.input[0] -ceq ('search_document: '+$script:chunks[2]['backup-policy'].Content))
            $beforeQuery=$script:events.Count;$old=Execute -Action Query
            $queryEvents=@($script:events|Select-Object -Skip $beforeQuery)
            Check 'SQLactive wird vor dem Query-Modellzugriff geprüft' ($queryEvents.IndexOf('Owner') -lt $queryEvents.IndexOf('Metadata') -and $old.Generation -eq 2)
            $savedVector=$script:chunks[2]['backup-policy'].VectorHash
            $script:chunks[2]['backup-policy'].VectorHash='f'*64;$script:chunks[2]['backup-policy'].ActualVectorHash='f'*64;$before=$script:payloads
            Check 'Quellquery blockiert konsistent geänderten Vektor samt Marker gegen das Migrationsreceipt vor Embedding' ((Reject {Execute -Action Query} 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT') -and $script:payloads -eq $before)
            $script:chunks[2]['backup-policy'].VectorHash=$savedVector;$script:chunks[2]['backup-policy'].ActualVectorHash=$savedVector
            $script:targetDrift=$true
            Check 'Zieldigestdrift blockiert Resume' (Reject {Execute -Action Migrate -Resume} 'AI_PERSISTENT_MODEL_DRIFT')
            Check 'Zieldrift blockiert keine aktive Quellquery' ((Execute -Action Query).Generation -eq 2)
            $script:targetDrift=$false
            $script:modelDrift=$true
            Check 'Quelldigestdrift blockiert unvollständiges Migrate-Resume' (Reject {Execute -Action Migrate -Resume} 'AI_PERSISTENT_MODEL_DRIFT')
            $script:modelDrift=$false
            $fileLock=[IO.File]::Open((JournalPath)+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try{Check 'Migrate-Resume respektiert denselben exklusiven Dateilock' (Reject {Execute -Action Migrate -Resume} 'AI_PERSISTENT_LOCKED')}finally{$fileLock.Dispose()}
            $script:fail='Locked';$before=$script:payloads
            Check 'SQL-AppLock blockiert Migrate vor Modellpayload' ((Reject {Execute -Action Migrate -Resume} 'AI_PERSISTENT_SQL_LOCKED') -and $script:payloads -eq $before)
            $script:fail=''
            $j=Get-Content (JournalPath) -Raw|ConvertFrom-Json;$j.migration.targetProfileHash='f'*64
            Check 'Verändertes Präfixprofil wird vor Persistenz abgewiesen' (Reject {Write-LabAiPersistentJournal (JournalPath) $j} 'AI_PERSISTENT_MIGRATION_JOURNAL_DRIFT')
            $beforeRequests=$script:requests.Count
            Check 'Commitantwortverlust ist sichtbarer Recoveryfall' (Reject {Execute -Action Migrate -Resume -Fault {param($Step,$Id)if($Step -eq 'AfterCommitSql'){throw 'lost commit'}}} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            Check 'Resume verarbeitet nur zwei fehlende Zielchunks' ($script:requests.Count-$beforeRequests -eq 2 -and $script:generations.Count -eq 3)
            $j=Get-Content (JournalPath) -Raw|ConvertFrom-Json
            Check 'SQL-Cutover liegt nach Antwortverlust vor Journalfinalisierung' ($script:owner.ActiveGeneration -eq 3 -and $j.activeGeneration -eq 2 -and $j.status -eq 'STAGING')
            $script:missingSource=$true;$q=Execute -Action Query
            Check 'Query nutzt vor Journalreparatur ausschließlich aktives Zielmodell' ($q.Generation -eq 3 -and $q.ModelKey -ceq 'ollama-nomic-embed-text-v2-moe' -and $script:requests[-1].Body.input[0] -ceq 'search_query: Wie oft werden synthetische Sicherungen überprüft?')
            $savedPlan=$script:generations[3].PlanKey;$script:generations[3].PlanKey='f'*64;$before=$script:payloads
            Check 'Aktiver PlanKey-Drift blockiert vor Queryembedding' ((Reject {Execute -Action Query} 'AI_PERSISTENT_GENERATION_DRIFT') -and $script:payloads -eq $before)
            $script:generations[3].PlanKey=$savedPlan
            function script:Write-LabArtifactJsonAtomic {param($Path,$InputObject)throw 'synthetic finalization failure'}
            Check 'Journalfehler nach SQLcommit erzeugt keinen zweiten Cutover' (Reject {Execute -Action Migrate -Resume} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            Check 'Zielquery bleibt trotz fehlgeschlagener Journalfinalisierung verfügbar' ((Execute -Action Query).Generation -eq 3)
            Set-Item Function:script:Write-LabArtifactJsonAtomic $originalWrite
            $replay=Execute -Action Migrate -Resume
            Check 'SQL-Commitreceipt finalisiert ohne neue Embeddings oder Generation' ($replay.EmbeddingRequests -eq 0 -and $script:generations.Count -eq 3)
            Check 'SQL-Cutover prüft Receiptprofil und Quellvektoren in derselben Transaktion' ($script:commitSql -match 'LabMigrationReceipt WITH\(UPDLOCK,HOLDLOCK\)' -and $script:commitSql -match 'SourceVectorSha256' -and $script:commitSql -match 'DATALENGTH\(Receipt\)')
            $caller=@([pscustomobject]@{Id='synthetic-guide';Content='Synthetischer Inhalt für die getrennte Sync-Grenze.'})
            $syncPlan=New-LabAiPersistentPlan -RunId $script:run -InstanceId primary -CollectionId $script:collection -Action Sync -FixtureRevision Initial -QueryId backup -Documents $caller -ExpectedDocuments $caller -LocalPort 11434 -TimeoutSeconds 300
            Check 'Caller-Sync bleibt nach dem getrennten Nomic-Modellupgrade explizit blockiert' (Reject {Invoke-LabAiPersistentRetrieval -Plan $syncPlan -StateRoot $Root -SqlExecutor $sql -MetadataTransport $metadata -EmbeddingTransport $transport} 'AI_PERSISTENT_SYNC_MIGRATION_UNSUPPORTED')
            Check 'Apply nach Modellmigration kann nicht zurückschalten' (Reject {Execute -Revision Delta} 'AI_PERSISTENT_STALE_REVISION')
            $script:receipt.UpgradeId=[guid]::NewGuid().ToString('D')
            Check 'Fremdes SQL-Upgradereceipt blockiert Query' (Reject {Execute -Action Query} 'AI_PERSISTENT_MIGRATION_RECEIPT_DRIFT')
            $script:targetDrift=$true
            Check 'Remove bleibt unabhängig von beiden Modellverfügbarkeiten' ((Execute -Action Remove).Status -eq 'REMOVED' -and -not $script:db)

            Reset
            $callerInitial=@(
                [pscustomobject]@{Id='caller-alpha';Content='Alpha beschreibt eine synthetische Sicherungsrichtlinie.'},
                [pscustomobject]@{Id='caller-beta';Content='Beta beschreibt einen synthetischen Wiederanlauf.'}
            )
            $callerSecond=@(
                [pscustomobject]@{Id='caller-alpha';Content='Alpha beschreibt eine aktualisierte synthetische Sicherungsrichtlinie.'},
                [pscustomobject]@{Id='caller-gamma';Content='Gamma beschreibt eine synthetische Aufbewahrung.'}
            )
            $callerThird=@(
                [pscustomobject]@{Id='caller-alpha';Content='Alpha beschreibt eine aktualisierte synthetische Sicherungsrichtlinie.'},
                [pscustomobject]@{Id='caller-delta';Content='Delta beschreibt einen synthetischen Restoretest.'}
            )
            $null=ExecuteCaller -Action Apply -Documents $callerInitial
            $null=ExecuteCaller -Action Sync -Documents $callerSecond -ExpectedDocuments $callerInitial
            $null=ExecuteCaller -Action Sync -Documents $callerThird -ExpectedDocuments $callerSecond
            $callerPreview=Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -Action Migrate -Documents $callerThird -TargetModelKey ollama-nomic-embed-text-v2-moe -WhatIf
            Check 'Caller-Migrate WhatIf bindet Dokumentzahl und Zielmodell ohne Statezugriff' ($callerPreview.DatasetMode -ceq 'CallerSupplied' -and $callerPreview.DocumentCount -eq 2 -and $callerPreview.Revision -ceq 'Managed' -and $callerPreview.ModelKey -ceq 'ollama-nomic-embed-text-v2-moe')
            $oversized=@([pscustomobject]@{Id='caller-large';Content=('x'*500)})
            Check 'Caller-Migrate weist ein Zielmodell-Input über 512 UTF-8-Bytes planend ab' (Reject {New-LabAiPersistentPlan -RunId $script:run -InstanceId primary -CollectionId $script:collection -Action Migrate -FixtureRevision Initial -QueryId backup -Documents $oversized -TargetModelKey ollama-nomic-embed-text-v2-moe -LocalPort 11434 -TimeoutSeconds 300} 'AI_PERSISTENT_MODEL_INPUT_LIMIT_EXCEEDED')
            $beforeRequests=$script:requests.Count
            Check 'Unterbrochenes Caller-Migrate hält die dynamische Quelle aktiv' (Reject {ExecuteCaller -Action Migrate -Documents $callerThird -Fault {param($Step,$Id)if($Step -eq 'AfterChunkSql'){throw 'lost caller chunk'}}} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            Check 'Caller-Migrate verlangt nach Teilstaging explizites Resume' (Reject {ExecuteCaller -Action Migrate -Documents $callerThird} 'AI_PERSISTENT_RESUME_REQUIRED')
            $sourceQuery=ExecuteCaller -Action Query -Documents $callerThird
            Check 'Caller-Query bleibt während Zielstaging auf der gebundenen Quelle' ($sourceQuery.Generation -eq 3 -and $sourceQuery.ModelKey -ceq 'ollama-embeddinggemma-latest' -and $script:owner.ActiveGeneration -eq 3)
            $callerMigration=ExecuteCaller -Action Migrate -Documents $callerThird -Resume
            Check 'Caller-Migrate nutzt die aktive Generation und schneidet atomar auf die nächste um' ($callerMigration.Generation -eq 4 -and $script:owner.ActiveGeneration -eq 4 -and $callerMigration.EmbeddingRequests -eq 1 -and $script:generations[3].Status -ceq 'COMMITTED')
            Check 'Caller-Migrate erzeugt jeden Zielvektor neu und Resume ergänzt nur den fehlenden' ($script:requests.Count-$beforeRequests -eq 3 -and @($script:events|Where-Object{$_ -eq 'Copy'}).Count -eq 1)
            $callerJournalText=Get-Content (JournalPath) -Raw
            $callerJournal=$callerJournalText|ConvertFrom-Json
            Check 'Caller-Migrationsjournal bindet dynamische Generationen ohne Dokumentinhalt' ($callerJournal.migration.datasetMode -ceq 'CallerSupplied' -and $callerJournal.migration.sourceGeneration -eq 3 -and $callerJournal.migration.targetGeneration -eq 4 -and $callerJournal.migration.sourceRevision -ceq 'Managed' -and $callerJournalText -notmatch 'aktualisierte synthetische')
            $callerQuery=ExecuteCaller -Action Query -Documents $callerThird
            Check 'Caller-Query verwendet nach Cutover Nomic und die freie Frage' ($callerQuery.Generation -eq 4 -and $callerQuery.DatasetMode -ceq 'CallerSupplied' -and $callerQuery.ModelKey -ceq 'ollama-nomic-embed-text-v2-moe' -and $callerQuery.Ranked.Count -eq 2 -and $script:requests[-1].Body.input[0] -ceq 'search_query: Welche synthetische Richtlinie gilt?')
            $largeQueryPlan=New-LabAiPersistentPlan -RunId $script:run -InstanceId primary -CollectionId $script:collection -Action Query -FixtureRevision Initial -QueryId backup -Documents $callerThird -Question ('q'*500) -LocalPort 11434 -TimeoutSeconds 300
            $beforePayloads=$script:payloads
            Check 'Caller-Zielquery weist ein Input über 512 UTF-8-Bytes vor Embedding ab' ((Reject {Invoke-LabAiPersistentRetrieval -Plan $largeQueryPlan -StateRoot $Root -SqlExecutor $sql -MetadataTransport $metadata -EmbeddingTransport $transport} 'AI_PERSISTENT_MODEL_INPUT_LIMIT_EXCEEDED') -and $script:payloads -eq $beforePayloads)
            $wrong=@([pscustomobject]@{Id='caller-alpha';Content='Falscher Bestand.'})
            $beforePayloads=$script:payloads
            Check 'Caller-Query weist einen anderen vollständigen Bestand vor Embedding ab' ((Reject {ExecuteCaller -Action Query -Documents $wrong} 'AI_PERSISTENT_REQUEST_BINDING_DRIFT') -and $script:payloads -eq $beforePayloads)
            $beforePayloads=$script:payloads;$callerReplay=ExecuteCaller -Action Migrate -Documents $callerThird
            Check 'Caller-Migration wird nach bestätigtem Cutover nur idempotent bestätigt' ($callerReplay.Generation -eq 4 -and $callerReplay.EmbeddingRequests -eq 0 -and $script:payloads -eq $beforePayloads)
        }finally{
            Set-Item Function:script:Get-LabTransferBinding $originalBinding;Set-Item Function:script:Assert-LabTransferBinding $originalAssert;Set-Item Function:script:Write-LabArtifactJsonAtomic $originalWrite
        }
        $checks.ToArray()
    } $temporaryRoot
    foreach($check in $checks){Write-Host "$(if($check.Success){'PASS'}else{'FAIL'}): $($check.Name)"}
    if(@($checks|Where-Object{-not $_.Success}).Count){throw 'AI persistent checks failed'}
    Write-Host "AI MODEL MIGRATION CHECKS: PASS ($($checks.Count))"
}finally{
    Remove-Module $module.Name -Force
    if(Test-Path -LiteralPath $temporaryRoot){$absolute=[IO.Path]::GetFullPath($temporaryRoot);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar;if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup'};Remove-Item -LiteralPath $absolute -Recurse -Force}
}
