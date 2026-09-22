#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft den expliziten Modellwechsel einer Fixture- und Caller-Collection unter Docker oder Podman.
.DESCRIPTION
    Vorhandenes Host-Embeddinggemma und Nomic v2 MoE; keine Downloads oder
    Host-Lifecycleaktion. Eigener SQL-Run, Upgrade-/Staging-/Commitantwortverlust,
    exakte Rangfolge beider Fixturefragen, Caller-Dokumente und vollständig gebundenes Cleanup.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[ValidateRange(1024,65535)][int]$LocalPort=11434,[switch]$RuntimeMutexAlreadyHeld)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-migration-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $root 'state';$data=Join-Path $root 'Lab_Data';$operation=[guid]::NewGuid().ToString('D');$collection=[guid]::NewGuid().ToString('D')
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
    $null=& $module {param($Port)$plan=New-LabAiEndpointPlan -ModelKey ollama-nomic-embed-text-v2-moe -EndpointRef ollama-local -Lane local -LocalPort $Port;Get-LabAiHostModelBinding -Plan $plan} $LocalPort
    $env:SQL_SERVER_LAB_STATE=$state;$env:SQL_SERVER_LAB_DATA_ROOT=$data
    $null=New-Item -ItemType Directory -Path $root
    & $module {param($Data)$null=Initialize-LabManagedDataRoot -DataRoot $Data -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false} $data
    $arrangeStarted=$true
    $lab=& $module {
        param($Provider,$State,$Operation)
        Invoke-WithLabWorkflowOperationContext -OperationId $Operation -ScriptBlock {
            param($Provider,$State)
            New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Port 0 -Cpu 1 -MemoryMB 2560 -LabName 'ai-migration-acceptance' -StateRoot $State -GenerateSaPassword -NonInteractive -Drives @([pscustomobject]@{id='retrieval-data';containerPath='/var/opt/mssql'})
        } -ArgumentList @($Provider,$State)
    } $Provider $state $operation
    Assert-Persistent ($lab.State -eq 'Running') 'Eigener SQL-2025-Run läuft'
    $binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $lab.RunId $state $operation
    $parameters=@{RunId=$lab.RunId;CollectionId=$collection;StateRoot=$state;LocalPort=$LocalPort;TimeoutSeconds=300}
    $migration=@{Action='Migrate';FixtureRevision='Delta';TargetModelKey='ollama-nomic-embed-text-v2-moe'}
    $parameters.TimeoutSeconds=600
    $preview=Invoke-SqlServerLabAiPersistentRetrieval @parameters @migration -WhatIf
    Assert-Persistent ($preview.Status -eq 'PLANNED' -and -not(Test-Path -LiteralPath (Join-Path $state "runs/$($lab.RunId)/ai-persistent"))) 'Migrate WhatIf schreibt kein Journal'
    $null=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Confirm:$false
    $delta=Invoke-SqlServerLabAiPersistentRetrieval @parameters -FixtureRevision Delta -Confirm:$false
    Assert-Persistent ($delta.Generation -eq 2) 'Bestätigte Delta-Generation ist Migrationsquelle'
    $journalPath=Join-Path $state "runs/$($lab.RunId)/ai-persistent/primary-$collection.json"
    function Read-MigrationSqlProof {
        & $module {
            param($Binding,$State,$Path)
            $journal=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json
            $secret=Get-LabRelationalCoreSecret -RunId $Binding.RunId -StateRoot $State;$connection=$null
            try{
                $connection=New-LabRelationalCoreConnection -Binding $Binding -DatabaseName master -Secret $secret;$connection.Open()
                $rows=@(Invoke-LabTransferSqlRows -Connection $connection -Query "SELECT Generation,ChunkId,Content,ContentHash,VectorHash,LOWER(CONVERT(char(64),HASHBYTES('SHA2_256',CAST(Embedding AS varchar(max))),2)) AS ActualVectorHash FROM [$($journal.databaseName)].dbo.LabChunks ORDER BY Generation,ChunkId;")
                [pscustomobject]@{SourceHash=Get-LabAiPlanKey @($rows|Where-Object Generation -LE 2);TargetCount=@($rows|Where-Object Generation -EQ 3).Count;TotalCount=$rows.Count}
            }finally{if($connection){$connection.Dispose()};$secret.Dispose()}
        } $binding $state $journalPath
    }
    $sourceProof=Read-MigrationSqlProof
    $faultEvidence=@{AfterUpgradeSql=0;AfterChunkSql=0;AfterCommitSql=0}
    function Invoke-MigrationFault {
        param([string]$Point,[bool]$Resume)
        $seen=$false
        try{
            & $module {
                param($Run,$Collection,$State,$Port,$Evidence,$Point,$Resume)
                $plan=New-LabAiPersistentPlan -RunId $Run -InstanceId primary -CollectionId $Collection -Action Migrate -FixtureRevision Delta -TargetModelKey ollama-nomic-embed-text-v2-moe -QueryId backup -LocalPort $Port -TimeoutSeconds 600 -Resume:$Resume
                $fault={param($Step,$Id)if($Step -eq $Point){$Evidence[$Point]++;throw 'SYNTHETIC_MIGRATION_REPLY_LOST'}}.GetNewClosure()
                Invoke-LabAiPersistentRetrieval -Plan $plan -StateRoot $State -FaultInjector $fault
            } $lab.RunId $collection $state $LocalPort $faultEvidence $Point $Resume
        }catch{if($_.Exception.Message -ceq 'AI_PERSISTENT_RECOVERY_REQUIRED'){$seen=$true}else{throw}}
        Assert-Persistent ($seen -and $faultEvidence[$Point] -eq 1) "Gezielter Antwortverlust erreicht: $Point"
    }
    Invoke-MigrationFault AfterUpgradeSql $false
    foreach($question in @('backup','cleanup')){
        $old=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -QueryId $question -Confirm:$false
        Assert-Persistent ($old.Generation -eq 2 -and $old.ModelKey -ceq 'ollama-embeddinggemma-latest' -and $old.Ranked[0].ChunkId -ceq "$question-policy") "Alte Generation trifft $question nach Upgradeantwortverlust"
    }
    Invoke-MigrationFault AfterChunkSql $true
    $partial=Read-MigrationSqlProof
    Assert-Persistent ($partial.TargetCount -eq 1 -and $partial.SourceHash -ceq $sourceProof.SourceHash) 'Ein Zielchunk persistiert und beide Quellgenerationen bleiben unverändert'
    $old=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -QueryId backup -Confirm:$false
    Assert-Persistent ($old.Generation -eq 2 -and $old.Ranked[0].ChunkId -ceq 'backup-policy') 'Quellquery bleibt nach Zielstagingabbruch verfügbar'
    Invoke-MigrationFault AfterCommitSql $true
    $pending=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json
    Assert-Persistent ($pending.activeGeneration -eq 2 -and $pending.status -eq 'STAGING') 'Lokales Journal liegt nach verlorenem Commitresponse hinter SQL'
    foreach($question in @('backup','cleanup')){
        $target=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -QueryId $question -Confirm:$false
        Assert-Persistent ($target.Generation -eq 3 -and $target.ModelKey -ceq 'ollama-nomic-embed-text-v2-moe' -and $target.Profile -ceq 'nomic-search' -and $target.Ranked[0].ChunkId -ceq "$question-policy") "Aktives Ziel trifft $question vor Journalreparatur"
    }
    $resumed=Invoke-SqlServerLabAiPersistentRetrieval @parameters @migration -Resume -Confirm:$false
    $replay=Invoke-SqlServerLabAiPersistentRetrieval @parameters @migration -Confirm:$false
    $proof=Read-MigrationSqlProof
    Assert-Persistent ($resumed.Generation -eq 3 -and $resumed.EmbeddingRequests -eq 0 -and $replay.EmbeddingRequests -eq 0 -and $proof.TargetCount -eq 3 -and $proof.TotalCount -eq 9 -and $proof.SourceHash -ceq $sourceProof.SourceHash) 'Resume und Replay bestätigen genau drei Generationen ohne weitere Embeddings'
    $callerCollection=[guid]::NewGuid().ToString('D')
    $callerDocuments=@(
        [pscustomobject]@{Id='caller-backup';Content='Synthetische Sicherungen werden täglich geprüft.'},
        [pscustomobject]@{Id='caller-restore';Content='Ein synthetischer Restoretest läuft wöchentlich.'},
        [pscustomobject]@{Id='caller-retention';Content='Die synthetische Aufbewahrung beträgt vierzehn Tage.'}
    )
    $callerParameters=@{RunId=$lab.RunId;CollectionId=$callerCollection;StateRoot=$state;LocalPort=$LocalPort;TimeoutSeconds=600;Documents=$callerDocuments}
    $callerInitial=Invoke-SqlServerLabAiPersistentRetrieval @callerParameters -Action Apply -Confirm:$false
    $callerMigrated=Invoke-SqlServerLabAiPersistentRetrieval @callerParameters -Action Migrate -TargetModelKey ollama-nomic-embed-text-v2-moe -Confirm:$false
    Assert-Persistent ($callerInitial.Generation -eq 1 -and $callerMigrated.Generation -eq 2 -and $callerMigrated.DatasetMode -ceq 'CallerSupplied' -and $callerMigrated.EmbeddingRequests -eq 3) 'Caller-Collection wird aus aktiver Generation vollständig neu eingebettet'
    $callerJournalPath=Join-Path $state "runs/$($lab.RunId)/ai-persistent/primary-$callerCollection.json"
    $callerJournalText=Get-Content -LiteralPath $callerJournalPath -Raw
    $callerJournal=$callerJournalText|ConvertFrom-Json
    Assert-Persistent ($callerJournal.migration.sourceGeneration -eq 1 -and $callerJournal.migration.targetGeneration -eq 2 -and $callerJournal.migration.datasetMode -ceq 'CallerSupplied' -and $callerJournalText -notmatch 'Synthetische Sicherungen') 'Caller-Migrationsjournal bindet Generationen ohne Dokumentinhalt'
    $callerQueryParameters=$callerParameters.Clone();$callerQueryParameters.Question='Wie werden synthetische Sicherungen geprüft?'
    $callerBeforeRestart=Invoke-SqlServerLabAiPersistentRetrieval @callerQueryParameters -Action Query -Confirm:$false
    Assert-Persistent ($callerBeforeRestart.Generation -eq 2 -and $callerBeforeRestart.ModelKey -ceq 'ollama-nomic-embed-text-v2-moe' -and $callerBeforeRestart.Profile -ceq 'nomic-search' -and $callerBeforeRestart.Ranked.Count -eq 3) 'Caller-Query verwendet nach Cutover das Nomic-Profil'
    $null=Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 180 -Force -Confirm:$false
    $afterBinding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $lab.RunId $state $operation
    Assert-Persistent ($afterBinding.ContainerId -ceq $binding.ContainerId) 'SQLrestart erhält die gebundene Containeridentität'
    foreach($question in @('backup','cleanup')){
        $target=Invoke-SqlServerLabAiPersistentRetrieval @parameters -Action Query -QueryId $question -Confirm:$false
        Assert-Persistent ($target.Generation -eq 3 -and $target.Ranked[0].ChunkId -ceq "$question-policy") "Zielranking $question übersteht SQLrestart"
    }
    $callerAfterRestart=Invoke-SqlServerLabAiPersistentRetrieval @callerQueryParameters -Action Query -Confirm:$false
    Assert-Persistent ($callerAfterRestart.Generation -eq 2 -and (($callerAfterRestart.Ranked.ChunkId -join ',') -ceq ($callerBeforeRestart.Ranked.ChunkId -join ','))) 'Caller-Zielranking übersteht SQLrestart'
    $callerRemoved=Invoke-SqlServerLabAiPersistentRetrieval -RunId $lab.RunId -CollectionId $callerCollection -StateRoot $state -LocalPort $LocalPort -TimeoutSeconds 600 -Action Remove -Confirm:$false
    Assert-Persistent ($callerRemoved.Status -eq 'REMOVED') 'Eigene Caller-Datenbank entfernt'
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
        if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notmatch '^sql-lab-ai-migration-[a-f0-9]{32}$'){throw 'AI_PERSISTENT_TEMP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}
if(-not $complete -or $cleanupFailed){throw 'AI_PERSISTENT_ACCEPTANCE_INCOMPLETE'}
Write-Host "AI MODEL MIGRATION ACCEPTANCE: PASS ($Provider; fixture and caller collections; SQLrestart; staging/resume; own DB/run cleanup)"
