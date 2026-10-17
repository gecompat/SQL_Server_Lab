#Requires -Version 7.5
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force
foreach($name in @('DiagnosticBundleReader','AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsRegistryPayload','AuthenticatedTlsCaCandidate',
    'AuthenticatedTlsContext','AuthenticatedTlsRegistryRoot','AuthenticatedTlsRegistryWriter','AuthenticatedTlsLab','AuthenticatedTlsQualification','SqlReadiness')){. (Join-Path $repo "Private/$name.ps1")}
. (Join-Path $repo 'Public/TestEnvironment.ps1')
$script:ModuleRoot=$repo
function Test-TlsLabReject {param([scriptblock]$Action) try{& $Action|Out-Null;return $false}catch{return $true}}
Add-CheckResult 'Native executor requires an explicit operation budget' (Test-TlsLabReject {Invoke-LabTlsDocker @('never-executed')})
$budget=New-LabTlsDockerBudget;$budget.Commands=100
Add-CheckResult 'Command ceiling rejects before native process start' (Test-TlsLabReject {Invoke-LabTlsDocker @('never-executed') -Budget $budget})
$budget=New-LabTlsDockerBudget;$budget.DeadlineUtc=[datetime]::UtcNow.AddSeconds(-1)
Add-CheckResult 'Time ceiling rejects before native process start' (Test-TlsLabReject {Invoke-LabTlsDocker @('never-executed') -Budget $budget})
$other=New-LabTlsDockerBudget
Add-CheckResult 'Independent operations retain separate counters and deadlines' ($other.Commands -eq 0 -and $other.DeadlineUtc -gt [datetime]::UtcNow -and $budget.Commands -eq 1)
foreach($json in @('{"x":1,"X":2}','{"x":{"a":1,"A":2}}','{"x":1,}','{"x":/*comment*/1}','{"x":1,"y":2}')){
    Add-CheckResult 'Bound JSON rejects duplicate/alias/comment/trailing/unknown fields' (Test-TlsLabReject {Read-LabTlsBoundJson ([Text.Encoding]::UTF8.GetBytes($json)) @('x')})
}
$roundtrip=Read-LabTlsBoundJson ([Text.Encoding]::UTF8.GetBytes('{"flag":false,"at":"2026-10-17T12:00:00.0000000Z"}')) @('flag','at')
Add-CheckResult 'Bound JSON preserves false boolean and UTC text' ($roundtrip.flag -is [bool] -and -not $roundtrip.flag -and $roundtrip.at -is [string])
Add-CheckResult 'Bound JSON has a byte limit' (Test-TlsLabReject {Read-LabTlsBoundJson ([byte[]]::new(65537)) @('x')})
foreach($parameters in @(@{Version='2025-CU9';DataRoot='x';Provider='podman'},@{Version='2022:cu27';DataRoot='x'},@{Version='2025-CU9';DataRoot='x';StateRoot='x'},@{Version='2025-CU9';DataRoot='x'})){
    Add-CheckResult 'Unsupported or incomplete false selection rejected before runtime' (Test-TlsLabReject {New-LabAuthenticatedTlsEnvironment $parameters})
}
$ordinary=Get-Content (Join-Path $repo 'Schemas/test-environment.schema.json') -Raw|ConvertFrom-Json -Depth 20
$strict=Get-Content (Join-Path $repo 'Schemas/test-environment-authenticated.schema.json') -Raw|ConvertFrom-Json -Depth 20
Add-CheckResult 'V1 true default and separate V2 false contract coexist' ($ordinary.properties.contractVersion.const -ceq 'SqlServerLab.TestEnvironment/1.0' -and $ordinary.'$defs'.environment.properties.trustServerCertificate.const -eq $true -and $strict.properties.contractVersion.const -ceq 'SqlServerLab.TestEnvironment/2.0' -and $strict.'$defs'.environment.properties.trustServerCertificate.const -eq $false)

