# Consumer SQL execution reuses the existing Windows SQL binding, DPAPI store
# and strict PowerShell Direct transport. It is an authorized admin operation,
# not a sandbox for untrusted SQL. Consumer objects/cleanup remain caller-owned.
function ConvertTo-LabWindowsSqlParameters {
    [CmdletBinding()]
    param([hashtable]$Parameters = @{})
    if ($Parameters.Count -gt 32) { throw 'WINDOWS_SQL_PARAMETERS_INVALID' }
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $items=[Collections.Generic.List[object]]::new(); $bytes=0L
    foreach ($key in $Parameters.Keys) {
        if ($key -isnot [string] -or $key -cnotmatch '^@?[A-Za-z][A-Za-z0-9_]{0,63}$') { throw 'WINDOWS_SQL_PARAMETERS_INVALID' }
        $name='@'+$key.TrimStart('@')
        if (-not $names.Add($name)) { throw 'WINDOWS_SQL_PARAMETERS_INVALID' }
        $value=$Parameters[$key]
        $type=if ($null -eq $value) {'NVarChar'}
            elseif ($value -is [byte[]]) {'VarBinary'}
            elseif ($value -is [string]) {'NVarChar'}
            elseif ($value -is [int]) {'Int'}
            elseif ($value -is [long]) {'BigInt'}
            elseif ($value -is [bool]) {'Bit'}
            else { throw 'WINDOWS_SQL_PARAMETERS_INVALID' }
        $bytes+=if ($value -is [byte[]]) {$value.LongLength} elseif ($value -is [string]) {[Text.Encoding]::UTF8.GetByteCount($value)} else {8}
        if ($bytes -gt 16MB) { throw 'WINDOWS_SQL_PARAMETERS_TOO_LARGE' }
        # Own the binary input snapshot; callers cannot change a deployment in flight.
        if ($value -is [byte[]]) { $value=$value.Clone() }
        $items.Add([pscustomobject]@{Name=$name;Type=$type;Value=$value})
    }
    return ,$items.ToArray()
}

