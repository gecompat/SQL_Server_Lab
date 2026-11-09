#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
foreach($name in @('DiagnosticBundleReader','StorageContract','AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsRegistryPayload',
    'AuthenticatedTlsRegistryDocument','AuthenticatedTlsRegistryRoot','AuthenticatedTlsContext','AuthenticatedTlsBackend','AuthenticatedTlsCaCandidate','AuthenticatedTlsRegistryWriter','AuthenticatedTlsAuthorityBinding','AuthenticatedTlsAuthority')){. (Join-Path $repo "Private/$name.ps1")}
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$script:authorityFixtureRuntimeExists=$false
$script:authorityFixtureRuntimeByTarget=@{}
function Get-DockerInstanceStatus {param([string]$ContainerIdOrName,[string]$StateRoot) $exists=$script:authorityFixtureRuntimeExists;if($script:authorityFixtureRuntimeByTarget.ContainsKey($ContainerIdOrName)){$exists=[bool]$script:authorityFixtureRuntimeByTarget[$ContainerIdOrName]};return [pscustomobject]@{Available=$true;Exists=$exists;Running=$exists}}
function Get-PodmanInstanceStatus {param([string]$ContainerIdOrName,[string]$StateRoot) $exists=$script:authorityFixtureRuntimeExists;if($script:authorityFixtureRuntimeByTarget.ContainsKey($ContainerIdOrName)){$exists=[bool]$script:authorityFixtureRuntimeByTarget[$ContainerIdOrName]};return [pscustomobject]@{Available=$true;Exists=$exists;Running=$exists}}
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

        $labsRoot=Join-Path $root 'State/authenticated-tls-labs'
        $operationsRoot=Join-Path $root 'State/authenticated-tls-windows-operations'
        $null=New-Item -ItemType Directory -Path $labsRoot,$operationsRoot -Force
        $unknownOperation=Join-Path $operationsRoot '33333333-3333-4333-8333-333333333333'
        $null=New-Item -ItemType Directory -Path $unknownOperation
        [IO.File]::SetAttributes($unknownOperation,[IO.FileAttributes]::Hidden)
        $blocked=$false
        try{
            $null=Retire-LabTlsOperationalAuthority $root $controller $location $binding.Authority.Ref $id $binding.RegistrySha256 -Confirm:$false
        }catch{$blocked=$_.Exception.Message -ceq 'TLS_AUTHORITY_RETIREMENT_UNCONFIRMED'}
        Add-CheckResult 'Unknown Windows operation blocks retirement without registry mutation' ($blocked -and
            (Get-LabTlsCaByteDigest ([IO.File]::ReadAllBytes($registry))) -ceq $binding.RegistrySha256)
        Remove-Item -LiteralPath $unknownOperation -Force
        $typedOperation=Join-Path $operationsRoot '44444444-4444-4444-8444-444444444444'
        $null=New-Item -ItemType Directory -Path $typedOperation
        Write-LabTlsCaPrivateFile (Join-Path $typedOperation 'intent.json') $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes @{ContractVersion='SqlServerLab.WindowsTlsCreateIntent/0.1';AuditId=[IO.Path]::GetFileName($typedOperation);Status='NEW_OWN_RUN_PENDING'})
        Write-LabTlsCaPrivateFile (Join-Path $typedOperation 'ready.json') $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes @{Status='READY';RunId='55555555-5555-4555-8555-555555555555';ClientChecks=2;ConsumerEnded='True'})
        $typedBlocked=$false
        try{$null=Retire-LabTlsOperationalAuthority $root $controller $location $binding.Authority.Ref $id $binding.RegistrySha256 -Confirm:$false}
        catch{$typedBlocked=$_.Exception.Message -ceq 'TLS_AUTHORITY_RETIREMENT_UNCONFIRMED'}
        Add-CheckResult 'String-encoded Windows terminal Boolean blocks retirement' ($typedBlocked -and
            (Get-LabTlsCaByteDigest ([IO.File]::ReadAllBytes($registry))) -ceq $binding.RegistrySha256)
        Remove-Item -LiteralPath $typedOperation -Recurse -Force
        $pendingAllocation=Join-Path $labsRoot ([guid]::NewGuid().ToString('D'))
        Initialize-LabTlsCaPrivateDirectory $pendingAllocation $binding.Native.UserSid -NewOnly
        Write-LabTlsCaPrivateFile (Join-Path $pendingAllocation 'intent.json') $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes @{AuditId=[IO.Path]::GetFileName($pendingAllocation);Status='OWNED_CREATE_PENDING'})
        $allocationBlocked=$false
        try{$null=Retire-LabTlsOperationalAuthority $root $controller $location $binding.Authority.Ref $id $binding.RegistrySha256 -Confirm:$false}
        catch{$allocationBlocked=$_.Exception.Message -ceq 'TLS_AUTHORITY_RETIREMENT_UNCONFIRMED'}
        Add-CheckResult 'Allocation without published run record blocks retirement without mutation' ($allocationBlocked -and
            (Get-LabTlsCaByteDigest ([IO.File]::ReadAllBytes($registry))) -ceq $binding.RegistrySha256)
        Remove-Item -LiteralPath $pendingAllocation -Recurse -Force
        $manual=$parsedCurrent.Value.RegistryDocument|ConvertTo-Json -Depth 12|ConvertFrom-Json -Depth 12
        $manual.Index.Revision=[int]$manual.Index.Revision+1
        $manualAuthority=@($manual.Payloads|Where-Object {$_.Kind -ceq 'AUTHORITY' -and $_.Ref -ceq $binding.Authority.Ref})[0]
        $manualAuthority.Status='RETIRED';$manual.Index.Records=@($manual.Payloads|ForEach-Object {Get-LabTlsPayloadIndexRecord $_})
        $manualBytes=ConvertTo-LabTlsRegistryWriterBytes $manual;$writerBinding=Get-LabTlsRegistryWriterBinding $root $controller $location
        $generic=Invoke-LabAuthenticatedTlsRegistryWrite $root $controller $location CURRENT_WINDOWS_PROCESS UPDATE `
            $writerBinding.Root.RootMetadataDigest $writerBinding.ActorDigest $binding.RegistrySha256 $manualBytes
        Add-CheckResult 'Generic registry UPDATE cannot create an unchecked tombstone' (-not $generic.Success -and
            (Get-LabTlsCaByteDigest ([IO.File]::ReadAllBytes($registry))) -ceq $binding.RegistrySha256)
        $orphanAllocation=Join-Path $labsRoot '66666666-6666-4666-8666-666666666666'
        Initialize-LabTlsCaPrivateDirectory $orphanAllocation $binding.Native.UserSid -NewOnly
        Write-LabTlsCaPrivateFile (Join-Path $orphanAllocation 'intent.json') $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes @{
            AuditId=[IO.Path]::GetFileName($orphanAllocation);Status='OWNED_CREATE_PENDING';Cleanup='Remove exact owned run; retain recovery if unconfirmed'})
        $orphanRuns=Join-Path $orphanAllocation 'runs';Initialize-LabTlsCaPrivateDirectory $orphanRuns $binding.Native.UserSid -NewOnly
        $orphanRun='77777777-7777-4777-8777-777777777777';$orphanRunDir=Join-Path $orphanRuns $orphanRun
        Initialize-LabTlsCaPrivateDirectory $orphanRunDir $binding.Native.UserSid -NewOnly
        $scope='88888888-8888-4888-8888-888888888888'
        Write-LabTlsCaPrivateFile (Join-Path $orphanRunDir 'run-state.json') $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes @{
            contractVersion='SqlServerLab.RunState/1.0';runId=$orphanRun;scopeId=$scope;state='REMOVED';metadata=@{desiredState=@{Instances=@(@{Id='primary';Provider='docker'})}}})
        $orphanConnection=@{runId=$orphanRun;scopeId=$scope;instances=@(@{id='primary';provider='docker';containerId='fixture-orphan-container';containerName='fixture-orphan-container'})}
        $orphanCleanup=[ordered]@{runId=$orphanRun;scopeId=$scope;status='COMPLETED';steps=@(@{resourceType='container';provider='docker';action='remove';state='COMPLETED';resourceId='fixture-orphan-container'})}
        Write-LabTlsCaPrivateFile (Join-Path $orphanRunDir 'cleanup-plan.json') $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes $orphanCleanup)
        Write-LabTlsCaPrivateFile (Join-Path $orphanRunDir 'connection-info.json') $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes $orphanConnection)
        $targetMismatchBlocked=$false
        try{$null=Assert-LabTlsAuthorityRunRetiredAndAbsent $orphanRun $orphanAllocation ([pscustomobject]@{ScopeId=$scope;InstanceId='primary';Provider='docker';RuntimeId='fixture-original-container'})}
        catch{$targetMismatchBlocked=$_.Exception.Message -ceq 'TLS_AUTHORITY_USE_UNCONFIRMED'}
        Add-CheckResult 'Saved TLS target mismatch blocks runtime absence evidence' $targetMismatchBlocked
        $windowsAudit='99999999-9999-4999-8999-999999999999';$windowsVm='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $windowsRunInfo=[pscustomobject]@{AuditId=$windowsAudit;RunId=$orphanRun;StateRoot=$orphanAllocation}
        $windowsRecord=[pscustomobject]@{AuditId=$windowsAudit;RunId=$orphanRun;StateRoot=$orphanAllocation;DataRoot=$root;ControllerId=$controller;LocationId=$location;
            AuthorityRef=$binding.Authority.Ref;RegistrySha256=$binding.RegistrySha256;InstanceId='primary';ScopeId=$scope;VmId=$windowsVm}
        $windowsTarget=Get-LabTlsAuthorityExpectedWindowsTarget $windowsRunInfo $windowsRecord $windowsAudit $root $controller $location $binding.Authority.Ref $binding.RegistrySha256
        Add-CheckResult 'READY Windows TLS operation supplies its saved VM target to retirement checks' ($windowsTarget.Provider -ceq 'hyperv' -and
            $windowsTarget.ScopeId -ceq $scope -and $windowsTarget.InstanceId -ceq 'primary' -and $windowsTarget.RuntimeId -ceq $windowsVm)
        $orphanConnection.instances[0].containerId='fixture-missing-container-id'
        Remove-Item -LiteralPath (Join-Path $orphanRunDir 'connection-info.json') -Force
        Write-LabTlsCaPrivateFile (Join-Path $orphanRunDir 'connection-info.json') $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes $orphanConnection)
        $script:authorityFixtureRuntimeByTarget=@{'fixture-missing-container-id'=$false;'fixture-orphan-container'=$true}
        $staleNameBlocked=$false
        try{$null=Retire-LabTlsOperationalAuthority $root $controller $location $binding.Authority.Ref $id $binding.RegistrySha256 -Confirm:$false}
        catch{$staleNameBlocked=$_.Exception.Message -ceq 'TLS_AUTHORITY_RETIREMENT_UNCONFIRMED'}
        Add-CheckResult 'Existing saved container name blocks absence when the recorded id is stale' ($staleNameBlocked -and
            (Get-LabTlsCaByteDigest ([IO.File]::ReadAllBytes($registry))) -ceq $binding.RegistrySha256)
        $script:authorityFixtureRuntimeByTarget=@{}
        $script:authorityFixtureRuntimeExists=$true;$liveOrphanBlocked=$false
        try{$null=Retire-LabTlsOperationalAuthority $root $controller $location $binding.Authority.Ref $id $binding.RegistrySha256 -Confirm:$false}
        catch{$liveOrphanBlocked=$_.Exception.Message -ceq 'TLS_AUTHORITY_RETIREMENT_UNCONFIRMED'}
        Add-CheckResult 'Recordless allocation with an existing runtime blocks retirement' ($liveOrphanBlocked -and
            (Get-LabTlsCaByteDigest ([IO.File]::ReadAllBytes($registry))) -ceq $binding.RegistrySha256)
        $script:authorityFixtureRuntimeExists=$false
        $script:authorityFixtureRealTerminal=${function:Write-LabTlsRegistryTerminal};$script:authorityFixtureFailTerminal=$true
        Set-Item Function:Write-LabTlsRegistryTerminal -Value {
            param($Binding,$Intent,$Outcome)
            if($script:authorityFixtureFailTerminal){$script:authorityFixtureFailTerminal=$false;throw 'FIXTURE_TERMINAL_CRASH'}
            & $script:authorityFixtureRealTerminal $Binding $Intent $Outcome
        }
        $retirementCrash=$false
        try{$null=Retire-LabTlsOperationalAuthority $root $controller $location $binding.Authority.Ref $id $binding.RegistrySha256 -Confirm:$false}
        catch{$retirementCrash=$_.Exception.Message -ceq 'TLS_AUTHORITY_RETIREMENT_UNCONFIRMED'}
        finally{Set-Item Function:Write-LabTlsRegistryTerminal -Value $script:authorityFixtureRealTerminal}
        $pending=Read-LabTlsRegistryWriterState (Get-LabTlsRegistryWriterBinding $root $controller $location)
        Add-CheckResult 'Interrupted tombstone install is retained for explicit recovery' ($retirementCrash -and $pending.Status -ceq 'CANDIDATE_INSTALLED' -and $pending.Pending.Count -eq 1)
        $recoveryBlocker=Join-Path $labsRoot ([guid]::NewGuid().ToString('D'))
        Initialize-LabTlsCaPrivateDirectory $recoveryBlocker $binding.Native.UserSid -NewOnly
        Write-LabTlsCaPrivateFile (Join-Path $recoveryBlocker 'intent.json') $binding.Native.UserSid (ConvertTo-LabTlsRegistryWriterBytes @{AuditId=[IO.Path]::GetFileName($recoveryBlocker);Status='OWNED_CREATE_PENDING'})
        $blockedRecovery=Invoke-LabAuthenticatedTlsRegistryWrite $root $controller $location CURRENT_WINDOWS_PROCESS RECOVER_COMMIT `
            $writerBinding.Root.RootMetadataDigest $writerBinding.ActorDigest $pending.Digest $null $pending.Pending[0].Intent.TransactionId
        $stillPending=Read-LabTlsRegistryWriterState (Get-LabTlsRegistryWriterBinding $root $controller $location)
        Add-CheckResult 'New unresolved allocation blocks tombstone recovery without consuming its intent' (-not $blockedRecovery.Success -and
            $stillPending.Status -ceq 'CANDIDATE_INSTALLED' -and $stillPending.Pending.Count -eq 1)
        Remove-Item -LiteralPath $recoveryBlocker -Recurse -Force
        $recover=Invoke-LabAuthenticatedTlsRegistryWrite $root $controller $location CURRENT_WINDOWS_PROCESS RECOVER_COMMIT `
            $writerBinding.Root.RootMetadataDigest $writerBinding.ActorDigest $pending.Digest $null $pending.Pending[0].Intent.TransactionId
        Add-CheckResult 'Retirement recovery repeats the use check and commits exact installed bytes' ($recover.Success -and $recover.Value.Status -ceq 'RECOVERY_COMMITTED')
        $retiredState=Read-LabTlsRegistryWriterState (Get-LabTlsRegistryWriterBinding $root $controller $location)
        $retired=[pscustomobject]@{Success=$recover.Success;Value=[pscustomobject]@{Status='TOMBSTONE_COMMITTED';AuthorityRef=$binding.Authority.Ref;
            CandidateId=$id;RegistrySha256=$retiredState.Digest;Revision=(Read-LabAuthenticatedTlsRegistryDocument $retiredState.Bytes).Value.RegistryDocument.Index.Revision;
            RemovalStatus='NONE';Ready=$false;MutationAllowed=$false}}
        $retiredBytes=[IO.File]::ReadAllBytes($registry);$retiredDocument=Read-LabAuthenticatedTlsRegistryDocument $retiredBytes
        $retiredAuthority=@($retiredDocument.Value.RegistryDocument.Payloads|Where-Object {$_.Kind -ceq 'AUTHORITY' -and $_.Ref -ceq $binding.Authority.Ref})
        Add-CheckResult 'Use-checked tombstone commits while preserving authority identity and history' ($retired.Success -and
            $retired.Value.Status -ceq 'TOMBSTONE_COMMITTED' -and $retired.Value.RemovalStatus -ceq 'NONE' -and
            $retiredDocument.Success -and $retiredAuthority.Count -eq 1 -and $retiredAuthority[0].Status -ceq 'RETIRED' -and
            $retiredAuthority[0].Generation -eq $binding.Authority.Generation -and
            $retiredAuthority[0].IdentityDigest -ceq $binding.Authority.IdentityDigest -and
            $retiredAuthority[0].RevisionDigest -ceq $binding.Authority.RevisionDigest -and
            $retiredDocument.Value.RegistryDocument.Payloads.Count -eq $parsedCurrent.Value.RegistryDocument.Payloads.Count)
        $staleRetirement=$false
        try{$null=Retire-LabTlsOperationalAuthority $root $controller $location $binding.Authority.Ref $id $binding.RegistrySha256 -Confirm:$false}
        catch{$staleRetirement=$_.Exception.Message -ceq 'TLS_AUTHORITY_EXPECTED_REGISTRY_CHANGED'}
        Add-CheckResult 'Retirement compare-and-swap rejects a stale replay' ($staleRetirement -and
            (Get-LabTlsCaByteDigest ([IO.File]::ReadAllBytes($registry))) -ceq $retired.Value.RegistrySha256)
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
