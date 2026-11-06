#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9A-Fa-f]{64}\z')][string]$ExpectedConfigurationSha256,
    [ValidateSet('Preflight','Supervisor','Worker')][string]$Mode='Preflight',
    [datetimeoffset]$DeadlineUtc=[datetimeoffset]::UtcNow.AddMinutes(120)
)
$ErrorActionPreference='Stop'
$pins=[Collections.Generic.List[IDisposable]]::new();$module=$null;$mutex=$null;$held=$false
$bound=$false;$lab=$null;$owned=$false;$ended=$true;$reserved=$false;$removed=$false;$child=$null;$exportIntended=$false
$result=[ordered]@{ContractVersion='SqlServerLab.PublicWindowsTlsAcceptance/0.1';Status='FAIL_PRE_EFFECT';Mode=$Mode;Pid=$PID;Phase='PREFLIGHT';Cleanup='NO_NATIVE_EFFECT';NativeEndKnown=$true;Cases=@();ErrorCode=$null}
try {
    $configPin=[IO.File]::Open($ConfigurationPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$pins.Add($configPin)
    if($configPin.Length -gt 4194304 -or (Get-FileHash -LiteralPath $ConfigurationPath).Hash -cne $ExpectedConfigurationSha256){throw 'TLS_PUBLIC_CONFIG_CHANGED'}
    $config=Get-Content -LiteralPath $ConfigurationPath -Raw|ConvertFrom-Json -Depth 20 -DateKind String
    if(-not $IsWindows -or $config.Scope -cne 'PUBLIC_WINDOWS_TLS_NEW_UNINTERRUPTED' -or $config.MaximumCreates -ne 1 -or $config.MaximumMinutes -ne 120 -or
        $config.ExpectedBuild -cne '17.0.1000.7' -or [datetimeoffset]::Parse($config.ExpiresUtc) -le [datetimeoffset]::UtcNow -or
        $DeadlineUtc -le [datetimeoffset]::UtcNow -or $DeadlineUtc -gt [datetimeoffset]::UtcNow.AddMinutes(121)){throw 'TLS_PUBLIC_CONFIG_INVALID'}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if($identity.User.Value -cne $config.ActorSid){throw 'TLS_PUBLIC_ACTOR_CHANGED'}
    $repo=[IO.Path]::GetFullPath($config.RepositoryRoot)
    foreach($row in $config.Sources){
        $path=[IO.Path]::GetFullPath((Join-Path $repo $row.RelativePath))
        if(-not $path.StartsWith($repo+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $row.RelativePath -match '\.\.'){throw 'TLS_PUBLIC_SOURCE_PATH_INVALID'}
        $pin=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$pins.Add($pin)
        if((Get-FileHash -LiteralPath $path).Hash -cne $row.Sha256){throw 'TLS_PUBLIC_SOURCE_CHANGED'}
    }
    $selfPin=[IO.File]::Open($PSCommandPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$pins.Add($selfPin)
    if((Get-FileHash -LiteralPath $PSCommandPath).Hash -cne $config.RunnerSha256){throw 'TLS_PUBLIC_RUNNER_CHANGED'}
    . (Join-Path $repo 'Tests/Common/AuthenticatedTlsHyperVAcceptance.ps1')
    if((@(Get-TlsHyperVSourceInventory $repo) -join "`n") -cne (@($config.Sources.RelativePath) -join "`n")){throw 'TLS_PUBLIC_SOURCE_INVENTORY_CHANGED'}
    $module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
    & $module {param($p,$sid)Assert-LabTlsCaPrivateAcl $p $sid;Assert-LabTlsCaPrivateAcl (Split-Path $p -Parent) $sid -Directory} $ConfigurationPath $config.ActorSid
    if([IO.Path]::GetFullPath((Split-Path $ConfigurationPath -Parent)) -cne $config.EvidenceRoot -or
        [IO.Path]::GetFullPath((Join-Path $config.DataRoot 'State')) -cne $config.StateRoot){throw 'TLS_PUBLIC_ROOT_CHANGED'}
    $bound=$true;$result.OperationId=$config.OperationId;$result.SourceDigest=$config.SourceDigest
    function Write-Evidence([string]$Name,$Value){
        if($Name -cnotmatch '\A[a-z-]+\.private\.json\z'){throw 'TLS_PUBLIC_EVIDENCE_NAME_INVALID'}
        & $module {param($p,$sid,$v)Write-LabTlsCaPrivateFile $p $sid (ConvertTo-LabTlsRegistryWriterBytes $v)} (Join-Path $config.EvidenceRoot $Name) $config.ActorSid $Value
    }
    function Read-Evidence([string]$Name){
        & $module {param($p,$sid)$b=Read-LabTlsCaPrivateFile $p $sid 4194304;[Text.Encoding]::UTF8.GetString($b)|ConvertFrom-Json -Depth 20 -DateKind String} (Join-Path $config.EvidenceRoot $Name) $config.ActorSid
    }
    function Assert-Budget {
        if([datetimeoffset]::UtcNow -ge $DeadlineUtc -or (Test-Path -LiteralPath (Join-Path $config.EvidenceRoot 'cancel.private.json'))){throw 'TLS_PUBLIC_BUDGET_ENDED'}
    }
    function Get-Baseline {
        $files=@(foreach($f in @(Get-ChildItem -LiteralPath (Join-Path $config.StateRoot 'runs') -Filter connection-info.json -Recurse -File)){
            [ordered]@{Path=$f.FullName;Sha256=(Get-FileHash -LiteralPath $f.FullName).Hash}
        })
        foreach($relative in @('.sql-server-lab-root.json','Catalog/storage-locations.json')){
            $p=Join-Path $config.DataRoot $relative;$files+=@{Path=$p;Sha256=(Get-FileHash -LiteralPath $p).Hash}
        }
        [ordered]@{
            VmIds=@(Get-VM|ForEach-Object {$_.Id.ToString('D')}|Sort-Object)
            Vms=@(Get-VM|Sort-Object Id|Select-Object @{n='Id';e={$_.Id.ToString('D')}},State,Notes)
            Switches=@(Get-VMSwitch|Sort-Object Id|Select-Object @{n='Id';e={$_.Id.ToString('D')}},SwitchType)
            Trust=@(Get-ChildItem Cert:/CurrentUser/Root|ForEach-Object {[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($_.RawData))}|Sort-Object)
            RunIds=@(Get-ChildItem -LiteralPath (Join-Path $config.StateRoot 'runs') -Directory|Select-Object -ExpandProperty Name|Sort-Object)
            Files=$files
        }
    }
    if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'TLS_PUBLIC_ELEVATED_RUNNER_REQUIRED'}
    $null=& $module {param($c)Get-LabTlsOperationalAuthority $c.DataRoot $c.ControllerId $c.LocationId $c.AuthorityRef $c.ClientRef} $config
    $selected=& $module {param($s)Get-HyperVManifestFallbackArtifactSelection -SqlVersion 2025 -InstallationType desktop-experience -MinimumEvaluationDaysRemaining 30 -StateRoot $s} $config.StateRoot
    if(-not $selected.Selected -or [string]$selected.Selected.sql.build -cnotmatch '\A2025\.0170\.1000\.0?7(?:\s|$)'){throw 'TLS_PUBLIC_PREPARED_IMAGE_REQUIRED'}
    if($Mode -ceq 'Preflight'){Write-Output 'TLS_PUBLIC_PREFLIGHT_PASS';return}
    Assert-Budget
    if($Mode -ceq 'Supervisor'){
        Write-Evidence 'supervisor-intent.private.json' @{OperationId=$config.OperationId;Pid=$PID;DeadlineUtc=$DeadlineUtc.ToString('o')}
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'));$start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($arg in @('-NoLogo','-NoProfile','-File',$PSCommandPath,'-ConfigurationPath',$ConfigurationPath,'-ExpectedConfigurationSha256',$ExpectedConfigurationSha256,'-Mode','Worker','-DeadlineUtc',$DeadlineUtc.ToString('o'))){$start.ArgumentList.Add($arg)}
        $child=[Diagnostics.Process]::new();$child.StartInfo=$start
        if(-not $child.Start()){throw 'TLS_PUBLIC_WORKER_START_FAILED'}
        $ended=$false;$out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
        Write-Evidence 'worker-launch.private.json' @{Pid=$child.Id;StartTicks=$child.StartTime.ToUniversalTime().Ticks;DeadlineUtc=$DeadlineUtc.ToString('o')}
        while(-not $child.WaitForExit(1000)){Assert-Budget}
        $outputText=$out.GetAwaiter().GetResult();$errorText=$err.GetAwaiter().GetResult()
        Write-Evidence 'worker-output.private.json' @{Output=$outputText.Substring(0,[Math]::Min($outputText.Length,131072));Error=$errorText.Substring(0,[Math]::Min($errorText.Length,131072))}
        Assert-Budget
        $worker=Read-Evidence 'worker-result.private.json'
        if($child.ExitCode -ne 0 -or $worker.ContractVersion -cne $result.ContractVersion -or $worker.OperationId -cne $config.OperationId -or
            $worker.Pid -ne $child.Id -or $worker.SourceDigest -cne $config.SourceDigest -or $worker.Status -cne 'PASS_PENDING_AUDIT' -or
            $worker.Cleanup -cne 'REMOVED' -or $worker.NativeEndKnown -ne $true -or @($worker.Cases).Count -ne 5){throw 'TLS_PUBLIC_WORKER_NOT_QUALIFIED'}
        $ended=$true;$result.Phase='INDEPENDENT_AUDIT';$before=Read-Evidence 'baseline.private.json'
        if(@(Get-VM|Where-Object {$_.Id.ToString('D') -ceq $worker.VmId}).Count){throw 'TLS_PUBLIC_OWN_VM_STILL_PRESENT'}
        $state=& $module {param($r,$s)Get-LabRunState -RunId $r -StateRoot $s} $worker.RunId $config.StateRoot
        if($state.state -cne 'REMOVED' -or $state.scopeId -cne $worker.ScopeId){throw 'TLS_PUBLIC_FRESH_REMOVAL_NOT_PROVEN'}
        $after=Get-Baseline
        foreach($field in @('VmIds','Vms','Switches','Trust')){
            if((ConvertTo-Json -InputObject @($before.$field) -Depth 8 -Compress) -cne (ConvertTo-Json -InputObject @($after.$field) -Depth 8 -Compress)){throw 'TLS_PUBLIC_FOREIGN_BASELINE_CHANGED'}
        }
        foreach($f in $before.Files){if(-not (Test-Path -LiteralPath $f.Path) -or (Get-FileHash -LiteralPath $f.Path).Hash -cne $f.Sha256){throw 'TLS_PUBLIC_FOREIGN_FILE_CHANGED'}}
        if(Test-Path -LiteralPath (Join-Path $config.EvidenceRoot 'export')){throw 'TLS_PUBLIC_EXPORT_NOT_REMOVED'}
        Assert-Budget
        $result.Cases=@($worker.Cases)+@('INDEPENDENT_FRESH_VM_ABSENCE','FOREIGN_BASELINE_UNCHANGED');$result.RunId=$worker.RunId;$result.VmId=$worker.VmId
        $result.Status='PASS';$result.Phase='COMPLETED';$result.Cleanup='REMOVED_AND_INDEPENDENTLY_AUDITED';return
    }
    $mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke')
    try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true;throw 'TLS_PUBLIC_RUNTIME_MUTEX_ABANDONED'}
    if(-not $held){throw 'TLS_PUBLIC_RUNTIME_BUSY'}
    Write-Evidence 'worker-intent.private.json' @{OperationId=$config.OperationId;Pid=$PID;DeadlineUtc=$DeadlineUtc.ToString('o')}
    $before=Get-Baseline;Write-Evidence 'baseline.private.json' $before
    Assert-Budget
    Write-Evidence 'create-reserved.private.json' @{MaximumCreates=1;OperationId=$config.OperationId;StartedAt=[datetimeoffset]::UtcNow.ToString('o')}
    $reserved=$true;$ended=$false;$result.Phase='PUBLIC_NEW'
    $lab=New-SqlServerLab -Provider hyperv -Version 2025 -DataRoot $config.DataRoot -StateRoot $config.StateRoot -TlsControllerId $config.ControllerId `
        -TlsLocationId $config.LocationId -TlsCandidateId $config.CandidateId -TlsClientPlatform Windows -TrustServerCertificate:$false -AutoStart off -NonInteractive
    $ended=$true
    if(@($lab.Instances).Count -ne 1 -or $lab.RunId -cin $before.RunIds -or [string]$lab.Instances[0].vmId -cin $before.VmIds){throw 'TLS_PUBLIC_FRESH_OWNERSHIP_INVALID'}
    $context=& $module {param($r,$s)Get-LabSsisPrerequisiteContext -RunId $r -InstanceId primary -StateRoot $s} $lab.RunId $config.StateRoot
    if($context.Run.scopeId -cne $lab.ScopeId -or [string]$context.Instance.vmId -cne [string]$lab.Instances[0].vmId){throw 'TLS_PUBLIC_OWNERSHIP_DRIFT'}
    $owned=$true;$result.RunId=$lab.RunId;$result.ScopeId=$lab.ScopeId;$result.VmId=[string]$context.Instance.vmId
    Write-Evidence 'returned-run.private.json' @{RunId=$result.RunId;ScopeId=$result.ScopeId;VmId=$result.VmId;Qualification=$lab.TlsQualification}
    $q=$lab.TlsQualification
    if($q.Status -cne 'QUALIFIED' -or $q.Provider -cne 'hyperv' -or $q.SqlBuild -cne $config.ExpectedBuild -or $q.Evidence -cne 'FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD' -or
        $q.TrustServerCertificate -ne $false -or $q.Encrypt -ne $true -or $q.WireCertificateFingerprint -cne 'NOT_OBSERVED'){throw 'TLS_PUBLIC_INITIAL_QUALIFICATION_INVALID'}
    $result.Cases+=@('PUBLIC_NEW_UNINTERRUPTED_TWO_STRICT_STACKS')
    Assert-Budget;$result.Phase='PUBLIC_EXPORT'
    $exportDirectory=[IO.Path]::GetFullPath((Join-Path $config.EvidenceRoot 'export'))
    if(Test-Path -LiteralPath $exportDirectory){throw 'TLS_PUBLIC_NEW_EXPORT_DIRECTORY_REQUIRED'}
    Write-Evidence 'export-intent.private.json' @{Path=$exportDirectory;RunId=$lab.RunId}
    $exportIntended=$true;$ended=$false
    $export=Export-SqlServerLabTestEnvironment -RunId $lab.RunId -InstanceId primary -StateRoot $config.StateRoot -TrustServerCertificate:$false -OutputDirectory $exportDirectory
    $ended=$true;$result.Cases+=@('PUBLIC_SIGNED_V2_EXPORT_TWO_STRICT_STACKS')
    Assert-Budget;$result.Phase='PUBLIC_READERS';$ended=$false
    $snapshot=Read-SqlServerLabQualifiedTestEnvironment -Path $export.JsonPath -RunId $lab.RunId -InstanceId primary -StateRoot $config.StateRoot
    $current=Read-SqlServerLabQualifiedTestEnvironment -ExportBytes $snapshot.ExportBytes -RunId $lab.RunId -InstanceId primary -StateRoot $config.StateRoot
    $ended=$true
    if($current.ExportSha256 -cne $snapshot.ExportSha256 -or @($current.Contract.environments).Count -ne 1){throw 'TLS_PUBLIC_SNAPSHOT_INVALID'}
    $result.Cases+=@('PUBLIC_READER_PATH_AND_SAME_BYTES')
    Assert-Budget;$result.Phase='SYNTHETIC_CONSUMER';$ended=$false
    $entry=$current.Contract.environments[0];$builder=[Data.SqlClient.SqlConnectionStringBuilder]::new($entry.connectionString)
    $connection=$null;$command=$null;$queryInvoked=$false;$queryReturned=$false
    try{
        if(-not $builder.Encrypt -or $builder.TrustServerCertificate -or $entry.runId -cne $lab.RunId){throw 'TLS_PUBLIC_CONSUMER_FLAGS_INVALID'}
        $builder['Pooling']=$false;$builder['Connect Timeout']=10;$builder['ConnectRetryCount']=0
        $connection=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString);$builder.Clear();$connection.Open()
        $command=$connection.CreateCommand();$command.CommandTimeout=10
        $command.CommandText="SELECT CONCAT(CONVERT(varchar(32),SERVERPROPERTY('ProductVersion')),'|',encrypt_option) FROM sys.dm_exec_connections WHERE session_id=@@SPID"
        $queryInvoked=$true;$value=$command.ExecuteScalar();$queryReturned=$true
        if($value -cne ($config.ExpectedBuild+'|TRUE')){throw 'TLS_PUBLIC_CONSUMER_ORACLE_FAILED'}
    }finally{
        if($command){$command.Dispose()};if($connection){$connection.Dispose()};$builder.Clear()
        # A returned query/oracle failure is ended after Dispose. A command
        # timeout still does not prove the server-side query ended.
        if(-not $queryInvoked -or $queryReturned){$ended=$true}
    }
    $result.Cases+=@('SYNTHETIC_READONLY_STRICT_CONSUMER')
    $result.Status='PASS_PENDING_AUDIT';$result.Phase='COMPLETED'
}catch{
    $result.Status='FAIL';$code=$_.Exception.Message
    $result.ErrorCode=if($code -cmatch '\A([A-Z][A-Z0-9_]+)(?::|\z)'){$Matches[1]}else{'UNCLASSIFIED'}
    $result.PrivateDiagnostic=$_.Exception.ToString();$result.PrivateStack=$_.ScriptStackTrace
}finally{
    if($Mode -ceq 'Worker' -and $owned -and $ended){
        try{
            $ended=$false
            $cleanup=Remove-SqlServerLab -RunId $lab.RunId -StateRoot $config.StateRoot -Force -Confirm:$false
            if($cleanup.Status -cne 'REMOVED'){throw 'TLS_PUBLIC_CLEANUP_NOT_REMOVED'}
            $ended=$true
            if($exportIntended -and (Test-Path -LiteralPath $exportDirectory)){
                $expected=[IO.Path]::GetFullPath((Join-Path $config.EvidenceRoot 'export'))
                if($exportDirectory -cne $expected -or -not $expected.StartsWith($config.EvidenceRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'TLS_PUBLIC_EXPORT_CLEANUP_PATH_INVALID'}
                $items=@(Get-Item -LiteralPath $exportDirectory -Force)+@(Get-ChildItem -LiteralPath $exportDirectory -Force -Recurse)
                if(@($items|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'TLS_PUBLIC_EXPORT_CLEANUP_REPARSE'}
                & $module {param($p,$sid)Assert-LabTlsCaPrivateAcl $p $sid -Directory} $exportDirectory $config.ActorSid
                Remove-Item -LiteralPath $expected -Recurse -Force
                if(Test-Path -LiteralPath $expected){throw 'TLS_PUBLIC_EXPORT_CLEANUP_FAILED'}
            }
            $removed=$true;$result.Cleanup='REMOVED';$result.Cases+=@('PUBLIC_REMOVE_OWN_RUN')
        }catch{$result.Cleanup='RECOVERY_REQUIRED';$result.CleanupError='TLS_PUBLIC_CLEANUP_FAILED';$result.Status='FAIL'}
    }elseif(-not $ended){$result.Cleanup='RECOVERY_RETAIN_OWN_RESOURCES'}
    $result.NativeEndKnown=$ended
    if($bound -and $Mode -cne 'Preflight'){
        if($Mode -ceq 'Supervisor' -and -not $ended){try{Write-Evidence 'cancel.private.json' @{Reason='SUPERVISOR_END_NOT_PROVEN';NoKillStopOrRemoval=$true}}catch{}}
        try{Write-Evidence ($Mode.ToLowerInvariant()+'-result.private.json') $result}catch{$result.Status='FAIL'}
    }
    if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()};if($child){$child.Dispose()}
    for($i=$pins.Count-1;$i -ge 0;$i--){$pins[$i].Dispose()}
}
if($result.Status -cnotin @('PASS','PASS_PENDING_AUDIT')){Write-Output $result.ErrorCode;exit 2}
