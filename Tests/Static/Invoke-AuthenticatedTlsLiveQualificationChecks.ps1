#Requires -Version 7.5
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
. (Join-Path $repo 'Private/AuthenticatedTlsLab.ps1')
. (Join-Path $repo 'Private/AuthenticatedTlsLiveQualification.ps1')

$begin=[DateTimeOffset]::Parse('2026-10-23T12:00:00+00:00')
$end=$begin.AddSeconds(10)
$run='11111111-1111-4111-8111-111111111111'
function New-LiveSample {
    param([string]$Provider='docker',[string]$Version='2025-CU9')
    $profile=Get-LabTlsSqlProfile $Version
    return [pscustomobject]@{
        ContractVersion='SqlServerLab.TlsQualification/0.1';Status='QUALIFIED'
        RunId=$run;InstanceId='primary';Provider=$Provider
        SqlVersion=$profile.SqlVersion;Patch=$profile.Patch;SqlBuild=$profile.SqlBuild
        Encrypt=$true;TrustServerCertificate=$false
        QualifiedAt=$begin.AddSeconds(5).ToString('o');ExpiresAt=$begin.AddMinutes(15).ToString('o')
        Evidence='FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD';WireCertificateFingerprint='NOT_OBSERVED'
        PrivateMetadata='SYNTHETIC_PRIVATE_MARKER'
    }
}
function Invoke-LiveProjection {
    param([object]$Sample,[DateTimeOffset]$Observed=$end)
    ConvertTo-LabTlsLiveQualificationResult -Qualification $Sample -RunId $run -InstanceId primary -StartedAt $begin -ObservedAt $Observed
}
function Test-LiveReject {
    param([scriptblock]$Action)
    try{& $Action|Out-Null;return $false}catch{return $_.Exception.Message -ceq 'TLS_LIVE_QUALIFICATION_RESULT_INVALID' -or $_.Exception.Message -ceq 'TLS_LAB_SQL_PROFILE_UNSUPPORTED'}
}
foreach($provider in @('docker','podman')){
    foreach($version in @('2019-CU32','2022-CU27','2025-CU9')){
        $result=Invoke-LiveProjection (New-LiveSample $provider $version)
        $profile=Get-LabTlsSqlProfile $version
        Add-CheckResult "Observation preserves selected $provider/$version and strict booleans" (
            $result.Status -ceq 'QUALIFIED_AT_OBSERVATION' -and $result.Provider -ceq $provider -and
            $result.SqlBuild -ceq $profile.SqlBuild -and $result.Encrypt -is [bool] -and $result.Encrypt -and
            $result.TrustServerCertificate -is [bool] -and -not $result.TrustServerCertificate
        )
    }
}
$expected=@('ContractVersion','Status','RunId','InstanceId','Provider','SqlVersion','Patch','SqlBuild','Encrypt',
    'TrustServerCertificate','QualifiedAtUtc','ObservedAtUtc','ExpiresAtUtc','ClientChecks','Evidence','WireCertificateFingerprint')
