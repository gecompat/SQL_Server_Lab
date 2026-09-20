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
            $script:events=[Collections.Generic.List[string]]::new();$script:bindingDrift=$false;$script:modelDrift=$false;$script:fail='';$script:payloads=0
            $script:db=$false;$script:owner=$null;$script:generations=@{};$script:chunks=@{};$script:guid='ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF'
            $script:collection=[guid]::NewGuid().ToString('D');$script:run='11111111-1111-4111-8111-111111111111'
            $script:parameters=@{RunId=$script:run;InstanceId='primary';CollectionId=$script:collection;Action='Apply';FixtureRevision='Initial';QueryId='backup';LocalPort=11434;TimeoutSeconds=300}
        }
        $metadata={param($Path,$Model)
            $script:events.Add('Metadata')
            switch($Path){
                '/api/version' {@{version='0.34.2'}}
                '/api/tags' {@{models=@([pscustomobject]@{name=$Model;digest=$(if($script:modelDrift){'b'*64}else{'a'*64})})}}
                '/api/show' {[pscustomobject]@{capabilities=@('embedding');model_info=[pscustomobject]@{'gemma.embedding_length'=768}}}
            }
        }
        $transport={param($Request)$script:payloads++;[pscustomobject]@{StatusCode=200;Body=@{embeddings=@(,@(1..768|ForEach-Object{0.01}))}}}
        $sql={param($Step,$Sql,$P)
            $script:events.Add($Step)
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
                Commit {if($script:owner.ActiveGeneration -ne $P.previous -or $script:chunks[$P.generation].Count -ne 3){throw 'cutover conflict'};$script:generations[$P.generation].Status='COMMITTED';$script:owner.ActiveGeneration=$P.generation}
                Query {foreach($row in @($script:chunks[$script:owner.ActiveGeneration].Values|Sort-Object ChunkId)){[pscustomobject]@{ChunkId=$row.ChunkId;ContentHash=$(if($script:fail -eq 'QueryHash'){'d'*64}else{$row.ContentHash});Distance=0.1}}}
                Remove {$script:db=$false;$script:owner=$null}
                default {throw "Unexpected SQL step $Step"}
            }
        }
        function Execute {param([string]$Action='Apply',[string]$Revision='Initial',[switch]$Resume,[scriptblock]$Fault)
            $p=$script:parameters.Clone();$p.Action=$Action;$p.FixtureRevision=$Revision;$p.Resume=[bool]$Resume
            $plan=New-LabAiPersistentPlan @p
            Invoke-LabAiPersistentRetrieval -Plan $plan -StateRoot $Root -SqlExecutor $sql -MetadataTransport $metadata -EmbeddingTransport $transport -FaultInjector $Fault
        }
        function JournalPath {Join-Path $Root "runs/$script:run/ai-persistent/primary-$script:collection.json"}
        try{
            Reset
            $null=Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId $script:collection -StateRoot $Root -WhatIf
            Check 'Public WhatIf berührt weder State noch Binding, Modell oder SQL' ($script:events.Count -eq 0 -and -not(Test-Path $Root))
            Check 'Ungültige GUID scheitert auch im rein planenden öffentlichen Aufruf' (Reject {Invoke-SqlServerLabAiPersistentRetrieval -RunId $script:run -CollectionId ('-'*36) -WhatIf} 'AI_PERSISTENT_IDENTITY_INVALID')
            $first=Execute
            Check 'Initial erstellt drei persistente Chunks und aktiviert genau eine Generation' ($first.Status -eq 'COMMITTED' -and $first.EmbeddingRequests -eq 3 -and $script:owner.ActiveGeneration -eq 1 -and $script:chunks[1].Count -eq 3)
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
