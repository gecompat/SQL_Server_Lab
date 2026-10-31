#Requires -Version 7.5
# Echte eigene RSA-/Datei-Fixtures; ausschließlich native Provider-/Gast- und
# Clientbeobachtungen sind injiziert. Kein SQL-, Hyper-V- oder Truststoreeffekt.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force
foreach($name in @('DiagnosticBundleReader','AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsRegistryPayload',
    'AuthenticatedTlsCaCandidate','AuthenticatedTlsContext','AuthenticatedTlsRegistryRoot','AuthenticatedTlsRegistryWriter',
    'AuthenticatedTlsLab','AuthenticatedTlsQualification','AuthenticatedTlsWindowsLab','AuthenticatedTlsLiveQualification','SqlReadiness')){
    . (Join-Path $repo "Private/$name.ps1")
}
. (Join-Path $repo 'Public/Read-SqlServerLabQualifiedTestEnvironment.ps1')
. (Join-Path $repo 'Public/TestEnvironment.ps1')
$script:ModuleRoot=$repo
function Reject-WindowsTls([scriptblock]$Action){try{& $Action|Out-Null;return $false}catch{return $true}}
function New-SyntheticWindowsTlsSecret {
    $secure=[securestring]::new()
    foreach($character in 'Synthetic-Only-8472!'.ToCharArray()){$secure.AppendChar($character)}
    $secure.MakeReadOnly();return $secure
}
$createIntent=& (Get-Module SqlServerLab) {
    $bytes=New-LabTlsWindowsCreateManifest @{Profile='compact';Cpu=2;MemoryMB=4096;Port=1433;LabName='Contoso'} ('hyperv-sql-prepared-sealed-'+('f'*64)) '11111111-1111-4111-8111-111111111111'
    $text=[Text.Encoding]::UTF8.GetString($bytes);$document=$text|ConvertFrom-Json
    [pscustomobject]@{Valid=(Test-LabManifestSchema $text).IsValid;Pinned=($document.instances[0].hyperv.preparedImageId -ceq ('hyperv-sql-prepared-sealed-'+('f'*64)));
        NoSecrets=($text -notmatch 'password|credential');Network=$document.instances[0].network.intent;Os=$document.instances[0].os;
        ActivationStrategy=$document.instances[0].windowsActivation.Strategy;ActivationEgress=$document.instances[0].windowsActivation.EgressPolicy}
}
Add-CheckResult 'Windows creator uses the canonical schema-valid secret-free pinned-image manifest' ($createIntent.Valid -and $createIntent.Pinned -and $createIntent.NoSecrets -and $createIntent.Network -ceq 'hostOnly' -and $createIntent.Os -ceq 'windows')
Add-CheckResult 'Windows test creation uses the established evaluation activation with temporary egress' ($createIntent.ActivationStrategy -ceq 'EvaluationOnline' -and $createIntent.ActivationEgress -ceq 'AllowTemporary')
$unprivileged=& (Get-Module SqlServerLab) {
    function Test-LabAdministrator {return $false}
    try{New-LabAuthenticatedTlsWindowsEnvironment @{Version='2025';Provider='hyperv';DataRoot='synthetic';
        TlsCandidateId='11111111-1111-4111-8111-111111111111';TlsControllerId='22222222-2222-4222-8222-222222222222';TlsLocationId='33333333-3333-4333-8333-333333333333'}|Out-Null;return $false}
    catch{return $_.Exception.Message -ceq 'TLS_WINDOWS_CREATE_ELEVATED_RUNNER_REQUIRED'}
}
Add-CheckResult 'Unprivileged Windows creation fails before authority registration, run reservation or VM effects' $unprivileged
foreach($parameters in @(@{Version='2022';Provider='hyperv'},@{Version='2025';Provider='docker'},
    @{Version='2025';Provider='hyperv';DataRoot='synthetic';TlsClientPlatform='Linux'},
    @{Version='2025';Provider='hyperv';DataRoot='synthetic';Manifest='synthetic'},
    @{Version='2025';Provider='hyperv';DataRoot='synthetic';AutoStart='on'})){
    Add-CheckResult 'Unsupported Windows selection rejects before provider or authority effects' (Reject-WindowsTls {New-LabAuthenticatedTlsWindowsEnvironment $parameters})
}
if(-not $IsWindows){Write-Host 'Windows native ACL fixture: NOT_EXECUTED';if($failures.Count){exit 1};return}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-windows-tls-'+[guid]::NewGuid().ToString('N'))
$caKey=$null;$leafKey=$null;$ca=$null;$leaf=$null
try{
    $native=Get-LabTlsWindowsProcessFacts
    Initialize-LabTlsCaPrivateDirectory $fixture $native.UserSid -NewOnly
    $caKey=[Security.Cryptography.RSA]::Create(3072);$leafKey=[Security.Cryptography.RSA]::Create(3072)
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Contoso Offline TLS CA',$caKey,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
    $ca=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5),[DateTimeOffset]::UtcNow.AddDays(2));$caDer=$ca.RawData
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=CONTOSO-SQL',$leafKey,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $san=[Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new();$san.AddIpAddress([Net.IPAddress]::Loopback);$request.CertificateExtensions.Add($san.Build())
    $leaf=$request.Create($ca,[DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddHours(1),[byte[]](1..16))
    $record=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsWindowsLab/0.1';AuditId='11111111-1111-4111-8111-111111111111';
        DataRoot=$fixture;StateRoot=$fixture;ControllerId='22222222-2222-4222-8222-222222222222';LocationId='33333333-3333-4333-8333-333333333333';
        AuthorityRef='44444444-4444-4444-8444-444444444444';ClientRef='55555555-5555-4555-8555-555555555555';RegistrySha256=('a'*64);
        RunId='66666666-6666-4666-8666-666666666666';InstanceId='primary';ScopeId='77777777-7777-4777-8777-777777777777';VmId='88888888-8888-4888-8888-888888888888';
        Host='127.0.0.1';Port=14333;SqlVersion='2025';Patch='base';SqlBuild='17.0.1000.7';ComputerName='CONTOSO-SQL';ProcessId=1234;
        StartedAt=[DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o');BootedAt=[DateTimeOffset]::UtcNow.AddMinutes(-3).ToString('o');
        CertificateSha256=(Get-LabTlsCaByteDigest $leaf.RawData);CertificateDer=[Convert]::ToBase64String($leaf.RawData);CertificateThumbprint=$leaf.Thumbprint;
        NotAfterUtc=([DateTimeOffset]$leaf.NotAfter.ToUniversalTime()).ToString('o');KeyContainer='SQLServerLab-TLS-Renew-11111111-1111-4111-8111-111111111111';
        KeyModulus=[Convert]::ToBase64String($leafKey.ExportParameters($false).Modulus);CertreqSha256=('B'*64)}
    $originalRecord=ConvertTo-LabTlsRegistryWriterBytes $record
    Add-CheckResult 'Closed Windows record accepts actual matching RSA3072 certificate bytes' ((Read-LabTlsWindowsRecord $originalRecord).VmId -ceq $record.VmId)
    foreach($change in @(@{name='VmId';value='not-a-guid'},@{name='ContractVersion';value='SqlServerLab.AuthenticatedTlsLab/0.2'},
        @{name='SqlBuild';value='17.0.5005.3'},@{name='Port';value='14333'},@{name='ProcessId';value=$true},@{name='BootedAt';value='yesterday'},
        @{name='RegistrySha256';value='bad'},@{name='Host';value='localhost'},@{name='KeyContainer';value='foreign'},
        @{name='CertificateThumbprint';value=('0'*40)},@{name='CertificateSha256';value=('0'*64)},@{name='KeyModulus';value='AQAB'})){
        $candidate=Read-LabTlsBoundJson $originalRecord @($record.PSObject.Properties.Name);$candidate.($change.name)=$change.value
        Add-CheckResult ('Windows record rejects '+$change.name) (Reject-WindowsTls {Read-LabTlsWindowsRecord (ConvertTo-LabTlsRegistryWriterBytes $candidate)})
    }
    $candidate=Read-LabTlsBoundJson $originalRecord @($record.PSObject.Properties.Name);$candidate|Add-Member Extra $true
    Add-CheckResult 'Windows record rejects unrecognized fields' (Reject-WindowsTls {Read-LabTlsWindowsRecord (ConvertTo-LabTlsRegistryWriterBytes $candidate)})
    $authority=[pscustomobject]@{Native=$native;RegistrySha256=$record.RegistrySha256;ActorDigest=('c'*64);RootDigest=('d'*64);
        Authority=[pscustomobject]@{Ref=$record.AuthorityRef;Generation=1;TrustScopeRef='99999999-9999-4999-8999-999999999999';CandidateId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';CertificateSha256=(Get-LabTlsCaByteDigest $caDer)};
        Client=[pscustomobject]@{Ref=$record.ClientRef;Generation=1;Details=[pscustomobject]@{SqlClientDiskSha256=('e'*64);SqlClientLoadedMvid='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';SqlcmdDiskSha256=('f'*64)}}}
    $script:observations=0;$script:drift=$false;$script:clientCalls=[Collections.Generic.List[string]]::new()
    function Get-LabTlsWindowsOwnBinding {param($StateRoot,$RunId,$InstanceId) [pscustomobject]@{Record=$record;Authority=$authority;Bytes=$originalRecord;StateRoot=$fixture}}
    function Get-LabTlsOwnBinding {param($StateRoot,$RunId,$InstanceId) Get-LabTlsWindowsOwnBinding $StateRoot $RunId $InstanceId}
    function Assert-LabTlsWindowsCertificateBinding {param($Bound,$Budget) $script:observations++;if($script:drift){throw 'SYNTHETIC_VM_DRIFT'};[pscustomobject]@{Directory=$fixture}}
    function Assert-LabTlsSqlCertificateBinding {param($Record,$StateRoot,$Budget) Assert-LabTlsWindowsCertificateBinding (Get-LabTlsOwnBinding $StateRoot $Record.RunId $Record.InstanceId) $Budget}
    function Get-LabTlsWindowsSqlSecret {param($RunDirectory) New-SyntheticWindowsTlsSecret}
    function Invoke-LabTlsStrictSqlClient {param($Port,$Password,$ExpectedBuild,$HostName) $script:clientCalls.Add("SqlClient|$HostName|$Port|$ExpectedBuild")}
    function Invoke-LabTlsStrictSqlcmd {param($Port,$Password,$Client,$ExpectedBuild,$HostName) $script:clientCalls.Add("ODBC|$HostName|$Port|$ExpectedBuild");[pscustomobject]@{SqlcmdSha256=('f'*64);LoadedOdbcSha256=('1'*64);LoadedOdbcBytes=4096}}
    function Get-LabTlsCaCandidateBinding {param($DataRoot,$ControllerId,$LocationId,$CandidateId) [pscustomobject]@{Der=$caDer;Encrypted=@(1);RootMetadataDigest=('d'*64);ActorDigest=('c'*64)}}
    function Open-LabTlsCaSigningKey {param($Encrypted,$Entropy,$Der) $copy=[Security.Cryptography.RSA]::Create();$copy.ImportParameters($caKey.ExportParameters($true));$copy}
    function Get-LabTlsCaExistingTrust {param($Der) if((Get-LabTlsCaByteDigest $Der) -ceq (Get-LabTlsCaByteDigest $caDer)){'IDENTICAL_PREEXISTING_NOT_OWNED'}else{'ABSENT'}}
    $out=Export-LabAuthenticatedTlsEnvironment (Join-Path $fixture 'export') $fixture $record.RunId primary
    Add-CheckResult 'Windows qualification runs both explicit strict client delegates with the exact endpoint/build' ($script:clientCalls.Count -eq 2 -and $script:clientCalls[0] -ceq 'SqlClient|127.0.0.1|14333|17.0.1000.7' -and $script:clientCalls[1] -ceq 'ODBC|127.0.0.1|14333|17.0.1000.7')
    $bytes=[IO.File]::ReadAllBytes($out.JsonPath)
    $snapshot=Read-SqlServerLabQualifiedTestEnvironment -ExportBytes $bytes -StateRoot $fixture -RunId $record.RunId -InstanceId primary
    Add-CheckResult 'Actual signed Windows V2 exporter and public same-byte reader round-trip' ($snapshot.Contract.environments[0].platform -ceq 'windows' -and $snapshot.Qualification.VmId -ceq $record.VmId -and $snapshot.Qualification.ContractVersion -ceq 'SqlServerLab.TlsQualification/0.3' -and $script:observations -ge 5)
    function New-WindowsTamperedExport([string]$Name,[object]$Value,[switch]$Entry){
        $document=Read-LabTlsBoundJson $bytes @('$schema','contractVersion','generatedAt','groupStatus','selectionRule','containsPlainTextSecrets','environments','qualification')
        $payload=Read-LabTlsBoundJson ([Convert]::FromBase64String($document.qualification.payload)) @('ContractVersion','EnvironmentSha256','Qualification')
        if($Entry){$document.environments[0].$Name=$Value;$payload.EnvironmentSha256=Get-LabTlsCaByteDigest (ConvertTo-LabTlsRegistryWriterBytes $document.environments[0])}else{$payload.Qualification.$Name=$Value}
        $signed=ConvertTo-LabTlsRegistryWriterBytes $payload;$document.qualification.payload=[Convert]::ToBase64String($signed)
        $document.qualification.signature=[Convert]::ToBase64String($caKey.SignData($signed,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1))
        return ,(ConvertTo-LabTlsRegistryWriterBytes $document)
    }
    foreach($change in @(@{name='VmId';value='cccccccc-cccc-4ccc-8ccc-cccccccccccc'},@{name='BootedAt';value=[DateTimeOffset]::UtcNow.ToString('o')},
        @{name='ProcessId';value=9999},@{name='TrustServerCertificate';value=$true},@{name='Provider';value='docker'},@{name='RootDigest';value=('0'*64)},
        @{name='ClientGeneration';value=2},@{name='LeafSha256';value=('0'*64)},@{name='ContractVersion';value='SqlServerLab.TlsQualification/0.1'},
        @{name='ExpiresAt';value=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')},@{name='QualifiedAt';value=[DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o')})){
        $tampered=New-WindowsTamperedExport $change.name $change.value
        Add-CheckResult ('Correctly signed Windows export rejects '+$change.name) (Reject-WindowsTls {Read-SqlServerLabQualifiedTestEnvironment -ExportBytes $tampered -StateRoot $fixture -RunId $record.RunId -InstanceId primary})
    }
    foreach($change in @(@{name='platform';value='linux'},@{name='host';value='127.0.0.2'},@{name='runId';value='dddddddd-dddd-4ddd-8ddd-dddddddddddd'},@{name='database';value='synthetic-other'})){
        $tampered=New-WindowsTamperedExport $change.name $change.value -Entry
        Add-CheckResult ('Correctly signed Windows export rejects entry '+$change.name) (Reject-WindowsTls {Read-SqlServerLabQualifiedTestEnvironment -ExportBytes $tampered -StateRoot $fixture -RunId $record.RunId -InstanceId primary})
    }
    $script:drift=$true
    Add-CheckResult 'Fresh native VM/service drift rejects an otherwise valid signed snapshot' (Reject-WindowsTls {Read-SqlServerLabQualifiedTestEnvironment -ExportBytes $bytes -StateRoot $fixture -RunId $record.RunId -InstanceId primary})
    $script:drift=$false
    $q=$snapshot.Qualification;$started=[DateTimeOffset]::Parse($q.QualifiedAt).AddSeconds(-1)
    $live=ConvertTo-LabTlsLiveQualificationResult $q $record.RunId primary $started ([DateTimeOffset]::UtcNow)
    Add-CheckResult 'Public live projection accepts only the separate Windows profile' ($live.Provider -ceq 'hyperv' -and $live.SqlBuild -ceq '17.0.1000.7' -and -not $live.PSObject.Properties['VmId'])
    # Ergebnis-/Endebindung vor einer späteren VM-Entfernung: kein Retry bei
    # unbekanntem Transportende und keine Verwechslung mit einem bestätigten
    # beendeten Gastfehler. Die echten Guestscriptbytes laufen nur nativ.
    $context=[pscustomobject]@{Run=[pscustomobject]@{runId=$record.RunId;scopeId=$record.ScopeId};StateRoot=$fixture;Directory=$fixture;
        Fingerprint='synthetic-fixed';Instance=[pscustomobject]@{vmName='Contoso';vmId=$record.VmId}}
    $script:guestMode='ended-failure';$script:guestDispatches=0
    function Get-LabSsisPrerequisiteContext {param($RunId,$InstanceId,$StateRoot) $context}
    function Get-LabSecret {param($Path,$Name) New-SyntheticWindowsTlsSecret}
    function Invoke-HyperVPowerShellDirect {
        param($VMName,$ExpectedRunId,$ExpectedScopeId,$ExpectedVmId,$Credential,[switch]$NoRetry,$TimeoutSeconds,$ScriptBlock,$ArgumentList)
        $script:guestDispatches++
        if(-not $NoRetry -or $TimeoutSeconds -ne 120){throw 'SYNTHETIC_DISPATCH_CONTRACT'}
        if($script:guestMode -ceq 'transport-unknown'){throw 'SYNTHETIC_LOST_REPLY'}
        [pscustomobject]@{Success=$false;ConsumerEnded=($script:guestMode -ceq 'ended-failure')}
    }
    $known=$false
    try{Invoke-LabTlsWindowsGuest $context {} @() (New-LabTlsWindowsBudget)}catch{$known=$_.Exception.Data['ConsumerEnded'] -eq $true}
    Add-CheckResult 'Confirmed ended guest failure carries explicit safe cleanup evidence with one dispatch' ($known -and $script:guestDispatches -eq 1)
    foreach($mode in @('transport-unknown','guest-end-unknown')){
        $script:guestMode=$mode;$script:guestDispatches=0;$unknown=$false
        try{Invoke-LabTlsWindowsGuest $context {} @() (New-LabTlsWindowsBudget)}catch{$unknown=$_.Exception.Data['ConsumerEnded'] -ne $true}
        Add-CheckResult ('Unconfirmed guest end stays recovery-required without retry: '+$mode) ($unknown -and $script:guestDispatches -eq 1)
    }
    $budget=New-LabTlsWindowsBudget;$budget.Commands=60;$script:guestDispatches=0
    Add-CheckResult 'Exhausted Windows guest budget rejects before dispatch' ((Reject-WindowsTls {Invoke-LabTlsWindowsGuest $context {} @() $budget}) -and $script:guestDispatches -eq 0)
}catch{Add-CheckResult ('Windows fixture: '+$_.Exception.Message) $false;Write-Host $_.ScriptStackTrace;$Error|Select-Object -First 3|ForEach-Object{Write-Host $_.Exception.Message;Write-Host $_.ScriptStackTrace}}
finally{
    foreach($item in @($leaf,$ca,$leafKey,$caKey)){if($item){$item.Dispose()}}
    if(Test-Path -LiteralPath $fixture){
        $path=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $path.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($path) -cnotmatch '^sql-lab-windows-tls-[0-9a-f]{32}$'){throw 'FIXTURE_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $path -Recurse -Force
        Add-CheckResult 'Only the own offline key/export fixture removed' (-not(Test-Path -LiteralPath $path))
    }
}
Write-Host "Windows TLS: $passed PASS / $($failures.Count) FAIL"
if($failures.Count){exit 1}
