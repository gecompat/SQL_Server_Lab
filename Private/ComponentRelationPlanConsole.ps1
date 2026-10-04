# Guided, memory-only input for the existing component relation plan.
function Get-LabComponentRelationConsoleRuns {
    param([Parameter(Mandatory)][string]$DataRoot)
    $root=Assert-LabDiagnosticPath -Path $DataRoot
    $stateRoot=Join-Path $root 'State'
    $directory=Assert-LabDiagnosticPath -Path (Join-Path $stateRoot 'runs')
    if (-not [IO.Directory]::Exists($directory)) { throw 'COMPONENT_RELATION_BINDING_UNAVAILABLE' }
    $directories=@(Get-ChildItem -LiteralPath $directory -Directory -Force -ErrorAction Stop)
    if ($directories.Count -gt 64) { throw 'COMPONENT_RELATION_SCOPE_UNSUPPORTED' }
    foreach ($item in $directories | Sort-Object Name) {
        if (-not (Test-LabDiagnosticGuid $item.Name)) { continue }
        # Invalid/legacy runs are unavailable, never adopted or repaired by browsing.
        try { $binding=Read-LabComponentRelationBinding -RunId $item.Name -StateRoot $stateRoot }
        catch { continue }
        if ($binding.Run.state -ceq 'REMOVED') { continue }
        [pscustomobject]@{RunId=$binding.Run.runId;ScopeId=$binding.Run.scopeId;State=$binding.Run.state;
            StateRoot=$stateRoot;Digest=$binding.Digest;Instances=@($binding.Instances | ForEach-Object {
                [pscustomobject]@{Id=$_.Id;Provider=$_.Provider;Version=$_.Version}
            })}
    }
}

