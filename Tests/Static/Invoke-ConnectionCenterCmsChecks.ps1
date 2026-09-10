#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft CMS-Gruppenzaehler, sichere Migration und kopierbare Kennwortknoten.
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

    $dockerClientTarget = ConvertTo-LabCmsServerTarget -Server '127.0.0.1,15433' -CmsProvider docker
    $podmanClientTarget = ConvertTo-LabCmsServerTarget -Server 'localhost,15434' -CmsProvider podman
    $hyperVClientTarget = ConvertTo-LabCmsServerTarget -Server '192.0.2.25,1433' -CmsProvider docker
    Add-CheckResult -Name 'CMS bewahrt die aus Sicht des SSMS-Clients erreichbaren Serverziele' -Success (
        $dockerClientTarget -eq '127.0.0.1,15433' -and
        $podmanClientTarget -eq 'localhost,15434' -and
        $hyperVClientTarget -eq '192.0.2.25,1433')
    Add-CheckResult -Name 'CMS erzeugt keine nur containerintern gueltigen Host-Aliasse' -Success (
        $dockerClientTarget -notmatch '^host\.docker\.internal' -and
        $podmanClientTarget -notmatch '^host\.containers\.internal')

    $source = Get-Content -LiteralPath $sourcePath -Raw -Encoding utf8
    Add-CheckResult -Name 'Bestehende CMS-Gruppen werden ID-stabil umbenannt' -Success (
        $source -match 'sp_sysmanagement_rename_shared_server_group' -and
        $source -match 'sp_sysmanagement_update_shared_server_group' -and
        $source -match 'Role=Root' -and $source -match 'Role=RuntimeState' -and
        $source -match 'Role=Provider')
    Add-CheckResult -Name 'Zaehler werden aus dem CMS-Istbaum rekursiv erneuert' -Success (
        $source -match 'RunningGroupTree' -and $source -match 'StoppedGroupTree' -and
        $source -match 'RunningProviderTree_' -and $source -match 'StoppedProviderTree_' -and
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

    $aliasEntry = [PSCustomObject]@{ RunId='generated-run'; DisplayName='Demo (primary)' }
    $generatedNodeName = Get-LabCmsRegisteredServerDisplayName -Entry $aliasEntry -StateRoot 'unused' `
        -IncludeGeneratedPassword -GeneratedPasswordResolver { param($RunId, $StateRoot) 'Generated!234' }
    $manualNodeName = Get-LabCmsRegisteredServerDisplayName -Entry $aliasEntry -StateRoot 'unused' `
        -IncludeGeneratedPassword -GeneratedPasswordResolver { param($RunId, $StateRoot) $null }
    $passwordDisplayDisabled = Get-LabCmsRegisteredServerDisplayName -Entry $aliasEntry -StateRoot 'unused' `
        -GeneratedPasswordResolver { param($RunId, $StateRoot) 'Generated!234' }
    Add-CheckResult -Name 'Kennwortknoten sind direkt kopierbar und manuelle Passwoerter bleiben verborgen' -Success (
        $generatedNodeName -eq 'Generated!234' -and
        $manualNodeName -eq 'MANUELLES PASSWORT EINGEBEN' -and
        $passwordDisplayDisabled -eq 'Demo (primary)')

    $longEntry = [PSCustomObject]@{ RunId='generated-run'; Id='generated-run/primary'; DisplayName=(('x' * 160) + ' (primary)') }
    $boundedEnvironmentGroup = Get-LabCmsEnvironmentGroupDisplayName -Entry $longEntry
    Add-CheckResult -Name 'CMS-Umgebungsordner bleibt innerhalb der sysname-Grenze' -Success (
        $boundedEnvironmentGroup.Length -le 128 -and
        $boundedEnvironmentGroup -match 'Run=generated-run' -and
        $boundedEnvironmentGroup -match 'Instance=primary' -and
        $boundedEnvironmentGroup -match 'Identity=[0-9a-f]{12}\]$')

    $collidingCmsEntries = @(
        [PSCustomObject]@{ RunId='11111111-1111-1111-1111-111111111111'; Id='11111111-1111-1111-1111-111111111111/primary'; DisplayName='sql2022-latest (primary)' },
        [PSCustomObject]@{ RunId='22222222-2222-2222-2222-222222222222'; Id='22222222-2222-2222-2222-222222222222/primary'; DisplayName='sql2022-latest (primary)' }
    )
    $resolvedCmsNames = @($collidingCmsEntries | ForEach-Object { Get-LabCmsManagedRegisteredServerDisplayName -Entry $_ -StateRoot 'unused' })
    $repeatedCmsNames = @($collidingCmsEntries | ForEach-Object { Get-LabCmsManagedRegisteredServerDisplayName -Entry $_ -StateRoot 'unused' })
    Add-CheckResult -Name 'Gleichnamige CMS-Server behalten beide stabile Run- und Instanzidentitaeten' -Success (
        $resolvedCmsNames.Count -eq 2 -and
        @($resolvedCmsNames | Select-Object -Unique).Count -eq 2 -and
        $resolvedCmsNames[0] -match 'sql2022-latest \(primary\) \[Run=11111111-1111-1111-1111-111111111111; Instance=primary; Identity=[0-9a-f]{12}\]$' -and
        $resolvedCmsNames[1] -match 'sql2022-latest \(primary\) \[Run=22222222-2222-2222-2222-222222222222; Instance=primary; Identity=[0-9a-f]{12}\]$' -and
        (@($resolvedCmsNames) -join "`n") -eq (@($repeatedCmsNames) -join "`n"))
    Add-CheckResult -Name 'CMS-Namensauflosung bleibt sysname-begrenzt und bindet die volle Identitaet stabil' -Success (
        (Get-LabCmsManagedRegisteredServerDisplayName -Entry $longEntry -StateRoot 'unused').Length -le 128 -and
        (Get-LabCmsManagedRegisteredServerDisplayName -Entry $longEntry -StateRoot 'unused') -eq (Get-LabCmsManagedRegisteredServerDisplayName -Entry $longEntry -StateRoot 'unused') -and
        $source -match 'function Get-LabCmsIdentityDisplayName' -and
        $source -match 'SHA256.*Identity' -and
        $source -match 'Get-LabCmsManagedRegisteredServerDisplayName')
    $resolvedAliasGroups = @($collidingCmsEntries | ForEach-Object { Get-LabCmsEnvironmentGroupDisplayName -Entry $_ })
    Add-CheckResult -Name 'Kennwortalias-Ordner bleiben bei gleichem Namen pro Run eindeutig' -Success (
        $resolvedAliasGroups.Count -eq 2 -and
        @($resolvedAliasGroups | Select-Object -Unique).Count -eq 2 -and
        @($resolvedAliasGroups | Where-Object Length -gt 128).Count -eq 0)
    Add-CheckResult -Name 'Dieselbe Namensauflosung gilt mit und ohne Providergruppen' -Success (
        $source -match 'Get-LabCmsManagedRegisteredServerDisplayName -Entry \$entry' -and
        $source -match 'if \(\[bool\]\$center\.Grouping\.CmsGroupByProvider\)' -and
        $source -match '\$targetGroup = if \(\$runtimeState -eq ''RUNNING''\) \{ ''@RunningId'' \} else \{ ''@StoppedId'' \}')

    Add-CheckResult -Name 'Kennwortmodus verschachtelt genau einen Server unter seinem Umgebungsordner' -Success (
        $source -match 'Role=Environment' -and
        $source -match 'DECLARE @EnvironmentGroup_' -and
        $source -match 'Get-LabCmsEnvironmentGroupDisplayName' -and
        $source -match 'if \(\$IncludeGeneratedPassword\) \{ return \$displayName \}' -and
        $source -match '\$targetGroup = "@EnvironmentGroup_\$variableSuffix"' -and
        $source -match 'ManagedEnvironmentGroups_' -and
        $source -match 'CmsEnvironmentGroupCursor_')

    $newLabSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\New-SqlServerLab.ps1') -Raw -Encoding utf8
    $testEnvironmentSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\TestEnvironment.ps1') -Raw -Encoding utf8
    $consoleSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\Invoke-SqlServerLab.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Generierte Containerkennwoerter besitzen einen expliziten verschluesselten Herkunftsnachweis' -Success (
        $newLabSource -match '\[switch\]\$GenerateSaPassword' -and
        $newLabSource -match "-Name 'generated-sql-sa-password'" -and
        $newLabSource -match 'SA_PASSWORD_GENERATION_CONTAINER_PROVIDER_REQUIRED' -and
        $testEnvironmentSource -match '-GenerateSaPassword -NonInteractive' -and
        $consoleSource -match "-Name 'generated-sql-sa-password'")

    Add-CheckResult -Name 'Kennworthaltige Sync-Plaene sind fluechtig und Exporte bleiben kennwortfrei' -Success (
        $source -match 'PASSWORD_ALIAS_REQUIRES_IN_MEMORY_SCRIPT' -and
        $source -match '\$scriptContent = \$lines -join \[Environment\]::NewLine' -and
        $source -match "Invoke-LabCmsSqlInMemory -Query" -and
        $source -match '\[System\.Data\.SqlClient\.SqlConnection\]::new' -and
        $source -match '\$builder\[''Data Source''\]' -and
        $source -match '\$builder\[''TrustServerCertificate''\]' -and
        $source -match '\$command\.CommandText = \$Query' -and
        $source -match "Kennwortfreies CMS-Synchronisationsskript exportieren")

    Add-CheckResult -Name 'CMS-Kennwortanzeige ist kompatibel standardmaessig deaktiviert' -Success (
        $source -match "ConnectionCenterGroups/1\.2" -and
        $source -match 'CmsShowGeneratedPasswordInName = \$false' -and
        $source -match 'if \(\$null -eq \$saved\.CmsShowGeneratedPasswordInName\) \{ \$false \}')

    Add-CheckResult -Name 'CMS-Menue warnt vor Klartext und bewahrt manuelle Passwoerter' -Success (
        $source -match "Generiertes Passwort im CMS-Namen anzeigen" -and
        $source -match 'Klartext in CMS-Namen, SSMS-Ansichten, Screenshots und CMS-Backups' -and
        $source -match 'Manuell eingegebene und manifestbasierte Passwoerter bleiben immer ausgeschlossen')

    Add-CheckResult -Name 'SSMS-Exportmenue verwendet Lab_Data statt Benutzerprofil-Fallback' -Success (
        $source -match 'function Read-LabConnectionCenterSsmsExportPath' -and
        $source -match 'Join-Path \(Join-Path \$dataRoot ''Exports''\) ''sql-server-lab\.regsrvr''' -and
        $source -match 'State Root unter dem Benutzerprofil wird nicht als sichtbares Exportziel verwendet' -and
        $source -match 'Export-SqlServerLabSsmsRegistration -Path \$exportPath')

    $script:testDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'sql-lab-menu-data'
    $script:testExportInput = ''
    $script:testExportWarning = $null
    function Get-LabDataRootDefault { return $script:testDataRoot }
    function Read-Host { param([string]$Prompt) return $script:testExportInput }
    function Write-LabWarning { param([string]$Message) $script:testExportWarning = $Message }
    $defaultExportPath = Read-LabConnectionCenterSsmsExportPath
    Add-CheckResult -Name 'Leere Menueeingabe waehlt den portablen Lab_Data-Exportpfad' -Success (
        $defaultExportPath -eq (Join-Path (Join-Path $script:testDataRoot 'Exports') 'sql-server-lab.regsrvr'))

    $script:testDataRoot = $null
    $script:testExportInput = ''
    $cancelledExportPath = Read-LabConnectionCenterSsmsExportPath
    Add-CheckResult -Name 'Ohne Lab_Data entsteht kein stiller Benutzerprofil-Export' -Success (
        $null -eq $cancelledExportPath -and $script:testExportWarning -match 'Benutzerprofil')

    Add-CheckResult -Name 'CMS-In-Memory-Executor schreibt weder Query- noch Skriptdatei' -Success (
        $source -match 'function Invoke-LabCmsSqlInMemory' -and
        [regex]::Match($source, 'function Invoke-LabCmsSqlInMemory[\s\S]+?(?=\r?\nfunction Export-SqlServerLabCmsSyncScript)').Value -notmatch 'WriteAllText|WriteAllLines|GetTempFileName|sqlcmd')
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
