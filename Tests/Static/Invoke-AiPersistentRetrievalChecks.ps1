#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-persistent-check-'+[guid]::NewGuid().ToString('N'))
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
            $script:events=[Collections.Generic.List[string]]::new();$script:sqlTexts=[Collections.Generic.List[string]]::new();$script:embeddingInputs=[Collections.Generic.List[string]]::new();$script:bindingDrift=$false;$script:modelDrift=$false;$script:fail='';$script:payloads=0;$script:dimension=768
            $script:db=$false;$script:owner=$null;$script:generations=@{};$script:chunks=@{};$script:guid='ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF'
            $script:collection=[guid]::NewGuid().ToString('D');$script:run='11111111-1111-4111-8111-111111111111'
            $script:parameters=@{RunId=$script:run;InstanceId='primary';CollectionId=$script:collection;Action='Apply';FixtureRevision='Initial';QueryId='backup';LocalPort=11434;TimeoutSeconds=300}
        }
        $metadata={param($Path,$Model)
            $script:events.Add('Metadata')
            switch($Path){
                '/api/version' {@{version='0.34.2'}}
                '/api/tags' {@{models=@([pscustomobject]@{name=$Model;digest=$(if($script:modelDrift){'b'*64}else{'a'*64})})}}
                '/api/show' {[pscustomobject]@{capabilities=@('embedding');model_info=[pscustomobject]@{'synthetic.embedding_length'=$script:dimension}}}
            }
        }
        $transport={param($Request)$script:payloads++;$script:embeddingInputs.Add([string]$Request.Body.input[0]);[pscustomobject]@{StatusCode=200;Body=@{embeddings=@(,@(1..$script:dimension|ForEach-Object{0.01}))}}}
        $sql={param($Step,$Sql,$P)
            $script:events.Add($Step)
            $script:sqlTexts.Add("$Step|$Sql")
            if($Step -ceq $script:fail){throw 'synthetic SQL failure'}
            switch($Step){
                Lock {@{LockResult=0}}
                Database {if($script:db){[pscustomobject]@{DatabaseGuid=$script:guid;State='ONLINE';IsReadOnly=$false}}}
                Create {if($script:db){throw 'collision'};$script:db=$true}
                Initialize {$script:owner=[pscustomobject]@{OwnerToken=$P.token;RunId=$P.run;ScopeId=$P.scope;InstanceId=$P.instance;CollectionId=$P.collection;DatabaseGuid=$script:guid;ActiveGeneration=0}}
                Owner {if($script:owner){$script:owner}}
                Generation {if($script:generations.ContainsKey($P.generation)){$script:generations[$P.generation]}}
                Chunks {if($script:chunks.ContainsKey($P.generation)){@($script:chunks[$P.generation].Values|Sort-Object ChunkId)}}
                Stage {$script:generations[$P.generation]=[pscustomobject]@{Generation=$P.generation;OperationId=$P.operation;PlanKey=$P.plan;Revision=$P.revision;DatasetHash=$P.dataset;ModelHash=$P.model;Status='STAGING'};$script:chunks[$P.generation]=@{}}
                Insert {if($script:chunks[$P.generation].ContainsKey($P.id)){throw 'duplicate'};$script:chunks[$P.generation][$P.id]=[pscustomobject]@{ChunkId=$P.id;Content=$P.content;ContentHash=$P.hash;VectorHash='c'*64;ActualVectorHash='c'*64}}
                Copy {$script:chunks[$P.generation][$P.id]=$script:chunks[$P.previous][$P.id].PSObject.Copy()}
                Commit {if($script:owner.ActiveGeneration -ne $P.previous -or $script:chunks[$P.generation].Count -ne $P.documentCount){throw 'cutover conflict'};$script:generations[$P.generation].Status='COMMITTED';$script:owner.ActiveGeneration=$P.generation}
                Query {foreach($row in @($script:chunks[$script:owner.ActiveGeneration].Values|Sort-Object ChunkId)){[pscustomobject]@{ChunkId=$row.ChunkId;ContentHash=$(if($script:fail -eq 'QueryHash'){'d'*64}else{$row.ContentHash});Distance=0.1}}}
                HybridQuery {foreach($row in @($script:chunks[$script:owner.ActiveGeneration].Values|Sort-Object ChunkId)){[pscustomobject]@{ChunkId=$row.ChunkId;ContentHash=$row.ContentHash;Distance=0.1;LexicalScore=$(if($row.ChunkId -ceq 'backup-policy'){0.75}else{0.25});HybridScore=$(if($row.ChunkId -ceq 'backup-policy'){0.855}else{0.705})}}}
                Prune {$keep=@($script:generations.Keys|Sort-Object -Descending|Select-Object -First $P.keep);$drop=@($script:generations.Keys|Where-Object{$_ -notin $keep});$deletedChunks=0;foreach($generation in $drop){$deletedChunks+=$script:chunks[$generation].Count;$script:chunks.Remove($generation);$script:generations.Remove($generation)};[pscustomobject]@{RetainedGenerations=$keep.Count;DeletedGenerations=$drop.Count;DeletedChunks=$deletedChunks}}
                Remove {$script:db=$false;$script:owner=$null}
                default {throw "Unexpected SQL step $Step"}
            }
        }
        function Execute {param([string]$Action='Apply',[string]$Revision='Initial',[ValidateSet('Vector','Hybrid')][string]$SearchMode='Vector',[object[]]$Documents,[object[]]$ExpectedDocuments,[string]$Question,[switch]$Resume,[scriptblock]$Fault,[int]$KeepGenerations=2,[string]$EmbeddingModelKey)
            $p=$script:parameters.Clone();$p.Action=$Action;$p.FixtureRevision=$Revision;$p.Resume=[bool]$Resume
            $p.SearchMode=$SearchMode
            if($Action -eq 'Migrate'){$p.TargetModelKey='ollama-nomic-embed-text-v2-moe'}
            if($null -ne $Documents){$p.Documents=$Documents}
            if($null -ne $ExpectedDocuments){$p.ExpectedDocuments=$ExpectedDocuments}
            if($Question){$p.Question=$Question}
            if($EmbeddingModelKey){$p.EmbeddingModelKey=$EmbeddingModelKey}
            $p.KeepGenerations=$KeepGenerations
            $plan=New-LabAiPersistentPlan @p
            Invoke-LabAiPersistentRetrieval -Plan $plan -StateRoot $Root -SqlExecutor $sql -MetadataTransport $metadata -EmbeddingTransport $transport -FaultInjector $Fault
        }
        function JournalPath {Join-Path $Root "runs/$script:run/ai-persistent/primary-$script:collection.json"}
        try{
            Reset
            $null=Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -StateRoot $Root -WhatIf
            Check 'Public WhatIf berührt weder State noch Binding, Modell oder SQL' ($script:events.Count -eq 0 -and -not(Test-Path $Root))
            Check 'Ungültige GUID scheitert auch im rein planenden öffentlichen Aufruf' (Reject {Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId ('-'*36) -WhatIf} 'AI_PERSISTENT_IDENTITY_INVALID')
            Check 'Hybridmodus ist ausschließlich für Query zulässig' (Reject {Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -SearchMode Hybrid -WhatIf} 'AI_PERSISTENT_SEARCH_MODE_INVALID')
            $custom=@(
                [pscustomobject]@{Id='restore-guide';Content='Synthetische Restore-Tests prüfen CHECKDB nach der Wiederherstellung.'},
                [pscustomobject]@{Id='index-guide';Content='Synthetische Index-Tests vergleichen reproduzierbare Abfragepläne.'},
                [pscustomobject]@{Id='security-guide';Content='Synthetische Sicherheitstests prüfen ausschließlich Testidentitäten.'}
            )
            $customPreview=Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -Documents $custom -WhatIf
            Check 'Caller-Dokumente bleiben im WhatIf rein planend und werden nur gezählt' ($customPreview.DatasetMode -ceq 'CallerSupplied' -and $customPreview.DocumentCount -eq 3 -and $script:events.Count -eq 0 -and -not(Test-Path $Root))
            $updatedPreview=@([pscustomobject]@{Id='restore-guide';Content='Neuer synthetischer Inhalt.'},$custom[1])
            $syncPreview=Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -Action Sync -Documents $updatedPreview -ExpectedDocuments $custom -WhatIf
            Check 'Sync-WhatIf zählt Ausgang und Ziel ohne Dokumentinhalt' ($syncPreview.ExpectedDocumentCount -eq 3 -and $syncPreview.DocumentCount -eq 2 -and ($syncPreview|ConvertTo-Json -Compress) -notmatch 'Neuer synthetischer Inhalt')
            Check 'Sync verlangt den vollständigen erwarteten Ausgangsbestand' (Reject {Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -Action Sync -Documents $updatedPreview -WhatIf} 'AI_PERSISTENT_DOCUMENTS_INVALID')
            Check 'ExpectedDocuments gilt ausschließlich für Sync' (Reject {Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -Documents $custom -ExpectedDocuments $custom -WhatIf} 'AI_PERSISTENT_EXPECTED_DOCUMENTS_UNEXPECTED')
            Check 'Prune weist Dokumentpayloads und ungültige Retention planend ab' ((Reject {Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -Action Prune -Documents $custom -WhatIf} 'AI_PERSISTENT_RETENTION_REQUEST_INVALID') -and (Reject {$invalid=$script:parameters.Clone();$invalid.Action='Prune';$invalid.KeepGenerations=32;New-LabAiPersistentPlan @invalid} 'AI_PERSISTENT_RETENTION_REQUEST_INVALID'))
            Check 'KeepGenerations gilt ausschließlich für Prune' ((Reject {Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -KeepGenerations 2 -WhatIf} 'AI_PERSISTENT_RETENTION_UNEXPECTED') -and (Reject {New-LabAiPersistentPlan @script:parameters -KeepGenerations 3} 'AI_PERSISTENT_RETENTION_UNEXPECTED'))
            Check 'Doppelte Caller-Dokument-IDs werden vor State und Modell abgewiesen' (Reject {Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -Documents @($custom[0],$custom[0]) -WhatIf} 'AI_PERSISTENT_DOCUMENTS_INVALID')
            Reset
            $customResult=Execute -Documents $custom
            Check 'Caller-Dokumente erzeugen eine gebundene initiale SQL-Generation' ($customResult.DatasetMode -ceq 'CallerSupplied' -and $customResult.EmbeddingRequests -eq 3 -and $script:owner.ActiveGeneration -eq 1 -and $script:chunks[1].Count -eq 3)
            $customQuery=Execute -Action Query -Documents $custom -Question 'Was prüfen synthetische Restore-Tests?'
            Check 'Freie Frage liest ausschließlich die gebundene Caller-Collection' ($customQuery.DatasetMode -ceq 'CallerSupplied' -and $customQuery.Ranked.Count -eq 3 -and 'restore-guide' -in $customQuery.Ranked.ChunkId)
            $beforeCustomDrift=$script:payloads
            $changed=@($custom[0],[pscustomobject]@{Id='index-guide';Content='Geänderter synthetischer Inhalt.'})
            Check 'Abweichende Caller-Dokumente blockieren Query vor Embedding' ((Reject {Execute -Action Query -Documents $changed -Question 'Welche Tests?'} 'AI_PERSISTENT_GENERATION_DRIFT') -and $script:payloads -eq $beforeCustomDrift)
            $updated=@(
                [pscustomobject]@{Id='restore-guide';Content='Synthetische Restore-Tests prüfen CHECKDB und den Datenstatus.'},
                $custom[1],
                [pscustomobject]@{Id='cleanup-guide';Content='Synthetische Testressourcen werden nach der Abnahme entfernt.'}
            )
            $sync=Execute -Action Sync -Documents $updated -ExpectedDocuments $custom
            Check 'Sync kopiert unveränderte Vektoren und bettet Update sowie Insert neu ein' ($sync.Generation -eq 2 -and $sync.EmbeddingRequests -eq 2 -and $sync.CopiedChunks -eq 1 -and $script:owner.ActiveGeneration -eq 2)
            $updatedQuery=Execute -Action Query -Documents $updated -Question 'Was geschieht nach der Abnahme?'
            Check 'Sync aktiviert Update, Insert und Delete atomar für folgende Queries' ($updatedQuery.Generation -eq 2 -and 'cleanup-guide' -in $updatedQuery.Ranked.ChunkId -and 'security-guide' -notin $updatedQuery.Ranked.ChunkId)
            $wrongExpected=@($custom[0],$custom[1],[pscustomobject]@{Id='security-guide';Content='Abweichender Altinhalt.'})
            $beforeSyncDrift=$script:payloads
            Check 'Sync mit falschem erwarteten Ausgangsstand scheitert vor Embedding' ((Reject {Execute -Action Sync -Documents $custom -ExpectedDocuments $wrongExpected} 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT') -and $script:payloads -eq $beforeSyncDrift)
            $secondSync=Execute -Action Sync -Documents $custom -ExpectedDocuments $updated
            Check 'Weitere Sync-Generation verwendet den jeweils aktiven gebundenen Ausgangsstand' ($secondSync.Generation -eq 3 -and $secondSync.EmbeddingRequests -eq 2 -and $secondSync.CopiedChunks -eq 1 -and $script:owner.ActiveGeneration -eq 3)
            $prunePreview=Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -Action Prune -KeepGenerations 2 -WhatIf
            Check 'Prune-WhatIf ist modellfrei und bindet die Retention' ($prunePreview.KeepGenerations -eq 2 -and $prunePreview.ModelSelection -ceq 'NOT_REQUIRED' -and $prunePreview.DocumentCount -eq 0)
            $pruned=Execute -Action Prune -KeepGenerations 2
            Check 'Prune entfernt nur abgeschlossene inaktive Generationen' ($pruned.Status -ceq 'PRUNED' -and $pruned.Generation -eq 3 -and $pruned.DeletedGenerations -eq 1 -and $pruned.DeletedChunks -eq 3 -and @($script:generations.Keys|Sort-Object) -join ',' -ceq '2,3')
            $prunedAgain=Execute -Action Prune -KeepGenerations 2
            Check 'Prune-Replay ist idempotent und modellfrei' ($prunedAgain.DeletedGenerations -eq 0 -and $prunedAgain.DeletedChunks -eq 0 -and $script:payloads -eq 9)
            $journalText=Get-Content (JournalPath) -Raw
            Check 'Sync-Journal enthält weder aktuelle noch frühere Dokumentinhalte' ($journalText -notmatch 'CHECKDB|Abfragepläne|Testressourcen')
            $null=Execute -Action Remove
            Reset;$null=Execute -Documents $custom
            $syncCrash={param($Step,$Id)if($Step -eq 'AfterChunkSql'){throw 'synthetic sync crash'}}
            Check 'Sync-Abbruch während Staging bleibt explizit sichtbar' (Reject {Execute -Action Sync -Documents $updated -ExpectedDocuments $custom -Fault $syncCrash} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            $beforePruneEvents=@($script:events|Where-Object{$_ -eq 'Prune'}).Count
            Check 'Prune blockiert unvollständiges Staging ohne Löschung' ((Reject {Execute -Action Prune} 'AI_PERSISTENT_RETENTION_UNSUPPORTED') -and @($script:events|Where-Object{$_ -eq 'Prune'}).Count -eq $beforePruneEvents -and $script:generations.Count -eq 2)
            $stagedQuery=Execute -Action Query -Documents $custom -Question 'Welche Tests?'
            Check 'Query liest während Sync-Staging weiterhin vollständig die alte Generation' ($stagedQuery.Generation -eq 1 -and $script:owner.ActiveGeneration -eq 1)
            Check 'Sync-Staging verlangt explizites Resume' (Reject {Execute -Action Sync -Documents $updated -ExpectedDocuments $custom} 'AI_PERSISTENT_RESUME_REQUIRED')
            $syncResume=Execute -Action Sync -Documents $updated -ExpectedDocuments $custom -Resume
            Check 'Sync-Resume übernimmt SQL-bestätigte Chunks ohne erneutes Embedding' ($syncResume.Generation -eq 2 -and $syncResume.EmbeddingRequests -eq 1 -and $syncResume.CopiedChunks -eq 1)
            Reset;$null=Execute -Documents $custom
            $syncLostReply={param($Step,$Id)if($Step -eq 'AfterCommitSql'){throw 'lost sync reply'}}
            Check 'Verlorene Sync-Cutoverantwort wird als Recoveryfall gemeldet' (Reject {Execute -Action Sync -Documents $updated -ExpectedDocuments $custom -Fault $syncLostReply} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            $beforeSyncRecovery=$script:payloads
            $syncRecovered=Execute -Action Sync -Documents $updated -ExpectedDocuments $custom -Resume
            Check 'SQL-Commitreceipt schließt Sync ohne Quell-Revalidierung oder neue Embeddings ab' ($syncRecovered.Generation -eq 2 -and $syncRecovered.EmbeddingRequests -eq 0 -and $script:payloads -eq $beforeSyncRecovery)
            $script:owner.ActiveGeneration=32;$beforeGenerationLimit=$script:payloads
            Check 'Begrenzte Generationenzahl blockiert vor Embedding und neuem Staging' ((Reject {Execute -Action Sync -Documents $custom -ExpectedDocuments $updated} 'AI_PERSISTENT_GENERATION_LIMIT_REACHED') -and $script:payloads -eq $beforeGenerationLimit -and $script:generations.Count -eq 2)
            $null=Execute -Action Remove
            Reset
            $first=Execute
            Check 'Initial erstellt drei persistente Chunks und aktiviert genau eine Generation' ($first.Status -eq 'COMMITTED' -and $first.EmbeddingRequests -eq 3 -and $script:owner.ActiveGeneration -eq 1 -and $script:chunks[1].Count -eq 3)
            $beforeFixturePrune=@($script:events|Where-Object{$_ -eq 'Prune'}).Count
            Check 'Prune übernimmt keine feste Fixture-Collection' ((Reject {Execute -Action Prune} 'AI_PERSISTENT_RETENTION_UNSUPPORTED') -and @($script:events|Where-Object{$_ -eq 'Prune'}).Count -eq $beforeFixturePrune -and $script:generations.Count -eq 1)
            $guidJournal=Read-LabAiPersistentJournal -Path (JournalPath) -Plan (New-LabAiPersistentPlan @script:parameters) -BindingHash ((Get-Content (JournalPath) -Raw|ConvertFrom-Json).bindingHash)
            Check 'Journal-Roundtrip bewahrt die großgeschriebene SQL-GUID wie Receipt und Observation' ($guidJournal.databaseGuid -ceq 'ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF' -and $guidJournal.databaseGuid -ceq $script:owner.DatabaseGuid)
            $guidJournal.databaseGuid='-'*36
            $bytesBeforeInvalid=[Convert]::ToHexString([IO.File]::ReadAllBytes((JournalPath)))
            Check 'GUID-Struktur bleibt trotz zulässiger Großbuchstaben strikt und alte Bytes erhalten' ((Reject {Write-LabAiPersistentJournal -Path (JournalPath) -Journal $guidJournal} 'AI_PERSISTENT_JOURNAL_INVALID') -and [Convert]::ToHexString([IO.File]::ReadAllBytes((JournalPath))) -ceq $bytesBeforeInvalid)
            $again=Execute
            Check 'Identischer erfolgreicher Auftrag ist ohne neue Embeddings idempotent' ($again.EmbeddingRequests -eq 0 -and $script:payloads -eq 3)
            Check 'SQL-Lock wird vor CREATE erworben' ($script:events.IndexOf('Lock') -lt $script:events.IndexOf('Create'))
            $crash={param($Step,$Id)if($Step -eq 'AfterChunkSql'){throw 'synthetic crash'}}
            Check 'Teilabbruch nach SQL-Chunk wird sichtbar' (Reject {Execute -Revision Delta -Fault $crash} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            $j=Get-Content (JournalPath) -Raw|ConvertFrom-Json
            Check 'Verlorene Chunkantwort lässt alte Generation aktiv und Journal hinter SQL' ($script:owner.ActiveGeneration -eq 1 -and $script:chunks[2].Count -eq 1 -and $j.completedChunks.Count -eq 0)
            $q=Execute -Action Query
            Check 'Query liest während Staging ausschließlich die alte Generation' ($q.Generation -eq 1 -and 'network-policy' -in $q.Ranked.ChunkId)
            Check 'Teilzustand verlangt explizites Resume' (Reject {Execute -Revision Delta} 'AI_PERSISTENT_RESUME_REQUIRED')
            $next=Execute -Revision Delta -Resume
            Check 'Resume ergänzt nur fehlende SQL-Chunks und übernimmt unveränderten Vektor' ($next.EmbeddingRequests -eq 1 -and $next.CopiedChunks -eq 1 -and $script:owner.ActiveGeneration -eq 2 -and $script:chunks[1].Count -eq 3)
            $q=Execute -Action Query
            Check 'Delta macht Update und Delete nach atomarer Umschaltung sichtbar' ($q.Generation -eq 2 -and 'network-policy' -notin $q.Ranked.ChunkId -and 'retention-policy' -in $q.Ranked.ChunkId -and $script:chunks[2]['backup-policy'].Content -match 'stündlich')
            Check 'Alte Revision kann aktiven Zeiger nicht zurücksetzen' (Reject {Execute} 'AI_PERSISTENT_STALE_REVISION')
            $script:modelDrift=$true;$before=$script:events.Count
            Check 'Digestdrift blockiert Query vor SQL' (Reject {Execute -Action Query} 'AI_PERSISTENT_MODEL_DRIFT')
            Check 'Bei Modelldrift wird keine SQL-Verbindung geöffnet' ('Lock' -notin @($script:events|Select-Object -Skip $before))
            $removed=Execute -Action Remove
            Check 'Exakt eigenes Remove funktioniert auch ohne weiterhin verfügbares Modell' ($removed.Status -eq 'REMOVED' -and -not $script:db)
            Check 'Remove-Replay bestätigt Abwesenheit ohne zweiten DROP' ((Execute -Action Remove).Status -eq 'REMOVED' -and @($script:events|Where-Object{$_ -eq 'Remove'}).Count -eq 1)
            Reset
            Check 'Verlorene Cutoverantwort ist sichtbarer Recoveryfall' (Reject {Execute -Fault {param($Step,$Id)if($Step -eq 'AfterCommitSql'){throw 'lost reply'}}} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            $before=$script:payloads;$result=Execute -Resume
            Check 'SQL-Commitreceipt repariert Journal ohne zweite Generation oder Embeddings' ($result.Status -eq 'COMMITTED' -and $script:payloads -eq $before -and $script:generations.Count -eq 1)
            $script:owner.OwnerToken='f'*64
            Check 'Fremder Ownershiptoken blockiert Remove ohne DROP' (Reject {Execute -Action Remove} 'AI_PERSISTENT_OWNERSHIP_MISMATCH')
            Check 'Fremde Datenbank bleibt erhalten' ($script:db -and 'Remove' -notin $script:events)
            Reset;$script:fail='Initialize'
            Check 'CREATE-Receipt-Lücke wird nicht als Erfolg ausgegeben' (Reject {Execute} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            $script:fail='';$before=@($script:events|Where-Object{$_ -eq 'Create'}).Count
            Check 'Vorhandene Datenbank ohne Receipt wird beim Resume nicht adoptiert' (Reject {Execute -Resume} 'AI_PERSISTENT_OWNERSHIP_UNPROVEN')
            Check 'Receipt-Lücke löst weder zweites CREATE noch DROP aus' ($script:db -and @($script:events|Where-Object{$_ -eq 'Create'}).Count -eq $before -and 'Remove' -notin $script:events)
            Reset;$script:db=$true
            Check 'Vorhandene Namenskollision wird niemals überschrieben' (Reject {Execute} 'AI_PERSISTENT_OWNERSHIP_UNPROVEN')
            Check 'Kollision erreicht kein CREATE' ('Create' -notin $script:events)
            Reset;$null=Execute
            $hybrid=Execute -Action Query -SearchMode Hybrid
            Check 'Hybridsuche kombiniert gebundene lexikalische und Vektorscores' ($hybrid.SearchMode -ceq 'Hybrid' -and $hybrid.Ranked.Count -eq 3 -and $hybrid.Ranked[0].ChunkId -ceq 'backup-policy' -and 'HybridQuery' -in $script:events)
            $script:guid='55555555-5555-4555-8555-555555555555'
            Check 'Database-GUID-ABA blockiert trotz gleichem Receipt' (Reject {Execute -Action Remove} 'AI_PERSISTENT_DATABASE_IDENTITY_DRIFT')
            $script:guid='ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF';$script:chunks[1]['backup-policy'].ActualVectorHash='e'*64
            Check 'Persistente Vektormanipulation blockiert Query' (Reject {Execute -Action Query} 'AI_PERSISTENT_CHUNK_DRIFT')
            $lock=[IO.File]::Open((JournalPath)+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try{Check 'Exklusive Dateisperre blockiert parallelen Aufruf' (Reject {Execute -Action Query} 'AI_PERSISTENT_LOCKED')}finally{$lock.Dispose()}
            Reset
            function script:Write-LabArtifactJsonAtomic {param($Path,$InputObject)throw 'synthetic atomic failure'}
            Check 'Initialer Journalschreibfehler verhindert SQL-Mutation' (Reject {Execute} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            Check 'Kein SQL-Aufruf vor dauerhaftem Createintent' ('Lock' -notin $script:events -and 'Create' -notin $script:events)
            Set-Item Function:script:Write-LabArtifactJsonAtomic $originalWrite
            Reset;$null=Execute
            $script:generations[1].PlanKey='f'*64
            $beforeEmbeddings=$script:payloads
            $beforeQueries=@($script:events|Where-Object{$_ -eq 'Query'}).Count
            Check 'Manipulierter aktiver PlanKey blockiert Query' (Reject {Execute -Action Query} 'AI_PERSISTENT_GENERATION_DRIFT')
            Check 'Aktive Plandrift erreicht weder Embedding noch Vektorsuche' ($script:payloads -eq $beforeEmbeddings -and @($script:events|Where-Object{$_ -eq 'Query'}).Count -eq $beforeQueries)
            Reset;$null=Execute
            $script:fail='QueryHash'
            Check 'Falscher Hash im Queryresultat scheitert trotz richtiger Dokument-ID' (Reject {Execute -Action Query} 'AI_PERSISTENT_QUERY_INVALID')
            $script:fail='';$script:generations[1].ModelHash='f'*64
            Check 'Delta übernimmt keinen Vektor aus manipuliertem Generationreceipt' (Reject {Execute -Revision Delta} 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT')
            Reset;$null=Execute
            $beforeBytes=[IO.File]::ReadAllBytes((JournalPath));$script:fail='Stage'
            Check 'Stagefehler lässt abgeschlossene Generation intakt' (Reject {Execute -Revision Delta} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            Check 'SQL-Pointer bleibt bei fehlgeschlagener Staginganlage unverändert' ($script:owner.ActiveGeneration -eq 1 -and $script:generations.Count -eq 1)
            $script:fail='';$script:bindingDrift=$true
            Check 'Container- oder Endpointdrift verhindert weitere SQL-Aufrufe' (Reject {Execute -Revision Delta -Resume} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            $deadline=[pscustomobject]@{Timer=[Diagnostics.Stopwatch]::StartNew();TimeoutSeconds=1}
            $plan=New-LabAiPersistentPlan @script:parameters
            Check 'Fehlendes Restbudget blockiert Modellprobe vor Netzwerk' (Reject {Get-LabAiPersistentModel $deadline $plan $metadata} 'AI_PERSISTENT_DEADLINE_EXCEEDED')
            Check 'Fehlendes Restbudget blockiert Embedding vor Payload' (Reject {Get-LabAiPersistentEmbedding $deadline $plan 'synthetic' $transport} 'AI_PERSISTENT_DEADLINE_EXCEEDED')
            Reset;$null=Execute
            $beforeBytes=[IO.File]::ReadAllBytes((JournalPath));$script:savedAtomic=$originalWrite
            function script:Write-LabArtifactJsonAtomic {param($Path,$InputObject)throw 'synthetic atomic failure'}
            Check 'Atomarer Delta-Journalfehler blockiert Staging' (Reject {Execute -Revision Delta} 'AI_PERSISTENT_RECOVERY_REQUIRED')
            Check 'Schreibfehler bewahrt alte Journalbytes und SQL-Generation' ([Convert]::ToHexString([IO.File]::ReadAllBytes((JournalPath))) -ceq [Convert]::ToHexString($beforeBytes) -and $script:generations.Count -eq 1)
            Set-Item Function:script:Write-LabArtifactJsonAtomic $originalWrite
            $outside=Join-Path $Root 'outside';$null=New-Item -ItemType Directory -Path $outside
            $link=Join-Path $Root 'linked-state';$linkType=if($IsWindows){'Junction'}else{'SymbolicLink'}
            $null=New-Item -ItemType $linkType -Path $link -Target $outside
            try{Check 'Reparse-StateRoot blockiert vor Schreiben oder Binding' (Reject {Assert-LabAiPersistentPath (Join-Path $link 'missing/leaf.json')} 'BACKUP_LIBRARY_OBJECT_REPARSE_POINT_BLOCKED')}finally{Remove-Item -LiteralPath $link -Force}
            Reset;$null=Execute
            $tampered=Get-Content (JournalPath) -Raw|ConvertFrom-Json;$tampered.modelBinding.Digest='e'*64
            & $originalWrite -Path (JournalPath) -InputObject $tampered
            Check 'Manipulierte Journal-Modellbindung scheitert vor Live-SQL' (Reject {Execute -Action Query} 'AI_PERSISTENT_JOURNAL_MODEL_INVALID')
            Reset;$script:dimension=1024;$script:parameters.EmbeddingModelKey='ollama-bge-m3-latest'
            $bgeApplied=Execute
            $bgeQuery=Execute -Action Query
            $bgeJournal=Get-Content (JournalPath) -Raw|ConvertFrom-Json
            Check 'BGE-M3 bindet Journal und SQL-Speicher exakt an 1024 Dimensionen' ($bgeApplied.Status -ceq 'COMMITTED' -and $bgeQuery.Status -ceq 'QUERIED' -and $bgeJournal.modelBinding.ModelKey -ceq 'ollama-bge-m3-latest' -and $bgeJournal.modelBinding.Dimension -eq 1024 -and @($script:sqlTexts|Where-Object{$_ -match '^(Initialize|Insert|Query)\|' -and $_ -match 'VECTOR\(1024\)'}).Count -ge 3)
            $script:parameters.Remove('EmbeddingModelKey')
            $bgeRemoved=Execute -Action Remove
            Check 'BGE-M3-Collection bleibt ohne erneute Modellauswahl exakt entfernbar' ($bgeRemoved.Status -ceq 'REMOVED' -and -not $script:db)
            Reset;$script:parameters.EmbeddingModelKey='ollama-nomic-embed-text-v2-moe'
            $nomicPreview=Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -EmbeddingModelKey ollama-nomic-embed-text-v2-moe -WhatIf
            Check 'Nomic-v2-WhatIf bindet 768 Dimensionen ohne Statezugriff' ($nomicPreview.ModelKey -ceq 'ollama-nomic-embed-text-v2-moe' -and $nomicPreview.Dimension -eq 768 -and $script:events.Count -eq 0)
            $nomicApplied=Execute
            $nomicQuery=Execute -Action Query
            $nomicJournal=Get-Content (JournalPath) -Raw|ConvertFrom-Json
            Check 'Nomic v2 bindet Journal und SQL-Speicher exakt an 768 Dimensionen' ($nomicApplied.Status -ceq 'COMMITTED' -and $nomicQuery.Status -ceq 'QUERIED' -and $nomicJournal.modelBinding.ModelKey -ceq 'ollama-nomic-embed-text-v2-moe' -and $nomicJournal.modelBinding.Dimension -eq 768)
            Check 'Nomic v2 präfigiert persistente Dokumente und Fragen rollengetreu' (@($script:embeddingInputs|Where-Object{$_ -clike 'search_document: *'}).Count -eq 3 -and $script:embeddingInputs[-1] -ceq 'search_query: Wie oft werden synthetische Sicherungen überprüft?')
            $oversized=@([pscustomobject]@{Id='oversized-input';Content=('x'*500)})
            Check 'Nomic v2 weist zu große persistente Inputs vor Statezugriff ab' (Reject {Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId ([guid]::NewGuid().ToString('D')) -Documents $oversized -EmbeddingModelKey ollama-nomic-embed-text-v2-moe -WhatIf} 'AI_PERSISTENT_MODEL_INPUT_LIMIT_EXCEEDED')
            Check 'Nomic-v2-Ausgang wird nicht fälschlich als EmbeddingGemma-Migrationsquelle behandelt' (Reject {Execute -Action Migrate -Revision Delta} 'AI_PERSISTENT_MIGRATION_SOURCE_MODEL_UNSUPPORTED')
            $script:parameters.Remove('EmbeddingModelKey')
            $nomicRemoved=Execute -Action Remove
            Check 'Nomic-v2-Collection bleibt ohne erneute Modellauswahl exakt entfernbar' ($nomicRemoved.Status -ceq 'REMOVED' -and -not $script:db)
            Reset;$script:dimension=384;$script:parameters.EmbeddingModelKey='ollama-all-minilm-latest'
            $miniApplied=Execute
            $miniQuery=Execute -Action Query
            $miniJournal=Get-Content (JournalPath) -Raw|ConvertFrom-Json
            Check 'All-MiniLM bindet Journal und SQL-Speicher exakt an 384 Dimensionen' ($miniApplied.Status -ceq 'COMMITTED' -and $miniQuery.Status -ceq 'QUERIED' -and $miniJournal.modelBinding.ModelKey -ceq 'ollama-all-minilm-latest' -and $miniJournal.modelBinding.Dimension -eq 384 -and @($script:sqlTexts|Where-Object{$_ -match '^(Initialize|Insert|Query)\|' -and $_ -match 'VECTOR\(384\)'}).Count -ge 3)
            Check 'All-MiniLM verwendet Dokumente und Fragen ohne Rollenpräfix' (@($script:embeddingInputs|Where-Object{$_ -clike 'search_*'}).Count -eq 0 -and $script:embeddingInputs[-1] -ceq 'Wie oft werden synthetische Sicherungen überprüft?')
            $script:parameters.Remove('EmbeddingModelKey')
            $miniRemoved=Execute -Action Remove
            Check 'All-MiniLM-Collection bleibt ohne erneute Modellauswahl exakt entfernbar' ($miniRemoved.Status -ceq 'REMOVED' -and -not $script:db)
            Reset;$script:parameters.EmbeddingModelKey='ollama-paraphrase-multilingual-latest'
            $paraphraseApplied=Execute
            $paraphraseQuery=Execute -Action Query
            $paraphraseJournal=Get-Content (JournalPath) -Raw|ConvertFrom-Json
            Check 'Paraphrase Multilingual bindet Journal und SQL-Speicher exakt an 768 Dimensionen' ($paraphraseApplied.Status -ceq 'COMMITTED' -and $paraphraseQuery.Status -ceq 'QUERIED' -and $paraphraseJournal.modelBinding.ModelKey -ceq 'ollama-paraphrase-multilingual-latest' -and $paraphraseJournal.modelBinding.Dimension -eq 768 -and @($script:sqlTexts|Where-Object{$_ -match '^(Initialize|Insert|Query)\|' -and $_ -match 'VECTOR\(768\)'}).Count -ge 3)
            Check 'Paraphrase Multilingual verwendet Dokumente und Fragen ohne Rollenpräfix' (@($script:embeddingInputs|Where-Object{$_ -clike 'search_*'}).Count -eq 0 -and $script:embeddingInputs[-1] -ceq 'Wie oft werden synthetische Sicherungen überprüft?')
            $script:parameters.Remove('EmbeddingModelKey')
            $paraphraseRemoved=Execute -Action Remove
            Check 'Paraphrase-Multilingual-Collection bleibt ohne erneute Modellauswahl exakt entfernbar' ($paraphraseRemoved.Status -ceq 'REMOVED' -and -not $script:db)
            Reset;$script:dimension=1024;$script:parameters.EmbeddingModelKey='ollama-snowflake-arctic-embed2-latest'
            $snowflakeApplied=Execute
            $snowflakeQuery=Execute -Action Query
            $snowflakeJournal=Get-Content (JournalPath) -Raw|ConvertFrom-Json
            Check 'Snowflake Arctic Embed 2 bindet Journal und SQL-Speicher exakt an 1024 Dimensionen' ($snowflakeApplied.Status -ceq 'COMMITTED' -and $snowflakeQuery.Status -ceq 'QUERIED' -and $snowflakeJournal.modelBinding.ModelKey -ceq 'ollama-snowflake-arctic-embed2-latest' -and $snowflakeJournal.modelBinding.Dimension -eq 1024 -and @($script:sqlTexts|Where-Object{$_ -match '^(Initialize|Insert|Query)\|' -and $_ -match 'VECTOR\(1024\)'}).Count -ge 3)
            Check 'Snowflake Arctic Embed 2 präfigiert nur die Frage' (@($script:embeddingInputs|Where-Object{$_ -clike 'Represent this sentence for searching relevant passages: *'}).Count -eq 1 -and $script:embeddingInputs[-1] -ceq 'Represent this sentence for searching relevant passages: Wie oft werden synthetische Sicherungen überprüft?')
            $script:parameters.Remove('EmbeddingModelKey')
            $snowflakeRemoved=Execute -Action Remove
            Check 'Snowflake-Arctic-Embed-2-Collection bleibt ohne erneute Modellauswahl exakt entfernbar' ($snowflakeRemoved.Status -ceq 'REMOVED' -and -not $script:db)
            function script:Get-LabTransferBinding {param($RunId,$InstanceId,$StateRoot)throw 'SYNTHETIC_PRIVATE_ENDPOINT_DETAIL'}
            Check 'Öffentlicher Vertrag sanitisiert auch frühe Bindingfehler' (Reject {Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -Action Query -StateRoot $Root -Confirm:$false} '^AI_PERSISTENT_RECOVERY_REQUIRED$')
        }finally{
            Set-Item Function:script:Get-LabTransferBinding $originalBinding;Set-Item Function:script:Assert-LabTransferBinding $originalAssert;Set-Item Function:script:Write-LabArtifactJsonAtomic $originalWrite
        }
        $checks.ToArray()
    } $temporaryRoot
    foreach($check in $checks){Write-Host "$(if($check.Success){'PASS'}else{'FAIL'}): $($check.Name)"}
    if(@($checks|Where-Object{-not $_.Success}).Count){throw 'AI persistent checks failed'}
    Write-Host "AI PERSISTENT RETRIEVAL CHECKS: PASS ($($checks.Count))"
}finally{
    Remove-Module $module.Name -Force
    if(Test-Path -LiteralPath $temporaryRoot){$absolute=[IO.Path]::GetFullPath($temporaryRoot);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar;if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup'};Remove-Item -LiteralPath $absolute -Recurse -Force}
}
