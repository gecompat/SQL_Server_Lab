# Synchronous own-session Start in the existing UI module; no jobs or ownership adoption.
function New-LabLlamaStartHttpResult {
    param([ValidateSet('ENDPOINT_VERIFIED','WHATIF_ONLY','NOT_CONFIRMED','RECOVERY_REQUIRED')][string]$Status,[AllowNull()][string]$OperationId,[bool]$PossibleOwnSession)
    [pscustomobject]@{
        Contract='SqlServerLab.BrowserLlamaStartResult/1.0';Status=$Status;OperationId=$(if($Status -ceq 'ENDPOINT_VERIFIED'){$OperationId}else{$null})
        SqlReadiness='NOT_CHECKED';PossibleOwnSession=$PossibleOwnSession;SameModuleRequired=$true
        AutoStopAllowed=$false;RetryAllowed=$false
    }
}

function Invoke-LabLlamaCppStartHttpRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][ValidateRange(1024,65535)][int]$ListenerPort)
    $ownedKey=$null;$arguments=@{};$dispatched=$false;$noEffect=$false;$document=$null;$bytes=$null;$text=$null
    try {
        $authority="http://127.0.0.1:$ListenerPort"
        if($Request.HttpMethod -cne 'POST' -or $Request.ContentType -cnotmatch '^application/json(?:\s*;\s*charset=utf-8)?$' -or
            $Request.LocalEndPoint.Address.ToString() -cne '127.0.0.1' -or $Request.LocalEndPoint.Port -ne $ListenerPort -or
            $Request.Url.Scheme -cne 'http' -or $Request.Url.Host -cne '127.0.0.1' -or $Request.Url.Port -ne $ListenerPort -or $Request.Url.UserInfo -or
            $Request.Url.GetLeftPart([UriPartial]::Authority) -cne $authority -or $Request.Headers['Origin'] -isnot [string] -or
            $Request.Headers['Origin'] -cne $authority){throw 'LLAMA_START_HTTP_INVALID'}
        $bytes=[byte[]]::new(65537);$length=0
        while($length -lt $bytes.Length){$read=$Request.InputStream.Read($bytes,$length,$bytes.Length-$length);if($read -eq 0){break};$length+=$read}
        if($length -gt 65536){throw 'LLAMA_START_HTTP_INVALID'}
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes,0,$length)
        if($text.Length -gt 32768){throw 'LLAMA_START_HTTP_INVALID'}
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=4
        $document=[Text.Json.JsonDocument]::Parse($text,$options)
        $pending=[Collections.Generic.Stack[Text.Json.JsonElement]]::new();$pending.Push($document.RootElement);$nodes=0
        while($pending.Count){
            if(++$nodes -gt 32){throw 'LLAMA_START_HTTP_INVALID'};$element=$pending.Pop()
            if($element.ValueKind -eq [Text.Json.JsonValueKind]::Object){
                $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach($property in $element.EnumerateObject()){if(-not $keys.Add($property.Name)){throw 'LLAMA_START_HTTP_INVALID'};$pending.Push($property.Value)}
            }elseif($element.ValueKind -eq [Text.Json.JsonValueKind]::Array){foreach($child in $element.EnumerateArray()){$pending.Push($child)}}
        }
        $root=$document.RootElement
        if($root.ValueKind -ne [Text.Json.JsonValueKind]::Object -or ((@($root.EnumerateObject()).Name|Sort-Object)-join ',') -cne 'Action,Confirmed,Parameters' -or
            $root.GetProperty('Action').ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $root.GetProperty('Confirmed').ValueKind -notin @([Text.Json.JsonValueKind]::True,[Text.Json.JsonValueKind]::False)){throw 'LLAMA_START_HTTP_INVALID'}
        $action=$root.GetProperty('Action').GetString();$confirmed=$root.GetProperty('Confirmed').GetBoolean()
        if(($action -ceq 'Start' -and -not $confirmed) -or ($action -ceq 'WhatIf' -and $confirmed) -or $action -cnotin @('Start','WhatIf')){throw 'LLAMA_START_HTTP_CONFIRMATION_REQUIRED'}
        $parameters=$root.GetProperty('Parameters')
        $names=@('RuntimeDirectory','Backend','Accelerator','ModelPath','ModelName','Dimension','Pooling','Port','CertificatePath','PrivateKeyPath','ApiKey','TrustedRootPath','StartTimeoutSeconds','LeaseSeconds','ContextSize')
        if($parameters.ValueKind -ne [Text.Json.JsonValueKind]::Object -or ((@($parameters.EnumerateObject()).Name|Sort-Object)-join ',') -cne (($names|Sort-Object)-join ',')){throw 'LLAMA_START_HTTP_INVALID'}
        foreach($name in @('RuntimeDirectory','ModelPath','CertificatePath','PrivateKeyPath','TrustedRootPath','Backend','Accelerator','ModelName','Pooling','ApiKey')){
            $value=$parameters.GetProperty($name);if($value.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'LLAMA_START_HTTP_INVALID'};$arguments[$name]=$value.GetString()
        }
        foreach($name in @('RuntimeDirectory','ModelPath','CertificatePath','PrivateKeyPath','TrustedRootPath')){
            if($arguments[$name].Length -gt 4096 -or ($name -cne 'TrustedRootPath' -and [string]::IsNullOrWhiteSpace($arguments[$name]))){throw 'LLAMA_START_HTTP_INVALID'}
        }
        if($arguments.Backend -cnotin @('LlamaCppCuda','LlamaCppOpenVino') -or $arguments.Accelerator -cnotin @('CPU','GPU','NPU') -or
            ($arguments.Backend -ceq 'LlamaCppCuda' -and $arguments.Accelerator -ceq 'NPU') -or $arguments.Pooling -cnotin @('mean','cls','last') -or
            $arguments.ModelName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $arguments.ApiKey -cnotmatch '^[A-Za-z0-9_-]{24,256}$'){throw 'LLAMA_START_HTTP_INVALID'}
        $limits=@{Dimension=@(1,1998);Port=@(1024,65535);StartTimeoutSeconds=@(1,600);LeaseSeconds=@(30,3600);ContextSize=@(32,8192)}
        foreach($name in $limits.Keys){
            $value=$parameters.GetProperty($name);$number=0
            if($value.ValueKind -ne [Text.Json.JsonValueKind]::Number -or $value.GetRawText() -cnotmatch '^[0-9]+$' -or -not $value.TryGetInt32([ref]$number) -or $number -lt $limits[$name][0] -or $number -gt $limits[$name][1]){throw 'LLAMA_START_HTTP_INVALID'}
            $arguments[$name]=$number
        }
        if($arguments.LeaseSeconds -le $arguments.StartTimeoutSeconds){throw 'LLAMA_START_HTTP_INVALID'}
        # Read effective module preference immediately before the unchanged public call.
        if($ConfirmPreference -isnot [Management.Automation.ConfirmImpact] -or $ConfirmPreference -notin @([Management.Automation.ConfirmImpact]::High,[Management.Automation.ConfirmImpact]::None)){throw 'LLAMA_START_HTTP_CONFIRM_POLICY_BLOCKED'}
        $ownedKey=[Security.SecureString]::new();foreach($character in $arguments.ApiKey.ToCharArray()){$ownedKey.AppendChar($character)};$ownedKey.MakeReadOnly();$arguments.ApiKey=$ownedKey
        if([string]::IsNullOrWhiteSpace($arguments.TrustedRootPath)){$arguments.Remove('TrustedRootPath')}
        $noEffect=$action -ceq 'WhatIf' -or [bool]$WhatIfPreference;$dispatched=$true
        if($action -ceq 'WhatIf'){$results=@(Start-SqlServerLabLlamaCppRuntime @arguments -WhatIf 3>$null 4>$null 5>$null 6>$null)}
        else{$results=@(Start-SqlServerLabLlamaCppRuntime @arguments 3>$null 4>$null 5>$null 6>$null)}
        if($noEffect){
            if($results.Count){return New-LabLlamaStartHttpResult -Status NOT_CONFIRMED -PossibleOwnSession $true}
            return New-LabLlamaStartHttpResult -Status WHATIF_ONLY -PossibleOwnSession $false
        }
        if($results.Count -ne 1){throw 'LLAMA_START_HTTP_RESULT_UNCONFIRMED'}
        Assert-LabGuidedLlamaResult -Result $results[0] -Arguments $arguments
        New-LabLlamaStartHttpResult -Status ENDPOINT_VERIFIED -OperationId $results[0].OperationId -PossibleOwnSession $true
    }catch{
        if($dispatched){
            $status=if($_.Exception.Message.StartsWith('LLAMA_RECOVERY_REQUIRED; OperationId=',[StringComparison]::Ordinal)){'RECOVERY_REQUIRED'}else{'NOT_CONFIRMED'}
            return New-LabLlamaStartHttpResult -Status $status -PossibleOwnSession (-not $noEffect)
        }
        if($_.Exception.Message -cin @('LLAMA_START_HTTP_INVALID','LLAMA_START_HTTP_CONFIRMATION_REQUIRED','LLAMA_START_HTTP_CONFIRM_POLICY_BLOCKED')){throw $_.Exception.Message}
        throw 'LLAMA_START_HTTP_INVALID'
    }finally{
        if($document){$document.Dispose()};if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}
        $text=$null;$parameters=$null;$root=$null;$results=$null;$arguments.Clear()
        if($ownedKey){$ownedKey.Dispose()}
    }
}
