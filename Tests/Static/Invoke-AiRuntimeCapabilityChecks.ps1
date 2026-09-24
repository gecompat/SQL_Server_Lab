#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-runtime-'+[guid]::NewGuid().ToString('N'))
try {
    function Coverage($kind){[pscustomobject]@{Kind=$kind;Status='VERIFIED';Method=('TEST_'+$kind)}}
    function Device($kind,$source,$vendor,$product,$name){[pscustomobject]@{Kind=$kind;SourceId=$source;VendorId=$vendor;ProductId=$product;DisplayName=$name}}
    function Inventory($devices){$probe=[pscustomobject]@{Platform='Windows';Coverage=@((Coverage CPU),(Coverage GPU),(Coverage NPU));Devices=@($devices)};& $module {param($p)Get-LabAiComputeInventory -ProbeResult $p} $probe}
    function Reject([scriptblock]$action,[string]$pattern){try{& $action|Out-Null;$false}catch{$_.Exception.Message -like $pattern}}
    $inventory=Inventory @((Device CPU cpu0 8086 cpu 'Intel CPU'),(Device GPU gpu0 10de nvidia 'NVIDIA GPU'),(Device GPU gpu1 8086 intel 'Intel GPU'),(Device NPU npu0 8086 npu 'Intel NPU'))
    $package=Join-Path $fixture 'llama-b200-bin-combo';$copy=Join-Path $fixture 'llama-b200-bin-copy';$null=New-Item -ItemType Directory -Path $package,$copy -Force
    foreach($name in @('llama-server.exe','ggml-cuda.dll','ggml-vulkan.dll','ggml-openvino.dll','support.dll')){[IO.File]::WriteAllText((Join-Path $package $name),('synthetic-'+$name));Copy-Item -LiteralPath (Join-Path $package $name) -Destination (Join-Path $copy $name)}
    $runtime=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $package)[0]
    $set=Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime $runtime
    Add-CheckResult 'Mehrbackend-Paket leitet CPU, CUDA, Vulkan und drei OpenVINO-Lanes ab' ($set.Capabilities.Count -eq 6 -and @($set.Capabilities|Where-Object Backend -eq LlamaCppOpenVino).Count -eq 3)
    Add-CheckResult 'Herstellerbindung trennt NVIDIA-CUDA von Intel-GPU und Intel-NPU' (@($set.Capabilities|Where-Object {$_.Backend -eq 'LlamaCppCuda' -and $_.VendorIds[0] -eq '10de' -and $_.MaximumDeviceCount -eq 1}).Count -eq 1 -and @($set.Capabilities|Where-Object {$_.Backend -eq 'LlamaCppOpenVino' -and $_.DeviceKinds[0] -eq 'NPU' -and $_.VendorIds[0] -eq '8086'}).Count -eq 1)
    Add-CheckResult 'Capability-Receipt entspricht Schema und enthält keine lokalen Pfade' (($set|ConvertTo-Json -Depth 20|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-runtime-capability-set.schema.json')) -and ($set|ConvertTo-Json -Depth 20) -notmatch [regex]::Escape($fixture))
    $candidates=Get-SqlServerLabAiComputeCandidate -Inventory $inventory -RuntimeCapability $set.Capabilities
    Add-CheckResult 'Abgeleitete Lanes erzeugen CPU-, NPU-, Einzel- und Mehr-GPU-Kandidaten' ($candidates.Candidates.Count -eq 8 -and @($candidates.Candidates|Where-Object {$_.Backend -eq 'LlamaCppVulkan' -and $_.Devices.Count -eq 2}).Count -eq 1)
    $vulkan=@($candidates.Candidates|Where-Object {$_.Backend -eq 'LlamaCppVulkan' -and $_.Devices.Count -eq 2})[0]
    $pinned=Get-SqlServerLabAiComputeSelection -WorkloadKey sql-ai-generation -ModelSha256 ('a'*64) -BenchmarkProfileSha256 ('b'*64) -InventorySha256 $inventory.InventorySha256 -Candidate $candidates.Candidates -PinnedCandidateId $vulkan.CandidateId
    Add-CheckResult 'Explizite Fixierung akzeptiert eine abgeleitete Mehr-GPU-Vulkan-Lane' ($pinned.CandidateId -ceq $vulkan.CandidateId -and ($pinned|ConvertTo-Json -Depth 20|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-compute-selection.schema.json')))
    $copyRuntime=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $copy)[0]
    $deduplicated=Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime @($runtime,$copyRuntime)
    Add-CheckResult 'Bytegleiche Pakete an anderen Pfaden werden inhaltsgebunden dedupliziert' ($deduplicated.RuntimeCount -eq 1 -and $deduplicated.CapabilitySetSha256 -eq $set.CapabilitySetSha256)
    [IO.File]::AppendAllText((Join-Path $copy 'support.dll'),'changed')
    $changed=Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime $copyRuntime
    Add-CheckResult 'Änderung einer Support-Binärdatei ändert Runtime- und Capability-Hash' ($changed.Capabilities[0].RuntimeSha256 -ne $set.Capabilities[0].RuntimeSha256 -and $changed.CapabilitySetSha256 -ne $set.CapabilitySetSha256)
    $tampered=$runtime|ConvertTo-Json -Depth 10|ConvertFrom-Json;$tampered.Invocation=Join-Path $copy 'llama-server.exe'
    Add-CheckResult 'Invocation außerhalb des gebundenen Paketverzeichnisses wird abgewiesen' (Reject {Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime $tampered} 'AI_RUNTIME_ARTIFACT_INVALID')
    $hidden=$runtime|ConvertTo-Json -Depth 10|ConvertFrom-Json;$hidden.DetectedBackends=@($hidden.DetectedBackends|Where-Object {$_ -ne 'LlamaCppCuda'})
    Add-CheckResult 'Vorhandenes Backend darf im Runtime-Receipt nicht verschwiegen werden' (Reject {Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime $hidden} 'AI_RUNTIME_ARTIFACT_INVALID')
    $metadata=$runtime|ConvertTo-Json -Depth 10|ConvertFrom-Json;$metadata.Package='other-package'
    Add-CheckResult 'Widersprüchliche Paketmetadaten werden abgewiesen' (Reject {Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime $metadata} 'AI_RUNTIME_RECEIPT_INVALID')
    Remove-Item -LiteralPath (Join-Path $package 'ggml-cuda.dll')
    Add-CheckResult 'Fehlende deklarierte Backenddatei wird abgewiesen' (Reject {Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime $runtime} 'AI_RUNTIME_ARTIFACT_INVALID')
    $rocm=Join-Path $fixture 'llama-b201-bin-rocm';$null=New-Item -ItemType Directory -Path $rocm
    [IO.File]::WriteAllText((Join-Path $rocm 'llama-server'),'server');[IO.File]::WriteAllText((Join-Path $rocm 'libggml-hip.so.1'),'hip')
    $rocmRuntime=@(Get-SqlServerLabLlamaCppRuntime -SearchRoot $rocm)[0]
    $rocmSet=Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime $rocmRuntime
    Add-CheckResult 'Fehlendes AMD-Gerät bleibt als ungeeignete ROCm-Lane mit Blocker sichtbar' (@($rocmSet.Capabilities|Where-Object {$_.Backend -eq 'LlamaCppRocm' -and -not $_.Eligible -and $_.Blockers -contains 'AI_RUNTIME_COMPATIBLE_DEVICE_NOT_FOUND'}).Count -eq 1)
    $missingInvocation=$rocmRuntime|ConvertTo-Json -Depth 10|ConvertFrom-Json;$missingInvocation.Invocation=Join-Path $rocm 'missing-server'
    Add-CheckResult 'Fehlende Runtime-Datei liefert nur einen stabilen Fehlercode' (Reject {Get-SqlServerLabAiRuntimeCapability -Inventory $inventory -Runtime $missingInvocation} 'AI_RUNTIME_ARTIFACT_INVALID')
    Add-CheckResult 'Öffentlicher Capability-Befehl ist manifestexportiert' ((Get-Command Get-SqlServerLabAiRuntimeCapability).ModuleName -eq 'SqlServerLab')
}
finally {if((Split-Path $fixture -Parent) -eq [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar) -and (Split-Path $fixture -Leaf) -like 'sql-lab-ai-runtime-*'){Remove-Item -LiteralPath $fixture -Recurse -Force};Remove-Module $module -Force -ErrorAction SilentlyContinue}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI RUNTIME CAPABILITY CONTRACT: PASS ($passed)"
