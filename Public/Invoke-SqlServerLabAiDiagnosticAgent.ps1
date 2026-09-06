<#
.SYNOPSIS
    Führt einen lokalen read-only SQL-Diagnose-Agenten aus.
.DESCRIPTION
    Führt maximal vier fest katalogisierte SELECT-Werkzeuge unter einer
    kurzlebigen Least-Privilege-SQL-Identität aus und fasst die begrenzten
    Ergebnisse mit einem lokalen Ollama-Modell zusammen. Freies SQL, DDL und
    DML aus Modellantworten werden nicht ausgeführt.
.PARAMETER RunId
    ID des vorhandenen SQL-Server-Lab-Runs.
.PARAMETER InstanceId
    Zielinstanz innerhalb des Runs.
.PARAMETER SaPassword
    Flüchtiges SA-Kennwort zum Anlegen und Entfernen der kurzlebigen Identität.
.PARAMETER Question
    Diagnosefrage für die lokale Zusammenfassung.
.PARAMETER ToolId
    Ein bis vier erlaubte Werkzeuge: server-summary, database-capacity, wait-statistics oder active-requests.
.PARAMETER GenerationModelKey
    Katalogschlüssel des lokalen Generierungsmodells.
.PARAMETER LocalPort
    Loopback-Port des lokalen Ollama-Endpunkts.
.PARAMETER StateRoot
    Optionaler State-Root.
.OUTPUTS
    Planobjekt bei WhatIf oder SqlServerLab.AiQueryResult/1.0.
.EXAMPLE
    Invoke-SqlServerLabAiDiagnosticAgent -RunId $runId -SaPassword $password -Question 'Gibt es auffällige Wartezeiten?' -ToolId wait-statistics
#>
function Invoke-SqlServerLabAiDiagnosticAgent {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,[ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]*$')][string]$InstanceId='primary',[Parameter(Mandatory)][SecureString]$SaPassword,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Question,[ValidateSet('server-summary','database-capacity','wait-statistics','active-requests')][string[]]$ToolId=@('server-summary'),[ValidatePattern('^[a-z][a-z0-9-]{2,95}$')][string]$GenerationModelKey='ollama-gemma3-1b-local',[ValidateRange(1024,65535)][int]$LocalPort=11434,[string]$StateRoot)
    $plan=New-LabAiDiagnosticAgentPlan -RunId $RunId -InstanceId $InstanceId -Question $Question -ToolId $ToolId -GenerationModelKey $GenerationModelKey -LocalPort $LocalPort
    if(-not$PSCmdlet.ShouldProcess("Run $RunId / Instanz $InstanceId",'kurzlebige read-only Diagnoseidentität anlegen und Agent ausführen')){return [PSCustomObject]@{Contract=$plan.Contract;Status=$plan.Status;RunId=$plan.RunId;InstanceId=$plan.InstanceId;ScenarioId=$plan.ScenarioId;ToolIds=$plan.ToolIds;GenerationModelKey=$plan.GenerationModelKey;PlanKey=$plan.PlanKey}}
    $target=Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    Invoke-LabAiDiagnosticAgent -Plan $plan -SaPassword $SaPassword -Target $target -Question $Question -StateRoot $StateRoot
}
