#Requires -Version 7.2

function New-LabAttentionItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Critical','Warning','Info')][string]$Severity,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message,
        [string]$ActionHint = ''
    )

    [PSCustomObject]@{
        Id = $Id
        Severity = $Severity
        Category = $Category
        Message = $Message
        ActionHint = $ActionHint
    }
}

function Get-LabAttentionSnapshot {
    <#
    .SYNOPSIS
        Ermittelt offene Benutzeraktionen ohne Runtime-Mutation.
    .DESCRIPTION
        Liest ausschließlich Katalog-, Media-, State- und Hyper-V-Metadaten.
        Es werden keine Medien geladen, Slots erzeugt, Provider gestartet oder
        Cleanup-/Recovery-Aktionen ausgeführt.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(0, 100)][int]$MinimumReadySqlSlots = 2,
        [ValidateRange(0, 100)][int]$LowTemplateCapacity = 2
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $mediaRoot = Get-LabMediaRootDefault
    if (-not $mediaRoot) {
        $items.Add((New-LabAttentionItem -Id 'media-root-missing' -Severity Warning -Category 'Media' `
            -Message 'Kein Media Root konfiguriert; Windows- und SQL-Medien können nicht geprüft werden.' `
            -ActionHint 'Hauptmenü: Media Root konfigurieren.'))
    }

    $catalogDate = if ($script:VersionCatalog -and $script:VersionCatalog.catalogMetadata) { [string]$script:VersionCatalog.catalogMetadata.lastVerified } else { '' }
    $verifiedAt = [datetime]::MinValue
    if (-not [datetime]::TryParse($catalogDate, [ref]$verifiedAt)) {
        $items.Add((New-LabAttentionItem -Id 'cu-catalog-date-missing' -Severity Warning -Category 'CU' `
            -Message 'Der CU-Katalog besitzt kein gültiges Prüfdatum.' -ActionHint 'Monatlichen CU-Agent ausführen.'))
    }
    else {
        $catalogAge = [Math]::Max(0, ((Get-Date).Date - $verifiedAt.Date).Days)
        if ($catalogAge -gt 35) {
            $items.Add((New-LabAttentionItem -Id 'cu-catalog-stale' -Severity Warning -Category 'CU' `
                -Message "CU-Katalog seit $catalogAge Tagen nicht verifiziert (Stand $catalogDate)." `
                -ActionHint 'Monatlichen CU-Agent ausführen.'))
        }
    }

    foreach ($version in @($script:VersionCatalog.versions | Where-Object { [string]$_.status -eq 'SUPPORTED' -and $_.docker })) {
        try {
            $latestPatch = @(Get-SqlServerPatchOptions -VersionId ([string]$version.id) -MediaRoot $mediaRoot) | Select-Object -First 1
            if (-not $latestPatch) { continue }
            if ([string]$latestPatch.WindowsStatus -eq 'MISSING') {
                $items.Add((New-LabAttentionItem -Id "cu-media-$($version.id)-$($latestPatch.Cu)" -Severity Warning -Category 'CU-Media' `
                    -Message "SQL $($version.id) $($latestPatch.Cu) ist katalogisiert; Windows-Paket fehlt." `
                    -ActionHint ([string]$latestPatch.WindowsRelativePath)))
            }
            elseif ([string]$latestPatch.WindowsStatus -eq 'PRESENT_UNVERIFIED') {
                $items.Add((New-LabAttentionItem -Id "cu-media-unverified-$($version.id)-$($latestPatch.Cu)" -Severity Info -Category 'CU-Media' `
                    -Message "SQL $($version.id) $($latestPatch.Cu) ist vorhanden, aber ohne katalogisierten SHA-256-Wert." `
                    -ActionHint ([string]$latestPatch.WindowsRelativePath)))
            }
        }
        catch {
            $items.Add((New-LabAttentionItem -Id "cu-status-$($version.id)-unavailable" -Severity Warning -Category 'CU' `
                -Message "CU-Medienstatus für SQL $($version.id) konnte nicht gelesen werden." -ActionHint $_.Exception.Message))
        }
    }

    $activeRuns = @()
    try { $activeRuns = @(Get-LabActiveRuns) } catch { }
    $recoveryRuns = @($activeRuns | Where-Object { [string]$_.state -in @('RECOVERY_REQUIRED','CLEANUP_PENDING','CLEANUP_RUNNING') })
    if ($recoveryRuns.Count -gt 0) {
        $items.Add((New-LabAttentionItem -Id 'run-recovery-required' -Severity Critical -Category 'Recovery' `
            -Message "$($recoveryRuns.Count) Umgebung(en) benötigen Recovery oder Cleanup." `
            -ActionHint 'Cleanup-Audit im Hauptmenü öffnen.'))
    }

    if ($IsWindows) {
        $artifacts = @()
        try { $artifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck) } catch { }
        try {
            $templatePool = Get-HyperVTemplatePoolStatus -Artifacts $artifacts
            if ([int]$templatePool.AvailableTemplates -le $LowTemplateCapacity) {
                $severity = if ([int]$templatePool.AvailableTemplates -eq 0) { 'Critical' } else { 'Warning' }
                $items.Add((New-LabAttentionItem -Id 'template-pool-capacity-low' -Severity $severity -Category 'Templates' `
                    -Message "Vorlagenpool hat nur $($templatePool.AvailableTemplates) von $($templatePool.MaximumTemplates) Plätzen frei." `
                    -ActionHint 'Nicht mehr benötigte, unreferenzierte Vorlagen gezielt prüfen.'))
            }
        }
        catch { }

        $readySqlSlots = 0
        foreach ($run in @($activeRuns | Where-Object { [string]$_.metadata.workflowKind -eq 'hyperv-lab' })) {
            try {
                $lab = Get-HyperVLabWorkflowRun -RunId ([string]$run.runId)
                $plan = $lab.Instance.sqlDeploymentPlan
                if ($plan -and [string]$plan.deploymentMode -eq 'sql-pool-slot' -and [string]$plan.state -eq 'SQL_SLOT_READY') { $readySqlSlots++ }
            }
            catch { }
        }
        if ($readySqlSlots -lt $MinimumReadySqlSlots) {
            $severity = if ($readySqlSlots -eq 0) { 'Critical' } else { 'Warning' }
            $items.Add((New-LabAttentionItem -Id 'sql-slot-pool-low' -Severity $severity -Category 'Slots' `
                -Message "Nur $readySqlSlots fertige SQL-Pool-Slots; Mindestbestand ist $MinimumReadySqlSlots." `
                -ActionHint 'Bei Bedarf neue Slots über den Hyper-V-Pfad erzeugen.'))
        }

        $pendingWindowsBuilds = @()
        $pendingSqlBuilds = @()
        try { $pendingWindowsBuilds = @(Get-HyperVImageBuildPlans | Where-Object { [string]$_.state -notin @('OS_SEALED','TEST_ARTIFACT_PUBLISHED') }) } catch { }
        try { $pendingSqlBuilds = @(Get-HyperVSqlImageBuildPlans | Where-Object { [string]$_.state -notin @('SQL_PREPARED_SEALED','TESTS_PASSED') }) } catch { }
        if ($pendingWindowsBuilds.Count + $pendingSqlBuilds.Count -gt 0) {
            $items.Add((New-LabAttentionItem -Id 'image-builds-pending' -Severity Info -Category 'Builder' `
                -Message "$($pendingWindowsBuilds.Count) Windows- und $($pendingSqlBuilds.Count) SQL-Builder sind offen." `
                -ActionHint 'Hyper-V Windows-Image verwalten öffnen.'))
        }
    }

    $severityOrder = @{ Critical = 0; Warning = 1; Info = 2 }
    $ordered = @($items | Sort-Object @{ Expression={ $severityOrder[[string]$_.Severity] } }, Category, Id)
    [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        CatalogVerifiedAt = $catalogDate
        MediaRoot = $mediaRoot
        AttentionItems = $ordered
        Count = $ordered.Count
        HasAttention = $ordered.Count -gt 0
    }
}

function Update-LabConsoleAttentionSnapshot {
    [CmdletBinding()]
    param()

    $script:LabConsoleAttentionSnapshot = Get-LabAttentionSnapshot
    return $script:LabConsoleAttentionSnapshot
}

function Get-LabConsoleAttentionSnapshot {
    [CmdletBinding()]
    param()

    if (-not $script:LabConsoleAttentionSnapshot) {
        $script:LabConsoleAttentionSnapshot = Get-LabAttentionSnapshot
    }
    return $script:LabConsoleAttentionSnapshot
}
