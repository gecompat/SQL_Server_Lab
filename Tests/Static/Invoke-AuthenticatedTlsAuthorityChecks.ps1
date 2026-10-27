#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
foreach($name in @('DiagnosticBundleReader','StorageContract','AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsRegistryPayload',
    'AuthenticatedTlsRegistryDocument','AuthenticatedTlsRegistryRoot','AuthenticatedTlsContext','AuthenticatedTlsBackend','AuthenticatedTlsCaCandidate','AuthenticatedTlsRegistryWriter','AuthenticatedTlsAuthorityBinding','AuthenticatedTlsAuthority')){. (Join-Path $repo "Private/$name.ps1")}
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$script:authorityFixtureContextPreview=(Get-Command Get-LabAuthenticatedTlsContextPreview).ScriptBlock
$script:authorityFixtureClientMetadataDrift=$false
$script:authorityFixtureSignerMetadataDrift=$false
function Get-LabAuthenticatedTlsContextPreview {
    param([object]$Request)
    $result=& $script:authorityFixtureContextPreview -Request $Request
    if($result.Success){
        if($script:authorityFixtureClientMetadataDrift -and $result.Value.Kind -ceq 'CLIENT_CONTEXT'){$result.Value.Binaries.SqlClient.DiskSha256='b'*64;$result.Value.Binaries.SqlClient.DiskBytes=[long]$result.Value.Binaries.SqlClient.DiskBytes+1}
        if($script:authorityFixtureSignerMetadataDrift -and $result.Value.Kind -ceq 'SIGNER_CONTEXT'){$result.Value.Backend.RuntimeVersion='99.0.0'}
    }
    return $result
}
$passed=0;$failures=[Collections.Generic.List[string]]::new()
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-authority-'+[guid]::NewGuid().ToString('N'))
try{
    if(-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows) -or $PSVersionTable.PSVersion -lt [version]'7.5'){
        Add-CheckResult 'Authority native Windows lane explicitly not executed' $true
        Write-Host 'Native Authority/DPAPI/ACL: NOT_EXECUTED; requires Windows PowerShell >=7.5'
    }else{
        $controller='11111111-1111-4111-8111-111111111111';$location='22222222-2222-4222-8222-222222222222'
        $root=Join-Path $fixture 'data';$null=New-Item -ItemType Directory -Path (Join-Path $root 'Catalog'),(Join-Path $root 'State') -Force
        $volume=(Get-LabVolumeIdentity $root).VolumeId
        $marker=@{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId=$volume;DataRoot=$root}
        $catalog=@{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@(@{LocationId=$location;ControllerId=$controller;VolumeId=$volume;LabDataRoot=$root})}
        [IO.File]::WriteAllText((Join-Path $root '.sql-server-lab-root.json'),($marker|ConvertTo-Json -Compress))
        [IO.File]::WriteAllText((Join-Path $root 'Catalog/storage-locations.json'),($catalog|ConvertTo-Json -Depth 5 -Compress))
        function Get-LabTlsCaStorageBase {param($Native) $null=$Native;return (Join-Path $fixture 'candidates')}
        $candidate=New-LabAuthenticatedTlsCaCandidate $root $controller $location CURRENT_WINDOWS_PROCESS 3
        Add-CheckResult 'Own actual RSA/DPAPI CA fixture created' $candidate.Success
        if(-not $candidate.Success){throw 'FIXTURE_CA_FAILED'}
        $id=$candidate.Value.CandidateId;$script:fixtureTrust=$true;$script:fixtureCertificateHash=$candidate.Value.CertificateSha256
        function Get-LabTlsCaExistingTrust {param([byte[]]$Der) if($script:fixtureTrust -and (Get-LabTlsCaByteDigest $Der) -ceq $script:fixtureCertificateHash){return 'IDENTICAL_PREEXISTING_NOT_OWNED'};return 'ABSENT'}
        $binding=Register-LabTlsOperationalAuthority $root $controller $location $id
        Add-CheckResult 'CA, signer, client and unique trustscope committed' ($binding.Authority.CandidateId -ceq $id -and $binding.Client.Ref -ceq $binding.Authority.ClientRef)
        $registry=Join-Path $root 'State/authenticated-tls/registry.json';$original=[IO.File]::ReadAllBytes($registry)
        $parsed=Read-LabAuthenticatedTlsRegistryDocument $original
        Add-CheckResult 'Complete operational document with three records' ($parsed.Success -and $parsed.Value.RegistryDocument.Payloads.Count -eq 3)
        $again=Register-LabTlsOperationalAuthority $root $controller $location $id
        Add-CheckResult 'Repeated binding reuses identity without another write' ($again.Authority.Ref -ceq $binding.Authority.Ref -and $again.RegistrySha256 -ceq $binding.RegistrySha256)
        $expectedRejected=$false
        try{$null=Register-LabTlsOperationalAuthority $root $controller $location $id ('f'*64)}catch{$expectedRejected=$_.Exception.Message-ceq'TLS_AUTHORITY_EXPECTED_REGISTRY_CHANGED'}
        Add-CheckResult 'Expected registry predecessor rejects stale requalification without mutation' ($expectedRejected -and
            (Get-LabTlsCaByteDigest ([IO.File]::ReadAllBytes($registry))) -ceq $binding.RegistrySha256)
        $beforeRevision=$parsed.Value.RegistryDocument.Index.Revision
        $beforeSigner=@($parsed.Value.RegistryDocument.Payloads|Where-Object Kind -CEQ SIGNER_CONTEXT)[0]
        $beforeClient=@($parsed.Value.RegistryDocument.Payloads|Where-Object Kind -CEQ CLIENT_CONTEXT)[0]
        $beforeAuthority=@($parsed.Value.RegistryDocument.Payloads|Where-Object Kind -CEQ AUTHORITY)[0]
        $script:authorityFixtureClientMetadataDrift=$true
        $clientRevised=Register-LabTlsOperationalAuthority $root $controller $location $id
        $clientCurrent=[IO.File]::ReadAllBytes($registry);$parsedClientCurrent=Read-LabAuthenticatedTlsRegistryDocument $clientCurrent
        $clientSigner=@($parsedClientCurrent.Value.RegistryDocument.Payloads|Where-Object Kind -CEQ SIGNER_CONTEXT)[0]
        $clientRecord=@($parsedClientCurrent.Value.RegistryDocument.Payloads|Where-Object Kind -CEQ CLIENT_CONTEXT)[0]
        $clientAuthority=@($parsedClientCurrent.Value.RegistryDocument.Payloads|Where-Object Kind -CEQ AUTHORITY)[0]
        Add-CheckResult 'Client-only metadata drift advances client and authority, preserving signer generation' ($parsedClientCurrent.Success -and
            $parsedClientCurrent.Value.RegistryDocument.Index.Revision -eq ($beforeRevision+1) -and $clientSigner.Generation -eq $beforeSigner.Generation -and
            $clientRecord.Generation -eq ($beforeClient.Generation+1) -and $clientAuthority.Generation -eq ($beforeAuthority.Generation+1) -and
            $clientAuthority.SignerGeneration -eq $clientSigner.Generation -and $clientAuthority.ClientGeneration -eq $clientRecord.Generation -and
            $clientSigner.Ref -ceq $beforeSigner.Ref -and $clientRecord.Ref -ceq $beforeClient.Ref -and $clientAuthority.Ref -ceq $beforeAuthority.Ref -and
            $clientRecord.Details.SqlClientDiskSha256 -ceq ('b'*64) -and
            $clientAuthority.CandidateBindingDigest -ceq $beforeAuthority.CandidateBindingDigest -and $clientAuthority.CertificateSha256 -ceq $beforeAuthority.CertificateSha256 -and
            $clientAuthority.EncryptedKeySha256 -ceq $beforeAuthority.EncryptedKeySha256 -and $clientAuthority.TrustStatus -ceq $beforeAuthority.TrustStatus -and
            $clientAuthority.CertificateStatus -ceq 'PROFILE_BOUND_NOT_QUALIFIED')
        $script:authorityFixtureSignerMetadataDrift=$true
        $beforeSigner=$clientSigner;$beforeClient=$clientRecord;$beforeAuthority=$clientAuthority
        $beforeRevision=$parsedClientCurrent.Value.RegistryDocument.Index.Revision
        $signerRevised=Register-LabTlsOperationalAuthority $root $controller $location $id
        $current=[IO.File]::ReadAllBytes($registry);$parsedCurrent=Read-LabAuthenticatedTlsRegistryDocument $current
        $afterSigner=@($parsedCurrent.Value.RegistryDocument.Payloads|Where-Object Kind -CEQ SIGNER_CONTEXT)[0]
        $afterClient=@($parsedCurrent.Value.RegistryDocument.Payloads|Where-Object Kind -CEQ CLIENT_CONTEXT)[0]
        $afterAuthority=@($parsedCurrent.Value.RegistryDocument.Payloads|Where-Object Kind -CEQ AUTHORITY)[0]
        Add-CheckResult 'Signer-only metadata drift advances signer and authority, preserving client generation' ($parsedCurrent.Success -and
            $parsedCurrent.Value.RegistryDocument.Index.Revision -eq ($beforeRevision+1) -and $afterSigner.Generation -eq ($beforeSigner.Generation+1) -and
            $afterClient.Generation -eq $beforeClient.Generation -and $afterAuthority.Generation -eq ($beforeAuthority.Generation+1) -and
            $afterAuthority.SignerGeneration -eq $afterSigner.Generation -and $afterAuthority.ClientGeneration -eq $afterClient.Generation -and
            $afterSigner.Ref -ceq $beforeSigner.Ref -and $afterClient.Ref -ceq $beforeClient.Ref -and $afterAuthority.Ref -ceq $beforeAuthority.Ref -and
            $afterSigner.Details.RuntimeVersion -ceq '99.0.0' -and $afterClient.Details.SqlClientDiskSha256 -ceq ('b'*64) -and
            $afterAuthority.CandidateBindingDigest -ceq $beforeAuthority.CandidateBindingDigest -and $afterAuthority.CertificateSha256 -ceq $beforeAuthority.CertificateSha256 -and
            $afterAuthority.EncryptedKeySha256 -ceq $beforeAuthority.EncryptedKeySha256 -and $afterAuthority.TrustStatus -ceq $beforeAuthority.TrustStatus -and
            $afterAuthority.CertificateStatus -ceq 'PROFILE_BOUND_NOT_QUALIFIED')
        $repeat=Register-LabTlsOperationalAuthority $root $controller $location $id
        Add-CheckResult 'Current revised metadata registration is idempotent' ($repeat.RegistrySha256 -ceq $signerRevised.RegistrySha256 -and $repeat.Authority.Generation -eq $signerRevised.Authority.Generation)
        $binding=$signerRevised;$parsed=$parsedCurrent;$original=$current
        foreach($field in @('CertificateSha256','EncryptedKeySha256','ClientRef','ClientGeneration','Store','NotAfterUtc')){
            $bad=$parsed.Value.RegistryDocument|ConvertTo-Json -Depth 12|ConvertFrom-Json -Depth 12
            $authority=@($bad.Payloads|Where-Object Kind -CEQ AUTHORITY)[0]
            switch($field){
                ClientGeneration {$authority.ClientGeneration=[int]$authority.ClientGeneration+1}
                ClientRef {$authority.ClientRef='33333333-3333-4333-8333-333333333333'}
                Store {$authority.Store='LOCAL_MACHINE_ROOT'}
                NotAfterUtc {$authority.NotAfterUtc='2000-01-01T00:00:00.0000000Z'}
                default {$authority.$field='f'*64}
            }
            $read=Read-LabAuthenticatedTlsRegistryDocument (ConvertTo-LabTlsRegistryWriterBytes $bad)
            Add-CheckResult "Closed operational field/digest rejection $field" (-not $read.Success)
        }
        $script:fixtureTrust=$false;$rejected=$false
        try{$null=Get-LabTlsOperationalAuthority $root $controller $location $binding.Authority.Ref $binding.Client.Ref}catch{$rejected=$true}
        Add-CheckResult 'Fresh trust withdrawal blocks the existing authority' $rejected
        $script:fixtureTrust=$true
        $restored=Get-LabTlsOperationalAuthority $root $controller $location $binding.Authority.Ref $binding.Client.Ref
        Add-CheckResult 'Trust restoration permits fresh proof of possession' ($restored.RegistrySha256 -ceq $binding.RegistrySha256)
        Add-CheckResult 'Reads and failed binds leave original registry bytes unchanged' ((Get-LabTlsCaByteDigest ([IO.File]::ReadAllBytes($registry))) -ceq (Get-LabTlsCaByteDigest $original))
    }
}catch{
    Add-CheckResult ('Authority fixture failed: '+$_.Exception.Message) $false
    # Bounded diagnostics from this synthetic fixture only, never runtime keys.
    $Error|Select-Object -First 4|ForEach-Object {Write-Host ('Fixture diagnostic: '+$_.Exception.Message)}
}
finally{
    if(Test-Path -LiteralPath $fixture){
        $resolved=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^sql-lab-authority-[0-9a-f]{32}$'){throw 'FIXTURE_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
        Add-CheckResult 'Own CA, key and registry fixtures fully removed' (-not (Test-Path -LiteralPath $resolved))
    }
}
Write-Host "TLS Authority: $passed PASS / $($failures.Count) FAIL"
if($failures.Count){exit 1}
