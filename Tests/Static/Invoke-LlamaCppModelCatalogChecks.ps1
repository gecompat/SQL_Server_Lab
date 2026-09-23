#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-llama-model-'+[guid]::NewGuid().ToString('N'))
try {
    $catalogPath=Join-Path $repoRoot 'Catalogs/llama-cpp-models.json'
    $schemaPath=Join-Path $repoRoot 'Schemas/llama-cpp-model-catalog.schema.json'
    $schemaValid=(Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | Test-Json -SchemaFile $schemaPath -ErrorAction Stop)
    Add-CheckResult 'GGUF-Katalog entspricht seinem JSON-Schema' $schemaValid
    $models=@(Get-SqlServerLabLlamaCppModel)
    Add-CheckResult 'Katalog bietet kompakte, ausgewogene und Performance-Stufe' (
        $models.Count -eq 3 -and @($models.HardwareTier|Sort-Object -Unique) -join ',' -eq 'balanced,compact,performance')
    Add-CheckResult 'Alle Modelle sind unveränderlich, hashgebunden und direkt beschaffbar' (
        @($models|Where-Object {-not $_.DirectDownload -or $_.Revision -notmatch '^[a-f0-9]{40}$' -or $_.Sha256 -notmatch '^[a-f0-9]{64}$' -or $_.SizeBytes -lt 4 -or $_.License -cne 'Apache-2.0'}).Count -eq 0)
    Add-CheckResult 'Kompaktes Q4_0 und größere Q4_K_M-Alternativen sind explizit' (
        (Get-SqlServerLabLlamaCppModel qwen2.5-1.5b-instruct-q4_0).Quantization -ceq 'Q4_0' -and
        (Get-SqlServerLabLlamaCppModel qwen3-4b-q4_k_m).Quantization -ceq 'Q4_K_M' -and
        (Get-SqlServerLabLlamaCppModel qwen3-8b-q4_k_m).Quantization -ceq 'Q4_K_M')
    $notFound='';try{$null=Get-SqlServerLabLlamaCppModel missing}catch{$notFound=$_.Exception.Message}
    Add-CheckResult 'Unbekannte Modell-ID fällt geschlossen aus' ($notFound -ceq 'LLAMA_MODEL_NOT_FOUND: missing')
    Add-CheckResult 'Öffentliche Downloadfunktion unterstützt WhatIf ohne Medienmutation' (
        @(Save-SqlServerLabLlamaCppModel -Id qwen3-4b-q4_k_m -MediaRoot (Join-Path $root 'missing') -WhatIf).Count -eq 0)

    $null=New-Item -ItemType Directory -Path $root -Force
    $payload=[byte[]](0x47,0x47,0x55,0x46,1,2,3,4,5,6,7,8)
    $fixture=Join-Path $root 'fixture.gguf';[IO.File]::WriteAllBytes($fixture,$payload)
    $hash=(Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant();Remove-Item $fixture
    $model=[pscustomobject]@{id='synthetic';fileName='synthetic.gguf';sizeBytes=[long]$payload.Length;sha256=$hash;source=[pscustomobject]@{repository='Qwen/Synthetic-GGUF';revision=('a'*40);downloadUrl=('https://huggingface.co/Qwen/Synthetic-GGUF/resolve/'+('a'*40)+'/synthetic.gguf?download=true')}}
    $downloads=[Collections.Generic.List[string]]::new()
    $download={param($Uri,$OutFile)$downloads.Add([string]$Uri);[IO.File]::WriteAllBytes($OutFile,$payload)}.GetNewClosure()
    $first=& $module {param($m,$r,$d)Save-LabLlamaCppModelFile -Model $m -MediaRoot $r -DownloadAction $d} $model $root $download
    Add-CheckResult 'Download wird erst nach Größe, Hash und GGUF-Magic atomisch veröffentlicht' (
        $first.Status -ceq 'DOWNLOADED' -and $downloads.Count -eq 1 -and (Test-Path -LiteralPath $first.Path -PathType Leaf))
    $second=& $module {param($m,$r,$d)Save-LabLlamaCppModelFile -Model $m -MediaRoot $r -DownloadAction $d} $model $root $download
    Add-CheckResult 'Vorhandener valider Cache wird revalidiert und nicht erneut geladen' ($second.Status -ceq 'ALREADY_PRESENT' -and $downloads.Count -eq 1)

    $badHash=$model|ConvertTo-Json -Depth 5|ConvertFrom-Json;$badHash.id='bad-hash';$badHash.fileName='bad-hash.gguf';$badHash.sha256='0'*64
    $badHash.source.downloadUrl='https://huggingface.co/Qwen/Synthetic-GGUF/resolve/'+('a'*40)+'/bad-hash.gguf?download=true'
    $failure='';try{$null=& $module {param($m,$r,$d)Save-LabLlamaCppModelFile $m $r $d} $badHash $root $download}catch{$failure=$_.Exception.Message}
    Add-CheckResult 'Hashfehler veröffentlicht kein Ziel und entfernt Teilstand' (
        $failure -ceq 'LLAMA_MODEL_HASH_MISMATCH: bad-hash' -and -not (Test-Path (Join-Path $root 'AI/Models/bad-hash.gguf')) -and
        @(Get-ChildItem (Join-Path $root 'AI/Models') -Filter '.download-*.gguf').Count -eq 0)

    $badSize=$model|ConvertTo-Json -Depth 5|ConvertFrom-Json;$badSize.id='bad-size';$badSize.fileName='bad-size.gguf';$badSize.sizeBytes=[long]$payload.Length+1
    $badSize.source.downloadUrl='https://huggingface.co/Qwen/Synthetic-GGUF/resolve/'+('a'*40)+'/bad-size.gguf?download=true'
    $failure='';try{$null=& $module {param($m,$r,$d)Save-LabLlamaCppModelFile $m $r $d} $badSize $root $download}catch{$failure=$_.Exception.Message}
    Add-CheckResult 'Größenfehler veröffentlicht kein Ziel' ($failure -ceq 'LLAMA_MODEL_SIZE_MISMATCH: bad-size' -and -not (Test-Path (Join-Path $root 'AI/Models/bad-size.gguf')))

    $invalidMagic=[byte[]](1,2,3,4,5);$invalidPath=Join-Path $root 'invalid.bin';[IO.File]::WriteAllBytes($invalidPath,$invalidMagic)
    $badMagic=$model|ConvertTo-Json -Depth 5|ConvertFrom-Json;$badMagic.id='bad-magic';$badMagic.fileName='bad-magic.gguf';$badMagic.sizeBytes=[long]$invalidMagic.Length
    $badMagic.sha256=(Get-FileHash $invalidPath -Algorithm SHA256).Hash.ToLowerInvariant();Remove-Item $invalidPath
    $badMagic.source.downloadUrl='https://huggingface.co/Qwen/Synthetic-GGUF/resolve/'+('a'*40)+'/bad-magic.gguf?download=true'
    $badDownload={param($Uri,$OutFile)[IO.File]::WriteAllBytes($OutFile,[byte[]](1,2,3,4,5))}
    $failure='';try{$null=& $module {param($m,$r,$d)Save-LabLlamaCppModelFile $m $r $d} $badMagic $root $badDownload}catch{$failure=$_.Exception.Message}
    Add-CheckResult 'GGUF-Magic bleibt auch bei passendem Hash Pflicht' ($failure -ceq 'LLAMA_MODEL_GGUF_INVALID: bad-magic')

    $badSource=$model|ConvertTo-Json -Depth 5|ConvertFrom-Json;$badSource.id='bad-source';$badSource.fileName='bad-source.gguf';$badSource.source.downloadUrl='https://example.invalid/bad-source.gguf'
    $called=$false;$never={param($Uri,$OutFile)$called=$true}.GetNewClosure()
    $failure='';try{$null=& $module {param($m,$r,$d)Save-LabLlamaCppModelFile $m $r $d} $badSource $root $never}catch{$failure=$_.Exception.Message}
    Add-CheckResult 'Nicht erlaubte Quelle wird vor Netzwerkaktion blockiert' ($failure -ceq 'LLAMA_MODEL_DOWNLOAD_SOURCE_NOT_ALLOWED' -and -not $called)
    $badPort=$model|ConvertTo-Json -Depth 5|ConvertFrom-Json;$badPort.id='bad-port';$badPort.fileName='bad-port.gguf'
    $badPort.source.downloadUrl='https://huggingface.co:444/Qwen/Synthetic-GGUF/resolve/'+('a'*40)+'/bad-port.gguf?download=true'
    $failure='';try{$null=& $module {param($m,$r,$d)Save-LabLlamaCppModelFile $m $r $d} $badPort $root $never}catch{$failure=$_.Exception.Message}
    Add-CheckResult 'Abweichender HTTPS-Port wird vor Netzwerkaktion blockiert' ($failure -ceq 'LLAMA_MODEL_DOWNLOAD_SOURCE_NOT_ALLOWED' -and -not $called)
    Add-CheckResult 'Neue öffentliche Befehle sind manifestexportiert' (
        (Get-Command Get-SqlServerLabLlamaCppModel).Source -ceq 'SqlServerLab' -and (Get-Command Save-SqlServerLabLlamaCppModel).Source -ceq 'SqlServerLab')
}
finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "LLAMA MODEL CATALOG CONTRACT: PASS ($passed)"
