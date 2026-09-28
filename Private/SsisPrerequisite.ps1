# Interne, rein lesende Beobachtung; kein Installations- oder Ausführungsnachweis.
function Get-LabSsisPrerequisiteContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$RunId,[Parameter(Mandatory)][string]$InstanceId,[Parameter(Mandatory)][string]$StateRoot)
    if ($RunId -eq [guid]::Empty -or $InstanceId -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$') { throw 'SSIS_TARGET_INVALID' }
    $root=Assert-LabDiagnosticPath -Path $StateRoot
    $directory=Join-Path (Join-Path $root 'runs') $RunId.ToString()
    $run=Read-LabDiagnosticJson -Path (Join-Path $directory 'run-state.json')
    $connection=Read-LabDiagnosticJson -Path (Join-Path $directory 'connection-info.json')
    $instances=@($connection.instances | Where-Object { [string]$_.id -ceq $InstanceId })
    if ([string]$run.runId -cne $RunId.ToString() -or [string]$run.state -cne 'RUNNING' -or
        [string]$run.metadata.workflowKind -cne 'hyperv-lab' -or -not [string]$run.scopeId -or $instances.Count -ne 1) { throw 'SSIS_TARGET_INVALID' }
    $instance=$instances[0]
    $vmId=[guid]::Empty
    if ([string]$instance.provider -cne 'hyperv' -or [string]$instance.workload -cne 'sql' -or
        [string]$instance.sqlVersion -cne '2025' -or -not [guid]::TryParse([string]$instance.vmId,[ref]$vmId) -or $vmId -eq [guid]::Empty -or
        [string]$instance.sqlReadiness.instanceName -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$' -or
        [int]$instance.port -lt 1 -or [int]$instance.port -gt 65535) { throw 'SSIS_TARGET_INVALID' }
    $managed=Get-HyperVManagedVM -VMName ([string]$instance.vmName) -ExpectedRunId $RunId.ToString() -ExpectedScopeId ([string]$run.scopeId)
    if (-not $managed -or [string]$managed.VM.Id -ne $vmId.ToString() -or [string]$managed.VM.State -ne 'Running' -or
        [string]$managed.Identity.instanceId -cne $InstanceId) { throw 'SSIS_VM_BINDING_INVALID' }
    foreach ($name in @('guest-administrator-password','generated-sql-sa-password','sa-password')) {
        $null=Assert-LabDiagnosticPath -Path (Join-Path $directory "secrets/$name.secret")
    }
    $identity=@{Run=$run;Connection=$connection;VmId=$vmId.ToString();InstanceId=$InstanceId} | ConvertTo-Json -Depth 32 -Compress
    [pscustomobject]@{Run=$run;Instance=$instance;Directory=$directory;StateRoot=$root;Fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity)))}
}

