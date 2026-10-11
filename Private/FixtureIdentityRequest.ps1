#Requires -Version 7.2
# Privater Formvalidator. Keine Zielbindung, Autorisierung oder Identitaetsanlage.

function Skip-FixtureIdentityJsonSpace {
    param([string]$Json, [hashtable]$State)
    while ($State.Offset -lt $Json.Length -and [int]$Json[$State.Offset] -in @(9,10,13,32)) { $State.Offset++ }
}

function Read-FixtureIdentityJsonValue {
    param([string]$Json, [hashtable]$State, [int]$Depth)
    Skip-FixtureIdentityJsonSpace $Json $State
    if ($State.Offset -ge $Json.Length) { $State.Invalid = $true; return $null }
    $character = $Json[$State.Offset]
    if ($character -eq '"') {
        $State.Offset++
        $builder = [Text.StringBuilder]::new()
        while ($State.Offset -lt $Json.Length) {
            $character = $Json[$State.Offset]; $State.Offset++
            if ($character -eq '"') { return [pscustomobject]@{ Type = 'string'; Value = $builder.ToString() } }
            if ([int]$character -lt 32) { break }
            if ($character -eq '\') {
                if ($State.Offset -ge $Json.Length) { break }
                $character = $Json[$State.Offset]; $State.Offset++
                switch -CaseSensitive ($character) {
                    'u' {
                        if ($State.Offset + 4 -gt $Json.Length) { $State.Invalid = $true; return $null }
                        $hex = $Json.Substring($State.Offset, 4)
                        if ($hex -cnotmatch '\A[0-9a-fA-F]{4}\z') { $State.Invalid = $true; return $null }
                        $character = [char][Convert]::ToInt32($hex, 16); $State.Offset += 4
                    }
                    'b' { $character = [char]8 }
                    'f' { $character = [char]12 }
                    'n' { $character = [char]10 }
                    'r' { $character = [char]13 }
                    't' { $character = [char]9 }
                    '"' { $character = [char]'"' }
                    '\' { $character = [char]'\' }
                    '/' { $character = [char]'/' }
                    default { $State.Invalid = $true; return $null }
                }
            }
            # Alle gueltigen Namen/Werte der geschlossenen Anfrage sind ASCII.
            # Auch escapete Surrogates/Nicht-ASCII koennen keine gueltige Form sein.
            if ([int]$character -gt 127) { break }
            [void]$builder.Append($character)
        }
        $State.Invalid = $true; return $null
    }
    if ($character -eq '{' -or $character -eq '[') {
        if ($Depth -ge 8) { $State.Invalid = $true; return $null }
        $isObject = $character -eq '{'
        $close = if ($isObject) { '}' } else { ']' }
        $items = [Collections.Generic.List[object]]::new()
        if ($isObject) { $items = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal) }
        $State.Offset++
        Skip-FixtureIdentityJsonSpace $Json $State
        if ($State.Offset -lt $Json.Length -and $Json[$State.Offset] -eq $close) { $State.Offset++ }
        else {
            while (-not $State.Invalid) {
                $key = $null
                if ($isObject) {
                    Skip-FixtureIdentityJsonSpace $Json $State
                    if ($State.Offset -ge $Json.Length -or $Json[$State.Offset] -ne '"') { $State.Invalid = $true; break }
                    $keyNode = Read-FixtureIdentityJsonValue $Json $State ($Depth + 1)
                    if ($State.Invalid) { break }
                    $key = $keyNode.Value
                    $State.Fields++
                    if ($State.Fields -gt 128 -or $items.ContainsKey($key)) { $State.Invalid = $true; break }
                    Skip-FixtureIdentityJsonSpace $Json $State
                    if ($State.Offset -ge $Json.Length -or $Json[$State.Offset] -ne ':') { $State.Invalid = $true; break }
                    $State.Offset++
                }
                $value = Read-FixtureIdentityJsonValue $Json $State ($Depth + 1)
                if ($State.Invalid) { break }
                if ($isObject) { $items.Add($key, $value) } else { $items.Add($value) }
                Skip-FixtureIdentityJsonSpace $Json $State
                if ($State.Offset -ge $Json.Length) { $State.Invalid = $true; break }
                $separator = $Json[$State.Offset]; $State.Offset++
                if ($separator -eq $close) { break }
                if ($separator -ne ',') { $State.Invalid = $true; break }
                # Nach Komma ist ein weiteres Element Pflicht, kein trailing comma.
                Skip-FixtureIdentityJsonSpace $Json $State
                if ($State.Offset -ge $Json.Length -or $Json[$State.Offset] -eq $close) { $State.Invalid = $true; break }
            }
        }
        if ($State.Invalid) { return $null }
        return [pscustomobject]@{ Type = $(if ($isObject) { 'object' } else { 'array' }); Value = $items }
    }
    # Nur DurationSeconds kann eine Zahl sein: JSONinteger, kein Float/Exponent.
    $start = $State.Offset
    if ($character -eq '-') { $State.Offset++ }
    if ($State.Offset -ge $Json.Length -or [int]$Json[$State.Offset] -lt 48 -or [int]$Json[$State.Offset] -gt 57) {
        $State.Invalid = $true; return $null
    }
    if ($Json[$State.Offset] -eq '0') { $State.Offset++ }
    else {
        while ($State.Offset -lt $Json.Length -and [int]$Json[$State.Offset] -ge 48 -and [int]$Json[$State.Offset] -le 57) { $State.Offset++ }
    }
    $number = 0
    if (-not [int]::TryParse($Json.Substring($start, $State.Offset - $start), [ref]$number)) { $State.Invalid = $true; return $null }
    return [pscustomobject]@{ Type = 'integer'; Value = $number }
}

