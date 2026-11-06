# Closed metadata for one Linux child of an existing Windows-controlled run.
# Parsing never registers a client, observes a provider, or grants qualification.
function Assert-LabTlsLinuxRecordFields {
    param([object]$Value, [string[]]$Names)
    if ($Value -isnot [pscustomobject]) { throw 'TLS_LINUX_CONTEXT_RECORD_INVALID' }
    $properties = @($Value.PSObject.Properties)
    if ($properties.Count -ne $Names.Count) { throw 'TLS_LINUX_CONTEXT_RECORD_INVALID' }
    foreach ($p in $properties) {
        if ($p.Name -cnotin $Names) { throw 'TLS_LINUX_CONTEXT_RECORD_INVALID' }
    }
}

function Assert-LabTlsLinuxRecordInteger {
    param([object]$Value, [long]$Minimum, [long]$Maximum = [long]::MaxValue)
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt $Minimum -or $Value -gt $Maximum) {
        throw 'TLS_LINUX_CONTEXT_RECORD_INVALID'
    }
}

function Assert-LabTlsLinuxRecordTime {
    param([object]$Value)
    # Keep the exact native RFC3339 spelling, including Podman UTC offsets.
    # It is later compared to fresh native text, not reformatted after parsing.
    if ($Value -isnot [string] -or
        $Value -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z') {
        throw 'TLS_LINUX_CONTEXT_RECORD_INVALID'
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$parsed)) { throw 'TLS_LINUX_CONTEXT_RECORD_INVALID' }
}

