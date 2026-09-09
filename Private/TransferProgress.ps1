# Streaming-Primitiven fuer bereits vom Aufrufer gebundene Dateipfade.
# Die Aufrufer behalten Ownership-, Journal-, Hash- und Recovery-Verantwortung.
function Copy-LabProgressStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IO.Stream]$Source,
        [Parameter(Mandatory)][IO.Stream]$Destination,
        [Parameter(Mandatory)][object]$Progress,
        [ValidateRange(0,[long]::MaxValue)][long]$Length = 0,
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 3600
    )
    $cancellation = [Threading.CancellationTokenSource]::new([timespan]::FromSeconds($TimeoutSeconds))
    try {
        $buffer = [byte[]]::new(1048576)
        $completed = 0L
        while ($true) {
            $count = Wait-LabProgressTask -Task ($Source.ReadAsync($buffer,0,$buffer.Length,$cancellation.Token)) -Progress $Progress -CompletedBytes $completed -TotalBytes $Length
            if ($count -eq 0) { break }
            $null = Wait-LabProgressTask -Task ($Destination.WriteAsync($buffer,0,$count,$cancellation.Token)) -Progress $Progress -CompletedBytes $completed -TotalBytes $Length
            $completed += $count
            Update-LabActionProgress -Progress $Progress -CompletedBytes $completed -TotalBytes $Length
        }
        if ($Length -gt 0 -and $completed -ne $Length) { throw 'LAB_TRANSFER_LENGTH_MISMATCH' }
    }
    finally { $cancellation.Cancel(); $cancellation.Dispose() }
}

function Copy-LabProgressFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Force
    )
    $sourcePath = [IO.Path]::GetFullPath($LiteralPath)
    $targetPath = [IO.Path]::GetFullPath($Destination)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ([string]::Equals($sourcePath,$targetPath,$comparison)) { throw 'LAB_TRANSFER_SAME_FILE' }
    if (-not $Force -and [IO.File]::Exists($targetPath)) { throw 'LAB_TRANSFER_TARGET_EXISTS' }
    $sourceInfo = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
    if ($sourceInfo.PSIsContainer -or ($sourceInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'LAB_TRANSFER_SOURCE_INVALID' }
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($targetPath)) ('.sql-lab-copy-' + [guid]::NewGuid().ToString('N'))
    $progress = Start-LabActionProgress -Phase Copy
    $inputStream = $null; $outputStream = $null; $temporaryCreated = $false
    try {
        $inputStream = [IO.File]::Open($sourcePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $outputStream = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $temporaryCreated = $true
        Copy-LabProgressStream -Source $inputStream -Destination $outputStream -Progress $progress -Length $inputStream.Length
        $outputStream.Flush($true)
        $outputStream.Dispose(); $outputStream = $null
        [IO.File]::SetLastWriteTimeUtc($temporary,$sourceInfo.LastWriteTimeUtc)
        # Atomare Ersetzung schuetzt vorhandene Ziele und Hardlinks vor
        # Teilkopien. Schreibgeschuetzte Ziele bleiben durch das OS geschuetzt.
        [IO.File]::Move($temporary,$targetPath,[bool]$Force)
        $temporaryCreated = $false
        [IO.File]::SetAttributes($targetPath,$sourceInfo.Attributes)
    }
    finally {
        try {
            if ($outputStream) { $outputStream.Dispose() }
            if ($inputStream) { $inputStream.Dispose() }
            if ($temporaryCreated -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
        finally { Stop-LabActionProgress -Progress $progress }
    }
}

function Get-LabProgressFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Alias('Path')][string]$LiteralPath,
        [ValidateSet('SHA256')][string]$Algorithm = 'SHA256'
    )
    $resolved = [IO.Path]::GetFullPath($LiteralPath)
    $progress = Start-LabActionProgress -Phase Hash
    $stream = $null
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $cancellation = [Threading.CancellationTokenSource]::new([timespan]::FromHours(1))
    try {
        $stream = [IO.File]::Open($resolved,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $buffer = [byte[]]::new(1048576); $completed = 0L
        while ($true) {
            $count = Wait-LabProgressTask -Task ($stream.ReadAsync($buffer,0,$buffer.Length,$cancellation.Token)) -Progress $progress -CompletedBytes $completed -TotalBytes $stream.Length
            if ($count -eq 0) { break }
            $hash.AppendData($buffer,0,$count)
            $completed += $count
            Update-LabActionProgress -Progress $progress -CompletedBytes $completed -TotalBytes $stream.Length
        }
        [pscustomobject]@{ Algorithm=$Algorithm; Hash=[Convert]::ToHexString($hash.GetHashAndReset()); Path=$resolved }
    }
    finally {
        try { $cancellation.Cancel(); $cancellation.Dispose(); if ($stream) { $stream.Dispose() }; $hash.Dispose() }
        finally { Stop-LabActionProgress -Progress $progress }
    }
}
