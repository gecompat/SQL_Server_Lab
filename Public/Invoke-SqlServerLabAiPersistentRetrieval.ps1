<#
.SYNOPSIS
    Verwaltet persistentes synthetisches Retrieval auf einem eigenen SQL-Datenbankscope.
.DESCRIPTION
    SQL Server 2025 unter Docker oder Podman; vorhandenes lokales embeddinggemma:latest.
    Initial und Delta sind feste versionierte synthetische Dokumentmengen. Alternativ
    kann eine Collection aus 1 bis 16 vom Aufrufer übergebenen Dokumenten aufgebaut,
    atomar synchronisiert, explizit auf die jüngsten abgeschlossenen Generationen begrenzt
    und mit einer freien Frage abgefragt werden. Inhalte bleiben in der
    eigenen SQL-Datenbank und in lokalen Ollama-Requests; Journal und öffentliche
    WhatIf-Ausgabe enthalten nur Hashes. Kein Cloudzugriff oder Generierung. Eine Datenbank ohne exakten
    Besitznachweis wird weder übernommen noch entfernt. WhatIf ist rein planend.
.PARAMETER RunId
    Vorhandener laufender SQL-2025-Container-Run mit verwaltetem SA-Secret.
.PARAMETER InstanceId
    SQL-Instanz, standardmäßig primary.
.PARAMETER CollectionId
    Selbst gewählte GUID der Collection; für Wiederaufnahme, Prune und Remove beibehalten.
.PARAMETER Action
    Apply erstellt eine neue Generation; Sync ersetzt den gebundenen Dokumentbestand atomar; Prune entfernt nach erfolgreichem Sync alte inaktive Generationen einer callerverwalteten v1-Collection; Migrate baut Delta mit dem expliziten Zielmodell neu auf; Query liest die aktive; Remove entfernt nur die eigene Datenbank.
.PARAMETER TargetModelKey
    Ausschließlich für Migrate: ollama-nomic-embed-text-v2-moe. Die feste Fixture benötigt Delta;
    callerverwaltete Dokumente behalten FixtureRevision Initial.
.PARAMETER EmbeddingModelKey
    Lokales Embeddingmodell für Apply, Query und Sync. EmbeddingGemma bleibt der
    Standard; BGE-M3 verwendet 1024 Dimensionen. Nomic v2 verwendet 768 Dimensionen
    und wendet sein Suchprofil mit einer Eingabegrenze von 512 UTF-8-Bytes automatisch an. Bei Query muss die Auswahl zur
    v1-Collection passen. Migrate bindet sein Zielmodell separat.
.PARAMETER FixtureRevision
    Initial oder Delta. Delta aktualisiert, entfernt und ergänzt feste synthetische Dokumente.
.PARAMETER QueryId
    Feste synthetische Frage backup oder cleanup.
.PARAMETER Documents
    Optional 1 bis 16 Dokumente mit eindeutigen Eigenschaften Id und Content.
    Gilt für eine initiale Apply-Generation, Sync, Migrate und deren Query.
.PARAMETER ExpectedDocuments
    Bei Sync der vollständige erwartete aktive Dokumentbestand. Abweichungen blockieren vor Embedding und SQL-Staging.
.PARAMETER Question
    Freie Frage für Query mit Documents. Sie wird weder journalisiert noch protokolliert.
.PARAMETER SearchMode
    Vector verwendet ausschließlich exakte Cosine-Distanz. Hybrid kombiniert
    diese mit deterministischer SQL-seitiger Termabdeckung. Hybrid gilt nur für das lokale
    Embeddinggemma-Schema und nicht für eine Modellmigration.
.PARAMETER Resume
    Setzt exakt gebundenes Staging fort; bestätigte SQL-Chunks werden nicht erneut eingebettet.
.PARAMETER LocalPort
    Loopback-Port des bereits laufenden Ollama-Dienstes.
.PARAMETER TimeoutSeconds
    Begrenzte Operationslaufzeit; einzelne SQL-/Embeddingrequests dauern höchstens 60 Sekunden.
.PARAMETER StateRoot
    Lokaler Run-State mit verschlüsseltem verwaltetem Secret und atomarem Journal.
.PARAMETER KeepGenerations
    Ausschließlich für Prune: Anzahl der jüngsten abgeschlossenen Generationen, die erhalten bleiben.
    Standardwert 2; die aktive Generation wird immer erhalten. Prune verwendet weder Ollama noch Dokumentpayloads.
.OUTPUTS
    Plan bei WhatIf; andernfalls Status, CollectionId, Generation und Requestzahl, bei Query Rangfolge.
    Query plant ohne Statezugriff mit ModelSelection ACTIVE_SQL_GENERATION und leerem ModelKey/Revision; Remove und Prune benötigen keine Modellwahl.
