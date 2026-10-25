# Fester lesender Gastkörper. Er startet keine Ausführung und lädt kein Paket.
function Get-LabSsisExecutionDiagnosticGuest {
    [CmdletBinding()]param()
    return {
        param([int]$Port,[string]$ExpectedInstance,[long]$ExecutionId,[long]$ExpectedProjectLsn,[guid]$ExpectedCatalogDatabaseGuid,[int]$TimeoutSeconds)
        $ErrorActionPreference='Stop';$connection=$null;$snapshot=$null
        $files=@();$registration=@();$comRegistration=@();$codes=@();$truncated=$false
        $worker=[pscustomobject]@{Status='NOT_ATTEMPTED';ProcessId=$null;StartTimeUtc=$null;Files=@()}
        $status='INCONCLUSIVE';$reason='SQL_OBSERVATION_UNAVAILABLE';$deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds);$fileBudget=[pscustomobject]@{Bytes=0L}
        $roles=[ordered]@{EXECUTOR='ISServerExec.exe';CORE='DTS.dll';CONNECTIONS='DtsConn.dll';PIPELINE='DtsPipeline.dll';LOGGING='DTSLog.dll';EXECUTE_PACKAGE='ExecPackageTask.dll'}
        function Read-SsisKnownFile([string]$Path,[string]$Role,[string]$AllowedDirectory) {
            $record=[ordered]@{Role=$Role;Status='UNAVAILABLE';FileMajor=$null;FileVersion=$null;Sha256=$null;Machine=$null}
            $stream=$null;$reader=$null;$sha=$null
            try {
                if([datetime]::UtcNow -ge $deadline){throw 'DEADLINE'}
                $full=[IO.Path]::GetFullPath($Path)
                if(-not [string]::Equals([IO.Path]::GetDirectoryName($full),[IO.Path]::GetFullPath($AllowedDirectory).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){throw 'LOCATION'}
                if(-not [IO.File]::Exists($full)){$record.Status='MISSING';return [pscustomobject]$record}
                $parent=$full
                while($parent){if(([IO.File]::GetAttributes($parent) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'REPARSE'};$parent=[IO.Path]::GetDirectoryName($parent)}
                $stream=[IO.FileStream]::new($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                if($stream.Length -lt 64 -or $stream.Length -gt 64MB -or $fileBudget.Bytes+$stream.Length -gt 256MB){throw 'FILE_LIMIT'}
                $fileBudget.Bytes+=$stream.Length
                $reader=[IO.BinaryReader]::new($stream,[Text.Encoding]::UTF8,$true)
                if($reader.ReadUInt16() -ne 0x5A4D){throw 'IMAGE'}
                $stream.Position=0x3C;$offset=$reader.ReadInt32()
                if($offset -lt 64 -or $offset -gt 1MB -or $offset+6 -gt $stream.Length){throw 'IMAGE'}
                $stream.Position=$offset;if($reader.ReadUInt32() -ne 0x4550){throw 'IMAGE'}
                $machine=switch($reader.ReadUInt16()){0x8664{'AMD64'};0x14C{'I386'};default{'OTHER'}}
                $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($full)
                $numericVersion='{0}.{1}.{2}.{3}' -f $version.FileMajorPart,$version.FileMinorPart,$version.FileBuildPart,$version.FilePrivatePart
                if($numericVersion -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'){throw 'VERSION'}
                $stream.Position=0;$sha=[Security.Cryptography.SHA256]::Create()
                $digest=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')
                $record.Status='OBSERVED';$record.FileMajor=[int]$version.FileMajorPart;$record.FileVersion=$numericVersion;$record.Sha256=$digest;$record.Machine=$machine
            } catch {} finally {if($sha){$sha.Dispose()};if($reader){$reader.Dispose()};if($stream){$stream.Dispose()}}
            [pscustomobject]$record
        }
        function ConvertTo-SsisEditionCode([object]$Value) {
            switch -CaseSensitive ([string]$Value) {
                'Enterprise Developer Edition'{'ENTERPRISE_DEVELOPER'};'Standard Developer Edition'{'STANDARD_DEVELOPER'};'Developer Edition'{'DEVELOPER'}
                'Enterprise Edition'{'ENTERPRISE'};'Standard Edition'{'STANDARD'};'Enterprise Evaluation Edition'{'EVALUATION'};'Evaluation Edition'{'EVALUATION'};default{'UNKNOWN'}
            }
        }
        function Read-SsisSnapshot {
            $command=$connection.CreateCommand();$command.CommandTimeout=[math]::Min(15,[math]::Max(1,[int]($deadline-[datetime]::UtcNow).TotalSeconds))
            try {
                $command.CommandText=@"
SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion')),COALESCE(CONVERT(nvarchar(128),SERVERPROPERTY('InstanceName')),N'MSSQLSERVER'),CONVERT(nvarchar(40),CONNECTIONPROPERTY('auth_scheme')),IS_SRVROLEMEMBER(N'sysadmin'),
 (SELECT service_broker_guid FROM sys.databases WHERE name=N'SSISDB'),
 e.execution_id,e.project_lsn,e.status,e.use32bitruntime,e.process_id,e.created_time,e.end_time
FROM SSISDB.catalog.executions e WHERE e.execution_id=@execution;
"@
                [void]$command.Parameters.Add('@execution',[Data.SqlDbType]::BigInt);$command.Parameters['@execution'].Value=$ExecutionId
                $reader=$command.ExecuteReader()
                try {
                    if(-not $reader.Read() -or [int]$reader.GetValue(0) -ne 17 -or -not [string]::Equals([string]$reader.GetValue(1),$ExpectedInstance,[StringComparison]::OrdinalIgnoreCase) -or [string]$reader.GetValue(2) -cnotin @('NTLM','KERBEROS') -or [int]$reader.GetValue(3) -ne 1 -or [guid]$reader.GetValue(4) -ne $ExpectedCatalogDatabaseGuid -or [long]$reader.GetValue(5) -ne $ExecutionId -or [long]$reader.GetValue(6) -ne $ExpectedProjectLsn){throw 'SQL_BINDING_MISMATCH'}
                    $value=[pscustomobject]@{ExecutionId=$ExecutionId.ToString();ProjectLsn=$ExpectedProjectLsn.ToString();CatalogDatabaseGuid=([guid]$reader.GetValue(4)).ToString('D');ObservedExecutionStatus=[int]$reader.GetValue(7);Use32BitRuntime=[bool]$reader.GetValue(8);AuthScheme=[string]$reader.GetValue(2);ProcessId=$(if($reader.IsDBNull(9)){$null}else{[int]$reader.GetValue(9)});CreatedTime=[datetimeoffset]$reader.GetValue(10);EndTime=$(if($reader.IsDBNull(11)){$null}else{[datetimeoffset]$reader.GetValue(11)})}
                    if($value.ProcessId -lt 1){$value.ProcessId=$null}
                    if($reader.Read() -or $reader.NextResult()){throw 'SQL_BINDING_MISMATCH'}
                    $value
                }finally{$reader.Dispose()}
            }finally{$command.Dispose()}
        }
        try {
            if(-not [Environment]::Is64BitProcess -or $Port -lt 1 -or $Port -gt 65535 -or $ExecutionId -lt 1 -or $ExpectedProjectLsn -lt 1 -or $ExpectedCatalogDatabaseGuid -eq [guid]::Empty){throw 'INPUT'}
            $settings=[Data.SqlClient.SqlConnectionStringBuilder]::new();$settings['Data Source']="tcp:127.0.0.1,$Port";$settings['Initial Catalog']='master';$settings['Integrated Security']=$true;$settings['Encrypt']=$true;$settings['TrustServerCertificate']=$true;$settings['Pooling']=$false;$settings['Connect Timeout']=10
            $connection=[Data.SqlClient.SqlConnection]::new($settings.ConnectionString)
            $connection.Open();$snapshot=Read-SsisSnapshot
            $reason='CAPTURE_FAILED'
            $binn=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Microsoft SQL Server/170/DTS/Binn'
            $files=@(foreach($role in $roles.Keys){Read-SsisKnownFile (Join-Path $binn $roles[$role]) $role $binn})
            foreach($viewName in @('X64','X86')) {
                $base=$null;$key=$null;$view=if($viewName -ceq 'X64'){[Microsoft.Win32.RegistryView]::Registry64}else{[Microsoft.Win32.RegistryView]::Registry32}
                $entry=[ordered]@{View=$viewName;Status='UNAVAILABLE';Edition='UNKNOWN';EditionType='UNKNOWN'}
                try {$base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view);$key=$base.OpenSubKey('SOFTWARE\Microsoft\Microsoft SQL Server\170\DTS\Setup',$false);if($key){$entry.Status='OBSERVED';$entry.Edition=ConvertTo-SsisEditionCode $key.GetValue('Edition');$entry.EditionType=ConvertTo-SsisEditionCode $key.GetValue('EditionType')}else{$entry.Status='MISSING'}}catch{}finally{if($key){$key.Dispose()};if($base){$base.Dispose()}}
                $registration+= [pscustomobject]$entry
                foreach($pair in @(@{Role='CONNECTIONS';ProgId='DTS.ConnectionManagerOleDb.9'},@{Role='EXECUTE_PACKAGE';ProgId='SSIS.ExecutePackageTask.9'},@{Role='PIPELINE';ProgId='SSIS.Pipeline.9'})) {
                    $base=$null;$key=$null;$server=$null;$item=[ordered]@{View=$viewName;Role=$pair.Role;Status='UNAVAILABLE';ServerLocation='UNREPORTED';ServerFileMajor=$null}
                    try {
                        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view);$key=$base.OpenSubKey(('SOFTWARE\Classes\'+$pair.ProgId+'\CLSID'),$false)
                        if(-not $key){$item.Status='MISSING'}else{
                            $clsid=[guid]::Empty;if(-not [guid]::TryParse([string]$key.GetValue(''),[ref]$clsid) -or $clsid -eq [guid]::Empty){throw 'CLSID'}
                            $server=$base.OpenSubKey(('SOFTWARE\Classes\CLSID\'+$clsid.ToString('B')+'\InprocServer32'),$false)
                            if(-not $server){$item.Status='MISSING'}else{
                                $item.Status='REGISTERED';$candidate=[Environment]::ExpandEnvironmentVariables(([string]$server.GetValue('')).Trim('"'))
                                $root=if($viewName -ceq 'X64'){$binn}else{Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft SQL Server/170/DTS/Binn'}
                                if([string]::Equals([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($candidate)),$root,[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([IO.Path]::GetFileName($candidate),$roles[$pair.Role],[StringComparison]::OrdinalIgnoreCase)){$item.ServerLocation='EXPECTED_DTS_BINN';$binary=Read-SsisKnownFile $candidate $pair.Role $root;$item.ServerFileMajor=$binary.FileMajor}else{$item.ServerLocation='OTHER'}
                            }
                        }
                    }catch{}finally{if($server){$server.Dispose()};if($key){$key.Dispose()};if($base){$base.Dispose()}}
                    $comRegistration+= [pscustomobject]$item
                }
            }
            $command=$connection.CreateCommand();$command.CommandTimeout=10
            try {$command.CommandText='SELECT DISTINCT TOP(65) message_code FROM SSISDB.catalog.event_messages WHERE operation_id=@execution AND message_type=120 AND message_code IS NOT NULL ORDER BY message_code;';[void]$command.Parameters.Add('@execution',[Data.SqlDbType]::BigInt);$command.Parameters['@execution'].Value=$ExecutionId;$reader=$command.ExecuteReader();try {while($reader.Read()){if($codes.Count -eq 64){$truncated=$true;break};$codes+= [int]$reader.GetValue(0)}}finally{$reader.Dispose()}}finally{$command.Dispose()}
            $worker.Status=if($snapshot.ProcessId -gt 0){'NOT_INSPECTED_TERMINAL'}else{'NOT_REPORTED'};$worker.ProcessId=$snapshot.ProcessId
            if($snapshot.ProcessId -gt 0 -and $snapshot.ObservedExecutionStatus -in @(2,5,8)) {
                $process=$null
                try {
                    $process=[Diagnostics.Process]::GetProcessById($snapshot.ProcessId);$null=$process.Handle
                    $worker.StartTimeUtc=([datetimeoffset]$process.StartTime.ToUniversalTime()).ToString('o')
                    if($process.StartTime.ToUniversalTime() -lt $snapshot.CreatedTime.UtcDateTime -or -not [string]::Equals($process.MainModule.FileName,(Join-Path $binn 'ISServerExec.exe'),[StringComparison]::OrdinalIgnoreCase)){$worker.Status='PID_IDENTITY_UNPROVEN'}else{
                        $worker.Status='RUNNING_CANDIDATE';$worker.Files=@(foreach($module in $process.Modules){foreach($role in $roles.Keys){if([string]::Equals($module.ModuleName,$roles[$role],[StringComparison]::OrdinalIgnoreCase)){Read-SsisKnownFile $module.FileName $role $binn}}})
                        if($worker.Files.Count -gt 6 -or @($worker.Files|Where-Object Role -CEQ 'EXECUTOR').Count -ne 1){throw 'MODULE_LIMIT'}
                        $after=Read-SsisSnapshot;if($after.ProcessId -ne $snapshot.ProcessId -or $after.ObservedExecutionStatus -notin @(2,5,8) -or $process.HasExited){$worker.Status='ENDED_DURING_READ'}
                    }
                }catch [ArgumentException]{$worker.Status='NOT_RUNNING'}catch{if($_.Exception.Message -ceq 'SQL_BINDING_MISMATCH'){throw};$worker.Status='INSPECTION_FAILED'}finally{if($process){$process.Dispose()}}
            }
            $null=Read-SsisSnapshot
            if([datetime]::UtcNow -ge $deadline){throw 'DEADLINE'}
            if($truncated){$reason='EVENT_LIMIT'}else{$status='OBSERVED';$reason='NONE'}
        }catch{if($_.Exception.Message -ceq 'SQL_BINDING_MISMATCH'){$reason='SQL_BINDING_MISMATCH';$snapshot=$null}}finally{if($connection){$connection.Dispose()}}
        $bound=if($snapshot){[pscustomobject]@{ExecutionId=$snapshot.ExecutionId;ProjectLsn=$snapshot.ProjectLsn;CatalogDatabaseGuid=$snapshot.CatalogDatabaseGuid;ObservedExecutionStatus=$snapshot.ObservedExecutionStatus;Use32BitRuntime=$snapshot.Use32BitRuntime;AuthScheme=$snapshot.AuthScheme}}else{$null}
        [pscustomobject]@{ContractVersion='SqlServerLab.SsisExecutionGuest/1.0';Status=$status;ReasonCode=$reason;Snapshot=$bound;InstalledFiles=@($files);Registration=@($registration);ComRegistration=@($comRegistration);Worker=$worker;ErrorCodes=@($codes);ErrorCodesTruncated=[bool]$truncated}
    }
}
