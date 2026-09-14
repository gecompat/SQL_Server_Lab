#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Hyper-V Orphan Cleanup Tool Checks' -ForegroundColor Cyan
try {
    $toolPath = Join-Path $repoRoot 'Tools\Remove-HyperVOrphanWithOwnedStorage.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($toolPath, [ref]$tokens, [ref]$parseErrors)
    Add-CheckResult -Name 'Bereinigungstool ist syntaktisch gültig' -Success ($parseErrors.Count -eq 0)

    $source = Get-Content -LiteralPath $toolPath -Raw -Encoding utf8
    $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { [string]$_.Name.VariablePath.UserPath })
    $operationalParameterNames = @($parameterNames | Where-Object { $_ -notin @('ShowHelp', 'RemainingArgs') })
    Add-CheckResult -Name 'Tool benötigt nur VM-Name und explizite Daten-VHDX-Freigabe' -Success (
        ((@($operationalParameterNames | Sort-Object) -join '|') -ceq 'DeleteAdditionalVhdx|VMName') -and
        $parameterNames -contains 'ShowHelp' -and
        $parameterNames -contains 'RemainingArgs' -and
        $source -match 'UNKNOWN_ARGUMENTS' -and
        $source -match "RemainingArgs -contains '--help'" -and
        $source -match 'VMName ist erforderlich')
    Add-CheckResult -Name 'Tool besitzt WhatIf- und High-Impact-Schutz' -Success (
        $source -match 'SupportsShouldProcess' -and
        $source -match "ConfirmImpact = 'High'" -and
        $source -match 'PositionalBinding = \$false' -and
        $source -match '\$PSCmdlet\.ShouldProcess' -and
        $source -match 'Daten-VHDX erfordert die explizite Freigabe')
    Add-CheckResult -Name 'Tool ermittelt Bindungen nur aus der gewählten VM' -Success (
        $source -match 'Get-VM -Name \$VMName' -and
        $source -match 'Get-VMHardDiskDrive -VM \$vm' -and
        $source -match 'Get-VHD -Path \$path' -and
        $source -match 'attachedVhdx\.Count -ne 2')
    Add-CheckResult -Name 'Tool blockiert laufende VMs, Checkpoints, Reparse-Points und fremde Disk-Bindungen' -Success (
        $source -match "vm\.State -ne 'Off'" -and
        $source -match 'Get-VMSnapshot -VM \$vm' -and
        $source -match 'Reparse-Point im Löschumfang' -and
        $source -match 'andere VM gebunden')
    Add-CheckResult -Name 'Tool bewahrt den Differencing-Parent und löscht nur abgeleitete eigene VHDX' -Success (
        $source -match "VhdType -eq 'Differencing'" -and
        $source -match 'PreservedPaths' -and
        $source -match 'foreach \(\$path in @\(\$childVhdxPath, \$additionalVhdxPath\)\)' -and
        $source -notmatch 'Remove-Item -LiteralPath \$sharedParentVhdxPath')
}
catch {
    Add-CheckResult -Name 'Hyper-V-Orphan-Cleanup-Tool-Testausführung' -Success $false -Message $_.Exception.Message
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "Hyper-V Orphan Cleanup Tool Checks: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Hyper-V Orphan Cleanup Tool Checks: $passed PASS" -ForegroundColor Green
