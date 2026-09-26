#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop';$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0;$module=$null
function New-TestSecureString([string]$Value){$secret=[securestring]::new();foreach($character in $Value.ToCharArray()){$secret.AppendChar($character)};$secret.MakeReadOnly();return $secret}
try {
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $principalMatches=& $module {
        $platform=if($IsWindows){'Windows'}elseif($IsLinux){'Linux'}else{'Unsupported'}
        $expected=Get-LabAiPlanKey ([ordered]@{Platform=$platform;Machine=[Environment]::MachineName;User=[Environment]::UserName})
        (Get-LabAiSharedGatewayServicePrincipalKey) -ceq $expected
    }
    Add-CheckResult 'Principalbindung behält den vorhandenen Plattform-, Host- und Benutzerhash bei' $principalMatches
    & $module { function script:Get-LabAiSharedGatewayServicePrincipalKey { 'f'*64 } }
    $consumers=@(
        [pscustomobject]@{RunId='11111111-1111-4111-8111-111111111111';InstanceId='primary';DatabaseId='22222222-2222-4222-8222-222222222222';ExternalModelName='ModelA';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_A'}
        [pscustomobject]@{RunId='33333333-3333-4333-8333-333333333333';InstanceId='secondary';DatabaseId='44444444-4444-4444-8444-444444444444';ExternalModelName='ModelB';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_B'}
    )
    $plan=Get-SqlServerLabAiSharedGatewayPlan -GatewayId shared-secret -Location 'https://localhost:18443/v1/embeddings' -UpstreamBackend LlamaCppCpu -UpstreamLocation 'http://127.0.0.1:18080/v1/embeddings' -RuntimeModel bound-model -Dimension 3 -ModelSha256 ('a'*64) -RuntimeSha256 ('b'*64) -ServerCertificateSha256 ('c'*64) -CertificateAuthoritySha256 ('d'*64) -Consumer $consumers
    $status=[pscustomobject]@{Status='REGISTERED_STOPPED';GatewayId=$plan.GatewayId;PlanKey=$plan.PlanKey;ReceiptKey=('e'*64)}
    $capability=& $module { $identity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayServiceCapability/1.0';Platform='Windows';ServiceMode='WINDOWS_S4U_TASK';PrincipalKey=('f'*64);VerifiedEvidence=@('LOCAL_STATE_ROOT','STATE_ROOT_NOT_EFS_ENCRYPTED','WINDOWS_SCHEDULED_TASKS_AVAILABLE');Blockers=@()};[pscustomobject]@{Contract=[pscustomobject]@{Name='SqlServerLab.AiSharedGatewayServiceCapability';Version='1.0'};Status='READY';Platform='Windows';ServiceMode='WINDOWS_S4U_TASK';PrincipalKey=('f'*64);VerifiedEvidence=$identity.VerifiedEvidence;Blockers=@();CapabilityKey=Get-LabAiPlanKey $identity}}
    $servicePlan=& $module {param($p,$s,$c)New-LabAiSharedGatewayServicePlan -Plan $p -GatewayStatus $s -HostCapability $c} $plan $status $capability
    $schema=Join-Path $repoRoot 'Schemas/ai-shared-gateway-service-secret-receipt.schema.json'
    $resolved=[Collections.Generic.List[string]]::new()
    $validSecret=New-TestSecureString ('A'*24)
    $receipt=& $module {param($p,$sp,$seen,$secret)$resolver={param($name)$seen.Add($name);$secret}.GetNewClosure();Test-LabAiSharedGatewayServiceSecret -Plan $p -ServicePlan $sp -SecretResolver $resolver} $plan $servicePlan $resolved $validSecret
    $resolvedReceipt=& $module {param($r,$p,$sp)Resolve-LabAiSharedGatewayServiceSecretReceipt -Receipt $r -Plan $p -ServicePlan $sp} $receipt $plan $servicePlan
    Add-CheckResult 'Dienst-Secret-Preflight bindet alle Consumer kurzlebig ohne Werte oder Referenznamen' ($resolvedReceipt.ReceiptKey -ceq $receipt.ReceiptKey -and ([datetimeoffset]$receipt.ExpiresAtUtc)-([datetimeoffset]$receipt.VerifiedAtUtc) -eq [timespan]::FromMinutes(5) -and $receipt.Status -ceq 'READY' -and $receipt.EvidenceStatus -ceq 'CURRENT_PRINCIPAL_SECRETS_RESOLVED' -and $receipt.PendingEvidence -contains 'NONINTERACTIVE_SERVICE_LOGON_SECRET_RESOLUTION' -and $receipt.ReferenceCount -eq 2 -and @($receipt.ReferenceKeys).Count -eq 2 -and @($resolved|Sort-Object) -join ',' -ceq 'SQL_SERVER_LAB_SECRET_SHARED_A,SQL_SERVER_LAB_SECRET_SHARED_B' -and ($receipt|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $schema) -and ($receipt|ConvertTo-Json -Depth 20) -notmatch 'SECRET_SHARED|AAAA')
    $tamperedReceipt=$receipt.PSObject.Copy();$tamperedReceipt.ReferenceCount=1
    $receiptTamperRejected=$false;try{& $module {param($r,$p,$sp)Resolve-LabAiSharedGatewayServiceSecretReceipt -Receipt $r -Plan $p -ServicePlan $sp} $tamperedReceipt $plan $servicePlan|Out-Null}catch{$receiptTamperRejected=$_.Exception.Message -match 'AI_SHARED_GATEWAY_SERVICE_SECRET_RECEIPT_INVALID'}
    Add-CheckResult 'Manipuliertes Secret-Receipt wird abgewiesen' $receiptTamperRejected
    & $module { function script:Get-LabAiSharedGatewayServicePrincipalKey { '0'*64 } }
    try {
        $foreignResolverCalled=$false;$foreignPlanRejected=$false
        try { & $module {param($p,$sp,[ref]$called,$secret)$resolver={param($name)$called.Value=$true;$secret}.GetNewClosure();Test-LabAiSharedGatewayServiceSecret -Plan $p -ServicePlan $sp -SecretResolver $resolver} $plan $servicePlan ([ref]$foreignResolverCalled) $validSecret | Out-Null }
        catch { $foreignPlanRejected=$_.Exception.Message -ceq 'AI_SHARED_GATEWAY_SERVICE_PRINCIPAL_MISMATCH' }
        Add-CheckResult 'Fremder Ausführungskontext blockiert vor dem ersten Vaultzugriff' ($foreignPlanRejected -and -not $foreignResolverCalled)
        $foreignReceiptRejected=$false
        try { & $module {param($r,$p,$sp)Resolve-LabAiSharedGatewayServiceSecretReceipt -Receipt $r -Plan $p -ServicePlan $sp} $receipt $plan $servicePlan | Out-Null }
        catch { $foreignReceiptRejected=$_.Exception.Message -ceq 'AI_SHARED_GATEWAY_SERVICE_PRINCIPAL_MISMATCH' }
        Add-CheckResult 'Gültiges Receipt wird in einem fremden Ausführungskontext nicht akzeptiert' $foreignReceiptRejected
    }
    finally { & $module { function script:Get-LabAiSharedGatewayServicePrincipalKey { 'f'*64 } } }
    $old=[datetime]::UtcNow.AddMinutes(-10);$expired=& $module {param($p,$sp,$time,$secret)$resolver={param($name)$secret}.GetNewClosure();Test-LabAiSharedGatewayServiceSecret -Plan $p -ServicePlan $sp -UtcNow $time -SecretResolver $resolver} $plan $servicePlan $old $validSecret
    $expiryRejected=$false;try{& $module {param($r,$p,$sp)Resolve-LabAiSharedGatewayServiceSecretReceipt -Receipt $r -Plan $p -ServicePlan $sp} $expired $plan $servicePlan|Out-Null}catch{$expiryRejected=$_.Exception.Message -match 'AI_SHARED_GATEWAY_SERVICE_SECRET_RECEIPT_EXPIRED'}
    Add-CheckResult 'Abgelaufenes Secret-Receipt wird getrennt abgewiesen' $expiryRejected
    $badType=$false;try{& $module {param($p,$sp)Test-LabAiSharedGatewayServiceSecret -Plan $p -ServicePlan $sp -SecretResolver {param($name)'plain-text'}} $plan $servicePlan|Out-Null}catch{$badType=$_.Exception.Message -match 'AI_SHARED_GATEWAY_SERVICE_SECRET_TYPE_UNSUPPORTED'}
    Add-CheckResult 'Nicht-SecureString aus SecretManagement wird getrennt abgewiesen' $badType
    $invalidSecret=New-TestSecureString 'too-short!'
    $badFormat=$false;try{& $module {param($p,$sp,$secret)$resolver={param($name)$secret}.GetNewClosure();Test-LabAiSharedGatewayServiceSecret -Plan $p -ServicePlan $sp -SecretResolver $resolver} $plan $servicePlan $invalidSecret|Out-Null}catch{$badFormat=$_.Exception.Message -match 'AI_SHARED_GATEWAY_SERVICE_SECRET_FORMAT_INVALID'}
    Add-CheckResult 'Ungeeignetes Gateway-Schlüsselformat wird ohne Wertausgabe abgewiesen' $badFormat
    $resolutionFailure=$false;try{& $module {param($p,$sp)Test-LabAiSharedGatewayServiceSecret -Plan $p -ServicePlan $sp -SecretResolver {param($name)throw 'vault detail'}} $plan $servicePlan|Out-Null}catch{$resolutionFailure=$_.Exception.Message -ceq 'AI_SHARED_GATEWAY_SERVICE_SECRET_RESOLUTION_FAILED'}
    Add-CheckResult 'Vaultfehler bleibt sanitisiert und stabil' $resolutionFailure
    $tampered=$servicePlan.PSObject.Copy();$tampered.VerifiedEvidence=@()
    $resolverCalled=$false;$tamperRejected=$false;try{& $module {param($p,$sp,[ref]$called)Test-LabAiSharedGatewayServiceSecret -Plan $p -ServicePlan $sp -SecretResolver {param($name)$called.Value=$true}} $plan $tampered ([ref]$resolverCalled)|Out-Null}catch{$tamperRejected=$_.Exception.Message -match 'AI_SHARED_GATEWAY_SERVICE_PLAN_INVALID'}
    Add-CheckResult 'Manipulierter Serviceplan blockiert vor Secretzugriff' ($tamperRejected -and -not $resolverCalled)
    $blockedStatus=[pscustomobject]@{Status='NOT_REGISTERED';GatewayId=$plan.GatewayId;PlanKey=$plan.PlanKey;ReceiptKey=('1'*64)}
    $blockedPlan=& $module {param($p,$s,$c)New-LabAiSharedGatewayServicePlan -Plan $p -GatewayStatus $s -HostCapability $c} $plan $blockedStatus $capability
    $blockedRejected=$false;try{& $module {param($p,$sp,$secret)$resolver={param($name)$secret}.GetNewClosure();Test-LabAiSharedGatewayServiceSecret -Plan $p -ServicePlan $sp -SecretResolver $resolver} $plan $blockedPlan $validSecret|Out-Null}catch{$blockedRejected=$_.Exception.Message -match 'AI_SHARED_GATEWAY_SERVICE_PLAN_BLOCKED'}
    Add-CheckResult 'Blockierter Serviceplan darf keine Secrets abfragen' $blockedRejected
    $blockedReceiptRejected=$false;try{& $module {param($r,$p,$sp)Resolve-LabAiSharedGatewayServiceSecretReceipt -Receipt $r -Plan $p -ServicePlan $sp} $receipt $plan $blockedPlan|Out-Null}catch{$blockedReceiptRejected=$_.Exception.Message -match 'AI_SHARED_GATEWAY_SERVICE_SECRET_RECEIPT_INVALID'}
    Add-CheckResult 'Secret-Receipt darf nicht an einen blockierten Serviceplan gebunden werden' $blockedReceiptRejected
    $previousGetSecret=if(Test-Path Function:global:Get-Secret){(Get-Item Function:global:Get-Secret).ScriptBlock}else{$null}
    $publicSecret=New-TestSecureString ('B'*24)
    Set-Item Function:global:Get-Secret -Value ({param([string]$Name)$publicSecret}.GetNewClosure())
    try{$public=$servicePlan|Test-SqlServerLabAiSharedGatewayServiceSecret -Plan $plan}finally{if($previousGetSecret){Set-Item Function:global:Get-Secret -Value $previousGetSecret}else{Remove-Item Function:global:Get-Secret -ErrorAction SilentlyContinue}}
    $command=Get-Command Test-SqlServerLabAiSharedGatewayServiceSecret
    Add-CheckResult 'Öffentlicher CLI-Befehl verwendet SecretManagement ohne Testadapter' ($public.Status -ceq 'READY' -and $command.ModuleName -ceq 'SqlServerLab' -and -not $command.Parameters.ContainsKey('SecretResolver'))
    $source=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/AiSharedGatewayServiceSecret.ps1') -Raw
    Add-CheckResult 'Dienstprüfung verwendet keine Prozessvariable als Neustartnachweis' ($source -notmatch 'GetEnvironmentVariable|Env:' -and $source -match 'Get-Secret')
}
finally {if($module){Remove-Module $module -Force -ErrorAction SilentlyContinue}}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI SHARED GATEWAY SERVICE SECRET: PASS ($passed)"
