#Requires -Version 7.5
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force
foreach($name in @('DiagnosticBundleReader','AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsRegistryPayload','AuthenticatedTlsCaCandidate',
    'AuthenticatedTlsContext','AuthenticatedTlsRegistryRoot','AuthenticatedTlsRegistryWriter','AuthenticatedTlsLab','AuthenticatedTlsQualification','AuthenticatedTlsRestartRebind','AuthenticatedTlsRebindRecovery','SqlReadiness')){. (Join-Path $repo "Private/$name.ps1")}
. (Join-Path $repo 'Public/TestEnvironment.ps1')
. (Join-Path $repo 'Public/Read-SqlServerLabQualifiedTestEnvironment.ps1')
$script:ModuleRoot=$repo
function Test-TlsLabReject {param([scriptblock]$Action) try{& $Action|Out-Null;return $false}catch{return $true}}
Add-CheckResult 'Native executor requires an explicit operation budget' (Test-TlsLabReject {Invoke-LabTlsContainer @('never-executed')})
$budget=New-LabTlsRuntimeBudget;$budget.Commands=100
Add-CheckResult 'Command ceiling rejects before native process start' (Test-TlsLabReject {Invoke-LabTlsContainer @('never-executed') -Budget $budget})
$budget=New-LabTlsRuntimeBudget;$budget.DeadlineUtc=[datetime]::UtcNow.AddSeconds(-1)
Add-CheckResult 'Time ceiling rejects before native process start' (Test-TlsLabReject {Invoke-LabTlsContainer @('never-executed') -Budget $budget})
$other=New-LabTlsRuntimeBudget
Add-CheckResult 'Independent operations retain separate counters and deadlines' ($other.Commands -eq 0 -and $other.DeadlineUtc -gt [datetime]::UtcNow -and $budget.Commands -eq 1)
foreach($json in @('{"x":1,"X":2}','{"x":{"a":1,"A":2}}','{"x":1,}','{"x":/*comment*/1}','{"x":1,"y":2}')){
    Add-CheckResult 'Bound JSON rejects duplicate/alias/comment/trailing/unknown fields' (Test-TlsLabReject {Read-LabTlsBoundJson ([Text.Encoding]::UTF8.GetBytes($json)) @('x')})
}
$roundtrip=Read-LabTlsBoundJson ([Text.Encoding]::UTF8.GetBytes('{"flag":false,"at":"2026-10-17T12:00:00.0000000Z"}')) @('flag','at')
Add-CheckResult 'Bound JSON preserves false boolean and UTC text' ($roundtrip.flag -is [bool] -and -not $roundtrip.flag -and $roundtrip.at -is [string])
Add-CheckResult 'Bound JSON has a byte limit' (Test-TlsLabReject {Read-LabTlsBoundJson ([byte[]]::new(65537)) @('x')})
foreach($parameters in @(@{Version='2025-CU9';DataRoot='x';Provider='hyperv'},@{Version='2022:cu27';DataRoot='x'},@{Version='2025-CU9';DataRoot='x';StateRoot='x'},@{Version='2025-CU9';DataRoot='x'})){
    Add-CheckResult 'Unsupported or incomplete false selection rejected before runtime' (Test-TlsLabReject {New-LabAuthenticatedTlsEnvironment $parameters})
}
$ordinary=Get-Content (Join-Path $repo 'Schemas/test-environment.schema.json') -Raw|ConvertFrom-Json -Depth 20
$strict=Get-Content (Join-Path $repo 'Schemas/test-environment-authenticated.schema.json') -Raw|ConvertFrom-Json -Depth 20
Add-CheckResult 'V1 true default and separate V2 false contract coexist' ($ordinary.properties.contractVersion.const -ceq 'SqlServerLab.TestEnvironment/1.0' -and $ordinary.'$defs'.environment.properties.trustServerCertificate.const -eq $true -and $strict.properties.contractVersion.const -ceq 'SqlServerLab.TestEnvironment/2.0' -and $strict.'$defs'.environment.properties.trustServerCertificate.const -eq $false)
. (Join-Path $PSScriptRoot 'Fixtures/AuthenticatedTlsLabProviderChecks.ps1')
. (Join-Path $PSScriptRoot 'Fixtures/AuthenticatedTlsLabVersionChecks.ps1')

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
        $record=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.1';RunId='synthetic-run';InstanceId='primary';ScopeId='synthetic-scope';ContainerId=('a'*64);ImageId=('sha256:'+('b'*64));Port=14333;StartedAt='synthetic-start';CertificateSha256=$caHash;DataRoot=$fixture;ControllerId='11111111-1111-4111-8111-111111111111';LocationId='22222222-2222-4222-8222-222222222222'}
        $authority=[pscustomobject]@{Native=$native;RegistrySha256=('c'*64);ActorDigest=('d'*64);RootDigest=('e'*64);
            Authority=[pscustomobject]@{Ref='33333333-3333-4333-8333-333333333333';Generation=1;TrustScopeRef='44444444-4444-4444-8444-444444444444';CandidateId='55555555-5555-4555-8555-555555555555';CertificateSha256=$caHash};
            Client=[pscustomobject]@{Ref='66666666-6666-4666-8666-666666666666';Generation=1;Details=[pscustomobject]@{SqlClientDiskSha256=('1'*64);SqlcmdDiskSha256=('2'*64)}}}
        $script:rejectBindingAfterObservation=$false;$script:changeRecordDuringObservation=$false
        function Get-LabTlsOwnBinding {
            param($StateRoot,$RunId,$InstanceId) $null=$StateRoot,$RunId,$InstanceId
            if($script:rejectBindingAfterObservation -and $script:certificateObservations -gt $script:bindingObservationStart){throw 'SYNTHETIC_AUTHORITY_TRUST_DRIFT'}
            [pscustomobject]@{Record=$record;Authority=$authority;Bytes=(ConvertTo-LabTlsRegistryWriterBytes $record)}
        }
        function Assert-LabTlsOwnContainer {param($Record,$StateRoot) $null=$Record,$StateRoot;[pscustomobject]@{RunDirectory=$fixture}}
        $script:certificateObservations=0
        function Assert-LabTlsSqlCertificateBinding {
            param($Record,$StateRoot) $null=$Record,$StateRoot;$script:certificateObservations++
            if($script:changeRecordDuringObservation){$record.StartedAt='changed-during-observation'}
        }
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
            $profile=Get-LabTlsBindingSqlProfile $record
            [pscustomobject]@{Status='QUALIFIED';Provider=(Get-LabTlsBindingProvider $record);SqlVersion=$profile.SqlVersion;Patch=$profile.Patch;SqlBuild=$profile.SqlBuild;QualifiedAt=[DateTimeOffset]::UtcNow.ToString('O');ExpiresAt=[DateTimeOffset]::UtcNow.AddMinutes(14).ToString('O');RunId=$RunId;InstanceId=$InstanceId;
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
        $script:originalPrivateReader=(Get-Command Read-LabTlsCaPrivateFile).ScriptBlock
        $script:privateFileReads=0
        function Read-LabTlsCaPrivateFile {
            param($Path,$UserSid,$MaximumBytes)
            $script:privateFileReads++
            return ,([byte[]](& $script:originalPrivateReader $Path $UserSid $MaximumBytes))
        }
        $snapshot=Read-SqlServerLabQualifiedTestEnvironment -Path $out.JsonPath -StateRoot $fixture -RunId $record.RunId -InstanceId $record.InstanceId
        Add-CheckResult 'Public V2 reader returns the once-read signed snapshot, not a Boolean/path ticket' ($script:privateFileReads -eq 1 -and
            $snapshot.ContractVersion -ceq 'SqlServerLab.QualifiedTestEnvironmentSnapshot/0.1' -and $snapshot.ExportSha256 -ceq (Get-LabTlsCaByteDigest $original) -and
            $snapshot.Contract.environments[0].password -ceq 'Synthetic-Only-8472!' -and [Convert]::ToBase64String($snapshot.ExportBytes) -ceq [Convert]::ToBase64String($original))
        [IO.File]::WriteAllText($out.JsonPath,'{"replaced":"PRIVATE_SNAPSHOT_CANARY"}')
        $snapshot.Contract.environments[0].password='untrusted-in-memory-change'
        $current=Read-SqlServerLabQualifiedTestEnvironment -ExportBytes $snapshot.ExportBytes -StateRoot $fixture -RunId $record.RunId -InstanceId $record.InstanceId
        Add-CheckResult 'Revalidation uses the same bytes despite replaced path and mutated caller projection' ($script:privateFileReads -eq 1 -and
            $current.ExportSha256 -ceq $snapshot.ExportSha256 -and $current.Contract.environments[0].password -ceq 'Synthetic-Only-8472!')
        Add-CheckResult 'A new path read rejects the substituted document' (Test-TlsLabReject {Read-SqlServerLabQualifiedTestEnvironment -Path $out.JsonPath -StateRoot $fixture -RunId $record.RunId -InstanceId $record.InstanceId})
        [IO.File]::WriteAllBytes($out.JsonPath,$original)
        $savedByte=$snapshot.ExportBytes[0];$snapshot.ExportBytes[0]=0
        Add-CheckResult 'Returned bytearrays do not alias another returned snapshot' ($current.ExportBytes[0] -eq $savedByte)
        Add-CheckResult 'Changed snapshot bytes require fresh validation and are rejected' (Test-TlsLabReject {Read-SqlServerLabQualifiedTestEnvironment -ExportBytes $snapshot.ExportBytes -StateRoot $fixture -RunId $record.RunId -InstanceId $record.InstanceId})
        $snapshot.ExportBytes[0]=$savedByte
        Add-CheckResult 'Oversized consumer bytes reject before private file reads' (Test-TlsLabReject {Read-SqlServerLabQualifiedTestEnvironment -ExportBytes ([byte[]]::new(65537)) -StateRoot $fixture -RunId $record.RunId -InstanceId $record.InstanceId})
        $script:originalExportClock=(Get-Command Get-LabTlsQualifiedExportUtcNow).ScriptBlock
        $script:exportClock=[Collections.Generic.Queue[DateTimeOffset]]::new()
        $script:exportClock.Enqueue([DateTimeOffset]::UtcNow)
        $script:exportClock.Enqueue([DateTimeOffset]::Parse($current.Qualification.ExpiresAt,[Globalization.CultureInfo]::InvariantCulture))
        function Get-LabTlsQualifiedExportUtcNow {if($script:exportClock.Count){return $script:exportClock.Dequeue()};return [DateTimeOffset]::UtcNow}
        $observations=$script:certificateObservations
        Add-CheckResult 'Expiry reached during native observation rejects before returning a snapshot' ((Test-TlsLabReject {Read-SqlServerLabQualifiedTestEnvironment -ExportBytes $current.ExportBytes -StateRoot $fixture -RunId $record.RunId -InstanceId $record.InstanceId}) -and $script:certificateObservations -eq ($observations+1))
        Set-Item Function:Read-LabTlsCaPrivateFile $script:originalPrivateReader
        Set-Item Function:Get-LabTlsQualifiedExportUtcNow $script:originalExportClock
        $originalStartedAt=$record.StartedAt
        try{
            $script:changeRecordDuringObservation=$true
            Add-CheckResult 'Record changed during observation rejects even without rebind history' (Test-TlsLabReject {Read-SqlServerLabQualifiedTestEnvironment -ExportBytes $current.ExportBytes -StateRoot $fixture -RunId $record.RunId -InstanceId $record.InstanceId})
        }finally{$record.StartedAt=$originalStartedAt;$script:changeRecordDuringObservation=$false}
        try{
            $script:bindingObservationStart=$script:certificateObservations;$script:rejectBindingAfterObservation=$true
            Add-CheckResult 'Authority or trust drift detected by the return binding rejects the snapshot' ((Test-TlsLabReject {Read-SqlServerLabQualifiedTestEnvironment -ExportBytes $current.ExportBytes -StateRoot $fixture -RunId $record.RunId -InstanceId $record.InstanceId}) -and $script:certificateObservations -eq ($script:bindingObservationStart+1))
        }finally{$script:rejectBindingAfterObservation=$false}
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
            if($field -ceq 'trustFlag'){
                $schemaFalse=$null;$schemaThrew=$false
                try{$schemaFalse=Test-LabTlsQualifiedExport $out.JsonPath $fixture $record.RunId $record.InstanceId}catch{$schemaThrew=$true}
                Add-CheckResult 'Schema-invalid trust flag preserves private Boolean verifier rejection without throwing' (-not $schemaThrew -and $schemaFalse -is [bool] -and -not $schemaFalse)
            }
            $rejected=$false;try{$rejected=-not (Test-LabTlsQualifiedExport $out.JsonPath $fixture $record.RunId $record.InstanceId)}catch{$rejected=$true}
            Add-CheckResult "Signed export rejects changed $field" $rejected
        }
        [IO.File]::WriteAllBytes($out.JsonPath,$original)
        Add-CheckResult 'Existing export cannot be overwritten' (Test-TlsLabReject {Export-LabAuthenticatedTlsEnvironment $out.Directory $fixture $record.RunId $record.InstanceId})
        $record.ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2'
        $record|Add-Member -NotePropertyName Provider -NotePropertyValue podman
        $podmanExport=Export-LabAuthenticatedTlsEnvironment (Join-Path $fixture 'podman-export') $fixture $record.RunId $record.InstanceId
        $podmanBytes=[IO.File]::ReadAllBytes($podmanExport.JsonPath)
        $podmanDocument=[Text.Encoding]::UTF8.GetString($podmanBytes)|ConvertFrom-Json -Depth 12 -DateKind String
        Add-CheckResult 'Signed Podman export retains its provider and validates copied V2 schema' ($podmanDocument.environments[0].provider -ceq 'podman' -and
            (Test-LabTlsQualifiedExport $podmanExport.JsonPath $fixture $record.RunId $record.InstanceId) -and (Test-Json -Json ([Text.Encoding]::UTF8.GetString($podmanBytes)) -SchemaFile $podmanExport.SchemaPath))
        $body=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($podmanDocument.qualification.payload))|ConvertFrom-Json -Depth 12 -DateKind String
        $body.Qualification.Provider='docker';$bodyBytes=ConvertTo-LabTlsRegistryWriterBytes $body
        $podmanDocument.qualification.payload=[Convert]::ToBase64String($bodyBytes)
        $podmanDocument.qualification.signature=[Convert]::ToBase64String($rsa.SignData($bodyBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1))
        [IO.File]::WriteAllBytes($podmanExport.JsonPath,(ConvertTo-LabTlsRegistryWriterBytes $podmanDocument))
        Add-CheckResult 'Valid CA signature cannot turn Podman qualification into Docker qualification' (-not (Test-LabTlsQualifiedExport $podmanExport.JsonPath $fixture $record.RunId $record.InstanceId))
        [IO.File]::WriteAllBytes($podmanExport.JsonPath,$podmanBytes)
        $record.ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.3'
        $record|Add-Member -NotePropertyName SqlProfileId -NotePropertyValue '2022-CU27'
        foreach($versionCase in @(
            @{Id='2022-CU27';Major='2022';Build='16.0.4295.3';Key='LINUX_SQL2022_CU27_TLS'},
            @{Id='2019-CU32';Major='2019';Build='15.0.4430.1';Key='LINUX_SQL2019_CU32_TLS'})){
        $record.SqlProfileId=$versionCase.Id
        foreach($versionProvider in @('docker','podman')){
            $record.Provider=$versionProvider
            $versionExport=Export-LabAuthenticatedTlsEnvironment (Join-Path $fixture ($versionProvider+'-'+$versionCase.Major)) $fixture $record.RunId $record.InstanceId
            $versionBytes=[IO.File]::ReadAllBytes($versionExport.JsonPath)
            $versionDoc=[Text.Encoding]::UTF8.GetString($versionBytes)|ConvertFrom-Json -Depth 12 -DateKind String
            Add-CheckResult "$versionProvider $($versionCase.Id) export binds build, schema and ENV prefix" ((Test-LabTlsQualifiedExport $versionExport.JsonPath $fixture $record.RunId $record.InstanceId) -and
                (Test-Json -Json ([Text.Encoding]::UTF8.GetString($versionBytes)) -SchemaFile $versionExport.SchemaPath) -and
                $versionDoc.environments[0].resolvedVersion -ceq $versionCase.Build -and (Get-Content -LiteralPath $versionExport.EnvPath -Raw).Contains('SQL_SERVER_LAB_'+$versionCase.Key+'_'))
            foreach($field in @('SqlVersion','Patch','SqlBuild','entryVersion','entryPatch','entryBuild','entryKey','coherentOtherProfile')){
                $bad=[Text.Encoding]::UTF8.GetString($versionBytes)|ConvertFrom-Json -Depth 12 -DateKind String
                $body=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($bad.qualification.payload))|ConvertFrom-Json -Depth 12 -DateKind String
                switch($field){
                    entryVersion {$bad.environments[0].sqlVersion='2025'}
                    entryPatch {$bad.environments[0].patch='cu9'}
                    entryBuild {$bad.environments[0].resolvedVersion='17.0.5005.3'}
                    entryKey {$bad.environments[0].key='LINUX_SQL2025_CU9_TLS'}
                    coherentOtherProfile {
                        $otherProfile=if($versionCase.Major -ceq '2019'){Get-LabTlsSqlProfile '2022-CU27'}else{Get-LabTlsSqlProfile '2019-CU32'}
                        $bad.environments[0].sqlVersion=$otherProfile.SqlVersion;$bad.environments[0].patch=$otherProfile.Patch
                        $bad.environments[0].resolvedVersion=$otherProfile.SqlBuild;$bad.environments[0].key=$otherProfile.ExportKey
                        $body.Qualification.SqlVersion=$otherProfile.SqlVersion;$body.Qualification.Patch=$otherProfile.Patch;$body.Qualification.SqlBuild=$otherProfile.SqlBuild
                    }
                    default {$body.Qualification.$field='changed'}
                }
                $body.EnvironmentSha256=Get-LabTlsCaByteDigest (ConvertTo-LabTlsRegistryWriterBytes $bad.environments[0])
                $bodyBytes=ConvertTo-LabTlsRegistryWriterBytes $body
                $bad.qualification.payload=[Convert]::ToBase64String($bodyBytes)
                $bad.qualification.signature=[Convert]::ToBase64String($rsa.SignData($bodyBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1))
                [IO.File]::WriteAllBytes($versionExport.JsonPath,(ConvertTo-LabTlsRegistryWriterBytes $bad))
                Add-CheckResult "Valid CA signature cannot change $($versionCase.Id) $field on $versionProvider" (-not (Test-LabTlsQualifiedExport $versionExport.JsonPath $fixture $record.RunId $record.InstanceId))
            }
        }
        }
        $record.ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2';$record.PSObject.Properties.Remove('SqlProfileId')
        # Exercise the creator's complete orchestration with explicitly synthetic
        # provider observations. These assertions guard the two review findings;
        # they do not claim native SQL or host-autostart acceptance.
        $script:capturedAutoStart=$null;$script:capturedProvider=$null;$script:writtenConnection=$null
        $authority.Authority|Add-Member -NotePropertyName NotAfterUtc -NotePropertyValue ([datetime]::UtcNow.AddDays(3).ToString('O'))
        function Register-LabTlsOperationalAuthority {param($DataRoot,$ControllerId,$LocationId,$CandidateId) $null=$DataRoot,$ControllerId,$LocationId,$CandidateId;return $authority}
        $script:fixtureImageId='sha256:'+('b'*64)
        function Invoke-LabTlsContainer {param($Arguments,$InputText) $null=$InputText;if($Arguments[0] -ceq 'image'){return $script:fixtureImageId};if($Arguments -contains 'base64'){return 'AQ=='};return ''}
        # Synthetic policy boundary for the creator orchestration. Actual policy
        # ACL/file/custody behavior is exercised by the cleanup fixture/native lane.
        function Get-LabTlsRuntimePin {
            param($Budget)
            [pscustomobject]@{Provider=$Budget.Provider;Invocation='synthetic.exe';Endpoint='synthetic-endpoint';IdentityPath='';IdentitySha256='';
                RuntimeScopeId=('runtime-scope-'+('f'*24));RoutingKey=('d'*64);IncarnationKey=('c'*64);MachineName=''}
        }
        function Initialize-LabOwnedHostPolicy {
            param($StateRoot,$RuntimePins,$ParentOperationId) $null=$RuntimePins
            Initialize-LabTlsCaPrivateDirectory $StateRoot $native.UserSid -NewOnly
            Write-LabTlsCaPrivateFile (Join-Path $StateRoot 'owned-host-policy.json') $native.UserSid ([Text.Encoding]::UTF8.GetBytes('{}'))
            [pscustomobject]@{PolicyId=$ParentOperationId}
        }
        function New-SqlServerLab {
            param($StateRoot,$Provider,$Version,$InstanceId,$AutoStart)
            $script:capturedVersion=$Version;$script:capturedAutoStart=$AutoStart;$script:capturedProvider=$Provider
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
        function Remove-SqlServerLab {
            [CmdletBinding(SupportsShouldProcess)]
            param($RunId,$StateRoot,[switch]$Force)
            $null=$RunId,$StateRoot,$Force;[pscustomobject]@{Status='REMOVED'}
        }
        function Write-LabArtifactJsonAtomic {param($Path,$InputObject) $null=$Path,$InputObject}
        foreach($provider in @('docker','podman')){
            $record.Provider=$provider
            $created=New-LabAuthenticatedTlsEnvironment @{Version='2025-CU9';Provider=$provider;DataRoot=$fixture;TlsControllerId=$record.ControllerId;TlsLocationId=$record.LocationId;TlsCandidateId=$authority.Authority.CandidateId}
            $settings=[Data.SqlClient.SqlConnectionStringBuilder]::new($created.Instances[0].ConnectionString)
            Add-CheckResult "Creator delegates explicit $provider and returns true/false in the public DTO" ($script:capturedProvider -ceq $provider -and $settings.Encrypt -and -not $settings.TrustServerCertificate)
            foreach($selectedVersion in @('2022-CU27','2019-CU32')){
                $createdVersion=New-LabAuthenticatedTlsEnvironment @{Version=$selectedVersion;Provider=$provider;DataRoot=$fixture;TlsControllerId=$record.ControllerId;TlsLocationId=$record.LocationId;TlsCandidateId=$authority.Authority.CandidateId}
                $versionRecord=Read-LabTlsLabRecord ([IO.File]::ReadAllBytes((Join-Path $createdVersion.StateRoot 'authenticated-tls-lab.json')))
                Add-CheckResult "Creator persists closed $selectedVersion profile for $provider" ($script:capturedVersion -ceq $selectedVersion -and $versionRecord.ContractVersion -ceq 'SqlServerLab.AuthenticatedTlsLab/0.3' -and $versionRecord.SqlProfileId -ceq $selectedVersion -and $versionRecord.Provider -ceq $provider)
            }
        }
        $script:fixtureImageId='sha256:'+('f'*64)
        $rejected=$false
        try{$null=New-LabAuthenticatedTlsEnvironment @{Version='2025-CU9';DataRoot=$fixture;TlsControllerId=$record.ControllerId;TlsLocationId=$record.LocationId;TlsCandidateId=$authority.Authority.CandidateId}}catch{$rejected=$_.Exception.Message -ceq 'TLS_LAB_IMAGE_CHANGED'}
        Add-CheckResult 'Creator rejects a tag rebound after the pinned preflight before TLS effects' $rejected
        $script:fixtureImageId='image:tag';$rejected=$false
        try{$null=New-LabAuthenticatedTlsEnvironment @{Version='2025-CU9';DataRoot=$fixture;TlsControllerId=$record.ControllerId;TlsLocationId=$record.LocationId;TlsCandidateId=$authority.Authority.CandidateId}}catch{$rejected=$_.Exception.Message -ceq 'TLS_LAB_IMAGE_ID_INVALID'}
        Add-CheckResult 'Creator rejects a preflight without a complete immutable image ID' $rejected
        $script:fixtureImageId='sha256:'+('b'*64)
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
