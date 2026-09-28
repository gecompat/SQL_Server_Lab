# Synthetic request transport checks; no SQL or VM action.
. (Join-Path $repoRoot 'Tests/Common/CSharpNativeProfileRequest.ps1')
$requestNow=[DateTimeOffset]::Parse('2030-01-01T00:00:00Z')
$requestProfile=[ordered]@{SchemaVersion='1';ArtifactId=('hyperv-os-sealed-'+('b'*64));PayloadRoot='C:\Synthetic\Payload';PackageSha256=('a'*64);ProbeSha256=('c'*64);SqlMediaPath='Sql\setup.iso';MediaEdition='Eval';StateRoot='C:\Synthetic\State';MediaRoot='C:\Synthetic\Media'}
$requestObject=[ordered]@{SchemaVersion='1';Purpose='CSharpNativeAcceptance';ProfileName='csharp-sql2025';Nonce='11111111-2222-4333-8444-555555555555';MainCommit=('d'*40);ExpiresUtc='2030-01-01T01:00:00Z';Profile=$requestProfile}
$requestJson=$requestObject|ConvertTo-Json -Depth 5 -Compress
$resolved=ConvertFrom-CSharpNativeRequest $requestJson 'csharp-sql2025' ('d'*40) $requestNow
Add-CheckResult -Name 'CSharp request: strict envelope and approved embedded profile accepted' -Success ($resolved.ExpiresUtc -eq $requestNow.AddHours(1) -and (ConvertFrom-CSharpNativeProfile $resolved.ProfileJson).PackageSha256 -ceq ('a'*64))
foreach($case in @(
    @{Name='syntax';Json='{synthetic private syntax'},@{Name='array';Json='[]'},
    @{Name='unknown field';Json=$requestJson.Replace('"Purpose":','"Command":"synthetic","Purpose":')},
    @{Name='duplicate';Json=$requestJson.Replace('"Purpose":','"Purpose":"CSharpNativeAcceptance","Purpose":')},
    @{Name='wrong purpose';Json=$requestJson.Replace('CSharpNativeAcceptance','Other')},
    @{Name='wrong profile';Json=$requestJson.Replace('csharp-sql2025','other')},
    @{Name='wrong commit';Json=$requestJson.Replace(('d'*40),('e'*40))},
    @{Name='zero nonce';Json=$requestJson.Replace('11111111-2222-4333-8444-555555555555','00000000-0000-0000-0000-000000000000')},
    @{Name='missing nonce';Json=$requestJson.Replace('"Nonce":"11111111-2222-4333-8444-555555555555",','')},
    @{Name='expired';Json=$requestJson.Replace('2030-01-01T01:00:00Z','2029-12-31T23:59:59Z')},
    @{Name='expiry boundary';Json=$requestJson.Replace('2030-01-01T01:00:00Z','2030-01-01T00:00:00Z')},
    @{Name='excessive expiry';Json=$requestJson.Replace('2030-01-01T01:00:00Z','2030-01-01T04:00:01Z')},
    @{Name='non UTC expiry';Json=$requestJson.Replace('2030-01-01T01:00:00Z','2030-01-01T01:00:00+00:00')},
    @{Name='embedded hash';Json=$requestJson.Replace(('a'*64),'latest')},
    @{Name='oversized';Json=('x'*32769)})){
    $outputs=@(& {try{ConvertFrom-CSharpNativeRequest $case.Json 'csharp-sql2025' ('d'*40) $requestNow}catch{$_.Exception.Message}} *>&1)
    Add-CheckResult -Name ('CSharp request: reject '+$case.Name) -Success ($outputs.Count -eq 1 -and [string]$outputs[0] -cmatch '^CSHARP_NATIVE_[A-Z_]+$')
}
$requestFile=Join-Path $nativeRoot 'synthetic-request.json'
[IO.File]::WriteAllText($requestFile,$requestJson,[Text.UTF8Encoding]::new($false))
$requestHash=(Get-FileHash -LiteralPath $requestFile -Algorithm SHA256).Hash.ToLowerInvariant()
$read=Read-CSharpNativeRequestBytes -Path $requestFile -ExpectedHash $requestHash
Add-CheckResult -Name 'CSharp request: actual same-handle bounded file read and SHA256 binding' -Success ($read -ceq $requestJson)
$caught='';try{Read-CSharpNativeRequestBytes $requestFile ('0'*64)}catch{$caught=$_.Exception.Message}
Add-CheckResult -Name 'CSharp request: hash mismatch rejected before parser' -Success ($caught -ceq 'CSHARP_NATIVE_REQUEST_HASH')
if($IsWindows){
$writer=[IO.File]::Open($requestFile,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{$caught='';try{Read-CSharpNativeRequestBytes $requestFile $requestHash}catch{$caught=$_.Exception.Message}}
finally{$writer.Dispose()}
Add-CheckResult -Name 'CSharp request: concurrent writer rejected without private diagnostics' -Success ($caught -ceq 'CSHARP_NATIVE_REQUEST_READ')
}
$requestBinding=[pscustomobject]@{Nonce=$requestObject.Nonce;MainCommit=('d'*40);RequestSha256=$requestHash}
foreach($fault in @('None','RecordOpen','RecordWrite','TerminalRecord','CreatedRecord','Collision','PartialWrite','Resolve','Supervisor','BothCleanup')){
    & {
        $saved=$env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT
        $env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT='synthetic-prior-root'
        $trace=[Collections.Generic.List[string]]::new()
        function Get-CSharpNativeRequestVolumeRoot {$nativeRoot}
        function New-CSharpNativeTemporaryDirectory {param($Path)$trace.Add('Create');if($fault -eq 'Collision'){throw 'CSHARP_NATIVE_PROFILE_EXISTS'}}
        function Write-CSharpNativeTemporaryProfile {param($Owned,$Json)$trace.Add('Write');$Owned.FileOwned=$true;if($fault -eq 'PartialWrite'){throw 'synthetic private write'}}
        function Get-CSharpNativeProfile {param($Name)$trace.Add('Resolve');if($fault -eq 'Resolve'){throw 'CSHARP_NATIVE_PROFILE_ACL'}}
        function Remove-CSharpNativeTemporaryProfile {param($Owned)$trace.Add('Cleanup');if($env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT -cne 'synthetic-prior-root'){throw 'CSHARP_NATIVE_ENV_NOT_RESTORED'};if($fault -eq 'BothCleanup'){throw 'CSHARP_NATIVE_PROFILE_CLEANUP_FAILED'}}
        $recordPath=Join-Path $nativeRoot ('recovery-'+[guid]::NewGuid().ToString('N')+'.jsonl')
        if($fault -eq 'RecordOpen'){[IO.File]::WriteAllText($recordPath,'preserve')}
        if($fault -eq 'RecordWrite'){function Write-CSharpNativeRecoveryRecord {param($Stream,$Owned,$Binding,$Status,$PrimaryFailure,$CleanupFailure,$RunCleanupFailure) throw 'CSHARP_NATIVE_PROFILE_RECORD_FAILED'}}
        if($fault -in @('TerminalRecord','CreatedRecord')){
            $realRecordWriter=${function:Write-CSharpNativeRecoveryRecord}
            function Write-CSharpNativeRecoveryRecord {
                param($Stream,$Owned,$Binding,$Status,$PrimaryFailure,$CleanupFailure,$RunCleanupFailure)
                if(($fault -eq 'TerminalRecord' -and $Status -eq 'CLEANED') -or ($fault -eq 'CreatedRecord' -and $Status -eq 'CREATED')){throw 'CSHARP_NATIVE_PROFILE_RECORD_FAILED'}
                & $realRecordWriter @PSBoundParameters
            }
        }
        $diagnostic=$null;$result=$null
        try{
            $result=Invoke-CSharpNativeWithTemporaryProfile -ProfileJson ($requestProfile|ConvertTo-Json -Compress) -RecoveryRecordPath $recordPath -RequestBinding $requestBinding -Action {
                $trace.Add('Supervisor')
                if($fault -in @('Supervisor','BothCleanup')){throw (New-CSharpNativeFailureException -PrimaryFailure 'CSHARP_NATIVE_CHILD_TIMEOUT' -CleanupFailure 'CSHARP_NATIVE_OWNED_RUN_CLEANUP_FAILED')}
                [pscustomobject]@{Status='PASSED'}
            }
        }catch{$diagnostic=Get-CSharpNativeRequestFailureDiagnostic $_}
        finally{$restored=$env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT -ceq 'synthetic-prior-root';$env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT=$saved}
        $good=switch($fault){
            'None' {$result.Status -eq 'PASSED' -and -not $diagnostic -and ($trace -join ',') -ceq 'Create,Write,Resolve,Supervisor,Cleanup'}
            'RecordOpen' {$trace.Count -eq 0 -and $diagnostic.PrimaryFailure -ceq 'CSHARP_NATIVE_PROFILE_RECORD_CREATE' -and [IO.File]::ReadAllText($recordPath) -ceq 'preserve'}
            'RecordWrite' {$trace.Count -eq 0 -and $diagnostic.PrimaryFailure -ceq 'CSHARP_NATIVE_PROFILE_RECORD_FAILED'}
            'TerminalRecord' {$trace.Contains('Supervisor') -and $trace.Contains('Cleanup') -and $diagnostic.PrimaryFailure -ceq 'CSHARP_NATIVE_PROFILE_RECORD_FAILED' -and -not $diagnostic.ProfileCleanupFailure -and $diagnostic.RecoveryRecordFailure -ceq 'CSHARP_NATIVE_PROFILE_RECORD_FAILED'}
            'CreatedRecord' {$trace.Contains('Create') -and $trace.Contains('Cleanup') -and -not $trace.Contains('Write') -and $diagnostic.PrimaryFailure -ceq 'CSHARP_NATIVE_PROFILE_RECORD_FAILED' -and -not $diagnostic.ProfileCleanupFailure}
            'Collision' {$diagnostic.PrimaryFailure -ceq 'CSHARP_NATIVE_PROFILE_EXISTS' -and ($trace -join ',') -ceq 'Create'}
            'PartialWrite' {$trace.Contains('Cleanup') -and -not $trace.Contains('Supervisor') -and ($diagnostic|ConvertTo-Json -Compress) -notmatch 'synthetic private'}
            'Resolve' {$trace.Contains('Cleanup') -and -not $trace.Contains('Supervisor') -and $diagnostic.PrimaryFailure -ceq 'CSHARP_NATIVE_PROFILE_ACL'}
            'Supervisor' {$trace.Contains('Cleanup') -and $diagnostic.PrimaryFailure -ceq 'CSHARP_NATIVE_CHILD_TIMEOUT' -and $diagnostic.CleanupFailure -ceq 'CSHARP_NATIVE_OWNED_RUN_CLEANUP_FAILED' -and $diagnostic.RecoveryRequired}
            'BothCleanup' {$diagnostic.PrimaryFailure -ceq 'CSHARP_NATIVE_CHILD_TIMEOUT' -and $diagnostic.CleanupFailure -ceq 'CSHARP_NATIVE_OWNED_RUN_CLEANUP_FAILED' -and $diagnostic.ProfileCleanupFailure -ceq 'CSHARP_NATIVE_PROFILE_CLEANUP_FAILED' -and $diagnostic.RecoveryRequired}
        }
        Add-CheckResult -Name ('CSharp request: owned wrapper '+$fault+' and environment restore') -Success ($good -and $restored)
        if($fault -notin @('RecordOpen','RecordWrite','TerminalRecord','CreatedRecord')){
            $records=@(Get-Content -LiteralPath $recordPath|ForEach-Object {$_|ConvertFrom-Json})
            $expectedLast=if($fault -eq 'BothCleanup'){'CLEANUP_FAILED'}elseif($fault -eq 'Collision'){'NOT_CREATED'}else{'CLEANED'}
            $recordGood=$records[0].Status -ceq 'PREPARED' -and -not $records[0].DirectoryOwned -and $records[-1].Status -ceq $expectedLast -and $records[0].Nonce -ceq $requestBinding.Nonce -and $records[0].RequestSha256 -ceq $requestHash
            if($fault -ne 'Collision'){$recordGood=$recordGood -and $records[1].Status -ceq 'CREATED' -and $records[1].DirectoryOwned -and -not $records[1].FileOwned}
            if($fault -eq 'BothCleanup'){$recordGood=$recordGood -and $records[-1].CleanupFailure -ceq 'CSHARP_NATIVE_PROFILE_CLEANUP_FAILED' -and $records[-1].RunCleanupFailure -ceq 'CSHARP_NATIVE_OWNED_RUN_CLEANUP_FAILED'}
            Add-CheckResult -Name ('CSharp request: retained recovery journal '+$fault) -Success $recordGood
        }
    }
}
foreach($bindingCase in @('NotOwned','WrongVolume','WrongName','WrongFile')){
    $owned=[pscustomobject]@{VolumeRoot=$nativeRoot;Root=(Join-Path $nativeRoot ('SqlServerLab-CSharpProfile-'+('a'*32)));File='';DirectoryOwned=$true;FileOwned=$false}
    $owned.File=Join-Path $owned.Root 'csharp-sql2025.json'
    switch($bindingCase){
        'NotOwned' {$owned.DirectoryOwned=$false}
        'WrongVolume' {$owned.VolumeRoot=Join-Path $nativeRoot 'other'}
        'WrongName' {$owned.Root=Join-Path $nativeRoot 'foreign'}
        'WrongFile' {$owned.File=Join-Path $nativeRoot 'foreign.json'}
    }
    $caught='';try{Remove-CSharpNativeTemporaryProfile $owned}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name ('CSharp request: cleanup rejects '+$bindingCase+' before IO') -Success ($caught -ceq 'CSHARP_NATIVE_PROFILE_CLEANUP_BINDING')
}
& {
    function Assert-CSharpNativeRequestDirectory {param($Path) throw 'CSHARP_NATIVE_REPARSE_POINT'}
    $owned=[pscustomobject]@{VolumeRoot=$nativeRoot;Root=(Join-Path $nativeRoot ('SqlServerLab-CSharpProfile-'+('f'*32)));DirectoryOwned=$true;FileOwned=$false;File=''}
    $owned.File=Join-Path $owned.Root 'csharp-sql2025.json'
    $caught='';try{Remove-CSharpNativeTemporaryProfile $owned}catch{$caught=$_.Exception.Message}
    Add-CheckResult -Name 'CSharp request: cleanup revalidates directory before deletion' -Success ($caught -ceq 'CSHARP_NATIVE_REPARSE_POINT')
}
try{$errorObject=[InvalidOperationException]::new('synthetic private primary');$errorObject.Data['ProfileCleanupFailure']='synthetic private cleanup';throw $errorObject}catch{$diagnostic=Get-CSharpNativeRequestFailureDiagnostic $_}
Add-CheckResult -Name 'CSharp request: private profile-cleanup diagnostics sanitized' -Success ($diagnostic.RecoveryRequired -and ($diagnostic|ConvertTo-Json -Compress) -notmatch 'synthetic private')
foreach($path in @('Tests/Common/CSharpNativeProfileRequest.ps1','Tests/Integration/Invoke-CSharpNativeRequestAcceptance.ps1')){
    $errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $path),[ref]$null,[ref]$errors)
    Add-CheckResult -Name ('CSharp request: parser '+$path) -Success (@($errors).Count -eq 0)
}
$requestWrapper=Get-Content (Join-Path $repoRoot 'Tests/Integration/Invoke-CSharpNativeRequestAcceptance.ps1') -Raw
Add-CheckResult -Name 'CSharp request: checkout before local request and unchanged supervisor' -Success ($requestWrapper.IndexOf('Assert-CSharpNativeCheckout') -lt $requestWrapper.IndexOf('$volume=Get-CSharpNativeRequestVolumeRoot') -and $requestWrapper.Contains('Invoke-CSharpHyperVAcceptance.ps1') -and $requestWrapper.Contains("'SqlServerLab-CSharpRequest-'+"))
if(-not $IsWindows -or -not $profileEvidenceElevated){
    Write-Host '  NOT_EXECUTED  CSharp request: real protected ephemeral profile and exact cleanup (elevated Windows required)'
}else{
    foreach($throwSupervisor in @($false,$true)){
        $script:csharpRequestRootSeen=$null
        $recordPath=Join-Path $nativeRoot ('real-recovery-'+[guid]::NewGuid().ToString('N')+'.jsonl')
        $rootSeen=$null;$caught=$null;$saved=$env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT
        try{
            Invoke-CSharpNativeWithTemporaryProfile -ProfileJson ($requestProfile|ConvertTo-Json -Compress) -RecoveryRecordPath $recordPath -RequestBinding $requestBinding -Action {
                $script:csharpRequestRootSeen=$env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT
                $actual=Get-CSharpNativeProfile -Name 'csharp-sql2025'
                if($actual.PackageSha256 -cne ('a'*64)){throw 'CSHARP_NATIVE_REQUEST_TEST_CONTENT'}
                if($throwSupervisor){throw 'CSHARP_NATIVE_REQUEST_TEST_SUPERVISOR'}
            }
        }catch{$caught=Get-CSharpNativeRequestFailureDiagnostic $_}
        $rootSeen=$script:csharpRequestRootSeen
        $good=($rootSeen -and -not(Test-Path -LiteralPath $rootSeen) -and $env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT -ceq $saved -and $(if($throwSupervisor){$caught.PrimaryFailure -ceq 'CSHARP_NATIVE_REQUEST_TEST_SUPERVISOR' -and -not $caught.ProfileCleanupFailure}else{-not $caught}))
        Add-CheckResult -Name ('CSharp request: real protected ephemeral profile and exact cleanup; supervisor throws='+$throwSupervisor) -Success $good -Message $(if($caught){$caught|ConvertTo-Json -Compress}else{'CSHARP_NATIVE_REQUEST_TEST_POSTCONDITION'})
    }
}
