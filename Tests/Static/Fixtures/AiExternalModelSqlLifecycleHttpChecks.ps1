# Synthetic request and job boundary checks; no SQL, network, or provider processes.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $RepositoryRoot 'Tools/WorkflowUiCommandGrants.ps1')
. (Join-Path $RepositoryRoot 'Tools/WorkflowUiJsonBody.ps1')
. (Join-Path $RepositoryRoot 'Tools/WorkflowUiExternalModelSql.ps1')

function Assert-Lifecycle([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Receive-Job {
    param($Job,[switch]$Keep)
    $Job.Records
}

function Start-UiWorkflowJob {
    param($Action,$Parameters)
    $fixture.Count++
    $fixture.Action = $Action
    $fixture.Parameters = $Parameters
    if ($fixture.FailStart) { throw 'SYNTHETIC_PRIVATE_START_FAILURE' }
    [pscustomobject]@{
        Id=if ($Action -ceq 'ReadExternalModelSqlEmbedding') { 'f'*32 } else { 'e'*32 };Action=$Action;ExternalModelSqlBinding=$binding;ExternalModelSqlMutationSubmitted=$false
        Job=[pscustomobject]@{State='Running';Records=@()}
    }
}

function Write-UiResponse {
    param($Context,$Body,$ContentType,$StatusCode,[switch]$NoStore)
    [pscustomobject]@{StatusCode=$StatusCode;Body=$Body;NoStore=$NoStore.IsPresent}
}

function Invoke-LifecycleRoute {
    param([string]$Stage,[string]$Body,[string]$Origin=$url.TrimEnd('/'))
    $path = '/api/ai-external-model/sql-' + $Stage
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $stream = [IO.MemoryStream]::new($bytes)
    try {
        $context = [pscustomobject]@{Request=[pscustomobject]@{
            HttpMethod='POST';Url=[uri]($url.TrimEnd('/')+$path);ContentType='application/json'
            Headers=@{Origin=$Origin};ContentLength64=[long]$bytes.Length;InputStream=$stream
        }}
        & $handler
        $fixture.BytesRead = $stream.Position
    } finally { $stream.Dispose() }
}

$fixture=[pscustomobject]@{Count=0;Action='';Parameters=$null;FailStart=$false;BytesRead=-1}
$binding=@{SqlPlan=[pscustomobject]@{SqlPlanKey=('d'*64);DatabaseName='AiLab'};RunId='11111111-2222-4333-8444-555555555555';InstanceId='primary'}
$receipt=[pscustomobject]@{
    Status='SQL_PREFLIGHT_VERIFIED';SqlPlanKey=$binding.SqlPlan.SqlPlanKey;DatabaseName='AiLab'
    RunId=$binding.RunId;InstanceId=$binding.InstanceId
}
$source=[pscustomobject]@{
    Id=('a'*32);Action='ReadExternalModelSqlPreflight';ExternalModelSqlBinding=$binding;ExternalModelSqlMutationSubmitted=$false
    Job=[pscustomobject]@{State='Completed';Records=@([pscustomobject]@{UiExternalModelSqlReceipt=$receipt})}
}
$jobs=@{$source.Id=$source}
$url='http://127.0.0.1:8484/'
$server=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepositoryRoot 'Tools/Start-SqlServerLabUi.ps1'),[ref]$null,[ref]$null)
$route=$server.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -ceq '$path -cmatch ''^/api/ai-external-model/sql-(apply|embedding|cleanup)$'''
},$true)
$handler=[scriptblock]::Create('foreach ($once in @(1)) { if ($path -cmatch ''^/api/ai-external-model/sql-(apply|embedding|cleanup)$'') '+$route.Clauses[0].Item2.Extent.Text+' }')
$apply=@{SourceJobId=$source.Id;Confirmed=$true;CredentialSecret='SYNTHETIC_FIXTURE_INPUT'}
$body=$apply|ConvertTo-Json -Compress

$result=Invoke-LifecycleRoute apply $body 'http://127.0.0.1:8485'
Assert-Lifecycle ($result.StatusCode -eq 400 -and $result.NoStore -and $fixture.BytesRead -eq 0 -and $fixture.Count -eq 0) 'Foreign origin read the body or queued work'
$result=Invoke-LifecycleRoute apply ($body.Replace('true','false'))
Assert-Lifecycle ($result.StatusCode -eq 400 -and $fixture.Count -eq 0) 'Missing confirmation admitted'
$result=Invoke-LifecycleRoute apply ('{"Confirmed":true,' + $body.Substring(1))
Assert-Lifecycle ($result.StatusCode -eq 400 -and $fixture.Count -eq 0) 'Duplicate field admitted'
$result=Invoke-LifecycleRoute apply ($body.Replace($source.Id,('b'*32)))
Assert-Lifecycle ($result.StatusCode -eq 409 -and $fixture.Count -eq 0) 'Unknown source admitted'
$result=Invoke-LifecycleRoute apply ('{"RunId":"foreign",' + $body.Substring(1))
Assert-Lifecycle ($result.StatusCode -eq 400 -and $fixture.Count -eq 0) 'Caller-supplied run accepted'
$source.Job.State='Running'
$result=Invoke-LifecycleRoute apply $body
Assert-Lifecycle ($result.StatusCode -eq 409 -and $fixture.Count -eq 0) 'Running preflight enabled Apply'
$source.Job.State='Completed'
$receipt.InstanceId='foreign'
$result=Invoke-LifecycleRoute apply $body
Assert-Lifecycle ($result.StatusCode -eq 409 -and $fixture.Count -eq 0) 'Receipt with changed instance admitted'
$receipt.InstanceId=$binding.InstanceId