.EXAMPLE
    Invoke-SqlServerLabAiPersistentRetrieval -RunId $runId -CollectionId $collectionId -Action Apply -FixtureRevision Initial
.EXAMPLE
    Invoke-SqlServerLabAiPersistentRetrieval -RunId $runId -CollectionId $collectionId -Action Apply -FixtureRevision Delta -Resume
.EXAMPLE
    Invoke-SqlServerLabAiPersistentRetrieval -RunId $runId -CollectionId $collectionId -Action Sync -ExpectedDocuments $old -Documents $new
.EXAMPLE
    Invoke-SqlServerLabAiPersistentRetrieval -RunId $runId -CollectionId $collectionId -Action Migrate -Documents $documents -TargetModelKey ollama-nomic-embed-text-v2-moe
.EXAMPLE
    Invoke-SqlServerLabAiPersistentRetrieval -RunId $runId -CollectionId $collectionId -Action Prune -KeepGenerations 2
.EXAMPLE
    Invoke-SqlServerLabAiPersistentRetrieval -RunId $runId -CollectionId $collectionId -Action Remove
#>
function Invoke-SqlServerLabAiPersistentRetrieval {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$RunId,
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$CollectionId,
        [ValidateSet('Apply','Query','Remove','Migrate','Sync','Prune')][string]$Action='Apply',
        [ValidateSet('ollama-nomic-embed-text-v2-moe')][string]$TargetModelKey,
        [ValidateSet('ollama-embeddinggemma-latest','ollama-bge-m3-latest','ollama-nomic-embed-text-v2-moe')][string]$EmbeddingModelKey='ollama-embeddinggemma-latest',
        [ValidateSet('Initial','Delta')][string]$FixtureRevision='Initial',
        [ValidateSet('backup','cleanup')][string]$QueryId='backup',
        [ValidateCount(1,16)][object[]]$Documents,
        [ValidateCount(1,16)][object[]]$ExpectedDocuments,
        [ValidateLength(1,1000)][string]$Question,
        [ValidateSet('Vector','Hybrid')][string]$SearchMode='Vector',
        [switch]$Resume,[ValidateRange(1024,65535)][int]$LocalPort=11434,
        [ValidateRange(60,600)][int]$TimeoutSeconds=300,[string]$StateRoot,
        [ValidateRange(1,31)][int]$KeepGenerations=2
    )
    if($Action -ne 'Prune' -and $PSBoundParameters.ContainsKey('KeepGenerations')){throw 'AI_PERSISTENT_RETENTION_UNEXPECTED'}
    if($PSBoundParameters.ContainsKey('EmbeddingModelKey') -and $Action -in @('Remove','Migrate','Prune')){throw 'AI_PERSISTENT_MODEL_SELECTION_UNEXPECTED'}
    $plan=New-LabAiPersistentPlan -RunId $RunId -InstanceId $InstanceId -CollectionId $CollectionId -Action $Action -FixtureRevision $FixtureRevision -QueryId $QueryId -Documents $Documents -ExpectedDocuments $ExpectedDocuments -Question $Question -SearchMode $SearchMode -LocalPort $LocalPort -TimeoutSeconds $TimeoutSeconds -Resume:$Resume -TargetModelKey $TargetModelKey -EmbeddingModelKey $EmbeddingModelKey -KeepGenerations $KeepGenerations
    if(-not $PSCmdlet.ShouldProcess("Run $RunId / Collection $CollectionId",$Action)){
        $fixedModel=$Action -in @('Apply','Migrate','Sync')
        $selection=if($fixedModel){'FIXED'}elseif($Action -eq 'Query'){'ACTIVE_SQL_GENERATION'}else{'NOT_REQUIRED'}
        return [pscustomobject]@{Status='PLANNED';Action=$Action;CollectionId=$CollectionId;Revision=$(if($fixedModel){$plan.Revision}else{$null});PlanKey=$plan.PlanKey;ModelKey=$(if($fixedModel){$plan.EndpointPlan.ModelKey}else{$null});ModelSelection=$selection;DatasetMode=$plan.DatasetMode;DocumentCount=$plan.Documents.Count;ExpectedDocumentCount=$(if($Action -eq 'Sync'){$plan.ExpectedDocuments.Count}else{$null});KeepGenerations=$(if($Action -eq 'Prune'){$plan.KeepGenerations}else{$null});SearchMode=$SearchMode;Dimension=$(if($plan.EndpointPlan){$plan.EndpointPlan.Dimension}else{$null})}
    }
    try{Invoke-LabAiPersistentRetrieval -Plan $plan -StateRoot $StateRoot}
    catch{if($_.Exception.Message -match '^AI_PERSISTENT_[A-Z_]+$'){throw $_.Exception.Message};throw 'AI_PERSISTENT_RECOVERY_REQUIRED'}
}
