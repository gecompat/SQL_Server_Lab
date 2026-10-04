# Actual guided handler -> public core -> files-only reader, with console/host leaves isolated.
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)
$ErrorActionPreference='Stop'
$passed=0;$failed=[Collections.Generic.List[string]]::new()
function Test-Case([string]$Name,[bool]$Condition){if($Condition){$script:passed++;Write-Host "PASS $Name"}else{$script:failed.Add($Name);Write-Host "FAIL $Name"}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-start-plan-cli-'+[guid]::NewGuid().ToString('N'))
$module=New-Module {
    param($root)
    function Read-ActualFunction([string]$Path,[string]$Name) {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $Path),[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'FIXTURE_SOURCE_PARSE'}
        $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true)
        if(-not $fn){throw 'FIXTURE_FUNCTION_MISSING'}
        $fn.Extent.Text
    }
    foreach($name in @('Find-LabLlamaCppRuntime','Get-LabLlamaCppRuntimeCandidate')){. ([scriptblock]::Create((Read-ActualFunction 'Private/AiExternalModelAcceleration.ps1' $name)))}
    . (Join-Path $root 'Private/LlamaCppStartPlan.ps1')
    . (Join-Path $root 'Public/Get-SqlServerLabLlamaCppStartPlan.ps1')
    . (Join-Path $root 'Private/LlamaCppStartPlanConsole.ps1')
    . ([scriptblock]::Create((Read-ActualFunction 'Private/PublicCommandConsole.ps1' 'Manage-LabPublicCommandsInteractive')))
    $script:actualObservation=(Get-Command Get-LabLlamaStartPlanObservation).ScriptBlock
    function Get-LabLlamaStartPlanObservation {
        param($RuntimeDirectory,$ModelPath)
        $script:ObservationCalls++
        if($script:ResultChange -ceq 'DRIFT' -and $script:ObservationCalls -eq 2){[IO.File]::WriteAllText($ModelPath,'GGUFchanged-metadata')}
        & $script:actualObservation @PSBoundParameters
    }
    $script:actualPublic=(Get-Command Get-SqlServerLabLlamaCppStartPlan).ScriptBlock
    $script:actualText=[scriptblock]::Create((Read-ActualFunction 'Private/ConsoleUi.ps1' 'Read-LabConsoleTextInput').Replace('function Read-LabConsoleTextInput','function Read-FixtureActualText'))
    . $script:actualText
    function Get-SqlServerLabLlamaCppStartPlan {
        param($RuntimeDirectory,$ModelPath,$Backend,$Accelerator,$Dimension,$Pooling,$Port,$StartTimeoutSeconds,$LeaseSeconds,$ContextSize)
        $script:PublicCalls++;$script:Received=@{}+$PSBoundParameters
        $result=& $script:actualPublic @PSBoundParameters
        switch($script:ResultChange){
            'EXEC' {$result.ExecutionSupported=$true}
            'PATH' {$result|Add-Member -NotePropertyName HostPath -NotePropertyValue 'PRIVATE_CANARY'}
            'BOOLSTRING' {$result.MutationAllowed='false'}
            'STATUS' {$result.Status='READY'}
            'RAWERROR' {throw 'PRIVATE_CANARY'}
        }
        $result
    }
    function New-LabConsoleItem {param($Id,$Label,$Value,$Data) [pscustomobject]@{Id=$Id;Label=$Label;Value=$Value;Data=$Data}}
    function Invoke-LabConsoleMenu {
        param($ScreenId,$Title,$Subtitle,$Items)
        $script:Steps++
        if($script:Steps -eq $script:CancelAt){return [pscustomobject]@{Status='Cancelled';SelectedItem=$null}}
        if($ScreenId -ceq 'public-command-menu'){
            $script:MenuCount++
            if($script:MenuCount -gt 1){return [pscustomobject]@{Status='Cancelled';SelectedItem=$null}}
            $script:MenuIds=@($Items.Id)
            return [pscustomobject]@{Status='Selected';SelectedItem=[pscustomobject]@{Id='llama-start-plan-preview';Data='FORBIDDEN_DATA'}}
        }
        $id=if($ScreenId -ceq 'llama-start-plan-preview'){$script:PreviewId}else{$script:Choices.Dequeue()}
        [pscustomobject]@{Status='Selected';SelectedItem=[pscustomobject]@{Id=$id;Data='FORBIDDEN_DATA'}}
    }
    function Read-LabConsoleTextInput {
        param($Prompt,$Default,[switch]$MaskInput)
        $script:Steps++;$script:Masks.Add([bool]$MaskInput)
        if($script:Steps -eq $script:CancelAt){return [pscustomobject]@{Status='Cancelled';Value=$null}}
        $script:NextText=$script:Inputs.Dequeue()
        Read-FixtureActualText -Prompt $Prompt -Default $Default -MaskInput:$MaskInput -Capability ([pscustomobject]@{Supported=$false}) -ReadInput {param($promptText)$script:FallbackPrompts.Add($promptText); ,$script:NextText}
    }
    function Write-LabInfo {param($Message)$script:Output.Add([string]$Message)}
    function Write-LabWarning {param($Message)$script:Output.Add([string]$Message);$script:Warnings++}
    function Wait-LabConsoleAcknowledgement {}
    function Get-LabPublicCommandConsoleCatalog {@()}
    $script:NativeCalls=0
    foreach($name in @('Start-SqlServerLabLlamaCppRuntime','Stop-SqlServerLabLlamaCppRuntime','Start-LabLlamaCppOwnedRuntime','Get-LabAiComputeInventory','Resolve-LabLlamaCppComputeSelection','Invoke-LabAiExternalModelHttpTransport','Get-LabDataRootDefault','Get-LabStateRoot','Get-LabSecret','Initialize-LabHostToolPath','Invoke-LabPublicCommandInteractive','Invoke-LabComponentRelationPlanInteractive')){
        Set-Item -Path "Function:script:$name" -Value {$script:NativeCalls++;throw 'FORBIDDEN_BOUNDARY'}
    }
    function Reset-Fixture {
        param($Runtime,$Model,[int]$Cancel=0,[string]$Change='',[string]$Preview='preview',[string]$Backend='LlamaCppCuda',[string]$Accelerator='CPU',[string[]]$Numbers=@('768','19435',' ',' ',' '))
        $script:ObservationCalls=0;$script:Steps=0;$script:CancelAt=$Cancel;$script:ResultChange=$Change;$script:PreviewId=$Preview;$script:PublicCalls=0;$script:MenuCount=0;$script:Warnings=0;$script:Received=$null
        $script:Choices=[Collections.Generic.Queue[string]]::new();foreach($v in @($Backend,$Accelerator,'mean')){$script:Choices.Enqueue($v)}
        $script:Inputs=[Collections.Generic.Queue[string]]::new();foreach($v in @($Runtime,$Model)+$Numbers){$script:Inputs.Enqueue($v)}
        $script:Output=[Collections.Generic.List[string]]::new();$script:Masks=[Collections.Generic.List[bool]]::new();$script:FallbackPrompts=[Collections.Generic.List[string]]::new()
    }
    function Invoke-FixtureCase {param($Values,[switch]$Menu)
        Reset-Fixture @Values
        if($Menu){Manage-LabPublicCommandsInteractive}else{Invoke-LabLlamaCppStartPlanInteractive}
        [pscustomobject]@{Calls=$script:PublicCalls;Steps=$script:Steps;Warnings=$script:Warnings;Output=($script:Output -join "`n");Arguments=$script:Received;Masks=$script:Masks.ToArray();Prompts=$script:FallbackPrompts.ToArray();MenuIds=$script:MenuIds;Native=$script:NativeCalls}
    }
} -ArgumentList $RepoRoot
try {
    [IO.Directory]::CreateDirectory($fixture)|Out-Null
    $runtime=Join-Path $fixture 'runtime';[IO.Directory]::CreateDirectory($runtime)|Out-Null
    [IO.File]::WriteAllText((Join-Path $runtime 'llama-server.exe'),'synthetic-not-executable')
    [IO.File]::WriteAllText((Join-Path $runtime 'ggml-cuda.dll'),'synthetic')
    $model=Join-Path $fixture 'PRIVATE_CANARY.gguf';[IO.File]::WriteAllText($model,'GGUFsynthetic')
    $a=@{Runtime=$runtime;Model=$model}
    $ok=& $module {param($v)Invoke-FixtureCase $v} $a
    Test-Case 'Actual handler -> Public -> actual Find/Candidate produces fixed preview' ($ok.Calls -eq 1 -and $ok.Warnings -eq 0 -and $ok.Output.Contains('PLAN_ONLY/BLOCKED') -and $ok.Output.Contains('SQL: NOT_CHECKED'))
    Test-Case 'Exact ten scalar arguments and declared defaults' ($ok.Arguments.Count -eq 10 -and $ok.Arguments.StartTimeoutSeconds -eq 120 -and $ok.Arguments.LeaseSeconds -eq 900 -and $ok.Arguments.ContextSize -eq 512)
    Test-Case 'Paths masked at actual text leaf and never projected' ($ok.Masks[0] -and $ok.Masks[1] -and $ok.Prompts[0].Contains('Ctrl+C') -and -not $ok.Output.Contains($fixture) -and -not $ok.Output.Contains('PRIVATE_CANARY'))
    Test-Case 'Actual PublicCommand menu dispatch ignores arbitrary item Data' ((& $module {param($v)Invoke-FixtureCase $v -Menu} $a).Calls -eq 1)
    foreach($step in 1..11){$v=@{}+$a;$v.Cancel=$step;$x=& $module {param($v)Invoke-FixtureCase $v} $v;Test-Case "Cancel at input/choice/preview step $step never calls plan" ($x.Calls -eq 0 -and $x.Native -eq 0)}
    foreach($id in @('back','PRIVATE_CANARY')){$v=@{}+$a;$v.Preview=$id;$x=& $module {param($v)Invoke-FixtureCase $v} $v;Test-Case "Preview id $id never dispatches" ($x.Calls -eq 0)}
    foreach($change in @('EXEC','PATH','BOOLSTRING','STATUS','RAWERROR')){$v=@{}+$a;$v.Change=$change;$x=& $module {param($v)Invoke-FixtureCase $v} $v;Test-Case "Untrusted result/error $change is fixed and nonreflecting" ($x.Warnings -eq 1 -and -not $x.Output.Contains('PRIVATE_CANARY') -and -not $x.Output.Contains('Actions: 0'))}
    foreach($backend in @('PRIVATE_CANARY','llamacppcuda')){$v=@{}+$a;$v.Backend=$backend;$x=& $module {param($v)Invoke-FixtureCase $v} $v;Test-Case 'Unknown/casechanged menu ID rejected before plan' ($x.Calls -eq 0 -and $x.Warnings -eq 1)}
    $v=@{}+$a;$v.Accelerator='NPU';$x=& $module {param($v)Invoke-FixtureCase $v} $v;Test-Case 'CUDA NPU fails before observation' ($x.Calls -eq 0 -and $x.Warnings -eq 1)
    foreach($numbers in @(@('1999','19435',' ',' ',' '),@('768','65536',' ',' ',' '),@('768','19435','601',' ',' '),@('768','19435','120','120',' '),@('768','19435',' ',' ','8193'),@('1e2','19435',' ',' ',' '))){$v=@{}+$a;$v.Numbers=$numbers;$x=& $module {param($v)Invoke-FixtureCase $v} $v;Test-Case 'Invalid numeric/lease input never calls core' ($x.Calls -eq 0)}
    $v=@{}+$a;$v.Change='DRIFT';$x=& $module {param($v)Invoke-FixtureCase $v} $v
    Test-Case 'Actual second observation drift gives fixed CLI refusal' ($x.Calls -eq 1 -and $x.Warnings -eq 1 -and $x.Output.Contains('Dateimetadaten'))
    [IO.File]::WriteAllText($model,'GGUFsynthetic')
    $v=@{}+$a;$v.Model='0';$x=& $module {param($v)Invoke-FixtureCase $v} $v
    Test-Case 'Masked fallback zero is input, not cancellation; core rejects relative path' ($x.Calls -eq 1 -and $x.Warnings -eq 1)
    [IO.File]::WriteAllText($model,'NOPEPRIVATE_CANARY')
    $x=& $module {param($v)Invoke-FixtureCase $v} $a;Test-Case 'Actual GGUF rejection is safely displayed' ($x.Calls -eq 1 -and $x.Warnings -eq 1 -and -not $x.Output.Contains('PRIVATE_CANARY'))
    [IO.File]::WriteAllText($model,'GGUFsynthetic')
    $link=Join-Path $fixture 'link';$kind=if($IsWindows){'Junction'}else{'SymbolicLink'}
    $null=New-Item -ItemType $kind -Path $link -Target $runtime
    $v=@{}+$a;$v.Runtime=$link;$x=& $module {param($v)Invoke-FixtureCase $v} $v;Test-Case 'Actual reparse Core veto reaches safe CLI message' ($x.Warnings -eq 1 -and $x.Output.Contains('Reparse'))
    Remove-Item -LiteralPath $link -Force
    $x=& $module {param($v)Invoke-FixtureCase $v} $a;Test-Case 'All native/secret/default/other workflow vetoes remain unused' ($x.Native -eq 0)
} finally {
    if($module){Remove-Module $module}
    $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or -not ([IO.Path]::GetFileName($resolved).StartsWith('sql-lab-start-plan-cli-'))){throw 'FIXTURE_CLEANUP_SCOPE'}
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
Write-Host "Guided CLI: $passed PASS / $($failed.Count) FAIL; own fixture removed. Console leaves synthetic; no keyboard/native execution claim."
if($failed.Count){throw 'LLAMA_START_PLAN_CONSOLE_CHECKS_FAILED'}
