#Requires -Version 7.2
<#
.SYNOPSIS
    Führt den expliziten, kostenbegrenzten Ollama-Cloud-Generation-Smoke aus.
.DESCRIPTION
    Verwendet ausschließlich einen synthetischen Prompt, liest den festen
    OLLAMA-Schlüssel lokal und prüft eine einzelne kataloggebundene Antwort.
    Der Test gibt weder Secretwert noch Prompt-/Thinking-Inhalt aus.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SecretFilePath,
    [ValidateRange(1,230)][int]$TimeoutSeconds = 120
)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
try {
    $result=Invoke-SqlServerLabAiModel -ModelKey ollama-gpt-oss-120b-cloud `
        -InputText 'Antworte ausschließlich mit dem Wort OK.' `
        -DataClassification synthetic-only -AllowCloudEgress `
        -SecretFilePath $SecretFilePath -MaximumOutputTokens 256 `
        -TimeoutSeconds $TimeoutSeconds -RetryCount 0 -Confirm:$false
    if ($result.Status -ne 'SUCCEEDED' -or $result.Text.Trim() -cne 'OK' -or $result.Attempts -ne 1) {
        throw 'AI_OLLAMA_CLOUD_ACCEPTANCE_FAILED'
    }
    Write-Host "AI OLLAMA CLOUD ACCEPTANCE: PASS ($($result.ModelKey), 1 Request)" -ForegroundColor Green
    if (@($result.Warnings).Count -gt 0) { Write-Warning (@($result.Warnings) -join ', ') }
}
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue }
