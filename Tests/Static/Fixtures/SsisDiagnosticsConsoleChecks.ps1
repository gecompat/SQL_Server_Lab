#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$checks=0
function Assert-SsisConsole($value,[string]$label){if(-not$value){throw ('SSIS_CONSOLE_CHECK_FAILED: '+$label)};$script:checks++;Write-Host ('PASS: '+$label)}
function Import-SsisConsoleFunction([string]$relative,[string]$name){
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $relative),[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'SSIS_CONSOLE_FIXTURE_PARSE_FAILED'}
    $matches=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name})
    if($matches.Count-ne1){throw ('SSIS_CONSOLE_FIXTURE_FUNCTION_NOT_UNIQUE: '+$name)}
    . ([scriptblock]::Create(($matches[0].Extent.Text-replace'^function ','function script:')))
}
. (Join-Path $repo 'Private/SsisDiagnosticsConsole.ps1')

$script:menuAnswers=[Collections.Generic.Queue[string]]::new()
$script:textAnswers=[Collections.Generic.Queue[object]]::new()
$script:confirmAnswers=[Collections.Generic.Queue[bool]]::new()
$script:seenScreens=[Collections.Generic.List[string]]::new()
$script:messages=[Collections.Generic.List[string]]::new()
$script:dispatches=[Collections.Generic.List[object]]::new()
$script:maskFlags=[Collections.Generic.List[bool]]::new()
function Reset-SsisConsole([string[]]$Menus,[object[]]$Texts,[bool[]]$Confirmations){
    $script:menuAnswers=[Collections.Generic.Queue[string]]::new();foreach($value in $Menus){$script:menuAnswers.Enqueue($value)}
    $script:textAnswers=[Collections.Generic.Queue[object]]::new();foreach($value in $Texts){$script:textAnswers.Enqueue($value)}
    $script:confirmAnswers=[Collections.Generic.Queue[bool]]::new();foreach($value in $Confirmations){$script:confirmAnswers.Enqueue($value)}
    $script:seenScreens.Clear();$script:messages.Clear();$script:dispatches.Clear();$script:maskFlags.Clear()
}
function New-LabConsoleItem {param($Id,$Label,$Value,$Shortcut,$Disabled,$DisabledReason,$Help);[pscustomobject]@{Id=$Id;Label=$Label;Value=$Value;Shortcut=$Shortcut;Disabled=$Disabled;DisabledReason=$DisabledReason;Help=$Help}}
function Invoke-LabConsoleMenu {param($ScreenId,$Title,$Subtitle,$Items);$script:seenScreens.Add($ScreenId);$answer=$script:menuAnswers.Dequeue();$item=@($Items|Where-Object Id -CEQ $answer)[0];[pscustomobject]@{Status='Selected';SelectedItem=$item}}
function Read-LabConsoleTextInput {param($Prompt,[string]$Default,[switch]$MaskInput);$script:maskFlags.Add([bool]$MaskInput);$value=$script:textAnswers.Dequeue();[pscustomobject]@{Status='Confirmed';Value=$value}}
function Read-LabConfirm {param($Prompt,[bool]$Default);$script:confirmAnswers.Dequeue()}
function Write-LabInfo {param($Message);$script:messages.Add([string]$Message)}
function Write-LabWarning {param($Message);$script:messages.Add([string]$Message)}
function Get-SqlServerLabSsisPackageDiagnostic {param($RunId,$InstanceId,$IspacPath,$PackageName,$PackagePath,$ExpectedSha256,$TimeoutSeconds);$script:dispatches.Add([pscustomobject]@{Kind='Package';Args=$PSBoundParameters});[pscustomobject]@{Status='OBSERVED';ReasonCode='NONE';Observation=[pscustomobject]@{Runtime=[pscustomobject]@{FileVersion='17.0.1000.7'};LoadStatus='RETURNED';Events=@([pscustomobject]@{Kind='WARNING';Code=123})}}}
function Get-SqlServerLabSsisExecutionDiagnostic {param($RunId,$InstanceId,$ExecutionId,$ExpectedProjectLsn,$ExpectedCatalogDatabaseGuid,$TimeoutSeconds);$script:dispatches.Add([pscustomobject]@{Kind='Execution';Args=$PSBoundParameters});[pscustomobject]@{Status='OBSERVED';ReasonCode='NONE';Observation=[pscustomobject]@{Snapshot=[pscustomobject]@{ObservedExecutionStatus=7};Worker=[pscustomobject]@{Status='NOT_REPORTED'};ErrorCodes=@()}}}
function Wait-LabConsoleAcknowledgement {}
function Get-CommandInfo {param($Name);$null}
function Get-LabConsoleTextInput {param($Prompt,$Default,[switch]$MaskInput);$null}

