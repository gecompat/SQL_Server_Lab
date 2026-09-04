function Get-SqlServerLabMaintenancePlan {
    <#
    .SYNOPSIS
        Plant einen schnellen oder vollständigen SQL_Server_Lab-Soll/Ist-Abgleich.
    .DESCRIPTION
        Inventarisiert gespeicherten Run-State sowie alle vorhandenen Docker-,
        Podman- und Hyper-V-Ressourcen. Fremde Ressourcen werden ignoriert.
        Der Befehl mutiert weder State noch Runtime. Full ergänzt den rekursiven
        Storage- und Cleanup-Audit; Runtime ist für regelmäßige Prüfungen gedacht.
    .PARAMETER Mode
        Runtime führt nur den schnellen Runtime-/State-Abgleich aus. Full ergänzt
        Get-SqlServerLabCleanupAudit.
    .PARAMETER StaleAfterMinutes
        Mindestalter eines unvollständigen Runs ohne gebundene Runtime, bevor
        dessen scopegebundener Cleanup angeboten wird.
    .PARAMETER StateRoot
        Optionaler abweichender State-Root.
    .OUTPUTS
        PSCustomObject mit Vertragsversion, Inventarzusammenfassung, Aktionen
        und optionalem vollständigem Cleanup-Audit.
    .EXAMPLE
        $plan = Get-SqlServerLabMaintenancePlan
        $plan.Actions | Format-Table
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Runtime','Full')][string]$Mode='Runtime',
        [ValidateRange(5,10080)][int]$StaleAfterMinutes=60,
        [string]$StateRoot
    )
    Get-LabMaintenancePlanCore -Mode $Mode -StaleAfterMinutes $StaleAfterMinutes -StateRoot $StateRoot
}