function Test-FixtureIdentityFields {
    param([object]$Node, [string[]]$Required, [string[]]$Optional = @())
    if ($null -eq $Node -or $Node.Type -ne 'object') { return $false }
    foreach ($name in $Required) { if (-not $Node.Value.ContainsKey($name)) { return $false } }
    foreach ($name in $Node.Value.Keys) {
        $known = $false
        foreach ($expected in @($Required) + @($Optional)) {
            if ([string]::Equals($name, $expected, [StringComparison]::Ordinal)) { $known = $true; break }
        }
        if (-not $known) { return $false }
    }
    return $true
}

function Test-FixtureIdentityString {
    param([object]$Node, [string[]]$Allowed)
    if ($null -eq $Node -or $Node.Type -ne 'string') { return $false }
    foreach ($value in $Allowed) { if ([string]::Equals($Node.Value, $value, [StringComparison]::Ordinal)) { return $true } }
    return $false
}

function Test-FixtureIdentityAlias {
    param([object]$Node)
    return $null -ne $Node -and $Node.Type -eq 'string' -and $Node.Value.Length -ge 1 -and $Node.Value.Length -le 32 -and
        $Node.Value -cmatch '\A[A-Za-z0-9_]{1,32}\z'
}

function Get-FixtureIdentityUsageMask {
    param([object]$Node)
    if (Test-FixtureIdentityString $Node @('MANUAL')) { return 1 }
    if (Test-FixtureIdentityString $Node @('AUTOMATED')) { return 2 }
    if (Test-FixtureIdentityString $Node @('MANUAL_AND_AUTOMATED')) { return 3 }
    return 0
}

function Get-FixtureIdentityRetention {
    param([object]$Node, [int]$UsageMask)
    if (-not (Test-FixtureIdentityFields $Node @('Mode') @('DurationSeconds'))) { return $null }
    $fields = $Node.Value
    if (Test-FixtureIdentityString $fields['Mode'] @('OPERATION')) {
        if ($UsageMask -ne 2 -or $fields.ContainsKey('DurationSeconds')) { return $null }
        return [pscustomobject][ordered]@{ Mode = 'OPERATION' }
    }
    if (-not (Test-FixtureIdentityString $fields['Mode'] @('SCENARIO'))) { return $null }
    $duration = 14400
    if ($fields.ContainsKey('DurationSeconds')) {
        $value = $fields['DurationSeconds']
        if ($value.Type -ne 'integer' -or $value.Value -lt 1 -or $value.Value -gt 86400) { return $null }
        $duration = $value.Value
    }
    return [pscustomobject][ordered]@{ Mode = 'SCENARIO'; DurationSeconds = $duration }
}

