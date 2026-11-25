function Get-LabSsmsRegistrationDownload {
    $catalog = Get-SqlServerLabConnectionCenter -StoredOnly
    if ($catalog.Entries.Count -gt 500) { throw 'SSMS_REGISTRATION_LIMIT_EXCEEDED' }
    $document = (New-LabSsmsRegistrationLines -ConnectionCenter $catalog) -join [Environment]::NewLine
    if ([Text.Encoding]::UTF8.GetByteCount($document) -gt 2097152) { throw 'SSMS_REGISTRATION_LIMIT_EXCEEDED' }
    return $document
}

function Get-LabStoredConnectionCenterBrowserView {
    $inventory = Get-SqlServerLabConnectionCenter -StoredOnly
    $entries = [Collections.Generic.List[object]]::new()
    $skipped = 0
    $limit = 200
    $more = $false
    foreach ($entry in $inventory.Entries) {
        $provider = [string]$entry.Provider
        $state = [string]$entry.RuntimeState
        $name = [string]$entry.DisplayName
        $server = [string]$entry.Server
        $port = [regex]::Match($server, ',([0-9]{1,5})\z')
        $portNumber = if ($port.Success) { [int]$port.Groups[1].Value } else { $null }
        # Only project an address, never the connection string or its options.
        if ($server.Length -gt 300 -or $server -cnotmatch '\A(?:tcp:)?(?:[A-Za-z0-9_.-]+|\[[0-9a-fA-F:]+\]|[0-9a-fA-F]*:[0-9a-fA-F:]+)(?:\\[A-Za-z0-9_.-]+)?(?:,[0-9]{1,5})?\z' -or
            ($port.Success -and ($portNumber -lt 1 -or $portNumber -gt 65535)) -or
            [string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 256 -or $name -match '[\x00-\x1f\x7f]' -or
            $provider -cnotin @('docker','podman','hyperv','unknown') -or $state -cnotin @('RUNNING','STOPPED','UNKNOWN')) {
            $skipped++
            continue
        }
        if ($entries.Count -ge $limit) {
            $more = $true
            continue
        }
        $entries.Add([pscustomobject]@{DisplayName=$name;Provider=$provider;Server=$server;StoredState=$state})
    }
    [pscustomobject]@{
        ContractVersion='SqlServerLab.StoredConnectionCenter/1.0'
        Entries=$entries.ToArray()
        SkippedCount=$skipped
        MoreAvailable=$more
    }
}