$packagePath=Join-Path ([IO.Path]::GetTempPath()) 'secret-name.dtsx'
try{
    Reset-SsisConsole @('Package','Dtsx') @('11111111-1111-1111-1111-111111111111','primary','60',$packagePath,'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA') @($true)
    Invoke-LabSsisDiagnosticsInteractive
    $boundArgs=$dispatches[0].Args
    Assert-SsisConsole ($dispatches.Count-eq1-and$dispatches[0].Kind-ceq'Package') 'DTSX route invokes only the package diagnostic after confirmation'
    Assert-SsisConsole ($boundArgs.RunId-eq[guid]'11111111-1111-1111-1111-111111111111'-and$boundArgs.PackagePath-ceq$packagePath-and$boundArgs.ExpectedSha256-ceq('A'*64)-and$boundArgs.TimeoutSeconds-eq60) 'DTSX inputs are bound to public diagnostic parameters'
    Assert-SsisConsole ($maskFlags.Count-eq5-and$maskFlags[3]-and(($messages-join' ')-notmatch'C:\\private|secret-name')) 'Package path input is masked and omitted from summary'
    Assert-SsisConsole ($seenScreens-join','-ceq'ssis-diagnostic-kind,ssis-diagnostic-package-format') 'Package mode exposes both guided choices'

    Reset-SsisConsole @('Package','back') @('11111111-1111-1111-1111-111111111111','primary','60') @()
    Invoke-LabSsisDiagnosticsInteractive
    Assert-SsisConsole ($dispatches.Count-eq0) 'Back from package format performs no diagnostic call'

    Reset-SsisConsole @('Execution') @('11111111-1111-1111-1111-111111111111','primary','60','9007199254740993','9007199254740995','33333333-3333-3333-3333-333333333333') @($true)
    Invoke-LabSsisDiagnosticsInteractive
    $boundArgs=$dispatches[0].Args
    Assert-SsisConsole ($dispatches.Count-eq1-and$dispatches[0].Kind-ceq'Execution') 'Execution route invokes only the metadata diagnostic after confirmation'
    Assert-SsisConsole ($boundArgs.ExecutionId-eq[long]9007199254740993-and$boundArgs.ExpectedProjectLsn-eq[long]9007199254740995-and$boundArgs.ExpectedCatalogDatabaseGuid-eq[guid]'33333333-3333-3333-3333-333333333333') 'Large execution identifiers retain exact Int64 values'
    Assert-SsisConsole (($messages -join ' ') -match 'Katalogstatus: 7') 'Summary uses the actual catalog execution status'

    Reset-SsisConsole @('Package','Dtsx') @('11111111-1111-1111-1111-111111111111','primary','60','relative.dtsx') @()
    Invoke-LabSsisDiagnosticsInteractive
    Assert-SsisConsole ($dispatches.Count-eq0-and($messages-join' ')-match'SSIS_DIAGNOSTIC_INPUT_INVALID') 'Invalid package path fails closed before dispatch'

    Reset-SsisConsole @('Package','Dtsx') @('11111111-1111-1111-1111-111111111111','primary','60',$packagePath,'A'*64) @($false)
    Invoke-LabSsisDiagnosticsInteractive
    Assert-SsisConsole ($dispatches.Count-eq0) 'Declining the package trust confirmation performs no diagnostic call'

    function Show-LabSubMenu {param($ScreenId,$Title,$Subtitle,$Items);$Items}
    Import-SsisConsoleFunction 'Public/BatchConsole.ps1' 'Show-LabWorkspaceMenu'
    $workspace=@(Show-LabWorkspaceMenu)
    Assert-SsisConsole (@($workspace|Where-Object Id -CEQ 'SsisDiagnostics').Count-eq1) 'Lab workspace menu exposes SSIS diagnostics'
    $shortcuts = @($workspace | Where-Object { $null -ne $_.Shortcut } | Group-Object Shortcut)
    Assert-SsisConsole (@($shortcuts | Where-Object Count -gt 1).Count -eq 0) 'Lab workspace shortcuts select a single action'

    Import-SsisConsoleFunction 'Public/Invoke-SqlServerLab.ps1' 'Invoke-LabMenuAction'
    $script:routed=0
    function Invoke-LabSsisDiagnosticsInteractive {$script:routed++}
    Invoke-LabMenuAction -ActionName SsisDiagnostics
    Assert-SsisConsole ($routed-eq1) 'Lab menu action dispatches the guided SSIS flow'

    function New-LabQueueStatusProvider {param($Height);@{}}
    Import-SsisConsoleFunction 'Public/Invoke-SqlServerLab.ps1' 'Invoke-SqlServerLab'
    Invoke-SqlServerLab -Action SsisDiagnostics -ConsoleMode Fallback
    Assert-SsisConsole ($routed-eq2) 'Direct CLI action opens the guided SSIS flow'
    . (Join-Path $repo 'Private/SsisDiagnosticsBrowser.ps1')
    $inputJson='{"RunId":"11111111-1111-1111-1111-111111111111","InstanceId":"primary","ExecutionId":"9007199254740993","ProjectLsn":"9007199254740995","CatalogDatabaseGuid":"22222222-2222-2222-2222-222222222222"}'
    $dispatches.Clear()
    $view=Invoke-LabSsisExecutionDiagnosticBrowser -Json $inputJson
    Assert-SsisConsole ($dispatches.Count -eq 1 -and $dispatches[0].Args.ExecutionId -eq [long]9007199254740993) 'Browser preserves exact Int64 receipt values'
    Assert-SsisConsole ($view.Status -ceq 'OBSERVED' -and $view.ExecutionStatus -eq 7 -and $view.ErrorCodes.Count -eq 0 -and
        @($view.PSObject.Properties.Name).Count -eq 5 -and ($view | ConvertTo-Json) -notmatch '11111111|22222222') 'Browser emits only the projected diagnostic summary'
    foreach($invalid in @($inputJson.Replace('"9007199254740993"','9007199254740993'), $inputJson.Replace('"primary"', '"primary","InstanceId":"other"'), $inputJson.Replace('"primary"', '"primary","StateRoot":"private"'))){
        $rejected=$false
        try { $null=Invoke-LabSsisExecutionDiagnosticBrowser -Json $invalid } catch { $rejected=$true }
        Assert-SsisConsole ($rejected -and $dispatches.Count -eq 1) 'Malformed browser inputs are rejected before dispatch'
    }
    $packageJson = @{
        RunId='11111111-1111-1111-1111-111111111111'; InstanceId='primary'; PackagePath=$packagePath
        PackageName=''; ExpectedSha256=('A' * 64); TrustConfirmed=$true
    }
    $dispatches.Clear()
    $packageView = Invoke-LabSsisPackageDiagnosticBrowser -Json ($packageJson | ConvertTo-Json -Compress)
    Assert-SsisConsole ($dispatches.Count -eq 1 -and $dispatches[0].Args.PackagePath -ceq $packagePath -and
        $packageView.EventCodes[0] -eq 123 -and ($packageView | ConvertTo-Json) -notmatch 'secret-name|AAAAAAAA') 'Browser binds trusted DTSX input and keeps artifact details private'
    $packageJson.PackagePath = Join-Path ([IO.Path]::GetTempPath()) 'synthetic.ispac'
    $packageJson.PackageName = 'Test.dtsx'
    $view = Invoke-LabSsisPackageDiagnosticBrowser -Json ($packageJson | ConvertTo-Json -Compress)
    Assert-SsisConsole ($dispatches.Count -eq 2 -and $dispatches[1].Args.PackageName -ceq 'Test.dtsx' -and
        $dispatches[1].Args.IspacPath -ceq $packageJson.PackagePath) 'Browser binds the ISPAC member to the selected package'
    foreach($value in @($false, 'true')){
        $packageJson.TrustConfirmed = $value
        $rejected = $false
        try { $null = Invoke-LabSsisPackageDiagnosticBrowser -Json ($packageJson | ConvertTo-Json -Compress) } catch { $rejected = $true }
        Assert-SsisConsole ($rejected -and $dispatches.Count -eq 2) 'Package request requires explicit boolean confirmation'
    }
    function Get-SqlServerLabSsisPackageDiagnostic { [CmdletBinding()]param([string]$RunId,[string]$InstanceId,[string]$IspacPath,[string]$PackageName,[string]$ExpectedSha256) [pscustomobject]@{ Status='INCONCLUSIVE'; Observation=$null } }
    $packageJson.TrustConfirmed = $true
    $unobserved = Invoke-LabSsisPackageDiagnosticBrowser -Json ($packageJson | ConvertTo-Json -Compress)
    Assert-SsisConsole ($unobserved.Status -ceq 'INCONCLUSIVE' -and $null -eq $unobserved.LoadStatus -and $unobserved.EventCodes.Count -eq 0) 'Missing guest observation is an empty inconclusive summary'
    Write-Host ('SSIS_DIAGNOSTICS_CONSOLE_CHECKS: '+$checks+' PASS; 0 FAIL')
} catch { throw }
