#Requires -Version 7.5
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force
# Check actual exported metadata without invoking lifecycle/provider actions.
$acceptanceAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tests/Common/AuthenticatedTlsRebindRecoveryAcceptance.ps1'),[ref]$null,[ref]$null)
foreach($call in @($acceptanceAst.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-like'*-SqlServerLab*'},$true))){
    $command=Get-Command $call.GetCommandName() -Module SqlServerLab -ErrorAction Stop
    $invalid=@($call.CommandElements|Where-Object{$_-is[Management.Automation.Language.CommandParameterAst]-and-not$command.Parameters.ContainsKey($_.ParameterName)}|ForEach-Object ParameterName)
    Add-CheckResult ("Recovery harness public parameter binding at line {0}: {1}; unknown=[{2}]" -f $call.Extent.StartLineNumber,$command.Name,($invalid-join',')) ($invalid.Count-eq0)
}
foreach($name in @('DiagnosticBundleReader','AuthenticatedTlsRequest','AuthenticatedTlsRegistryIndex','AuthenticatedTlsRegistryPayload',
    'AuthenticatedTlsCaCandidate','AuthenticatedTlsContext','AuthenticatedTlsRegistryRoot','AuthenticatedTlsRegistryWriter',
    'AuthenticatedTlsLab','AuthenticatedTlsQualification','AuthenticatedTlsRestartRebind','AuthenticatedTlsRebindRecovery')){. (Join-Path $repo "Private/$name.ps1")}
. (Join-Path $repo 'Public/Update-SqlServerLabTlsBinding.ps1')
. (Join-Path $repo 'Public/Get-SqlServerLabTlsBindingRecovery.ps1')
. (Join-Path $repo 'Public/Resolve-SqlServerLabTlsBindingRecovery.ps1')
$script:ModuleRoot=$repo
function Test-RebindReject {param([scriptblock]$Action) try{& $Action|Out-Null;return $false}catch{return $true}}
$script:baseEpoch=[datetime]::UtcNow.AddMinutes(-10).ToString('O')
$script:nextEpoch=[datetime]::UtcNow.AddMinutes(-5).ToString('O')
$record=[ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.3';Provider='docker';RuntimeBinding=@{};
    AuditId='11111111-1111-4111-8111-111111111111';DataRoot='synthetic';ControllerId='22222222-2222-4222-8222-222222222222';LocationId='33333333-3333-4333-8333-333333333333';
    AuthorityRef='44444444-4444-4444-8444-444444444444';ClientRef='55555555-5555-4555-8555-555555555555';RegistrySha256=('a'*64);
    RunId='synthetic-rebind';InstanceId='primary';ScopeId='synthetic-scope';ContainerId=('b'*64);ImageId=('sha256:'+('c'*64));Port=14333;
    CertificateSha256=('d'*64);CertificateDer='AQ==';NotAfterUtc=[DateTimeOffset]::UtcNow.AddDays(1).ToString('O');StartedAt=$script:baseEpoch;
    ServerPath='/var/opt/mssql/tls-11111111111141118111111111111111';SqlProfileId='2019-CU32'}