function Select-LabComponentRelationConsoleItem {
    param([string]$Title,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items)
    if (-not $Items.Count) { return $null }
    $selection=Invoke-LabConsoleMenu -ScreenId 'component-relation-choice' -Title $Title `
        -Subtitle 'Gespeicherte SQL-Instanzen; SQL-Bereitschaft nicht geprüft. Esc: Zurück.' -Items $Items
    if ($selection.Status -ne 'Selected') { return $null }
    $matched=@($Items | Where-Object Id -CEQ $selection.SelectedItem.Id)
    if ($matched.Count -ne 1) { throw 'COMPONENT_RELATION_TARGET_INVALID' }
    return $matched[0].Data
}

function Invoke-LabComponentRelationPlanInteractive {
    [CmdletBinding()]
    param()
    try {
        $rootInput=Read-LabConsoleTextInput -Prompt 'Vorhandenes registriertes Lab_Data-Verzeichnis (nur lesen)'
        if ($rootInput.Status -ne 'Confirmed') { return }
        $runs=@(Get-LabComponentRelationConsoleRuns -DataRoot ([string]$rootInput.Value))
        if (-not $runs.Count) {
            Write-LabInfo 'Keine vollständig gebundenen Container-Runs mit höchstens zwei SQL-Instanzen verfügbar.'
            $null=Wait-LabConsoleAcknowledgement
            return
        }
        $own=Select-LabComponentRelationConsoleItem -Title 'Lab für die Komponenten-Vorschau auswählen' -Items @(
            foreach ($run in $runs) {
                New-LabConsoleItem -Id $run.RunId -Label ($run.Instances.Id -join ', ') `
                    -Value ("Lab {0} · {1} · {2}" -f $run.RunId,$run.State,($run.Instances.Provider -join '/')) -Data $run
            }
        )
        if (-not $own) { return }
        $relations=[Collections.Generic.List[object]]::new()
        $shared=$null
        while ($true) {
            $menu=Invoke-LabConsoleMenu -ScreenId 'component-relation-preview' -Title 'SQL-Komponenten: reine Vorschau' `
                -Subtitle ("{0} Beziehungen · keine Speicherung oder Ausführung · Shared-SQL bleibt erhalten." -f $relations.Count) -Items @(
                    New-LabConsoleItem -Id add -Label 'SQL-Voraussetzung ergänzen' -Disabled:($relations.Count -ge 4) -DisabledReason 'Höchstens vier Beziehungen'
                    New-LabConsoleItem -Id preview -Label 'Vorschau anzeigen (SQL nicht geprüft)'
                    New-LabConsoleItem -Id back -Label 'Zurück / Abbrechen'
                )
            if ($menu.Status -ne 'Selected' -or $menu.SelectedItem.Id -ceq 'back') { return }
            if ($menu.SelectedItem.Id -ceq 'preview') {
                foreach ($selected in @($own,$shared) | Where-Object { $null -ne $_ }) {
                    $fresh=Read-LabComponentRelationBinding -RunId $selected.RunId -StateRoot $own.StateRoot
                    if ($fresh.Digest -cne $selected.Digest -or $fresh.Run.state -cne $selected.State) { throw 'COMPONENT_RELATION_BINDING_CHANGED' }
                }
                $plan=Get-SqlServerLabReconcilePlan -RunId $own.RunId -StateRoot $own.StateRoot -ProposedRelations @($relations.ToArray())
                Write-LabInfo 'PLAN_ONLY: keine Speicherung, Adoption oder Ausführung. SQL-Bereitschaft: NOT_CHECKED. Shared Removal: PRESERVE.'
                Write-LabInfo ("Ergebnis: {0} · {1} Beziehungen" -f $plan.Status,$plan.Desired.ProposedRelations.Count)
                foreach ($component in $plan.PrerequisiteOrder) {
                    Write-LabInfo ("{0} · Provider: {1} · {2} · {3}" -f $component.InstanceId,$component.Provider,$component.LifecycleState,$component.ManagementMode)
                }
                $null=Wait-LabConsoleAcknowledgement
                return
            }
            if ($menu.SelectedItem.Id -cne 'add' -or $relations.Count -ge 4) { throw 'COMPONENT_RELATION_INPUT_INVALID' }
            $source=Select-LabComponentRelationConsoleItem -Title 'Verbrauchende SQL-Instanz auswählen' -Items @(
                foreach ($instance in $own.Instances) {
                    New-LabConsoleItem -Id $instance.Id -Label $instance.Id -Value ("SQL {0} · {1}" -f $instance.Version,$instance.Provider) -Data $instance
                }
            )
            if (-not $source) { return }
            $targets=@(
                foreach ($run in $runs) {
                    if ($run.RunId -cne $own.RunId -and $shared -and $run.RunId -cne $shared.RunId) { continue }
                    foreach ($instance in $run.Instances) {
                        if ($run.RunId -ceq $own.RunId -and $instance.Id -ceq $source.Id) { continue }
                        if ($shared -and $run.RunId -ceq $shared.RunId -and $instance.Id -cne $shared.InstanceId) { continue }
                        $duplicate=@($relations | Where-Object { $_.SourceInstanceId -ceq $source.Id -and $_.Target.RunId -ceq $run.RunId -and $_.Target.InstanceId -ceq $instance.Id })
                        if ($duplicate.Count) { continue }
                        $target=[pscustomobject]@{RunId=$run.RunId;ScopeId=$run.ScopeId;InstanceId=$instance.Id;ManagementMode=if($run.RunId -ceq $own.RunId){'PROVISIONED'}else{'EXTERNAL_READ_ONLY'}}
                        New-LabConsoleItem -Id ($run.RunId+':'+$instance.Id) -Label $instance.Id `
                            -Value ("SQL {0} · {1} · {2}" -f $instance.Version,$instance.Provider,$(if($run.RunId -ceq $own.RunId){'im ausgewählten Lab'}else{'Shared-SQL: nur Referenz, bleibt erhalten'})) -Data $target
                    }
                }
            )
            $target=Select-LabComponentRelationConsoleItem -Title 'Benötigte SQL-Instanz auswählen' -Items $targets
            if (-not $target) { return }
            if ($target.RunId -cne $own.RunId -and -not $shared) {
                $shared=($runs | Where-Object RunId -CEQ $target.RunId | Select-Object -First 1).PSObject.Copy()
                $shared | Add-Member -NotePropertyName InstanceId -NotePropertyValue $target.InstanceId
            }
            $relations.Add([pscustomobject]@{SourceInstanceId=$source.Id;Type='requires-sql';Target=$target})
        }
    } catch {
        # Metadata/parser exception text can contain private paths or host values.
        $known=@('COMPONENT_RELATION_BINDING_CHANGED','COMPONENT_RELATION_CYCLE','COMPONENT_RELATION_TARGET_INVALID','COMPONENT_RELATION_SCOPE_UNSUPPORTED','COMPONENT_RELATION_INPUT_INVALID')
        $code=if($_.Exception.Message -cin $known){$_.Exception.Message}else{'COMPONENT_RELATION_BINDING_UNAVAILABLE'}
        Write-LabWarning ("{0}: Vorschau nicht verfügbar; Metadaten prüfen. Keine Änderung ausgeführt." -f $code)
        $null=Wait-LabConsoleAcknowledgement
    }
}
