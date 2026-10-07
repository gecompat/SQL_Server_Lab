param([Parameter(Mandatory)][PSModuleInfo]$Module,[Parameter(Mandatory)]$SqlPlan)
$ErrorActionPreference='Stop';$authorityPassed=0
function Check-Authority([string]$Name,[bool]$Success){if(-not $Success){throw ('AUTHORITY_CHECK_FAILED: '+$Name)};$script:authorityPassed++;Write-Host ('PASS '+$Name)}
$arguments=@{Backend='LlamaCppCuda';Accelerator='GPU';ExternalModelName='SyntheticEgress';RuntimeModel='bound-model';Dimension=3;ModelSha256=('a'*64);RuntimeSha256=('b'*64);ServerCertificateSha256=('c'*64)}
foreach($location in @('https://127.0.0.1/v1/embeddings','https://127.0.0.2/v1/embeddings','https://[::1]/v1/embeddings','https://localhost/v1/embeddings','https://LOCALHOST/v1/embeddings','https://host.docker.internal:11435/v1/embeddings','https://host.containers.internal:11435/v1/embeddings')){
 $p=Get-SqlServerLabAiExternalModelPlan @arguments -Location $location
 Check-Authority ('Lokaler Plan '+$location) ($p.Status -ceq 'NOT_PROBED')
}
foreach($location in @('https://egress-fixture.invalid/v1/embeddings','https://192.0.2.1/v1/embeddings','https://10.1.2.3/v1/embeddings','https://169.254.1.1/v1/embeddings','https://[2001:db8::1]/v1/embeddings','https://localhost.egress-fixture.invalid/v1/embeddings','https://host.docker.internal.egress-fixture.invalid/v1/embeddings','https://localhost./v1/embeddings','https://localhost@192.0.2.1/v1/embeddings')){
 $p=Get-SqlServerLabAiExternalModelPlan @arguments -Location $location
 Check-Authority ('Fremde Autoritaet blockiert '+$location) ($p.Status -ceq 'BLOCKED' -and 'AI_EXTERNAL_MODEL_LOCAL_AUTHORITY_REQUIRED' -in $p.Blockers)
}
$public=Get-SqlServerLabAiExternalModelPlan @arguments -Location 'https://egress-fixture.invalid/v1/embeddings'
$alias=Get-SqlServerLabAiExternalModelPlan @arguments -Location 'https://host.docker.internal:11435/v1/embeddings'
Check-Authority 'Vorher charakterisierter lokaler PlanKey bleibt unveraendert' ($alias.PlanKey -ceq 'c7ef480c3ed8ae0a540b3e04300b504238aca47099ba35a12bb78f660b6a3e57')
$public.Status='NOT_PROBED';$public.Blockers=@()
$probeCalls=[pscustomobject]@{Count=0};$transport={param($r)$null=$r;$probeCalls.Count++;throw 'UNREACHABLE'}.GetNewClosure()
$errorCode=$null;try{& $Module {param($p,$t)Invoke-LabAiExternalModelEndpointProbe -Plan $p -Transport $t} $public $transport|Out-Null}catch{$errorCode=$_.Exception.Message}
Check-Authority 'Manipulierter Plan wird vor injiziertem Transport revalidiert' ($errorCode -ceq 'AI_EXTERNAL_MODEL_PLAN_BLOCKED' -and $probeCalls.Count -eq 0)
$secret=[Security.SecureString]::new();1..24|ForEach-Object{$secret.AppendChar('s')};$secret.MakeReadOnly()
$uncreatedRoot=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))) ('.artifacts/test-runs/authority-uncreated-'+[guid]::NewGuid().ToString('N'))
try{
 $errorCode=$null
 # Ohne Guard scheitert TimeoutSeconds=0 vor SendAsync; keine externe Probe.
 try{& $Module {param($s)Invoke-LabAiExternalModelHttpTransport -Request @{Method='POST';TimeoutSeconds=0} -Location 'https://egress-fixture.invalid/v1/embeddings' -ExpectedServerCertificateSha256 ('c'*64) -ApiKey $s} $secret|Out-Null}catch{$errorCode=$_.Exception.Message}
 Check-Authority 'Direkter HTTP-Transport verwirft Ziel vor Client und Secret' ($errorCode -ceq 'AI_EXTERNAL_MODEL_LOCAL_AUTHORITY_REQUIRED')
 $partial=[pscustomobject]@{Location='https://egress-fixture.invalid/v1/embeddings'}
 foreach($operation in @('Preflight','Apply','Embedding')){
  $errorCode=$null
  try{& $Module {param($p,$s,$root,$op)
   $argsSql=@{SqlPlan=$p;RunId='11111111-1111-4111-8111-111111111111';StateRoot=$root}
   switch($op){
    'Preflight'{Invoke-LabAiExternalModelSqlPreflight @argsSql}
    'Apply'{Invoke-LabAiExternalModelSqlApply @argsSql -PreflightReceipt @{} -CredentialSecret $s}
    'Embedding'{Invoke-LabAiExternalModelSqlEmbeddingProbe @argsSql -ApplyReceipt @{}}
   }
  } $partial $secret $uncreatedRoot $operation|Out-Null}catch{$errorCode=$_.Exception.Message}
  Check-Authority ('SQL '+$operation+' verwirft Ziel vor State-/Bindingzugriff') ($errorCode -ceq 'AI_EXTERNAL_MODEL_LOCAL_AUTHORITY_REQUIRED' -and -not(Test-Path -LiteralPath $uncreatedRoot))
 }
}finally{$secret.Dispose()}
$legacy=$SqlPlan|ConvertTo-Json -Depth 12|ConvertFrom-Json
$legacy.ValidUntilUtc=[string]$SqlPlan.ValidUntilUtc
$legacy.Location='https://egress-fixture.invalid/v1/embeddings';$legacy.CredentialName='https://egress-fixture.invalid'
$legacy.SqlPlanKey=& $Module {param($p)
 Get-LabAiPlanKey -InputObject ([ordered]@{Contract='SqlServerLab.AiExternalModelSqlPlan/1.0';DatabaseName=[string]$p.DatabaseName;SqlMajorVersion=[int]$p.SqlMajorVersion;ExternalModelName=[string]$p.ExternalModelName;CredentialName=[string]$p.CredentialName;Location=[string]$p.Location;ApiFormat=[string]$p.ApiFormat;RuntimeModel=[string]$p.RuntimeModel;Dimension=[int]$p.Dimension;RetryCount=[int]$p.RetryCount;SourcePlanKey=[string]$p.SourcePlanKey;EndpointReceiptKey=[string]$p.EndpointReceiptKey;ValidUntilUtc=[string]$p.ValidUntilUtc})
} $legacy
$legacy.OwnershipTableName='SqlServerLabAiOwner_'+$legacy.SqlPlanKey.Substring(0,24)
$read=& $Module {param($p)Resolve-LabAiExternalModelSqlPlan -SqlPlan $p -AllowExpired} $legacy
Check-Authority 'Legacy SQL-Plan bleibt hashgebunden lesbar fuer Cleanup' ($read.SqlPlanKey -ceq $legacy.SqlPlanKey)
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'));$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Private/AiExternalModelAcceleration.ps1'),[ref]$tokens,[ref]$errors)
$apply=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-LabAiExternalModelSqlApply'},$true))[0].Body.Extent.Text
Check-Authority 'Jede Resume-Mutation prueft Ziel vor Secretkonvertierung' ($apply.IndexOf('Resolve-LabAiExternalModelLocalAuthority -Location ([string]$canonical.Location)') -gt $apply.IndexOf('return New-LabAiExternalModelSqlApplyReceipt') -and $apply.IndexOf('Resolve-LabAiExternalModelLocalAuthority -Location ([string]$canonical.Location)') -lt $apply.IndexOf('SecureStringToBSTR'))
Write-Host ('EXTERNAL_MODEL_AUTHORITY_CHECKS: '+$authorityPassed+' PASS; DNS/network/SQL/provider NOT_EXECUTED; own secret disposed; no state created')
$true
