#Requires -Version 7.2
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification='Synthetic test key generated only for this isolated acceptance run; no real credential is embedded.')]
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $good="load_tensors: offloaded 13/13 layers to GPU`nCUDA0 compute buffer size = 21 MiB"
    $test={param($log,$backend,$accelerator) Test-LabLlamaCppAcceleratorLog -Log $log -Backend $backend -Accelerator $accelerator}
    Add-CheckResult 'CUDA verlangt vollständigen Offload und Compute-Puffer' (& $module $test $good LlamaCppCuda GPU)
    Add-CheckResult 'Teilweiser Offload wird abgewiesen' (-not (& $module $test ($good.Replace('13/13','12/13')) LlamaCppCuda GPU))
    Add-CheckResult 'Geräteinventar allein ist kein Ausführungsnachweis' (-not (& $module $test 'using device CUDA0' LlamaCppCuda GPU))
    Add-CheckResult 'Fallback wird trotz positiver Zeilen abgewiesen' (-not (& $module $test ($good+"`nfallback to CPU") LlamaCppCuda GPU))
    Add-CheckResult 'OpenVINO bindet exakt das angeforderte Gerät' (& $module $test "OpenVINO: using device NPU`nOPENVINO0`noffloaded 13/13 layers" LlamaCppOpenVino NPU)
    Add-CheckResult 'OpenVINO-GPU belegt keine NPU' (-not (& $module $test "OpenVINO: using device GPU`nOPENVINO0`noffloaded 13/13 layers" LlamaCppOpenVino NPU))
    Add-CheckResult 'Explizite CPU erfordert CPU-Compute ohne Gerätebuffer' (& $module $test 'CPU compute buffer size = 3 MiB' LlamaCppCuda CPU)
    Add-CheckResult 'CPU-Claim lehnt GPU-Modellbuffer ab' (-not (& $module $test "CPU compute buffer size = 3 MiB`nCUDA0 model buffer size = 7 MiB" LlamaCppCuda CPU))
    $key=ConvertTo-SecureString ('x'*24) -AsPlainText -Force
    try {
        $preview=@(Start-SqlServerLabLlamaCppRuntime -RuntimeDirectory missing -Backend LlamaCppCuda -Accelerator GPU -ModelPath missing -ModelName synthetic -Dimension 3 -Pooling mean -Port 19435 -CertificatePath missing -PrivateKeyPath missing -ApiKey $key -WhatIf)
        Add-CheckResult 'WhatIf führt keine Dateiprüfung oder Mutation aus' ($preview.Count -eq 0)
    } finally {$key.Dispose()}
    $code='';try{Stop-SqlServerLabLlamaCppRuntime -OperationId ([guid]::NewGuid().ToString('D'))}catch{$code=$_.Exception.Message}
    Add-CheckResult 'Fremde Operation wird ohne Prozesszugriff abgewiesen' ($code -eq 'LLAMA_OWNERSHIP_NOT_FOUND')
    Add-CheckResult 'Start verlangt keinen Hashparameter' (-not (Get-Command Start-SqlServerLabLlamaCppRuntime).Parameters.ContainsKey('RuntimeSha256') -and -not (Get-Command Start-SqlServerLabLlamaCppRuntime).Parameters.ContainsKey('ModelSha256'))
}
finally {Remove-Module $module -Force}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "LLAMA OWNED CONTRACT: PASS ($passed)"
