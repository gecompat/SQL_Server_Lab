<#
.SYNOPSIS
    Erstellt einen read-only Lifecycle-, Hyper-V-Netzwerk-/Ressourcen-/Storage-, Container- oder External-Runtime-Reconcile-Plan.
.DESCRIPTION
    Liest den bestehenden Run und dessen Runtime-Zustand und liefert einen
    versionierten Desired/Actual/Diff/Action-Vertrag. Der Befehl fuehrt keine
    Mutation aus: Auch bei Start- oder Stop-Differenzen bleiben Actions reine
    Vorschlaege. Unvollstaendige Runtime-Zustaende werden fail-closed als
    unsupported ausgewiesen. Fuer Hyper-V-Runs prueft der Lifecycle-Plan
    zusaetzlich die persistierte Netzabsicht gegen Adapter, Switch-Typ,
    Hostinfrastruktur und eine beobachtbare Gastadresse, ohne Hostwerte
    offenzulegen. Der eigene HyperVNetwork-Parametersatz plant nur additive
    Infrastrukturreparaturen und das Wiederverbinden eines vorhandenen,
    getrennten run-eigenen Adapters.
.PARAMETER RunId
    Eindeutige ID des vorhandenen Lab-Runs.
.PARAMETER TargetState
    Gewuenschter Lifecycle-Zustand: RUNNING oder STOPPED.
.PARAMETER ManifestPath
    Zielmanifest fuer eine erstmalige External-Runtime-Installation oder einen
    späteren Reconcile. Ausserhalb des resolvergebundenen Softwarevertrags darf
    es nicht vom persistierten Sollzustand abweichen.
.PARAMETER InstanceId
    Zielinstanz für Hyper-V-Netzwerk-, Container- oder External-Runtime-Reconcile. Darf nur
    entfallen, wenn genau eine geeignete Runtime-Instanz im Run existiert.
.PARAMETER HyperVNetwork
    Waehlt den eng begrenzten read-only Hyper-V-Netzwerk-Reconcile-Plan.
.PARAMETER HyperVResources
    Waehlt den manifestgebundenen read-only Hyper-V-vCPU-/RAM-Reconcile-Plan.
.PARAMETER HyperVStorage
    Waehlt den manifestgebundenen read-only Hyper-V-Zusatz-VHDX-Reconcile-Plan.
.PARAMETER HyperVSqlStorage
    Waehlt den read-only Hyper-V-SQL-Dateiplatzierungs-Reconcile-Plan.
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
.PARAMETER AutoStart
    Gewünschter Container-Autostartvertrag. Eine Abweichung erfordert recreate.
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
.EXAMPLE
    Get-SqlServerLabReconcilePlan -RunId $runId -HyperVNetwork -InstanceId primary

    Zeigt reparierbare und nicht automatisch reparierbare Hyper-V-Netzwerkdrift.
.EXAMPLE
    Get-SqlServerLabReconcilePlan -RunId $runId -HyperVResources -InstanceId primary

    Klassifiziert vCPU- und RAM-Drift als no-op, live, restart oder unsupported.
.EXAMPLE
    Get-SqlServerLabReconcilePlan -RunId $runId -HyperVStorage -InstanceId primary

    Plant fehlende Zusatz-VHDX, Grow-only-Aenderungen und Gastverifikation.
.EXAMPLE
    Get-SqlServerLabReconcilePlan -RunId $runId -HyperVSqlStorage -InstanceId primary

    Vergleicht SQL-Default- und TempDB-Dateipfade mit dem gebundenen Storageplan.
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
        [Parameter(Mandatory, ParameterSetName = 'HyperVNetwork')]
        [Parameter(Mandatory, ParameterSetName = 'HyperVResources')]
        [Parameter(Mandatory, ParameterSetName = 'HyperVStorage')]
        [Parameter(Mandatory, ParameterSetName = 'HyperVSqlStorage')]
        [string]$InstanceId,

        [Parameter(Mandatory, ParameterSetName = 'HyperVNetwork')]
        [switch]$HyperVNetwork,

        [Parameter(Mandatory, ParameterSetName = 'HyperVResources')]
        [switch]$HyperVResources,

        [Parameter(Mandatory, ParameterSetName = 'HyperVStorage')]
        [switch]$HyperVStorage,

        [Parameter(Mandatory, ParameterSetName = 'HyperVSqlStorage')]
        [switch]$HyperVSqlStorage,

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
        [ValidateSet('on', 'off')]
        [string]$AutoStart,

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
        if ($PSBoundParameters.ContainsKey('AutoStart')) { $arguments.AutoStart=[string]$AutoStart }
        return New-LabContainerReconcilePlan @arguments
    }
    if ($PSCmdlet.ParameterSetName -eq 'HyperVNetwork') {
        return New-LabHyperVNetworkReconcilePlan -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    }
    if ($PSCmdlet.ParameterSetName -eq 'HyperVResources') {
        return New-LabHyperVResourceReconcilePlan -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    }
    if ($PSCmdlet.ParameterSetName -eq 'HyperVStorage') {
        return New-LabHyperVStorageReconcilePlan -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    }
    if ($PSCmdlet.ParameterSetName -eq 'HyperVSqlStorage') {
        return New-LabHyperVSqlStorageReconcilePlan -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    }
    return New-LabReconcilePlan -RunId $RunId -TargetState $TargetState -StateRoot $StateRoot
}
