# Der Aufrufer bindet Archiveintrag und Ziel bereits an den Sample-Vertrag.
# Keine Archivpfade werden hier eigenstaendig aufgeloest oder veroeffentlicht.
function Expand-LabProgressZipEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IO.Compression.ZipArchiveEntry]$Entry,
        [Parameter(Mandatory)][string]$Destination,
        [object]$Progress
    )
    $ownsProgress = $null -eq $Progress
    if ($ownsProgress) { $Progress = Start-LabActionProgress -Phase Extract }
    $source = $null; $target = $null; $created = $false; $complete = $false
    try {
        $source = $Entry.Open()
        $target = [IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $created = $true
        Copy-LabProgressStream -Source $source -Destination $target -Progress $progress -Length $Entry.Length
        $target.Flush($true)
        $target.Dispose(); $target = $null
        [IO.File]::SetLastWriteTimeUtc($Destination,$Entry.LastWriteTime.UtcDateTime)
        $complete = $true
    }
    finally {
        try {
            if ($target) { $target.Dispose() }
            if ($source) { $source.Dispose() }
            if ($created -and -not $complete) { [IO.File]::Delete($Destination) }
        }
        finally { if ($ownsProgress) { Stop-LabActionProgress -Progress $Progress } }
    }
}
