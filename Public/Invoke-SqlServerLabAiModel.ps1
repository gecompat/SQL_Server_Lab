<#
.SYNOPSIS
    Ruft ein katalogisiertes Ollama-Modell lokal oder über die explizit freigegebene Cloud-Lane auf.
.DESCRIPTION
    Sendet genau einen Prompt an die Ollama-Cloud-API. Das Modell ist kataloggebunden,
    Cloud-Egress und Datenklassifikation sind explizit, Requests und Retries sind begrenzt.
    Der API-Key wird erst nach ShouldProcess aus der lokalen .env-Datei gelesen und weder
    in Plan, State, Prozessargumente, Fehler noch Ausgabe übernommen.
.PARAMETER ModelKey
    Katalogschlüssel des Ollama-Cloud-Modells.
.PARAMETER InputText
    Zu sendender Prompt. Der Inhalt wird nicht protokolliert oder persistiert.
.PARAMETER DataClassification
    Deklarierte Datenklasse des Prompts. Interne Daten werden von diesem Slice abgelehnt.
.PARAMETER AllowCloudEgress
    Explizite Freigabe für den Versand an ollama.com.
.PARAMETER Lane
    Explizite lokale oder Cloud-Lane. Standard ist cloud.
.PARAMETER LocalPort
    Dynamisch gebundener Loopback-Port eines lokalen Ollama-Endpunkts.
.PARAMETER SecretFilePath
    Optionale lokale .env-Datei. Standard ist .env im konfigurierten Media Root.
.PARAMETER MaximumOutputTokens
    Maximale Anzahl generierter Tokens.
.PARAMETER TimeoutSeconds
    Timeout pro Request.
.PARAMETER RetryCount
    Begrenzte Wiederholungen bei Timeout, HTTP 408, 429 oder 5xx.
.OUTPUTS
    Sanitisiertes Ergebnis mit Modell-/Planidentität, Versuchszahl, Text und Warncodes.
.EXAMPLE
    Invoke-SqlServerLabAiModel -ModelKey ollama-gpt-oss-120b-cloud -InputText 'Antworte nur mit OK.' -DataClassification synthetic-only -AllowCloudEgress
.EXAMPLE
    Invoke-SqlServerLabAiModel -ModelKey ollama-gpt-oss-120b-cloud -InputText 'Test' -DataClassification synthetic-only -AllowCloudEgress -WhatIf
#>
function Invoke-SqlServerLabAiModel {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{2,95}$')][string]$ModelKey,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InputText,
        [Parameter(Mandatory)][ValidateSet('synthetic-only','public-or-redistributable','internal-explicit')][string]$DataClassification,
        [switch]$AllowCloudEgress,
        [ValidateSet('local','cloud')][string]$Lane = 'cloud',
        [ValidateRange(1024,65535)][int]$LocalPort = 11434,
        [string]$SecretFilePath,
        [ValidateRange(1,4096)][int]$MaximumOutputTokens = 512,
        [ValidateRange(1,230)][int]$TimeoutSeconds = 60,
        [ValidateRange(0,10)][int]$RetryCount = 1
    )

    if ($Lane -eq 'cloud' -and $DataClassification -eq 'internal-explicit') { throw 'AI_ENDPOINT_INTERNAL_DATA_EGRESS_NOT_IMPLEMENTED' }
    $endpointRef = if ($Lane -eq 'cloud') { 'ollama-cloud' } else { 'ollama-local' }
    $plan = New-LabAiEndpointPlan -ModelKey $ModelKey -EndpointRef $endpointRef -Lane $Lane `
        -AllowCloudEgress:$AllowCloudEgress -MaximumRequests (1 + $RetryCount) `
        -MaximumOutputTokens $MaximumOutputTokens -TimeoutSeconds $TimeoutSeconds -RetryCount $RetryCount -LocalPort $LocalPort
    if ($plan.Status -eq 'BLOCKED') { throw "AI_ENDPOINT_PLAN_BLOCKED: $(@($plan.Blockers) -join ', ')" }

    $publicPlan = [PSCustomObject]@{
        Contract=$plan.Contract;Status=$plan.Status;Lane=$plan.Lane;EndpointRef=$plan.EndpointRef
        TargetHost=$plan.TargetHost;ModelKey=$plan.ModelKey;Purpose=$plan.Purpose;Dimension=$plan.Dimension
        Port=$plan.Port;CredentialRef=$plan.CredentialRef;Egress=$plan.Egress;RequestBudget=$plan.RequestBudget
        Blockers=@($plan.Blockers);Warnings=@($plan.Warnings);PlanKey=$plan.PlanKey
    }
    if (-not $PSCmdlet.ShouldProcess($plan.TargetHost, "katalogisiertes Modell $ModelKey aufrufen")) { return $publicPlan }

    $credential = $null
    $warnings = @()
    if ($Lane -eq 'cloud') {
        if (-not $SecretFilePath) {
            $mediaRoot = Get-LabMediaRootDefault
            if (-not $mediaRoot) { throw 'AI_SECRET_MEDIA_ROOT_NOT_CONFIGURED' }
            $SecretFilePath = Join-Path $mediaRoot '.env'
        }
        $secret = Get-LabAiDotEnvSecret -Path $SecretFilePath
        $credential = $secret.Secret
        $warnings = @($secret.Warnings)
    }
    $result = Invoke-LabAiEndpointRequest -Plan $plan -InputText $InputText -Credential $credential
    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiModelResult';Version='1.0'}
        Status=$result.Status;Purpose=$result.Purpose;ModelKey=$result.ModelKey;PlanKey=$result.PlanKey
        Attempts=$result.Attempts;Text=$result.Text;Vector=$result.Vector;Warnings=$warnings
    }
}
