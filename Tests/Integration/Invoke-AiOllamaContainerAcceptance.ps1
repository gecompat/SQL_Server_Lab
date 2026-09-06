#Requires -Version 7.2
<#
.SYNOPSIS
    Führt die lokale Ollama-Abnahme getrennt für Docker oder Podman aus.
.DESCRIPTION
    Startet einen eindeutig benannten, run-eigenen Ollama-Container auf einem
    dynamischen Loopback-Port, lädt die katalogisierten Referenzmodelle, prüft
    Live-Digests, Embedding und Generation, startet den Container neu und
    entfernt ihn im finally-Block. Es werden nur synthetische Texte verwendet.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [ValidateRange(60,1800)][int]$TimeoutSeconds = 900,
    [switch]$KeepOnFailure
)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runtimeName="sql-lab-ai-ollama-$Provider-$([Guid]::NewGuid().ToString('N').Substring(0,12))"
$tool=$null
$succeeded=$false

function Wait-OllamaReady {
    param([Parameter(Mandatory)][int]$Port,[Parameter(Mandatory)][int]$Timeout)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            $version=Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/version" -TimeoutSec 5
            if ([string]$version.version -match '^0\.11\.') { return }
        } catch { }
        Start-Sleep -Seconds 2
    } while($timer.Elapsed.TotalSeconds -lt $Timeout)
    throw 'AI_OLLAMA_LOCAL_READINESS_TIMEOUT'
}

try {
    $resolution=@(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if (-not $resolution.Available) { throw "AI_OLLAMA_PROVIDER_UNAVAILABLE: $Provider" }
    $tool=[string]$resolution.Invocation
    if ($Provider -eq 'podman') { & (Join-Path $repoRoot 'Tests\Integration\Initialize-PodmanRuntime.ps1') | Out-Null }
    & $tool info *> $null
    if ($LASTEXITCODE -ne 0) { throw "AI_OLLAMA_PROVIDER_UNREACHABLE: $Provider" }

    $catalog=Get-Content -LiteralPath (Join-Path $repoRoot 'Catalogs\ai-models.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $runtime=@($catalog.runtimes | Where-Object key -eq 'ollama-container-0-11-10')[0]
    $image="$($runtime.image):$($runtime.version)"
    & $tool pull $image *> $null
    if ($LASTEXITCODE -ne 0) { throw 'AI_OLLAMA_IMAGE_PULL_FAILED' }
    $imageDigest=[string](& $tool image inspect $image --format '{{index .RepoDigests 0}}' 2>$null | Select-Object -First 1)
    if ($imageDigest -notmatch '@sha256:[a-f0-9]{64}$') { throw 'AI_OLLAMA_IMAGE_DIGEST_MISSING' }

    & $tool run -d --name $runtimeName --label sql-server-lab.scope=ai-acceptance -p '127.0.0.1::11434' $image *> $null
    if ($LASTEXITCODE -ne 0) { throw 'AI_OLLAMA_CONTAINER_START_FAILED' }
    $portText=[string](& $tool port $runtimeName '11434/tcp' | Select-Object -First 1)
    if ($portText -notmatch ':(?<port>[0-9]+)$') { throw 'AI_OLLAMA_DYNAMIC_PORT_MISSING' }
    $port=[int]$Matches.port
    Wait-OllamaReady -Port $port -Timeout 90

    foreach($model in @('embeddinggemma:300m-qat-q4_0','gemma3:1b')) {
        $pullBody=@{model=$model;stream=$false}|ConvertTo-Json -Compress
        $null=Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/api/pull" -ContentType 'application/json' -Body $pullBody -TimeoutSec $TimeoutSeconds
    }
    $tags=Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/tags" -TimeoutSec 30
    foreach($model in @('embeddinggemma:300m-qat-q4_0','gemma3:1b')) {
        $match=@($tags.models | Where-Object name -eq $model)
        if ($match.Count -ne 1 -or [string]$match[0].digest -notmatch '^(sha256:)?[a-f0-9]{64}$') { throw "AI_OLLAMA_MODEL_DIGEST_MISSING: $model" }
    }

    Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
    $embedding=Invoke-SqlServerLabAiModel -ModelKey ollama-embeddinggemma-300m-q4 -Lane local -LocalPort $port `
        -InputText 'synthetischer SQL Server Vektortest' -DataClassification synthetic-only -MaximumOutputTokens 16 -TimeoutSeconds 120 -RetryCount 0 -Confirm:$false
    if ($embedding.Status -ne 'SUCCEEDED' -or $embedding.Vector.Count -ne 768) { throw 'AI_OLLAMA_LOCAL_EMBEDDING_FAILED' }
    $generation=Invoke-SqlServerLabAiModel -ModelKey ollama-gemma3-1b-local -Lane local -LocalPort $port `
        -InputText 'Antworte ausschließlich mit dem Wort OK.' -DataClassification synthetic-only -MaximumOutputTokens 64 -TimeoutSeconds 180 -RetryCount 0 -Confirm:$false
    if ($generation.Status -ne 'SUCCEEDED' -or [string]::IsNullOrWhiteSpace($generation.Text) -or $generation.Text.Length -gt 256) { throw 'AI_OLLAMA_LOCAL_GENERATION_FAILED' }

    & $tool restart $runtimeName *> $null
    if ($LASTEXITCODE -ne 0) { throw 'AI_OLLAMA_CONTAINER_RESTART_FAILED' }
    $restartPortText=[string](& $tool port $runtimeName '11434/tcp' | Select-Object -First 1)
    if ($restartPortText -notmatch ':(?<port>[0-9]+)$') { throw 'AI_OLLAMA_RESTART_PORT_MISSING' }
    $port=[int]$Matches.port
    Wait-OllamaReady -Port $port -Timeout 180
    $afterRestart=Invoke-SqlServerLabAiModel -ModelKey ollama-embeddinggemma-300m-q4 -Lane local -LocalPort $port `
        -InputText 'synthetischer Restarttest' -DataClassification synthetic-only -MaximumOutputTokens 16 -TimeoutSeconds 120 -RetryCount 0 -Confirm:$false
    if ($afterRestart.Vector.Count -ne 768) { throw 'AI_OLLAMA_LOCAL_RESTART_EMBEDDING_FAILED' }

    $succeeded=$true
    [PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.AiOllamaContainerAcceptance';Version='1.0'};Status='PASSED';Provider=$Provider;ImageDigest=$imageDigest;EmbeddingDimension=768;Generation='NON_EMPTY_BOUNDED';Restart='PASSED'}
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if ($tool -and ($succeeded -or -not $KeepOnFailure)) { & $tool rm -f $runtimeName *> $null }
}
