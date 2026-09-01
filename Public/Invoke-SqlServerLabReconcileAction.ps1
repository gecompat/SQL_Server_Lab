<#
.SYNOPSIS
    Wendet einen Lifecycle-, Hyper-V-Netzwerk-/Ressourcen-/Storage-/SQL-, Container- oder External-Runtime-Reconcile-Plan auf einen Run an.
.DESCRIPTION
    Liest zuerst den passenden Reconcile-Plan aus. Lifecycle-Aktionen verlangen
    genau eine eindeutige Operation START oder STOP. Der getrennte Hyper-V-
    Netzwerkpfad repariert nur additive gebundene Hostinfrastruktur und genau
    einen vorhandenen getrennten Adapter. Container- und External-Runtime-
    Parametersaetze behalten ihre eigenen journalisierten Grenzen. Nicht
    unterstuetzte Planzustaende bleiben mutationsfrei.
.PARAMETER RunId
    Identifizierer des vorhandenen Runs.
.PARAMETER TargetState
    Gewuenschter Zielzustand fuer den Run nach der Reconcile-Ausfuehrung.
.PARAMETER ManifestPath
    Zielmanifest fuer eine erstmalige Installation oder einen späteren,
    resolvergebundenen External-Runtime-Reconcile.
.PARAMETER InstanceId
    Zielinstanz fuer den Hyper-V-Netzwerk-, Ressourcen-, Storage-, SQL-, Container- oder External-Runtime-Reconcile.
.PARAMETER RepairHyperVNetwork
    Repariert nur fehlende additive Hostinfrastruktur und verbindet genau einen
    vorhandenen, getrennten run-eigenen VM-Adapter wieder.
.PARAMETER RepairHyperVResources
    Repariert den manifestgebundenen vCPU-/RAM-Sollzustand. CPU-, RAM-Modus-
    und Startup-Aenderungen einer laufenden VM verwenden Stop, Apply und Start.
.PARAMETER RepairHyperVStorage
    Repariert fehlende manifestgebundene Zusatz-VHDX, vergroessert bestehende
    VHDX ausschliesslich grow-only und verifiziert die Volumes im Gast.
.PARAMETER RepairHyperVSqlStorage
    Repariert gebundene SQL-Default- und TempDB-Dateipfade und startet den
    SQL-Dienst kontrolliert neu. User- und Systemdatenbanken bleiben unberuehrt.
.PARAMETER RepairHyperVSqlConfiguration
    Repariert nur dynamische sp_configure-Werte und fuegt deklarierte globale
    Trace Flags live hinzu. SQL-Port, Dateipfade und Datenbanken bleiben unberuehrt.
.PARAMETER AllowExternalSwitchCreation
    Erlaubt im Hyper-V-Netzwerk-Reconcile die bereits lokal gebundene Erstellung
    eines External Switch. Ohne diesen Switch bleibt LAN-Erstellung fail-closed.
.PARAMETER Container
    Wählt den journalisierten Container-Ressourcen-Reconcile.
.PARAMETER Cpu
    Gewünschte vCPU-Grenze.
.PARAMETER MemoryMB
    Gewünschte RAM-Grenze in MB.
.PARAMETER Port
    Gewünschter SQL-Hostport; eine Änderung verwendet recreate.
.PARAMETER SqlMaxMemoryMB
    Gewünschter live angewandter SQL-Wert `max server memory (MB)`.
.PARAMETER AutoStart
    Gewünschter Container-Autostartvertrag. Eine Abweichung verwendet recreate.
.PARAMETER RepairSqlRuntimeContract
    Repariert SQL-Memory-/Healthcheck-Drift über recreate.
.PARAMETER ReadinessTimeoutSeconds
    Maximale Wartezeit fuer die SQL-Readiness des Ersatzcontainers.
.PARAMETER StateRoot
    Optionaler lokaler State-Root fuer einen reproduzierbaren Aufruf.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Liefert den Plan sowie eine
    versionierte Zusammenfassung der ausgefuehrten Executor-Schritte.
.EXAMPLE
    Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -TargetState STOPPED

.EXAMPLE
    Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -RepairHyperVNetwork -InstanceId primary -WhatIf

    Zeigt, ob die eng begrenzte Hyper-V-Netzwerkreparatur ausgefuehrt wuerde.