function Get-LabWindowsSqlScriptGuest {
    [CmdletBinding()]param()
    return {
        param([string[]]$Batches,[object[]]$Parameters,[string]$Database,[int]$Port,
            [string]$ExpectedInstance,[int]$ExpectedMajor,[bool]$KeepConnection,[int]$TimeoutSeconds)
        $ErrorActionPreference='Stop'
        $connection=$null; $executed=0; $auth=''; $stage='IDENTITY'; $sqlNumber=$null
        $sets=[Collections.Generic.List[object]]::new(); $resultBytes=0L; $rowCount=0
        $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        function New-WindowsSqlConnection {
            $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new()
            $builder.DataSource="tcp:127.0.0.1,$Port"; $builder.InitialCatalog=$Database
            $builder.IntegratedSecurity=$true; $builder.Encrypt=$true; $builder.TrustServerCertificate=$true
            $builder.Pooling=$false; $builder.ConnectTimeout=[math]::Min(15,$TimeoutSeconds)
            $sql=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
            try {
                $sql.Open(); $cmd=$sql.CreateCommand(); $cmd.CommandTimeout=[math]::Min(15,$TimeoutSeconds)
                try {
                    $cmd.CommandText="SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion')), CONVERT(nvarchar(128),ISNULL(SERVERPROPERTY('InstanceName'),N'MSSQLSERVER')), CONVERT(nvarchar(40),CONNECTIONPROPERTY('auth_scheme'));"
                    $reader=$cmd.ExecuteReader()
                    try {
                        if (-not $reader.Read() -or $reader.GetInt32(0) -ne $ExpectedMajor -or
                            $reader.GetString(1) -cne $ExpectedInstance -or $reader.GetString(2) -cnotin @('NTLM','KERBEROS')) {
                            throw 'WINDOWS_SQL_IDENTITY_INVALID'
                        }
                        $scriptAuth=$reader.GetString(2)
                        if ($reader.Read()) { throw 'WINDOWS_SQL_IDENTITY_INVALID' }
                    } finally {$reader.Dispose()}
                } finally {$cmd.Dispose()}
                [pscustomobject]@{Connection=$sql;AuthScheme=$scriptAuth}
            } catch {$sql.Dispose(); throw}
        }
        try {
            for ($index=0; $index -lt $Batches.Count; $index++) {
                $stage='IDENTITY'
                if (-not $connection) { $opened=New-WindowsSqlConnection; $connection=$opened.Connection; $auth=$opened.AuthScheme }
                $stage='SCRIPT'
                $remaining=[int][math]::Floor(($deadline-[datetime]::UtcNow).TotalSeconds)
                if ($remaining -lt 1) { throw 'WINDOWS_SQL_DEADLINE' }
                $command=$connection.CreateCommand(); $command.CommandTimeout=$remaining
                try {
                    $command.CommandText=$Batches[$index]
                    foreach ($item in $Parameters) {
                        $parameter=$command.Parameters.Add([string]$item.Name,[Data.SqlDbType]([string]$item.Type))
                        if ($item.Type -in @('VarBinary','NVarChar')) { $parameter.Size=-1 }
                        $parameter.Value=if ($null -eq $item.Value) {[DBNull]::Value} else {$item.Value}
                    }
                    $reader=$command.ExecuteReader([Data.CommandBehavior]::SequentialAccess)
                    try {
                        do {
                            $stage='OUTPUT'
                            if ($reader.FieldCount -gt 64 -or $sets.Count -ge 128) { throw 'WINDOWS_SQL_RESULT_LIMIT' }
                            $columns=@(for($i=0;$i -lt $reader.FieldCount;$i++) {$reader.GetName($i)})
                            $rows=[Collections.Generic.List[object]]::new()
                            while ($reader.Read()) {
                                if (++$rowCount -gt 1024 -or [datetime]::UtcNow -ge $deadline) { throw 'WINDOWS_SQL_RESULT_LIMIT' }
                                $cells=@(for($i=0;$i -lt $reader.FieldCount;$i++) {
                                    if ($reader.IsDBNull($i)) {$null;continue}
                                    $fieldType=$reader.GetFieldType($i)
                                    if ($fieldType -eq [byte[]]) {throw 'WINDOWS_SQL_RESULT_TYPE_UNSUPPORTED'}
                                    if ($fieldType -eq [string]) {
                                        $length=$reader.GetChars($i,0,$null,0,0)
                                        if ($length -gt 128KB) {throw 'WINDOWS_SQL_RESULT_LIMIT'}
                                        $characters=[char[]]::new([int]$length)
                                        if ($reader.GetChars($i,0,$characters,0,$characters.Length) -ne $length) {throw 'WINDOWS_SQL_RESULT_READ_FAILED'}
                                        [string]::new($characters);continue
                                    }
                                    $value=$reader.GetValue($i)
                                    if ($value -is [datetime]) {$value.ToString('o')}
                                    elseif ($value -is [guid]) {$value.ToString()}
                                    elseif ($value -is [string] -or $value -is [ValueType] -and $value -isnot [Data.SqlTypes.INullable]) {$value}
                                    else {throw 'WINDOWS_SQL_RESULT_TYPE_UNSUPPORTED'}
                                })
                                $resultBytes+=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $cells -Depth 4 -Compress))
                                if ($resultBytes -gt 512KB) { throw 'WINDOWS_SQL_RESULT_LIMIT' }
                                $rows.Add($cells)
                            }
                            if ($reader.FieldCount -gt 0) { $sets.Add([pscustomobject]@{Batch=$index+1;Columns=$columns;Rows=$rows.ToArray()}) }
                            $stage='SCRIPT'
                        } while ($reader.NextResult())
                    } finally {$reader.Dispose()}
                    $executed++
                } finally {$command.Dispose()}
                if (-not $KeepConnection) {$connection.Dispose(); $connection=$null}
            }
            $result=[pscustomobject]@{Success=$true;Batches=$executed;AuthScheme=$auth;ResultSets=$sets.ToArray();ErrorCode=$null;SqlErrorNumber=$null}
            if ([Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $result -Depth 12 -Compress)) -gt 1MB) {throw 'WINDOWS_SQL_RESULT_LIMIT'}
            return $result
        } catch {
            # Neither SQL text, provider errors, identities nor selected data
            # become automatic diagnostics. A failure never proves rollback.
            if ($_.Exception -is [Data.SqlClient.SqlException]) {$sqlNumber=$_.Exception.Number}
            return [pscustomobject]@{Success=$false;Batches=$executed;AuthScheme=$auth;ResultSets=@();ErrorCode=('WINDOWS_SQL_'+$stage+'_FAILED');SqlErrorNumber=$sqlNumber}
        } finally {if($connection){$connection.Dispose()}}
    }
}