if($IsWindows){
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-qualified-'+[guid]::NewGuid().ToString('N'))
    $rsa=$null;$certificate=$null
    try{
        $null=New-Item -ItemType Directory -Path $fixture
        $native=Get-LabTlsWindowsProcessFacts
        $rsa=[Security.Cryptography.RSA]::Create(3072)
        $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Synthetic TLS export fixture',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddDays(1))
        $der=$certificate.RawData;$caHash=Get-LabTlsCaByteDigest $der
        $record=[pscustomobject]@{RunId='synthetic-run';InstanceId='primary';ScopeId='synthetic-scope';ContainerId=('a'*64);ImageId=('sha256:'+('b'*64));Port=14333;StartedAt='synthetic-start';CertificateSha256=$caHash;DataRoot=$fixture;ControllerId='11111111-1111-4111-8111-111111111111';LocationId='22222222-2222-4222-8222-222222222222'}
        $authority=[pscustomobject]@{Native=$native;RegistrySha256=('c'*64);ActorDigest=('d'*64);RootDigest=('e'*64);
            Authority=[pscustomobject]@{Ref='33333333-3333-4333-8333-333333333333';Generation=1;TrustScopeRef='44444444-4444-4444-8444-444444444444';CandidateId='55555555-5555-4555-8555-555555555555';CertificateSha256=$caHash};
            Client=[pscustomobject]@{Ref='66666666-6666-4666-8666-666666666666';Generation=1;Details=[pscustomobject]@{SqlClientDiskSha256=('1'*64);SqlcmdDiskSha256=('2'*64)}}}
        function Get-LabTlsOwnBinding {param($StateRoot,$RunId,$InstanceId) $null=$StateRoot,$RunId,$InstanceId;[pscustomobject]@{Record=$record;Authority=$authority}}
        function Assert-LabTlsOwnContainer {param($Record,$StateRoot) $null=$Record,$StateRoot;[pscustomobject]@{RunDirectory=$fixture}}
        function Assert-LabTlsSqlCertificateBinding {param($Record,$StateRoot) $null=$Record,$StateRoot}
        function Get-LabSecret {
            param($Path,$Name) $null=$Path,$Name
            $secure=[securestring]::new();foreach($character in 'Synthetic-Only-8472!'.ToCharArray()){$secure.AppendChar($character)}
            $secure.MakeReadOnly();return $secure
        }
        function Get-LabTlsCaCandidateBinding {param($DataRoot,$ControllerId,$LocationId,$CandidateId) $null=$DataRoot,$ControllerId,$LocationId,$CandidateId;[pscustomobject]@{Der=$der;Encrypted=@(1);RootMetadataDigest=('e'*64);ActorDigest=('d'*64)}}
        function Open-LabTlsCaSigningKey {param($Encrypted,$Entropy,$Der) $null=$Encrypted,$Entropy,$Der; $copy=[Security.Cryptography.RSA]::Create();$copy.ImportParameters($rsa.ExportParameters($true));return $copy}
        function Get-LabTlsCaExistingTrust {param($Der) if((Get-LabTlsCaByteDigest $Der) -ceq $caHash){'IDENTICAL_PREEXISTING_NOT_OWNED'}else{'ABSENT'}}
        function Test-LabAuthenticatedTlsEnvironment {
            param($RunId,$InstanceId,$StateRoot) $null=$StateRoot
            [pscustomobject]@{Status='QUALIFIED';QualifiedAt=[DateTimeOffset]::UtcNow.ToString('O');ExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(14).ToString('O');RunId=$RunId;InstanceId=$InstanceId;
                ContainerId=$record.ContainerId;ScopeId=$record.ScopeId;ImageId=$record.ImageId;StartedAt=$record.StartedAt;RegistrySha256=$authority.RegistrySha256;ActorDigest=$authority.ActorDigest;
                AuthorityRef=$authority.Authority.Ref;ClientRef=$authority.Client.Ref;AuthorityGeneration=1;ClientGeneration=1;TrustScopeRef=$authority.Authority.TrustScopeRef;
                SqlClientSha256=$authority.Client.Details.SqlClientDiskSha256;SqlcmdSha256=$authority.Client.Details.SqlcmdDiskSha256;LeafSha256=$record.CertificateSha256;Endpoint=[pscustomobject]@{Port=$record.Port;Host='127.0.0.1'}}
        }
        # Exercise the actual exporter, signing, protected files and verifier. Runtime
        # observations are synthetic here; the integration lane supplies real SQL.
        $out=Export-LabAuthenticatedTlsEnvironment (Join-Path $fixture 'export') $fixture $record.RunId $record.InstanceId
        $original=[IO.File]::ReadAllBytes($out.JsonPath)
        Add-CheckResult 'Actual RSA-signed V2 export reads back under private ACL' (Test-LabTlsQualifiedExport $out.JsonPath $fixture $record.RunId $record.InstanceId)
        Add-CheckResult 'V2 export validates against its copied schema' (Test-Json -Json ([Text.Encoding]::UTF8.GetString($original)) -SchemaFile $out.SchemaPath)
        Add-CheckResult 'All five explicit export formats exist' (@('TestUmgebung.json','TestUmgebung.schema.json','TestUmgebung.env','TestUmgebung.md','TestUmgebung.prompt.md'|Where-Object {-not (Test-Path -LiteralPath (Join-Path $out.Directory $_))}).Count -eq 0)
        foreach($field in @('signature','trustFlag','password','run','ca')){
            $bad=[Text.Encoding]::UTF8.GetString($original)|ConvertFrom-Json -Depth 12 -DateKind String
            switch($field){
                signature {$bad.qualification.signature=[Convert]::ToBase64String([byte[]]::new(384))}
                trustFlag {$bad.environments[0].trustServerCertificate=$true}
                password {$bad.environments[0].password='changed'}
                run {$bad.environments[0].runId='other'}
                ca {$bad.qualification.caDer=[Convert]::ToBase64String([byte[]]@(1))}
            }
            [IO.File]::WriteAllBytes($out.JsonPath,(ConvertTo-LabTlsRegistryWriterBytes $bad))
            $rejected=$false;try{$rejected=-not (Test-LabTlsQualifiedExport $out.JsonPath $fixture $record.RunId $record.InstanceId)}catch{$rejected=$true}
            Add-CheckResult "Signed export rejects changed $field" $rejected
        }
        [IO.File]::WriteAllBytes($out.JsonPath,$original)
        Add-CheckResult 'Existing export cannot be overwritten' (Test-TlsLabReject {Export-LabAuthenticatedTlsEnvironment $out.Directory $fixture $record.RunId $record.InstanceId})
        # Exercise the creator's complete orchestration with explicitly synthetic
        # provider observations. These assertions guard the two review findings;
        # they do not claim native SQL or host-autostart acceptance.
        $script:capturedAutoStart=$null;$script:writtenConnection=$null
        $authority.Authority|Add-Member -NotePropertyName NotAfterUtc -NotePropertyValue ([datetime]::UtcNow.AddDays(3).ToString('O'))
        function Register-LabTlsOperationalAuthority {param($DataRoot,$ControllerId,$LocationId,$CandidateId) $null=$DataRoot,$ControllerId,$LocationId,$CandidateId;return $authority}
        function Invoke-LabTlsDocker {param($Arguments,$InputText) $null=$InputText;if($Arguments -contains 'base64'){return 'AQ=='};return ''}
        function New-SqlServerLab {
            param($StateRoot,$Provider,$Version,$InstanceId,$AutoStart)
            $null=$Provider,$Version;$script:capturedAutoStart=$AutoStart
            [pscustomobject]@{RunId='synthetic-run';StateRoot=$StateRoot;Instances=@([pscustomobject]@{Id=$InstanceId;ConnectionString='Server=127.0.0.1,14333;Encrypt=True;TrustServerCertificate=True;Password=***'})}
        }
        function Get-LabTlsOwnedRuntimeContext {
            param($RunId,$StateRoot) $null=$RunId
            [pscustomobject]@{Run=[pscustomobject]@{scopeId='synthetic-scope'};ContainerId=('a'*64);CurrentPort=14333;Inspect=[pscustomobject]@{Image=('sha256:'+('b'*64));State=[pscustomobject]@{StartedAt='synthetic-start'}};
                Instance=[pscustomobject]@{connectionString='Server=127.0.0.1,14333;Encrypt=True;TrustServerCertificate=True;Password=***'};Connection=[pscustomobject]@{};ConnectionPath=(Join-Path $StateRoot 'synthetic.json')}
        }
        function Assert-LabTlsOwnContainer {param($Record,$StateRoot) Get-LabTlsOwnedRuntimeContext $Record.RunId $StateRoot}
        function New-LabAuthenticatedTlsServerLeaf {param($DataRoot,$ControllerId,$LocationId,$Context,$CandidateId,$CsrDer,$Identity,$ValidityDays)
            $null=$DataRoot,$ControllerId,$LocationId,$Context,$CandidateId,$CsrDer,$Identity,$ValidityDays
            [pscustomobject]@{Success=$true;Value=[pscustomobject]@{CertificateDer=$der;CertificateSha256=$caHash;NotAfterUtc=[datetime]::UtcNow.AddDays(1).ToString('O')}}}
        function Stop-SqlServerLab {
            [CmdletBinding(SupportsShouldProcess)]
            param($RunId,$StateRoot,[switch]$Force,[switch]$SkipHostMemoryRelease)
            $null=$RunId,$StateRoot,$Force,$SkipHostMemoryRelease
        }
        function Start-SqlServerLab {param($RunId,$StateRoot) $null=$RunId,$StateRoot}
        function Write-LabArtifactJsonAtomic {param($Path,$InputObject) $null=$Path,$InputObject}
        $created=New-LabAuthenticatedTlsEnvironment @{Version='2025-CU9';DataRoot=$fixture;TlsControllerId=$record.ControllerId;TlsLocationId=$record.LocationId;TlsCandidateId=$authority.Authority.CandidateId}
        $settings=[Data.SqlClient.SqlConnectionStringBuilder]::new($created.Instances[0].ConnectionString)
        Add-CheckResult 'Creator returns explicit true/false in the actual public run DTO' ($settings.Encrypt -and -not $settings.TrustServerCertificate)
        Add-CheckResult 'Creator delegates only autostart off and rejects on' ($script:capturedAutoStart -ceq 'off' -and (Test-TlsLabReject {New-LabAuthenticatedTlsEnvironment @{Version='2025-CU9';DataRoot=$fixture;AutoStart='on'}}))
    }catch{Add-CheckResult ('Qualified export fixture failed: '+$_.Exception.Message) $false;Write-Host $_.ScriptStackTrace; $Error|Select-Object -First 3|ForEach-Object {Write-Host $_.Exception.Message}}
    finally{
        if($certificate){$certificate.Dispose()};if($rsa){$rsa.Dispose()}
        if(Test-Path -LiteralPath $fixture){
            $resolved=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^sql-lab-qualified-[0-9a-f]{32}$'){throw 'FIXTURE_CLEANUP_SCOPE_INVALID'}
            Remove-Item -LiteralPath $resolved -Recurse -Force
            Add-CheckResult 'Own signed export/key fixtures fully removed' (-not (Test-Path -LiteralPath $resolved))
        }
    }
}else{Write-Host 'Native signed export ACL fixture: NOT_EXECUTED (Windows required)'}
Write-Host "TLS Lab: $passed PASS / $($failures.Count) FAIL"
if($failures.Count){exit 1}
