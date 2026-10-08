# Einmalige HTTP-Commandannahme; keine fachliche Freigabe oder Persistenz.
function New-UiCommandGrantStore {
    param([Parameter(Mandatory)]$Session,[ValidateRange(1,256)][int]$Quota=256,[ValidateRange(50,60000)][int]$TtlMilliseconds=60000)
    if (-not $Session.Active -or $Session.Capability -cnotmatch '^[a-f0-9]{64}$') { throw 'UI_COMMAND_GRANT_SESSION_INVALID' }
    $key=[byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($key)
    return [pscustomobject]@{ Active=$true; Operator=$Session; OperatorCapability=$Session.Capability; ListenerUrl=$Session.ListenerUrl; Key=$key; Sync=[object]::new(); Quota=$Quota; TtlMilliseconds=$TtlMilliseconds; Tokens=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal); Receipts=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal) }
}

function Assert-UiCommandGrantBinding {
    param([Parameter(Mandatory)]$Store,[Parameter(Mandatory)]$Session,[Parameter(Mandatory)]$Request,[Parameter(Mandatory)][string]$Route,[Parameter(Mandatory)][string]$Method)
    if (-not $Store.Active -or -not $Session.Active -or -not [object]::ReferenceEquals($Store.Operator,$Session) -or
        $Store.OperatorCapability -cne $Session.Capability -or $Store.ListenerUrl -cne $Session.ListenerUrl -or
        $Request.Url -isnot [uri] -or $Request.Url.GetLeftPart([UriPartial]::Authority) -cne $Store.ListenerUrl.TrimEnd('/') -or
        -not $Request.Url.AbsolutePath.Equals($Route,[StringComparison]::OrdinalIgnoreCase) -or $Request.Url.Query -or
        $Request.HttpMethod -cne $Method) { throw 'UI_COMMAND_GRANT_REQUIRED' }
}

function Assert-UiCommandJsonUnique {
    param([Parameter(Mandatory)]$Element)
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw 'UI_COMMAND_REQUEST_INVALID' }
            Assert-UiCommandJsonUnique $property.Value
        }
    } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        foreach($item in $Element.EnumerateArray()) { Assert-UiCommandJsonUnique $item }
    }
}

function Get-UiCommandGrantRequest {
    param([Parameter(Mandatory)][string]$Body,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Catalog)
    $document=$null
    try {
        $json=if($Body.Length -gt 0 -and $Body[0] -eq [char]0xfeff){$Body.Substring(1)}else{$Body}
        $options=[Text.Json.JsonDocumentOptions]::new(); $options.MaxDepth=30
        $document=[Text.Json.JsonDocument]::Parse($json,$options)
        Assert-UiCommandJsonUnique $document.RootElement
        if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'UI_COMMAND_REQUEST_INVALID'}
        $request=$json|ConvertFrom-Json -Depth 30 -ErrorAction Stop
        $names=@($request.PSObject.Properties.Name)
        if ($names.Count -ne 4 -or @($names|Where-Object {$_ -cnotin @('commandName','confirmed','parameterSetName','parameters')}).Count -or
            $request.commandName -isnot [string] -or $request.parameterSetName -isnot [string] -or
            $request.parameters -isnot [pscustomobject] -or $request.confirmed -isnot [bool]) { throw 'UI_COMMAND_REQUEST_INVALID' }
        $commands=@($Catalog|Where-Object Name -CEQ $request.commandName)
        if($commands.Count -ne 1 -or $commands[0].RequiresConfirmation -isnot [bool]){throw 'UI_COMMAND_REQUEST_INVALID'}
        $sets=@($commands[0].ParameterSets|Where-Object Name -CEQ $request.parameterSetName)
        if($sets.Count -ne 1){throw 'UI_COMMAND_REQUEST_INVALID'}
        if($commands[0].RequiresConfirmation -and -not $request.confirmed){throw 'UI_COMMAND_REQUEST_INVALID'}
        return $request
    } catch { throw 'UI_COMMAND_REQUEST_INVALID' }
    finally { if($document){$document.Dispose()} }
}