$sample=New-LiveSample
$sample|Add-Member ScriptProperty IgnoredSecret {throw 'SYNTHETIC_GETTER_MUST_NOT_RUN'}
$result=Invoke-LiveProjection $sample
Add-CheckResult 'Public result is a closed secret-free observation with both designated clients' (
    @($result.PSObject.Properties).Count -eq $expected.Count -and
    @(Compare-Object @($expected|Sort-Object) @($result.PSObject.Properties.Name|Sort-Object)).Count -eq 0 -and
    $result.ContractVersion -ceq 'SqlServerLab.TlsLiveQualificationResult/0.1' -and
    ($result.ClientChecks -join ',') -ceq 'SYSTEM_DATA_SQLCLIENT,ODBC_SQLCMD' -and
    ($result|ConvertTo-Json -Depth 5) -notmatch 'SYNTHETIC_PRIVATE_MARKER|IgnoredSecret|Endpoint|Authority|Digest|StateRoot'
)
Add-CheckResult 'Observation keeps original validity without extending or claiming wire capture' (
    $result.QualifiedAtUtc -ceq $sample.QualifiedAt -and $result.ExpiresAtUtc -ceq $sample.ExpiresAt -and
    $result.ObservedAtUtc -ceq $end.ToString('o') -and $result.WireCertificateFingerprint -ceq 'NOT_OBSERVED'
)
foreach($case in @(
    @{Name='other run';Field='RunId';Value='22222222-2222-4222-8222-222222222222'},
    @{Name='other instance';Field='InstanceId';Value='other'},
    @{Name='other provider';Field='Provider';Value='hyperv'},
    @{Name='wrong build';Field='SqlBuild';Value='17.0.1000.7'},
    @{Name='profile reinterpretation';Field='SqlVersion';Value='2022'},
    @{Name='noncanonical patch';Field='Patch';Value='CU9'},
    @{Name='unqualified';Field='Status';Value='READY'},
    @{Name='wrong contract';Field='ContractVersion';Value='SqlServerLab.TlsQualification/9.0'},
    @{Name='bypass';Field='TrustServerCertificate';Value=$true},
    @{Name='no encryption';Field='Encrypt';Value=$false},
    @{Name='text boolean';Field='Encrypt';Value='true'},
    @{Name='numeric boolean';Field='TrustServerCertificate';Value=0},
    @{Name='null evidence';Field='Evidence';Value=$null},
    @{Name='claimed wire capture';Field='WireCertificateFingerprint';Value=('a'*64)},
    @{Name='missing client evidence';Field='Evidence';Value='SQLCLIENT_ONLY'},
    @{Name='oversize scalar';Field='SqlBuild';Value=('x'*129)},
    @{Name='old proof';Field='QualifiedAt';Value=$begin.AddSeconds(-1).ToString('o')},
    @{Name='future proof';Field='QualifiedAt';Value=$end.AddSeconds(1).ToString('o')},
    @{Name='expired';Field='ExpiresAt';Value=$end.ToString('o')},
    @{Name='excessive validity';Field='ExpiresAt';Value=$begin.AddMinutes(16).ToString('o')},
    @{Name='unparseable time';Field='QualifiedAt';Value='not-a-time'}
)){
    $bad=New-LiveSample;$bad.($case.Field)=$case.Value
    Add-CheckResult ("Rejects "+$case.Name) (Test-LiveReject {Invoke-LiveProjection $bad})
}
$bad=New-LiveSample;$bad.PSObject.Properties.Remove('Status')
Add-CheckResult 'Missing qualification is not a successful observation' (Test-LiveReject {Invoke-LiveProjection $bad})
$script:liveGetterRan=$false
$bad=New-LiveSample;$bad.PSObject.Properties.Remove('RunId')
$bad|Add-Member ScriptProperty RunId {$script:liveGetterRan=$true;return $run}
$rejected=Test-LiveReject {Invoke-LiveProjection $bad}
Add-CheckResult 'Required ETS getter is rejected without execution' ($rejected -and -not $script:liveGetterRan)
Add-CheckResult 'Arrays cannot stand in for one qualification' (Test-LiveReject {Invoke-LiveProjection @((New-LiveSample),(New-LiveSample))})
Add-CheckResult 'Rewound observation clock fails closed' (Test-LiveReject {Invoke-LiveProjection (New-LiveSample) $begin.AddSeconds(-1)})
Add-CheckResult 'Expiry during return does not produce a positive result' (Test-LiveReject {Invoke-LiveProjection (New-LiveSample) $begin.AddMinutes(15)})

