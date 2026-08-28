<#
.SYNOPSIS
    Erstellt einen read-only Lifecycle- oder External-Runtime-Reconcile-Plan.
.DESCRIPTION
    Liest den bestehenden Run und dessen Runtime-Zustand und liefert einen
    versionierten Desired/Actual/Diff/Action-Vertrag. Der Befehl fuehrt keine
    Mutation aus: Auch bei Start- oder Stop-Differenzen bleiben Actions reine
    Vorschlaege. Unvollstaendige Runtime-Zustaende werden fail-closed als
    unsupported ausgewiesen.
.PARAMETER RunId
    Eindeutige ID des vorhandenen Lab-Runs.
.PARAMETER TargetState
    Gewuenschter Lifecycle-Zustand: RUNNING oder STOPPED.
.PARAMETER ManifestPath
    Zielmanifest fuer einen External-Runtime-Reconcile. Ausserhalb des resolver-
    gebundenen Softwarevertrags darf es nicht vom persistierten Sollzustand
    abweichen.
.PARAMETER InstanceId
    Zielinstanz. Darf nur entfallen, wenn genau eine geeignete Runtime-Instanz
    im Run existiert.
.PARAMETER StateRoot
    Optionaler lokaler State-Root fuer einen reproduzierbaren, isolierten
    Lesezugriff. Ohne Angabe gilt der konfigurierte Standard-State-Root.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Serialisierbarer Vertrag ohne
    Secrets, Host/Port-Werte, Container-/VM-IDs oder lokale Pfade.
.EXAMPLE
    Get-SqlServerLabReconcilePlan -RunId $runId -TargetState STOPPED

    Zeigt den read-only Plan zum kontrollierten Stoppen eines Runs.
#>
function Get-SqlServerLabReconcilePlan {
    [CmdletBinding(DefaultParameterSetName = 'Lifecycle')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$RunId,

        [Parameter(Mandatory, ParameterSetName = 'Lifecycle')]
        [ValidateSet('RUNNING', 'STOPPED')]
        [string]$TargetState,

        [Parameter(Mandatory, ParameterSetName = 'ExternalRuntime')]
        [string]$ManifestPath,

        [Parameter(ParameterSetName = 'ExternalRuntime')]
        [string]$InstanceId,

        [string]$StateRoot
    )

    if ($PSCmdlet.ParameterSetName -eq 'ExternalRuntime') {
        return New-LabExternalRuntimeReconcilePlan -RunId $RunId -ManifestPath $ManifestPath `
            -InstanceId $InstanceId -StateRoot $StateRoot
    }
    return New-LabReconcilePlan -RunId $RunId -TargetState $TargetState -StateRoot $StateRoot
}
