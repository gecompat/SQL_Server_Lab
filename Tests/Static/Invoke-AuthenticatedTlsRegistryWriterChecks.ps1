#Requires -Version 7.2
[CmdletBinding()]
param([string]$ChildRequestPath)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
foreach($name in @('DiagnosticBundleReader','StorageContract','AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsRegistryPayload',
    'AuthenticatedTlsRegistryDocument','AuthenticatedTlsRegistryRoot','AuthenticatedTlsContext','AuthenticatedTlsBackend','AuthenticatedTlsCaCandidate','AuthenticatedTlsRegistryWriter')){
    . (Join-Path $repo "Private/$name.ps1")
}
function Get-TlsWriterFixturePayload {
    param([string]$Ref)
    $facts=Get-LabTlsWindowsProcessFacts;$backend=Get-LabAuthenticatedTlsBackendMetadata CURRENT_PROCESS
    if(-not $backend.Success){throw 'FIXTURE_BACKEND_UNAVAILABLE'}
    return [pscustomobject][ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryPayload/0.1';ControllerId=$controller;LocationId=$location;
        Kind='SIGNER_CONTEXT';Ref=$Ref;Generation=1;Status='ACTIVE';Context='CURRENT_WINDOWS_PROCESS';
        Actor=[pscustomobject]@{UserSid=$facts.UserSid;HostMarker=$facts.HostMarker;ProfilePath=$facts.ProfilePath};
        Details=[pscustomobject]@{Backend='DOTNET_X509';RuntimeVersion=$backend.Value.RuntimeVersion;ApiStatus=$backend.Value.ApiStatus;
            Apis=$backend.Value.Apis;KeyProtectionStatus='NOT_EVALUATED'}}
}
function Get-TlsWriterFixtureDocument {
    param([int]$Revision,[object[]]$Payloads=@())
    $records=@($Payloads|ForEach-Object {Get-LabTlsPayloadIndexRecord $_})
    return ,[Text.Encoding]::UTF8.GetBytes((([pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsContextRegistry/0.1';
        Index=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsRegistryIndex/0.1';ControllerId=$controller;LocationId=$location;Revision=$Revision;Records=$records};
        Payloads=@($Payloads)})|ConvertTo-Json -Depth 12 -Compress))
}
function Invoke-TlsWriterFixtureOperation {
    param($Root,$Preview,$Operation,$Bytes,$Id)
    Invoke-LabAuthenticatedTlsRegistryWrite $Root $controller $location CURRENT_WINDOWS_PROCESS $Operation `
        $Preview.RootMetadataDigest $Preview.ActorDigest $Preview.RegistryByteSha256 $Bytes $Id
}

if($ChildRequestPath){
    # Nur der eigene von der Elternsuite erzeugte Tempbaum ist ein Testauftrag.
    $requestFile=[IO.Path]::GetFullPath($ChildRequestPath)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $requestFile.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or
        $requestFile.Substring($temp.Length) -cnotmatch '\Asql-lab-tls-writer-[0-9a-f]{32}\\[0-9a-f]{32}\.request\.json\z'){throw 'CHILD_SCOPE_INVALID'}
    $request=Read-LabDiagnosticJson $requestFile 65536 5
    $controller=$request.ControllerId;$location=$request.LocationId
    $root=[IO.Path]::GetFullPath($request.Root)
    if(-not $root.StartsWith((Split-Path $requestFile -Parent)+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'CHILD_ROOT_INVALID'}
    $realWrite=${function:Write-LabTlsCaPrivateFile};$realTerminal=${function:Write-LabTlsRegistryTerminal}
    $script:childMode=$request.Mode
    function Write-LabTlsCaPrivateFile {
        param($Path,$UserSid,$Bytes)
        if($script:childMode -ceq 'BEFORE_INTENT' -and $Path.EndsWith('.intent.json')){[Environment]::Exit(71)}
        & $realWrite $Path $UserSid $Bytes
        if($script:childMode -ceq 'AFTER_INTENT' -and $Path.EndsWith('.intent.json')){[Environment]::Exit(72)}
        if($script:childMode -ceq 'AFTER_CANDIDATE' -and $Path.EndsWith('.candidate.json')){[Environment]::Exit(73)}
    }
    function Write-LabTlsRegistryTerminal {
        param($Binding,$Intent,$Outcome)
        if($script:childMode -ceq 'AFTER_REPLACE'){[Environment]::Exit(74)}
        & $realTerminal $Binding $Intent $Outcome
    }
    if($request.Mode -cin @('HOLD_LOCK','HOLD_FILE')){
        $binding=Get-LabTlsRegistryWriterBinding $root $controller $location
        $held=Enter-LabTlsRegistryWriterLock $binding
        if($request.Mode -ceq 'HOLD_FILE'){$held.Mutex.ReleaseMutex();$held.Mutex.Dispose()}
        try{
            [IO.File]::WriteAllText($request.ReadyPath,'READY')
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while(-not [IO.File]::Exists($request.ReleasePath) -and $watch.Elapsed.TotalSeconds -lt 15){Start-Sleep -Milliseconds 50}
        }finally{if($request.Mode -ceq 'HOLD_FILE'){$held.Stream.Dispose()}else{Exit-LabTlsRegistryWriterLock $held}}
        exit 0
    }
    $candidate=Get-TlsWriterFixtureDocument 1 @(Get-TlsWriterFixturePayload $request.Ref)
    if($request.Mode -ceq 'PARALLEL'){
        [IO.File]::WriteAllText($request.ReadyPath,'READY')
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while(-not [IO.File]::Exists($request.ReleasePath) -and $watch.Elapsed.TotalSeconds -lt 15){Start-Sleep -Milliseconds 50}
        if(-not [IO.File]::Exists($request.ReleasePath)){exit 79}
    }
    $result=Invoke-TlsWriterFixtureOperation $root $request.Preview UPDATE $candidate
    [IO.File]::WriteAllText($request.ResultPath,($result|ConvertTo-Json -Depth 4 -Compress))
    exit 0
}

. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-writer-'+[guid]::NewGuid().ToString('N'))
$controller='11111111-1111-4111-8111-111111111111';$location='22222222-2222-4222-8222-222222222222'
$children=[Collections.Generic.List[object]]::new()
function New-TlsWriterFixture {
    $root=Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path (Join-Path $root 'Catalog'),(Join-Path $root 'State') -Force
    $volume=(Get-LabVolumeIdentity $root).VolumeId
    $marker=@{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId=$volume;DataRoot=$root}
    $catalog=@{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;
        LabDataLocations=@(@{LocationId=$location;ControllerId=$controller;VolumeId=$volume;LabDataRoot=$root})}
    [IO.File]::WriteAllText((Join-Path $root '.sql-server-lab-root.json'),($marker|ConvertTo-Json -Compress))
    [IO.File]::WriteAllText((Join-Path $root 'Catalog/storage-locations.json'),($catalog|ConvertTo-Json -Depth 5 -Compress))
    return $root
}
function Get-TlsWriterFixturePreview {param($Root) return Get-LabAuthenticatedTlsRegistryWriterPreview $Root $controller $location CURRENT_WINDOWS_PROCESS}
function Initialize-TlsWriterFixture {
    param($Root)
    $preview=Get-TlsWriterFixturePreview $Root
    $result=Invoke-TlsWriterFixtureOperation $Root $preview.Value INITIALIZE (Get-TlsWriterFixtureDocument 0)
    if(-not $result.Success){throw 'FIXTURE_INITIALIZATION_FAILED'}
    return Get-TlsWriterFixturePreview $Root
}
function Get-TlsWriterSnapshot {
    param($Root)
    return (@(Get-ChildItem -LiteralPath $Root -File -Recurse|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join '|')
}
function Start-TlsWriterFixtureChild {
    param($Root,$Preview,$Mode,$Ref)
    $stem=Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
    $request=@{Root=$Root;ControllerId=$controller;LocationId=$location;Preview=$Preview;Mode=$Mode;Ref=$Ref;
        ResultPath=$stem+'.result.json';ReadyPath=$stem+'.ready';ReleasePath=$stem+'.release'}
    [IO.File]::WriteAllText(($stem+'.request.json'),($request|ConvertTo-Json -Depth 5 -Compress))
    $info=[Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($arg in @('-NoLogo','-NoProfile','-File',$PSCommandPath,'-ChildRequestPath',($stem+'.request.json'))){$info.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::Start($info)
    $child=[pscustomobject]@{Process=$process;Request=$request;Stdout=$process.StandardOutput.ReadToEndAsync();Stderr=$process.StandardError.ReadToEndAsync()}
    $children.Add($child)
    return $child
}
function Complete-TlsWriterFixtureChild {
    param($Child)
    if(-not $Child.Process.WaitForExit(20000)){$Child.Process.Kill($true);$Child.Process.WaitForExit();throw 'CHILD_TIMEOUT'}
    $null=$Child.Stdout.GetAwaiter().GetResult();$stderr=$Child.Stderr.GetAwaiter().GetResult()
    if($stderr){throw $stderr}
    return $Child.Process.ExitCode
}
function Wait-TlsWriterChildReady {
    param($Child)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not [IO.File]::Exists($Child.Request.ReadyPath) -and $watch.Elapsed.TotalSeconds -lt 10 -and -not $Child.Process.HasExited){Start-Sleep -Milliseconds 50}
    if(-not [IO.File]::Exists($Child.Request.ReadyPath)){throw 'CHILD_NOT_READY'}
}
try{
    & {
        Set-StrictMode -Version Latest
        $alien=[pscustomobject]@{};$script:alienCalls=0;$alien|Add-Member ScriptMethod ToString {$script:alienCalls++;throw 'PRIVATE_CANARY'} -Force
        foreach($inputValue in @($null,'relative',$alien)){
            $r=Invoke-LabAuthenticatedTlsRegistryWrite $inputValue $controller $location CURRENT_WINDOWS_PROCESS INITIALIZE ('a'*64) ('b'*64) ABSENT (Get-TlsWriterFixtureDocument 0)
            Add-CheckResult 'TLS-W01 geschlossene Eingabeablehnung' (-not $r.Success -and $null -eq $r.Value -and $r.ErrorCode -ceq 'TLS_REGISTRY_WRITE_REJECTED')
        }
        Add-CheckResult 'TLS-W01 keine fremden Stringcasts' ($script:alienCalls -eq 0)
        $script:operationMethods=0
        $operation=([string]::Concat('UP','DATE')|Add-Member ScriptMethod StartsWith {$script:operationMethods++;return $true} -Force -PassThru)
        $r=Invoke-LabAuthenticatedTlsRegistryWrite 'C:\lab' $controller $location CURRENT_WINDOWS_PROCESS $operation ('a'*64) ('b'*64) ABSENT $null '99999999-9999-4999-8999-999999999999'
        Add-CheckResult 'TLS-W01 dekorierter Enumstring fuehrt keine Callermethode aus' (-not $r.Success -and $script:operationMethods -eq 0)
        if(-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
            $r=Get-TlsWriterFixturePreview 'C:\lab'
            Add-CheckResult 'TLS-W01 Windows-Lane auf anderer Plattform gesperrt' (-not $r.Success)
            Write-Host 'TLS-W Windows ACL/Lock/Replace/Crash: NOT_EXECUTED auf Nicht-Windows'
            return
        }
        $root=New-TlsWriterFixture;$preview=Get-TlsWriterFixturePreview $root
        Add-CheckResult 'TLS-W02 native lesende Bindung vor Anlage' ($preview.Success -and $preview.Value.Status -ceq 'NOT_INITIALIZED' -and
            -not (Test-Path -LiteralPath (Join-Path $root 'State/authenticated-tls')) -and -not $preview.Value.Ready -and -not $preview.Value.MutationAllowed)
        $before=Get-TlsWriterSnapshot $root
        $bad=Invoke-LabAuthenticatedTlsRegistryWrite $root $controller $location CURRENT_WINDOWS_PROCESS INITIALIZE ('a'*64) $preview.Value.ActorDigest ABSENT (Get-TlsWriterFixtureDocument 0)
        Add-CheckResult 'TLS-W02 stale Root vor Mutation abgelehnt' (-not $bad.Success -and (Get-TlsWriterSnapshot $root) -ceq $before)
        $bad=Invoke-LabAuthenticatedTlsRegistryWrite $root $controller $location CURRENT_WINDOWS_PROCESS INITIALIZE $preview.Value.RootMetadataDigest ('b'*64) ABSENT (Get-TlsWriterFixtureDocument 0)
        Add-CheckResult 'TLS-W02 falscher Actor vor Mutation abgelehnt' (-not $bad.Success -and (Get-TlsWriterSnapshot $root) -ceq $before)
        $invalid=[Text.Encoding]::UTF8.GetBytes('{"ContractVersion":"invalid"}')
        $bad=Invoke-TlsWriterFixtureOperation $root $preview.Value INITIALIZE $invalid
        Add-CheckResult 'TLS-W02 ungueltiges Dokument vor Anlage abgelehnt' (-not $bad.Success -and (Get-TlsWriterSnapshot $root) -ceq $before)
        $preview=Initialize-TlsWriterFixture $root
        $empty=Get-LabAuthenticatedTlsRegistryRoot $root $controller $location
        Add-CheckResult 'TLS-W03 explizite native Initialisierung und alter Reader' ($preview.Success -and $preview.Value.Status -ceq 'COMMITTED' -and $empty.Success -and $empty.Value.RegistryDocument.Index.Revision -eq 0)
        $sid=(Get-LabTlsWindowsProcessFacts).UserSid
        $dir=Join-Path $root 'State/authenticated-tls'
        Assert-LabTlsCaPrivateAcl $dir $sid -Directory
        foreach($file in Get-ChildItem -LiteralPath $dir -File){Assert-LabTlsCaPrivateAcl $file.FullName $sid}
        Add-CheckResult 'TLS-W03 private native Verzeichnis-/Datei-ACLs' $true
        $before=Get-TlsWriterSnapshot $root
        $r=Invoke-TlsWriterFixtureOperation $root $preview.Value INITIALIZE (Get-TlsWriterFixtureDocument 0)
        Add-CheckResult 'TLS-W03 keine Adoption bestehender Registry' (-not $r.Success -and (Get-TlsWriterSnapshot $root) -ceq $before)
        $payload=Get-TlsWriterFixturePayload '33333333-3333-4333-8333-333333333333';$candidate=Get-TlsWriterFixtureDocument 1 @($payload)
        $r=Invoke-TlsWriterFixtureOperation $root $preview.Value UPDATE $candidate
        $current=Get-TlsWriterFixturePreview $root
        Add-CheckResult 'TLS-W04 atomarer nativer Replace mit frischer Payload und Commit' ($r.Success -and $r.Value.Status -ceq 'METADATA_COMMITTED' -and
            $current.Success -and $current.Value.RegistryByteSha256 -ceq (Get-LabTlsCaByteDigest $candidate) -and -not $r.Value.Ready)
        $before=Get-TlsWriterSnapshot $root
        $r=Invoke-TlsWriterFixtureOperation $root $preview.Value UPDATE $candidate
        Add-CheckResult 'TLS-W04 unveraenderter stale Client ohne Writes abgelehnt' (-not $r.Success -and (Get-TlsWriterSnapshot $root) -ceq $before)
        # Eine alte, formal gueltige Registry ist ohne passenden Journalhead ungueltig.
        $registry=Join-Path $dir 'registry.json';$original=[IO.File]::ReadAllBytes($registry)
        [IO.File]::WriteAllBytes($registry,(Get-TlsWriterFixtureDocument 0))
        Add-CheckResult 'TLS-W04 Rollback-Replay gesperrt' (-not (Get-TlsWriterFixturePreview $root).Success)
        [IO.File]::WriteAllBytes($registry,$original)
        $ownerPath=Join-Path $dir 'owner.json';$ownerBytes=[IO.File]::ReadAllBytes($ownerPath)
        $duplicate=[Text.Encoding]::UTF8.GetString($ownerBytes).Replace('"RegistryId":','"Registry\u0049d":"private-canary","RegistryId":')
        [IO.File]::WriteAllText($ownerPath,$duplicate)
        Add-CheckResult 'TLS-W04 escapter Duplicate im Owner gesperrt' (-not (Get-TlsWriterFixturePreview $root).Success)
        [IO.File]::WriteAllBytes($ownerPath,$ownerBytes)
        $oldAcl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($ownerPath))
        $badAcl=Get-LabTlsCaSecurity $sid;$badAcl.SetAccessRuleProtection($false,$true)
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($ownerPath),$badAcl)
        Add-CheckResult 'TLS-W04 aufgeweichte native ACL gesperrt' (-not (Get-TlsWriterFixturePreview $root).Success)
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($ownerPath),$oldAcl)
        $backup=@(Get-ChildItem -LiteralPath $dir -Filter '*.source.json' -File)
        Add-CheckResult 'TLS-W04 Originalbytes als private Ersatzsicherung erhalten' ($backup.Count -eq 1 -and (Get-LabTlsCaByteDigest ([IO.File]::ReadAllBytes($backup[0].FullName))) -ceq $preview.Value.RegistryByteSha256)
        $saved=[IO.File]::ReadAllBytes($backup[0].FullName)
        [IO.File]::WriteAllBytes($backup[0].FullName,[byte[]]@(0))
        Add-CheckResult 'TLS-W04 korrupte Ersatzsicherung gesperrt' (-not (Get-TlsWriterFixturePreview $root).Success)
        [IO.File]::WriteAllBytes($backup[0].FullName,$saved)
        $markerPath=Join-Path $root '.sql-server-lab-root.json';$catalogPath=Join-Path $root 'Catalog/storage-locations.json'
        $markerBytes=[IO.File]::ReadAllBytes($markerPath);$catalogBytes=[IO.File]::ReadAllBytes($catalogPath)
        $volume=(Get-LabVolumeIdentity $root).VolumeId
        $fake='\\?\Volume{99999999-9999-4999-8999-999999999999}\'
        foreach($path in @($markerPath,$catalogPath)){
            $value=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
            if($path -ceq $markerPath){$value.VolumeId=$fake}else{$value.LabDataLocations[0].VolumeId=$fake}
            [IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 6 -Compress))
        }
        Add-CheckResult 'TLS-W04 passende kopierte Volumemetadaten genuegen nicht' (-not (Get-TlsWriterFixturePreview $root).Success)
        [IO.File]::WriteAllBytes($markerPath,$markerBytes);[IO.File]::WriteAllBytes($catalogPath,$catalogBytes)

        foreach($mode in @('BEFORE_INTENT','AFTER_INTENT','AFTER_CANDIDATE','AFTER_REPLACE')){
            $root=New-TlsWriterFixture;$initial=Initialize-TlsWriterFixture $root
            $child=Start-TlsWriterFixtureChild $root $initial.Value $mode '44444444-4444-4444-8444-444444444444'
            $exitCode=Complete-TlsWriterFixtureChild $child
            $after=Get-TlsWriterFixturePreview $root
            $expected=if($mode -ceq 'BEFORE_INTENT'){'COMMITTED'}elseif($mode -ceq 'AFTER_REPLACE'){'CANDIDATE_INSTALLED'}else{'SOURCE_UNCHANGED'}
            Add-CheckResult "TLS-W05 echter Prozessabbruch $mode" ($exitCode -in @(71,72,73,74) -and $after.Success -and $after.Value.Status -ceq $expected)
            if($mode -ceq 'BEFORE_INTENT'){continue}
            $before=Get-TlsWriterSnapshot $root
            $blocked=Invoke-TlsWriterFixtureOperation $root $after.Value UPDATE (Get-TlsWriterFixtureDocument 1 @(Get-TlsWriterFixturePayload '55555555-5555-4555-8555-555555555555'))
            Add-CheckResult 'TLS-W05 pending Intent blockiert normale Writes ohne Retry' (-not $blocked.Success -and (Get-TlsWriterSnapshot $root) -ceq $before)
            $wrong=if($mode -ceq 'AFTER_REPLACE'){'RECOVER_ABORT'}else{'RECOVER_COMMIT'}
            $r=Invoke-TlsWriterFixtureOperation $root $after.Value $wrong $null $after.Value.PendingTransactionId
            Add-CheckResult 'TLS-W06 falsche Recoveryaktion ohne Writes abgelehnt' (-not $r.Success -and (Get-TlsWriterSnapshot $root) -ceq $before)
            if($mode -ceq 'AFTER_INTENT'){
                $script:operationMethods=0
                $operation=([string]::Concat('UP','DATE')|Add-Member ScriptMethod StartsWith {$script:operationMethods++;return $true} -Force -PassThru)
                $r=Invoke-TlsWriterFixtureOperation $root $after.Value $operation $null $after.Value.PendingTransactionId
                Add-CheckResult 'TLS-W06 dekoriertes UPDATE kann pending Intent nicht als Recovery abbrechen' (-not $r.Success -and
                    $script:operationMethods -eq 0 -and (Get-TlsWriterSnapshot $root) -ceq $before)
            }
            if($mode -ceq 'AFTER_REPLACE'){
                $registryPath=Join-Path $root 'State/authenticated-tls/registry.json';$saved=[IO.File]::ReadAllBytes($registryPath)
                [IO.File]::WriteAllBytes($registryPath,(Get-TlsWriterFixtureDocument 1 @(Get-TlsWriterFixturePayload '99999999-9999-4999-8999-999999999999')))
                $unknown=Get-TlsWriterFixturePreview $root;$snapshot=Get-TlsWriterSnapshot $root
                $r=Invoke-TlsWriterFixtureOperation $root $unknown.Value RECOVER_COMMIT $null $unknown.Value.PendingTransactionId
                Add-CheckResult 'TLS-W06 fremde gueltige Bytes bleiben UNKNOWN ohne Recoverywrite' ($unknown.Success -and $unknown.Value.Status -ceq 'UNKNOWN' -and
                    -not $r.Success -and (Get-TlsWriterSnapshot $root) -ceq $snapshot)
                [IO.File]::WriteAllBytes($registryPath,$saved)
            }
            $action=if($mode -ceq 'AFTER_REPLACE'){'RECOVER_COMMIT'}else{'RECOVER_ABORT'}
            $r=Invoke-TlsWriterFixtureOperation $root $after.Value $action $null $after.Value.PendingTransactionId
            $recovered=Get-TlsWriterFixturePreview $root
            Add-CheckResult "TLS-W06 explizite native Recovery $action" ($r.Success -and $recovered.Success -and $recovered.Value.Status -ceq 'COMMITTED' -and
                $recovered.Value.RegistryByteSha256 -ceq $after.Value.RegistryByteSha256)
            if($action -ceq 'RECOVER_ABORT'){
                $before=Get-TlsWriterSnapshot $root
                $reuse=Get-TlsWriterFixtureDocument 1 @(Get-TlsWriterFixturePayload '44444444-4444-4444-8444-444444444444')
                $r=Invoke-TlsWriterFixtureOperation $root $recovered.Value UPDATE $reuse
                Add-CheckResult 'TLS-W06 abgebrochene Referenz bleibt reserviert' (-not $r.Success -and (Get-TlsWriterSnapshot $root) -ceq $before)
                $fresh=Get-TlsWriterFixtureDocument 1 @(Get-TlsWriterFixturePayload '55555555-5555-4555-8555-555555555555')
                $r=Invoke-TlsWriterFixtureOperation $root $recovered.Value UPDATE $fresh
                Add-CheckResult 'TLS-W06 neue Referenz nach Recovery schreibbar' $r.Success
            }
        }
        $root=New-TlsWriterFixture;$initial=Initialize-TlsWriterFixture $root
        foreach($mode in @('HOLD_LOCK','HOLD_FILE')){
            $holder=Start-TlsWriterFixtureChild $root $initial.Value $mode '66666666-6666-4666-8666-666666666666'
            Wait-TlsWriterChildReady $holder
            $watch=[Diagnostics.Stopwatch]::StartNew()
            $r=Invoke-TlsWriterFixtureOperation $root $initial.Value UPDATE (Get-TlsWriterFixtureDocument 1 @(Get-TlsWriterFixturePayload '66666666-6666-4666-8666-666666666666'))
            Add-CheckResult "TLS-W07 echte fremde Prozesssperre $mode begrenzt abgelehnt" (-not $r.Success -and $watch.Elapsed.TotalSeconds -lt 10)
            [IO.File]::WriteAllText($holder.Request.ReleasePath,'RELEASE')
            Add-CheckResult 'TLS-W07 eigener Sperrprozess kontrolliert beendet' ((Complete-TlsWriterFixtureChild $holder) -eq 0)
        }
        $one=Start-TlsWriterFixtureChild $root $initial.Value PARALLEL '77777777-7777-4777-8777-777777777777'
        $two=Start-TlsWriterFixtureChild $root $initial.Value PARALLEL '88888888-8888-4888-8888-888888888888'
        Wait-TlsWriterChildReady $one;Wait-TlsWriterChildReady $two
        [IO.File]::WriteAllText($one.Request.ReleasePath,'RELEASE');[IO.File]::WriteAllText($two.Request.ReleasePath,'RELEASE')
        $codes=@((Complete-TlsWriterFixtureChild $one),(Complete-TlsWriterFixtureChild $two))
        $results=@((Get-Content -LiteralPath $one.Request.ResultPath -Raw|ConvertFrom-Json),(Get-Content -LiteralPath $two.Request.ResultPath -Raw|ConvertFrom-Json))
        $after=Get-TlsWriterFixturePreview $root
        Add-CheckResult 'TLS-W07 zwei native Writer genau ein Commit ohne verlorenes Update' (@($codes|Where-Object {$_ -ne 0}).Count -eq 0 -and
            @($results|Where-Object {$_.Success}).Count -eq 1 -and $after.Success -and $after.Value.Status -ceq 'COMMITTED')
    }
}finally{
    foreach($child in $children){if(-not $child.Process.HasExited){$child.Process.Kill($true);$child.Process.WaitForExit()};$child.Process.Dispose()}
    if(Test-Path -LiteralPath $fixtureRoot){
        $resolved=[IO.Path]::GetFullPath($fixtureRoot);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '\Asql-lab-tls-writer-[0-9a-f]{32}\z'){throw 'FIXTURE_CLEANUP_SCOPE_INVALID'}
        $null=Assert-LabDiagnosticPath $resolved
        Remove-Item -LiteralPath $resolved -Recurse -Force
        Add-CheckResult 'TLS-W08 eigener Tempbaum vollstaendig entfernt' (-not (Test-Path -LiteralPath $resolved))
    }
}
Write-Host "TLS Registry Writer: $passed PASS / $($failures.Count) FAIL"
if($failures.Count){throw 'TLS_REGISTRY_WRITER_CHECKS_FAILED'}
