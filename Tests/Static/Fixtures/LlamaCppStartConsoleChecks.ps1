# Actual menu -> guidance -> public ShouldProcess -> isolated private runtime leaf.
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)
$ErrorActionPreference='Stop'
$passed=0;$failed=0
function Check([string]$Name,[bool]$Condition){if($Condition){$script:passed++;Write-Host "PASS $Name"}else{$script:failed++;Write-Host "FAIL $Name"}}
$module=New-Module {
    param($root)
    . (Join-Path $root 'Private/LlamaCppStartConsole.ps1')
    . (Join-Path $root 'Public/Start-SqlServerLabLlamaCppRuntime.ps1')
    $tok=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Private/PublicCommandConsole.ps1'),[ref]$tok,[ref]$parseErrors)
    if($parseErrors.Count){throw 'FIXTURE_PARSE_FAILED'}
    $fn=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Manage-LabPublicCommandsInteractive'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Private/ConsoleUi.ps1'),[ref]$tok,[ref]$parseErrors)
    $fn=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-LabConsoleTextInput'},$true)
    . ([scriptblock]::Create($fn.Extent.Text.Replace('function Read-LabConsoleTextInput','function Read-FixtureActualInput')))
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Private/LlamaCppSessionGuidance.ps1'),[ref]$tok,[ref]$parseErrors)
    $fn=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-LabLlamaCppSessionView'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $id='11111111-2222-4333-8444-555555555555'
    function Start-LabLlamaCppOwnedRuntime {
        param($RuntimeDirectory,$Backend,$Accelerator,$ModelPath,$ModelName,$Dimension,$Pooling,$Port,$CertificatePath,$PrivateKeyPath,$ApiKey,$TrustedRootPath,$StartTimeoutSeconds,$LeaseSeconds,$ContextSize)
        $script:Starts++;$script:Received=@{}+$PSBoundParameters
        $script:KeyLengthAtDispatch=$ApiKey.Length
        if($script:Mode -ceq 'RAWERROR'){throw 'PRIVATE_CALLER_CANARY'}
        if($script:Mode -ceq 'RECOVERY'){throw 'LLAMA_RECOVERY_REQUIRED; OperationId=PRIVATE_CALLER_CANARY; OriginalFailure=PRIVATE_CALLER_CANARY'}
        if($script:Mode -ceq 'NULL'){return}
        $script:LlamaCppOwnedSessions=@{$id=@{Port=$Port;Worker=[pscustomobject]@{HasExited=$false}}}
        $selector=if($Backend -ceq 'LlamaCppOpenVino'){'OPENVINO0'}elseif($Accelerator -ceq 'CPU'){'none'}else{'CUDA0'}
        $result=[pscustomobject]@{Contract='SqlServerLab.LlamaCppOwnedRuntime/1.0';OperationId=$id;Status='ENDPOINT_VERIFIED';Backend=$Backend;Accelerator=$Accelerator;ModelName=$ModelName;Dimension=[int]$Dimension;Location="https://127.0.0.1:$Port/v1/embeddings";ServerCertificateSha256=('a'*64);LeaseSeconds=[int]$LeaseSeconds;ArtifactEvidence=$null;CandidateId=$null;SelectionMode='EXPLICIT_LEGACY';RuntimeSelectors=@($selector)}
        switch($script:Mode){
            'EXTRA' {$result|Add-Member -NotePropertyName HostPath -NotePropertyValue 'PRIVATE_CALLER_CANARY'}
            'FOREIGN' {$result.OperationId='22222222-2222-4333-8444-555555555555'}
            'DRIFT' {$script:LlamaCppOwnedSessions[$id].Port=12345}
            'STRINGINT' {$result.Dimension=[string]$Dimension}
            'SELECTED' {$result.SelectionMode='AUTO';$result.CandidateId='PRIVATE_CALLER_CANARY'}
            'SELECTORS' {$result.RuntimeSelectors=@('none','CUDA0')}
            'LOCATION' {$result.Location='PRIVATE_CALLER_CANARY'}
            'ALIAS' {$result.ModelName='PRIVATE_CALLER_CANARY'}
            'ARTIFACT' {$result.ArtifactEvidence=@{HostPath='PRIVATE_CALLER_CANARY'}}
            'SCRIPT' {$result.PSObject.Properties.Remove('Status');$result|Add-Member -MemberType ScriptProperty -Name Status -Value {'ENDPOINT_VERIFIED'}}
            'MULTI' {$result}
        }
        $result
    }
    function Stop-LabLlamaCppOwnedRuntime {$script:Forbidden++;throw 'FORBIDDEN_STOP'}
    function Stop-SqlServerLabLlamaCppRuntime {$script:Forbidden++;throw 'FORBIDDEN_STOP'}
    function Get-LabPublicCommandConsoleCatalog {@()}
    function New-LabConsoleItem {param($Id,$Label,$Value,$Data)[pscustomobject]@{Id=$Id;Label=$Label;Value=$Value;Data=$Data}}
    function Invoke-LabConsoleMenu {
        param($ScreenId,$Title,$Subtitle,$Items)
        if($ScreenId -ceq 'public-command-menu'){
            $script:Menus++;if($script:Menus -gt 1){return [pscustomobject]@{Status='Cancelled'}}
            $script:MenuIds=@($Items.Id)
            return [pscustomobject]@{Status='Selected';SelectedItem=[pscustomobject]@{Id='llama-guided-start';Data='PRIVATE_CALLER_CANARY'}}
        }
        $script:Steps++
        if($script:Steps -eq $script:CancelAt){return [pscustomobject]@{Status='Cancelled'}}
        $value=if($ScreenId -ceq 'llama-guided-start-confirm'){$script:Action}else{$script:Choices.Dequeue()}
        if($script:Mode -ceq 'MENUOBJECT'){$value=[pscustomobject]@{Caller='PRIVATE_CALLER_CANARY'}}
        [pscustomobject]@{Status='Selected';SelectedItem=[pscustomobject]@{Id=$value;Data='PRIVATE_CALLER_CANARY'}}
    }
    function Read-LabConsoleTextInput {
        param($Prompt,$Default,[switch]$MaskInput,[switch]$AsSecureString)
        $script:Steps++
        if($script:Steps -eq $script:CancelAt){return [pscustomobject]@{Status='Cancelled';Value=$null}}
        if($AsSecureString){
            $script:Key=[Security.SecureString]::new();foreach($ch in ('x'*32).ToCharArray()){$script:Key.AppendChar($ch)}
            return Read-FixtureActualInput -Prompt $Prompt -AsSecureString -Capability ([pscustomobject]@{Supported=$false}) -ReadInput {param($promptText)$script:SecurePrompt=$promptText;,$script:Key}
        }
        else{$value=$script:Inputs.Dequeue()}
        [pscustomobject]@{Status='Confirmed';Value=$value}
    }
    function Read-LabConfirm {param($Prompt,$Default)$script:Steps++;$script:DefaultWasFalse=($Default -is [bool] -and -not $Default);return ($script:Confirm -and $script:Steps -ne $script:CancelAt)}
    function Write-LabInfo {param($Message)$script:Output.Add([string]$Message)}
    function Write-LabWarning {param($Message)$script:Output.Add([string]$Message)}
    foreach($name in @('Get-Item','Get-Content','Test-Path','Get-LabHostToolInvocation','Find-LabLlamaCppRuntime','Get-SqlServerLabLlamaCppStartPlan','Invoke-LabAiExternalModelHttpTransport','Start-Process')){
        Set-Item ('Function:script:'+$name) ([scriptblock]::Create("`$script:Forbidden++;throw 'FORBIDDEN_NATIVE_OR_FILE'"))
    }
    function Run-Case {
        param([string]$Mode='VALID',[int]$CancelAt=-1,[string]$Action='start',[bool]$Confirm=$true,[string]$Backend='LlamaCppCuda',[string]$Accelerator='CPU',[string]$Mutation='')
        $script:Mode=$Mode;$script:CancelAt=$CancelAt;$script:Action=$Action;$script:Confirm=$Confirm;$script:Starts=0;$script:Steps=0;$script:Menus=0;$script:Key=$null;$script:Received=$null;$script:DefaultWasFalse=$false;$script:LlamaCppOwnedSessions=@{};$script:Forbidden=0
        $script:Output=[Collections.Generic.List[string]]::new();$script:Inputs=[Collections.Generic.Queue[string]]::new();$script:Choices=[Collections.Generic.Queue[string]]::new()
        foreach($text in @('PRIVATE_PATH_CANARY','PRIVATE_PATH_CANARY','PRIVATE_PATH_CANARY','PRIVATE_PATH_CANARY','','PRIVATE_ALIAS_CANARY','768','19435','120','900','512')){$script:Inputs.Enqueue($text)}
        foreach($choice in @($Backend,$Accelerator,'mean')){$script:Choices.Enqueue($choice)}
        if($Mutation -ceq 'PATH'){$script:Inputs.Clear();foreach($text in @(('x'*4097))){$script:Inputs.Enqueue($text)}}
        if($Mutation -ceq 'ENUM'){$script:Choices.Clear();$script:Choices.Enqueue('PRIVATE_CALLER_CANARY')}
        if($Mutation -in @('LEASE','FLOAT','ALIAS','CA')){
            $texts=@('PRIVATE_PATH_CANARY','PRIVATE_PATH_CANARY','PRIVATE_PATH_CANARY','PRIVATE_PATH_CANARY','','PRIVATE_ALIAS_CANARY','768','19435','120','900','512')
            switch($Mutation){'LEASE'{$texts[9]='30'}'FLOAT'{$texts[6]='1.2'}'ALIAS'{$texts[5]='PRIVATE_ALIAS_CANARY/INVALID'}'CA'{$texts[4]='PRIVATE_CA_CANARY'}}
            $script:Inputs.Clear();foreach($text in $texts){$script:Inputs.Enqueue($text)}
        }
        Manage-LabPublicCommandsInteractive
        if($script:Forbidden){throw 'FIXTURE_FORBIDDEN_BOUNDARY_REACHED'}
        $disposed=$false;if($script:Key){try{$script:Key.AppendChar([char]122)}catch [ObjectDisposedException]{$disposed=$true}}
        $view=Get-LabLlamaCppSessionView
        [pscustomobject]@{Starts=$script:Starts;Output=($script:Output -join "`n");Disposed=$disposed;Received=$script:Received;Menu=$script:MenuIds;DefaultFalse=$script:DefaultWasFalse;Sessions=$script:LlamaCppOwnedSessions.Count;ViewItems=$view.Items.Count;KeyLength=$script:KeyLengthAtDispatch;SecurePrompt=$script:SecurePrompt}
    }
} -ArgumentList $RepoRoot
try{
    $r=& $module {Run-Case}
    Check 'actual menu -> handler -> public -> private leaf once' ($r.Starts -eq 1 -and $r.Output.Contains('ENDPOINT_VERIFIED') -and $r.DefaultFalse)
    Check 'explicit typed15 input map, optional CA omitted' ($r.Received.Count -eq 14 -and $r.Received.Dimension -is [int] -and $r.KeyLength -eq 32 -and -not $r.Received.ContainsKey('Confirm') -and -not $r.Received.ContainsKey('CaptureArtifactEvidence'))
    Check 'owned API-Key disposed, existing session preserved' ($r.Disposed -and $r.Sessions -eq 1)
    Check 'actual secure input leaf and same module session visibility' ($r.SecurePrompt.Contains('Ctrl+C: Abbruch') -and $r.ViewItems -eq 1)
    Check 'paths alias canary absent from display' ($r.Output -notmatch 'PRIVATE_|https://|ServerCertificate')
    Check 'menu retains separate preview/component/evaluation' ('llama-start-plan-preview' -in $r.Menu -and 'component-relations-preview' -in $r.Menu -and 'evaluation-refresh-preview' -in $r.Menu)
    foreach($step in 1..17){$r=& $module {param($s)Run-Case -CancelAt $s} $step;Check ("cancel stage $step zeroStart") ($r.Starts -eq 0)}
    $r=& $module {Run-Case -Action whatif};Check 'actual public WhatIf private0 no readiness' ($r.Starts -eq 0 -and $r.Disposed -and $r.Output.Contains('keine Bereitschaftsprüfung'))
    $r=& $module {Run-Case -Confirm $false};Check 'explicit effect confirmation defaultfalse cancels' ($r.Starts -eq 0 -and $r.Disposed -and $r.DefaultFalse)
    foreach($mode in @('EXTRA','FOREIGN','DRIFT','STRINGINT','SELECTED','SELECTORS','LOCATION','ALIAS','ARTIFACT','SCRIPT','MULTI','NULL','RAWERROR')){
        $r=& $module {param($m)Run-Case -Mode $m} $mode
        Check ("unexpected $mode no success/secret/autoStop") ($r.Starts -eq 1 -and $r.Output -notmatch 'ENDPOINT_VERIFIED|PRIVATE_' -and $r.Output.Contains('Start nicht bestätigt') -and $r.Disposed)
    }
    $r=& $module {Run-Case -Mode RECOVERY};Check 'compound recovery fixed visible, payload withheld' ($r.Starts -eq 1 -and $r.Output.Contains('RECOVERY_REQUIRED') -and $r.Output -notmatch 'PRIVATE_|OriginalFailure|OperationId=' -and $r.Disposed)
    foreach($mutation in @('PATH','ENUM','LEASE','FLOAT','ALIAS')){$r=& $module {param($m)Run-Case -Mutation $m} $mutation;Check ("invalid $mutation preconfirm0") ($r.Starts -eq 0 -and $r.Output.Contains('Eingabe ungültig'))}
    $r=& $module {Run-Case -Mutation CA};Check 'optional CA explicit15 map no caller path display' ($r.Starts -eq 1 -and $r.Received.Count -eq 15 -and $r.Output -notmatch 'PRIVATE_CA')
    $r=& $module {Run-Case -Mode MENUOBJECT};Check 'nonstring menu identity preconfirm0' ($r.Starts -eq 0 -and $r.Output.Contains('Eingabe ungültig'))
    $r=& $module {Run-Case -Accelerator NPU};Check 'CUDA-NPU preconfirm0' ($r.Starts -eq 0 -and $r.Output.Contains('Eingabe ungültig'))
    $r=& $module {Run-Case -Backend LlamaCppOpenVino -Accelerator NPU};Check 'explicit OpenVINO selector strict accepted synthetic only' ($r.Starts -eq 1 -and $r.Output.Contains('ENDPOINT_VERIFIED'))
} finally {Remove-Module $module -ErrorAction SilentlyContinue}
Write-Host "LLAMA GUIDED START CLI: $passed PASS, $failed FAIL; native/file/process/network 0"
if($failed){exit 1}
