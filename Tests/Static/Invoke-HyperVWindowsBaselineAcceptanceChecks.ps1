#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den Vertrag des realen Hyper-V-Windows-Baseline-Acceptance-Runners.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runnerPath = Join-Path $repoRoot 'Tests\Integration\Invoke-HyperVWindowsBaselineAcceptanceRun.ps1'
$reconcilePath = Join-Path $repoRoot 'Public\Invoke-SqlServerLabReconcileAction.ps1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Hyper-V Windows Baseline Acceptance Checks' -ForegroundColor Cyan

Add-CheckResult -Name 'Windows-Baseline-Acceptance-Runner ist vorhanden' -Success (Test-Path -LiteralPath $runnerPath -PathType Leaf)

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
Add-CheckResult -Name 'Windows-Baseline-Acceptance-Runner ist syntaktisch gueltig' -Success (@($parseErrors).Count -eq 0) -Message (@($parseErrors | ForEach-Object Message) -join '; ')

$pwsh = Get-Command pwsh -ErrorAction Stop
& $pwsh.Source -NoLogo -NoProfile -File $runnerPath -ShowHelp *> $null
Add-CheckResult -Name 'Windows-Baseline-Acceptance-Runner bietet Hilfe ohne Pflichtparameter-Prompt' -Success ($LASTEXITCODE -eq 0)

$runnerText = Get-Content -LiteralPath $runnerPath -Raw -Encoding utf8
$reconcileText = Get-Content -LiteralPath $reconcilePath -Raw -Encoding utf8

$runnerTokens = $null
$runnerParseErrors = $null
$runnerAst = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$runnerTokens, [ref]$runnerParseErrors)

function Get-CommandParameterValues {
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.CommandAst]$Command,
        [Parameter(Mandatory)][string]$ParameterName
    )

    $values = [System.Collections.Generic.List[string]]::new()
    $captureNext = $false
    foreach ($element in $command.CommandElements) {
        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            $captureNext = ($element.ParameterName -ieq $ParameterName)
            continue
        }
        if ($captureNext) {
            if ($null -ne $element.Extent) {
                $values.Add($element.Extent.Text.Trim("""'"))
            }
            $captureNext = $false
        }
    }
    return @($values)
}

function Has-CommandParameterName {
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.CommandAst]$Command,
        [Parameter(Mandatory)][string]$ParameterName
    )

    foreach ($element in $Command.CommandElements) {
        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
            $element.ParameterName -ieq $ParameterName) {
            return $true
        }
    }

    return $false
}

$runnerReconcileCalls = @(
    $runnerAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-SqlServerLabReconcileAction'
    }, $true)
)
$runnerArtifactCalls = @(
    $runnerAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Get-HyperVImageArtifact'
    }, $true)
)

$reconcileTargets = @{}
foreach ($call in $runnerReconcileCalls) {
    foreach ($target in Get-CommandParameterValues -Command $call -ParameterName 'TargetState') {
        $reconcileTargets[$target.ToUpperInvariant()] = $true
    }
}
$artifactLookupHasArtifactId = $false
$artifactLookupHasStateRoot = $false
foreach ($call in $runnerArtifactCalls) {
    if (Has-CommandParameterName -Command $call -ParameterName 'ArtifactId') {
        $artifactLookupHasArtifactId = $true
    }
    if (Has-CommandParameterName -Command $call -ParameterName 'StateRoot') {
        $artifactLookupHasStateRoot = $true
    }
}

Add-CheckResult -Name 'Runner akzeptiert ausschliesslich immutable OS_SEALED-Artifact-IDs' -Success (
    $runnerText -match 'hyperv-os-sealed-\[a-f0-9\]\{64\}' -and
    $runnerText -match "artifactState -eq 'OS_SEALED'" -and
    $runnerText -match 'Parent-VHDX ist vor dem Lauf schreibgeschuetzt'
)
Add-CheckResult -Name 'Runner deckt OOBE und Windows-only-Provisionierung ab' -Success (
    $runnerText -match 'Invoke-HyperVLabUnattendedProvision' -and
    $runnerText -match '\$provisioning\.WindowsOnly' -and
    $runnerText -match "windowsProvisioning\.state -eq 'COMPLETE'"
)
Add-CheckResult -Name 'Runner prueft Stop, Start und PowerShell-Direct-Reconnect' -Success (
    $runnerReconcileCalls.Count -ge 2 -and
    $reconcileTargets.ContainsKey('STOPPED') -and
    $reconcileTargets.ContainsKey('RUNNING') -and
    $runnerText -match 'Wait-HyperVPowerShellDirect'
)
Add-CheckResult -Name 'Runner übergibt Artifact-Id und StateRoot bei Hyper-V-Image-Metadatenabfrage' -Success (
    $artifactLookupHasArtifactId -and
    $artifactLookupHasStateRoot
)
Add-CheckResult -Name 'Runner behauptet fuer die OS-Baseline keine SQL-Bereitschaft' -Success (
    $runnerText -match 'sqlServices = @\(\$sqlServices\)' -and
    $runnerText -match 'sqlInstanceRegistryPresent' -and
    $runnerText -match 'Windows-OS-Baseline enthaelt keine SQL-Server-Instanz'
)
Add-CheckResult -Name 'Runner entfernt den Scope standardmaessig und behaelt Fehler nur explizit' -Success (
    $runnerText -match 'Remove-SqlServerLab.+-StateRoot \$StateRoot.+-Force' -and
    $runnerText -match '\$failure -and \$KeepOnFailure\.IsPresent' -and
    $runnerText -match 'verifiedArtifact\.sha256 -eq \$artifact\.sha256'
)
Add-CheckResult -Name 'Reconcile-Executor reicht Custom-StateRoot an Start und Stop weiter' -Success (
    $reconcileText -match 'Start-SqlServerLab -RunId \$RunId -StateRoot \$StateRoot' -and
    $reconcileText -match 'Stop-SqlServerLab -RunId \$RunId -StateRoot \$StateRoot -Force'
)

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, 0 FAIL" -ForegroundColor Green
exit 0