#>
function Invoke-SqlServerLabReconcileAction {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Lifecycle')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
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
        [Parameter(Mandatory, ParameterSetName = 'HyperVSqlConfiguration')]
        [string]$InstanceId,

        [Parameter(Mandatory, ParameterSetName = 'HyperVNetwork')]
        [switch]$RepairHyperVNetwork,

        [Parameter(Mandatory, ParameterSetName = 'HyperVResources')]
        [switch]$RepairHyperVResources,

        [Parameter(Mandatory, ParameterSetName = 'HyperVStorage')]
        [switch]$RepairHyperVStorage,

        [Parameter(Mandatory, ParameterSetName = 'HyperVSqlStorage')]
        [switch]$RepairHyperVSqlStorage,

        [Parameter(Mandatory, ParameterSetName = 'HyperVSqlConfiguration')]
        [switch]$RepairHyperVSqlConfiguration,

        [Parameter(ParameterSetName = 'HyperVNetwork')]
        [switch]$AllowExternalSwitchCreation,

        [Parameter(ParameterSetName = 'ExternalRuntime')]
        [Parameter(ParameterSetName = 'Container')]
        [ValidateRange(10, 900)]
        [int]$ReadinessTimeoutSeconds = 300,

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

    if ($PSCmdlet.ParameterSetName -eq 'HyperVSqlConfiguration') {
        $plan = Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlConfiguration -InstanceId $InstanceId -StateRoot $StateRoot
        $wouldExecute = if ($plan.IsNoOp -or [string]$plan.HighestChangeClass -ne 'live') { $false } else {
            $PSCmdlet.ShouldProcess("Run '$RunId', Instanz '$InstanceId'", 'Hyper-V-SQL-Livekonfiguration journalgebunden reparieren')
        }
        $entry = [ordered]@{
            Operation=if($plan.IsNoOp){'None'}else{'RepairHyperVSqlConfiguration'};ChangeClass=[string]$plan.HighestChangeClass
            Planned=(@($plan.Actions).Count -eq 1);Executed=$false
            Status=if($plan.IsNoOp){'NO_OP'}elseif([string]$plan.HighestChangeClass -ne 'live'){'UNSUPPORTED'}elseif($wouldExecute){'PLANNED'}else{'WOULD_EXECUTE'}
            Reason=$null;Result=$null
        }
        $summary=[ordered]@{Status=$entry.Status;PlannedActions=@($plan.Actions).Count;ExecutedActions=0;FailedActions=0;MutationAllowed=$false;Errors=@()}
        if($wouldExecute){
            try{
                $entry.Result=Invoke-LabHyperVSqlConfigurationReconcileRepair -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
                $entry.Executed=$true;$entry.Status=[string]$entry.Result.Status;$summary.Status=[string]$entry.Result.Status;$summary.ExecutedActions=1;$summary.MutationAllowed=$true
            }
            catch{
                $entry.Executed=$true;$entry.Status='FAILED';$entry.Reason=$_.Exception.Message;$summary.Status='FAILED';$summary.ExecutedActions=1;$summary.FailedActions=1;$summary.Errors=@($_.Exception.Message)
            }
        }
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.ReconcileAction';Version='1.7'};RunId=$RunId;TargetState=$null;Plan=$plan
            ExecutionPlan=@([PSCustomObject]$entry);ExecutionSummary=[PSCustomObject]$summary;MutationAllowed=[bool]$summary.MutationAllowed;Warnings=@($plan.Warnings)
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'HyperVSqlStorage') {
        $plan = Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlStorage -InstanceId $InstanceId -StateRoot $StateRoot
        $wouldExecute = if ($plan.IsNoOp -or [string]$plan.HighestChangeClass -ne 'restart') { $false } else {
            $PSCmdlet.ShouldProcess("Run '$RunId', Instanz '$InstanceId'", 'Hyper-V-SQL-Dateiplatzierung receiptgebunden reparieren')
        }
        $entry = [ordered]@{
            Operation=if($plan.IsNoOp){'None'}else{'RepairHyperVSqlStorage'};ChangeClass=[string]$plan.HighestChangeClass
            Planned=(@($plan.Actions).Count -eq 1);Executed=$false
            Status=if($plan.IsNoOp){'NO_OP'}elseif([string]$plan.HighestChangeClass -ne 'restart'){'UNSUPPORTED'}elseif($wouldExecute){'PLANNED'}else{'WOULD_EXECUTE'}
            Reason=$null;Result=$null
        }
        $summary=[ordered]@{Status=$entry.Status;PlannedActions=@($plan.Actions).Count;ExecutedActions=0;FailedActions=0;MutationAllowed=$false;Errors=@()}
        if($wouldExecute){
            try{
                $entry.Result=Invoke-LabHyperVSqlStorageReconcileRepair -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
                $entry.Executed=$true;$entry.Status=[string]$entry.Result.Status;$summary.Status=[string]$entry.Result.Status;$summary.ExecutedActions=1;$summary.MutationAllowed=$true
            }
            catch{
                $entry.Executed=$true;$entry.Status='FAILED';$entry.Reason=$_.Exception.Message;$summary.Status='FAILED';$summary.ExecutedActions=1;$summary.FailedActions=1;$summary.Errors=@($_.Exception.Message)
            }
        }
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.ReconcileAction';Version='1.6'};RunId=$RunId;TargetState=$null;Plan=$plan
            ExecutionPlan=@([PSCustomObject]$entry);ExecutionSummary=[PSCustomObject]$summary;MutationAllowed=[bool]$summary.MutationAllowed;Warnings=@($plan.Warnings)
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'HyperVStorage') {
        $plan = Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVStorage -InstanceId $InstanceId -StateRoot $StateRoot
        $wouldExecute = if ($plan.IsNoOp -or [string]$plan.HighestChangeClass -notin @('live','restart')) { $false } else {
            $PSCmdlet.ShouldProcess("Run '$RunId', Instanz '$InstanceId'", "Hyper-V-Storage '$($plan.HighestChangeClass)' eigentumsgeprueft reparieren")
        }
        $entry = [ordered]@{
            Operation=if($plan.IsNoOp){'None'}else{'RepairHyperVStorage'};ChangeClass=[string]$plan.HighestChangeClass
            Planned=(@($plan.Actions).Count -eq 1);Executed=$false
            Status=if($plan.IsNoOp){'NO_OP'}elseif([string]$plan.HighestChangeClass -notin @('live','restart')){'UNSUPPORTED'}elseif($wouldExecute){'PLANNED'}else{'WOULD_EXECUTE'}
            Reason=$null;Result=$null
        }
        $summary=[ordered]@{Status=$entry.Status;PlannedActions=@($plan.Actions).Count;ExecutedActions=0;FailedActions=0;MutationAllowed=$false;Errors=@()}
        if($wouldExecute){
            try{
                $entry.Result=Invoke-LabHyperVStorageReconcileRepair -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
                $entry.Executed=$true;$entry.Status=[string]$entry.Result.Status;$summary.Status=[string]$entry.Result.Status;$summary.ExecutedActions=1;$summary.MutationAllowed=$true
            }
            catch{
                $entry.Executed=$true;$entry.Status='FAILED';$entry.Reason=$_.Exception.Message;$summary.Status='FAILED';$summary.ExecutedActions=1;$summary.FailedActions=1;$summary.Errors=@($_.Exception.Message)
            }
        }
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.ReconcileAction';Version='1.5'};RunId=$RunId;TargetState=$null;Plan=$plan
            ExecutionPlan=@([PSCustomObject]$entry);ExecutionSummary=[PSCustomObject]$summary;MutationAllowed=[bool]$summary.MutationAllowed;Warnings=@($plan.Warnings)
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'HyperVResources') {
        $plan = Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVResources -InstanceId $InstanceId -StateRoot $StateRoot
        $wouldExecute = if ($plan.IsNoOp -or [string]$plan.HighestChangeClass -notin @('live','restart')) { $false } else {
            $PSCmdlet.ShouldProcess("Run '$RunId', Instanz '$InstanceId'", "Hyper-V-Ressourcen '$($plan.HighestChangeClass)' eigentumsgeprüft reparieren")
        }
        $entry = [ordered]@{
            Operation=if($plan.IsNoOp){'None'}else{'RepairHyperVResources'};ChangeClass=[string]$plan.HighestChangeClass
            Planned=(@($plan.Actions).Count -eq 1);Executed=$false
            Status=if($plan.IsNoOp){'NO_OP'}elseif([string]$plan.HighestChangeClass -notin @('live','restart')){'UNSUPPORTED'}elseif($wouldExecute){'PLANNED'}else{'WOULD_EXECUTE'}
            Reason=$null;Result=$null
        }
        $summary=[ordered]@{Status=$entry.Status;PlannedActions=@($plan.Actions).Count;ExecutedActions=0;FailedActions=0;MutationAllowed=$false;Errors=@()}
        if($wouldExecute){
            try{
                $entry.Result=Invoke-LabHyperVResourceReconcileRepair -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
                $entry.Executed=$true;$entry.Status=[string]$entry.Result.Status;$summary.Status=[string]$entry.Result.Status;$summary.ExecutedActions=1;$summary.MutationAllowed=$true
            }
            catch{
                $entry.Executed=$true;$entry.Status='FAILED';$entry.Reason=$_.Exception.Message;$summary.Status='FAILED';$summary.ExecutedActions=1;$summary.FailedActions=1;$summary.Errors=@($_.Exception.Message)
            }
        }
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.ReconcileAction';Version='1.4'};RunId=$RunId;TargetState=$null;Plan=$plan
            ExecutionPlan=@([PSCustomObject]$entry);ExecutionSummary=[PSCustomObject]$summary;MutationAllowed=[bool]$summary.MutationAllowed;Warnings=@($plan.Warnings)
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'HyperVNetwork') {
        $plan = Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVNetwork -InstanceId $InstanceId -StateRoot $StateRoot
        $wouldExecute = if ($plan.IsNoOp -or [string]$plan.HighestChangeClass -ne 'live') { $false } else {
            $PSCmdlet.ShouldProcess("Run '$RunId', Instanz '$InstanceId'", 'Hyper-V-Netzwerkbindung eigentumsgeprüft reparieren')
        }
        $entry = [ordered]@{
            Operation=if ($plan.IsNoOp) { 'None' } else { 'RepairNetwork' }
            ChangeClass=[string]$plan.HighestChangeClass; Planned=(@($plan.Actions).Count -eq 1)
            Executed=$false
            Status=if ($plan.IsNoOp) { 'NO_OP' } elseif ([string]$plan.HighestChangeClass -ne 'live') { 'UNSUPPORTED' } elseif ($wouldExecute) { 'PLANNED' } else { 'WOULD_EXECUTE' }
            Reason=$null; Result=$null
        }
        $summary = [ordered]@{
            Status=$entry.Status; PlannedActions=@($plan.Actions).Count; ExecutedActions=0
            FailedActions=0; MutationAllowed=$false; Errors=@()
        }
        if ($wouldExecute) {
            try {
                $entry.Result = Invoke-LabHyperVNetworkReconcileRepair -RunId $RunId -InstanceId $InstanceId `
                    -AllowExternalSwitchCreation:$AllowExternalSwitchCreation -StateRoot $StateRoot
                $entry.Executed=$true; $entry.Status=[string]$entry.Result.Status
                $summary.Status=[string]$entry.Result.Status; $summary.ExecutedActions=1; $summary.MutationAllowed=$true
            }
            catch {
                $entry.Executed=$true; $entry.Status='FAILED'; $entry.Reason=$_.Exception.Message
                $summary.Status='FAILED'; $summary.ExecutedActions=1; $summary.FailedActions=1; $summary.Errors=@($_.Exception.Message)
            }
        }
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{ Name='SqlServerLab.ReconcileAction'; Version='1.3' }
            RunId=$RunId; TargetState=$null; Plan=$plan; ExecutionPlan=@([PSCustomObject]$entry)
            ExecutionSummary=[PSCustomObject]$summary; MutationAllowed=[bool]$summary.MutationAllowed
            Warnings=@($plan.Warnings)
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'ExternalRuntime') {
        $plan = Get-SqlServerLabReconcilePlan -RunId $RunId -ManifestPath $ManifestPath -InstanceId $InstanceId -StateRoot $StateRoot
        $wouldExecute = if ($plan.IsNoOp) { $false } else {
            $PSCmdlet.ShouldProcess("Run '$RunId', Instanz '$($plan.InstanceId)'", 'External Runtime durch validierten Ersatzcontainer aktualisieren')
        }
        $entry = [ordered]@{
            Operation=if ($plan.IsNoOp) { 'None' } else { [string]$plan.Actions[0].Operation }; Planned=(-not $plan.IsNoOp); Executed=$false
            Status=if ($plan.IsNoOp) { 'NO_OP' } elseif ($wouldExecute) { 'PLANNED' } else { 'WOULD_EXECUTE' }
            Reason=$null; Result=$null
        }
        $summary = [ordered]@{
            Status=$entry.Status; PlannedActions=@($plan.Actions).Count; ExecutedActions=0
            FailedActions=0; MutationAllowed=$false; Errors=@()
        }
        if (-not $plan.IsNoOp -and $wouldExecute) {
            try {
                $entry.Result = Invoke-LabExternalRuntimeReconcileRefresh -RunId $RunId -ManifestPath $ManifestPath `
                    -InstanceId $InstanceId -ReadinessTimeoutSeconds $ReadinessTimeoutSeconds -StateRoot $StateRoot
                $entry.Executed = $true; $entry.Status = [string]$entry.Result.Status
                $summary.Status = [string]$entry.Result.Status; $summary.ExecutedActions = 1; $summary.MutationAllowed = $true
            }
            catch {
                $entry.Executed = $true; $entry.Status = 'FAILED'; $entry.Reason = $_.Exception.Message
                $summary.Status = 'FAILED'; $summary.ExecutedActions = 1; $summary.FailedActions = 1; $summary.Errors = @($_.Exception.Message)
            }
        }
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{ Name='SqlServerLab.ReconcileAction'; Version='1.1' }
            RunId=$RunId; TargetState=$null; Plan=$plan; ExecutionPlan=@([PSCustomObject]$entry)
            ExecutionSummary=[PSCustomObject]$summary; MutationAllowed=[bool]$summary.MutationAllowed
            Warnings=@($plan.Warnings)
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'Container') {
        $planArguments = @{ RunId=$RunId; Container=$true; StateRoot=$StateRoot; RepairSqlRuntimeContract=$RepairSqlRuntimeContract }
        if (-not [string]::IsNullOrWhiteSpace($InstanceId)) { $planArguments.InstanceId=[string]$InstanceId }
        if ($PSBoundParameters.ContainsKey('Cpu')) { $planArguments.Cpu=[decimal]$Cpu }
        if ($PSBoundParameters.ContainsKey('MemoryMB')) { $planArguments.MemoryMB=[int]$MemoryMB }
        if ($PSBoundParameters.ContainsKey('Port')) { $planArguments.Port=[int]$Port }
        if ($PSBoundParameters.ContainsKey('SqlMaxMemoryMB')) { $planArguments.SqlMaxMemoryMB=[int]$SqlMaxMemoryMB }
        if ($PSBoundParameters.ContainsKey('AutoStart')) { $planArguments.AutoStart=[string]$AutoStart }
        $plan = Get-SqlServerLabReconcilePlan @planArguments
        $wouldExecute = if ($plan.IsNoOp) { $false } else {
            $PSCmdlet.ShouldProcess("Run '$RunId', Instanz '$($plan.InstanceId)'", "Container-Reconcile '$($plan.HighestChangeClass)' ausführen")
        }
        $entry = [ordered]@{
            Operation=if($plan.IsNoOp){'None'}else{[string]$plan.Actions[0].Operation}
            ChangeClass=[string]$plan.HighestChangeClass; Planned=(-not $plan.IsNoOp); Executed=$false
            Status=if($plan.IsNoOp){'NO_OP'}elseif($wouldExecute){'PLANNED'}else{'WOULD_EXECUTE'}
            Reason=$null; Result=$null
        }
        $summary = [ordered]@{
            Status=$entry.Status; PlannedActions=@($plan.Actions).Count; ExecutedActions=0
            FailedActions=0; MutationAllowed=$false; Errors=@()
        }
        if (-not $plan.IsNoOp -and $wouldExecute) {
            try {
                $updateArguments = @{
                    RunId=$RunId; InstanceId=[string]$plan.InstanceId; Cpu=[decimal]$plan.Desired.Cpu
                    MemoryMB=[int]$plan.Desired.MemoryMB; Port=[int]$plan.Desired.Port
                    ReadinessTimeoutSeconds=$ReadinessTimeoutSeconds; RepairSqlRuntimeContract=$RepairSqlRuntimeContract
                    StateRoot=$StateRoot; Confirm=$false
                }
                if ($null -ne $plan.Desired.SqlMaxMemoryMB) { $updateArguments.SqlMaxMemoryMB=[int]$plan.Desired.SqlMaxMemoryMB }
                $updateArguments.AutoStart=[string]$plan.Desired.AutoStart
                $result = Update-SqlServerLabContainer @updateArguments
                $entry.Executed=$true; $entry.Status='SUCCEEDED'; $entry.Result=$result
                $summary.Status='SUCCEEDED'; $summary.ExecutedActions=1; $summary.MutationAllowed=$true
            }
            catch {
                $entry.Executed=$true; $entry.Status='FAILED'; $entry.Reason=$_.Exception.Message
                $summary.Status='FAILED'; $summary.ExecutedActions=1; $summary.FailedActions=1; $summary.Errors=@($_.Exception.Message)
            }
        }
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{ Name='SqlServerLab.ReconcileAction'; Version='1.2' }
            RunId=$RunId; TargetState=$null; Plan=$plan; ExecutionPlan=@([PSCustomObject]$entry)
            ExecutionSummary=[PSCustomObject]$summary; MutationAllowed=[bool]$summary.MutationAllowed
            Warnings=@($plan.Warnings)
        }
    }

    $plan = Get-SqlServerLabReconcilePlan -RunId $RunId -TargetState $TargetState -StateRoot $StateRoot
    $planActions = @($plan.Actions)
    $operations = @()
    foreach ($action in @($planActions)) {
        if ($null -eq $action) { continue }
        $operationValue = if ($action.PSObject.Properties['Operation']) { [string]$action.Operation } else { '' }
        $normalizedOperation = $operationValue.Trim().ToUpperInvariant()
        if ($normalizedOperation) { $operations += $normalizedOperation }
    }
    $operations = @($operations | Sort-Object -Unique)
    $changeClass = if ($plan.HighestChangeClass) { [string]$plan.HighestChangeClass } else { '' }
    $supportedOperationsLookup = @{}
    foreach ($supportedOperation in @('START', 'STOP')) {
        $supportedOperationsLookup[$supportedOperation] = $supportedOperation
    }
    $executionPlan = @()
    $wouldExecute = $PSCmdlet.ShouldProcess("Run '$RunId'", "Reconcile target state '$TargetState'")

    if (($operations.Count -eq 0) -and ($changeClass.ToUpperInvariant().Trim() -eq 'RESTART') -and $plan.PSObject.Properties['Desired']) {
        $fallbackTargetState = if ($plan.Desired.PSObject.Properties['TargetState']) { [string]$plan.Desired.TargetState } else { [string]$TargetState }
        $fallbackOperation = if ($fallbackTargetState -eq 'STOPPED') { 'STOP' } else { 'START' }
        $providers = New-Object System.Collections.Generic.List[string]
        foreach ($desiredInstance in @($plan.Desired.Instances)) {
            if ($null -eq $desiredInstance) { continue }
            $provider = [string]$desiredInstance.Provider
            if ($provider) {
                $providers.Add($provider)
            }
        }
        $providers = @($providers | Sort-Object -Unique)
        if ($providers.Count -gt 0) {
            $operations = @([string]$fallbackOperation)
            $planActions = @(
                foreach ($provider in $providers) {
                    [PSCustomObject]@{
                        Operation = $fallbackOperation
                        Provider = [string]$provider
                        TargetState = $fallbackTargetState
                    }
                }
            )
        }
    }

    if (($changeClass.ToUpperInvariant().Trim() -ne 'RESTART') -or $operations.Count -eq 0) {
        $status = if ($plan.IsNoOp -eq $true) { 'NO_OP' } else { 'UNSUPPORTED' }
        return [PSCustomObject]@{
            Contract = [PSCustomObject]@{ Name = 'SqlServerLab.ReconcileAction'; Version = '1.0' }
            RunId = $RunId
            TargetState = $TargetState
            Plan = $plan
            ExecutionPlan = @()
            ExecutionSummary = [PSCustomObject]@{
                Status = $status
                PlannedActions = 0
                ExecutedActions = 0
                FailedActions = 0
                MutationAllowed = $false
                Errors = @()
            }
            MutationAllowed = $false
            Warnings = @($plan.Warnings)
        }
    }

    if (($operations.Count -ne 1) -or (@($operations | Where-Object { -not $supportedOperationsLookup.ContainsKey($_) }).Count -gt 0)) {
        $unsupportedOperation = [string]::Join(',', $operations)
        return [PSCustomObject]@{
            Contract = [PSCustomObject]@{ Name = 'SqlServerLab.ReconcileAction'; Version = '1.0' }
            RunId = $RunId
            TargetState = $TargetState
            Plan = $plan
            ExecutionPlan = @([PSCustomObject]@{
                Operation = $unsupportedOperation
                Planned = $true
                Executed = $false
                Status = 'UNSUPPORTED'
                Reason = 'Plan enthält gemischte oder unbekannte Operationen.'
            })
            ExecutionSummary = [PSCustomObject]@{
                Status = 'UNSUPPORTED'
                PlannedActions = $planActions.Count
                ExecutedActions = 0
                FailedActions = 0
                MutationAllowed = $false
                Errors = @('Plan enthält nicht eindeutige Reconcile-Operationen.')
            }
            MutationAllowed = $false
            Warnings = @($plan.Warnings + 'Plan enthält gemischte oder unbekannte Operationspfade.')
        }
    }

    $executionSummary = [ordered]@{
        Status = 'WOULD_EXECUTE'
        PlannedActions = $planActions.Count
        ExecutedActions = 0
        FailedActions = 0
        MutationAllowed = $false
        Errors = @()
    }

    $canonicalOperation = if ([string]$operations[0] -eq 'START') { 'Start' } else { 'Stop' }
    $entry = [ordered]@{
        Operation = $canonicalOperation
        Planned = $true
        Executed = $wouldExecute
        Status = if ($wouldExecute) { 'PLANNED' } else { 'WOULD_EXECUTE' }
        Reason = if ($wouldExecute) { $null } else { 'Ausfuehrung via -WhatIf oder abgebrochener Bestätigung.' }
        Result = $null
    }

    if ($wouldExecute) {
        $executionSummary.Status = 'PLANNED'
        try {
            $result = if ($canonicalOperation -eq 'Start') {
                Start-SqlServerLab -RunId $RunId -StateRoot $StateRoot
            }
            else {
                Stop-SqlServerLab -RunId $RunId -StateRoot $StateRoot -Force
            }
            $entry.Status = if ([string]$result.Status -match 'FAILED|WITH_ERRORS|RECOVERY_REQUIRED') { 'FAILED' } else { 'SUCCEEDED' }
            $entry.Result = $result
            $executionSummary.ExecutedActions = 1
            if ($entry.Status -eq 'FAILED') {
                $executionSummary.FailedActions = 1
            $executionSummary.Errors += "Executor '$canonicalOperation' fehlgeschlagen: $($result.Status)"
            }
            else {
                $executionSummary.MutationAllowed = $true
                $executionSummary.Status = 'SUCCEEDED'
            }
        }
        catch {
            $entry.Status = 'FAILED'
            $entry.Reason = $_.Exception.Message
            $executionSummary.Status = 'FAILED'
            $executionSummary.FailedActions = 1
            $executionSummary.Errors += $_.Exception.Message
        }
    }
    else {
        $executionSummary.Status = 'WOULD_EXECUTE'
    }

    $executionPlan += [PSCustomObject]$entry

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.ReconcileAction'; Version = '1.0' }
        RunId = $RunId
        TargetState = $TargetState
        Plan = $plan
        ExecutionPlan = $executionPlan
        ExecutionSummary = [PSCustomObject]$executionSummary
        MutationAllowed = [bool]$executionSummary.MutationAllowed
        Warnings = @($plan.Warnings)
    }
}
