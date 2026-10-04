#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-start-plan-'+[guid]::NewGuid().ToString('N'))
$passed=0;$failed=[Collections.Generic.List[string]]::new()
function Check([string]$Name,[bool]$Value){if($Value){$script:passed++;Write-Host "PASS $Name"}else{$script:failed.Add($Name);Write-Host "FAIL $Name"}}
function Reject([scriptblock]$Body,[string]$Code){try{& $Body|Out-Null;$false}catch{$_.Exception.Message -ceq $Code}}
$module=New-Module {
    param($root)
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Private/AiExternalModelAcceleration.ps1'),[ref]$tokens,[ref]$parseErrors)
    foreach($name in @('Get-LabLlamaCppRuntimeCandidate','Find-LabLlamaCppRuntime')) {
        $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    . (Join-Path $root 'Private/LlamaCppStartPlan.ps1')
    . (Join-Path $root 'Public/Get-SqlServerLabLlamaCppStartPlan.ps1')
    . (Join-Path $root 'Public/Start-SqlServerLabLlamaCppRuntime.ps1')
    $script:NativeCalls=0
    foreach($name in @('Start-LabLlamaCppOwnedRuntime','Resolve-LabLlamaCppComputeSelection','Get-LabAiComputeInventory','Invoke-LabAiBenchmarkProcess','Invoke-LabAiExternalModelHttpTransport','Get-LabDataRootDefault','Get-LabStateRoot','Get-LabSecret','Get-LabAiExternalModelFileSha256')) {
        Set-Item -Path "Function:script:$name" -Value {$script:NativeCalls++;throw 'FORBIDDEN_NATIVE_BOUNDARY'}
    }
} -ArgumentList $repoRoot
try {
    $null=New-Item -ItemType Directory -Path $fixture
    $runtime=Join-Path $fixture 'runtime';$null=New-Item -ItemType Directory -Path $runtime
    [IO.File]::WriteAllText((Join-Path $runtime 'llama-server.exe'),'synthetic-not-executable')
    [IO.File]::WriteAllText((Join-Path $runtime 'ggml-cuda.dll'),'synthetic')
    $model=Join-Path $fixture 'private-canary.gguf';[IO.File]::WriteAllBytes($model,[Text.Encoding]::ASCII.GetBytes('GGUFsynthetic'))
    $a=@{RuntimeDirectory=$runtime;Backend='LlamaCppCuda';Accelerator='CPU';ModelPath=$model;Dimension=768;Pooling='mean';Port=19435}
    $plan=& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $a
    Check 'Public → actual files-only reader produces distinct nonexecutable contract' ($plan.Contract.Name -ceq 'SqlServerLab.LlamaCppStartPlan' -and $plan.Contract.Version -ceq '1.0' -and $plan.Mode -ceq 'PLAN_ONLY' -and $plan.Status -ceq 'BLOCKED' -and $plan.Actions.Count -eq 0 -and -not $plan.ExecutionSupported -and -not $plan.MutationAllowed)
    foreach($field in @('DeviceReadiness','PortAvailability','EmbeddingReadiness','TlsReadiness','PrivateKeyMatch','SanTrust','SqlReadiness')){Check "$field stays NOT_CHECKED" ($plan.$field -ceq 'NOT_CHECKED')}
    Check 'Files and four-byte format are not embedding/compatibility proof' ($plan.RuntimeEvidence -ceq 'FILES_ONLY' -and $plan.ModelFormat -ceq 'GGUF' -and $plan.InputObservation -ceq 'METADATA_STABLE_NOT_CAS')
    $json=$plan|ConvertTo-Json -Depth 8
    Check 'DTO excludes paths, caller canary, plan keys and artifact digests' ($json -notmatch 'private-canary|llama-server|RuntimeDirectory|ModelPath|PlanKey|Sha256' -and -not $json.Contains($fixture))
    $lower=@{}+$a;$lower.Backend='llamacppcuda';$lower.Accelerator='cpu';$lower.Pooling='MEAN'
    $canonical=& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $lower
    Check 'Enums use canonical spelling' ($canonical.Backend -ceq 'LlamaCppCuda' -and $canonical.Accelerator -ceq 'CPU' -and $canonical.Pooling -ceq 'mean')
    $unsupported=@{}+$a;$unsupported.Accelerator='NPU'
    Check 'CUDA NPU denied before observation' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $unsupported} 'LLAMA_START_PLAN_ACCELERATOR_UNSUPPORTED')
    $badLease=@{}+$a;$badLease.LeaseSeconds=120
    Check 'Lease must exceed start timeout' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $badLease} 'LLAMA_START_PLAN_LEASE_INVALID')
    foreach($field in @('Dimension','Port','ContextSize','StartTimeoutSeconds','LeaseSeconds')) {
        $bad=@{}+$a;$bad[$field]=0
        $blocked=$false;try{& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $bad|Out-Null}catch{$blocked=$true}
        Check "Public scalar boundary $field" $blocked
    }
    foreach($field in @('ComputeSelection','Inventory','DeviceBinding','ModelName','ApiKey','PrivateKeyPath','CertificatePath','TrustedRootPath')) {
        Check "$field is not a plan parameter" (& $module {param($name)-not(Get-Command Get-SqlServerLabLlamaCppStartPlan).Parameters.ContainsKey($name)} $field)
    }
    [IO.File]::WriteAllText((Join-Path $runtime 'ggml-openvino.dll'),'synthetic')
    Check 'Ambiguous actual backend rejected' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $a} 'LLAMA_START_PLAN_RUNTIME_MISMATCH')
    Remove-Item -LiteralPath (Join-Path $runtime 'ggml-openvino.dll')
    Remove-Item -LiteralPath (Join-Path $runtime 'ggml-cuda.dll')
    Check 'CPU installer without supported backend is not compatible' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $a} 'LLAMA_START_PLAN_RUNTIME_MISMATCH')
    [IO.File]::WriteAllText((Join-Path $runtime 'ggml-cuda.dll'),'synthetic')
    [IO.File]::WriteAllBytes($model,[byte[]]@(71,71,85))
    Check 'Short model rejected' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $a} 'LLAMA_START_PLAN_GGUF_REQUIRED')
    [IO.File]::WriteAllBytes($model,[byte[]]@())
    Check 'Empty model rejected before stream opening' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $a} 'LLAMA_START_PLAN_GGUF_REQUIRED')
    [IO.File]::WriteAllText($model,'NOPEprivate-canary')
    Check 'Bad magic rejected' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $a} 'LLAMA_START_PLAN_GGUF_REQUIRED')
    $stream=[IO.File]::OpenWrite($model);try{$stream.Write([Text.Encoding]::ASCII.GetBytes('GGUF'));$stream.SetLength(4194304)}finally{$stream.Dispose()}
    Check 'Large regular model uses header-only observation' ((& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $a).ModelFormat -ceq 'GGUF')
    $absent=@{}+$a;$absent.ModelPath=Join-Path $fixture 'raw-private-canary-absent'
    Check 'Unreadable caller path gives fixed safe code' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $absent} 'LLAMA_START_PLAN_INPUT_UNREADABLE')
    $relative=@{}+$a;$relative.RuntimeDirectory='private-canary'
    Check 'Relative paths never read ambient roots' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $relative} 'LLAMA_START_PLAN_PATH_INVALID')
    $broad=Join-Path $fixture 'broad';$null=New-Item -ItemType Directory -Path $broad
    1..17|ForEach-Object{$null=New-Item -ItemType Directory -Path (Join-Path $broad "d$_")}
    $bad=@{}+$a;$bad.RuntimeDirectory=$broad
    Check '17 directories denied before discovery' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $bad} 'LLAMA_START_PLAN_DIRECTORY_LIMIT')
    $crowd=Join-Path $fixture 'crowd';$null=New-Item -ItemType Directory -Path $crowd
    1..257|ForEach-Object{[IO.File]::WriteAllText((Join-Path $crowd "f$_"),'x')}
    $bad=@{}+$a;$bad.RuntimeDirectory=$crowd
    Check '257 files denied before discovery' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $bad} 'LLAMA_START_PLAN_FILE_LIMIT')
    $link=Join-Path $fixture 'link';$kind=if($IsWindows){'Junction'}else{'SymbolicLink'}
    $null=New-Item -ItemType $kind -Path $link -Target $runtime
    $bad=@{}+$a;$bad.RuntimeDirectory=$link
    Check 'Reparse installation rejected' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $bad} 'LLAMA_START_PLAN_REPARSE_REJECTED')
    Remove-Item -LiteralPath $link -Force
    $link=Join-Path $runtime 'linked-child';$null=New-Item -ItemType $kind -Path $link -Target $crowd
    Check 'Reparse neighboring candidate rejected before Find' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $a} 'LLAMA_START_PLAN_REPARSE_REJECTED')
    Remove-Item -LiteralPath $link -Force
    $link=Join-Path $fixture 'model-parent-link';$null=New-Item -ItemType $kind -Path $link -Target $fixture
    $bad=@{}+$a;$bad.ModelPath=Join-Path $link 'private-canary.gguf'
    Check 'Model ancestor reparse rejected' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $bad} 'LLAMA_START_PLAN_REPARSE_REJECTED')
    Remove-Item -LiteralPath $link -Force
    $neighbor=Join-Path $runtime 'neighbor';$null=New-Item -ItemType Directory -Path $neighbor
    [IO.File]::WriteAllText((Join-Path $neighbor 'llama-server.exe'),'synthetic');[IO.File]::WriteAllText((Join-Path $neighbor 'ggml-openvino.dll'),'synthetic')
    Check 'Neighbor backend not adopted into explicit installation' ((& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $a).Backend -ceq 'LlamaCppCuda')
    $readSource=[IO.File]::ReadAllText((Join-Path $repoRoot 'Private/LlamaCppStartPlan.ps1'))
    Check 'Model reader explicitly reads four bytes without full hash' ($readSource.Contains('$stream.Read($magic,0,4)') -and $readSource -notmatch 'Get-FileHash|ComputeHash|ReadAllBytes|ReadAllText')
    & $module {$script:originalFind=(Get-Command Find-LabLlamaCppRuntime).ScriptBlock;function script:Find-LabLlamaCppRuntime {param($SearchRoot)$items=@(& $script:originalFind -SearchRoot $SearchRoot);[IO.File]::AppendAllText((Join-Path $SearchRoot[0] 'ggml-cuda.dll'),'changed');$items}}
    Check 'Actual discovery followed by metadata drift fails closed' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $a} 'LLAMA_START_PLAN_INPUT_DRIFT')
    & $module {Set-Item Function:script:Find-LabLlamaCppRuntime $script:originalFind}
    & $module {param($modelFile)$script:modelFile=$modelFile;function script:Find-LabLlamaCppRuntime {param($SearchRoot)$items=@(& $script:originalFind -SearchRoot $SearchRoot);[IO.File]::AppendAllText($script:modelFile,'drift');$items}} $model
    Check 'Model drift between actual reader observations rejected' (Reject {& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap} $a} 'LLAMA_START_PLAN_INPUT_DRIFT')
    & $module {Set-Item Function:script:Find-LabLlamaCppRuntime $script:originalFind}
    Check 'Common Verbose flag never alters private parameter contract' ((& $module {param($argsMap)Get-SqlServerLabLlamaCppStartPlan @argsMap -Verbose} $a).Mode -ceq 'PLAN_ONLY')
    $fullStart=@{}+$a;$fullStart.ModelName='local';$fullStart.CertificatePath='unread-cert';$fullStart.PrivateKeyPath='unread-key';$fullStart.ApiKey=[Security.SecureString]::new()
    & $module {param($argsMap)Start-SqlServerLabLlamaCppRuntime @argsMap -WhatIf} $fullStart|Out-Null
    Check 'Existing Start WhatIf unchanged and no native/secret/default calls' (& $module {$script:NativeCalls -eq 0})
    Check 'Start does not accept plan objects as execution grant' (& $module {-not(Get-Command Start-SqlServerLabLlamaCppRuntime).Parameters.ContainsKey('Plan')})
} finally {
    if ((Split-Path $fixture -Parent) -cne [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar) -or (Split-Path $fixture -Leaf) -cnotlike 'sql-lab-start-plan-*') {throw 'FIXTURE_CLEANUP_SCOPE_UNKNOWN'}
    if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
    Remove-Module $module -ErrorAction SilentlyContinue
}
Write-Host "LLAMA START PLAN: PASS $passed FAIL $($failed.Count), CLEANUP_SUCCEEDED"
if($failed.Count){throw 'LLAMA_START_PLAN_CHECKS_FAILED'}
