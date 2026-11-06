#Requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsRequest.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsRegistryIndex.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsLab.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsLinuxContextRecord.ps1')
$passed = 0
$failures = [Collections.Generic.List[string]]::new()
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Add-CheckResult $Name $true }
    catch { Add-CheckResult $Name $false ($_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function New-Record {
    $id = '11111111-1111-1111-1111-111111111111'
    $other = '22222222-2222-2222-2222-222222222222'
    $time = '2026-10-26T03:00:00.123456789Z'
    [ordered]@{
        ContractVersion='SqlServerLab.AuthenticatedTlsLinuxClient/0.1';ClientRef=$id
        Generation=1;Status='REGISTERED_NOT_QUALIFIED';CreatedAtUtc=$time
        Parent=[ordered]@{
            AuditId=$id;ControllerId=$id;LocationId=$id;AuthorityRef=$id;ParentControllerClientRef=$other
            RegistrySha256=('a'*64);RuntimeBindingSha256=('b'*64);RunId=$id;ScopeId=$id;InstanceId='primary'
            Provider='docker';SqlContainerId=('c'*64);SqlImageId=('sha256:'+('d'*64));SqlStartedAt=$time
        }
        Client=[ordered]@{
            ContainerId=('e'*64);ImageId=('sha256:'+('d'*64));StartedAt=$time;IntentId=$id
            Uid=10001;Gid=0;NetworkMode=('container:'+('c'*64));NetNamespace='net:[4026533333]'
            ReadOnlyRoot=$true;NoNewPrivileges=$true;Capabilities='NONE'
        }
        Endpoint=[ordered]@{Kind='DNS';Host='localhost';Port=1433;Namespace='net:[4026533333]'}
        Trust=[ordered]@{
            Store='ISOLATED_CLIENT_CA_STORE';Path='/opt/tls-client/ca.pem';CertificateSha256=('f'*64);FileSha256=('e'*64)
            Bytes=1600;Uid=10001;Mode='600';FileSystem='tmpfs';Device=47;Inode=8;ParentUid=10001;ParentMode='700'
            Home='/opt/tls-client';Directory='/opt/tls-client/empty';DirectoryUid=10001;DirectoryMode='700'
            DirectoryDevice=47;DirectoryInode=9;DirectoryEmpty=$true;UserStoreAbsent=$true
        }
        Binaries=[ordered]@{
            PowerShell=[ordered]@{Path='/opt/tls-client/pwsh/pwsh';Sha256=('a'*64);Bytes=64000}
            SqlClient=[ordered]@{Path='/opt/tls-client/pwsh/System.Data.SqlClient.dll';Sha256=('b'*64);Bytes=1234567}
            Sqlcmd=[ordered]@{Path='/opt/mssql-tools18/bin/sqlcmd';Sha256=('c'*64);Bytes=100000}
            OdbcDriver=[ordered]@{Path='/opt/microsoft/msodbcsql18/lib64/libmsodbcsql-18.6.so.1.1';Sha256=('d'*64);Bytes=10000000}
        }
    }
}
function To-Bytes($Value) { [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 12 -Compress)) }
function Reject($Value) {
    $rejected = $false
    try { $null = Read-LabTlsLinuxClientContextRecord (To-Bytes $Value) }
    catch { $rejected = $_.Exception.Message -ceq 'TLS_LINUX_CONTEXT_RECORD_INVALID' }
    Assert $rejected 'Expected closed metadata rejection'
}
function Get-Parent($Record, [string]$Path) {
    $parts = $Path.Split('.')
    $target = $Record
    for ($i = 0; $i -lt $parts.Length - 1; $i++) { $target = $target[$parts[$i]] }
    return ,$target
}
function Get-Leaves($Record, [string]$Prefix = '') {
    foreach ($key in $Record.Keys) {
        $path = if ($Prefix) { $Prefix + '.' + $key } else { $key }
        if ($Record[$key] -is [Collections.IDictionary]) { Get-Leaves $Record[$key] $path }
        else { [pscustomobject]@{Path=$path;Value=$Record[$key]} }
    }
}
foreach ($provider in @('docker','podman')) {
    Check ("Metadata accepts $provider exact typed topology, without qualification") {
        $r = New-Record
        $r.Parent.Provider = $provider
        if ($provider -ceq 'podman') { $r.Client.StartedAt = '2026-10-26T04:00:00.1234567+01:00' }
        $bytes = To-Bytes $r
        $result = Read-LabTlsLinuxClientContextRecord $bytes
        Assert (-not $result.Ready -and $result.BindingStatus -ceq 'NOT_OBSERVED') 'Parser cannot claim live authority'
        Assert ($result.Record.Client.StartedAt -ceq $r.Client.StartedAt) 'Native RFC3339 text was rewritten'
        $first = $result.Bytes[0];$bytes[0] = 0
        Assert ($result.Bytes[0] -eq $first) 'Caller mutation reached metadata snapshot'
    }
}
foreach ($leaf in @(Get-Leaves (New-Record))) {
    if ($leaf.Value -is [string]) {
        foreach ($variant in @('empty','single','nested')) {
            Check ("Scalar metadata: $($leaf.Path)/$variant") {
                $r = New-Record
                $parent = Get-Parent $r $leaf.Path
                $name = $leaf.Path.Split('.')[-1]
                $bad = switch ($variant) {
                    empty { ,([object[]]::new(0)) }
                    single { ,([object[]]@($leaf.Value)) }
                    nested { ,([object[]]@(,([object[]]@($leaf.Value)))) }
                }
                $parent[$name] = $bad
                Reject $r
            }
        }
    } elseif ($leaf.Value -is [bool]) {
        foreach ($variant in @('integer','string','array')) {
            Check ("Boolean metadata: $($leaf.Path)/$variant") {
                $r = New-Record
                $parent = Get-Parent $r $leaf.Path
                $name = $leaf.Path.Split('.')[-1]
                $parent[$name] = switch ($variant) { integer { 1 }; string { 'true' }; array { ,([object[]]@($true)) } }
                Reject $r
            }
        }
    } elseif ($leaf.Value -is [int]) {
        foreach ($variant in @('bool','string','negative','fraction')) {
            Check ("Integer metadata: $($leaf.Path)/$variant") {
                $r = New-Record
                $parent = Get-Parent $r $leaf.Path
                $name = $leaf.Path.Split('.')[-1]
                $parent[$name] = switch ($variant) { bool { $true }; string { '1' }; negative { -1 }; fraction { 1.25 } }
                Reject $r
            }
        }
    }
}
foreach ($path in @('Parent','Client','Endpoint','Trust','Binaries','Binaries.PowerShell','Binaries.SqlClient','Binaries.Sqlcmd','Binaries.OdbcDriver')) {
    foreach ($variant in @('missing','extra','array')) {
        Check ("Closed object: $path/$variant") {
            $r = New-Record
            $parent = Get-Parent $r $path
            $name = $path.Split('.')[-1]
            switch ($variant) {
                missing { $parent.Remove($name) }
                extra { $parent[$name].Extra = 'forbidden' }
                array { $parent[$name] = [object[]]@($parent[$name]) }
            }
            Reject $r
        }
    }
}
foreach ($mode in @('parent-ref','sql-client-id','namespace-route','namespace-inode','host-endpoint','host-port','writable-root','privileges','capabilities','trust-path','trust-mode','trust-filesystem','trust-file-hash','trust-home','trust-directory','trust-extra-ca','trust-user-store','binary-path','binary-hash','invalid-date','unqualified-status')) {
    Check ("Metadata semantic boundary: $mode") {
        $r = New-Record
        switch ($mode) {
            parent-ref { $r.Parent.ParentControllerClientRef = $r.ClientRef }
            sql-client-id { $r.Client.ContainerId = $r.Parent.SqlContainerId }
            namespace-route { $r.Client.NetworkMode = 'host' }
            namespace-inode { $r.Endpoint.Namespace = 'net:[4026534444]' }
            host-endpoint { $r.Endpoint.Host = '127.0.0.1' }
            host-port { $r.Endpoint.Port = 21433 }
            writable-root { $r.Client.ReadOnlyRoot = $false }
            privileges { $r.Client.NoNewPrivileges = $false }
            capabilities { $r.Client.Capabilities = 'CAP_SYS_ADMIN' }
            trust-path { $r.Trust.Path = '/etc/ssl/certs/ca-certificates.crt' }
            trust-mode { $r.Trust.Mode = '644' }
            trust-filesystem { $r.Trust.FileSystem = 'ext4' }
            trust-file-hash { $r.Trust.FileSha256 = 'unbound' }
            trust-home { $r.Trust.Home = '/tmp' }
            trust-directory { $r.Trust.Directory = '/etc/ssl/certs' }
            trust-extra-ca { $r.Trust.DirectoryEmpty = $false }
            trust-user-store { $r.Trust.UserStoreAbsent = $false }
            binary-path { $r.Binaries.PowerShell.Path = '/tmp/pwsh' }
            binary-hash { $r.Binaries.SqlClient.Sha256 = 'bad' }
            invalid-date { $r.Client.StartedAt = '2026-99-99T00:00:00Z' }
            unqualified-status { $r.Status = 'QUALIFIED' }
        }
        Reject $r
    }
}
Check 'Duplicate nested metadata keys are rejected before projection' {
    $text = (New-Record) | ConvertTo-Json -Depth 12 -Compress
    $text = $text.Replace('"Host":"localhost"', '"Host":"localhost","host":"localhost"')
    $rejected = $false
    try { $null = Read-LabTlsLinuxClientContextRecord ([Text.Encoding]::UTF8.GetBytes($text)) }
    catch { $rejected = $_.Exception.Message -ceq 'TLS_LINUX_CONTEXT_RECORD_INVALID' }
    Assert $rejected 'Expected duplicate-case rejection'
}
[pscustomobject]@{Suite='AuthenticatedTlsLinuxContextRecord';Passed=$passed;Failed=$failures.Count;ProviderActions=0;SqlLogins=0} | ConvertTo-Json -Compress
if ($failures.Count) { throw 'TLS_LINUX_CONTEXT_RECORD_CHECKS_FAILED' }
