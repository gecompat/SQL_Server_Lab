<#
.SYNOPSIS
    Führt lokales RAG mit Ollama-Embeddings und exakter SQL-2025-Vektorsuche aus.
.DESCRIPTION
    Dokumenttexte und Frage bleiben flüchtig auf dem Controller. SQL Server
    erhält ausschließlich validierte Dokument-IDs und Vektoren in einer
    Tabellenvariable; es werden keine dauerhaften Datenbankobjekte angelegt.
.PARAMETER RunId
    ID des vorhandenen SQL-Server-Lab-Runs.
.PARAMETER InstanceId
    Zielinstanz innerhalb des Runs. Standard ist primary.
.PARAMETER SaPassword
    Flüchtiges SQL-SA-Kennwort; es wird weder protokolliert noch persistiert.
.PARAMETER Question
    Frage für Retrieval und lokale Generierung.
.PARAMETER Document
    Ein bis zwanzig Objekte mit den Feldern Id und Content.
.PARAMETER GoldenDatasetId
    Repository-gebundener Golden-Dataset-Schlüssel. Wird nur zusammen mit CaseId verwendet.
.PARAMETER GoldenDatasetVersion
    Version des Golden Datasets.
.PARAMETER CaseId
    Fall aus dem Golden Dataset; Frage, Dokumente, Modelle, Top-k und Schwellen werden daraus gebunden.
.PARAMETER EmbeddingModelKey
    Katalogschlüssel des lokalen Embeddingmodells.
.PARAMETER GenerationModelKey
    Katalogschlüssel des lokalen Generierungsmodells.
.PARAMETER LocalPort
    Loopback-Port des bereits laufenden lokalen Ollama-Endpunkts.
.PARAMETER TopK
    Anzahl der von SQL Server geordneten Kontextdokumente.
.PARAMETER StateRoot
    Optionaler State-Root zur Auflösung des Runs.
.OUTPUTS
    SqlServerLab.AiRagPlan/1.0 bei WhatIf oder SqlServerLab.AiQueryResult/1.0 bei Ausführung.
.PARAMETER GenerationLane
    AdHoc: lokale Generierung oder ausdrücklich gewählte direkte HTTPS-Cloud.
.PARAMETER AllowCloudEgress
    Erlaubt Frage und ausgewählten Dokumentkontext an ollama.com zu senden.
.PARAMETER DataClassification
    Cloud verlangt synthetic-only oder public-or-redistributable für sämtliche Eingaben.
.PARAMETER SecretFilePath
    Cloud: lokale .env mit OLLAMA; Standard ist Media Root. Lesen erst nach ShouldProcess.
.PARAMETER GenerationTimeoutSeconds
    Begrenzte Laufzeit pro Generierungsversuch (1 bis 230 Sekunden).
.PARAMETER GenerationRetryCount
    Null oder eine Wiederholung; kein automatischer Wechsel der Lane.
.EXAMPLE
    Invoke-SqlServerLabAiRag -RunId $runId -SaPassword $password -Question 'Welche Sicherung gilt?' -Document @(@{Id='backup-policy';Content='Sicherungen werden täglich geprüft.'})
.EXAMPLE
    Invoke-SqlServerLabAiRag -RunId $runId -SaPassword $password -CaseId backup-frequency
