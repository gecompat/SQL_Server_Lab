#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$h='a'*64;$c='b'*64
try {
    $plan=Get-SqlServerLabAiExternalModelPlan -Backend LlamaCppOpenVino -Accelerator NPU -Location 'https://host.docker.internal:11435/v1/embeddings' -ExternalModelName LocalNpuEmbedding -RuntimeModel bound-model -Dimension 768 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c
    Add-CheckResult 'OpenVINO-NPU-Plan bleibt bis zur Live-Evidence NOT_PROBED' ($plan.Status -eq 'NOT_PROBED' -and $plan.EvidenceStatus -eq 'CONFIGURATION_ONLY' -and $plan.ApiFormat -eq 'OpenAI')
    Add-CheckResult 'Plan ist schema-valide und hashgebunden' (($plan|ConvertTo-Json -Depth 10|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-external-model-plan.schema.json')) -and $plan.PlanKey -match '^[a-f0-9]{64}$')
    Add-CheckResult 'Plan enthält keine Secretwerte oder Hostpfade' (($plan|ConvertTo-Json -Depth 10) -notmatch '(?i)(Bearer|secret|C:\\|/home/)')
    $ovms=Get-SqlServerLabAiExternalModelPlan -Backend OpenVinoModelServer -Accelerator NPU -Location 'https://localhost:8443/v3/embeddings' -ExternalModelName OvmsNpu -RuntimeModel model -Dimension 1024 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c
    Add-CheckResult 'OVMS verlangt den separaten TLS-Gateway' ($ovms.Status -eq 'BLOCKED' -and 'AI_EXTERNAL_MODEL_OVMS_GATEWAY_REQUIRED' -in $ovms.Blockers)
    $ovmsGateway=Get-SqlServerLabAiExternalModelPlan -Backend OpenVinoModelServer -Accelerator NPU -TlsMode Gateway -Location 'https://localhost:8443/v3/embeddings' -ExternalModelName OvmsNpu -RuntimeModel model -Dimension 1024 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c
    Add-CheckResult 'OVMS-Gateway ist korrekt gebunden, aber nicht als ausgeführt behauptet' ($ovmsGateway.Status -eq 'NOT_PROBED' -and $ovmsGateway.EndpointPath -eq '/v3/embeddings')
    $rocm=Get-SqlServerLabAiExternalModelPlan -Backend LlamaCppRocm -Accelerator NPU -Location 'https://localhost:11435/v1/embeddings' -ExternalModelName RocmNpu -RuntimeModel model -Dimension 768 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c
    Add-CheckResult 'ROCm wird nicht fälschlich als NPU-Nachweis behandelt' ($rocm.Status -eq 'BLOCKED' -and 'AI_EXTERNAL_MODEL_ACCELERATOR_UNSUPPORTED' -in $rocm.Blockers)
    $wrongPath=Get-SqlServerLabAiExternalModelPlan -Backend LlamaCppOpenVino -Accelerator NPU -Location 'https://localhost:11435/v3/embeddings' -ExternalModelName WrongPath -RuntimeModel model -Dimension 768 -ModelSha256 $h -RuntimeSha256 $h -ServerCertificateSha256 $c
    Add-CheckResult 'Backendfremder Embeddingpfad blockiert' ($wrongPath.Status -eq 'BLOCKED' -and 'AI_EXTERNAL_MODEL_ENDPOINT_PATH_MISMATCH' -in $wrongPath.Blockers)
    Add-CheckResult 'Beschleunigernachweis bleibt explizit offen' ('ACCELERATOR_RUNTIME_ATTESTATION' -in $plan.RequiredEvidence)
}
finally {Remove-Module $module -Force -ErrorAction SilentlyContinue}
Write-Host "`nAI external model acceleration checks: $passed passed, $($failures.Count) failed"
if($failures.Count){$failures|ForEach-Object{Write-Host " - $_" -ForegroundColor Red};exit 1}
