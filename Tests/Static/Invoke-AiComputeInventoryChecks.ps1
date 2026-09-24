#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    function Coverage($kind,$status='VERIFIED',$method=('TEST_'+$kind)){[pscustomobject]@{Kind=$kind;Status=$status;Method=$method}}
    function Device($kind,$source,$vendor,$product,$name){[pscustomobject]@{Kind=$kind;SourceId=$source;VendorId=$vendor;ProductId=$product;DisplayName=$name}}
    function Probe($devices,$coverage=@((Coverage CPU),(Coverage GPU),(Coverage NPU))){[pscustomobject]@{Platform='Windows';Coverage=@($coverage);Devices=@($devices)}}
    function Inventory($probe){& $module {param($p)Get-LabAiComputeInventory -ProbeResult $p} $probe}
    function Capability($backend,$runtime,$kinds,$vendors,$min,$max,$mixed=$false,$eligible=$true,$blockers=@()){[pscustomobject]@{Backend=$backend;RuntimeSha256=$runtime;DeviceKinds=@($kinds);VendorIds=@($vendors);MinimumDeviceCount=$min;MaximumDeviceCount=$max;AllowMixedKinds=$mixed;Eligible=$eligible;Blockers=@($blockers)}}
    function Reject([scriptblock]$action,[string]$pattern){try{& $action|Out-Null;$false}catch{$_.Exception.Message -like $pattern}}
    $devices=@((Device CPU cpu0 8086 meteor-lake 'Intel Core Ultra'),(Device GPU pci2 10de 2c58 'NVIDIA RTX'),(Device NPU pnp3 8086 7d1d 'Intel AI Boost'),(Device GPU pci1 10de 2c58 'NVIDIA RTX'))
    $inventory=Inventory (Probe $devices)
    Add-CheckResult 'Vollständige CPU-/NPU-/Mehr-GPU-Coverage erhält einen Inventarhash' ($inventory.Status -ceq 'COMPLETE' -and $inventory.InventorySha256 -match '^[a-f0-9]{64}$' -and $inventory.Devices.Count -eq 4)
    Add-CheckResult 'Identische GPUs bleiben mit stabilen Ordinalen getrennt' (@($inventory.Devices|Where-Object Kind -eq GPU|ForEach-Object DeviceId) -join ',' -ceq 'gpu:10de:2c58:0,gpu:10de:2c58:1')
    Add-CheckResult 'Receipt entspricht Schema' (($inventory|ConvertTo-Json -Depth 20)|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-compute-inventory.schema.json'))
    Add-CheckResult 'Ausgabe enthält keine rohen PnP- oder Busidentitäten' (($inventory|ConvertTo-Json -Depth 20) -notmatch 'pci1|pci2|pnp3|SourceId')
    $reordered=Inventory (Probe @($devices[3],$devices[2],$devices[0],$devices[1]))
    Add-CheckResult 'Probe-Reihenfolge ändert Inventarhash und Geräte-IDs nicht' ($reordered.InventorySha256 -ceq $inventory.InventorySha256 -and (($reordered.Devices.DeviceId -join ',') -ceq ($inventory.Devices.DeviceId -join ',')))
    $incomplete=Inventory (Probe @($devices[0],$devices[1]) @((Coverage CPU),(Coverage GPU),(Coverage NPU UNAVAILABLE)))
    Add-CheckResult 'Fehlende NPU-Coverage fällt geschlossen ohne Inventarhash aus' ($incomplete.Status -ceq 'INCOMPLETE' -and $null -eq $incomplete.InventorySha256 -and 'AI_COMPUTE_INVENTORY_NPU_UNAVAILABLE' -in $incomplete.Blockers)
    $noCpu=Inventory (Probe @($devices[1]) @((Coverage CPU),(Coverage GPU),(Coverage NPU)))
    Add-CheckResult 'Fehlende CPU bleibt trotz erfolgreicher Probe unvollständig' ($noCpu.Status -ceq 'INCOMPLETE' -and 'AI_COMPUTE_INVENTORY_CPU_MISSING' -in $noCpu.Blockers)
    $duplicateSource=Probe @($devices[0],(Device GPU CPU0 10de 2c58 duplicate))
    Add-CheckResult 'Doppelte Quellidentität wird unabhängig von Großschreibung abgewiesen' (Reject {Inventory $duplicateSource} 'AI_COMPUTE_INVENTORY_DEVICE_INVALID')
    $duplicateCoverage=Probe @($devices[0]) @((Coverage CPU),(Coverage CPU),(Coverage NPU))
    Add-CheckResult 'Doppelte Coverage-Art wird abgewiesen' (Reject {Inventory $duplicateCoverage} 'AI_COMPUTE_INVENTORY_COVERAGE_INVALID')
    $extra=(Probe @($devices[0])|ConvertTo-Json -Depth 10|ConvertFrom-Json);$extra.Devices[0]|Add-Member SecretPath 'C:\private'
    Add-CheckResult 'Unbekanntes Gerätefeld wird abgewiesen' (Reject {Inventory $extra} 'AI_COMPUTE_INVENTORY_DEVICE_INVALID')
    Add-CheckResult 'Öffentlicher Inventarbefehl ist manifestexportiert' ((Get-Command Get-SqlServerLabAiComputeInventory).Source -ceq 'SqlServerLab')
    $cuda=Capability LlamaCppCuda ('1'*64) @('GPU') @('10de') 1 2
    $mixed=Capability Ollama ('2'*64) @('CPU','GPU') @('*') 2 3 $true
    $candidateSet=Get-SqlServerLabAiComputeCandidate -Inventory $inventory -RuntimeCapability @($mixed,$cuda)
    Add-CheckResult 'Alle erlaubten Einzel-, Mehr-GPU- und gemischten Teilmengen werden erzeugt' ($candidateSet.Candidates.Count -eq 7 -and @($candidateSet.Candidates|Where-Object {$_.Backend -eq 'LlamaCppCuda' -and $_.Devices.Count -eq 2}).Count -eq 1 -and @($candidateSet.Candidates|Where-Object {$_.Backend -eq 'Ollama' -and 'CPU' -in $_.Devices.Kind -and 'GPU' -in $_.Devices.Kind}).Count -eq 3)
    Add-CheckResult 'Kandidatenreceipt entspricht Schema' (($candidateSet|ConvertTo-Json -Depth 20)|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/ai-compute-candidate-set.schema.json'))
    $reorderedCapabilities=Get-SqlServerLabAiComputeCandidate -Inventory $reordered -RuntimeCapability @($cuda,$mixed)
    Add-CheckResult 'Inventar- und Runtime-Reihenfolge ändern CandidateSetSha256 nicht' ($candidateSet.CandidateSetSha256 -ceq $reorderedCapabilities.CandidateSetSha256)
    Add-CheckResult 'Unvollständiges Inventar erzeugt keine Kandidaten' (Reject {Get-SqlServerLabAiComputeCandidate -Inventory $incomplete -RuntimeCapability $cuda} 'AI_COMPUTE_INVENTORY_INCOMPLETE')
    $tampered=$inventory|ConvertTo-Json -Depth 20|ConvertFrom-Json;$tampered.Devices[0].ProductId='tampered'
    Add-CheckResult 'Manipuliertes Inventar wird vor Kandidatenbildung abgewiesen' (Reject {Get-SqlServerLabAiComputeCandidate -Inventory $tampered -RuntimeCapability $cuda} 'AI_COMPUTE_INVENTORY_RECEIPT_INVALID')
    $mixedVendorInventory=Inventory (Probe @($devices[0],$devices[1],$devices[2],(Device GPU pci4 8086 7d67 'Intel Graphics')))
    $vendorFiltered=Get-SqlServerLabAiComputeCandidate -Inventory $mixedVendorInventory -RuntimeCapability $cuda
    Add-CheckResult 'CUDA-Kandidaten enthalten nur NVIDIA-GPUs' (@($vendorFiltered.Candidates).Count -eq 1 -and @($vendorFiltered.Candidates[0].Devices|Where-Object {$_.DeviceId -notlike 'gpu:10de:*'}).Count -eq 0)
    $wildcardMixed=Capability Ollama ('6'*64) @('GPU') @('*','10de') 1 1
    Add-CheckResult 'Wildcard-Hersteller darf nicht mit Einzelherstellern gemischt werden' (Reject {Get-SqlServerLabAiComputeCandidate -Inventory $inventory -RuntimeCapability $wildcardMixed} 'AI_COMPUTE_RUNTIME_CAPABILITY_INVALID')
    $tamperedCoverage=$inventory|ConvertTo-Json -Depth 20|ConvertFrom-Json;$tamperedCoverage.Coverage[0]|Add-Member ExtraField nope
    Add-CheckResult 'Zusätzliche Coverage-Felder werden abgewiesen' (Reject {Get-SqlServerLabAiComputeCandidate -Inventory $tamperedCoverage -RuntimeCapability $cuda} 'AI_COMPUTE_INVENTORY_RECEIPT_INVALID')
    $sevenGpu=@(1..7|ForEach-Object {Device GPU "pci$_" 10de 2c58 "GPU $_"});$largeDevices=@((Device CPU cpu0 8086 x cpu))+$sevenGpu;$largeInventory=Inventory (Probe $largeDevices)
    $tooMany=Capability LlamaCppCuda ('3'*64) @('GPU') @('10de') 1 7
    Add-CheckResult 'Mehr als 64 Kombinationen werden nicht still abgeschnitten' (Reject {Get-SqlServerLabAiComputeCandidate -Inventory $largeInventory -RuntimeCapability $tooMany} 'AI_COMPUTE_CANDIDATE_SET_TOO_LARGE')
    $npuOnly=Capability LlamaCppOpenVino ('4'*64) @('NPU') @('8086') 1 1
    $withoutNpu=Inventory (Probe @($devices[0],$devices[1]))
    Add-CheckResult 'Geeignete Runtime ohne passendes Gerät fällt geschlossen aus' (Reject {Get-SqlServerLabAiComputeCandidate -Inventory $withoutNpu -RuntimeCapability $npuOnly} 'AI_COMPUTE_RUNTIME_CAPABILITY_WITHOUT_DEVICE*')
    $blocked=Capability LlamaCppRocm ('5'*64) @('GPU') @('10de') 1 1 $false $false @('AI_RUNTIME_NOT_VERIFIED')
    $blockedSet=Get-SqlServerLabAiComputeCandidate -Inventory $inventory -RuntimeCapability $blocked
    Add-CheckResult 'Ungeeignete Runtimekombinationen bleiben mit Blocker sichtbar' (-not $blockedSet.Candidates[0].Eligible -and 'AI_RUNTIME_NOT_VERIFIED' -in $blockedSet.Candidates[0].Blockers)
    Add-CheckResult 'Öffentlicher Kandidatenbefehl ist manifestexportiert' ((Get-Command Get-SqlServerLabAiComputeCandidate).Source -ceq 'SqlServerLab')
}
finally {Remove-Module $module -Force}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "AI COMPUTE INVENTORY CONTRACT: PASS ($passed)"
