#Requires -Version 7.5
# No scheduler registration, elevation, SQL connection, provider or trust mutation.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repo 'Tools/BoundedTlsRunner/Common.ps1')
. (Join-Path $repo 'Tests/Common/CheckResult.ps1')
$passed=0;$failures=[Collections.Generic.List[string]]::new()
function Reject([scriptblock]$Action,[string]$Code){try{& $Action;return $false}catch{return $_.Exception.Message -ceq $Code}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ContosoBoundedTls-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temp
try{
    $now=[datetimeoffset]'2026-01-01T00:00:00Z'
    $plan=[pscustomobject]@{ExpiresUtc=$now.AddHours(2).ToString('o');MaximumAttempts=2}
    foreach($attempt in 0,1){
        $state=[pscustomobject]@{Status='READY';Attempts=$attempt}
        Add-CheckResult ('Remaining attempt '+$attempt+' admitted') ((Get-BoundedTlsDecision $plan $state Run $now) -ceq 'RUN')
    }
    $state=[pscustomobject]@{Status='READY';Attempts=2}
    Add-CheckResult 'Third attempt rejected' ((Get-BoundedTlsDecision $plan $state Run $now) -ceq 'EXHAUSTED')
    Add-CheckResult 'Close remains possible after budget' ((Get-BoundedTlsDecision $plan $state Close $now) -ceq 'CLOSE')
    Add-CheckResult 'Exact expiry admits no new run' ((Get-BoundedTlsDecision $plan $state Run $now.AddHours(2)) -ceq 'CLOSE')
    Add-CheckResult 'Post-expiry ready probe becomes close' ((Get-BoundedTlsDecision $plan $state Ready $now.AddHours(3)) -ceq 'CLOSE')
    foreach($terminal in @('PASS','CLOSED','RECOVERY_REQUIRED')){
        Add-CheckResult ('Terminal '+$terminal+' cannot restart') ((Get-BoundedTlsDecision $plan ([pscustomobject]@{Status=$terminal;Attempts=0}) Run $now) -ceq 'CLOSED')
    }
    foreach($operation in @('Ready','Run','Close')){
        Add-CheckResult ('Unknown running predecessor blocks '+$operation) ((Get-BoundedTlsDecision $plan ([pscustomobject]@{Status='RUNNING';Attempts=1}) $operation $now) -ceq 'RECOVERY')
    }
    Add-CheckResult 'Unknown protected state rejected' (Reject {Get-BoundedTlsDecision $plan ([pscustomobject]@{Status='UNRECOGNIZED';Attempts=0}) Ready $now} 'BOUNDED_TLS_STATE_INVALID')
    Add-CheckResult 'Negative protected counter rejected' (Reject {Get-BoundedTlsDecision $plan ([pscustomobject]@{Status='READY';Attempts=-1}) Ready $now} 'BOUNDED_TLS_STATE_INVALID')
    foreach($operation in @('RunScript','Install','RestartHost','run','Run -Command test','')){
        Add-CheckResult ('Unknown operation rejected: '+$operation) (Reject {Get-BoundedTlsDecision $plan $state $operation $now} 'BOUNDED_TLS_OPERATION_REJECTED')
    }
    Add-CheckResult 'Closed fields accept dictionaries' (-not (Reject {Assert-BoundedTlsFields @{A=1;B=2} @('A','B')} 'BOUNDED_TLS_FIELDS_INVALID'))
    Add-CheckResult 'Closed fields accept JSON objects' (-not (Reject {Assert-BoundedTlsFields ([pscustomobject]@{A=1;B=2}) @('A','B')} 'BOUNDED_TLS_FIELDS_INVALID'))
    Add-CheckResult 'Command property rejected' (Reject {Assert-BoundedTlsFields ([pscustomobject]@{A=1;Command='untrusted'}) @('A','B')} 'BOUNDED_TLS_FIELDS_INVALID')
    Add-CheckResult 'Differently cased field rejected' (Reject {Assert-BoundedTlsFields ([pscustomobject]@{a=1;B=2}) @('A','B')} 'BOUNDED_TLS_FIELDS_INVALID')
    $file=Join-Path $temp 'input.json'
    foreach($json in @('{"Operation":"Close","Operation":"Run"}','{"Operation":"Run","operation":"Close"}','{"nested":{"A":1,"A":2}}')){
        [IO.File]::WriteAllText($file,$json)
        Add-CheckResult 'Duplicate JSON keys rejected before dispatch' (Reject {Read-BoundedTlsJson $file} 'BOUNDED_TLS_DUPLICATE_JSON_FIELD')
    }
    [IO.File]::WriteAllText($file,'{"A":1,"B":[{"C":true}]}')
    $doc=Read-BoundedTlsJson $file
    Add-CheckResult 'Bounded structured JSON read' ($doc.A -eq 1 -and $doc.B[0].C -eq $true)
    Add-CheckResult 'Oversized JSON rejected' (Reject {Read-BoundedTlsJson $file 2} 'BOUNDED_TLS_FILE_SIZE_INVALID')
    $hash=Get-BoundedTlsHash $file
    $pinned=Read-BoundedTlsPinnedJson $file $hash
    Add-CheckResult 'Approved bytes are hashed and parsed together' ($pinned.A -eq 1)
    [IO.File]::AppendAllText($file,' ')
    Add-CheckResult 'Source byte drift changes hash' ($hash -cne (Get-BoundedTlsHash $file))
    Add-CheckResult 'Replaced manifest cannot retain old approval' (Reject {Read-BoundedTlsPinnedJson $file $hash} 'BOUNDED_TLS_APPROVED_BYTES_CHANGED')
    $runner=[guid]::NewGuid().ToString('D');$first=[guid]::NewGuid().ToString('D');$second=[guid]::NewGuid().ToString('D')
    $request=[pscustomobject]@{ContractVersion='SqlServerLab.BoundedTlsRequest/0.1';RunnerId=$runner;RequestId=$first;Operation='Run'}
    $ledger=[pscustomobject]@{ConsumedRequestIds=@($first,$second);LastRequestId=$second}
    Add-CheckResult 'Earlier request replay rejected after intervening request' (Reject {Assert-BoundedTlsRequest $request $runner $ledger} 'BOUNDED_TLS_REQUEST_REPLAY')
    $request.RequestId=[guid]::NewGuid().ToString('D')
    Add-CheckResult 'Fresh request remains admissible' (-not(Reject {Assert-BoundedTlsRequest $request $runner $ledger} 'BOUNDED_TLS_REQUEST_REPLAY'))
    $request.RequestId=[guid]::Empty.ToString('D')
    Add-CheckResult 'Empty request GUID rejected' (Reject {Assert-BoundedTlsRequest $request $runner $ledger} 'BOUNDED_TLS_REQUEST_INVALID')
    foreach($path in @('../foreign.ps1','a/../foreign.ps1','/outside.ps1','C:/outside.ps1','.git/config','a\outside.ps1')){
        Add-CheckResult ('Source escape rejected: '+$path) (Reject {Assert-BoundedTlsSourceRow ([pscustomobject]@{RelativePath=$path;Sha256=('A'*64)}) $temp} 'BOUNDED_TLS_SOURCE_ROW_INVALID')
    }
    Add-CheckResult 'Gitignore remains an ordinary source' ((Assert-BoundedTlsSourceRow ([pscustomobject]@{RelativePath='.gitignore';Sha256=('A'*64)}) $temp) -ceq (Join-Path $temp '.gitignore'))
    $sid='S-1-5-21-1-2-3-1001';$sddl=Get-BoundedTlsTaskSddl $sid
    Add-CheckResult 'Task user receives read/execute only' ($sddl.Contains('(A;;GRGX;;;'+$sid+')') -and -not $sddl.Contains('(A;;GA;;;'+$sid+')'))
    Add-CheckResult 'Task System/Admin rights retained' ($sddl.Contains('(A;;GA;;;SY)') -and $sddl.Contains('(A;;GA;;;BA)'))
    Add-CheckResult 'Task SDDL actor injection rejected' (Reject {Get-BoundedTlsTaskSddl 'SY)(A;;GA;;;WD'} 'BOUNDED_TLS_ACTOR_INVALID')
    $nativePath=Join-Path $repo 'Tests/Integration/Invoke-AuthenticatedTlsWindowsPublicAcceptance.ps1'
    $native=Get-Content -LiteralPath $nativePath -Raw
    $settings=@(Get-Content -LiteralPath $nativePath|Where-Object {$_.Contains('$builder[''Pooling'']') -and $_.Contains('Connect Timeout') -and $_.Contains('ConnectRetryCount')})
    Add-CheckResult 'One actual consumer settings block found' ($settings.Count -eq 1)
    if($IsWindows){
        $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new('Data Source=tcp:127.0.0.1,1433;Initial Catalog=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=False')
        . ([scriptblock]::Create($settings[0].Trim()))
        Add-CheckResult 'Actual adapter timeout keyword accepted' ($builder['Connect Timeout'] -eq 10)
        Add-CheckResult 'Actual adapter pooling/retry off' (-not $builder.Pooling -and $builder['ConnectRetryCount'] -eq 0)
        Add-CheckResult 'Actual adapter preserves strict TLS' ($builder.Encrypt -and -not $builder.TrustServerCertificate)
        Add-CheckResult 'Actual adapter preserves target and database' ($builder.DataSource -ceq 'tcp:127.0.0.1,1433' -and $builder.InitialCatalog -ceq 'master')
        Add-CheckResult 'Actual adapter preserves Windows identity selection' $builder.IntegratedSecurity
        $builder.Clear()
    }else{Write-Host 'Windows SqlClient metadata cases NOT EXECUTED on this platform; no SQL connection is opened.'}
    $installer=Get-Content (Join-Path $repo 'Tools/BoundedTlsRunner/Install.ps1') -Raw
    $invoke=Get-Content (Join-Path $repo 'Tools/BoundedTlsRunner/Invoke.ps1') -Raw
    Add-CheckResult 'Task permissions applied atomically at create' ($installer.Contains('RegisterTaskDefinition($plan.TaskName,$definition,18,') -and -not $installer.Contains('Register-ScheduledTask'))
    Add-CheckResult 'Interactive same-user principal, no stored password' ($installer.Contains('LogonType=3') -and $installer.Contains('$plan.ActorSid,$null,3,'))
    Add-CheckResult 'Task has no forced native kill timeout' ($installer.Contains("ExecutionTimeLimit='PT0S'"))
    Add-CheckResult 'Task explicitly disables hard termination' $installer.Contains('AllowHardTerminate=$false')
    Add-CheckResult 'Lease and scheduler share exact second precision' $installer.Contains('[datetimeoffset]::FromUnixTimeSeconds([datetimeoffset]::UtcNow.ToUnixTimeSeconds())')
    Add-CheckResult 'Expired/unknown state closes before parsing writable requests' ($invoke.IndexOf('$protectedDecision=') -lt $invoke.IndexOf('$request=if('))
    Add-CheckResult 'Ready/outcome bound to fresh dispatch and process' ($invoke.Contains("'ready-'+`$DispatchId+") -and $invoke.Contains('BOUNDED_TLS_WORKFLOW_RESULT_BINDING_INVALID'))
    Add-CheckResult 'Actual native global runtime mutex retained' $native.Contains('Global\SQL_Server_Lab_Runtime_Smoke')
    Add-CheckResult 'Unknown native end retains resources' ($native.Contains('RECOVERY_RETAIN_OWN_RESOURCES') -and -not $invoke.Contains('Stop-Process'))
    Add-CheckResult 'Frozen source verification precedes import' ($invoke.IndexOf('BOUNDED_TLS_FROZEN_SOURCE_CHANGED') -lt $invoke.IndexOf('$module=Import-Module'))
    foreach($script in @(Get-ChildItem (Join-Path $repo 'Tools/BoundedTlsRunner') -Filter '*.ps1')+@(Get-Item $nativePath)){
        $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tokens,[ref]$errors)
        Add-CheckResult ('Parser: '+$script.Name) ($errors.Count -eq 0)
    }
}finally{
    $full=[IO.Path]::GetFullPath($temp)
    if(-not $full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'ContosoBoundedTls-*'){throw 'BOUNDED_TLS_FIXTURE_CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
Write-Host "Bounded TLS runner: $passed PASS / $($failures.Count) FAIL"
if($failures.Count){exit 1}
