<#
.SYNOPSIS
    Erfasst sanitisierte SQL-Observability-Evidence read-only.
#>

function Get-LabSqlObservabilityEvidenceSqlObservation {
    [CmdletBinding()]
    param(
        [string]$HostName='127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$SaPlain
    )

    $query=@"
SET NOCOUNT ON;
SELECT CONCAT(N'OBS100_SERVER|', CONVERT(nvarchar(10),SERVERPROPERTY('ProductMajorVersion')), N'|', CONVERT(nvarchar(20),cpu_count), N'|', CONVERT(nvarchar(30),physical_memory_kb))
FROM sys.dm_os_sys_info;
SELECT CONCAT(N'OBS100_DATABASE|', CONVERT(nvarchar(30),COUNT_BIG(*)), N'|', CONVERT(nvarchar(30),COALESCE(SUM(CONVERT(bigint,size))*8,0)), N'|', CONVERT(nvarchar(30),COALESCE(SUM(CASE WHEN is_query_store_on=1 THEN 1 ELSE 0 END),0)))
FROM sys.databases
WHERE state=0;
SELECT CONCAT(N'OBS100_WAIT|', CONVERT(nvarchar(30),COUNT_BIG(*)), N'|', CONVERT(nvarchar(30),COALESCE(SUM(waiting_tasks_count),0)), N'|', CONVERT(nvarchar(30),COALESCE(SUM(wait_time_ms),0)))
FROM sys.dm_os_wait_stats
WHERE wait_type NOT LIKE N'SLEEP%';
"@
    $lines=@(Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $SaPlain -Database master -Query $query | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^OBS100_(SERVER|DATABASE|WAIT)\|' })
    $records=@{}
    foreach($line in $lines){
        $parts=$line.Split('|')
        if($parts.Count -ne 4 -or $parts[0] -notmatch '^OBS100_(SERVER|DATABASE|WAIT)$' -or $records.ContainsKey($parts[0])){
            throw 'SQL_OBSERVABILITY_EVIDENCE_RESULT_INVALID'
        }
        if(@($parts[1..3] | Where-Object { $_ -notmatch '^\d+$' }).Count -gt 0){
            throw 'SQL_OBSERVABILITY_EVIDENCE_RESULT_INVALID'
        }
        $records[$parts[0]]=@($parts[1..3] | ForEach-Object { [long]$_ })
    }
    foreach($record in @('OBS100_SERVER','OBS100_DATABASE','OBS100_WAIT')){
        if(-not $records.ContainsKey($record)){throw "SQL_OBSERVABILITY_EVIDENCE_RESULT_MISSING: $record"}
    }
    if($records.OBS100_SERVER[0] -lt 1 -or $records.OBS100_SERVER[1] -lt 1 -or $records.OBS100_SERVER[2] -lt 1){
        throw 'SQL_OBSERVABILITY_EVIDENCE_RESULT_INVALID'
    }
    [PSCustomObject][ordered]@{
        SqlMajorVersion=[string]$records.OBS100_SERVER[0]
        CpuCount=[int]$records.OBS100_SERVER[1]
        PhysicalMemoryKb=[long]$records.OBS100_SERVER[2]
        OnlineDatabaseCount=[long]$records.OBS100_DATABASE[0]
        TotalFileSizeKb=[long]$records.OBS100_DATABASE[1]
        QueryStoreEnabledCount=[long]$records.OBS100_DATABASE[2]
        NonSleepWaitTypeCount=[long]$records.OBS100_WAIT[0]
        WaitingTaskCount=[long]$records.OBS100_WAIT[1]
        WaitTimeMs=[long]$records.OBS100_WAIT[2]
    }
}

function Test-LabSqlObservabilityEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Evidence)
    try {
        $valid=$Evidence | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $script:SchemasPath 'sql-observability-evidence.schema.json') -ErrorAction Stop
    }
    catch { throw "SQL_OBSERVABILITY_EVIDENCE_SCHEMA_INVALID: $($_.Exception.Message)" }
    if(-not $valid){throw 'SQL_OBSERVABILITY_EVIDENCE_SCHEMA_INVALID'}
    return $true
}

function New-LabSqlObservabilityEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Observation,
        [Parameter(Mandatory)][ValidateSet('docker','podman','hyperv','external')][string]$Provider,
        [AllowNull()][string]$RunId,
        [AllowNull()][string]$InstanceId
    )

    foreach($property in @('SqlMajorVersion','CpuCount','PhysicalMemoryKb','OnlineDatabaseCount','TotalFileSizeKb','QueryStoreEnabledCount','NonSleepWaitTypeCount','WaitingTaskCount','WaitTimeMs')){
        if(-not $Observation.PSObject.Properties[$property] -or [long]$Observation.$property -lt 0){
            throw "SQL_OBSERVABILITY_EVIDENCE_OBSERVATION_INVALID: $property"
        }
    }
    if([long]$Observation.CpuCount -lt 1 -or [long]$Observation.PhysicalMemoryKb -lt 1 -or [string]$Observation.SqlMajorVersion -notmatch '^[0-9]{2,4}$'){
        throw 'SQL_OBSERVABILITY_EVIDENCE_OBSERVATION_INVALID'
    }
    if([long]$Observation.QueryStoreEnabledCount -gt [long]$Observation.OnlineDatabaseCount){
        throw 'SQL_OBSERVABILITY_EVIDENCE_OBSERVATION_INVALID'
    }
    $evidence=[PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.SqlObservabilityEvidence/1.0'
        Source=[PSCustomObject][ordered]@{Provider=$Provider;RunId=$RunId;InstanceId=$InstanceId;SqlMajorVersion=[string]$Observation.SqlMajorVersion}
        ObservationStatus='SQL_ENGINE_COMPLETE'
        Server=[PSCustomObject][ordered]@{CpuCount=[int]$Observation.CpuCount;PhysicalMemoryKb=[long]$Observation.PhysicalMemoryKb}
        Databases=[PSCustomObject][ordered]@{OnlineCount=[long]$Observation.OnlineDatabaseCount;TotalFileSizeKb=[long]$Observation.TotalFileSizeKb;QueryStoreEnabledCount=[long]$Observation.QueryStoreEnabledCount}
        WaitStatistics=[PSCustomObject][ordered]@{NonSleepWaitTypeCount=[long]$Observation.NonSleepWaitTypeCount;WaitingTaskCount=[long]$Observation.WaitingTaskCount;WaitTimeMs=[long]$Observation.WaitTimeMs}
        EvidenceBoundary=[PSCustomObject][ordered]@{SqlTextIncluded=$false;DatabaseNamesIncluded=$false;LoginNamesIncluded=$false;HostValuesIncluded=$false;SecretValuesIncluded=$false}
        ObservedAt=Get-LabTimestamp
    }
    $null=Test-LabSqlObservabilityEvidence -Evidence $evidence
    return $evidence
}

function Get-LabSqlObservabilityEvidence {
    [CmdletBinding()]
    param(
        [string]$HostName='127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][ValidateSet('docker','podman','hyperv','external')][string]$Provider,
        [AllowNull()][string]$RunId,
        [AllowNull()][string]$InstanceId
    )

    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try {$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)} finally {[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    try {
        $observation=Get-LabSqlObservabilityEvidenceSqlObservation -HostName $HostName -Port $Port -SaPlain $plain
        return New-LabSqlObservabilityEvidence -Observation $observation -Provider $Provider -RunId $RunId -InstanceId $InstanceId
    }
    finally {$plain=$null}
}