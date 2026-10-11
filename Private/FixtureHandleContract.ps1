#Requires -Version 7.2
# Interner Formcodec; keine Aufloesung, Autorisierung oder Identitaetsanlage.

function Test-FixtureHandleId {
    param([object]$Value)
    if ($Value -isnot [string] -or $Value.Length -ne 36 -or
        $Value -cnotmatch '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') { return $false }
    $id = [guid]::Empty
    return [guid]::TryParseExact($Value, 'D', [ref]$id) -and $id -ne [guid]::Empty
}

function ConvertFrom-FixtureHandleBytes {
    [CmdletBinding()]
    param([object]$Bytes)

    $rejected = [pscustomobject]@{ Success = $false; Value = $null; ErrorCode = 'FIXTURE_HANDLE_INVALID' }
    if ($Bytes -isnot [byte[]] -or $Bytes.Length -eq 0 -or $Bytes.Length -gt 256) { return $rejected }
    # Jede gueltige geschlossene Form hat nur ASCII-UTF8: Namen, Version und
    # UUID sind ASCII, JSONwhitespace ebenfalls. Unicode-Escapes bleiben erlaubt.
    # Alle anderen Bytes (auch BOM/defektes UTF8) sind vor Decodierung ungueltig.
    foreach ($byte in $Bytes) { if ($byte -gt 127) { return $rejected } }
    $json = [Text.Encoding]::ASCII.GetString($Bytes)
    $space = '[ \t\r\n]*'
    $token = '"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"'
    # Geschlossene JSONgrammatik statt verlustbehafteter Objektprojektion.
    # Disjunkte Tokenalternativen und die 256-Bytegrenze begrenzen die Arbeit.
    $pattern = '\A' + $space + '\{' + $space + '(?<k1>' + $token + ')' + $space + ':' + $space +
        '(?<v1>' + $token + ')' + $space + ',' + $space + '(?<k2>' + $token + ')' + $space + ':' +
        $space + '(?<v2>' + $token + ')' + $space + '\}' + $space + '\z'
    $match = [regex]::Match($json, $pattern)
    if (-not $match.Success) { return $rejected }

    $decoded = @{}
    foreach ($group in @('k1', 'v1', 'k2', 'v2')) {
        $text = $match.Groups[$group].Value
        $builder = [Text.StringBuilder]::new()
        for ($index = 1; $index -lt $text.Length - 1; $index++) {
            $character = $text[$index]
            if ($character -eq '\') {
                $index++
                switch -CaseSensitive ($text[$index]) {
                    'u' { $character = [char][Convert]::ToInt32($text.Substring($index + 1, 4), 16); $index += 4 }
                    'b' { $character = [char]8 }
                    'f' { $character = [char]12 }
                    'n' { $character = [char]10 }
                    'r' { $character = [char]13 }
                    't' { $character = [char]9 }
                    default { $character = $text[$index] }
                }
            }
            [void]$builder.Append($character)
        }
        $decoded[$group] = $builder.ToString()
    }
    if ([string]::Equals($decoded.k1, 'ContractVersion', [StringComparison]::Ordinal) -and
        [string]::Equals($decoded.k2, 'HandleId', [StringComparison]::Ordinal)) {
        $version = $decoded.v1; $handleId = $decoded.v2
    }
    elseif ([string]::Equals($decoded.k2, 'ContractVersion', [StringComparison]::Ordinal) -and
        [string]::Equals($decoded.k1, 'HandleId', [StringComparison]::Ordinal)) {
        $version = $decoded.v2; $handleId = $decoded.v1
    }
    else { return $rejected } # Auch nach Decodierung doppelte/abweichende Namen.
    if (-not [string]::Equals($version, '1.0', [StringComparison]::Ordinal) -or -not (Test-FixtureHandleId $handleId)) { return $rejected }
    return [pscustomobject]@{
        Success = $true
        Value = [pscustomobject][ordered]@{ ContractVersion = $version; HandleId = $handleId }
        ErrorCode = $null
    }
}

function ConvertTo-FixtureHandleBytes {
    [CmdletBinding()]
    param([object]$Handle)

    $rejected = [pscustomobject]@{ Success = $false; Value = $null; ErrorCode = 'FIXTURE_HANDLE_INVALID' }
    # Kein Parameter-Downcast, Hashtable-Coercion oder Ausfuehren von Gettern.
    if ($null -eq $Handle -or [object].GetMethod('GetType').Invoke($Handle.PSObject.BaseObject, $null) -ne [Management.Automation.PSCustomObject]) { return $rejected }
    $propertyCount = 0
    $version = $null; $handleId = $null
    foreach ($property in $Handle.PSObject.Properties) {
        $propertyCount++
        if ($propertyCount -gt 2) { return $rejected }
        if ($property.GetType() -ne [Management.Automation.PSNoteProperty] -or $property.Value -isnot [string]) { return $rejected }
        if ([string]::Equals($property.Name, 'ContractVersion', [StringComparison]::Ordinal)) { $version = $property.Value }
        elseif ([string]::Equals($property.Name, 'HandleId', [StringComparison]::Ordinal)) { $handleId = $property.Value }
        else { return $rejected }
    }
    if ($propertyCount -ne 2 -or -not [string]::Equals($version, '1.0', [StringComparison]::Ordinal) -or
        -not (Test-FixtureHandleId $handleId)) { return $rejected }
    $json = '{"ContractVersion":"1.0","HandleId":"' + $handleId + '"}'
    return [pscustomobject]@{ Success = $true; Value = [Text.Encoding]::UTF8.GetBytes($json); ErrorCode = $null }
}