function Read-LabTlsLinuxClientContextRecord {
    param([byte[]]$Bytes)
    try {
        $r = Read-LabTlsBoundJson $Bytes @(
            'ContractVersion','ClientRef','Generation','Status','Parent','Client',
            'Endpoint','Trust','Binaries','CreatedAtUtc'
        )
        foreach ($name in @('ContractVersion','ClientRef','Status')) {
            if ($r.$name -isnot [string]) { throw 'INVALID' }
        }
        if ($r.ContractVersion -cne 'SqlServerLab.AuthenticatedTlsLinuxClient/0.1' -or
            $r.Status -cne 'REGISTERED_NOT_QUALIFIED' -or
            -not (Test-LabTlsRequestReference $r.ClientRef)) { throw 'INVALID' }
        Assert-LabTlsLinuxRecordInteger $r.Generation 1 ([int]::MaxValue)
        Assert-LabTlsLinuxRecordTime $r.CreatedAtUtc
        $parent = $r.Parent
        Assert-LabTlsLinuxRecordFields $parent @(
            'AuditId','ControllerId','LocationId','AuthorityRef','ParentControllerClientRef',
            'RegistrySha256','RuntimeBindingSha256','RunId','ScopeId','InstanceId',
            'Provider','SqlContainerId','SqlImageId','SqlStartedAt'
        )
        foreach ($name in @('AuditId','ControllerId','LocationId','AuthorityRef','ParentControllerClientRef','RunId','ScopeId')) {
            if ($parent.$name -isnot [string] -or -not (Test-LabTlsRequestReference $parent.$name)) { throw 'INVALID' }
        }
        if ($parent.ParentControllerClientRef -ceq $r.ClientRef -or
            $parent.InstanceId -isnot [string] -or $parent.InstanceId -cne 'primary' -or $parent.Provider -isnot [string] -or
            $parent.Provider -cnotin @('docker','podman')) { throw 'INVALID' }
        foreach ($name in @('RegistrySha256','RuntimeBindingSha256','SqlContainerId')) {
            if ($parent.$name -isnot [string] -or $parent.$name -cnotmatch '\A[0-9a-f]{64}\z') { throw 'INVALID' }
        }
        if ($parent.SqlImageId -isnot [string] -or $parent.SqlImageId -cnotmatch '\Asha256:[0-9a-f]{64}\z') { throw 'INVALID' }
        Assert-LabTlsLinuxRecordTime $parent.SqlStartedAt
        $client = $r.Client
        Assert-LabTlsLinuxRecordFields $client @(
            'ContainerId','ImageId','StartedAt','IntentId','Uid','Gid',
            'NetworkMode','NetNamespace','ReadOnlyRoot','NoNewPrivileges','Capabilities'
        )
        if ($client.ContainerId -isnot [string] -or $client.ContainerId -cnotmatch '\A[0-9a-f]{64}\z' -or
            $client.ContainerId -ceq $parent.SqlContainerId -or
            $client.ImageId -isnot [string] -or $client.ImageId -cnotmatch '\Asha256:[0-9a-f]{64}\z' -or
            $client.IntentId -isnot [string] -or -not (Test-LabTlsRequestReference $client.IntentId)) { throw 'INVALID' }
        Assert-LabTlsLinuxRecordTime $client.StartedAt
        Assert-LabTlsLinuxRecordInteger $client.Uid 10001 10001
        Assert-LabTlsLinuxRecordInteger $client.Gid 0 0
        if ($client.NetworkMode -isnot [string] -or $client.NetworkMode -cne ('container:' + $parent.SqlContainerId) -or
            $client.NetNamespace -isnot [string] -or $client.NetNamespace -cnotmatch '\Anet:\[[1-9][0-9]{0,19}\]\z' -or
            $client.ReadOnlyRoot -isnot [bool] -or $client.ReadOnlyRoot -ne $true -or
            $client.NoNewPrivileges -isnot [bool] -or $client.NoNewPrivileges -ne $true -or
            $client.Capabilities -isnot [string] -or $client.Capabilities -cne 'NONE') { throw 'INVALID' }
        Assert-LabTlsLinuxRecordFields $r.Endpoint @('Kind','Host','Port','Namespace')
        if ($r.Endpoint.Kind -isnot [string] -or $r.Endpoint.Kind -cne 'DNS' -or
            $r.Endpoint.Host -isnot [string] -or $r.Endpoint.Host -cne 'localhost' -or
            $r.Endpoint.Namespace -isnot [string] -or $r.Endpoint.Namespace -cne $client.NetNamespace) { throw 'INVALID' }
        Assert-LabTlsLinuxRecordInteger $r.Endpoint.Port 1433 1433
        Assert-LabTlsLinuxRecordFields $r.Trust @(
            'Store','Path','CertificateSha256','FileSha256','Bytes','Uid','Mode','FileSystem','Device','Inode','ParentUid','ParentMode',
            'Home','Directory','DirectoryUid','DirectoryMode','DirectoryDevice','DirectoryInode','DirectoryEmpty','UserStoreAbsent'
        )
        foreach ($pair in @(
            @('Store','ISOLATED_CLIENT_CA_STORE'), @('Path','/opt/tls-client/ca.pem'),
            @('Mode','600'), @('FileSystem','tmpfs'), @('ParentMode','700'),
            @('Home','/opt/tls-client'), @('Directory','/opt/tls-client/empty'), @('DirectoryMode','700')
        )) {
            if ($r.Trust.($pair[0]) -isnot [string] -or $r.Trust.($pair[0]) -cne $pair[1]) { throw 'INVALID' }
        }
        foreach ($name in @('CertificateSha256','FileSha256')) {
            if ($r.Trust.$name -isnot [string] -or $r.Trust.$name -cnotmatch '\A[0-9a-f]{64}\z') { throw 'INVALID' }
        }
        Assert-LabTlsLinuxRecordInteger $r.Trust.Bytes 1 32768
        Assert-LabTlsLinuxRecordInteger $r.Trust.Uid 10001 10001
        Assert-LabTlsLinuxRecordInteger $r.Trust.ParentUid 10001 10001
        Assert-LabTlsLinuxRecordInteger $r.Trust.DirectoryUid 10001 10001
        foreach ($name in @('Device','Inode','DirectoryDevice','DirectoryInode')) { Assert-LabTlsLinuxRecordInteger $r.Trust.$name 1 }
        foreach ($name in @('DirectoryEmpty','UserStoreAbsent')) {
            if ($r.Trust.$name -isnot [bool] -or $r.Trust.$name -ne $true) { throw 'INVALID' }
        }
        Assert-LabTlsLinuxRecordFields $r.Binaries @('PowerShell','SqlClient','Sqlcmd','OdbcDriver')
        $paths = @{
            PowerShell = '\A/opt/tls-client/pwsh/pwsh\z'
            SqlClient = '\A/opt/tls-client/pwsh/System\.Data\.SqlClient\.dll\z'
            Sqlcmd = '\A/opt/mssql-tools18/bin/sqlcmd\z'
            OdbcDriver = '\A/opt/microsoft/msodbcsql18/lib64/libmsodbcsql-18\.[0-9]+(?:\.[0-9]+){0,2}\.so\.[0-9]+(?:\.[0-9]+){0,2}\z'
        }
        foreach ($name in @('PowerShell','SqlClient','Sqlcmd','OdbcDriver')) {
            $binary = $r.Binaries.$name
            Assert-LabTlsLinuxRecordFields $binary @('Path','Sha256','Bytes')
            if ($binary.Path -isnot [string] -or $binary.Path -cnotmatch $paths[$name] -or
                $binary.Sha256 -isnot [string] -or $binary.Sha256 -cnotmatch '\A[0-9a-f]{64}\z') { throw 'INVALID' }
            Assert-LabTlsLinuxRecordInteger $binary.Bytes 1 268435456
        }
        return [pscustomobject][ordered]@{
            ContractVersion = 'SqlServerLab.LinuxClientContextMetadata/0.1'
            Record = $r
            Bytes = [byte[]]$Bytes.Clone()
            Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
            Ready = $false
            BindingStatus = 'NOT_OBSERVED'
        }
    } catch { throw 'TLS_LINUX_CONTEXT_RECORD_INVALID' }
}
