#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop';$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    function Reject([scriptblock]$Action,[string]$Code){try{& $Action|Out-Null;$false}catch{$_.Exception.Message -ceq $Code}}
    $h='a'*64;$caHash='b'*64;$c1=[pscustomobject]@{RunId='11111111-1111-4111-8111-111111111111';InstanceId='primary';DatabaseId='22222222-2222-4222-8222-222222222222';ExternalModelName='SharedEmbedding';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_AI_A'}
    $c2=[pscustomobject]@{RunId='33333333-3333-4333-8333-333333333333';InstanceId='secondary';DatabaseId='44444444-4444-4444-8444-444444444444';ExternalModelName='SharedEmbedding2';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_AI_B'}
    $planArgs=@{GatewayId='shared-ai';Location='https://host.docker.internal:18443/v1/embeddings';UpstreamBackend='LlamaCppCuda';UpstreamLocation='http://127.0.0.1:18080/v1/embeddings';RuntimeModel='bound-model';Dimension=768;InputProfile='nomic-search';ModelSha256=$h;RuntimeSha256=$h;ServerCertificateSha256=$h;CertificateAuthoritySha256=$caHash;Consumer=@($c2,$c1)}
    $plan=Get-SqlServerLabAiSharedGatewayPlan @planArgs
    Add-CheckResult 'Plan ist geheimnisfrei, blockiert und schema-valide' ($plan.Status -ceq 'BLOCKED' -and $plan.EvidenceStatus -ceq 'CONFIGURATION_ONLY' -and ($plan|ConvertTo-Json -Depth 12|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-shared-gateway-plan.schema.json')))
    $reordered=@{}+$planArgs;$reordered.Consumer=@($c1,$c2);$reorderedPlan=Get-SqlServerLabAiSharedGatewayPlan @reordered
    Add-CheckResult 'Verbraucherreihenfolge ist kanonisch und ändert PlanKey nicht' ($plan.Consumers[0].RunId -ceq $c1.RunId -and $reorderedPlan.PlanKey -ceq $plan.PlanKey)
    Add-CheckResult 'Plan bindet nur Verbraucherreferenzen, lokalen Endpunkt und Inhaltsdigests' ($plan.Consumers[0].ApiKeyReference -ceq 'SQL_SERVER_LAB_SECRET_SHARED_AI_A' -and $plan.Location -ceq 'https://host.docker.internal:18443/v1/embeddings' -and $plan.PSObject.Properties.Name -notcontains 'ApiKey')
    $publicLocation=@{}+$planArgs;$publicLocation.Location='https://example.com:18443/v1/embeddings'
    Add-CheckResult 'Öffentliches Gatewayziel wird abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @publicLocation} 'AI_SHARED_GATEWAY_LOCATION_INVALID')
    $remote=@{}+$planArgs;$remote.UpstreamLocation='https://example.com/v1/embeddings'
    Add-CheckResult 'Nicht-Loopback-Upstream wird abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @remote} 'AI_SHARED_GATEWAY_UPSTREAM_INVALID')
    $wrongPath=@{}+$planArgs;$wrongPath.UpstreamBackend='OpenVinoModelServer'
    Add-CheckResult 'Falscher Backendpfad wird abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @wrongPath} 'AI_SHARED_GATEWAY_UPSTREAM_INVALID')
    $sameCertificate=@{}+$planArgs;$sameCertificate.CertificateAuthoritySha256=$sameCertificate.ServerCertificateSha256
    Add-CheckResult 'Identische CA- und Serverzertifikathashes werden abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @sameCertificate} 'AI_SHARED_GATEWAY_CERTIFICATE_HASHES_MUST_DIFFER')
    $duplicate=@{}+$planArgs;$duplicate.Consumer=@($c1,$c1)
    Add-CheckResult 'Doppelter Verbraucher wird abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @duplicate} 'AI_SHARED_GATEWAY_CONSUMER_DUPLICATE')
    $sameSecret=$c2|Select-Object *;$sameSecret.ApiKeyReference=$c1.ApiKeyReference
    $duplicateSecret=@{}+$planArgs;$duplicateSecret.Consumer=@($c1,$sameSecret)
    Add-CheckResult 'Geteilte Verbraucher-Secretreferenz wird abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @duplicateSecret} 'AI_SHARED_GATEWAY_SECRET_REFERENCE_DUPLICATE')
    $extra=$c1|Select-Object *,@{n='HostName';e={'private-host'}}
    $withHost=@{}+$planArgs;$withHost.Consumer=@($extra)
    Add-CheckResult 'Zusätzliche Hostdaten im Verbraucher werden abgewiesen' (Reject {Get-SqlServerLabAiSharedGatewayPlan @withHost} 'AI_SHARED_GATEWAY_CONSUMER_INVALID')
    Add-CheckResult 'Öffentlicher Befehl ist manifestexportiert' ((Get-Command Get-SqlServerLabAiSharedGatewayPlan).ModuleName -ceq 'SqlServerLab')
}
finally {Remove-Module $module -Force -ErrorAction SilentlyContinue}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI SHARED GATEWAY PLAN: PASS ($passed)"