function Invoke-SqlServerLabMaintenance {
    <#
    .SYNOPSIS
        Führt einen zuvor erzeugten SQL_Server_Lab-Maintenance-Plan aus.
    .DESCRIPTION
        Safe führt ausschließlich eindeutige State-Synchronisation und
        abgelaufene, vollständig identifizierte Testartefakte aus. Cleanup
        ergänzt scopegebundene Orphan- und Run-Cleanup-Aktionen. Alte
        Testartefakte ohne vollständige Run-/Scope-Identität benötigen immer
        AllowLegacyTestArtifactRemoval. Jede Ressource wird unmittelbar vor
        der Mutation erneut inventarisiert und gegen ihren Fingerprint geprüft.
        Cleanup entfernt außerdem abgelaufene, eindeutig benannte Testobjekte
        direkt im tatsächlichen Benutzer-Temp; andere Tempobjekte bleiben unberührt.
    .PARAMETER Plan
        Ergebnis von Get-SqlServerLabMaintenancePlan.
    .PARAMETER Mode
        Safe oder Cleanup.
    .PARAMETER AllowLegacyTestArtifactRemoval
        Erlaubt im Cleanup-Modus die Entfernung gestoppter Legacy-Testcontainer
        ohne Bind-Mounts und ausgeschalteter Legacy-Test-VMs in einem exklusiven
        registrierten Lab_Data/HyperV/Runs-Root.
    .PARAMETER StateRoot
        Optionaler abweichender State-Root.
    .OUTPUTS
        PSCustomObject mit Aktionsresultaten, Fehlerzahl und einem frisch
        erzeugten Plan der noch verbleibenden Abweichungen.
    .EXAMPLE
        $plan = Get-SqlServerLabMaintenancePlan
        Invoke-SqlServerLabMaintenance -Plan $plan -Mode Safe -WhatIf
    .EXAMPLE
        Invoke-SqlServerLabMaintenance -Plan $plan -Mode Cleanup -AllowLegacyTestArtifactRemoval
    #>
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)]$Plan,
        [ValidateSet('Safe','Cleanup')][string]$Mode='Safe',
        [switch]$AllowLegacyTestArtifactRemoval,
        [string]$StateRoot
    )
    if([string]$Plan.ContractVersion -ne 'SqlServerLab.MaintenancePlan/1.0'){throw 'MAINTENANCE_PLAN_CONTRACT_UNSUPPORTED'}
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $results=[Collections.Generic.List[object]]::new()
    foreach($action in @($Plan.Actions)) {
        $eligible=$action.Disposition -eq 'SAFE_AUTOMATIC' -or
            ($Mode -eq 'Cleanup' -and $action.Disposition -eq 'SCOPED_CLEANUP') -or
            ($Mode -eq 'Cleanup' -and $AllowLegacyTestArtifactRemoval -and $action.Disposition -eq 'EXPLICIT_LEGACY_APPROVAL')
        if(-not $eligible) {
            $results.Add([PSCustomObject]@{ActionId=$action.ActionId;ActionType=$action.ActionType;Status='SKIPPED_POLICY';Name=$action.Name;RunId=$action.RunId})
            continue
        }
        $target=if($action.Name){[string]$action.Name}else{[string]$action.RunId}
        if(-not $PSCmdlet.ShouldProcess($target,[string]$action.ActionType)) {
            $results.Add([PSCustomObject]@{ActionId=$action.ActionId;ActionType=$action.ActionType;Status='PLANNED';Name=$action.Name;RunId=$action.RunId})
            continue
        }
        try {
            $result=switch([string]$action.ActionType) {
                'SYNC_RUNTIME_STATE' {
                    $currentRun=Get-LabRunState -RunId ([string]$action.RunId) -StateRoot $StateRoot
                    if(-not $currentRun -or [string]$currentRun.scopeId -ne [string]$action.ScopeId){throw 'RUN_SCOPE_REVALIDATION_FAILED'}
                    Sync-SqlServerLabRuntimeState -RunId ([string]$action.RunId) -StateRoot $StateRoot -Confirm:$false
                }
                'MARK_RECOVERY_REQUIRED' {
                    $currentRun=Get-LabRunState -RunId ([string]$action.RunId) -StateRoot $StateRoot
                    if(-not $currentRun -or [string]$currentRun.scopeId -ne [string]$action.ScopeId){throw 'RUN_SCOPE_REVALIDATION_FAILED'}
                    Sync-SqlServerLabRuntimeState -RunId ([string]$action.RunId) -StateRoot $StateRoot -Confirm:$false
                }
                'RETRY_RUN_CLEANUP' {
                    $currentRun=Get-LabRunState -RunId ([string]$action.RunId) -StateRoot $StateRoot
                    if(-not $currentRun){[PSCustomObject]@{Status='ALREADY_ABSENT';RunId=$action.RunId};break}
                    if([string]$currentRun.scopeId -ne [string]$action.ScopeId){throw 'RUN_SCOPE_REVALIDATION_FAILED'}
                    Remove-SqlServerLab -RunId ([string]$action.RunId) -StateRoot $StateRoot -Force -Confirm:$false
                }
                'REMOVE_STALE_TEST_TEMP_ARTIFACTS' { Remove-LabStaleTestTempArtifacts -Action $action }
                'REMOVE_ORPHAN_CONTAINER' {
                    $inventory=Get-LabMaintenanceContainerInventory -Provider ([string]$action.Provider)
                    $current=@($inventory.Resources|Where-Object { [string]$_.ResourceId -eq [string]$action.ResourceId }|Select-Object -First 1)[0]
                    if(-not $current){[PSCustomObject]@{Status='ALREADY_ABSENT';Name=$action.Name};break}
                    $known=@(Get-LabActiveRuns -StateRoot $StateRoot|ForEach-Object {[string]$_.runId})
                    if($current.Classification -ne 'LAB_BOUND' -or $current.RunId -in $known -or $current.ScopeId -ne [string]$action.ScopeId -or $current.Fingerprint -ne [string]$action.Fingerprint){throw 'ORPHAN_CONTAINER_REVALIDATION_FAILED'}
                    if($action.Provider -eq 'docker'){Remove-DockerInstance -ContainerIdOrName $current.ResourceId -ExpectedScopeId $current.ScopeId}
                    else{Remove-PodmanInstance -ContainerIdOrName $current.ResourceId -ExpectedScopeId $current.ScopeId}
                    [PSCustomObject]@{Status='REMOVED';Name=$current.Name}
                }
                'REMOVE_ORPHAN_HYPERV' {
                    $inventory=Get-LabMaintenanceHyperVInventory
                    $current=@($inventory.Resources|Where-Object { [string]$_.ResourceId -eq [string]$action.ResourceId }|Select-Object -First 1)[0]
                    if(-not $current){[PSCustomObject]@{Status='ALREADY_ABSENT';Name=$action.Name};break}
                    $known=@(Get-LabActiveRuns -StateRoot $StateRoot|ForEach-Object {[string]$_.runId})
                    if($current.Classification -ne 'LAB_BOUND' -or $current.RunId -in $known -or $current.ScopeId -ne [string]$action.ScopeId -or $current.Fingerprint -ne [string]$action.Fingerprint){throw 'ORPHAN_HYPERV_REVALIDATION_FAILED'}
                    Remove-HyperVInstance -VMName $current.Name -ExpectedScopeId $current.ScopeId -ExpectedRunDirectory $current.ResourceRoot
                }
                'REMOVE_LEGACY_TEST_CONTAINER' { Remove-LabLegacyTestContainer -Provider ([string]$action.Provider) -Action $action }
                'REMOVE_LEGACY_TEST_HYPERV' { Remove-LabLegacyTestHyperV -Action $action }
                default { throw "MAINTENANCE_ACTION_UNSUPPORTED: $($action.ActionType)" }
            }
            $status=if($result -and $result.PSObject.Properties['Status']){[string]$result.Status}else{'COMPLETED'}
            $results.Add([PSCustomObject]@{ActionId=$action.ActionId;ActionType=$action.ActionType;Status=$status;Name=$action.Name;RunId=$action.RunId;Result=$result})
        }
        catch {
            $results.Add([PSCustomObject]@{ActionId=$action.ActionId;ActionType=$action.ActionType;Status='FAILED';Name=$action.Name;RunId=$action.RunId;Error=$_.Exception.Message})
        }
    }
    $failed=@($results|Where-Object Status -eq 'FAILED').Count
    $remaining=Get-SqlServerLabMaintenancePlan -Mode Runtime -StaleAfterMinutes ([int]$Plan.StaleAfterMinutes) -StateRoot $StateRoot
    [PSCustomObject]@{
        ContractVersion='SqlServerLab.MaintenanceResult/1.0';PlanId=[string]$Plan.PlanId
        Status=if($failed -gt 0){'PARTIAL'}elseif(@($results|Where-Object Status -eq 'PLANNED').Count -gt 0){'PLANNED'}else{'COMPLETED'}
        Completed=@($results|Where-Object Status -notin @('FAILED','SKIPPED_POLICY','PLANNED')).Count
        Skipped=@($results|Where-Object Status -eq 'SKIPPED_POLICY').Count;Failed=$failed;Actions=@($results);RemainingPlan=$remaining
    }
}
