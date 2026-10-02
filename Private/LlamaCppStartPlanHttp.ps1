# Dedicated files-only preview. No workflow, job, session or execution token.
function Invoke-LabLlamaCppStartPlanHttpRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)
    try {
        if ($Request.HttpMethod -cne 'POST' -or $Request.ContentType -notmatch '^application/json(?:\s*;\s*charset=utf-8)?$') { throw 'LLAMA_START_PLAN_HTTP_INVALID' }
        $origin=[string]$Request.Headers['Origin']
        if ($origin -and $origin -cne $Request.Url.GetLeftPart([UriPartial]::Authority)) { throw 'LLAMA_START_PLAN_HTTP_INVALID' }
        # Decode only valid UTF-8 bytes; no replacement-character fallback.
        $bytes=[byte[]]::new(65537);$length=0
        while ($length -lt $bytes.Length) {
            $read=$Request.InputStream.Read($bytes,$length,$bytes.Length-$length)
            if ($read -eq 0) { break };$length+=$read
        }
        if ($length -gt 65536) { throw 'LLAMA_START_PLAN_HTTP_INVALID' }
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes,0,$length)
        if ($text.Length -gt 16384) { throw 'LLAMA_START_PLAN_HTTP_INVALID' }
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=4
        $document=[Text.Json.JsonDocument]::Parse($text,$options)
        try {
            $pending=[Collections.Generic.Stack[Text.Json.JsonElement]]::new();$pending.Push($document.RootElement);$nodes=0
            while ($pending.Count) {
                if (++$nodes -gt 32) { throw 'LLAMA_START_PLAN_HTTP_INVALID' }
                $element=$pending.Pop()
                if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                    $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    foreach ($property in $element.EnumerateObject()) {
                        if (-not $keys.Add($property.Name)) { throw 'LLAMA_START_PLAN_HTTP_INVALID' };$pending.Push($property.Value)
                    }
                } elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                    foreach ($child in $element.EnumerateArray()) { $pending.Push($child) }
                }
            }
            $root=$document.RootElement
            if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
                ((@($root.EnumerateObject()).Name | Sort-Object) -join ',') -cne 'Action,Parameters' -or
                $root.GetProperty('Action').ValueKind -ne [Text.Json.JsonValueKind]::String -or $root.GetProperty('Action').GetString() -cne 'Preview') { throw 'LLAMA_START_PLAN_HTTP_INVALID' }
            $parameters=$root.GetProperty('Parameters')
            $names=@('RuntimeDirectory','Backend','Accelerator','ModelPath','Dimension','Pooling','Port','StartTimeoutSeconds','LeaseSeconds','ContextSize')
            if ($parameters.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
                ((@($parameters.EnumerateObject()).Name | Sort-Object) -join ',') -cne (($names | Sort-Object) -join ',')) { throw 'LLAMA_START_PLAN_HTTP_INVALID' }
            $arguments=@{}
            foreach ($name in @('RuntimeDirectory','ModelPath','Backend','Accelerator','Pooling')) {
                $value=$parameters.GetProperty($name)
                if ($value.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'LLAMA_START_PLAN_HTTP_INVALID' }
                $arguments[$name]=$value.GetString()
            }
            foreach ($name in @('RuntimeDirectory','ModelPath')) {
                if (-not $arguments[$name] -or $arguments[$name].Length -gt 4096) { throw 'LLAMA_START_PLAN_HTTP_INVALID' }
            }
            if ($arguments.Backend -cnotin @('LlamaCppCuda','LlamaCppOpenVino') -or $arguments.Accelerator -cnotin @('CPU','GPU','NPU') -or $arguments.Pooling -cnotin @('mean','cls','last')) { throw 'LLAMA_START_PLAN_HTTP_INVALID' }
            $limits=@{Dimension=@(1,1998);Port=@(1024,65535);StartTimeoutSeconds=@(1,600);LeaseSeconds=@(30,3600);ContextSize=@(32,8192)}
            foreach ($name in $limits.Keys) {
                $value=$parameters.GetProperty($name);$number=0
                if ($value.ValueKind -ne [Text.Json.JsonValueKind]::Number -or $value.GetRawText() -cnotmatch '^[0-9]+$' -or
                    -not $value.TryGetInt32([ref]$number) -or $number -lt $limits[$name][0] -or $number -gt $limits[$name][1]) { throw 'LLAMA_START_PLAN_HTTP_INVALID' }
                $arguments[$name]=$number
            }
            if ($arguments.LeaseSeconds -le $arguments.StartTimeoutSeconds) { throw 'LLAMA_START_PLAN_LEASE_INVALID' }
            if ($arguments.Backend -ceq 'LlamaCppCuda' -and $arguments.Accelerator -ceq 'NPU') { throw 'LLAMA_START_PLAN_ACCELERATOR_UNSUPPORTED' }
        } finally { $document.Dispose() }
        $plans=@(Get-SqlServerLabLlamaCppStartPlan @arguments -WarningAction SilentlyContinue -InformationAction SilentlyContinue)
        if ($plans.Count -ne 1) { throw 'LLAMA_START_PLAN_HTTP_RESULT_INVALID' }
        # Existing strict DTO validator is unchanged; its code is not exposed as HTTP text.
        try { Assert-LabLlamaStartPlanConsoleResult -Plan $plans[0] -Arguments $arguments } catch { throw 'LLAMA_START_PLAN_HTTP_RESULT_INVALID' }
        return $plans[0]
    } catch {
        $known=@('LLAMA_START_PLAN_HTTP_INVALID','LLAMA_START_PLAN_HTTP_RESULT_INVALID','LLAMA_START_PLAN_PATH_INVALID','LLAMA_START_PLAN_FILE_INVALID','LLAMA_START_PLAN_REPARSE_REJECTED','LLAMA_START_PLAN_DIRECTORY_LIMIT','LLAMA_START_PLAN_FILE_LIMIT','LLAMA_START_PLAN_GGUF_REQUIRED','LLAMA_START_PLAN_LEASE_INVALID','LLAMA_START_PLAN_ACCELERATOR_UNSUPPORTED','LLAMA_START_PLAN_RUNTIME_MISMATCH','LLAMA_START_PLAN_INPUT_DRIFT','LLAMA_START_PLAN_INPUT_UNREADABLE')
        if ($_.Exception.Message -cin $known) { throw $_.Exception.Message }
        throw 'LLAMA_START_PLAN_HTTP_INVALID'
    }
}
