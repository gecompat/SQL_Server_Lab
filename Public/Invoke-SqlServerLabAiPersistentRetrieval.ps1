<#
.SYNOPSIS
    Verwaltet persistentes synthetisches Retrieval auf einem eigenen SQL-Datenbankscope.
.DESCRIPTION
    SQL Server 2025 unter Docker oder Podman; vorhandenes lokales embeddinggemma:latest.
    Initial und Delta sind feste versionierte synthetische Dokumentmengen. Alternativ
    kann eine initiale Collection aus 1 bis 16 vom Aufrufer übergebenen Dokumenten
    aufgebaut und mit einer freien Frage abgefragt werden. Inhalte bleiben in der
    eigenen SQL-Datenbank und in lokalen Ollama-Requests; Journal und Plan enthalten
    nur Hashes. Kein Cloudzugriff oder Generierung. Eine Datenbank ohne exakten
    Besitznachweis wird weder übernommen noch entfernt. WhatIf ist rein planend.
.PARAMETER RunId
    Vorhandener laufender SQL-2025-Container-Run mit verwaltetem SA-Secret.
.PARAMETER InstanceId
    SQL-Instanz, standardmäßig primary.
.PARAMETER CollectionId
    Selbst gewählte GUID der Collection; für Wiederaufnahme und Remove beibehalten.
.PARAMETER Action
    Apply erstellt eine neue Generation; Migrate baut Delta mit dem expliziten Zielmodell neu auf; Query liest die aktive; Remove entfernt nur die eigene Datenbank.
.PARAMETER TargetModelKey
    Ausschließlich für Migrate: ollama-nomic-embed-text-v2-moe. Benötigt FixtureRevision Delta.
.PARAMETER FixtureRevision
    Initial oder Delta. Delta aktualisiert, entfernt und ergänzt feste synthetische Dokumente.
.PARAMETER QueryId
    Feste synthetische Frage backup oder cleanup.
.PARAMETER Documents
    Optional 1 bis 16 Dokumente mit eindeutigen Eigenschaften Id und Content.
    Gilt nur für eine initiale Apply-Generation und deren Query.
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
.OUTPUTS
    Plan bei WhatIf; andernfalls Status, CollectionId, Generation und Requestzahl, bei Query Rangfolge.
    Query plant ohne Statezugriff mit ModelSelection ACTIVE_SQL_GENERATION und leerem ModelKey/Revision; Remove benötigt keine Modellwahl.
.EXAMPLE
    Invoke-SqlServerLabAiPersistentRetrieval -RunId $runId -CollectionId $collectionId -Action Apply -FixtureRevision Initial
.EXAMPLE
    Invoke-SqlServerLabAiPersistentRetrieval -RunId $runId -CollectionId $collectionId -Action Apply -FixtureRevision Delta -Resume
.EXAMPLE
    Invoke-SqlServerLabAiPersistentRetrieval -RunId $runId -CollectionId $collectionId -Action Remove
#>
function Invoke-SqlServerLabAiPersistentRetrieval {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$RunId,
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$CollectionId,
        [ValidateSet('Apply','Query','Remove','Migrate')][string]$Action='Apply',
        [ValidateSet('ollama-nomic-embed-text-v2-moe')][string]$TargetModelKey,
        [ValidateSet('Initial','Delta')][string]$FixtureRevision='Initial',
        [ValidateSet('backup','cleanup')][string]$QueryId='backup',
        [ValidateCount(1,16)][object[]]$Documents,
        [ValidateLength(1,1000)][string]$Question,
        [ValidateSet('Vector','Hybrid')][string]$SearchMode='Vector',
        [switch]$Resume,[ValidateRange(1024,65535)][int]$LocalPort=11434,
        [ValidateRange(60,600)][int]$TimeoutSeconds=300,[string]$StateRoot
    )
    $plan=New-LabAiPersistentPlan -RunId $RunId -InstanceId $InstanceId -CollectionId $CollectionId -Action $Action -FixtureRevision $FixtureRevision -QueryId $QueryId -Documents $Documents -Question $Question -SearchMode $SearchMode -LocalPort $LocalPort -TimeoutSeconds $TimeoutSeconds -Resume:$Resume -TargetModelKey $TargetModelKey
    if(-not $PSCmdlet.ShouldProcess("Run $RunId / Collection $CollectionId",$Action)){
        $fixedModel=$Action -in @('Apply','Migrate')
        $selection=if($fixedModel){'FIXED'}elseif($Action -eq 'Query'){'ACTIVE_SQL_GENERATION'}else{'NOT_REQUIRED'}
        return [pscustomobject]@{Status='PLANNED';Action=$Action;CollectionId=$CollectionId;Revision=$(if($fixedModel){$plan.Revision}else{$null});PlanKey=$plan.PlanKey;ModelKey=$(if($fixedModel){$plan.EndpointPlan.ModelKey}else{$null});ModelSelection=$selection;DatasetMode=$plan.DatasetMode;DocumentCount=$plan.Documents.Count;SearchMode=$SearchMode;Dimension=768}
    }
    try{Invoke-LabAiPersistentRetrieval -Plan $plan -StateRoot $StateRoot}
    catch{if($_.Exception.Message -match '^AI_PERSISTENT_[A-Z_]+$'){throw $_.Exception.Message};throw 'AI_PERSISTENT_RECOVERY_REQUIRED'}
}
