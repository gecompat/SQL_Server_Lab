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
.EXAMPLE
    Invoke-SqlServerLabAiRag -RunId $runId -SaPassword $password -Question 'Welche Sicherung gilt?' -Document @(@{Id='backup-policy';Content='Sicherungen werden täglich geprüft.'})
#>
function Invoke-SqlServerLabAiRag {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]*$')][string]$InstanceId='primary',
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Question,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$Document,
        [ValidatePattern('^[a-z][a-z0-9-]{2,95}$')][string]$EmbeddingModelKey='ollama-embeddinggemma-300m-q4',
        [ValidatePattern('^[a-z][a-z0-9-]{2,95}$')][string]$GenerationModelKey='ollama-gemma3-1b-local',
        [ValidateRange(1024,65535)][int]$LocalPort=11434,
        [ValidateRange(1,20)][int]$TopK=3,
        [string]$StateRoot
    )
    $plan=New-LabAiRagPlan -RunId $RunId -InstanceId $InstanceId -Question $Question -Document $Document -EmbeddingModelKey $EmbeddingModelKey -GenerationModelKey $GenerationModelKey -LocalPort $LocalPort -TopK $TopK
    if (-not $PSCmdlet.ShouldProcess("Run $RunId / Instanz $InstanceId",'lokales SQL-zentriertes RAG ausführen')) {
        return [PSCustomObject]@{
            Contract=$plan.Contract;Status=$plan.Status;RunId=$plan.RunId;InstanceId=$plan.InstanceId
            ScenarioId=$plan.ScenarioId;TopK=$plan.TopK;DocumentCount=$plan.DocumentCount
            EmbeddingModelKey=$plan.EmbeddingModelKey;GenerationModelKey=$plan.GenerationModelKey;PlanKey=$plan.PlanKey
        }
    }
    $target=Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    Invoke-LabAiRag -Plan $plan -SaPassword $SaPassword -Target $target -Question $Question
}
