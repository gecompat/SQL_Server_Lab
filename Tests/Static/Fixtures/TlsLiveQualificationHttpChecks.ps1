# Actual state layout, public wrapper, HTTP and async dispatcher; SQL leaf synthetic.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $PSScriptRoot '../../Common/CheckResult.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
foreach($file in @('Private/StateMachine.ps1','Private/DiagnosticBundleReader.ps1','Private/AuthenticatedTlsLab.ps1',
    'Private/AuthenticatedTlsLiveQualification.ps1','Private/AuthenticatedTlsLiveQualificationHttp.ps1',
    'Public/Test-SqlServerLabTlsQualification.ps1','Tools/WorkflowUiTlsLiveQualification.ps1')){. (Join-Path $repo $file)}
$run='11111111-1111-4111-8111-111111111111';$script:calls=0
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temp=Join-Path $tempBase ('sql-lab-tls-ui-fixture-'+[guid]::NewGuid().ToString('n'))
$state=Join-Path $temp 'Data/State/authenticated-tls-labs/33333333-3333-4333-8333-333333333333'
$runDirectory=Join-Path (Join-Path $state 'runs') $run
$null=New-Item -ItemType Directory -Path $runDirectory
$runPath=Join-Path $runDirectory 'run-state.json'
$stateBefore=$env:SQL_SERVER_LAB_STATE;$env:SQL_SERVER_LAB_STATE=$state
$modulePath=Join-Path $temp 'SqlServerLab.psm1';$release=Join-Path $temp 'release'
$records=@{};$jobs=@{};$module=$null
function Write-SyntheticRun([switch]$Duplicate){
    $instances=@([pscustomobject]@{Id='primary';Provider='docker';Version='2025-CU9'})
    if($Duplicate){$instances+=@($instances[0])}
    $value=@{contractVersion='SqlServerLab.RunState/1.0';runId=$run;state='RUNNING';metadata=@{desiredState=@{Instances=$instances}}}
    [IO.File]::WriteAllText($runPath,($value|ConvertTo-Json -Depth 6))
}
function Assert-LabTlsLiveQualificationHost {}
function Test-LabAuthenticatedTlsEnvironment {
    param($RunId,$InstanceId,$StateRoot)
    if($StateRoot -cne $env:SQL_SERVER_LAB_STATE){throw 'SYNTHETIC_WRONG_STATE'}
    $script:calls++;$now=[DateTimeOffset]::UtcNow
    [pscustomobject]@{ContractVersion='SqlServerLab.TlsQualification/0.1';Status='QUALIFIED';RunId=$RunId;InstanceId=$InstanceId;
        Provider='docker';SqlVersion='2025';Patch='cu9';SqlBuild='17.0.5005.3';Encrypt=$true;TrustServerCertificate=$false;
        QualifiedAt=$now.ToString('o');ExpiresAt=$now.AddMinutes(15).ToString('o');Evidence='FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD';WireCertificateFingerprint='NOT_OBSERVED'}
}
try {
    Write-SyntheticRun
    $body=@{RunId=$run;InstanceId='primary';Provider='docker'}|ConvertTo-Json -Compress
    $target=Get-LabTlsLiveQualificationHttpTarget (Get-LabTlsLiveQualificationHttpSelection $body)
    $result=Invoke-LabTlsLiveQualificationHttpRequest -Body $body
    Add-CheckResult 'Real configured audit/runs layout binds original StateRoot reader and one synthetic SQL leaf' (
        $script:calls -eq 1 -and $target.StateRoot -ceq $state -and $result.RunId -ceq $run -and $result.Status -ceq 'QUALIFIED_AT_OBSERVATION')
    Add-CheckResult 'HTTP returns exactly public16 fields without private state or credentials' (
        @($result.PSObject.Properties).Count -eq 16 -and ($result|ConvertTo-Json -Compress) -notmatch 'StateRoot|Password|Endpoint')
    foreach($bad in @(
        '{}','[]',('{"RunId":"'+$run+'","runid":"'+$run+'","InstanceId":"primary","Provider":"docker"}'),
        ('{"RunId":"'+$run+'","InstanceId":"primary","Provider":"docker","StateRoot":"'+$state.Replace('\','\\')+'"}'),
        ('{"RunId":"'+$run+'","InstanceId":"primary","Provider":"hyperv"}'),
        ('{"RunId":"'+$run+'","InstanceId":false,"Provider":"docker"}'),
        ('{"RunId":"'+$run+'","InstanceId":"primary","Provider":"podman"}'),
        ('{"RunId":"22222222-2222-4222-8222-222222222222","InstanceId":"primary","Provider":"docker"}')
    )){
        $before=$script:calls;$rejected=$false
        try{Invoke-LabTlsLiveQualificationHttpRequest -Body $bad|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'TLS_LIVE_HTTP_REJECTED'}
        Add-CheckResult 'Invalid, duplicate, client path or foreign tuple rejected before SQL leaf' ($rejected -and $script:calls -eq $before)
    }
    Write-SyntheticRun -Duplicate
    $rejected=$false
    try{Invoke-LabTlsLiveQualificationHttpRequest -Body $body|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'TLS_LIVE_HTTP_REJECTED'}
    Add-CheckResult 'Actual file with ambiguous instances does not choose a target' ($rejected -and $script:calls -eq 1)
    Write-SyntheticRun
    foreach($field in @('ContractVersion','Status')){
        foreach($value in @($true,@($result.$field,$result.$field))){
            $bad=$result.PSObject.Copy();$bad.$field=$value;$rejected=$false
            try{ConvertTo-LabTlsLiveQualificationHttpResult $bad $target ([DateTimeOffset]::UtcNow.AddMinutes(-1))|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'TLS_LIVE_HTTP_REJECTED'}
            Add-CheckResult "Typed discriminator $field rejects bool/array without promoting success" $rejected
        }
    }
    $extra=$result.PSObject.Copy();$extra|Add-Member NoteProperty PrivateSecret 'SYNTHETIC_SECRET';$rejected=$false
    try{ConvertTo-LabTlsLiveQualificationHttpResult $extra $target ([DateTimeOffset]::UtcNow.AddMinutes(-1))|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'TLS_LIVE_HTTP_REJECTED'}
    Add-CheckResult 'Unknown result property is rejected rather than serialized' $rejected
    $getter=$result.PSObject.Copy();$getter.PSObject.Properties.Remove('ObservedAtUtc');$getter|Add-Member ScriptProperty ObservedAtUtc {throw 'SYNTHETIC_GETTER_EXECUTED'};$rejected=$false
    try{ConvertTo-LabTlsLiveQualificationHttpResult $getter $target ([DateTimeOffset]::UtcNow.AddMinutes(-1))|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'TLS_LIVE_HTTP_REJECTED'}
    Add-CheckResult 'Executable DTO getter is rejected without evaluation' $rejected
    # Original layout readers run in the real ThreadJob. Only SQL and the host
    # capability are synthetic; the SQL leaf waits for release.
    $source=@'
. '__REPO__/Private/StateMachine.ps1'
. '__REPO__/Private/DiagnosticBundleReader.ps1'
. '__REPO__/Private/AuthenticatedTlsLab.ps1'
. '__REPO__/Private/AuthenticatedTlsLiveQualification.ps1'
. '__REPO__/Private/AuthenticatedTlsLiveQualificationHttp.ps1'
. '__REPO__/Public/Test-SqlServerLabTlsQualification.ps1'
function Assert-LabTlsLiveQualificationHost {}
function Test-LabAuthenticatedTlsEnvironment {
param($RunId,$InstanceId,$StateRoot)
if($StateRoot -cne $env:SQL_SERVER_LAB_STATE){throw 'SYNTHETIC_WRONG_STATE'}
$until=[DateTimeOffset]::UtcNow.AddSeconds(10)
while(-not [IO.File]::Exists('__RELEASE__')){if([DateTimeOffset]::UtcNow -ge $until){throw 'SYNTHETIC_GATE_TIMEOUT'};Start-Sleep -Milliseconds 20}
$now=[DateTimeOffset]::UtcNow
[pscustomobject]@{ContractVersion='SqlServerLab.TlsQualification/0.1';Status='QUALIFIED';RunId=$RunId;InstanceId=$InstanceId;Provider='docker';SqlVersion='2025';Patch='cu9';SqlBuild='17.0.5005.3';Encrypt=$true;TrustServerCertificate=$false;QualifiedAt=$now.ToString('o');ExpiresAt=$now.AddMinutes(15).ToString('o');Evidence='FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD';WireCertificateFingerprint='NOT_OBSERVED'}
}
'@
    [IO.File]::WriteAllText($modulePath,$source.Replace('__REPO__',$repo.Replace("'","''")).Replace('__RELEASE__',$release.Replace("'","''")))
    $module=Import-Module $modulePath -Force -PassThru
    function Test-UiTlsLiveQualificationAvailable {return $true}
    $accepted=Start-UiTlsLiveQualificationJob -Records $records -Jobs $jobs -ModulePath $modulePath -Body $body
    $poll=Get-UiTlsLiveQualificationJob -Records $records -Id $accepted.Id
    Add-CheckResult 'Real ThreadJob returns acceptance and pending while SQL leaf is held' ($accepted.Status -ceq 'ACCEPTED' -and $poll.Status -ceq 'PENDING' -and $jobs.Count -eq 1)
    $rejected=$false
    try{Start-UiTlsLiveQualificationJob -Records $records -Jobs $jobs -ModulePath $modulePath -Body $body|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'TLS_LIVE_UI_BUSY'}
    Add-CheckResult 'Second request cannot create another nonterminal job' ($rejected -and $records.Count -eq 1 -and $jobs.Count -eq 1)
    [IO.File]::WriteAllText($release,'release')
    if(-not(Wait-Job -Job $jobs[$accepted.Id].Job -Timeout 15)){throw 'SYNTHETIC_JOB_NOT_TERMINAL'}
    $poll=Get-UiTlsLiveQualificationJob -Records $records -Id $accepted.Id
    $again=Get-UiTlsLiveQualificationJob -Records $records -Id $accepted.Id
    Add-CheckResult 'Repeated GET reads one terminal observation and creates no SQL work' ($poll.Status -ceq 'COMPLETE' -and $again.Result.QualifiedAtUtc -ceq $poll.Result.QualifiedAtUtc -and $jobs.Count -eq 1)
    $fullRecords=@{};1..64|ForEach-Object{$fullRecords[[string]$_]=$records[$accepted.Id]}
    $fullJobs=@{};1..256|ForEach-Object{$fullJobs[[string]$_]=$jobs[$accepted.Id]}
    $otherJobs=@{};1..255|ForEach-Object{$otherJobs[[string]$_]=[pscustomobject]@{Id=$_}}
    foreach($limit in @(@{Records=$fullRecords;Jobs=$jobs;Other=@{}},@{Records=$records;Jobs=$fullJobs;Other=@{}},@{Records=$records;Jobs=$jobs;Other=$otherJobs})){
        $before=Get-Job|Measure-Object;$rejected=$false
        try{Start-UiTlsLiveQualificationJob -Records $limit.Records -Jobs $limit.Jobs -PersistentJobs $limit.Other -ModulePath $modulePath -Body $body|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'TLS_LIVE_UI_CAPACITY'}
        $after=Get-Job|Measure-Object
        Add-CheckResult '64 TLS or256 combined thread/persistent entries reject before job creation' ($rejected -and $before.Count -eq $after.Count)
    }
    function Test-UiTlsLiveQualificationAvailable {return $false}
    $rejected=$false
    try{Start-UiTlsLiveQualificationJob -Records $records -Jobs $jobs -ModulePath $modulePath -Body $body|Out-Null}catch{$rejected=$_.Exception.Message -ceq 'TLS_LIVE_UI_UNAVAILABLE'}
    Add-CheckResult 'Unsupported host leaves general UI baseline unchanged and creates no job' ($rejected -and $jobs.Count -eq 1)
}finally{
    foreach($record in $jobs.Values){if($record.Job.State -notin @('Completed','Failed','Stopped')){Stop-Job $record.Job};Remove-Job $record.Job -Force}
    if($module){Remove-Module $module -Force}
    $env:SQL_SERVER_LAB_STATE=$stateBefore
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($temp)) -cne $tempBase.TrimEnd([IO.Path]::DirectorySeparatorChar)){throw 'SYNTHETIC_CLEANUP_BOUNDARY_CHANGED'}
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL"
if($failures.Count){exit 1}
