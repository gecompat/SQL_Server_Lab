function Get-LabLlamaCppModelCatalog {
    [CmdletBinding()]
    param()

    if (-not $script:LlamaCppModelCatalog) {
        $path = Join-Path $script:CatalogsPath 'llama-cpp-models.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'LLAMA_MODEL_CATALOG_MISSING' }
        $catalog = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        if ($catalog.schemaVersion -cne '1.0' -or @($catalog.models).Count -lt 1) { throw 'LLAMA_MODEL_CATALOG_INVALID' }
        $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($model in @($catalog.models)) {
            $expectedPath = '/' + $model.source.repository + '/resolve/' + $model.source.revision + '/' + $model.fileName
            $uri = try { [uri]$model.source.downloadUrl } catch { $null }
            if (-not $ids.Add([string]$model.id) -or [string]$model.id -notmatch '^[a-z0-9][a-z0-9._-]{0,127}$' -or
                [string]$model.fileName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.gguf$' -or
                [string]$model.sha256 -notmatch '^[a-f0-9]{64}$' -or [long]$model.sizeBytes -lt 4 -or
                [string]$model.source.revision -notmatch '^[a-f0-9]{40}$' -or $model.source.gated -ne $false -or
                [string]$model.source.license -cne 'Apache-2.0' -or -not $uri -or $uri.Scheme -cne 'https' -or
                $uri.Host -cne 'huggingface.co' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment -or
                $uri.Query -cne '?download=true' -or $uri.AbsolutePath -cne $expectedPath) {
                throw 'LLAMA_MODEL_CATALOG_INVALID'
            }
        }
        $script:LlamaCppModelCatalog = $catalog
    }
    return $script:LlamaCppModelCatalog
}

function Get-LabLlamaCppModel {
    [CmdletBinding()]
    param([string]$Id)
    $models = @((Get-LabLlamaCppModelCatalog).models)
    if ($Id) {
        $match = @($models | Where-Object id -CEQ $Id)
        if ($match.Count -ne 1) { throw "LLAMA_MODEL_NOT_FOUND: $Id" }
        return $match[0]
    }
    return $models
}

function Confirm-LabLlamaCppModelFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "LLAMA_MODEL_FILE_INVALID: $($Model.id)"
    }
    if ($item.Length -ne [long]$Model.sizeBytes) { throw "LLAMA_MODEL_SIZE_MISMATCH: $($Model.id)" }
    $actual = (Get-LabProgressFileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actual -cne [string]$Model.sha256) { throw "LLAMA_MODEL_HASH_MISMATCH: $($Model.id)" }
    $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $magic = [byte[]]::new(4)
        if ($stream.Read($magic, 0, 4) -ne 4 -or [Text.Encoding]::ASCII.GetString($magic) -cne 'GGUF') {
            throw "LLAMA_MODEL_GGUF_INVALID: $($Model.id)"
        }
    }
    finally { $stream.Dispose() }
    return $item.FullName
}

function Save-LabLlamaCppModelFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$MediaRoot,
        [scriptblock]$DownloadAction
    )
    if (-not (Test-Path -LiteralPath $MediaRoot -PathType Container)) { throw "LLAMA_MODEL_MEDIA_ROOT_NOT_FOUND: $MediaRoot" }
    $resolvedRoot = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    $rootItem = Get-Item -LiteralPath $resolvedRoot -Force -ErrorAction Stop
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'LLAMA_MODEL_MEDIA_ROOT_REPARSE_POINT' }
    if ([string]$Model.fileName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.gguf$') { throw 'LLAMA_MODEL_FILE_NAME_INVALID' }

    $directory = $resolvedRoot
    foreach ($segment in @('AI', 'Models')) {
        $directory = Join-Path $directory $segment
        if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -ErrorAction Stop }
        $directoryItem = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if ($directoryItem -isnot [IO.DirectoryInfo] -or ($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'LLAMA_MODEL_STORAGE_REPARSE_POINT'
        }
    }
    $target = [IO.Path]::GetFullPath((Join-Path $directory ([string]$Model.fileName)))
    if (-not (Test-LabPathWithinRoot -Root $resolvedRoot -Path $target).Valid) { throw 'LLAMA_MODEL_PATH_OUTSIDE_MEDIA_ROOT' }
    if (Test-Path -LiteralPath $target) {
        $path = Confirm-LabLlamaCppModelFile -Model $Model -Path $target
        return [PSCustomObject]@{ Contract='SqlServerLab.LlamaCppModelAcquisition/1.0'; Id=$Model.id; Status='ALREADY_PRESENT'; Path=$path; Sha256=$Model.sha256; SizeBytes=[long]$Model.sizeBytes }
    }

    $uri = try { [uri]$Model.source.downloadUrl } catch { $null }
    $expectedPath = '/' + $Model.source.repository + '/resolve/' + $Model.source.revision + '/' + $Model.fileName
    if (-not $uri -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'huggingface.co' -or
        -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment -or $uri.Query -cne '?download=true' -or
        $uri.AbsolutePath -cne $expectedPath) {
        throw 'LLAMA_MODEL_DOWNLOAD_SOURCE_NOT_ALLOWED'
    }
    $lockPath = $target + '.lock'
    try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw "LLAMA_MODEL_DOWNLOAD_BUSY: $($Model.id)" }
    $temporary = Join-Path $directory ('.download-' + [guid]::NewGuid().ToString('N') + '.gguf')
    try {
        if (Test-Path -LiteralPath $target) {
            $path = Confirm-LabLlamaCppModelFile -Model $Model -Path $target
            return [PSCustomObject]@{ Contract='SqlServerLab.LlamaCppModelAcquisition/1.0'; Id=$Model.id; Status='ALREADY_PRESENT'; Path=$path; Sha256=$Model.sha256; SizeBytes=[long]$Model.sizeBytes }
        }
        if (-not $DownloadAction) {
            $DownloadAction = { param($Uri, $OutFile) Save-LabProgressDownload -Uri $Uri -OutFile $OutFile -MaximumRedirection 10 -ErrorAction Stop }
        }
        $null = & $DownloadAction $uri $temporary
        if (-not (Test-Path -LiteralPath $temporary -PathType Leaf)) { throw "LLAMA_MODEL_DOWNLOAD_MISSING: $($Model.id)" }
        $null = Confirm-LabLlamaCppModelFile -Model $Model -Path $temporary
        [IO.File]::Move($temporary, $target, $false)
        $path = Confirm-LabLlamaCppModelFile -Model $Model -Path $target
        return [PSCustomObject]@{ Contract='SqlServerLab.LlamaCppModelAcquisition/1.0'; Id=$Model.id; Status='DOWNLOADED'; Path=$path; Sha256=$Model.sha256; SizeBytes=[long]$Model.sizeBytes }
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        if ($lock) { $lock.Dispose() }
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}