function Get-LabSsisGuestProbe {
    [CmdletBinding()]
    param()
    return {
        param([securestring]$Password,[int]$Port,[string]$ExpectedInstance,[int]$SqlTimeout)
        $ErrorActionPreference='Stop'
        function Read-SsisComponentObservation {
            $directory=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Microsoft SQL Server/170/DTS/Binn'
            $status='OBSERVED'
            foreach ($name in @('DTExec.exe','Microsoft.SqlServer.IntegrationServices.Server.dll')) {
                try {
                    $file=Get-Item -LiteralPath (Join-Path $directory $name) -Force -ErrorAction Stop
                    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [int]$file.VersionInfo.FileMajorPart -ne 17) { return 'UNKNOWN' }
                }
                catch [Management.Automation.ItemNotFoundException] { $status='NOT_OBSERVED' }
                catch { return 'UNKNOWN' }
            }
            return $status
        }
        function Read-SsisSqlObservation {
            param($Connection,[int]$Timeout)
            $command=$null;$reader=$null
            try {
                $command=$Connection.CreateCommand();$command.CommandTimeout=$Timeout
                # Sysadmin avoids interpreting metadata invisibility (including OFFLINE databases) as absence.
                $command.CommandText=@'
SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion')),
       CONVERT(nvarchar(128),SERVERPROPERTY('Edition')),
       COALESCE(CONVERT(nvarchar(128),SERVERPROPERTY('InstanceName')),N'MSSQLSERVER'),
       IS_SRVROLEMEMBER(N'sysadmin'),
       (SELECT state_desc FROM sys.databases WHERE name=N'SSISDB');
'@
                $reader=$command.ExecuteReader([Data.CommandBehavior]::SequentialAccess)
                if (-not $reader.Read()) { throw 'SSIS_SQL_RESULT_INVALID' }
                $major=if($reader.IsDBNull(0)){0}else{[int]$reader.GetValue(0)}
                $edition=if($reader.IsDBNull(1)){''}else{[string]$reader.GetValue(1)}
                $instance=if($reader.IsDBNull(2)){''}else{[string]$reader.GetValue(2)}
                $sysadmin=if($reader.IsDBNull(3)){0}else{[int]$reader.GetValue(3)}
                $state=if($reader.IsDBNull(4)){''}else{[string]$reader.GetValue(4)}
                if ($reader.Read() -or $reader.NextResult()) { throw 'SSIS_SQL_RESULT_INVALID' }
                $reader.Dispose();$reader=$null
                $catalog='UNKNOWN'
                if ($sysadmin -eq 1) {
                    $catalog=if(-not $state){'MISSING'}elseif($state -ne 'ONLINE'){'NOT_ONLINE'}else{'ONLINE_UNVERIFIED'}
                    if ($state -eq 'ONLINE') {
                        $command.CommandText="SELECT CASE WHEN OBJECT_ID(N'[SSISDB].[catalog].[catalog_properties]',N'V') IS NOT NULL THEN 1 ELSE 0 END;"
                        $value=$command.ExecuteScalar()
                        if ($value -is [int] -and $value -eq 1) { $catalog='ONLINE_CATALOG_OBSERVED' }
                    }
                }
                [pscustomobject]@{Major=$major;Edition=$edition;Instance=$instance;Catalog=$catalog}
            }
            finally { if($reader){$reader.Dispose()};if($command){$command.Dispose()} }
        }
        $components=Read-SsisComponentObservation
        $connection=$null;$secret=$null
        try {
            Add-Type -AssemblyName System.Data
            $secret=$Password.Copy();$secret.MakeReadOnly()
            $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new()
            $builder['Data Source']="tcp:127.0.0.1,$Port";$builder['Initial Catalog']='master'
            $builder['Encrypt']=$true;$builder['TrustServerCertificate']=$true;$builder['Pooling']=$false
            $builder['Persist Security Info']=$false;$builder['Connect Timeout']=[math]::Min(15,$SqlTimeout)
            $connection=[Data.SqlClient.SqlConnection]::new($builder.ConnectionString,[Data.SqlClient.SqlCredential]::new('sa',$secret))
            $connection.Open()
            $observation=Read-SsisSqlObservation -Connection $connection -Timeout $SqlTimeout
            if ($observation.Instance -ine $ExpectedInstance) { throw 'SSIS_SQL_INSTANCE_MISMATCH' }
            [pscustomobject]@{SqlStatus='OBSERVED';Major=$observation.Major;Edition=$observation.Edition;Components=$components;Catalog=$observation.Catalog}
        }
        catch { [pscustomobject]@{SqlStatus='UNKNOWN';Major=0;Edition='';Components=$components;Catalog='UNKNOWN'} }
        finally { if($connection){$connection.Dispose()};if($secret){$secret.Dispose()} }
    }
}

