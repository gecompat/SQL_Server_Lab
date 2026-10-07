# Flüchtige Operatorbindung; keine fachliche Aktionsfreigabe oder Replaygarantie.
function Get-UiOperatorPlatformDecision {
    param([Parameter(Mandatory)][string]$Platform,[Parameter(Mandatory)][bool]$UnixModeAvailable)
    if ($Platform -ceq 'Windows' -or ($Platform -ceq 'Unix' -and $UnixModeAvailable)) {
        return [pscustomobject]@{ Allowed=$true; Code='UI_OPERATOR_PLATFORM_SUPPORTED' }
    }
    $code = if ($Platform -ceq 'Unix') { 'UI_OPERATOR_UNIX_MODE_UNAVAILABLE' } else { 'UI_OPERATOR_PLATFORM_UNSUPPORTED' }
    return [pscustomobject]@{ Allowed=$false; Code=$code }
}

function Get-UiOperatorHostDecision {
    # Auf .NET 6 den noch fehlenden Enumtyp niemals auflösen. Keine Mutation
    # und kein Credential entsteht, bevor alle atomaren Rechte-APIs existieren.
    $platform = if ($IsWindows) { 'Windows' } elseif ($IsLinux -or $IsMacOS) { 'Unix' } else { 'Other' }
    $available = $false
    if ($platform -ceq 'Unix') {
        $create = @([IO.Directory].GetMethods() | Where-Object {
            $_.Name -ceq 'CreateDirectory' -and $_.GetParameters().Count -eq 2 -and
            $_.GetParameters()[0].ParameterType.FullName -ceq 'System.String' -and
            $_.GetParameters()[1].ParameterType.FullName -ceq 'System.IO.UnixFileMode'
        })
        $get = @([IO.File].GetMethods() | Where-Object {
            $_.Name -ceq 'GetUnixFileMode' -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.FullName -ceq 'System.String'
        })
        $set = @([IO.File].GetMethods() | Where-Object {
            $_.Name -ceq 'SetUnixFileMode' -and $_.GetParameters().Count -eq 2 -and
            $_.GetParameters()[0].ParameterType.FullName -ceq 'System.String' -and
            $_.GetParameters()[1].ParameterType.FullName -ceq 'System.IO.UnixFileMode'
        })
        $available = $create.Count -eq 1 -and $get.Count -eq 1 -and $set.Count -eq 1
    }
    return Get-UiOperatorPlatformDecision -Platform $platform -UnixModeAvailable $available
}

function Assert-UiOperatorPlainPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while ($current) {
        if (-not [IO.Directory]::Exists($current) -and -not [IO.File]::Exists($current)) { throw 'UI_OPERATOR_PATH_INVALID' }
        if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'UI_OPERATOR_PATH_INVALID' }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
    return $full
}

