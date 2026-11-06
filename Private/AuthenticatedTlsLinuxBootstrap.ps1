function Get-LabTlsLinuxPeerEntryProgram {
    return @'
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$bootLine=[Console]::In.ReadLine()
if($null-eq$bootLine-or$bootLine.Length-gt131072){throw 'BOOT'}
$boot=[Text.UTF8Encoding]::new($false,$true).GetString([Convert]::FromBase64String($bootLine))|ConvertFrom-Json -DateKind String
$bytes=[Convert]::FromBase64String($boot.ExportBase64)
$moduleFile=Join-Path $PSScriptRoot 'lab/SqlServerLab.LinuxPeer.psd1'
$module=Import-Module -Name $moduleFile -PassThru -ErrorAction Stop
$channel=@{
    State='OPEN';InFlight=$false;Requests=0;ProcessId=$PID
    ProcessStartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    Lifetime=[Diagnostics.Stopwatch]::StartNew();MaximumElapsed=[TimeSpan]::FromMilliseconds([long]$boot.MaximumMilliseconds)
    ControllerStateRoot=$boot.StateRoot;RunId=$boot.RunId;InstanceId=$boot.InstanceId
    ExportSha256=$boot.ExportSha256;ClientRef=$boot.ClientRef;ContextDigest=$boot.ContextDigest
    ExpiresAt=[DateTimeOffset]::ParseExact($boot.ExpiresAt,'o',[Globalization.CultureInfo]::InvariantCulture)
    Exchange={
        param([byte[]]$Request)
        [Console]::Out.WriteLine('VERIFY '+[Convert]::ToBase64String($Request));[Console]::Out.Flush()
        $reply=[Console]::In.ReadLine()
        if($null-eq$reply-or$reply.Length-gt4096-or-not$reply.StartsWith('REPLY ',[StringComparison]::Ordinal)){throw 'CHANNEL'}
        return ,[Convert]::FromBase64String($reply.Substring(6))
    }
}
& $module {param($Ref,$Channel)$script:SqlServerLabTlsLinuxPeerChannels=@{};$script:SqlServerLabTlsLinuxPeerChannels[$Ref]=$Channel} $boot.SessionRef $channel
$context=[pscustomobject]@{ModuleFile=$moduleFile;StateRoot=$boot.StateRoot;RunId=$boot.RunId;InstanceId=$boot.InstanceId
    LinuxSessionRef=$boot.SessionRef;LinuxClientRef=$boot.ClientRef;LinuxClientContextDigest=$boot.ContextDigest}
$hello=@{ContractVersion='SqlServerLab.LinuxPeerHello/0.1';SessionRef=$boot.SessionRef;ProcessId=$PID}
[Console]::Out.WriteLine('HELLO '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($hello|ConvertTo-Json -Compress))))
[Console]::Out.Flush()
try{
    $result=& (Join-Path $PSScriptRoot 'toolbelt/Tests/CI/Invoke-LabLinuxPreflight.ps1') -ExportBytes $bytes -TlsContext $context
    if($channel.Requests-ne2-or$channel.State-cne'OPEN'){throw 'PROTOCOL'}
    [Console]::Out.WriteLine('RESULT '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($result|ConvertTo-Json -Compress))))
    [Console]::Out.Flush()
}finally{
    $channel.State='CLOSED';[Array]::Clear($bytes,0,$bytes.Length)
    & $module {$script:SqlServerLabTlsLinuxPeerChannels.Clear()}
}
'@
}

