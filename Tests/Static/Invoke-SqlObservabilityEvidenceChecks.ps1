#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$results=[Collections.Generic.List[object]]::new()
function Add-CheckResult { param([string]$Name,[bool]$Success) $results.Add([PSCustomObject]@{Name=$Name;Success=$Success});Write-Host "$(if($Success){'PASS'}else{'FAIL'}): $Name" -ForegroundColor $(if($Success){'Green'}else{'Red'}) }

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $result=& $module {
        $script:capturedQuery=$null
        Set-Item Function:script:Invoke-SqlQuery -Value {
            param($Query)
            $script:capturedQuery=[string]$Query
            @('OBS100_SERVER|17|4|8192','OBS100_DATABASE|3|16384|2','OBS100_WAIT|5|7|11')
        }
        $password=[SecureString]::new()
        foreach($character in 'ephemeral-test-value'.ToCharArray()){$password.AppendChar($character)}
        $password.MakeReadOnly()
        $direct=Get-SqlServerLabSqlObservabilityEvidence -HostName 127.0.0.1 -Port 14330 -Provider external -SaPassword $password
        Set-Item Function:script:Resolve-LabRunInstance -Value {
            [PSCustomObject]@{HostName='192.0.2.10';Port=1433;Provider='hyperv';ContainerName='';VMName='SQLLAB-OBS100';Version='2025'}
        }
        $run=Get-SqlServerLabSqlObservabilityEvidence -RunId '11111111-1111-1111-1111-111111111111' -InstanceId primary -SaPassword $password
        $missing=$false
        Set-Item Function:script:Invoke-SqlQuery -Value { @('OBS100_SERVER|17|4|8192','OBS100_DATABASE|3|16384|2') }
        try { $null=Get-LabSqlObservabilityEvidenceSqlObservation -Port 14330 -SaPlain 'ephemeral-test-value' } catch { $missing=$_.Exception.Message -match 'RESULT_MISSING' }
        [PSCustomObject]@{Direct=$direct;Run=$run;Missing=$missing;Query=$script:capturedQuery}
    }
    Add-CheckResult 'Read-only Evidence enthält aggregierte Server-, Datenbank-, Query-Store- und Wait-Metriken' (
        $result.Direct.Server.CpuCount -eq 4 -and $result.Direct.Databases.QueryStoreEnabledCount -eq 2 -and
        $result.Direct.WaitStatistics.WaitTimeMs -eq 11)
    Add-CheckResult 'Direkte Evidence projiziert weder Endpoint noch Secret oder SQL-Text' (
        $result.Direct.Source.Provider -eq 'external' -and -not $result.Direct.Source.RunId -and -not $result.Direct.Source.InstanceId -and
        (($result.Direct|ConvertTo-Json -Depth 20) -notmatch '127\.0\.0\.1|14330|ephemeral-test-value|OBS100_'))
    Add-CheckResult 'Run-/Instanzbindung bleibt stabil und ohne aufgelöste Hostwerte' (
        $result.Run.Source.Provider -eq 'hyperv' -and $result.Run.Source.RunId -eq '11111111-1111-1111-1111-111111111111' -and
        $result.Run.Source.InstanceId -eq 'primary' -and (($result.Run|ConvertTo-Json -Depth 20) -notmatch '192\.0\.2\.10|1433|SQLLAB-OBS100'))
    Add-CheckResult 'Evidence erfüllt den versionierten JSON-Schema-Vertrag' (
        (($result.Run|ConvertTo-Json -Depth 20)|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/sql-observability-evidence.schema.json') -ErrorAction SilentlyContinue))
    Add-CheckResult 'Unvollständige SQL-Antwort wird fail-closed abgelehnt' $result.Missing
    Add-CheckResult 'SQL-Erhebung enthält ausschließlich aggregierte read-only SELECT-Metadatenzugriffe' (
        $result.Query -match 'sys\.dm_os_sys_info' -and $result.Query -match 'sys\.dm_os_wait_stats' -and $result.Query -match 'is_query_store_on' -and
        $result.Query -notmatch '(?im)^\s*(INSERT|UPDATE|DELETE|MERGE|BACKUP|RESTORE|CREATE|ALTER|DROP|EXEC(?:UTE)?)\b')
}
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue }

$failed=@($results|Where-Object{-not $_.Success})
if($failed.Count -gt 0){throw "SQL OBSERVABILITY EVIDENCE CHECKS FAILED: $($failed.Name -join '; ')"}
Write-Host "SQL OBSERVABILITY EVIDENCE CHECKS: PASS ($($results.Count))" -ForegroundColor Green