function Move-SqlServerLabContainerNetwork {
    <#
    .SYNOPSIS
        Verschiebt verwaltete Docker- oder Podman-Container auf ein konfliktfreies Labnetz.
    .DESCRIPTION
        Erkennt einen Konflikt des bestehenden Labnetzes, migriert ausschliesslich
        gelabelte SQL_Server_Lab-Container und bewahrt ein lokales Recovery-Journal.
        Fremde Container werden nicht verändert und können die Migration blockieren.
    .PARAMETER Provider
        Der zu migrierende Containerprovider Docker oder Podman.
    .PARAMETER StateRoot
        Optionaler lokaler State Root. Ohne Angabe wird der konfigurierte
        Standard-State-Root verwendet.
    .PARAMETER ExpectedPlanKey
        Optionaler Fingerabdruck einer zuvor gelesenen Netzvorschau.
        Eine geänderte Runtime-Bindung sperrt die Ausführung.
    .OUTPUTS
        PSCustomObject mit read-only Migrationsplan oder dem Ergebnis der
        ausgefuehrten Migration einschliesslich Recovery-Status.
    .EXAMPLE
        Move-SqlServerLabContainerNetwork -Provider podman -WhatIf

        Zeigt eine erforderliche Podman-Netzmigration ohne Runtime-Mutation.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
        [ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedPlanKey,
        [string]$StateRoot
    )

    $plan = New-LabContainerNetworkMigrationPlan -Provider $Provider -StateRoot $StateRoot
    if ($ExpectedPlanKey -and $plan.PlanKey -cne $ExpectedPlanKey) { throw 'LAB_NETWORK_MIGRATION_PREVIEW_CHANGED' }
    if ($plan.IsNoOp) { return $plan }
    if (-not $PSCmdlet.ShouldProcess("$Provider $($plan.Actual.Name)", "Labnetz nach $($plan.Desired.Subnet) migrieren")) { return $plan }
    return Invoke-LabContainerNetworkMigration -Provider $Provider -ExpectedPlanKey $plan.PlanKey -StateRoot $StateRoot
}