# Exercise the actual public wrapper in an isolated module. The injected
# backend is not a SQL proof; native acceptance must use the real backend.
$subject=New-Module -ArgumentList $repo,(New-LiveSample),$begin,$end -ScriptBlock {
    param($Root,$Sample,$Begin,$End)
    . (Join-Path $Root 'Private/AuthenticatedTlsLab.ps1')
    . (Join-Path $Root 'Private/AuthenticatedTlsLiveQualification.ps1')
    . (Join-Path $Root 'Public/Test-SqlServerLabTlsQualification.ps1')
    $script:sample=$Sample;$script:begin=$Begin;$script:end=$End
    $script:calls=0;$script:clockCalls=0;$script:unsupported=$false;$script:fault=$false
    function Assert-LabTlsLiveQualificationHost {if($script:unsupported){throw 'TLS_LIVE_QUALIFICATION_WINDOWS_POWERSHELL_7_5_REQUIRED'}}
    function Get-LabTlsLiveQualificationUtcNow {$script:clockCalls++;if($script:clockCalls -eq 1){return $script:begin};return $script:end}
    function Test-LabAuthenticatedTlsEnvironment {
        param($RunId,$InstanceId,$StateRoot)
        $script:calls++;$script:selection=@($RunId,$InstanceId,$StateRoot)
        if($script:fault){throw 'SYNTHETIC_PRIVATE_BACKEND_DIAGNOSTIC'}
        return $script:sample
    }
    Export-ModuleMember -Function Test-SqlServerLabTlsQualification
}
try{
    $root=Join-Path ([IO.Path]::GetTempPath()) 'synthetic-live-qualification'
    $result=& $subject {param($R,$S) Test-SqlServerLabTlsQualification -RunId $R -InstanceId primary -StateRoot $S} $run $root
    $state=& $subject {@{Calls=$script:calls;Selection=$script:selection}}
    Add-CheckResult 'Public wrapper performs one fresh selected qualification without export or cache' (
        $state.Calls -eq 1 -and ($state.Selection -join '|') -ceq ($run+'|primary|'+$root) -and $result.Status -ceq 'QUALIFIED_AT_OBSERVATION'
    )
    & $subject {$script:fault=$true;$script:clockCalls=0}
    $message='';try{& $subject {param($R,$S) Test-SqlServerLabTlsQualification -RunId $R -InstanceId primary -StateRoot $S} $run $root|Out-Null}catch{$message=$_.Exception.Message}
    Add-CheckResult 'Backend failure is closed and never reflects private diagnostics' ($message -ceq 'TLS_LIVE_QUALIFICATION_REJECTED')
    & $subject {$script:unsupported=$true;$script:calls=0;$script:clockCalls=0}
    $message='';try{& $subject {param($R,$S) Test-SqlServerLabTlsQualification -RunId $R -InstanceId primary -StateRoot $S} $run $root|Out-Null}catch{$message=$_.Exception.Message}
    $state=& $subject {@{Calls=$script:calls;ClockCalls=$script:clockCalls}}
    Add-CheckResult 'Unsupported host reports required capability before backend work' (
        $message -ceq 'TLS_LIVE_QUALIFICATION_WINDOWS_POWERSHELL_7_5_REQUIRED' -and $state.Calls -eq 0 -and $state.ClockCalls -eq 0
    )
}finally{Remove-Module $subject -Force -ErrorAction SilentlyContinue}
. (Join-Path $repo 'Tests/Common/AuthenticatedTlsAcceptanceSelection.ps1')
. (Join-Path $repo 'Tests/Common/AuthenticatedTlsLiveQualificationAcceptance.ps1')
$expected=Get-OwnedTlsAcceptanceProfile '2025-CU9';$lab=[pscustomobject]@{RunId=$run}
$observation=Invoke-LiveProjection (New-LiveSample)
$oraclePassed=$true;try{Assert-OwnedTlsLiveObservation $observation $expected $lab docker $begin $end}catch{$oraclePassed=$false}
Add-CheckResult 'Independent native oracle accepts the selected closed observation' $oraclePassed
$wrong=Invoke-LiveProjection (New-LiveSample docker '2022-CU27')
$message='';try{Assert-OwnedTlsLiveObservation $wrong $expected $lab docker $begin $end}catch{$message=$_.Exception.Message}
Add-CheckResult 'Independent native oracle rejects a self-consistent different SQL profile' ($message -ceq 'TLS_ACCEPTANCE_REQUESTED_SQL_PROFILE_CHANGED')
foreach($case in @(
    @{Name='private output field';Field='Secret';Value='SYNTHETIC_PRIVATE_MARKER';Error='TLS_LIVE_ACCEPTANCE_CLOSED_RESULT_REQUIRED'},
    @{Name='prior observation';Field='QualifiedAtUtc';Value=$begin.AddSeconds(-1).ToString('o');Error='TLS_LIVE_ACCEPTANCE_FRESH_OBSERVATION_REQUIRED'},
    @{Name='one missing stack';Field='ClientChecks';Value=@('SYSTEM_DATA_SQLCLIENT');Error='TLS_LIVE_ACCEPTANCE_OBSERVATION_INVALID'}
)){
    $bad=Invoke-LiveProjection (New-LiveSample)
    $bad|Add-Member NoteProperty $case.Field $case.Value -Force
    $message='';try{Assert-OwnedTlsLiveObservation $bad $expected $lab docker $begin $end}catch{$message=$_.Exception.Message}
    Add-CheckResult ('Independent native oracle rejects '+$case.Name) ($message -ceq $case.Error)
}
$harness=Join-Path $repo 'Tests/Integration/Invoke-AuthenticatedTlsLabAcceptance.ps1'
$selection=@{DataRoot=$root;ControllerId=$run;LocationId=$run;CandidateId=$run;EvidenceDirectory=(Join-Path $root 'synthetic-evidence');Execute=$true;ExerciseLiveQualification=$true}
foreach($flag in @('KeepLab','ExerciseRestartRebind')){
    $arguments=$selection.Clone();$arguments[$flag]=$true;$message=''
    try{& $harness @arguments|Out-Null}catch{$message=$_.Exception.Message}
    Add-CheckResult ('Live harness rejects competing scenario before module/provider work: '+$flag) ($message -ceq 'TLS_ACCEPTANCE_LIVE_REQUIRES_EXCLUSIVE_SCENARIO_AND_CLEANUP')
}
$stop=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-live-stop-'+[guid]::NewGuid().ToString('N'))
try{
    [IO.File]::WriteAllText($stop,'SYNTHETIC_STOP_REQUESTED')
    $message=''
    try{Invoke-OwnedTlsLiveQualificationScenario -Lab $null -Results ([Collections.Generic.List[object]]::new()) -StopFile $stop}
    catch{$message=$_.Exception.Message}
    Add-CheckResult 'Requested stop rejects before any public API or lifecycle work' ($message -ceq 'TLS_LIVE_ACCEPTANCE_STOP_REQUESTED')
}finally{if(Test-Path -LiteralPath $stop){Remove-Item -LiteralPath $stop -Force}}
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL; native SQL/provider actions: 0"
if($failures.Count){exit 1}
