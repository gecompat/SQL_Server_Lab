#Requires -Version 7.2
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)
$ErrorActionPreference='Stop'
$definitions=@()
foreach($entry in @(
    @{Path='Public/Clear-SqlServerLab.ps1';Name='Clear-SqlServerLab'},
    @{Path='Public/BatchConsole.ps1';Name='Show-LabMaintenanceMenu'}
)) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $entry.Path),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'CLEAR_WARNING_SOURCE_PARSE'}
    $functions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $entry.Name},$true))
    if($functions.Count -ne 1){throw 'CLEAR_WARNING_FUNCTION_NOT_UNIQUE'}
    $definitions+=$functions[0].Extent.Text
}
$module=New-Module -ScriptBlock {
    param($Definitions)
    foreach($definition in $Definitions){. ([scriptblock]::Create($definition))}
    function Get-SqlServerLabCleanupAudit {[pscustomobject]@{Audit=[pscustomobject]@{HyperV=[pscustomobject]@{Status='NOT_INSTALLED'}}}}
    function Get-LabStateRoot {Join-Path ([IO.Path]::GetTempPath()) 'synthetic-clear-warning'}
    function Get-LabActiveRuns {@([pscustomobject]@{runId='synthetic-running';state='RUNNING'},[pscustomobject]@{runId='synthetic-stopped';state='STOPPED'})}
    function Get-LabAutomatedTestEnvironmentRunIds {@()}
    function Get-HyperVImageBuildPlans {@()}
    function Get-HyperVSqlImageBuildPlans {@()}
    function Get-LabDataRootDefault {$null}
    function Resolve-LabHostTool {param($Name)[pscustomobject]@{Available=($Name -ceq 'docker');Invocation='Invoke-SyntheticCleanupRuntime'}}
    function Invoke-SyntheticCleanupRuntime {$global:LASTEXITCODE=0}
    function Get-DockerLabContainers {@([pscustomobject]@{ContainerId='synthetic-container';Name='synthetic';Status='running';RunId='synthetic-running';ScopeId='synthetic-scope'})}
    function Write-LabHeader {param($Message)$script:headers.Add([string]$Message)}
    function Write-LabStatus {}
    function Write-LabInfo {param($Message)$script:messages.Add([string]$Message)}
    function Write-LabSuccess {}
    function Write-LabWarning {param($Message)$script:messages.Add([string]$Message)}
    function Write-LabError {}
    function Read-LabConfirm {
        param($Prompt,[bool]$Default=$true)
        $script:confirmations.Add([pscustomobject]@{Prompt=$Prompt;Default=$Default;MessagesBefore=@($script:messages)})
        return $Default # Simulate Enter without explicit consent.
    }
    function Remove-SqlServerLab {$script:mutations++;throw 'SYNTHETIC_REMOVAL_FORBIDDEN'}
    function Remove-DockerInstance {$script:mutations++;throw 'SYNTHETIC_REMOVAL_FORBIDDEN'}
    function Remove-Item {$script:mutations++;throw 'SYNTHETIC_REMOVAL_FORBIDDEN'}
    function New-LabConsoleItem {param($Id,$Label,$Value,$Shortcut,$Help)[pscustomobject]@{Id=$Id;Label=$Label;Value=$Value;Help=$Help}}
    function Show-LabSubMenu {param($ScreenId,$Title,$Subtitle,$Items)$Items}
} -ArgumentList (,$definitions)
try {
    & $module {
        $passed=0
        $clear=@(Show-LabMaintenanceMenu|Where-Object Id -ceq Clear)
        if($clear.Count -ne 1 -or $clear[0].Label -notmatch 'Alle.*löschen' -or $clear[0].Value -notmatch 'laufende.*gestoppte'){throw 'CLEAR_MENU_DELETION_SCOPE_NOT_VISIBLE'}
        $passed++
        foreach($mode in @('All','StateOnly','ContainersOnly','ForceWhatIf')) {
            $script:messages=[Collections.Generic.List[string]]::new()
            $script:headers=[Collections.Generic.List[string]]::new()
            $script:confirmations=[Collections.Generic.List[object]]::new()
            $script:mutations=0
            $arguments=@{Confirm=$false}
            if($mode -ceq 'StateOnly'){$arguments.StateOnly=$true}
            if($mode -ceq 'ContainersOnly'){$arguments.ContainersOnly=$true}
            if($mode -ceq 'ForceWhatIf'){$arguments.Force=$true;$arguments.WhatIf=$true}
            $result=Clear-SqlServerLab @arguments
            if($result.Status -cne 'CANCELLED' -or $script:mutations -ne 0){throw "CLEAR_ENTER_OR_WHATIF_REMOVED_RESOURCE_$mode"}
            if($mode -ceq 'ForceWhatIf') {
                if($script:confirmations.Count -ne 0){throw 'CLEAR_FORCE_WHATIF_PROMPTED'}
            }
            else {
                if($script:confirmations.Count -ne 1 -or $script:confirmations[0].Default){throw "CLEAR_CONFIRMATION_DEFAULT_NOT_NO_$mode"}
                $prompt=$script:confirmations[0].Prompt
                $before=$script:confirmations[0].MessagesBefore -join ' '
                switch($mode) {
                    All {if($prompt -notmatch 'ALLE.*laufende.*gestoppte.*löschen' -or $before -notmatch 'keine reine Bereinigung verwaister Reste' -or $before -notmatch 'ALLE Lab-Verzeichnisse'){throw 'CLEAR_ALL_WARNING_NOT_BEFORE_CONFIRMATION'}}
                    StateOnly {if($prompt -notmatch 'verwaiste State-Einträge' -or $before -notmatch 'Umgebungen werden nicht gelöscht'){throw 'CLEAR_STATE_ONLY_SCOPE_MISLEADING'}}
                    ContainersOnly {if($prompt -notmatch 'ALLE.*Lab-Container.*laufender' -or $before -notmatch 'Run-State bleibt bestehen'){throw 'CLEAR_CONTAINERS_ONLY_SCOPE_MISLEADING'}}
                }
            }
            $passed++
        }
        Write-Host "CLEAR REMOVAL WARNINGS: $passed PASS; Enter/WhatIf native removal NOT_EXECUTED"
    }
}
finally {Remove-Module $module}
