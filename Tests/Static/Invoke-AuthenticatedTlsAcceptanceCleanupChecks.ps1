#Requires -Version 7.5
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
. (Join-Path $repo 'Tests/Common/AuthenticatedTlsAcceptanceCleanup.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
if(-not $IsWindows){Write-Host 'Native TLS acceptance cleanup ACL: NOT_EXECUTED (Windows required)';exit 0}
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-export-cleanup-'+[guid]::NewGuid().ToString('N'))
try{
    $run=[guid]::NewGuid().ToString('D');$audit=[guid]::NewGuid().ToString('D');$scope=[guid]::NewGuid().ToString('D')
    $root=Join-Path $fixture ('State/authenticated-tls-labs/'+$audit)
    $directory=Join-Path $root 'qualified-export';$runDir=Join-Path $root ('runs/'+$run)
    & $module {param($root,$directory,$runDir,$run,$audit,$scope,$dataRoot)
        $sid=(Get-LabTlsWindowsProcessFacts).UserSid
        Initialize-LabTlsCaPrivateDirectory $root $sid -NewOnly
        Initialize-LabTlsCaPrivateDirectory $directory $sid -NewOnly
        $null=New-Item -ItemType Directory -Path $runDir -Force
        $record=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.1';AuditId=$audit;DataRoot=$dataRoot;ControllerId='';LocationId='';AuthorityRef='';ClientRef='';RegistrySha256='';
            RunId=$run;InstanceId='primary';ScopeId=$scope;ContainerId='';ImageId='';Port=14333;CertificateSha256='';CertificateDer='';NotAfterUtc='';StartedAt='';ServerPath=''}
        Write-LabTlsCaPrivateFile (Join-Path $root 'authenticated-tls-lab.json') $sid (ConvertTo-LabTlsRegistryWriterBytes $record)
        foreach($name in @('TestUmgebung.json','TestUmgebung.env','TestUmgebung.schema.json','TestUmgebung.md','TestUmgebung.prompt.md')){
            Write-LabTlsCaPrivateFile (Join-Path $directory $name) $sid ([byte[]]@(1,2,3))
        }
        # Tripwires: the cleanup must not reopen a CA or depend on working trust.
        function script:Get-LabTlsCaCandidateBinding {throw 'CLEANUP_KEY_OR_CA_ACCESS_FORBIDDEN'}
        function script:Get-LabTlsCaExistingTrust {throw 'CLEANUP_TRUST_ACCESS_FORBIDDEN'}
    } $root $directory $runDir $run $audit $scope $fixture
    $statePath=Join-Path $runDir 'run-state.json'
    @{runId=$run;scopeId=$scope;state='RUNNING'}|ConvertTo-Json|Set-Content -LiteralPath $statePath
    $blocked=$false;try{Remove-OwnedTlsAcceptanceExport $root $run $module}catch{$blocked=$true}
    Add-CheckResult 'Live owned run export is preserved' ($blocked -and @(Get-ChildItem -LiteralPath $directory -File).Count -eq 5)
    @{runId=$run;scopeId=$scope;state='REMOVED'}|ConvertTo-Json|Set-Content -LiteralPath $statePath
    $blocked=$false;try{Remove-OwnedTlsAcceptanceExport $root ([guid]::NewGuid().ToString('D')) $module}catch{$blocked=$true}
    Add-CheckResult 'Different run cannot authorize export cleanup' ($blocked -and @(Get-ChildItem -LiteralPath $directory -File).Count -eq 5)
    $extra=Join-Path $directory 'unrelated.txt';[IO.File]::WriteAllText($extra,'synthetic')
    $blocked=$false;try{Remove-OwnedTlsAcceptanceExport $root $run $module}catch{$blocked=$true}
    Add-CheckResult 'Unexpected contents prevent any deletion' ($blocked -and @(Get-ChildItem -LiteralPath $directory -File).Count -eq 6)
    Remove-Item -LiteralPath $extra
    Remove-OwnedTlsAcceptanceExport $root $run $module
    Add-CheckResult 'Removed own run cleans all fixed exports without key or trust access' (-not (Test-Path -LiteralPath $directory) -and (Test-Path -LiteralPath $statePath))
    Remove-OwnedTlsAcceptanceExport $root $run $module
    Add-CheckResult 'Repeated cleanup is a read-only absent-directory no-op' (-not (Test-Path -LiteralPath $directory))
    & $module {param($root,$directory)
        $sid=(Get-LabTlsWindowsProcessFacts).UserSid
        $path=Join-Path $root 'authenticated-tls-lab.json'
        $record=Read-LabTlsLabRecord (Read-LabTlsCaPrivateFile $path $sid 32768)
        $record.ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2';$record|Add-Member -NotePropertyName Provider -NotePropertyValue podman
        $record|Add-Member -NotePropertyName RuntimeBinding -NotePropertyValue ([pscustomobject]@{})
        [IO.File]::WriteAllBytes($path,(ConvertTo-LabTlsRegistryWriterBytes $record))
        Initialize-LabTlsCaPrivateDirectory $directory $sid -NewOnly
        Write-LabTlsCaPrivateFile (Join-Path $directory 'TestUmgebung.env') $sid ([byte[]]@(1,2,3))
    } $root $directory
    $blocked=$false;try{Remove-OwnedTlsAcceptanceExport $root $run $module}catch{$blocked=$true}
    Add-CheckResult 'New 0.2 binding cannot authorize cleanup without its required policy' ($blocked -and (Test-Path -LiteralPath $directory))
    $audit2=[guid]::NewGuid().ToString('D');$root2=Join-Path $fixture ('State/authenticated-tls-labs/'+$audit2)
    $directory2=Join-Path $root2 'qualified-export'
    & $module {param($root,$directory,$fixture,$run,$audit,$scope)
        $exe=Join-Path $fixture 'podman.exe';$identity=Join-Path $fixture 'synthetic-identity'
        [IO.File]::WriteAllBytes($exe,[byte[]]@(1));[IO.File]::WriteAllText($identity,'synthetic-not-a-key')
        $pin=[pscustomobject]@{Provider='podman';Invocation=$exe;Endpoint='ssh://synthetic@127.0.0.1:2222/run/podman/podman.sock';IdentityPath=$identity;IdentitySha256=(Get-FileHash -LiteralPath $identity).Hash.ToLowerInvariant()}
        $policy=Initialize-LabOwnedHostPolicy -StateRoot $root -RuntimePins @($pin) -ParentOperationId $audit
        $accepted=Assert-LabTlsLabRoot $root
        if($accepted.PolicyId -cne $policy.PolicyId){throw 'SYNTHETIC_POLICY_ROOT_NOT_ACCEPTED'}
        $caRejected=$false;try{Assert-LabTlsCaPrivateAcl $root (Get-LabTlsWindowsProcessFacts).UserSid -Directory}catch{$caRejected=$true}
        if(-not $caRejected){throw 'SYNTHETIC_CA_ACL_GUARD_WEAKENED'}
        $context=[pscustomobject]@{Provider='podman';Invocation=$exe;Endpoint=$pin.Endpoint;IdentityPath=$identity;IdentitySha256=$pin.IdentitySha256;
            RuntimeScopeId=('runtime-scope-'+('f'*24));RoutingKey=(Get-LabRetainedStoreHash @('podman',$pin.Endpoint,$pin.IdentitySha256));IncarnationKey=('c'*64);MachineName='synthetic-machine'}
        $record=[pscustomobject]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.2';Provider='podman';RuntimeBinding=(New-LabTlsRuntimeBinding $policy $context $root);
            AuditId=$audit;DataRoot=$fixture;ControllerId='';LocationId='';AuthorityRef='';ClientRef='';RegistrySha256='';RunId=$run;InstanceId='primary';ScopeId=$scope;ContainerId='';ImageId='';Port=14333;CertificateSha256='';CertificateDer='';NotAfterUtc='';StartedAt='';ServerPath=''}
        $sid=(Get-LabTlsWindowsProcessFacts).UserSid
        Write-LabTlsCaPrivateFile (Join-Path $root 'authenticated-tls-lab.json') $sid (ConvertTo-LabTlsRegistryWriterBytes $record)
        $metadata=@{};$metadata.ownedHostIntegration=New-LabOwnedHostRunReference -Policy $policy -RunId $run -ScopeId $scope -Metadata $metadata
        $runDir=Join-Path $root ('runs/'+$run);$null=New-Item -ItemType Directory -Path $runDir -Force
        [pscustomobject]@{runId=$run;scopeId=$scope;state='REMOVED';metadata=$metadata}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $runDir 'run-state.json')
        Initialize-LabTlsCaPrivateDirectory $directory $sid -NewOnly
        Write-LabTlsCaPrivateFile (Join-Path $directory 'TestUmgebung.env') $sid ([byte[]]@(1,2,3))
        $null=Get-LabTlsRecordedRuntimePin $record $root
    } $root2 $directory2 $fixture $run $audit2 $scope
    Add-CheckResult 'Dedicated owner-only TLS policy root is accepted without weakening the CA guard' ($true)
    Remove-OwnedTlsAcceptanceExport $root2 $run $module
    Add-CheckResult 'Policy-bound 0.2 Podman export cleanup validates run custody without CA or trust access' (-not (Test-Path -LiteralPath $directory2))
    & $module {param($root,$directory)
        $sid=(Get-LabTlsWindowsProcessFacts).UserSid;$path=Join-Path $root 'authenticated-tls-lab.json'
        $record=Read-LabTlsLabRecord (Read-LabTlsCaPrivateFile $path $sid 32768)
        $record.ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.3'
        [IO.File]::WriteAllBytes($path,(ConvertTo-LabTlsRegistryWriterBytes $record))
        Initialize-LabTlsCaPrivateDirectory $directory $sid -NewOnly
        Write-LabTlsCaPrivateFile (Join-Path $directory 'TestUmgebung.env') $sid ([byte[]]@(1,2,3))
    } $root2 $directory2
    $blocked=$false;try{Remove-OwnedTlsAcceptanceExport $root2 $run $module}catch{$blocked=$true}
    Add-CheckResult 'Incomplete 0.3 profile preserves fixed export before deletion' ($blocked -and (Test-Path -LiteralPath $directory2))
    & $module {param($root)
        $path=Join-Path $root 'authenticated-tls-lab.json'
        $record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 12 -DateKind String
        $record|Add-Member -NotePropertyName SqlProfileId -NotePropertyValue '2022-CU27'
        [IO.File]::WriteAllBytes($path,(ConvertTo-LabTlsRegistryWriterBytes $record))
    } $root2
    Remove-OwnedTlsAcceptanceExport $root2 $run $module
    Add-CheckResult 'Policy-bound SQL2022 cleanup remains independent of CA, trust and catalog reads' (-not (Test-Path -LiteralPath $directory2))
}catch{Add-CheckResult ('Cleanup fixture failed: '+$_.Exception.Message) $false}
finally{
    if(Test-Path -LiteralPath $fixture){
        $resolved=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^sql-lab-tls-export-cleanup-[0-9a-f]{32}$'){throw 'FIXTURE_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
        Add-CheckResult 'Own cleanup fixture fully removed' (-not (Test-Path -LiteralPath $resolved))
    }
}
Write-Host "TLS acceptance cleanup: $passed PASS / $($failures.Count) FAIL"
if($failures.Count){exit 1}