function ConvertFrom-FixtureIdentityRequestBytes {
    [CmdletBinding()]
    param([object]$Bytes)

    $rejected = [pscustomobject]@{ Success = $false; Value = $null; ErrorCode = 'FIXTURE_REQUEST_INVALID' }
    if ($Bytes -isnot [byte[]]) { return $rejected }
    # Wie beim I01-Formcodec hat jede gueltige Anfrage nur ASCII-UTF8-Bytes;
    # JSON-Unicode-Escapes dieser Zeichen bleiben erlaubt. Kein Raw-Parserfehler.
    # Array direkt zaehlen, keine vom Caller ueberschriebene Length-Property.
    $size = 0
    foreach ($byte in $Bytes) { $size++; if ($size -gt 16384 -or $byte -gt 127) { return $rejected } }
    if ($size -eq 0) { return $rejected }
    $json = [Text.Encoding]::ASCII.GetString($Bytes)
    $state = @{ Offset = 0; Fields = 0; Invalid = $false }
    $root = Read-FixtureIdentityJsonValue $json $state 0
    if ($state.Invalid) { return $rejected }
    Skip-FixtureIdentityJsonSpace $json $state
    if ($state.Offset -ne $json.Length -or -not (Test-FixtureIdentityFields $root @('ContractVersion','RequestRef','TargetRef','ScenarioAlias','OsIdentities','SqlIdentities'))) { return $rejected }
    $fields = $root.Value
    if (-not (Test-FixtureIdentityString $fields['ContractVersion'] @('1.0')) -or
        -not (Test-FixtureIdentityAlias $fields['ScenarioAlias'])) { return $rejected }
    foreach ($name in @('RequestRef','TargetRef')) {
        if ($fields[$name].Type -ne 'string' -or -not (Test-FixtureHandleId $fields[$name].Value)) { return $rejected }
    }
    $sql = $fields['SqlIdentities']
    if ($fields['OsIdentities'].Type -ne 'array' -or -not (Test-FixtureIdentityFields $sql @('Logins','DatabaseUsers')) -or
        $sql.Value['Logins'].Type -ne 'array' -or $sql.Value['DatabaseUsers'].Type -ne 'array') { return $rejected }
    $osNodes = $fields['OsIdentities'].Value; $loginNodes = $sql.Value['Logins'].Value; $userNodes = $sql.Value['DatabaseUsers'].Value
    $total = $osNodes.Count + $loginNodes.Count + $userNodes.Count
    if ($osNodes.Count -gt 16 -or $loginNodes.Count -gt 16 -or $userNodes.Count -gt 32 -or $total -lt 1 -or $total -gt 64) { return $rejected }

    $os = [Collections.Generic.List[object]]::new(); $logins = [Collections.Generic.List[object]]::new(); $users = [Collections.Generic.List[object]]::new()
    $osAliases = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $loginAliases = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $userAliases = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $loginByAlias = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($group in @('OS','LOGIN','USER')) {
        $nodes = $osNodes
        if ($group -eq 'LOGIN') { $nodes = $loginNodes }
        if ($group -eq 'USER') { $nodes = $userNodes }
        $required = @('Alias','Usage','Retention')
        if ($group -eq 'OS') { $required += 'Kind' }
        if ($group -eq 'USER') { $required += @('LoginAlias','DatabaseRef','ProfileAlias') }
        foreach ($node in $nodes) {
            if (-not (Test-FixtureIdentityFields $node $required)) { return $rejected }
            $entry = $node.Value
            if (-not (Test-FixtureIdentityAlias $entry['Alias'])) { return $rejected }
            $usage = Get-FixtureIdentityUsageMask $entry['Usage']
            if ($usage -eq 0) { return $rejected }
            $retention = Get-FixtureIdentityRetention $entry['Retention'] $usage
            if ($null -eq $retention) { return $rejected }
            if ($group -eq 'OS') {
                if (-not (Test-FixtureIdentityString $entry['Kind'] @('WINDOWS_LOCAL_ACCOUNT','LINUX_LOCAL_ACCOUNT','LINUX_NUMERIC_CONTEXT')) -or
                    -not $osAliases.Add($entry['Alias'].Value)) { return $rejected }
                $os.Add([pscustomobject][ordered]@{ Alias = $entry['Alias'].Value; Kind = $entry['Kind'].Value; Usage = $entry['Usage'].Value; Retention = $retention })
            }
            elseif ($group -eq 'LOGIN') {
                if (-not $loginAliases.Add($entry['Alias'].Value)) { return $rejected }
                $login = [pscustomobject][ordered]@{ Alias = $entry['Alias'].Value; Usage = $entry['Usage'].Value; Retention = $retention }
                $logins.Add($login); $loginByAlias.Add($login.Alias, $login)
            }
            else {
                if (-not (Test-FixtureIdentityAlias $entry['LoginAlias']) -or -not (Test-FixtureIdentityAlias $entry['ProfileAlias']) -or
                    $entry['DatabaseRef'].Type -ne 'string' -or -not (Test-FixtureHandleId $entry['DatabaseRef'].Value) -or
                    -not $userAliases.Add($entry['DatabaseRef'].Value + '|' + $entry['Alias'].Value) -or
                    -not $loginByAlias.ContainsKey($entry['LoginAlias'].Value)) { return $rejected }
                $login = $loginByAlias[$entry['LoginAlias'].Value]
                $loginUsage = Get-FixtureIdentityUsageMask ([pscustomobject]@{ Type = 'string'; Value = $login.Usage })
                if (($usage -band $loginUsage) -ne $usage -or
                    ($retention.Mode -eq 'SCENARIO' -and ($login.Retention.Mode -ne 'SCENARIO' -or $retention.DurationSeconds -gt $login.Retention.DurationSeconds))) { return $rejected }
                $users.Add([pscustomobject][ordered]@{
                    Alias = $entry['Alias'].Value; LoginAlias = $entry['LoginAlias'].Value; DatabaseRef = $entry['DatabaseRef'].Value
                    ProfileAlias = $entry['ProfileAlias'].Value; Usage = $entry['Usage'].Value; Retention = $retention
                })
            }
        }
    }
    return [pscustomobject]@{
        Success = $true
        Value = [pscustomobject][ordered]@{
            ContractVersion = '1.0'; RequestRef = $fields['RequestRef'].Value; TargetRef = $fields['TargetRef'].Value; ScenarioAlias = $fields['ScenarioAlias'].Value
            OsIdentities = $os.ToArray(); SqlIdentities = [pscustomobject][ordered]@{ Logins = $logins.ToArray(); DatabaseUsers = $users.ToArray() }
        }
        ErrorCode = $null
    }
}
