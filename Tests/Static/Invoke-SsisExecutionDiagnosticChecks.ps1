#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Private/SsisExecutionDiagnostic.ps1')
. (Join-Path $repoRoot 'Providers/HyperV/HyperVSsisExecutionDiagnostic.ps1')
. (Join-Path $repoRoot 'Public/Get-SqlServerLabSsisExecutionDiagnostic.ps1')
$cases=0
function Check([bool]$Value,[string]$Name){if(-not $Value){throw ('SSIS_EXECUTION_DIAGNOSTIC_CHECK_'+$Name)};$script:cases++}
$run=[guid]'11111111-1111-1111-1111-111111111111';$database=[guid]'33333333-3333-3333-3333-333333333333'
$execution=9007199254740993L;$version=9007199254740995L
$directory=Join-Path $repoRoot ('.artifacts/test-runs/ssis-execution-static-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $directory)
$tracker=[pscustomobject]@{Context=0;Calls=0;Secrets=0;Bound=$false;NoRetry=$false;Args=@()}
function New-SyntheticObservation {
    $files=@(foreach($role in @('EXECUTOR','CORE','CONNECTIONS','PIPELINE','LOGGING','EXECUTE_PACKAGE')){[pscustomobject]@{Role=$role;Status='OBSERVED';FileMajor=17;FileVersion='17.0.1000.7';Sha256=('A'*64);Machine='AMD64';PrivatePath='RAW_PRIVATE'}})
    $registration=@(foreach($view in @('X64','X86')){[pscustomobject]@{View=$view;Status='OBSERVED';Edition='ENTERPRISE_DEVELOPER';EditionType='ENTERPRISE_DEVELOPER';Account='RAW_PRIVATE'}})
    $com=@(foreach($view in @('X64','X86')){foreach($role in @('EXECUTE_PACKAGE','CONNECTIONS','PIPELINE')){[pscustomobject]@{View=$view;Role=$role;Status='REGISTERED';ServerLocation='EXPECTED_DTS_BINN';ServerFileMajor=17;Clsid='RAW_PRIVATE'}}})
    [pscustomobject]@{ContractVersion='SqlServerLab.SsisExecutionGuest/1.0';Status='OBSERVED';ReasonCode='NONE';Snapshot=[pscustomobject]@{ExecutionId=$execution.ToString();ProjectLsn=$version.ToString();CatalogDatabaseGuid=$database.ToString('D');ObservedExecutionStatus=4;Use32BitRuntime=$false;AuthScheme='NTLM';PrivateAccount='RAW_PRIVATE'};InstalledFiles=$files;Registration=$registration;ComRegistration=$com;Worker=[pscustomobject]@{Status='NOT_RUNNING';ProcessId=$null;StartTimeUtc=$null;Files=@();PSComputerName='RAW_PRIVATE'};ErrorCodes=@(-1073659899);ErrorCodesTruncated=$false;PSComputerName='RAW_PRIVATE';RunspaceId='RAW_PRIVATE'}
}
function Test-LabSsisWindowsHost {$mode -cne 'non-windows'}
function Get-LabSsisPrerequisiteContext {
    $tracker.Context++
    [pscustomobject]@{Directory=$directory;ExpectedMajor=$(if($mode -ceq 'old-version'){16}else{17});ExpectedInstance='MSSQLSERVER';Run=@{scopeId='synthetic'};Instance=@{vmName='SyntheticGuest';vmId='22222222-2222-2222-2222-222222222222';port=1433};Fingerprint=$(if(($mode -ceq 'pre-drift' -and $tracker.Context -gt 1) -or ($mode -ceq 'post-drift' -and $tracker.Context -gt 2)){'changed'}else{'stable'})}
}
function Get-LabSecret {$tracker.Secrets++;if($mode -ceq 'credential'){return $null};$value=[securestring]::new();$value.AppendChar('x');$value}
function Invoke-HyperVPowerShellDirect {
    param($VMName,$ExpectedRunId,$ExpectedScopeId,$ExpectedVmId,$Credential,$ScriptBlock,$ArgumentList,$TimeoutSeconds,[switch]$NoRetry)
    $tracker.Calls++;$tracker.Args=$ArgumentList;$tracker.NoRetry=[bool]$NoRetry;$tracker.Bound=$ExpectedRunId -ceq $run.ToString() -and $ExpectedScopeId -ceq 'synthetic' -and $ExpectedVmId -eq '22222222-2222-2222-2222-222222222222'
    if($mode -ceq 'transport'){throw 'RAW_PRIVATE'}
    $value=New-SyntheticObservation
    switch -CaseSensitive($mode){
        'extra'{return @($value,$value)}
        'bad-id'{$value.Snapshot.ExecutionId='1'}
        'bad-version'{$value.Snapshot.ProjectLsn='1'}
        'bad-guid'{$value.Snapshot.CatalogDatabaseGuid='44444444-4444-4444-4444-444444444444'}
        'bad-sha'{$value.InstalledFiles[0].Sha256='RAW_PRIVATE'}
        'bad-file-major'{$value.InstalledFiles[0].FileMajor=18}
        'year-file-major'{$value.InstalledFiles[0].FileMajor=2025;$value.InstalledFiles[0].FileVersion='2025.170.1000.7';$value.ComRegistration[0].ServerFileMajor=2025}
        'duplicate-role'{$value.InstalledFiles[1].Role='EXECUTOR'}
        'duplicate-registration'{$value.Registration[1].View='X64'}
        'duplicate-com'{$value.ComRegistration[1].Role='EXECUTE_PACKAGE'}
        'bad-worker'{$value.Worker.Status='RUNNING_CANDIDATE'}
        'worker-running'{$value.Snapshot.ObservedExecutionStatus=2;$value.Worker.Status='RUNNING_CANDIDATE';$value.Worker.ProcessId=123;$value.Worker.StartTimeUtc=([datetimeoffset]::Parse('2026-01-01T00:00:00Z')).ToString('o');$value.Worker.Files=@($value.InstalledFiles[0])}
        'bad-worker-terminal'{$value.Worker.Status='RUNNING_CANDIDATE';$value.Worker.ProcessId=123;$value.Worker.StartTimeUtc=([datetimeoffset]::Parse('2026-01-01T00:00:00Z')).ToString('o');$value.Worker.Files=@($value.InstalledFiles[0])}
        'bad-worker-enum'{$value.Worker.Status='RAW_PRIVATE';$value.Worker.ProcessId=123}
        'bad-com-enum'{$value.ComRegistration[0].View='RAW_PRIVATE'}
        'bad-observed-reason'{$value.ReasonCode='CAPTURE_FAILED'}
        'false-success'{$value.Snapshot=$null}
        'padded-status'{$value.Status='OBSERVED '}
        'truncated'{$value.ErrorCodesTruncated=$true}
        'codes-overflow'{$value.ErrorCodes=@(1..65)}
    }
    $value
}
try {
    $invokeArguments=@{RunId=$run;StateRoot=$directory;ExecutionId=$execution;ExpectedProjectLsn=$version;ExpectedCatalogDatabaseGuid=$database}
    foreach($mode in @('ok','worker-running','year-file-major','credential','pre-drift','post-drift','old-version','transport','extra','bad-id','bad-version','bad-guid','bad-sha','bad-file-major','duplicate-role','duplicate-registration','duplicate-com','bad-worker','bad-worker-terminal','bad-worker-enum','bad-com-enum','bad-observed-reason','false-success','padded-status','truncated','codes-overflow')) {
        $tracker.Context=0;$tracker.Calls=0;$tracker.Secrets=0
        $result=Get-SqlServerLabSsisExecutionDiagnostic @invokeArguments
        if($mode -cin @('ok','worker-running','year-file-major')){
            Check ($result.Status -ceq 'OBSERVED' -and $result.ReadOnly -and $result.ExecutionStatus -ceq 'NOT_STARTED_BY_DIAGNOSTIC') 'OBSERVED_CONTRACT'
            Check ($result.Observation.Snapshot.ExecutionId -ceq $execution.ToString() -and $result.Observation.Snapshot.ProjectLsn -ceq $version.ToString()) 'BIGINT_EXACT'
            Check ($tracker.Calls -eq 1 -and $tracker.Bound -and $tracker.NoRetry -and $tracker.Args[2] -eq $execution -and $tracker.Args[3] -eq $version -and $tracker.Args[4] -eq $database) 'ONE_BOUND_DISPATCH'
            Check (($result|ConvertTo-Json -Depth 10) -notmatch 'RAW_PRIVATE|PSComputerName|RunspaceId|PrivatePath|Account|Clsid') 'CLOSED_NESTED_DTO'
        }else{
            Check ($result.Status -ceq 'INCONCLUSIVE' -and $null -eq $result.Observation) ('FAIL_CLOSED_'+$mode)
            Check (($result|ConvertTo-Json -Depth 10) -notmatch 'RAW_PRIVATE') ('NO_PRIVATE_FAILURE_'+$mode)
            if($mode -cin @('credential','pre-drift','old-version')){Check ($tracker.Calls -eq 0) ('NO_DISPATCH_'+$mode)}
        }
    }
    $mode='non-windows';$blocked=$false;try{Get-SqlServerLabSsisExecutionDiagnostic @invokeArguments|Out-Null}catch{$blocked=$_.Exception.Message -ceq 'SSIS_EXECUTION_DIAGNOSTIC_WINDOWS_HOST_REQUIRED'};Check $blocked 'WINDOWS_HOST_BOUNDARY'
    $mode='ok';$invalid=$invokeArguments.Clone();$invalid.ExecutionId=0L;$blocked=$false;try{Get-SqlServerLabSsisExecutionDiagnostic @invalid|Out-Null}catch{$blocked=$true};Check $blocked 'POSITIVE_EXECUTION_ID'
    $invalid=$invokeArguments.Clone();$invalid.ExpectedCatalogDatabaseGuid=[guid]::Empty;$blocked=$false;try{Get-SqlServerLabSsisExecutionDiagnostic @invalid|Out-Null}catch{$blocked=$_.Exception.Message -ceq 'SSIS_EXECUTION_DIAGNOSTIC_INPUT_INVALID'};Check $blocked 'NONEMPTY_DATABASE_ID'
    # Produktionsgastkörper: ausschließlich SQL-, Registry- und Dateiwurzelgrenze ersetzen.
    function New-SyntheticConnection {
        $connection=[pscustomobject]@{}
        $connection|Add-Member ScriptMethod Open {}
        $connection|Add-Member ScriptMethod Dispose {}
        $connection|Add-Member ScriptMethod CreateCommand {
            $parameterSource=[Data.SqlClient.SqlCommand]::new()
            $command=[pscustomobject]@{CommandText='';CommandTimeout=0;Parameters=$parameterSource.Parameters;ParameterSource=$parameterSource}
            $command|Add-Member ScriptMethod Dispose {$this.ParameterSource.Dispose()}
            $command|Add-Member ScriptMethod ExecuteReader {
                $table=[Data.DataTable]::new()
                if($this.CommandText -match 'FROM SSISDB.catalog.executions'){
                    $script:snapshotReads++
                    foreach($name in @('Major','Instance','Auth','Admin','DatabaseGuid','Execution','Version','Status','Use32Bit','Pid','Created','Ended')){[void]$table.Columns.Add($name,[object])}
                    $id=if($script:guestMode -ceq 'wrong-guid' -or ($script:guestMode -ceq 'worker-binding-drift' -and $script:snapshotReads -eq 2)){[guid]'44444444-4444-4444-4444-444444444444'}else{$database}
                    $instance=if($script:guestMode -ceq 'wrong-instance'){'OTHER'}else{'MSSQLSERVER'}
                    $active=$script:guestMode -cin @('worker-ok','worker-binding-drift');$status=if($active){2}else{4};$processId=if($active){123}else{[DBNull]::Value}
                    [void]$table.Rows.Add(@(17,$instance,'NTLM',1,$id,$execution,$version,$status,$false,$processId,[datetimeoffset]::Parse('2026-01-01T00:00:00Z'),[datetimeoffset]::Parse('2026-01-01T00:00:01Z')))
                }else{[void]$table.Columns.Add('Code',[int]);[void]$table.Rows.Add(@(-1073659899))}
                return ,$table.CreateDataReader()
            }
            $command
        }
        $connection
    }
    $source=(Get-LabSsisExecutionDiagnosticGuest).ToString()
    Check ($source.Contains("SELECT service_broker_guid FROM sys.databases WHERE name=N'SSISDB'") -and -not $source.Contains('database_recovery_status')) 'CONSUMER_CATALOG_IDENTITY'
    function New-SyntheticProcess {
        $path=Join-Path $directory 'Microsoft SQL Server/170/DTS/Binn/ISServerExec.exe'
        $process=[pscustomobject]@{Handle=1;StartTime=[datetime]::Parse('2026-01-01T00:00:01Z');MainModule=[pscustomobject]@{FileName=$path};Modules=@([pscustomobject]@{ModuleName='ISServerExec.exe';FileName=$path});HasExited=$false}
        $process|Add-Member ScriptMethod Dispose {};return $process
    }
    $factory='$connection=[Data.SqlClient.SqlConnection]::new($settings.ConnectionString)';$registry='$base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)'
    Check ([regex]::Matches($source,[regex]::Escape($factory)).Count -eq 1 -and [regex]::Matches($source,[regex]::Escape($registry)).Count -eq 2) 'TEST_BOUNDARIES_EXACT'
    $source=$source.Replace($factory,'$connection=New-SyntheticConnection').Replace($registry,"throw 'SYNTHETIC_REGISTRY_UNAVAILABLE'").Replace("([Environment]::GetFolderPath('ProgramFiles'))",("'"+$directory.Replace("'","''")+"'"))
    $processFactory='[Diagnostics.Process]::GetProcessById($snapshot.ProcessId)'
    Check ([regex]::Matches($source,[regex]::Escape($processFactory)).Count -eq 1) 'PROCESS_TEST_BOUNDARY_EXACT'
    $source=$source.Replace($processFactory,'(New-SyntheticProcess)')
    $guest=[scriptblock]::Create($source)
    foreach($script:guestMode in @('ok','worker-ok','wrong-guid','wrong-instance','worker-binding-drift')) {
        $script:snapshotReads=0
        $result=& $guest 1433 MSSQLSERVER $execution $version $database 30
        if($script:guestMode -cin @('ok','worker-ok')){
            Check ($result.Status -ceq 'OBSERVED' -and $result.Snapshot.ExecutionId -ceq $execution.ToString() -and $result.ErrorCodes[0] -eq -1073659899) 'GUEST_METADATA_OBSERVED'
            $expectedWorker=if($script:guestMode -ceq 'worker-ok'){'RUNNING_CANDIDATE'}else{'NOT_REPORTED'}
            Check (@($result.InstalledFiles).Count -eq 6 -and @($result.Registration).Count -eq 2 -and @($result.ComRegistration).Count -eq 6 -and $result.Worker.Status -ceq $expectedWorker) 'GUEST_BOUNDED_FOOTPRINT'
            $normalized=ConvertTo-LabSsisExecutionDiagnosticObservation $result $execution $version $database
            Check ($normalized.Status -ceq 'OBSERVED') 'GUEST_HOST_PROJECTION'
        }else{Check ($result.Status -ceq 'INCONCLUSIVE' -and $result.ReasonCode -ceq 'SQL_BINDING_MISMATCH' -and $null -eq $result.Snapshot) ('GUEST_BINDING_'+$script:guestMode)}
    }
    Write-Host "SSIS_EXECUTION_DIAGNOSTIC_STATIC_PASS cases=$cases; synthetic metadata and transport; no SQL or VM execution"
}finally{
    $full=[IO.Path]::GetFullPath($directory);$allowed=[IO.Path]::GetFullPath((Join-Path $repoRoot '.artifacts/test-runs')).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'STATIC_CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
