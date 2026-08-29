<#
.SYNOPSIS
    Erstellt einen read-only Lifecycle-, Container- oder External-Runtime-Reconcile-Plan.
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
    Zielinstanz für Container- oder External-Runtime-Reconcile. Darf nur
    entfallen, wenn genau eine geeignete Runtime-Instanz im Run existiert.
.PARAMETER Container
    Wählt den Container-Ressourcen-Reconcile. Der Plan klassifiziert die
    Änderung als no-op, live oder recreate und mutiert die Runtime nicht.
.PARAMETER Cpu
    Gewünschte vCPU-Grenze. Ohne Angabe bleibt der Istwert erhalten.
.PARAMETER MemoryMB
    Gewünschte RAM-Grenze in MB. Ohne Angabe bleibt der Istwert erhalten.
.PARAMETER Port
    Gewünschter SQL-Hostport. Eine Abweichung erfordert recreate.
.PARAMETER SqlMaxMemoryMB
    Gewünschter live angewandter SQL-Wert `max server memory (MB)`.
.PARAMETER RepairSqlRuntimeContract
    Plant bei Drift von SQL-Memory-/Healthcheck-Vertrag ein recreate.
.PARAMETER StateRoot
    Optionaler lokaler State-Root fuer einen reproduzierbaren, isolierten
    Lesezugriff. Ohne Angabe gilt der konfigurierte Standard-State-Root.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Serialisierbarer Vertrag ohne
    Secrets, Host/Port-Werte, Container-/VM-IDs oder lokale Pfade.
.EXAMPLE
    Get-SqlServerLabReconcilePlan -RunId $runId -TargetState STOPPED

    Zeigt den read-only Plan zum kontrollierten Stoppen eines Runs.
.EXAMPLE
    Get-SqlServerLabReconcilePlan -RunId $runId -Container -Cpu 2 -MemoryMB 4096

    Zeigt eine Live-Ressourcenänderung ohne Mutation an.
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
        [Parameter(ParameterSetName = 'Container')]
        [string]$InstanceId,

        [Parameter(Mandatory, ParameterSetName = 'Container')]
        [switch]$Container,

        [Parameter(ParameterSetName = 'Container')]
        [ValidateRange(1, 64)]
        [decimal]$Cpu,

        [Parameter(ParameterSetName = 'Container')]
        [ValidateRange(512, 1048576)]
        [int]$MemoryMB,

        [Parameter(ParameterSetName = 'Container')]
        [ValidateRange(1024, 65535)]
        [int]$Port,

        [Parameter(ParameterSetName = 'Container')]
        [ValidateRange(128, 2147483647)]
        [int]$SqlMaxMemoryMB,

        [Parameter(ParameterSetName = 'Container')]
        [switch]$RepairSqlRuntimeContract,

        [string]$StateRoot
    )

    if ($PSCmdlet.ParameterSetName -eq 'ExternalRuntime') {
        return New-LabExternalRuntimeReconcilePlan -RunId $RunId -ManifestPath $ManifestPath `
            -InstanceId $InstanceId -StateRoot $StateRoot
    }
    if ($PSCmdlet.ParameterSetName -eq 'Container') {
        $arguments = @{ RunId=$RunId; InstanceId=$InstanceId; StateRoot=$StateRoot; RepairSqlRuntimeContract=$RepairSqlRuntimeContract }
        if ($PSBoundParameters.ContainsKey('Cpu')) { $arguments.Cpu=[decimal]$Cpu }
        if ($PSBoundParameters.ContainsKey('MemoryMB')) { $arguments.MemoryMB=[int]$MemoryMB }
        if ($PSBoundParameters.ContainsKey('Port')) { $arguments.Port=[int]$Port }
        if ($PSBoundParameters.ContainsKey('SqlMaxMemoryMB')) { $arguments.SqlMaxMemoryMB=[int]$SqlMaxMemoryMB }
        return New-LabContainerReconcilePlan @arguments
    }
    return New-LabReconcilePlan -RunId $RunId -TargetState $TargetState -StateRoot $StateRoot
}