#>
function Invoke-SqlServerLabAiRag {
    [CmdletBinding(DefaultParameterSetName='AdHoc',SupportsShouldProcess,ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]*$')][string]$InstanceId='primary',
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory,ParameterSetName='AdHoc')][ValidateNotNullOrEmpty()][string]$Question,
        [Parameter(Mandatory,ParameterSetName='AdHoc')][ValidateNotNullOrEmpty()][object[]]$Document,
        [Parameter(ParameterSetName='AdHoc')][ValidatePattern('^[a-z][a-z0-9-]{2,95}$')][string]$EmbeddingModelKey='ollama-embeddinggemma-300m-q4',
        [Parameter(ParameterSetName='AdHoc')][ValidatePattern('^[a-z][a-z0-9-]{2,95}$')][string]$GenerationModelKey='ollama-gemma3-1b-local',
        [Parameter(ParameterSetName='Golden')][ValidatePattern('^[a-z][a-z0-9-]{2,63}$')][string]$GoldenDatasetId='sql-lab-rag-de',
        [Parameter(ParameterSetName='Golden')][ValidatePattern('^[1-9][0-9]*\.[0-9]+$')][string]$GoldenDatasetVersion='1.0',
        [Parameter(Mandatory,ParameterSetName='Golden')][ValidatePattern('^[a-z][a-z0-9-]{2,63}$')][string]$CaseId,
        [ValidateRange(1024,65535)][int]$LocalPort=11434,
        [Parameter(ParameterSetName='AdHoc')][ValidateRange(1,20)][int]$TopK=3,
        [Parameter(ParameterSetName='AdHoc')][ValidateSet('local','cloud')][string]$GenerationLane='local',
        [Parameter(ParameterSetName='AdHoc')][switch]$AllowCloudEgress,
        [Parameter(ParameterSetName='AdHoc')][ValidateSet('synthetic-only','public-or-redistributable','internal-explicit')][string]$DataClassification,
        [Parameter(ParameterSetName='AdHoc')][string]$SecretFilePath,
        [Parameter(ParameterSetName='AdHoc')][ValidateRange(1,230)][int]$GenerationTimeoutSeconds=60,
        [Parameter(ParameterSetName='AdHoc')][ValidateRange(0,1)][int]$GenerationRetryCount=1,
        [string]$StateRoot
    )
    $evaluationBinding = $null
    if ($PSCmdlet.ParameterSetName -eq 'Golden') {
        $golden = Read-LabAiRetrievalGoldenDataset -DatasetId $GoldenDatasetId -Version $GoldenDatasetVersion
        $case = Get-LabAiRetrievalGoldenCase -GoldenDataset $golden -CaseId $CaseId
        $Question = [string]$case.question
        $Document = @($golden.Dataset.documents)
        $EmbeddingModelKey = [string]$golden.Dataset.models.embedding
        $GenerationModelKey = [string]$golden.Dataset.models.generation
        $TopK = [int]$case.topK
        $evaluationBinding = [PSCustomObject]@{
            DatasetId = $GoldenDatasetId
            DatasetVersion = $GoldenDatasetVersion
            DatasetHash = [string]$golden.DatasetHash
            CaseId = $CaseId
        }
    }
    if($GenerationLane -eq 'local' -and $SecretFilePath){throw 'AI_RAG_SECRET_UNEXPECTED'}
    $classificationArguments=@{}
    if($DataClassification){$classificationArguments.DataClassification=$DataClassification}
    $plan=New-LabAiRagPlan -RunId $RunId -InstanceId $InstanceId -Question $Question -Document $Document -EmbeddingModelKey $EmbeddingModelKey -GenerationModelKey $GenerationModelKey -LocalPort $LocalPort -TopK $TopK -EvaluationBinding $evaluationBinding -GenerationLane $GenerationLane -AllowCloudEgress:$AllowCloudEgress -GenerationTimeoutSeconds $GenerationTimeoutSeconds -GenerationRetryCount $GenerationRetryCount @classificationArguments
    if (-not $PSCmdlet.ShouldProcess("Run $RunId / Instanz $InstanceId","SQL-RAG mit $GenerationLane Generierung ausführen")) {
        return [PSCustomObject]@{
            Contract=$plan.Contract;Status=$plan.Status;RunId=$plan.RunId;InstanceId=$plan.InstanceId
            ScenarioId=$plan.ScenarioId;TopK=$plan.TopK;DocumentCount=$plan.DocumentCount
            EmbeddingModelKey=$plan.EmbeddingModelKey;GenerationModelKey=$plan.GenerationModelKey;PlanKey=$plan.PlanKey
            EvaluationBinding=$plan.EvaluationBinding
            GenerationLane=$GenerationLane;DataClassification=$DataClassification;Egress=$plan.GenerationPlan.Egress
        }
    }
    $target=Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    $credential=$null
    try {
        if($GenerationLane -eq 'cloud'){
            if(-not $SecretFilePath){$mediaRoot=Get-LabMediaRootDefault;if(-not $mediaRoot){throw 'AI_SECRET_MEDIA_ROOT_NOT_CONFIGURED'};$SecretFilePath=Join-Path $mediaRoot '.env'}
            $secret=Get-LabAiDotEnvSecret -Path $SecretFilePath
            $credential=$secret.Secret
            foreach($warningCode in @($secret.Warnings)){Write-Warning $warningCode}
        }
        Invoke-LabAiRag -Plan $plan -SaPassword $SaPassword -Target $target -Question $Question -GenerationCredential $credential
    }
    finally {if($credential){$credential.Dispose()};$secret=$null}
}