function Get-UiCommandBodyMac {
    param([Parameter(Mandatory)]$Store,[Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $hmac=[Security.Cryptography.HMACSHA256]::new($Store.Key)
    try { return ,$hmac.ComputeHash($Bytes) } finally {$hmac.Dispose()}
}

function Clear-UiCommandReceiptMac {
    param([Parameter(Mandatory)]$Record)
    if($Record.BodyMac){[Array]::Clear($Record.BodyMac,0,$Record.BodyMac.Length);$Record.BodyMac=$null}
}

function New-UiCommandGrant {
    param([Parameter(Mandatory)]$Store,[Parameter(Mandatory)]$Session,[Parameter(Mandatory)]$Request,[Parameter(Mandatory)][byte[]]$Bytes)
    Assert-UiCommandGrantBinding $Store $Session $Request '/api/command-grants' 'POST'
    if($Request.Headers.GetValues('X-SqlServerLab-Action-Grant')){throw 'UI_COMMAND_GRANT_REQUIRED'}
    [Threading.Monitor]::Enter($Store.Sync)
    $tokenBytes=$null;$mac=$null
    try {
        if(-not $Store.Active -or $Store.Receipts.Count -ge $Store.Quota){throw 'UI_COMMAND_GRANT_CAPACITY'}
        $tokenBytes=[byte[]]::new(32);[Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
        $token=[Convert]::ToHexString($tokenBytes).ToLowerInvariant()
        $tokenKey=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($tokenBytes))
        $receiptId=[guid]::NewGuid().ToString('N')
        $mac=Get-UiCommandBodyMac $Store $Bytes
        $expires=[Diagnostics.Stopwatch]::GetTimestamp()+[long]([Diagnostics.Stopwatch]::Frequency*$Store.TtlMilliseconds/1000)
        $Store.Receipts.Add($receiptId,[pscustomobject]@{ReceiptId=$receiptId;State='ISSUED';JobId=$null;Expires=$expires;BodyLength=$Bytes.Length;BodyMac=$mac})
        $Store.Tokens.Add($tokenKey,$receiptId);$mac=$null
        return [pscustomobject]@{grant=$token;receiptId=$receiptId;expiresInMilliseconds=$Store.TtlMilliseconds}
    } finally {
        if($tokenBytes){[Array]::Clear($tokenBytes,0,$tokenBytes.Length)}
        if($mac){[Array]::Clear($mac,0,$mac.Length)}
        [Threading.Monitor]::Exit($Store.Sync)
    }
}

function Use-UiCommandGrant {
    param([Parameter(Mandatory)]$Store,[Parameter(Mandatory)]$Session,[Parameter(Mandatory)]$Request,[Parameter(Mandatory)][byte[]]$Bytes)
    Assert-UiCommandGrantBinding $Store $Session $Request '/api/commands' 'POST'
    $values=$Request.Headers.GetValues('X-SqlServerLab-Action-Grant')
    if($null -eq $values -or $values.Count -ne 1 -or $values[0] -cnotmatch '^[a-f0-9]{64}$'){throw 'UI_COMMAND_GRANT_REQUIRED'}
    $tokenBytes=[Convert]::FromHexString($values[0]);$mac=$null
    try {
        $tokenKey=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($tokenBytes))
        [Threading.Monitor]::Enter($Store.Sync)
        try {
            if(-not $Store.Active -or -not $Store.Tokens.ContainsKey($tokenKey)){throw 'UI_COMMAND_GRANT_REQUIRED'}
            $record=$Store.Receipts[$Store.Tokens[$tokenKey]]
            if($record.State -cne 'ISSUED'){throw 'UI_COMMAND_GRANT_REQUIRED'}
            # Erst nach vollständiger begrenzter Bodylesung, unter derselben Sperre.
            if([Diagnostics.Stopwatch]::GetTimestamp() -ge $record.Expires){$record.State='EXPIRED';Clear-UiCommandReceiptMac $record;throw 'UI_COMMAND_GRANT_REQUIRED'}
            $mac=Get-UiCommandBodyMac $Store $Bytes
            if($record.BodyLength -ne $Bytes.Length -or -not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($record.BodyMac,$mac)){throw 'UI_COMMAND_GRANT_REQUIRED'}
            if([Diagnostics.Stopwatch]::GetTimestamp() -ge $record.Expires){$record.State='EXPIRED';Clear-UiCommandReceiptMac $record;throw 'UI_COMMAND_GRANT_REQUIRED'}
            $record.State='CONSUMED';Clear-UiCommandReceiptMac $record
            return $record.ReceiptId
        } finally {[Threading.Monitor]::Exit($Store.Sync)}
    } finally {
        [Array]::Clear($tokenBytes,0,$tokenBytes.Length)
        if($mac){[Array]::Clear($mac,0,$mac.Length)}
    }
}

function Set-UiCommandGrantOutcome {
    param([Parameter(Mandatory)]$Store,[Parameter(Mandatory)][string]$ReceiptId,[AllowNull()][string]$JobId)
    [Threading.Monitor]::Enter($Store.Sync)
    try {
        if(-not $Store.Active -or -not $Store.Receipts.ContainsKey($ReceiptId)){throw 'UI_COMMAND_GRANT_REQUIRED'}
        $record=$Store.Receipts[$ReceiptId]
        if($record.State -cne 'CONSUMED'){throw 'UI_COMMAND_GRANT_REQUIRED'}
        if([string]::IsNullOrWhiteSpace($JobId)){$record.State='UNCONFIRMED'}else{$record.JobId=$JobId;$record.State='ACCEPTED'}
    } finally {[Threading.Monitor]::Exit($Store.Sync)}
}

function Get-UiCommandGrantReceipt {
    param([Parameter(Mandatory)]$Store,[Parameter(Mandatory)]$Session,[Parameter(Mandatory)]$Request,[Parameter(Mandatory)][string]$ReceiptId,[switch]$Cancel)
    $route='/api/command-grants/'+$ReceiptId+$(if($Cancel){'/cancel'}else{''})
    Assert-UiCommandGrantBinding $Store $Session $Request $route $(if($Cancel){'POST'}else{'GET'})
    [Threading.Monitor]::Enter($Store.Sync)
    try {
        if(-not $Store.Active -or $ReceiptId -cnotmatch '^[a-f0-9]{32}$' -or -not $Store.Receipts.ContainsKey($ReceiptId)){throw 'UI_COMMAND_GRANT_REQUIRED'}
        $record=$Store.Receipts[$ReceiptId]
        if($record.State -ceq 'ISSUED') {
            if([Diagnostics.Stopwatch]::GetTimestamp() -ge $record.Expires){$record.State='EXPIRED'}elseif($Cancel){$record.State='CANCELLED'}
            if($record.State -cne 'ISSUED'){Clear-UiCommandReceiptMac $record}
        }
        return [pscustomobject]@{receiptId=$record.ReceiptId;state=$record.State;jobId=$record.JobId}
    } finally {[Threading.Monitor]::Exit($Store.Sync)}
}

function Close-UiCommandGrantStore {
    param([Parameter(Mandatory)]$Store)
    [Threading.Monitor]::Enter($Store.Sync)
    try {
        $Store.Active=$false
        foreach($record in $Store.Receipts.Values){Clear-UiCommandReceiptMac $record}
        if($Store.Key){[Array]::Clear($Store.Key,0,$Store.Key.Length);$Store.Key=$null};$Store.OperatorCapability=$null;$Store.Operator=$null
        $Store.Tokens.Clear();$Store.Receipts.Clear()
    } finally {[Threading.Monitor]::Exit($Store.Sync)}
}