$original=Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $record)
$oldInstant=[DateTimeOffset]::Parse($script:baseEpoch,[Globalization.CultureInfo]::InvariantCulture)
$newInstant=[DateTimeOffset]::Parse($script:nextEpoch,[Globalization.CultureInfo]::InvariantCulture)
$oldOffset=$oldInstant.ToOffset([TimeSpan]::FromHours(2)).ToString('O')
$newOffset=$newInstant.ToOffset([TimeSpan]::FromHours(2)).ToString('O')
foreach($pair in @(
    @{Name='Unchanged Docker Z format';Old=$script:baseEpoch;New=$script:nextEpoch},
    @{Name='Podman eight/nine fractional digits with explicit offset';Old=($oldOffset -replace '(\.\d{7})([+]02:00)$','${1}3${2}');New=($newOffset -replace '(\.\d{7})([+]02:00)$','${1}37${2}')},
    @{Name='Offset predecessor and Z candidate';Old=$oldOffset;New=$script:nextEpoch},
    @{Name='Z predecessor and offset candidate';Old=$script:baseEpoch;New=$newOffset},
    @{Name='UTC ordering across different positive and negative offsets';Old=$oldOffset;New=$newInstant.ToOffset([TimeSpan]::FromHours(-5)).ToString('O')}
)){
    $before=Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $record);$before.StartedAt=$pair.Old
    $candidate=Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $before);$candidate.StartedAt=$pair.New
    $accepted=$true;try{Assert-LabTlsRestartCandidate $before $candidate}catch{$accepted=$false}
    Add-CheckResult $pair.Name ($accepted -and $candidate.StartedAt -ceq $pair.New)
}
foreach($epoch in @($oldInstant.ToOffset([TimeSpan]::FromHours(-5)).ToString('O'),
    [DateTimeOffset]::UtcNow.AddHours(1).ToOffset([TimeSpan]::FromHours(-5)).ToString('O'),
    ($script:nextEpoch.TrimEnd('Z')+'+15:00'),($script:nextEpoch.TrimEnd('Z')+'+02'),$script:nextEpoch.TrimEnd('Z'))){
    $bad=Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $record);$bad.StartedAt=$epoch
    Add-CheckResult 'Equal instant, disguised future, invalid offset and missing zone remain rejected' (Test-RebindReject {Assert-LabTlsRestartCandidate $original $bad})
}
foreach($field in @('Provider','ContainerId','ImageId','Port','CertificateSha256','CertificateDer','NotAfterUtc','SqlProfileId','ScopeId','AuthorityRef','ClientRef','RegistrySha256','ServerPath',
    'RunId','InstanceId','AuditId','DataRoot','ControllerId','LocationId','RuntimeBinding')){
    $bad=Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $record);$bad.StartedAt=$script:nextEpoch
    $bad.$field=if($field -ceq 'Port'){14334}elseif($field -ceq 'Provider'){'podman'}elseif($field -ceq 'SqlProfileId'){'2022-CU27'}else{'changed'}
    Add-CheckResult "Restart candidate rejects changed immutable $field" (Test-RebindReject {Assert-LabTlsRestartCandidate $original $bad})
}
foreach($epoch in @($script:baseEpoch,'invalid',[datetime]::UtcNow.AddHours(1).ToString('O'),[datetime]::UtcNow.AddHours(-1).ToString('O'))){
    $bad=Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $record);$bad.StartedAt=$epoch
    Add-CheckResult 'Repeated, malformed, future and backwards epochs are rejected' (Test-RebindReject {Assert-LabTlsRestartCandidate $original $bad})
}
$legacy=Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $record);$legacy.ContractVersion='SqlServerLab.AuthenticatedTlsLab/0.1'
Add-CheckResult 'Legacy unpinned records cannot enter restart rebind' (Test-RebindReject {Get-LabTlsRebindIdentityDigest $legacy})
if($IsWindows){
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-tls-rebind-'+[guid]::NewGuid().ToString('N'))
    $script:rebindNative=Get-LabTlsWindowsProcessFacts
    $script:rebindAuthority=[pscustomobject]@{Native=$script:rebindNative;RegistrySha256=('a'*64);ActorDigest=('e'*64);RootDigest=('f'*64);
        Authority=[pscustomobject]@{Ref=$record.AuthorityRef;Generation=1;TrustScopeRef='66666666-6666-4666-8666-666666666666';CertificateSha256=('1'*64)};
        Client=[pscustomobject]@{Ref=$record.ClientRef;Generation=1;Details=[pscustomobject]@{SqlClientDiskSha256=('2'*64);SqlClientLoadedMvid='77777777-7777-4777-8777-777777777777'}}}
    function Reset-RebindFixture {
        $script:rebindRoot=Join-Path $fixture ([guid]::NewGuid().ToString('D'))
        Initialize-LabTlsCaPrivateDirectory $script:rebindRoot $script:rebindNative.UserSid -NewOnly
        $record.DataRoot=$script:rebindRoot;$record.StartedAt=$script:baseEpoch
        Write-LabTlsCaPrivateFile (Join-Path $script:rebindRoot 'authenticated-tls-lab.json') $script:rebindNative.UserSid (ConvertTo-LabTlsRegistryWriterBytes $record)
        $script:observedEpoch=$script:baseEpoch;$script:sqlChecks=0;$script:odbcChecks=0;$script:boundReads=0
        $script:probeFails=$false;$script:postCommitFails=$false;$script:sourceDrifts=$false
    }
    # Actual private qualification, ACL/file IO, writer lock, atomic replace and
    # history reader; only authority/provider/client observations are injected.
    function Get-LabTlsOwnBinding {
        param($StateRoot,$RunId,$InstanceId)
        if($StateRoot -cne $script:rebindRoot -or $RunId -cne 'synthetic-rebind' -or $InstanceId -cne 'primary'){throw 'TLS_FIXTURE_SCOPE_CHANGED'}
        $script:boundReads++
        $path=Join-Path $StateRoot 'authenticated-tls-lab.json'
        if($script:sourceDrifts -and $script:boundReads -eq 5){
            $drift=Read-LabTlsLabRecord (Read-LabTlsCaPrivateFile $path $script:rebindNative.UserSid 32768)
            $drift.StartedAt=[datetime]::UtcNow.AddMinutes(-1).ToString('O')
            [IO.File]::WriteAllBytes($path,(ConvertTo-LabTlsRegistryWriterBytes $drift))
        }
        $bytes=Read-LabTlsCaPrivateFile $path $script:rebindNative.UserSid 32768
        return [pscustomobject]@{Record=(Read-LabTlsLabRecord $bytes);Bytes=$bytes;Authority=$script:rebindAuthority;StateRoot=$StateRoot}
    }
    function New-LabTlsRuntimeBudget {param($Provider,$StateRoot,$Record) $null=$StateRoot;[pscustomobject]@{Provider=$Provider;Record=$Record}}
    function Assert-LabTlsOwnContainer {param($Record,$StateRoot,$Budget) $null=$Record,$StateRoot,$Budget;[pscustomobject]@{Inspect=[pscustomobject]@{State=[pscustomobject]@{StartedAt=$script:observedEpoch}}}}
    function Assert-LabTlsSqlCertificateBinding {
        param($Record,$StateRoot,$Budget) $null=$Budget
        if($Record.StartedAt -cne $script:observedEpoch){throw 'TLS_FIXTURE_EPOCH_DRIFT'}
        if($script:postCommitFails){
            $live=Read-LabTlsLabRecord (Read-LabTlsCaPrivateFile (Join-Path $StateRoot 'authenticated-tls-lab.json') $script:rebindNative.UserSid 32768)
            if($live.StartedAt -ceq $Record.StartedAt){throw 'TLS_FIXTURE_POSTCOMMIT_LOST_REPLY'}
        }
        [pscustomobject]@{RunDirectory=$StateRoot}
    }
    function Get-LabSecret {param($Path,$Name) $null=$Path,$Name;[securestring]::new()}
    function Invoke-LabTlsStrictSqlClient {param($Port,$Password,$ExpectedBuild) $null=$Port,$Password;if($ExpectedBuild -cne '15.0.4430.1'){throw 'TLS_FIXTURE_WRONG_BUILD'};$script:sqlChecks++}
    function Invoke-LabTlsStrictSqlcmd {
        param($Port,$Password,$Client,$ExpectedBuild) $null=$Port,$Password,$Client
        if($ExpectedBuild -cne '15.0.4430.1'){throw 'TLS_FIXTURE_WRONG_BUILD'};$script:odbcChecks++
        if($script:probeFails){throw 'TLS_FIXTURE_CLIENT_REJECTED'}
        [pscustomobject]@{SqlcmdSha256=('3'*64);LoadedOdbcSha256=('4'*64);LoadedOdbcBytes=42}
    }
    try {
        Initialize-LabTlsCaPrivateDirectory $fixture $script:rebindNative.UserSid -NewOnly
        Reset-RebindFixture
        $candidate=Read-LabTlsLabRecord (ConvertTo-LabTlsRegistryWriterBytes $record);$candidate.StartedAt=$script:nextEpoch
        Add-CheckResult 'Candidate qualification requires the exact expected source digest before clients' ((Test-RebindReject {Test-LabAuthenticatedTlsEnvironment -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -RestartCandidate $candidate -ExpectedSourceSha256 ('0'*64)}) -and $script:sqlChecks -eq 0)
        $message='';try{$null=Test-LabAuthenticatedTlsEnvironment -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -RestartCandidate $candidate -ExpectedSourceSha256 (Get-LabTlsCaByteDigest (ConvertTo-LabTlsRegistryWriterBytes $record))}catch{$message=$_.Exception.Message}
        Add-CheckResult 'Candidate qualification requires the actual held internal writer lock before clients' ($message -ceq 'TLS_REBIND_HELD_LOCK_REQUIRED' -and $script:sqlChecks -eq 0 -and $script:odbcChecks -eq 0)
        $script:boundReads=0
        $null=Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -WhatIf
        Add-CheckResult 'Actual public WhatIf performs no authority/provider/client or state work' ($script:boundReads -eq 0 -and $script:sqlChecks -eq 0 -and @(Get-ChildItem -LiteralPath $script:rebindRoot).Count -eq 1)
        $result=Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -Confirm:$false
        Add-CheckResult 'Unchanged epoch is a no-op without a fresh proof or storage creation' ($result.Status -ceq 'UNCHANGED_ALREADY_BOUND' -and $result.QualificationStatus -ceq 'NOT_EXECUTED' -and $script:sqlChecks -eq 0 -and -not(Test-Path -LiteralPath (Join-Path $script:rebindRoot 'authenticated-tls-rebind')))
        $before=[IO.File]::ReadAllBytes((Join-Path $script:rebindRoot 'authenticated-tls-lab.json'))
        $script:observedEpoch=$script:nextEpoch
        $result=Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -Confirm:$false
        $after=Get-LabTlsOwnBinding $script:rebindRoot synthetic-rebind primary
        Add-CheckResult 'Actual rebind commits only after both strict client boundaries' ($result.BindingUpdated -and $result.QualificationStatus -ceq 'QUALIFIED' -and $script:sqlChecks -eq 1 -and $script:odbcChecks -eq 1 -and $after.Record.StartedAt -ceq $script:observedEpoch)
        $binding=[pscustomobject]@{Directory=(Join-Path $script:rebindRoot 'authenticated-tls-rebind');Native=$script:rebindNative}
        Add-CheckResult 'Durable actual predecessor/candidate/backup/commit chain reads back' ((Read-LabTlsRebindHistory $binding $after.Record $after.Bytes) -eq 1)
        $transaction=@(Get-ChildItem -LiteralPath $binding.Directory -Directory)[0].FullName
        Add-CheckResult 'File.Replace preserves the exact original bytes in its actual backup' ((Get-LabTlsCaByteDigest ([IO.File]::ReadAllBytes((Join-Path $transaction 'source.json')))) -ceq (Get-LabTlsCaByteDigest $before))
        $normal=Test-LabAuthenticatedTlsEnvironment -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot
        Add-CheckResult 'Complete committed history permits ordinary fresh qualification with both clients' ($normal.Status -ceq 'QUALIFIED' -and $normal.StartedAt -ceq $script:observedEpoch -and $script:sqlChecks -eq 2 -and $script:odbcChecks -eq 2)
        $script:observedEpoch=[datetime]::UtcNow.AddMinutes(-2).ToString('O')
        $null=Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -Confirm:$false
        $after=Get-LabTlsOwnBinding $script:rebindRoot synthetic-rebind primary
        Add-CheckResult 'A second explicit restart extends the exact predecessor chain' ((Read-LabTlsRebindHistory $binding $after.Record $after.Bytes) -eq 2 -and $script:sqlChecks -eq 3 -and $script:odbcChecks -eq 3)
        $lock=Enter-LabTlsRegistryWriterLock $binding
        try {
            Add-CheckResult 'Held actual writer file lock rejects a competing rebind' (Test-RebindReject {Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -Confirm:$false})
            $count=$script:sqlChecks
            Add-CheckResult 'Held actual writer file lock blocks ordinary qualification before clients' ((Test-RebindReject {Test-LabAuthenticatedTlsEnvironment -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot}) -and $script:sqlChecks -eq $count)
        }finally{Exit-LabTlsRegistryWriterLock $lock}
        $pending=Join-Path $binding.Directory ([guid]::NewGuid().ToString('D'))
        Initialize-LabTlsCaPrivateDirectory $pending $script:rebindNative.UserSid -NewOnly
        Write-LabTlsCaPrivateFile (Join-Path $pending 'intent.json') $script:rebindNative.UserSid ([Text.Encoding]::UTF8.GetBytes('{}'))
        $count=$script:sqlChecks
        Add-CheckResult 'Pending history blocks even an unchanged-epoch no-op before new clients' ((Test-RebindReject {Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -Confirm:$false}) -and $script:sqlChecks -eq $count)
        Reset-RebindFixture;$script:observedEpoch=$script:nextEpoch;$script:probeFails=$true
        $before=Get-FileHash -LiteralPath (Join-Path $script:rebindRoot 'authenticated-tls-lab.json')
        Add-CheckResult 'Failed second strict client preserves binding and starts no transaction' ((Test-RebindReject {Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -Confirm:$false}) -and
            (Get-FileHash -LiteralPath $before.Path).Hash -ceq $before.Hash -and @(Get-ChildItem -LiteralPath (Join-Path $script:rebindRoot 'authenticated-tls-rebind') -Directory).Count -eq 0)
        Reset-RebindFixture;$script:observedEpoch=$script:nextEpoch;$script:sourceDrifts=$true
        Add-CheckResult 'Changed actual source bytes after intent are rejected without overwrite' (Test-RebindReject {Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -Confirm:$false})
        $drift=Read-LabTlsLabRecord ([IO.File]::ReadAllBytes((Join-Path $script:rebindRoot 'authenticated-tls-lab.json')))
        Add-CheckResult 'External source drift is retained, never silently rolled back' ($drift.StartedAt -cne $script:baseEpoch -and $drift.StartedAt -cne $script:nextEpoch)
        Reset-RebindFixture;$script:observedEpoch=$script:nextEpoch;$script:postCommitFails=$true
        $message='';try{$null=Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -Confirm:$false}catch{$message=$_.Exception.Message}
        $after=Get-LabTlsOwnBinding $script:rebindRoot synthetic-rebind primary
        Add-CheckResult 'Unknown post-replace result preserves installed candidate and recovery need' ($message -ceq 'TLS_REBIND_RECOVERY_REQUIRED' -and $after.Record.StartedAt -ceq $script:nextEpoch)
        $count=$script:sqlChecks;$script:postCommitFails=$false
        Add-CheckResult 'Lost reply is not a success or permission to replay' ((Test-RebindReject {Update-SqlServerLabTlsBinding -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot -Confirm:$false}) -and $script:sqlChecks -eq $count)
        foreach($operation in @('qualification','export','readback')){
            $count=$script:sqlChecks;$odbcCount=$script:odbcChecks;$message=''
            $blockedOutput=Join-Path $script:rebindRoot 'blocked-export'
            try{
                switch($operation){
                    qualification {$null=Test-LabAuthenticatedTlsEnvironment -RunId synthetic-rebind -InstanceId primary -StateRoot $script:rebindRoot}
                    export {$null=Export-LabAuthenticatedTlsEnvironment -OutputDirectory $blockedOutput -StateRoot $script:rebindRoot -RunId synthetic-rebind -InstanceId primary}
                    readback {$null=Test-LabTlsQualifiedExport -Path (Join-Path $blockedOutput 'TestUmgebung.json') -StateRoot $script:rebindRoot -RunId synthetic-rebind -InstanceId primary}
                }
            }catch{$message=$_.Exception.Message}
            Add-CheckResult "Uncommitted installed candidate blocks ordinary $operation before clients or output" ($message -ceq 'TLS_REBIND_RECOVERY_REQUIRED' -and
                $script:sqlChecks -eq $count -and $script:odbcChecks -eq $odbcCount -and -not(Test-Path -LiteralPath $blockedOutput))
        }
        . (Join-Path $PSScriptRoot 'Fixtures/AuthenticatedTlsRebindRecoveryChecks.ps1')
    } catch {Add-CheckResult ('Restart rebind fixture failed: '+$_.Exception.Message) $false;Write-Host $_.ScriptStackTrace}
    finally {
        if(Test-Path -LiteralPath $fixture){
            $resolved=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^sql-lab-tls-rebind-[0-9a-f]{32}$'){throw 'FIXTURE_CLEANUP_SCOPE_INVALID'}
            Remove-Item -LiteralPath $resolved -Recurse -Force
            Add-CheckResult 'Own lock/history/record fixtures fully removed' (-not(Test-Path -LiteralPath $resolved))
        }
    }
}else{Write-Host 'Actual Windows ACL/replace/lock fixture: NOT_EXECUTED (Windows required)'}
Write-Host "TLS Restart Rebind: $passed PASS / $($failures.Count) FAIL"
if($failures.Count){exit 1}