function Get-LabTlsLinuxConsumerSourceSet {
    param([string]$ToolbeltRoot)
    $tb=Assert-LabDiagnosticPath ([IO.Path]::GetFullPath($ToolbeltRoot))
    $lab=$script:ModuleRoot
    # Caller-selected code, never selected by the export or an environment var.
    $sources=@(
        @($lab,'SqlServerLab.LinuxPeer.psd1','lab/SqlServerLab.LinuxPeer.psd1'),
        @($lab,'Private/AuthenticatedTlsLinuxPeerModule.psm1','lab/Private/AuthenticatedTlsLinuxPeerModule.psm1'),
        @($lab,'Private/AuthenticatedTlsRegistryIndex.ps1','lab/Private/AuthenticatedTlsRegistryIndex.ps1'),
        @($lab,'Private/AuthenticatedTlsLab.ps1','lab/Private/AuthenticatedTlsLab.ps1'),
        @($lab,'Private/AuthenticatedTlsLinuxPeer.ps1','lab/Private/AuthenticatedTlsLinuxPeer.ps1'),
        @($lab,'Public/Read-SqlServerLabQualifiedTestEnvironment.ps1','lab/Public/Read-SqlServerLabQualifiedTestEnvironment.ps1'),
        @($tb,'Tests/CI/LabLinuxQualifiedContract.ps1','toolbelt/Tests/CI/LabLinuxQualifiedContract.ps1'),
        @($tb,'Tests/CI/Invoke-LabLinuxPreflight.ps1','toolbelt/Tests/CI/Invoke-LabLinuxPreflight.ps1')
    )
    $held=[Collections.Generic.List[object]]::new();$total=0
    try{
        foreach($row in $sources){
            $path=Assert-LabDiagnosticPath ([IO.Path]::GetFullPath((Join-Path $row[0] $row[1])))
            if(-not$path.StartsWith(([IO.Path]::TrimEndingDirectorySeparator($row[0])+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)){throw 'TLS_LINUX_SOURCE_SCOPE_INVALID'}
            $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $entry=@{Path=$path;Relative=$row[2];Stream=$stream;Bytes=$stream.Length;Sha256=''}
            $held.Add($entry);$total+=$stream.Length
            if($stream.Length-lt1-or$stream.Length-gt1048576-or$total-gt2097152){throw 'TLS_LINUX_SOURCE_LIMIT'}
            $entry.Sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant();$stream.Position=0
        }
        return ,$held
    }catch{foreach($entry in $held){$entry.Stream.Dispose()};throw}
}

function Initialize-LabTlsLinuxConsumerFiles {
    param([object]$Bound,[object]$Budget,[object]$Client,[object]$SourceSet,[string]$Directory)
    if($Directory-cnotmatch'\A/opt/tls-client/session-[0-9a-f]{32}\z'){throw 'TLS_LINUX_SOURCE_SCOPE_INVALID'}
    $cid=$Client.Record.Client.ContainerId
    $mkdir="set -eu; umask 077; mkdir '$Directory'; mkdir -p '$Directory/lab/Private' '$Directory/lab/Public' '$Directory/toolbelt/Tests/CI'"
    $null=Invoke-LabTlsContainer @('exec','--user','10001:0',$cid,'/bin/sh','-c',$mkdir) -Budget $Budget
    foreach($entry in $SourceSet){
        $target=$Directory+'/'+$entry.Relative
        $command="set -eu; umask 077; test ! -e '$target'; cat > '$target'"
        $null=Invoke-LabTlsLinuxFileTransfer -Budget $Budget -Arguments @('exec','-i','--user','10001:0',$cid,'/bin/sh','-c',$command) -InputPath $entry.Path -ExpectedSha256 $entry.Sha256 -ExpectedBytes $entry.Bytes
        $observed=Invoke-LabTlsContainer @('exec',$cid,'sha256sum',$target) -Budget $Budget
        if($observed-cne($entry.Sha256+'  '+$target)){throw 'TLS_LINUX_SOURCE_COPY_CHANGED'}
    }
    $program=Get-LabTlsLinuxPeerEntryProgram
    if([Text.Encoding]::UTF8.GetByteCount($program)-gt16384){throw 'TLS_LINUX_BOOTSTRAP_LIMIT'}
    $null=Invoke-LabTlsContainer @('exec','-i','--user','10001:0',$cid,'/bin/sh','-c',("set -eu; umask 077; cat > '"+$Directory+"/entry.ps1'")) $program -Budget $Budget
    $expected=Get-LabTlsCaByteDigest ([Text.Encoding]::UTF8.GetBytes($program))
    if((Invoke-LabTlsContainer @('exec',$cid,'sha256sum',($Directory+'/entry.ps1')) -Budget $Budget)-cne($expected+'  '+$Directory+'/entry.ps1')){throw 'TLS_LINUX_SOURCE_COPY_CHANGED'}
}