function Invoke-LabWindowsSqlScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$RunId,[Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$ScriptPath,
        [string]$Database='master',[hashtable]$Parameters=@{},[switch]$KeepConnection,
        [ValidateRange(5,600)][int]$TimeoutSeconds=300)
    if (-not $IsWindows) {throw 'WINDOWS_SQL_WINDOWS_HOST_REQUIRED'}
    if ($Database -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {throw 'WINDOWS_SQL_DATABASE_INVALID'}
    $inputParameters=ConvertTo-LabWindowsSqlParameters -Parameters $Parameters
    $inputStream=$null
    try {
        $inputPath=Assert-LabDiagnosticPath -Path $ScriptPath
        $inputStream=[IO.File]::Open($inputPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ($inputStream.Length -lt 1 -or $inputStream.Length -gt 4MB) {throw 'WINDOWS_SQL_SCRIPT_SIZE_INVALID'}
        $bytes=[byte[]]::new([int]$inputStream.Length); $offset=0
        while($offset -lt $bytes.Length) {$read=$inputStream.Read($bytes,$offset,$bytes.Length-$offset);if($read -lt 1){throw 'WINDOWS_SQL_SCRIPT_READ_FAILED'};$offset+=$read}
        $text=([Text.UTF8Encoding]::new($false,$true)).GetString($bytes).TrimStart([char]0xFEFF)
        $batches=@([regex]::Split($text,'(?im)^\s*GO\s*(?:--.*)?$') | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
        if ($batches.Count -lt 1 -or $batches.Count -gt 256 -or $text.Contains([char]0)) {throw 'WINDOWS_SQL_SCRIPT_INVALID'}
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    } catch {throw 'WINDOWS_SQL_INPUT_INVALID'} finally {if($inputStream){$inputStream.Dispose()}}
    # This existing binder already validates state paths, unique run/instance,
    # provider, running VM, durable VM ID, SQL version and expected SQL instance.
    try {$context=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot}
    catch {throw 'WINDOWS_SQL_TARGET_UNAVAILABLE'}
    $guest=$null; $lease=$null; $journal=$null; $watch=[Diagnostics.Stopwatch]::StartNew()
    $operationId=[guid]::NewGuid().ToString(); $dispatched=$false
    try {
        $lockPath=Assert-LabDiagnosticPath -Path (Join-Path $context.Directory 'windows-sql-script.lock')
        try {$lease=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch {throw 'WINDOWS_SQL_OPERATION_BUSY'}
        $fresh=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ($fresh.Fingerprint -cne $context.Fingerprint) {throw 'WINDOWS_SQL_BINDING_CHANGED'}
        $guest=Get-LabSecret -Path $context.Directory -Name 'guest-administrator-password'
        if (-not $guest) {throw 'WINDOWS_SQL_GUEST_CREDENTIAL_REQUIRED'}
        $journalPath=Assert-LabDiagnosticPath -Path (Join-Path $context.Directory ('windows-sql-'+$operationId+'.json'))
        $journal=[ordered]@{ContractVersion='SqlServerLab.WindowsSqlOperation/1.0';OperationId=$operationId;
            RunId=$RunId.ToString();ScopeId=[string]$context.Run.scopeId;InstanceId=$InstanceId;VmId=[string]$context.Instance.vmId;
            ScriptSha256=$hash;Status='DISPATCHED';Recovery='INSPECT_OWN_CONSUMER_OBJECTS_BEFORE_ANY_RETRY'}
        Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        $fresh=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ($fresh.Fingerprint -cne $context.Fingerprint) {throw 'WINDOWS_SQL_BINDING_CHANGED'}
        $dispatched=$true
        $response=@(Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() `
            -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) `
            -Credential ([pscredential]::new('Administrator',$guest)) -NoRetry -TimeoutSeconds $TimeoutSeconds `
            -ScriptBlock (Get-LabWindowsSqlScriptGuest) -ArgumentList @($batches,$inputParameters,$Database,[int]$context.Instance.port,
                [string]$context.ExpectedInstance,[int]$context.ExpectedMajor,[bool]$KeepConnection,$TimeoutSeconds) `
            -ErrorAction Stop 3>$null 4>$null 5>$null 6>$null)
        $fresh=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ($fresh.Fingerprint -cne $context.Fingerprint) {throw 'WINDOWS_SQL_BINDING_CHANGED'}
        if ($response.Count -ne 1 -or $response[0].Success -isnot [bool] -or $response[0].Batches -lt 0 -or
            $response[0].Batches -gt $batches.Count -or ($response[0].Success -and
                ($response[0].Batches -ne $batches.Count -or $response[0].AuthScheme -cnotin @('NTLM','KERBEROS'))) -or
            (-not $response[0].Success -and $response[0].ErrorCode -cnotin @('WINDOWS_SQL_IDENTITY_FAILED','WINDOWS_SQL_SCRIPT_FAILED','WINDOWS_SQL_OUTPUT_FAILED')) -or
            ($null -ne $response[0].SqlErrorNumber -and $response[0].SqlErrorNumber -isnot [int]) -or
            [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $response[0] -Depth 12 -Compress)) -gt 1MB) {throw 'WINDOWS_SQL_RESPONSE_INVALID'}
        $result=$response[0]
        $journal.Status=if($result.Success){'SUCCEEDED'}else{'FAILED_UNCONFIRMED'}
        Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal
        [pscustomobject]@{Success=[bool]$result.Success;Message=$journal.Status;Batches=[int]$result.Batches;Duration=$watch.Elapsed;
            OperationId=$operationId;RunId=$RunId.ToString();InstanceId=$InstanceId;Authentication='Windows';AuthScheme=[string]$result.AuthScheme;
            Outcome=$journal.Status;ResultSets=@($result.ResultSets);ErrorCode=$result.ErrorCode;SqlErrorNumber=$result.SqlErrorNumber}
    } catch {
        $reason=if ($_.Exception.Message -cin @('WINDOWS_SQL_OPERATION_BUSY','WINDOWS_SQL_BINDING_CHANGED','WINDOWS_SQL_GUEST_CREDENTIAL_REQUIRED','WINDOWS_SQL_RESPONSE_INVALID')) {
            $_.Exception.Message
        } else {'WINDOWS_SQL_TRANSPORT_OR_JOURNAL_FAILED'}
        $journalRecorded=$false
        if ($journal) {
            $journal.Status=if($dispatched){'FAILED_UNCONFIRMED'}else{'NOT_DISPATCHED'}
            try {Write-LabArtifactJsonAtomic -Path $journalPath -InputObject $journal;$journalRecorded=$true} catch {$journalRecorded=$false}
        }
        $code=if($dispatched){'WINDOWS_SQL_OPERATION_UNCONFIRMED'}else{'WINDOWS_SQL_NOT_DISPATCHED'}
        $failure=[InvalidOperationException]::new($code+': Inspect the bound consumer objects and operation journal before retrying.')
        $failure.Data['OperationId']=$operationId; $failure.Data['Dispatched']=$dispatched
        $failure.Data['JournalRecorded']=$journalRecorded
        $failure.Data['ReasonCode']=$reason
        throw $failure
    } finally {if($guest){$guest.Dispose()};if($lease){$lease.Dispose()};$watch.Stop()}
}
