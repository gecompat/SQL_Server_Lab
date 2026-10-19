$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../../Integration/Invoke-SqlFeatureAcceptance.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$null)
$function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Wait-FeatureSql'},$true)
if(-not $function){throw 'SQL_FEATURE_READINESS_FIXTURE_FUNCTION_MISSING'}
. ([scriptblock]::Create($function.Extent.Text))
$Provider='hyperv';$lab=[pscustomobject]@{RunId='synthetic-run'};$StateRoot='synthetic-state';$database='FeatureSynthetic'
$module={param([scriptblock]$Action,$Run,$State,$DatabaseName)& $Action $Run $State $DatabaseName}
$script:reads=0;$script:observations=0;$script:waits=0;$script:failures=2
function Get-LabSqlFeatureContext {param($RunId,$InstanceId,$StateRoot)[pscustomobject]@{RunId=$RunId;InstanceId=$InstanceId;StateRoot=$StateRoot}}
function Get-LabSqlFeatureObservation {param($Context)$script:observations++;[pscustomobject]@{FullText=1;FileStream=1;Build='17.0.1000.7';RunId=$Context.RunId}}
function Start-Sleep {param($Seconds)if($Seconds -ne 2){throw 'SQL_FEATURE_READINESS_FIXTURE_WAIT_INVALID'};$script:waits++}
function Invoke-LabSqlFeatureSql {
    param($Context,$Query)
    if($Context.RunId -cne 'synthetic-run' -or $Query -cne "USE [FeatureSynthetic];SELECT CONVERT(nvarchar(60),DATABASEPROPERTYEX(DB_NAME(),'Status')) AS DatabaseStatus;"){throw 'SQL_FEATURE_READINESS_FIXTURE_EXPECTED_READ_ONLY_DATABASE_OPEN'}
    $script:reads++
    if($script:reads -le $script:failures){throw 'SYNTHETIC_DATABASE_AUTOSTART_DURING_SERVER_STARTUP'}
    [pscustomobject]@{DatabaseStatus='ONLINE'}
}
Wait-FeatureSql
if($script:reads -ne 3 -or $script:observations -ne 3 -or $script:waits -ne 2){throw 'SQL_FEATURE_READINESS_FIXTURE_SERVER_READY_IS_NOT_DATABASE_READY'}
$Provider='docker';Wait-FeatureSql
if($script:reads -ne 3){throw 'SQL_FEATURE_READINESS_FIXTURE_UNRELATED_PROVIDER_PROBED'}
$Provider='hyperv';$script:reads=0;$script:failures=1;$script:waits=0;$rejected=$false
try{Wait-FeatureSql -TimeoutSeconds 0}catch{$rejected=$_.Exception.Message -ceq 'SYNTHETIC_DATABASE_AUTOSTART_DURING_SERVER_STARTUP'}
if(-not $rejected -or $script:reads -ne 1 -or $script:waits){throw 'SQL_FEATURE_READINESS_FIXTURE_DEADLINE_NOT_ENFORCED'}
Write-Host 'SQL FEATURE DATABASE READINESS: PASS (startup race, read-only retry, deadline, provider isolation)'
