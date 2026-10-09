# Typisierter Manifest-Zulassungsvertrag; kein Provider-Aufrufer.
function ConvertTo-LabSmtpTestServiceConfig {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) { return $null }
    $values = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $allowed = @('enabled','id','senderInstanceIds','maxStoredMessages','maxStoredBytes','maxMessageMiB','acceptedMessagesPerUtc60Seconds','MemoryMiB','CPUs')
    if ($InputObject -is [Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ($key -isnot [string] -or -not $seen.Add($key) -or $key -cnotin $allowed) { throw 'SMTP_TEST_CONFIG_INVALID' }
            $values.Add($key, $InputObject[$key])
        }
    }
    elseif ($InputObject -is [pscustomobject]) {
        foreach ($property in $InputObject.PSObject.Properties) {
            if ($property.MemberType -ne [Management.Automation.PSMemberTypes]::NoteProperty -or
                -not $seen.Add($property.Name) -or $property.Name -cnotin $allowed) { throw 'SMTP_TEST_CONFIG_INVALID' }
            $values.Add($property.Name, $property.Value)
        }
    }
    else { throw 'SMTP_TEST_CONFIG_INVALID' }

    $defaults = [ordered]@{ enabled=$true; id='smtp'; senderInstanceIds=@('primary'); maxStoredMessages=1000; maxStoredBytes=268435456L; maxMessageMiB=1; acceptedMessagesPerUtc60Seconds=120; MemoryMiB=256; CPUs=0.5 }
    foreach ($key in $values.Keys) { $defaults[$key] = $values[$key] }
    if ($defaults.enabled -isnot [bool]) { throw 'SMTP_TEST_CONFIG_INVALID' }
    if (-not $defaults.enabled) {
        if ($values.Count -ne 1) { throw 'SMTP_TEST_CONFIG_INVALID' }
        return $null
    }
    if ($defaults.id -isnot [string] -or $defaults.id -cnotmatch '^[a-z][a-z0-9-]{0,31}$') { throw 'SMTP_TEST_CONFIG_INVALID' }
    $senders = $defaults.senderInstanceIds
    if ($senders -isnot [array] -or $senders.Count -lt 1 -or $senders.Count -gt 64) { throw 'SMTP_TEST_CONFIG_INVALID' }
    $senderSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($sender in $senders) {
        if ($sender -isnot [string] -or $sender -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or -not $senderSet.Add($sender)) { throw 'SMTP_TEST_CONFIG_INVALID' }
    }
    $ranges = @{ maxStoredMessages=@(1L,100000L); maxStoredBytes=@(1048576L,4294967296L); maxMessageMiB=@(1L,64L); acceptedMessagesPerUtc60Seconds=@(1L,100000L); MemoryMiB=@(64L,4096L) }
    foreach ($key in $ranges.Keys) {
        $value = $defaults[$key]
        if (($value -isnot [byte] -and $value -isnot [sbyte] -and $value -isnot [int16] -and $value -isnot [uint16] -and
             $value -isnot [int32] -and $value -isnot [uint32] -and $value -isnot [int64] -and $value -isnot [uint64]) -or
            $value -lt $ranges[$key][0] -or $value -gt $ranges[$key][1]) { throw 'SMTP_TEST_CONFIG_INVALID' }
        $defaults[$key] = [long]$value
    }
    $cpu = $defaults.CPUs
    if (($cpu -isnot [double] -and $cpu -isnot [single] -and $cpu -isnot [decimal] -and $cpu -isnot [byte] -and $cpu -isnot [sbyte] -and
         $cpu -isnot [int16] -and $cpu -isnot [uint16] -and $cpu -isnot [int32] -and $cpu -isnot [uint32] -and $cpu -isnot [int64] -and $cpu -isnot [uint64]) -or
        [double]::IsNaN([double]$cpu) -or [double]::IsInfinity([double]$cpu) -or $cpu -lt 0.1 -or $cpu -gt 8) { throw 'SMTP_TEST_CONFIG_INVALID' }
    $defaults.CPUs = [double]$cpu
    $defaults.senderInstanceIds = [string[]]@($senders)
    # DATA- und logische Speichergrenze bleiben unabhängig.
    $defaults.maxMessageBytes = $defaults.maxMessageMiB * 1048576L
    return [pscustomobject]$defaults
}

function ConvertFrom-LabSmtpTestServiceJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json)
    $document = $null
    try {
        if ([Text.Encoding]::UTF8.GetByteCount($Json) -gt 16384) { throw 'SMTP_TEST_CONFIG_INVALID' }
        $document = [Text.Json.JsonDocument]::Parse($Json)
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'SMTP_TEST_CONFIG_INVALID' }
        $visit = {
            param([Text.Json.JsonElement]$Element)
            if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $Element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) { throw 'SMTP_TEST_CONFIG_INVALID' }
                    & $visit $property.Value
                }
            }
            elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($elementValue in $Element.EnumerateArray()) { & $visit $elementValue }
            }
        }
        & $visit $document.RootElement
        return ConvertTo-LabSmtpTestServiceConfig ($Json | ConvertFrom-Json -AsHashtable -Depth 64)
    }
    catch { throw 'SMTP_TEST_CONFIG_INVALID' }
    finally { if ($document) { $document.Dispose() } }
}
