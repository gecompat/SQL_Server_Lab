#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
foreach($file in @('AuthenticatedTlsRequest','AuthenticatedTlsBackend','DiagnosticBundleReader','AuthenticatedTlsContext')){
    . (Join-Path $repo "Private/$file.ps1")
}
$source=Join-Path $repo 'Private/AuthenticatedTlsContext.ps1'
function New-TlsContextFixture {
    param([string]$Kind='CLIENT_CONTEXT')
    $value=[ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsContextRequest/0.1';RequestId='11111111-1111-4111-8111-111111111111';Kind=$Kind;Context='CURRENT_WINDOWS_PROCESS'}
    if($Kind -ceq 'CLIENT_CONTEXT'){
        $value.ClientRef='22222222-2222-4222-8222-222222222222';$value.Store='CURRENT_USER_ROOT';$value.ClientStacks=@('ODBC_SQLCMD','SYSTEM_DATA_SQLCLIENT')
    }else{$value.SignerContextRef='33333333-3333-4333-8333-333333333333';$value.Backend='DOTNET_X509'}
    return [pscustomobject]$value
}
function Assert-TlsContextRejected {
    param([object]$Request)
    $all=@(Test-LabAuthenticatedTlsContextRequest -Request $Request *>&1)
    Add-CheckResult 'TLS-C01 geschlossene Ablehnung ohne Rohdaten' ($all.Count -eq 1 -and -not $all[0].Success -and $null -eq $all[0].Value -and
        $all[0].ErrorCode -ceq 'TLS_CONTEXT_REQUEST_INVALID' -and ($all|ConvertTo-Json -Depth 12 -Compress) -notmatch 'TLS_CONTEXT_PRIVATE_CANARY')
}
& {
    Set-StrictMode -Version Latest
    foreach($kind in @('CLIENT_CONTEXT','SIGNER_CONTEXT')){
        $request=New-TlsContextFixture $kind
        $result=Test-LabAuthenticatedTlsContextRequest $request
        $count=if($kind -ceq 'CLIENT_CONTEXT'){7}else{6}
        Add-CheckResult "TLS-C01 frische Form $kind" ($result.Success -and $null -eq $result.ErrorCode -and
            @($result.PSObject.Properties).Count -eq 3 -and @($result.Value.PSObject.Properties).Count -eq $count -and
            -not [object]::ReferenceEquals($request,$result.Value))
        foreach($name in @($request.PSObject.Properties.Name)){
            $bad=New-TlsContextFixture $kind;$bad.PSObject.Properties.Remove($name)
            Assert-TlsContextRejected $bad
            $bad=New-TlsContextFixture $kind;$bad.$name=$null
            Assert-TlsContextRejected $bad
        }
        foreach($extra in @('AuthorityRef','HostMarker','UserSid','Process','Binaries','StateRoot','Approved','Generation','MutationAllowed')){
            $bad=New-TlsContextFixture $kind;$bad|Add-Member NoteProperty $extra 'TLS_CONTEXT_PRIVATE_CANARY'
            Assert-TlsContextRejected $bad
        }
        foreach($context in @('CURRENT_PROCESS','current_windows_process','CURRENT_WINDOWS_PROCESS ',"CURRENT_WINDOWS_PROCESS`n",'CURRENT_USER','LOCAL_MACHINE',@('CURRENT_WINDOWS_PROCESS'),1,$true)){
            $bad=New-TlsContextFixture $kind;$bad.Context=$context;Assert-TlsContextRejected $bad
        }
        foreach($name in @('RequestId',$(if($kind -ceq 'CLIENT_CONTEXT'){'ClientRef'}else{'SignerContextRef'}))){
            foreach($id in @([guid]::Empty.ToString('D'),'TLS_CONTEXT_PRIVATE_CANARY','{11111111-1111-4111-8111-111111111111}',[guid]::NewGuid(),1)){
                $bad=New-TlsContextFixture $kind;$bad.$name=$id;Assert-TlsContextRejected $bad
            }
        }
    }
    $request=New-TlsContextFixture
    $result=Test-LabAuthenticatedTlsContextRequest $request
    Add-CheckResult 'TLS-C02 feste Stackreihenfolge, eigenes Array' (($result.Value.ClientStacks -join ',') -ceq 'SYSTEM_DATA_SQLCLIENT,ODBC_SQLCMD' -and
        -not [object]::ReferenceEquals($result.Value.ClientStacks,$request.ClientStacks))
    $request.ClientStacks[0]='TLS_CONTEXT_PRIVATE_CANARY'
    Add-CheckResult 'TLS-C02 Caller-Aenderung bleibt getrennt' ($result.Value.ClientStacks[1] -ceq 'ODBC_SQLCMD')
    $request=New-TlsContextFixture;$request.ClientStacks=[string[]]@('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')
    Add-CheckResult 'TLS-C02 natives string-Array akzeptiert' (Test-LabAuthenticatedTlsContextRequest $request).Success
    foreach($stacks in @(@(),@('ODBC_SQLCMD'),@('ODBC_SQLCMD','ODBC_SQLCMD'),@('system_data_sqlclient','ODBC_SQLCMD'),@('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD','EXTRA'),@('SYSTEM_DATA_SQLCLIENT',1))){
        $bad=New-TlsContextFixture;$bad.ClientStacks=$stacks;Assert-TlsContextRejected $bad
    }
    foreach($pair in @(@('CLIENT_CONTEXT','Store','LOCAL_MACHINE_ROOT'),@('CLIENT_CONTEXT','Store','CURRENT_USER_ROOT '),@('SIGNER_CONTEXT','Backend','OPENSSL'),@('SIGNER_CONTEXT','Backend','dotnet_x509'))){
        $bad=New-TlsContextFixture $pair[0];$bad.($pair[1])=$pair[2];Assert-TlsContextRejected $bad
    }
    foreach($bad in @($null,1,$true,'CLIENT_CONTEXT',@{},@('CLIENT_CONTEXT'),[Collections.Generic.List[string]]::new())){Assert-TlsContextRejected $bad}
    $script:foreignCalls=0
    $alien=[pscustomobject]@{};$alien|Add-Member ScriptProperty Context {$script:foreignCalls++;throw 'TLS_CONTEXT_PRIVATE_CANARY getter'}
    $alien|Add-Member ScriptMethod ToString {$script:foreignCalls++;throw 'TLS_CONTEXT_PRIVATE_CANARY cast'} -Force
    Assert-TlsContextRejected $alien
    $bad=New-TlsContextFixture;$bad.Context=$alien;Assert-TlsContextRejected $bad
    $bad=New-TlsContextFixture;$bad.ClientStacks=@($alien,'ODBC_SQLCMD');Assert-TlsContextRejected $bad
    $bad=New-TlsContextFixture;$bad.PSObject.Properties.Remove('Context');$bad|Add-Member NoteProperty context 'CURRENT_WINDOWS_PROCESS';Assert-TlsContextRejected $bad
    Add-CheckResult 'TLS-C03 keine fremden Getter oder Casts' ($script:foreignCalls -eq 0)
    $culture=[Threading.Thread]::CurrentThread.CurrentCulture
    try{
        foreach($name in @('en-US','de-DE','tr-TR')){
            [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($name)
            foreach($char in @([char]0x200b,[char]0x00ad)){
                foreach($kind in @('CLIENT_CONTEXT','SIGNER_CONTEXT')){
                    $shape=New-TlsContextFixture $kind
                    foreach($field in @('Kind','Context','ContractVersion',$(if($kind -ceq 'CLIENT_CONTEXT'){'Store'}else{'Backend'}))){
                        $bad=New-TlsContextFixture $kind;$bad.$field=$shape.$field+$char;Assert-TlsContextRejected $bad
                    }
                }
                $bad=New-TlsContextFixture;$bad.ClientStacks=@('SYSTEM_DATA_SQLCLIENT',('ODBC_SQLCMD'+$char));Assert-TlsContextRejected $bad
            }
        }
    }finally{[Threading.Thread]::CurrentThread.CurrentCulture=$culture}
}

# Native Leser durch synthetische Befunde ersetzen; keine echten Hostwerte im Testlog.
$originalFacts=${function:Get-LabTlsWindowsProcessFacts};$originalBinaries=${function:Get-LabTlsWindowsClientBinaryMetadata}
$originalBackend=${function:Get-LabAuthenticatedTlsBackendMetadata}
$script:factsCalls=0;$script:binaryCalls=0;$script:backendCalls=0
try{
    function Get-LabTlsWindowsProcessFacts {
        $script:factsCalls++
        return [pscustomobject]@{UserSid='S-1-5-21-100-200-300-1001';HostMarker='44444444-4444-4444-8444-444444444444';HostMarkerStatus='LOCAL_REGISTRY_MARKER_ONLY';
            ProfilePath='synthetic-profile';ProfileStatus='OBSERVED_HIVE_AND_PATH';ActorStatus='NON_IMPERSONATING_PROCESS_TOKEN';ProcessId=123;ProcessStartUtcTicks=456L;ProcessPath='synthetic-process'}
    }
    function Get-LabTlsWindowsClientBinaryMetadata {
        $script:binaryCalls++
        return [pscustomobject]@{LoadedImageDigestStatus='NOT_MEASURED';SqlcmdFlavorStatus='NOT_QUALIFIED';LoadedOdbcDriverStatus='NOT_EXECUTED'}
    }
    function Get-LabAuthenticatedTlsBackendMetadata {
        param($Context)
        $script:backendCalls++
        return [pscustomobject]@{Success=$true;Value=[pscustomobject]@{Context=$Context;ApiStatus='INCOMPLETE';Ready=$false;MutationAllowed=$false}}
    }
    $bad=New-TlsContextFixture;$bad|Add-Member NoteProperty UserSid 'TLS_CONTEXT_PRIVATE_CANARY'
    $result=Get-LabAuthenticatedTlsContextPreview $bad
    Add-CheckResult 'TLS-C04 Formpruefung vor jeder nativen Lesung' (-not $result.Success -and $result.ErrorCode -ceq 'TLS_CONTEXT_REQUEST_INVALID' -and
        $script:factsCalls -eq 0 -and $script:binaryCalls -eq 0 -and $script:backendCalls -eq 0)
    foreach($kind in @('CLIENT_CONTEXT','SIGNER_CONTEXT')){
        $result=Get-LabAuthenticatedTlsContextPreview (New-TlsContextFixture $kind)
        $value=$result.Value
        $count=if($kind -ceq 'CLIENT_CONTEXT'){15}else{13}
        Add-CheckResult "TLS-C05 private Projektion $kind" ($result.Success -and $null -eq $result.ErrorCode -and @($value.PSObject.Properties).Count -eq $count -and
            $value.ContractVersion -ceq 'SqlServerLab.AuthenticatedTlsContextPreview/0.1' -and $value.Kind -ceq $kind -and
            $value.Status -ceq 'PRIVATE_METADATA_PREVIEW' -and $value.Context -ceq 'CURRENT_WINDOWS_PROCESS' -and
            $value.RegistrationStatus -ceq 'NOT_REGISTERED' -and $value.QualificationStatus -ceq 'NOT_EXECUTED' -and
            $value.Ready -is [bool] -and -not $value.Ready -and $value.MutationAllowed -is [bool] -and -not $value.MutationAllowed)
        Add-CheckResult "TLS-C05 keine CA-Referenz $kind" ($null -eq $value.PSObject.Properties['AuthorityRef'])
        if($kind -ceq 'CLIENT_CONTEXT'){
            Add-CheckResult 'TLS-C05 keine Clientqualifikation behauptet' ($value.TrustStatus -ceq 'NOT_EVALUATED' -and $value.Binaries.SqlcmdFlavorStatus -ceq 'NOT_QUALIFIED' -and
                $value.Binaries.LoadedImageDigestStatus -ceq 'NOT_MEASURED' -and $value.Binaries.LoadedOdbcDriverStatus -ceq 'NOT_EXECUTED' -and $script:backendCalls -eq 0)
        }else{Add-CheckResult 'TLS-C05 unvollstaendiges Backend ohne Keyfreigabe' ($value.Backend.ApiStatus -ceq 'INCOMPLETE' -and $value.Backend.Context -ceq 'CURRENT_PROCESS' -and $value.KeyProtectionStatus -ceq 'NOT_EVALUATED' -and $script:binaryCalls -eq 1)}
    }
    foreach($code in @('TLS_CONTEXT_PLATFORM_UNSUPPORTED','TLS_CONTEXT_IDENTITY_UNAVAILABLE','TLS_CONTEXT_HOST_UNAVAILABLE','TLS_CONTEXT_PROFILE_UNAVAILABLE',
        'TLS_CONTEXT_BINARY_UNAVAILABLE','TLS_CONTEXT_BACKEND_UNAVAILABLE','TLS_CONTEXT_PRIVATE_CANARY raw error')){
        $script:probeError=$code
        function Get-LabTlsWindowsProcessFacts {throw $script:probeError}
        $all=@(Get-LabAuthenticatedTlsContextPreview (New-TlsContextFixture) *>&1)
        $expected=if($code -like '*PRIVATE_CANARY*'){'TLS_CONTEXT_PREVIEW_UNAVAILABLE'}else{$code}
        Add-CheckResult 'TLS-C06 Fehler ohne Teilbefund oder Rohdiagnose' ($all.Count -eq 1 -and -not $all[0].Success -and $null -eq $all[0].Value -and
            $all[0].ErrorCode -ceq $expected -and ($all|ConvertTo-Json -Depth 12 -Compress) -notmatch 'PRIVATE_CANARY|synthetic-profile')
    }
    function Get-LabTlsWindowsProcessFacts {return [pscustomobject]@{ProfilePath='TLS_CONTEXT_PRIVATE_CANARY synthetic-profile'}}
    function Get-LabTlsWindowsClientBinaryMetadata {throw 'TLS_CONTEXT_BINARY_UNAVAILABLE'}
    $all=@(Get-LabAuthenticatedTlsContextPreview (New-TlsContextFixture) *>&1)
    Add-CheckResult 'TLS-C06 Binaryfehler verwirft private Prozessmetadaten' ($all.Count -eq 1 -and -not $all[0].Success -and $null -eq $all[0].Value -and
        $all[0].ErrorCode -ceq 'TLS_CONTEXT_BINARY_UNAVAILABLE' -and ($all|ConvertTo-Json -Compress) -notmatch 'PRIVATE_CANARY')
    function Get-LabAuthenticatedTlsBackendMetadata {param($Context) return [pscustomobject]@{Success=$false;Value=$null}}
    $all=@(Get-LabAuthenticatedTlsContextPreview (New-TlsContextFixture 'SIGNER_CONTEXT') *>&1)
    Add-CheckResult 'TLS-C06 Backendfehler verwirft private Prozessmetadaten' ($all.Count -eq 1 -and -not $all[0].Success -and $null -eq $all[0].Value -and
        $all[0].ErrorCode -ceq 'TLS_CONTEXT_BACKEND_UNAVAILABLE' -and ($all|ConvertTo-Json -Compress) -notmatch 'PRIVATE_CANARY')
    Set-Item function:Get-LabTlsWindowsProcessFacts $originalFacts
    if(-not $IsWindows){
        $result=Get-LabAuthenticatedTlsContextPreview (New-TlsContextFixture)
        Add-CheckResult 'TLS-C06 Nicht-Windows vor Identitaet/Registry gesperrt' (-not $result.Success -and $result.ErrorCode -ceq 'TLS_CONTEXT_PLATFORM_UNSUPPORTED' -and $null -eq $result.Value)
    }
}finally{
    Set-Item function:Get-LabTlsWindowsProcessFacts $originalFacts
    Set-Item function:Get-LabTlsWindowsClientBinaryMetadata $originalBinaries
    Set-Item function:Get-LabAuthenticatedTlsBackendMetadata $originalBackend
}

# Nur eigene kleine lokale Bytes lesen, keine echten Clientbinaries.
$owned=Join-Path $repo ('.artifacts/test-runs/tls-context-synthetic-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $owned
try{
    $path=Join-Path $owned 'sqlcmd.exe';[IO.File]::WriteAllBytes($path,[byte[]]@(97,98,99))
    $metadata=Read-LabTlsContextBinaryMetadata $path 'sqlcmd.exe'
    Add-CheckResult 'TLS-C07 bekannte Bytes und reine Disk-Evidence' ($metadata.DiskSha256 -ceq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' -and
        $metadata.DiskBytes -eq 3 -and $metadata.Evidence -ceq 'ON_DISK_BYTES_ONLY' -and @($metadata.PSObject.Properties).Count -eq 4)
    foreach($fileName in @('other.exe','sqlcmd.exe ')){
        $blocked=$false;try{$null=Read-LabTlsContextBinaryMetadata $path $fileName}catch{$blocked=$true}
        Add-CheckResult 'TLS-C07 falscher Dateiname gesperrt' $blocked
    }
    foreach($length in @(0,67108865)){
        $stream=[IO.File]::Open($path,[IO.FileMode]::Create);try{$stream.SetLength($length)}finally{$stream.Dispose()}
        $blocked=$false;try{$null=Read-LabTlsContextBinaryMetadata $path 'sqlcmd.exe'}catch{$blocked=$true}
        Add-CheckResult 'TLS-C07 leere oder zu grosse Datei vor Hash gesperrt' $blocked
    }
    $blocked=$false;try{$null=Read-LabTlsContextBinaryMetadata (Join-Path $owned '../sqlcmd.exe') 'sqlcmd.exe'}catch{$blocked=$true}
    Add-CheckResult 'TLS-C07 Traversal gesperrt' $blocked
}finally{
    # Exakt selbst angelegter GUID-Scope, niemals fremde oder echte Binaries.
    $expectedParent=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/test-runs')).TrimEnd('\','/')
    if([string]::Equals([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($owned)),$expectedParent,[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($owned) -cmatch '\Atls-context-synthetic-[0-9a-f]{32}\z'){
        Remove-Item -LiteralPath $owned -Recurse -Force
    }else{throw 'TLS_CONTEXT_FIXTURE_CLEANUP_BLOCKED'}
}
Add-CheckResult 'TLS-C07 eigener Fixture-Scope entfernt' (-not (Test-Path -LiteralPath $owned))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
Add-CheckResult 'TLS-C08 Laden definiert nur Funktionen' ($errors.Count -eq 0 -and @($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0)
$commands=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object GetCommandName)
$allowed=@('Get-LabTlsRequestFields','Test-LabTlsRequestEnum','Test-LabTlsRequestReference','Assert-LabDiagnosticPath','Where-Object','Get-Command','Select-Object',
    'Read-LabTlsContextBinaryMetadata','Test-LabAuthenticatedTlsContextRequest','Get-LabTlsWindowsProcessFacts','Get-LabTlsWindowsClientBinaryMetadata','Get-LabAuthenticatedTlsBackendMetadata')
Add-CheckResult 'TLS-C08 nur begrenzter lesender Commandgraph' (@($commands|Where-Object {$_ -cnotin $allowed}).Count -eq 0)
$text=[IO.File]::ReadAllText($source)
$methods=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true)|ForEach-Object {$_.Member.Value})
Add-CheckResult 'TLS-C08 keine Registry-/Key-/Store-/Prozessmutation' (@($methods|Where-Object {$_ -cin @('SetValue','CreateSubKey','DeleteSubKey','OpenExisting','Load','LoadFrom','Start','CreateSigningRequest','LoadSigningRequest','ExportPkcs12')}).Count -eq 0 -and
    $text -notmatch 'X509Store|SqlConnection\]::new')
Add-CheckResult 'TLS-C08 nur Application und Disk-Beobachtung, kein Loaded-Image-Versprechen' ($text.Contains('-CommandType Application') -and $text.Contains("LoadedImageDigestStatus='NOT_MEASURED'") -and $text.Contains("SqlcmdFlavorStatus='NOT_QUALIFIED'"))
Write-Host "Authenticated TLS Context: $passed PASS, $($failures.Count) FAIL"
if($failures.Count){throw 'AUTHENTICATED_TLS_CONTEXT_CHECKS_FAILED'}
