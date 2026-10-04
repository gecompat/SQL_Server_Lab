# Metadata observations only; this plan never creates an owned runtime.
function Get-LabLlamaStartPlanItem {
    param([Parameter(Mandatory)][string]$Path,[switch]$Directory)
    if ($Path.Length -gt 4096 -or -not [IO.Path]::IsPathFullyQualified($Path) -or $Path.StartsWith('\\') -or $Path.StartsWith('//')) { throw 'LLAMA_START_PLAN_PATH_INVALID' }
    $full=[IO.Path]::GetFullPath($Path)
    if ($IsWindows -and $full.Substring(2).Contains(':')) { throw 'LLAMA_START_PLAN_PATH_INVALID' }
    $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (($Directory -and $item -isnot [IO.DirectoryInfo]) -or (-not $Directory -and $item -isnot [IO.FileInfo])) { throw 'LLAMA_START_PLAN_FILE_INVALID' }
    $ancestor=$item
    while ($ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'LLAMA_START_PLAN_REPARSE_REJECTED' }
        $ancestor=if ($ancestor -is [IO.FileInfo]) {$ancestor.Directory} else {$ancestor.Parent}
    }
    if ($Directory -and $item.FullName -eq $item.Root.FullName) { throw 'LLAMA_START_PLAN_PATH_INVALID' }
    $item
}

function Get-LabLlamaStartPlanObservation {
    param([Parameter(Mandatory)][string]$RuntimeDirectory,[Parameter(Mandatory)][string]$ModelPath)
    $root=Get-LabLlamaStartPlanItem -Path $RuntimeDirectory -Directory
    $children=@(Get-ChildItem -LiteralPath $root.FullName -Directory -Force -ErrorAction Stop | Select-Object -First 17)
    if ($children.Count -gt 16) { throw 'LLAMA_START_PLAN_DIRECTORY_LIMIT' }
    $rows=@(foreach ($directory in @($root)+$children) {
        $checked=Get-LabLlamaStartPlanItem -Path $directory.FullName -Directory
        $files=@(Get-ChildItem -LiteralPath $checked.FullName -File -Force -ErrorAction Stop | Select-Object -First 257)
        if ($files.Count -gt 256) { throw 'LLAMA_START_PLAN_FILE_LIMIT' }
        foreach ($file in $files) {
            $checkedFile=Get-LabLlamaStartPlanItem -Path $file.FullName
            [ordered]@{Path=$checkedFile.FullName;Length=$checkedFile.Length;WriteTicks=$checkedFile.LastWriteTimeUtc.Ticks}
        }
        [ordered]@{Path=$checked.FullName;Length=$null;WriteTicks=$checked.LastWriteTimeUtc.Ticks}
    })
    $model=Get-LabLlamaStartPlanItem -Path $ModelPath
    if ($model.Length -lt 4) { throw 'LLAMA_START_PLAN_GGUF_REQUIRED' }
    $stream=[IO.File]::Open($model.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $magic=[byte[]]::new(4)
        if ($stream.Read($magic,0,4) -ne 4 -or [Text.Encoding]::ASCII.GetString($magic) -cne 'GGUF') { throw 'LLAMA_START_PLAN_GGUF_REQUIRED' }
    } finally { $stream.Dispose() }
    $model.Refresh()
    [pscustomobject]@{Root=$root.FullName;Rows=@($rows|Sort-Object {$_.Path});Model=[ordered]@{Path=$model.FullName;Length=$model.Length;WriteTicks=$model.LastWriteTimeUtc.Ticks;Magic='GGUF'}}
}

function Get-LabLlamaCppStartPlan {
    param([string]$RuntimeDirectory,[string]$Backend,[string]$Accelerator,[string]$ModelPath,[int]$Dimension,[string]$Pooling,[int]$Port,[int]$StartTimeoutSeconds,[int]$LeaseSeconds,[int]$ContextSize)
    try {
        if ($LeaseSeconds -le $StartTimeoutSeconds) { throw 'LLAMA_START_PLAN_LEASE_INVALID' }
        if ($Backend -ceq 'LlamaCppCuda' -and $Accelerator -ceq 'NPU') { throw 'LLAMA_START_PLAN_ACCELERATOR_UNSUPPORTED' }
        $before=Get-LabLlamaStartPlanObservation -RuntimeDirectory $RuntimeDirectory -ModelPath $ModelPath
        $comparer=if($IsWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
        $runtimes=@(Find-LabLlamaCppRuntime -SearchRoot @($before.Root) -WarningAction SilentlyContinue | Where-Object {$comparer.Equals([string]$_.InstallationPath,$before.Root)})
        if ($runtimes.Count -ne 1 -or [string]$runtimes[0].Backend -cne $Backend -or [string]$runtimes[0].EvidenceStatus -cne 'FILES_ONLY') { throw 'LLAMA_START_PLAN_RUNTIME_MISMATCH' }
        $after=Get-LabLlamaStartPlanObservation -RuntimeDirectory $RuntimeDirectory -ModelPath $ModelPath
        if (($before|ConvertTo-Json -Depth 8 -Compress) -cne ($after|ConvertTo-Json -Depth 8 -Compress)) { throw 'LLAMA_START_PLAN_INPUT_DRIFT' }
        # No locators, arbitrary caller text, approval token or artifact hashes are projected.
        [pscustomobject]@{
            Contract=[pscustomobject]@{Name='SqlServerLab.LlamaCppStartPlan';Version='1.0'}
            Mode='PLAN_ONLY';Status='BLOCKED';Actions=@();ExecutionSupported=$false;MutationAllowed=$false
            Backend=$Backend;Accelerator=$Accelerator;Dimension=$Dimension;Pooling=$Pooling;Port=$Port
            StartTimeoutSeconds=$StartTimeoutSeconds;LeaseSeconds=$LeaseSeconds;ContextSize=$ContextSize
            RuntimeEvidence='FILES_ONLY';ModelFormat='GGUF';InputObservation='METADATA_STABLE_NOT_CAS'
            DeviceReadiness='NOT_CHECKED';PortAvailability='NOT_CHECKED';EmbeddingReadiness='NOT_CHECKED'
            TlsReadiness='NOT_CHECKED';PrivateKeyMatch='NOT_CHECKED';SanTrust='NOT_CHECKED';SqlReadiness='NOT_CHECKED'
            Blockers=@('LIVE_READINESS_NOT_CHECKED','TLS_AND_SECRETS_NOT_SUPPLIED','SQL_EMBEDDING_NOT_CHECKED')
            NextSteps=@('SELECT_EXPLICIT_START_INPUTS','VALIDATE_TLS_AND_DEVICE_READINESS_SEPARATELY','USE_EXISTING_START_WITH_FRESH_INPUT_VALIDATION')
        }
    } catch {
        $code=[string]$_.Exception.Message
        $known=@('LLAMA_START_PLAN_PATH_INVALID','LLAMA_START_PLAN_FILE_INVALID','LLAMA_START_PLAN_REPARSE_REJECTED','LLAMA_START_PLAN_DIRECTORY_LIMIT','LLAMA_START_PLAN_FILE_LIMIT','LLAMA_START_PLAN_GGUF_REQUIRED','LLAMA_START_PLAN_LEASE_INVALID','LLAMA_START_PLAN_ACCELERATOR_UNSUPPORTED','LLAMA_START_PLAN_RUNTIME_MISMATCH','LLAMA_START_PLAN_INPUT_DRIFT')
        if ($code -cnotin $known) { $code='LLAMA_START_PLAN_INPUT_UNREADABLE' }
        throw $code
    }
}