function ConvertTo-LabSsisPrerequisiteResult {
    [CmdletBinding()]
    param([AllowNull()]$Observation,[string]$FailureCode='')
    $sql='UNKNOWN';$edition='UNKNOWN';$components='UNKNOWN';$catalog='UNKNOWN'
    if ($null -ne $Observation) {
        if ([string]$Observation.Components -cin @('OBSERVED','NOT_OBSERVED','UNKNOWN')) { $components=[string]$Observation.Components }
        if ([string]$Observation.SqlStatus -ceq 'OBSERVED') {
            $sql=if($Observation.Major -eq 17){'SQL_2025_OBSERVED'}else{'VERSION_MISMATCH'}
            $edition=switch -Regex ([string]$Observation.Edition) {
                '^(Enterprise |Standard )?Developer Edition( \(64-bit\))?$' { (([string]$Matches[1]).Trim()+'Developer').Trim();break }
                '^(Enterprise|Standard|Express|Web|Enterprise Evaluation) Edition( \(64-bit\))?$' { $Matches[1];break }
                default { 'UNKNOWN' }
            }
            if ([string]$Observation.Catalog -cin @('MISSING','NOT_ONLINE','ONLINE_UNVERIFIED','ONLINE_CATALOG_OBSERVED','UNKNOWN')) { $catalog=[string]$Observation.Catalog }
        }
    }
    if ($FailureCode -cnotin @('','SSIS_TARGET_UNAVAILABLE','SSIS_PROBE_UNAVAILABLE','SSIS_BINDING_CHANGED')) { $FailureCode='SSIS_PROBE_UNAVAILABLE' }
    [pscustomobject]@{
        Contract='SqlServerLab.SsisPrerequisite/0.1';Provider='hyperv';OperatingSystem='windows'
        Sql=$sql;Edition=$edition;DefaultPathComponents=$components;SsisDb=$catalog
        Status=$(if($FailureCode -or $sql -eq 'UNKNOWN'){'INCONCLUSIVE'}else{'OBSERVED'})
        ReasonCode=$FailureCode;ExecutionStatus='NOT_EXECUTED';InstallationVerified=$false;ReadOnly=$true
    }
}

function Invoke-LabSsisPrerequisite {
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$RunId,[string]$InstanceId='primary',[Parameter(Mandatory)][string]$StateRoot,[ValidateRange(10,120)][int]$TimeoutSeconds=60)
    $guest=$null;$sa=$null
    try {
        try { $context=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot }
        catch { return ConvertTo-LabSsisPrerequisiteResult -Observation $null -FailureCode 'SSIS_TARGET_UNAVAILABLE' }
        $guest=Get-LabSecret -Path $context.Directory -Name 'guest-administrator-password'
        $sa=Get-LabSecret -Path $context.Directory -Name 'generated-sql-sa-password'
        if (-not $sa) { $sa=Get-LabSecret -Path $context.Directory -Name 'sa-password' }
        if (-not $guest -or -not $sa) { throw 'SSIS_CREDENTIAL_REQUIRED' }
        $fresh=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ($fresh.Fingerprint -cne $context.Fingerprint) { return ConvertTo-LabSsisPrerequisiteResult -Observation $null -FailureCode 'SSIS_BINDING_CHANGED' }
        $observation=@(Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() `
            -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) `
            -Credential ([pscredential]::new('Administrator',$guest)) -ScriptBlock (Get-LabSsisGuestProbe) `
            -ArgumentList @($sa,[int]$context.Instance.port,[string]$context.Instance.sqlReadiness.instanceName,[math]::Min(30,$TimeoutSeconds)) `
            -TimeoutSeconds $TimeoutSeconds -ErrorAction Stop 3>$null 4>$null 5>$null 6>$null)
        $fresh=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ($fresh.Fingerprint -cne $context.Fingerprint) { return ConvertTo-LabSsisPrerequisiteResult -Observation $null -FailureCode 'SSIS_BINDING_CHANGED' }
        if ($observation.Count -ne 1) { throw 'SSIS_RESULT_INVALID' }
        ConvertTo-LabSsisPrerequisiteResult -Observation $observation[0]
    }
    catch { ConvertTo-LabSsisPrerequisiteResult -Observation $null -FailureCode 'SSIS_PROBE_UNAVAILABLE' }
    finally { if($guest){$guest.Dispose()};if($sa){$sa.Dispose()} }
}
