#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop';$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0;$module=$null
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-shared-gateway-service-plan-'+[guid]::NewGuid().ToString('N'))
try {
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $consumer=@([pscustomobject]@{RunId='11111111-1111-4111-8111-111111111111';InstanceId='primary';DatabaseId='22222222-2222-4222-8222-222222222222';ExternalModelName='SharedModel';ApiKeyReference='SQL_SERVER_LAB_SECRET_SHARED_AI'})
    $plan=Get-SqlServerLabAiSharedGatewayPlan -GatewayId shared-service -Location 'https://localhost:18443/v1/embeddings' -UpstreamBackend LlamaCppCpu -UpstreamLocation 'http://127.0.0.1:18080/v1/embeddings' -RuntimeModel bound-model -Dimension 3 -ModelSha256 ('a'*64) -RuntimeSha256 ('b'*64) -ServerCertificateSha256 ('c'*64) -CertificateAuthoritySha256 ('d'*64) -Consumer $consumer
    $status=[pscustomobject]@{Status='REGISTERED_STOPPED';GatewayId=$plan.GatewayId;PlanKey=$plan.PlanKey;ReceiptKey=('e'*64)}
    $newCapability={param($platform,$mode,$principal,$verified,$blockers)& $module {param($platform,$mode,$principal,$verified,$blockers)$identity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayServiceCapability/1.0';Platform=$platform;ServiceMode=$mode;PrincipalKey=$principal;VerifiedEvidence=@($verified|Sort-Object -Unique);Blockers=@($blockers|Sort-Object -Unique)};[pscustomobject]@{Contract=[pscustomobject]@{Name='SqlServerLab.AiSharedGatewayServiceCapability';Version='1.0'};Status=if($identity.Blockers.Count){'BLOCKED'}else{'READY'};Platform=$platform;ServiceMode=$mode;PrincipalKey=$principal;VerifiedEvidence=$identity.VerifiedEvidence;Blockers=$identity.Blockers;CapabilityKey=Get-LabAiPlanKey $identity}} $platform $mode $principal $verified $blockers}
    $windowsCapability=& $newCapability 'Windows' 'WINDOWS_S4U_TASK' ('f'*64) @('WINDOWS_SCHEDULED_TASKS_AVAILABLE','LOCAL_STATE_ROOT','STATE_ROOT_NOT_EFS_ENCRYPTED') @()
    $linuxCapability=& $newCapability 'Linux' 'LINUX_SYSTEMD_USER' ('2'*64) @('SYSTEMD_USER_MANAGER_AVAILABLE','SYSTEMD_USER_LINGER_ENABLED') @()
    $schema=Join-Path $repoRoot 'Schemas/ai-shared-gateway-service-plan.schema.json'
    $windows=& $module {param($p,$s,$c)New-LabAiSharedGatewayServicePlan -Plan $p -GatewayStatus $s -HostCapability $c} $plan $status $windowsCapability
    Add-CheckResult 'Windows S4U-Plan bindet lokalen unverschlüsselten Benutzerzustand' ($windows.Status -ceq 'READY' -and $windows.ServiceMode -ceq 'WINDOWS_S4U_TASK' -and $windows.StartupScope -ceq 'CURRENT_USER_AT_BOOT' -and $windows.Warnings -contains 'WINDOWS_S4U_NO_NETWORK_OR_EFS_ACCESS' -and $windows.Warnings -contains 'WINDOWS_S4U_REGISTRATION_MAY_REQUIRE_ELEVATION' -and ($windows|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $schema))
    $windowsAgain=& $module {param($p,$s,$c)New-LabAiSharedGatewayServicePlan -Plan $p -GatewayStatus $s -HostCapability $c} $plan $status $windowsCapability
    Add-CheckResult 'Serviceplan bleibt bei identischer Evidence deterministisch' ($windows.PlanKey -ceq $windowsAgain.PlanKey)
    $linux=& $module {param($p,$s,$c)New-LabAiSharedGatewayServicePlan -Plan $p -GatewayStatus $s -HostCapability $c} $plan $status $linuxCapability
    Add-CheckResult 'Linux-Systemd-Plan verlangt Usermanager und Linger-Evidence' ($linux.Status -ceq 'READY' -and $linux.ServiceMode -ceq 'LINUX_SYSTEMD_USER' -and $linux.VerifiedEvidence -contains 'SYSTEMD_USER_LINGER_ENABLED' -and $linux.Warnings.Count -eq 0 -and ($linux|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $schema))
    $wrongMode=& $module {param($p,$s,$c)New-LabAiSharedGatewayServicePlan -Plan $p -GatewayStatus $s -HostCapability $c -ServiceMode SystemdUser} $plan $status $windowsCapability
    Add-CheckResult 'Explizit unpassende Dienstoption bleibt sichtbar blockiert' ($wrongMode.Status -ceq 'BLOCKED' -and $wrongMode.Blockers -contains 'AI_SHARED_GATEWAY_SERVICE_MODE_UNSUPPORTED')
    $missingStatus=[pscustomobject]@{Status='NOT_REGISTERED';GatewayId=$plan.GatewayId;PlanKey=$plan.PlanKey;ReceiptKey=('4'*64)}
    $missing=& $module {param($p,$s,$c)New-LabAiSharedGatewayServicePlan -Plan $p -GatewayStatus $s -HostCapability $c} $plan $missingStatus $windowsCapability
    Add-CheckResult 'Fehlende Registrierung wird mit handlungsfähigem Blocker erklärt' ($missing.Status -ceq 'BLOCKED' -and $missing.EvidenceStatus -ceq 'GATEWAY_STATE_BLOCKED' -and $missing.Blockers -contains 'AI_SHARED_GATEWAY_SERVICE_REGISTRATION_REQUIRED')
    $recoveryStatus=[pscustomobject]@{Status='RECOVERY_REQUIRED';GatewayId=$plan.GatewayId;PlanKey=$plan.PlanKey;ReceiptKey=('5'*64)}
    $recovery=& $module {param($p,$s,$c)New-LabAiSharedGatewayServicePlan -Plan $p -GatewayStatus $s -HostCapability $c} $plan $recoveryStatus $windowsCapability
    Add-CheckResult 'Gateway-Recoverybedarf blockiert Dienstplanung getrennt' ($recovery.Blockers -contains 'AI_SHARED_GATEWAY_SERVICE_STORAGE_RECOVERY_REQUIRED')
    $blockedCapability=& $newCapability 'Linux' 'LINUX_SYSTEMD_USER' ('6'*64) @('SYSTEMD_USER_MANAGER_AVAILABLE') @('AI_SHARED_GATEWAY_SERVICE_LINGER_REQUIRED')
    $blocked=& $module {param($p,$s,$c)New-LabAiSharedGatewayServicePlan -Plan $p -GatewayStatus $s -HostCapability $c} $plan $status $blockedCapability
    Add-CheckResult 'Fehlendes Linux-Linger bleibt als exakter Hostblocker erhalten' ($blocked.Status -ceq 'BLOCKED' -and $blocked.EvidenceStatus -ceq 'HOST_CAPABILITY_BLOCKED' -and $blocked.Blockers -contains 'AI_SHARED_GATEWAY_SERVICE_LINGER_REQUIRED')
    $tamperedCapability=$windowsCapability.PSObject.Copy();$tamperedCapability.VerifiedEvidence=@('WINDOWS_SCHEDULED_TASKS_AVAILABLE')
    $tamperRejected=$false;try{& $module {param($p,$s,$c)New-LabAiSharedGatewayServicePlan -Plan $p -GatewayStatus $s -HostCapability $c} $plan $status $tamperedCapability|Out-Null}catch{$tamperRejected=$_.Exception.Message -match 'AI_SHARED_GATEWAY_SERVICE_CAPABILITY_INVALID'}
    Add-CheckResult 'Manipulierte Host-Evidence wird vor der Planung abgewiesen' $tamperRejected
    $wrongPlatformCapability=& $newCapability 'Windows' 'LINUX_SYSTEMD_USER' ('8'*64) @() @()
    $wrongPlatformRejected=$false;try{& $module {param($p,$s,$c)New-LabAiSharedGatewayServicePlan -Plan $p -GatewayStatus $s -HostCapability $c} $plan $status $wrongPlatformCapability|Out-Null}catch{$wrongPlatformRejected=$_.Exception.Message -match 'AI_SHARED_GATEWAY_SERVICE_CAPABILITY_INVALID'}
    Add-CheckResult 'Plattform und Dienstmodus müssen semantisch zusammenpassen' $wrongPlatformRejected
    $public=$plan|Get-SqlServerLabAiSharedGatewayServicePlan -StateRoot $testRoot
    Add-CheckResult 'Öffentlicher read-only Plan mutiert fehlenden StateRoot nicht' ($public.Status -ceq 'BLOCKED' -and $public.Blockers -contains 'AI_SHARED_GATEWAY_SERVICE_REGISTRATION_REQUIRED' -and -not(Test-Path -LiteralPath $testRoot) -and ($public|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $schema))
    Add-CheckResult 'Öffentlicher Serviceplan ist manifestexportiert und fixierbar' ((Get-Command Get-SqlServerLabAiSharedGatewayServicePlan).ModuleName -ceq 'SqlServerLab' -and (Get-Command Get-SqlServerLabAiSharedGatewayServicePlan).Parameters['ServiceMode'].Attributes.ValidValues -contains 'WindowsS4U')
}
finally {if($module){Remove-Module $module -Force -ErrorAction SilentlyContinue};if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI SHARED GATEWAY SERVICE PLAN: PASS ($passed)"
