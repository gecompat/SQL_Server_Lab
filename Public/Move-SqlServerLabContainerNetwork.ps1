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
    .OUTPUTS
        PSCustomObject mit read-only Migrationsplan oder dem Ergebnis der
        ausgefuehrten Migration einschliesslich Recovery-Status.
    .EXAMPLE
        Move-SqlServerLabContainerNetwork -Provider podman -WhatIf

        Zeigt eine erforderliche Podman-Netzmigration ohne Runtime-Mutation.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider, [string]$StateRoot)

    $plan = New-LabContainerNetworkMigrationPlan -Provider $Provider -StateRoot $StateRoot
    if ($plan.IsNoOp) { return $plan }
    if (-not $PSCmdlet.ShouldProcess("$Provider $($plan.Actual.Name)", "Labnetz nach $($plan.Desired.Subnet) migrieren")) { return $plan }
    return Invoke-LabContainerNetworkMigration -Provider $Provider -StateRoot $StateRoot
}