try {
    $result=Invoke-LifecycleRoute apply $body
    Assert-Lifecycle ($result.StatusCode -eq 202 -and $result.NoStore -and $fixture.Count -eq 1 -and
        $fixture.Action -ceq 'ApplyExternalModelSql' -and $fixture.Parameters.CredentialSecret -is [SecureString] -and
        [object]::ReferenceEquals($fixture.Parameters.PreflightReceipt,$receipt) -and
        $fixture.Parameters.RunId -ceq $binding.RunId -and $result.Body -cnotmatch 'SYNTHETIC_FIXTURE_INPUT') 'Apply was not bound to exactly one completed preflight'
    $result=Invoke-LifecycleRoute apply $body
    Assert-Lifecycle ($result.StatusCode -eq 409 -and $fixture.Count -eq 1) 'Apply source was reusable'
} finally { $fixture.Parameters.CredentialSecret.Dispose() }

$applied=$jobs['e'*32]
$after=@{SourceJobId=$applied.Id;Confirmed=$true}|ConvertTo-Json -Compress
$result=Invoke-LifecycleRoute embedding $after
Assert-Lifecycle ($result.StatusCode -eq 409 -and $fixture.Count -eq 1) 'Embedding admitted without completed Apply'
$applied.Job.State='Completed'
$appliedReceipt=$receipt.PSObject.Copy()
$appliedReceipt.Status='SQL_EXTERNAL_MODEL_APPLIED'
$applied.Job.Records=@([pscustomobject]@{UiExternalModelSqlReceipt=$appliedReceipt})
$result=Invoke-LifecycleRoute embedding $after
Assert-Lifecycle ($result.StatusCode -eq 202 -and $fixture.Action -ceq 'ReadExternalModelSqlEmbedding' -and
    [object]::ReferenceEquals($fixture.Parameters.ApplyReceipt,$appliedReceipt) -and
    -not $fixture.Parameters.ContainsKey('CredentialSecret')) 'Embedding did not use only the retained Apply receipt'
$result=Invoke-LifecycleRoute cleanup $after
Assert-Lifecycle ($result.StatusCode -eq 409 -and $fixture.Count -eq 2 -and -not $applied.ExternalModelSqlMutationSubmitted) 'Cleanup overlapped an active SQL job'
$jobs['f'*32].Job.State='Completed'
$fixture.FailStart=$true
$result=Invoke-LifecycleRoute cleanup $after
Assert-Lifecycle ($result.StatusCode -eq 400 -and $result.NoStore -and $result.Body -cnotmatch 'SYNTHETIC_PRIVATE' -and
    $fixture.Action -ceq 'RemoveExternalModelSql' -and $applied.ExternalModelSqlMutationSubmitted) 'Uncertain Cleanup lost the consumption marker or returned raw details'
$result=Invoke-LifecycleRoute cleanup $after
Assert-Lifecycle ($result.StatusCode -eq 409 -and $fixture.Count -eq 3) 'Uncertain Cleanup could be repeated'
$guard=$server.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item2.Extent.Text.Contains('AI_EXTERNAL_MODEL_SQL_BROWSER_DIRECT_ENDPOINT_REQUIRED') -and
    $node.Clauses[0].Item1.Extent.Text.StartsWith('$action -in ')
},$true)
$rejection=[scriptblock]::Create($guard.Extent.Text)
foreach($action in 'ApplyExternalModelSql','readexternalmodelSqlembedding','RemoveExternalModelSql'){
    $denied=$false
    try { & $rejection } catch { $denied=$_.Exception.Message -ceq 'AI_EXTERNAL_MODEL_SQL_BROWSER_DIRECT_ENDPOINT_REQUIRED' }
    Assert-Lifecycle $denied 'General workflow endpoint can accept a dedicated SQL lifecycle action'
}
$snapshot=$server.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-UiJobSnapshot'
},$true)
. ([scriptblock]::Create($snapshot.Extent.Text))
$now=[datetime]::UtcNow.ToString('o')
$JobLogBurstLimit=300
$record=[pscustomobject]@{
    Id=$applied.Id;Action=$applied.Action;StartedAt=$now;LastActivityAt=$now;LastObservedLineCount=0
    ExternalModelSqlMutationSubmitted=$false
    Job=[pscustomobject]@{State='Running';Records=@([pscustomobject]@{UiExternalModelSqlReceipt=$appliedReceipt})}
}
$view=Get-UiJobSnapshot -Record $record
Assert-Lifecycle (-not $view.PSObject.Properties['ExternalModelSqlReceipt']) 'Running job exposed a follow-up'
$record.Job.State='Completed'
$view=Get-UiJobSnapshot -Record $record
Assert-Lifecycle (-not $view.Lines.Count -and $view.ExternalModelSqlReceipt.Status -ceq 'SQL_EXTERNAL_MODEL_APPLIED') 'A fresh job poll lost the typed receipt'
$record.ExternalModelSqlMutationSubmitted=$true
$view=Get-UiJobSnapshot -Record $record
Assert-Lifecycle ($view.ExternalModelSqlMutationSubmitted -and $view.ExternalModelSqlReceipt.InstanceId -ceq $binding.InstanceId) 'A fresh job poll lost the consumed marker'
$record.Job.State='Failed'
$view=Get-UiJobSnapshot -Record $record
Assert-Lifecycle (-not $view.PSObject.Properties['ExternalModelSqlReceipt']) 'Failed job exposed a follow-up'
'GUIDED EXTERNAL MODEL SQL HTTP: PASS (20 synthetic boundary cases)'