function Test-UiOperatorDirectoryProtection {
    param([Parameter(Mandatory)][string]$Path)
    $null = Assert-UiOperatorPlainPath $Path
    if ($IsWindows) {
        $acl = Get-Acl -LiteralPath $Path
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $rules = @($acl.Access)
        return $acl.AreAccessRulesProtected -and $acl.Owner -and
            $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ceq $sid -and $rules.Count -eq 1 -and
            $rules[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ceq $sid -and
            $rules[0].AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            (($rules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl)
    }
    if ($IsLinux -or $IsMacOS) {
        return [IO.File]::GetUnixFileMode($Path) -eq ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    }
    return $false
}

function New-UiOperatorSession {
    param([Parameter(Mandatory)][string]$ListenerUrl)
    $platformDecision = Get-UiOperatorHostDecision
    if (-not $platformDecision.Allowed) { throw $platformDecision.Code }
    $listener = $null
    if (-not [uri]::TryCreate($ListenerUrl,[UriKind]::Absolute,[ref]$listener) -or
        $listener.Scheme -cne 'http' -or $listener.Host -cne '127.0.0.1' -or $listener.Port -lt 1025 -or
        $listener.AbsolutePath -cne '/' -or $listener.UserInfo -or $listener.Query -or $listener.Fragment) { throw 'UI_OPERATOR_LISTENER_INVALID' }
    $parent = Assert-UiOperatorPlainPath ([IO.Path]::GetTempPath())
    $directory = Join-Path $parent ('sql-lab-ui-' + [guid]::NewGuid().ToString('N'))
    $file = Join-Path $directory 'operator.json'
    $stream = $null; $secretBytes = [byte[]]::new(32); $payloadBytes = $null
    try {
        if (Test-Path -LiteralPath $directory) { throw 'UI_OPERATOR_PATH_EXISTS' }
        # Rechte bereits bei Verzeichnisanlage setzen, bevor Credentialbytes entstehen.
        if ($IsWindows) {
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner($sid); $acl.SetAccessRuleProtection($true,$false)
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
            [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($directory),$acl)
        } elseif ($IsLinux -or $IsMacOS) {
            $null = [IO.Directory]::CreateDirectory($directory,([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute))
        } else { throw 'UI_OPERATOR_PLATFORM_UNSUPPORTED' }
        if (-not (Test-UiOperatorDirectoryProtection $directory)) { throw 'UI_OPERATOR_PROTECTION_INVALID' }
        [Security.Cryptography.RandomNumberGenerator]::Fill($secretBytes)
        $capability = [Convert]::ToHexString($secretBytes).ToLowerInvariant()
        $startUrl = $ListenerUrl + '#sql-lab-operator=' + $capability
        $payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes((@{ ContractVersion='SqlServerLab.UiOperator/1.0'; ListenerUrl=$ListenerUrl; StartUrl=$startUrl; Capability=$capability } | ConvertTo-Json -Compress))
        $stream = [IO.FileStream]::new($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
        if ($IsLinux -or $IsMacOS) { [IO.File]::SetUnixFileMode($file,([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)) }
        $null = Assert-UiOperatorPlainPath $file
        if (-not (Test-UiOperatorDirectoryProtection $directory)) { throw 'UI_OPERATOR_PROTECTION_INVALID' }
        $stream.Write($payloadBytes,0,$payloadBytes.Length); $stream.Flush($true)
        # Normale lokale Reader teilen nur Read. Nach dem CreateNew-Write halten
        # wir deshalb selbst einen Read-Handle ohne Write-/Delete-Sharing.
        $stream.Dispose()
        $stream = [IO.FileStream]::new($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        return [pscustomobject]@{ ListenerUrl=$ListenerUrl; Capability=$capability; StartUrl=$startUrl; Directory=$directory; File=$file; Stream=$stream; PayloadLength=$payloadBytes.Length; PayloadSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payloadBytes)); Active=$true }
    } catch {
        if ($stream) { $stream.Dispose() }
        # Keine unbestätigte Ressource löschen. Lokaler Pfad ist kein Credentialwert.
        Write-Warning ('UI_OPERATOR_HANDOFF_UNCONFIRMED: privaten Startscope lokal prüfen: ' + $directory)
        throw 'UI_OPERATOR_HANDOFF_UNCONFIRMED'
    } finally {
        [Array]::Clear($secretBytes,0,$secretBytes.Length)
        if ($payloadBytes) { [Array]::Clear($payloadBytes,0,$payloadBytes.Length) }
    }
}

function Get-UiOperatorDecision {
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][string]$ListenerUrl,[Parameter(Mandatory)]$Session)
    $result = [pscustomobject]@{ Allowed=$false; StatusCode=403; Code='UI_OPERATOR_REQUIRED' }
    if ($Request.Url -isnot [uri] -or $Request.Headers -isnot [Collections.Specialized.NameValueCollection]) { return $result }
    # Statische Produktassets enthalten keine Capability und bleiben öffentlich.
    if (-not $Request.Url.AbsolutePath.StartsWith('/api/',[StringComparison]::OrdinalIgnoreCase) -and
        -not $Request.Url.AbsolutePath.Equals('/api',[StringComparison]::OrdinalIgnoreCase)) {
        $result.Allowed=$true; $result.StatusCode=200; $result.Code='UI_OPERATOR_STATIC'; return $result
    }
    if ($null -eq $Session -or -not $Session.Active -or $Session.ListenerUrl -cne $ListenerUrl -or
        $Request.Url.GetLeftPart([UriPartial]::Authority) -cne $ListenerUrl.TrimEnd('/') -or
        $Session.Capability -isnot [string] -or $Session.Capability -cnotmatch '^[a-f0-9]{64}$') { return $result }
    $values = $Request.Headers.GetValues('X-SqlServerLab-Operator')
    if ($null -eq $values -or $values.Count -ne 1 -or $values[0] -isnot [string] -or $values[0] -cnotmatch '^[a-f0-9]{64}$') { return $result }
    $provided=[Text.Encoding]::ASCII.GetBytes($values[0]); $expected=[Text.Encoding]::ASCII.GetBytes($Session.Capability)
    try { $matches = [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($provided,$expected) }
    finally { [Array]::Clear($provided,0,$provided.Length); [Array]::Clear($expected,0,$expected.Length) }
    if ($matches) { $result.Allowed=$true; $result.StatusCode=200; $result.Code='UI_OPERATOR_AUTHENTICATED' }
    return $result
}

function Close-UiOperatorSession {
    param([Parameter(Mandatory)]$Session)
    $Session.Active=$false; $Session.Capability=$null; $Session.StartUrl=$null
    try {
        if ($Session.Stream) { $Session.Stream.Dispose(); $Session.Stream=$null }
        $null = Assert-UiOperatorPlainPath $Session.File
        # Maximal zwei Einträge lesen; kein ungebundenes Temp-Inventar.
        $entries=[IO.Directory]::EnumerateFileSystemEntries($Session.Directory).GetEnumerator()
        try { $singleEntry=$entries.MoveNext() -and -not $entries.MoveNext() }
        finally { $entries.Dispose() }
        if (-not (Test-UiOperatorDirectoryProtection $Session.Directory) -or
            [IO.Path]::GetDirectoryName($Session.File) -cne $Session.Directory -or
            [IO.Path]::GetFileName($Session.File) -cne 'operator.json' -or
            [IO.Path]::GetFileName($Session.Directory) -cnotmatch '^sql-lab-ui-[a-f0-9]{32}$' -or
            -not $singleEntry -or
            $Session.PayloadLength -gt 4096 -or ([IO.FileInfo]::new($Session.File)).Length -ne $Session.PayloadLength) { throw 'UI_OPERATOR_CLEANUP_INVALID' }
        $bytes=[IO.File]::ReadAllBytes($Session.File)
        try { if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $Session.PayloadSha256) { throw 'UI_OPERATOR_CLEANUP_CHANGED' } }
        finally { [Array]::Clear($bytes,0,$bytes.Length) }
        [IO.File]::Delete($Session.File)
        [IO.Directory]::Delete($Session.Directory,$false)
        return $true
    } catch {
        Write-Warning ('UI_OPERATOR_CLEANUP_UNCONFIRMED: privaten Startscope lokal erhalten: ' + $Session.Directory)
        return $false
    }
}
