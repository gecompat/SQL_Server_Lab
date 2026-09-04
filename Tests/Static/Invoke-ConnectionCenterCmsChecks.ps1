#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft sichtbare, dynamische CMS-Gruppenzaehler und deren sichere Migration.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sourcePath = Join-Path $repoRoot 'Public\Sync-SqlServerLabConnectionCenter.ps1'
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Connection Center CMS Checks' -ForegroundColor Cyan

try {
    . $sourcePath
    $entries = @(
        [PSCustomObject]@{ Provider='docker'; RuntimeState='RUNNING' }
        [PSCustomObject]@{ Provider='hyperv'; RuntimeState='RUNNING' }
        [PSCustomObject]@{ Provider='hyperv'; RuntimeState='RUNNING' }
        [PSCustomObject]@{ Provider='docker'; RuntimeState='STOPPED' }
        [PSCustomObject]@{ Provider='hyperv'; RuntimeState='STOPPED' }
        [PSCustomObject]@{ Provider='hyperv'; RuntimeState='STOPPED' }
        [PSCustomObject]@{ Provider='hyperv'; RuntimeState='STOPPED' }
        [PSCustomObject]@{ Provider='podman'; RuntimeState='UNKNOWN' }
    )
    $center = [PSCustomObject]@{
        Grouping = [PSCustomObject]@{ RootGroupName='SQL Server Lab' }
        Entries = $entries
    }
    $summary = Get-LabCmsHierarchySummary -ConnectionCenter $center
    $runningProviders = @($summary.Running.Providers | ForEach-Object { $_.DisplayName })
    $stoppedProviders = @($summary.Stopped.Providers | ForEach-Object { $_.DisplayName })

    Add-CheckResult -Name 'CMS-Root zeigt die rekursive Gesamtanzahl' -Success (
        $summary.Root.Count -eq 8 -and $summary.Root.DisplayName -eq 'SQL Server Lab (8)')
    Add-CheckResult -Name 'Running zeigt Status- und Provideranzahlen' -Success (
        $summary.Running.Count -eq 3 -and $summary.Running.DisplayName -eq 'Running (3)' -and
        $runningProviders.Count -eq 2 -and 'DOCKER (1)' -in $runningProviders -and
        'HYPERV (2)' -in $runningProviders)
    Add-CheckResult -Name 'Stopped zeigt Status- und Provideranzahlen' -Success (
        $summary.Stopped.Count -eq 5 -and $summary.Stopped.DisplayName -eq 'Stopped (5)' -and
        $stoppedProviders.Count -eq 3 -and 'DOCKER (1)' -in $stoppedProviders -and
        'HYPERV (3)' -in $stoppedProviders -and 'PODMAN (1)' -in $stoppedProviders)
    Add-CheckResult -Name 'Leere Providergruppen werden nicht projiziert' -Success (
        'PODMAN (0)' -notin $runningProviders)

    $source = Get-Content -LiteralPath $sourcePath -Raw -Encoding utf8
    Add-CheckResult -Name 'Bestehende CMS-Gruppen werden ID-stabil umbenannt' -Success (
        $source -match 'sp_sysmanagement_rename_shared_server_group' -and
        $source -match 'sp_sysmanagement_update_shared_server_group' -and
        $source -match 'Role=Root' -and $source -match 'Role=RuntimeState' -and
        $source -match 'Role=Provider')
    Add-CheckResult -Name 'Zaehler werden aus dem CMS-Istbaum rekursiv erneuert' -Success (
        $source -match 'RunningGroupTree' -and $source -match 'StoppedGroupTree' -and
        $source -match 'ManagedRootTree' -and $source -match 'SELECT @RunningCount = COUNT\(\*\)' -and
        $source -match 'SELECT @StoppedCount = COUNT\(\*\)' -and
        $source -match 'SELECT @ManagedRootCount = COUNT\(\*\)')
    Add-CheckResult -Name 'Namenskollisionen brechen die CMS-Transaktion fail-closed ab' -Success (
        $source -match 'CMS running provider group name collision' -and
        $source -match 'CMS stopped provider group name collision' -and
        $source -match 'CMS managed root group name collision')
    Add-CheckResult -Name 'Providergruppen entstehen nur fuer vorhandene Endpunkte' -Success (
        $source -match 'if \(\$runningProviderEntries\.Count -gt 0\)' -and
        $source -match 'if \(\$stoppedProviderEntries\.Count -gt 0\)' -and
        $source -match 'sp_sysmanagement_delete_shared_server_group')
}
catch {
    Add-CheckResult -Name 'Connection-Center-CMS-Vertragspruefung' -Success $false -Message $_.Exception.Message
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
exit 0
