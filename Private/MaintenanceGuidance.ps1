# Guided audit and catalog-only recovery. Neither audit classification nor a
# missing catalog record grants permission to delete or to adopt a volume.
function Get-LabMaintenanceGuidanceSources {
    [CmdletBinding()]
    param([string]$StateRoot, $Configuration)
    $candidates = [Collections.Generic.List[object]]::new()
    $evidence = [Collections.Generic.List[object]]::new()
    $activeStorageIds = [Collections.Generic.List[string]]::new()
    $blocked = $false
    $runs = Join-Path $StateRoot 'runs'
    if (Test-Path -LiteralPath $runs) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $runs -Directory -Force -ErrorAction Stop | Sort-Object Name)) {
            try {
                $runPath = Join-Path $directory.FullName 'run-state.json'
                $json = Get-Content -LiteralPath $runPath -Raw -ErrorAction Stop
                $run = $json | ConvertFrom-Json -Depth 50 -ErrorAction Stop
                $id = [guid]::Empty
                if (-not [guid]::TryParseExact($directory.Name,'D',[ref]$id) -or
                    [string]$run.runId -cne $directory.Name -or -not $run.state -or -not $run.scopeId) { throw 'MAINTENANCE_STATE_UNVERIFIABLE' }
                $evidence.Add(@($directory.Name, (Get-LabRetainedStoreHash $json)))
                if ($run.state -notin @('REMOVED','CLEANED_UP')) {
                    $desired = Get-LabPersistedDesiredState -RunId $run.runId -StateRoot $StateRoot
                    if ($desired.Status -cne 'VALID') { $blocked=$true; continue }
                    foreach ($drive in @($desired.Snapshot.Instances | ForEach-Object { @($_.Intents.Drives) })) {
                        if ($drive.PersistentStorageId) { $activeStorageIds.Add([string]$drive.PersistentStorageId) }
                    }
                    continue
                }
                $connectionPath = Join-Path $directory.FullName 'connection-info.json'
                if (-not (Test-Path -LiteralPath $connectionPath)) { continue }
                $connection = Get-Content -LiteralPath $connectionPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50 -ErrorAction Stop
                foreach ($instance in @($connection.instances)) {
                    if ($instance.provider -notin @('docker','podman') -or -not $instance.persistentStorage.persistentStorageId) { continue }
                    try {
                        $source = Get-LabContainerStoreRecoverySource -OriginalRunId $directory.Name -InstanceId $instance.id `
                            -PersistentStorageId $instance.persistentStorage.persistentStorageId -StateRoot $StateRoot -Configuration $Configuration
                        $candidateId = Get-LabRetainedStoreHash @($Configuration.ControllerId,$source.RunId,$source.InstanceId,$source.PersistentStorageId)
                        $candidates.Add([pscustomobject]@{ Id=$candidateId; Source=$source })
                    }
                    catch { } # Unsupported sources remain audit findings, never repair candidates.
                }
            }
            catch { $blocked = $true }
        }
    }
    [pscustomobject]@{ Candidates=@($candidates); Incomplete=$blocked; StateEvidence=@($evidence); ActiveStorageIds=@($activeStorageIds) }
}

function Get-LabMaintenanceRepairAuthority {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$CandidateId, [string]$DataRoot, [string]$StateRoot)
    $root = Resolve-LabDataRootForUse -DataRoot $DataRoot
    $configuration = Get-LabStorageConfiguration -DataRoot $root
    $state = Get-LabCanonicalResourceRoot -StateRoot (Get-LabStateRoot -ExplicitPath $StateRoot)
    $sources = Get-LabMaintenanceGuidanceSources -StateRoot $state -Configuration $configuration
    if ($sources.Incomplete) { throw 'MAINTENANCE_REFERENCE_INVENTORY_INCOMPLETE' }
    $matches = @($sources.Candidates | Where-Object Id -CEQ $CandidateId)
    if ($matches.Count -ne 1) { throw 'MAINTENANCE_CANDIDATE_UNRESOLVED' }
    $source = $matches[0].Source
    if ($source.PersistentStorageId -cin $sources.ActiveStorageIds) { throw 'MAINTENANCE_ACTIVE_REFERENCE' }
    $run = Get-LabRunState -RunId $source.RunId -StateRoot $state
    if (@($run.providerSubRuns | Where-Object { $_ -and [string]$_.state -cnotin @('REMOVED','CLEANED_UP') }).Count) { throw 'MAINTENANCE_RECOVERY_REQUIRED' }
    $protection = @()
    foreach ($location in @($configuration.LabDataLocations | Sort-Object LocationId)) {
        # Read the actual registry directly: the convenience RunIds reader
        # deliberately swallows errors and therefore cannot authorize repair.
        $registry = Get-LabTestEnvironmentRegistry -OutputDirectory (Join-Path $location.LabDataRoot 'Exports')
        if ($registry.environments -isnot [array]) { throw 'MAINTENANCE_REGISTRY_UNVERIFIABLE' }
        foreach ($entry in $registry.environments) {
            $registeredId=[guid]::Empty
            if ($entry -isnot [pscustomobject] -or ($entry.runId -and -not [guid]::TryParseExact([string]$entry.runId,'D',[ref]$registeredId))) { throw 'MAINTENANCE_REGISTRY_UNVERIFIABLE' }
        }
        if (@($registry.environments | Where-Object runId -EQ $source.RunId).Count) { throw 'MAINTENANCE_PROTECTED_GROUP' }
        $protection += Get-LabRetainedStoreHash $registry.environments
    }
    $directory = Join-Path (Join-Path $state 'runs') $source.RunId
    $recoveryEvidence = @()
    foreach ($journal in @(Get-ChildItem -LiteralPath $directory -File -Filter '*journal*.json' -ErrorAction Stop | Sort-Object Name)) {
        $document = Get-Content -LiteralPath $journal.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 50 -ErrorAction Stop
        if ([string]$document.Status -cnotin @('COMPLETED','ROLLED_BACK')) { throw 'MAINTENANCE_RECOVERY_REQUIRED' }
        $recoveryEvidence += @($journal.Name,(Get-FileHash -LiteralPath $journal.FullName -Algorithm SHA256).Hash)
    }
    # Capacity is a live observation, not catalog/root authority. Native probes
    # and unrelated host writes may change it between preview and apply.
    $locationAuthority=@(foreach ($location in $configuration.LabDataLocations) {
        $identity=[ordered]@{}
        foreach ($name in @($location.PSObject.Properties.Name | Where-Object { $_ -cne 'FreeBytes' } | Sort-Object)) {
            $identity[$name]=$location.$name
        }
        [pscustomobject]$identity
    })
    $authorityKey = Get-LabRetainedStoreHash ([ordered]@{
        DataRoot=(Get-LabCanonicalResourceRoot -StateRoot $root); StateRoot=$state; Controller=$configuration.ControllerId
        Locations=$locationAuthority; Source=$source; StateEvidence=$sources.StateEvidence
        Protection=$protection; Recovery=$recoveryEvidence
    })
    [pscustomobject]@{Configuration=$configuration; StateRoot=$state; DataRoot=$root; Source=$source; Key=$authorityKey}
}

function Get-LabMaintenanceRepairPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$CandidateId, [string]$DataRoot, [string]$StateRoot)
    $authority = Get-LabMaintenanceRepairAuthority -CandidateId $CandidateId -DataRoot $DataRoot -StateRoot $StateRoot
    $source=$authority.Source; $configuration=$authority.Configuration; $state=$authority.StateRoot; $root=$authority.DataRoot
    $store = [pscustomobject]@{
        PersistentStorageId=$source.PersistentStorageId; Provider=$source.Provider
        LocationBinding=[pscustomobject]@{ ProviderResourceId=$source.VolumeName }
        RuntimeBinding=$null
    }
    $observation = Get-LabRetainedStoreObservation -Store $store -Configuration $configuration -StateRoot $state
    $preview = Repair-LabContainerStoreCatalog -Source $source -StateRoot $state -RuntimeScopeId $observation.Context.RuntimeScopeId `
        -Configuration $configuration -Preview
    if ($preview.Store.Deletion) { throw 'MAINTENANCE_PENDING_DELETION' }
    $key = Get-LabRetainedStoreHash ([ordered]@{
        Authority=$authority.Key; Volume=$observation.VolumeFingerprint
        RuntimeScope=$observation.Context.RuntimeScopeId; Revision=$preview.CatalogRevision
        Store=$preview.Store.PersistentStorageId
    })
    [pscustomobject]@{
        CandidateId=$CandidateId; ExpectedKey=$key; Status=$(if ($preview.Changed) {'READY'} else {'NO_CHANGE'})
        Provider=$source.Provider; InstanceId=$source.InstanceId
        Notice='Nur fehlende Katalogzuordnung ergänzen. Keine Daten-, Runtime-, Lösch- oder Lifecycleänderung.'
        # Private authority is never serialized by the HTTP/CLI projection.
        Configuration=$configuration; StateRoot=$state; DataRoot=$root; Source=$source
        AuthorityKey=$authority.Key
        Observation=$observation; CatalogRevision=$preview.CatalogRevision
    }
}

function ConvertTo-LabMaintenanceRepairView {
    param([Parameter(Mandatory)]$Plan)
    [pscustomobject]@{CandidateId=$Plan.CandidateId; ExpectedKey=$Plan.ExpectedKey; Status=$Plan.Status;
        Provider=$Plan.Provider; InstanceId=$Plan.InstanceId; Notice=$Plan.Notice}
}

function Invoke-LabMaintenanceRepair {
    [CmdletBinding()]
    param([string]$CandidateId, [string]$ExpectedKey, [switch]$Confirmed, [string]$DataRoot, [string]$StateRoot)
    if (-not $Confirmed) { return [pscustomobject]@{Status='CANCELLED'; Changed=$false} }
    if ($ExpectedKey -cnotmatch '^[a-f0-9]{64}$') { throw 'MAINTENANCE_PREVIEW_REQUIRED' }
    $root = Resolve-LabDataRootForUse -DataRoot $DataRoot
    $configuration = Get-LabStorageConfiguration -DataRoot $root
    # Registry writers already acquire their group lock before touching catalog
    # state. Preserve that order; canonical sorted roots avoid cross-root cycles.
    $registryRoots=@($configuration.LabDataLocations | ForEach-Object {
        Get-LabCanonicalResourceRoot -StateRoot (Join-Path $_.LabDataRoot 'Exports')
    } | Sort-Object -Unique)
    $locks=[Collections.Generic.List[object]]::new()
    try {
        foreach ($registryRoot in $registryRoots) { $locks.Add((Enter-LabTestGroupLock -OutputDirectory $registryRoot)) }
        Invoke-LabPersistentStorageCatalogLock -ControllerId $configuration.ControllerId -ScriptBlock {
        $fresh = Get-LabMaintenanceRepairPlan -CandidateId $CandidateId -DataRoot $DataRoot -StateRoot $StateRoot
        if ($fresh.Configuration.ControllerId -cne $configuration.ControllerId -or $fresh.ExpectedKey -cne $ExpectedKey) { throw 'MAINTENANCE_PREVIEW_STALE' }
        $freshRegistryRoots=@($fresh.Configuration.LabDataLocations | ForEach-Object { Get-LabCanonicalResourceRoot -StateRoot (Join-Path $_.LabDataRoot 'Exports') } | Sort-Object -Unique)
        if (($registryRoots -join '|') -cne ($freshRegistryRoots -join '|')) { throw 'MAINTENANCE_REGISTRY_AUTHORITY_CHANGED' }
        $readAuthority=${function:Get-LabMaintenanceRepairAuthority}
        $authorityKey=$fresh.AuthorityKey
        $boundCandidate=$CandidateId; $requestedRoot=$DataRoot; $requestedState=$StateRoot
        $beforeCommit={
            $latest=& $readAuthority -CandidateId $boundCandidate -DataRoot $requestedRoot -StateRoot $requestedState
            if ($latest.Key -cne $authorityKey) { throw 'MAINTENANCE_AUTHORITY_CHANGED' }
        }.GetNewClosure()
        if ($fresh.Status -eq 'NO_CHANGE') {
            & $beforeCommit
            return [pscustomobject]@{Status='NO_CHANGE'; Changed=$false}
        }
        $result = Repair-LabContainerStoreCatalog -Source $fresh.Source -StateRoot $fresh.StateRoot `
            -RuntimeScopeId $fresh.Observation.Context.RuntimeScopeId -Configuration $fresh.Configuration `
            -ExpectedRevision $fresh.CatalogRevision -ExpectedObservation ([pscustomobject]@{
                RuntimeScopeId=$fresh.Observation.Context.RuntimeScopeId; Source=$fresh.Observation.Source; VolumeFingerprint=$fresh.Observation.VolumeFingerprint
            }) -BeforeCatalogCommit $beforeCommit
        [pscustomobject]@{Status=$(if ($result.Changed) {'RECOVERED'} else {'NO_CHANGE'}); Changed=[bool]$result.Changed}
        }
    }
    finally {
        for ($index=$locks.Count-1; $index -ge 0; $index--) { Exit-LabTestGroupLock -Mutex $locks[$index] }
    }
}

function Get-LabMaintenanceGuidanceView {
    [CmdletBinding()]
    param([string]$DataRoot, [string]$StateRoot)
    $audit = (Get-SqlServerLabCleanupAudit -NoWrite -DataRoot $DataRoot -StateRoot $StateRoot).Audit
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($finding in @($audit.Findings.Retained) + @($audit.Findings.UnexpectedResiduals) + @($audit.Findings.RecoveryRequired) + @($audit.Findings.Unverifiable)) {
        if (-not $finding) { continue }
        $rows.Add([pscustomobject]@{Id=('finding-' + $rows.Count); CandidateId=$null; Label=($finding.Provider + ' · ' + $finding.Category + ' · ' + ($rows.Count + 1))
            Fields=@([pscustomobject]@{Label='Befund';Value=[string]$finding.ReasonCode},
                [pscustomobject]@{Label='Herkunft / Nutzung';Value='Auditbefund; fehlende Registrierung oder unbekannte Runtime beweist keine Fremdzuordnung und keine freie Nutzung.'},
                [pscustomobject]@{Label='Löschbarkeit';Value='Nicht freigegeben; bestehende Retention-, Ownership- und Recoverygrenzen gelten.'},
                [pscustomobject]@{Label='Nächster Schritt';Value=[string]$finding.Guidance})})
    }
    foreach ($item in @($audit.StorageResidency.Objects)) {
        $store = @($audit.PersistentStorage.Catalog.Stores | Where-Object { $_.LocationBinding.InventoryObjectId -ceq $item.ObjectId })
        $provenance = if ($store.Count -eq 1) {'Katalogzuordnung vorhanden; noch keine native Ownershipfreigabe'} else {'Unbekannt / nicht katalogisiert; kein Fremd- oder Löschbarkeitsnachweis'}
        $usage = if (@($store | Where-Object { $_.Lease -or @($_.References | Where-Object State -EQ 'ACTIVE').Count }).Count) {'Aktive Katalogreferenz oder Lease: bewahren'} else {'Keine aktive Katalogreferenz belegt; tatsächliche Nutzung unbekannt'}
        $rows.Add([pscustomobject]@{ Id=$item.ObjectId; Label=($item.Provider + ' · ' + $item.ObjectClass + ' · ' + ($rows.Count + 1)); CandidateId=$null
            Fields=@(
                [pscustomobject]@{Label='Stabile Inventarreferenz';Value=[string]$item.ObjectId},
                [pscustomobject]@{Label='Befund';Value=[string]$item.AuditStatus},
                [pscustomobject]@{Label='Herkunft';Value=$provenance},
                [pscustomobject]@{Label='Nutzung';Value=$usage},
                [pscustomobject]@{Label='Löschbarkeit';Value='Nicht freigegeben. Audit und Orphan-Kandidat sind keine Löschautorisierung.'},
                [pscustomobject]@{Label='Nächster Schritt';Value='Zuordnung und Nutzung prüfen. Retained-Löschung ausschließlich im separaten Plan-/Resume-Verfahren.'}
            ) })
    }
    $configuration = Get-LabStorageConfiguration -DataRoot $DataRoot
    $sources = Get-LabMaintenanceGuidanceSources -StateRoot $audit.StateRoot -Configuration $configuration
    foreach ($candidate in $sources.Candidates) {
        $rows.Add([pscustomobject]@{Id=$candidate.Id; CandidateId=$candidate.Id; Label=($candidate.Source.Provider + ' · SQL-Speicherzuordnung · ' + $candidate.Source.InstanceId + ' · ' + $candidate.Source.PersistentStorageId.Substring(0,8))
            Fields=@([pscustomobject]@{Label='Herkunft';Value='Terminaler ursprünglicher Run und moderner SQL-Speichervertrag vorhanden'},
                [pscustomobject]@{Label='Speicherreferenz';Value=$candidate.Source.PersistentStorageId},
                [pscustomobject]@{Label='Ursprünglicher Run';Value=$candidate.Source.RunId},
                [pscustomobject]@{Label='Instanz / SQL-Version';Value=($candidate.Source.InstanceId + ' / ' + $candidate.Source.SqlMajorVersion)},
                [pscustomobject]@{Label='Nutzung';Value='Erst in ausdrücklicher Vorschau nativ zu prüfen'},
                [pscustomobject]@{Label='Nächster Schritt';Value='Katalogzuordnung separat vorprüfen; Konflikte, unbekannte Nutzung oder Recovery sperren die Reparatur.'})})
    }
    $incomplete = $sources.Incomplete -or @($audit.StateReadIssues).Count -gt 0
    [pscustomobject]@{Rows=@($rows); Incomplete=$incomplete; GeneratedAt=$audit.CreatedAt
        Notice='Read-only Befunde. Herkunft, aktuelle Nutzung und Löschbarkeit sind getrennt; unregistriert bedeutet unbekannt. Keine automatische Reparatur oder Löschung.'
        InventoryStatus=$(if ($incomplete) {'Run-/Referenzinventur unvollständig: Reparatur gesperrt.'} else {'Runinventur lesbar; Provider- und Ownershipnachweise bleiben getrennt.'})
        UnavailableProviders=[int]$audit.Summary.UnverifiableProviders
    }
}

function Show-LabMaintenanceGuidanceInteractive {
    [CmdletBinding()]
    param()
    $view = $null; $message = 'Befunde ausdrücklich lesen. Keine automatische Reparatur oder Löschung.'; $outcome='NoChange'
    while ($true) {
        $selection = Invoke-LabConsoleMenu -ScreenId 'maintenance-guidance' -Title 'Wartungsbefunde und Zuordnung' -Subtitle $message -Items @(
            New-LabConsoleItem -Id read -Label 'Befunde lesen / aktualisieren' -Shortcut r
            if ($view) { foreach ($row in $view.Rows) { New-LabConsoleItem -Id $row.Id -Label $row.Label -Data $row } }
            New-LabConsoleItem -Id back -Label 'Zurück' -Shortcut 0
        )
        if ($selection.Status -eq 'Cancelled') { return New-LabActionResult -Action CleanupAudit -Status $outcome }
        if ($selection.Status -eq 'Refresh' -or ($selection.Status -eq 'Selected' -and $selection.SelectedItem.Id -eq 'read')) {
            try { $view = Get-LabMaintenanceGuidanceView; $message = "$($view.Rows.Count) Befunde · $($view.InventoryStatus) · $($view.UnavailableProviders) Provider nicht vollständig prüfbar" }
            catch { $view=$null; $message='Befunde nicht verfügbar. Keine sichere Aussage; Konfiguration und Leserechte prüfen.' }
            continue
        }
        if ($selection.Status -ne 'Selected') { continue }
        if ($selection.SelectedItem.Id -eq 'back') { return New-LabActionResult -Action CleanupAudit -Status $outcome }
        $row=$selection.SelectedItem.Data
        if (-not $row -or -not $view) { continue }
        Write-Host $view.Notice
        foreach ($field in $row.Fields) { Write-Host ("{0}: {1}" -f $field.Label,$field.Value) }
        if ($row.CandidateId -and -not $view.Incomplete) {
            if (Read-LabConfirm -Prompt 'Nur Katalogzuordnung vorprüfen?' -Default $false) {
                try {
                    $plan=Get-LabMaintenanceRepairPlan -CandidateId $row.CandidateId
                    Write-Host ("{0} · {1}" -f $plan.Status,$plan.Notice)
                    if ($plan.Status -eq 'READY' -and (Read-LabConfirm -Prompt 'Diese fehlende Katalogzuordnung jetzt ergänzen?' -Default $false)) {
                        $result=Invoke-LabMaintenanceRepair -CandidateId $plan.CandidateId -ExpectedKey $plan.ExpectedKey -Confirmed
                        Write-Host ("Katalogergebnis: {0}" -f $result.Status)
                        if ($result.Changed) { $outcome='Changed' }
                        $view=$null; $message='Ergebnis erhalten. Befunde erneut lesen.'
                    }
                }
                catch { $outcome='Failed'; Write-Host 'Zuordnung nicht bestätigt. Schutz, Nutzung, Recovery und aktuellen Katalog prüfen; vor Wiederholung neu vorprüfen.' }
            }
        }
        $null=Wait-LabConsoleAcknowledgement -Prompt 'Enter oder Escape: Zurück zur Auswahl'
    }
}
