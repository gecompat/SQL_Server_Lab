# Begrenzte Transportlesung; keine JSON-Fachpruefung oder Operatorautoritaet.
function Read-UiJsonRequestBody {
    param(
        [Parameter(Mandatory)]$Request,
        [ValidateRange(1,1048576)][int]$MaxBytes = 1048576,
        [ValidateRange(50,5000)][int]$TimeoutMilliseconds = 5000,
        [switch]$IncludeBytes
    )
    $result = [pscustomobject]@{ Allowed = $false; StatusCode = 400; Code = 'UI_REQUEST_BODY_READ_FAILED'; Body = $null }
    if ($IncludeBytes) { $result | Add-Member -NotePropertyName BodyBytes -NotePropertyValue $null }
    $inputStream = $null; $memory = $null; $buffer = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $inputStream = $Request.InputStream
        if ($inputStream -isnot [IO.Stream] -or -not $inputStream.CanRead) { return $result }
        $lengthProperty = $Request.PSObject.Properties['ContentLength64']
        if ($lengthProperty -and $lengthProperty.Value -gt $MaxBytes) {
            $result.StatusCode = 413; $result.Code = 'UI_REQUEST_BODY_TOO_LARGE'; return $result
        }
        $memory = [IO.MemoryStream]::new(); $buffer = [byte[]]::new(4096)
        while ($true) {
            $remaining = $TimeoutMilliseconds - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { $result.StatusCode = 408; $result.Code = 'UI_REQUEST_BODY_TIMEOUT'; return $result }
            # Hoechstens ein Sentinelbyte ueber dem Limit lesen, nie puffern.
            $quota = [int][Math]::Min($buffer.Length, $MaxBytes - $memory.Length + 1)
            $pending = $inputStream.ReadAsync($buffer, 0, $quota)
            if (-not $pending.Wait($remaining)) { $result.StatusCode = 408; $result.Code = 'UI_REQUEST_BODY_TIMEOUT'; return $result }
            $count = $pending.GetAwaiter().GetResult()
            if ($count -eq 0) { break }
            if ($memory.Length + $count -gt $MaxBytes) { $result.StatusCode = 413; $result.Code = 'UI_REQUEST_BODY_TOO_LARGE'; return $result }
            $memory.Write($buffer, 0, $count)
        }
        $result.Body = [Text.UTF8Encoding]::new($false,$true).GetString($memory.GetBuffer(),0,[int]$memory.Length)
        if ($IncludeBytes) { $result.BodyBytes = $memory.ToArray() }
        $result.Allowed = $true; $result.StatusCode = 200; $result.Code = 'UI_REQUEST_BODY_READ'; return $result
    }
    catch [Text.DecoderFallbackException] { $result.Code = 'UI_REQUEST_BODY_UTF8_INVALID'; return $result }
    catch { return $result }
    finally {
        if (-not $result.Allowed -and $IncludeBytes -and $result.BodyBytes) { [Array]::Clear($result.BodyBytes,0,$result.BodyBytes.Length); $result.BodyBytes=$null }
        if (-not $result.Allowed -and $inputStream -is [IO.Stream]) { try { $inputStream.Dispose() } catch { } }
        if ($memory) { [Array]::Clear($memory.GetBuffer(),0,$memory.GetBuffer().Length); $memory.Dispose() }
        if ($buffer) { [Array]::Clear($buffer,0,$buffer.Length) }
        $clock.Stop()
    }
}

# Acht UI-interne Adapter behalten ihre engeren UTF-16-Zeichenlimits.
# Der Transport begrenzt zuerst Bytes und dieselbe absolute Fuenfsekundenfrist.
function Read-UiSpecializedJsonRequestBody {
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][ValidateSet(1024,4096,16384)][int]$MaxCharacters,
        [Parameter(Mandatory)][string]$LimitErrorCode
    )
    try {
        $read = Read-UiJsonRequestBody -Request $Request -MaxBytes ($MaxCharacters * 4)
        if (-not $read.Allowed) {
            $failure = [IO.InvalidDataException]::new($read.Code)
            $failure.Data['SqlServerLab.UiBodyStatus'] = $read.StatusCode
            throw $failure
        }
        # StreamReader entfernte eine fuehrende UTF-8-BOM vor der Zeichenzaehlung.
        $body = $read.Body
        if ($body.Length -gt 0 -and $body[0] -eq [char]0xfeff) { $body = $body.Substring(1) }
        if ($body.Length -gt $MaxCharacters) { throw $LimitErrorCode }
        return $body
    }
    finally {
        # Wie beim bisherigen StreamReader auch erfolgreiche Bodys schliessen.
        try { $Request.InputStream.Dispose() } catch { }
    }
}

function Write-UiBodyFailureResponse {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$ErrorRecord)
    $failure = $ErrorRecord.Exception
    if ($failure -isnot [IO.InvalidDataException]) { return $false }
    $expected = switch -CaseSensitive ($failure.Message) {
        'UI_REQUEST_BODY_TOO_LARGE' { 413 }
        'UI_REQUEST_BODY_TIMEOUT' { 408 }
        'UI_REQUEST_BODY_UTF8_INVALID' { 400 }
        'UI_REQUEST_BODY_READ_FAILED' { 400 }
        default { return $false }
    }
    if ($failure.Data['SqlServerLab.UiBodyStatus'] -ne $expected) { return $false }
    Write-UiResponse -Context $Context -Body $failure.Message -StatusCode $expected
    return $true
}
