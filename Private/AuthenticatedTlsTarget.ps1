#Requires -Version 7.2
# Private lesende Metadatenbindung; keine Live-Runtime- oder PKI-Autorisierung.

function Get-LabAuthenticatedTlsTargetMetadata {
    [CmdletBinding()]
    param([object]$Request, [object]$InstanceId, [object]$DataRoot)

    $ErrorActionPreference = 'Stop'
    $rejected = [pscustomobject][ordered]@{ Success = $false; Value = $null; ErrorCode = 'TLS_TARGET_REQUEST_INVALID' }
    $checked = Test-LabAuthenticatedTlsRequest -Request $Request
    if (-not $checked.Success -or -not (Test-LabTlsRequestEnum $checked.Value.Kind @('LEAF_PROFILE'))) { return $rejected }
    $leaf = $checked.Value
    if ($InstanceId -isnot [string] -or $InstanceId -cnotmatch '\A[A-Za-z][A-Za-z0-9_-]{0,63}\z' -or
        $DataRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($DataRoot)) {
        $rejected.ErrorCode = 'TLS_TARGET_SELECTOR_INVALID'; return $rejected
    }
    if (-not (Test-LabTlsRequestEnum $leaf.Provider @('docker','podman'))) {
        $rejected.ErrorCode = 'TLS_TARGET_PROVIDER_UNSUPPORTED'; return $rejected
    }
    try {
        # TargetRef ist hier die vorhandene RunId, keine neue Registry oder freie StateRoot.
        # Der Reader bindet Controller, registrierten Root, Scope und Sollinstanzen.
        $binding = Get-LabDiagnosticBinding -RunId $leaf.TargetRef -InstanceId $InstanceId -DataRoot $DataRoot -Provider $leaf.Provider
        $actual = @($binding.Run.instances | Where-Object { [string]::Equals($_.id, $InstanceId, [StringComparison]::Ordinal) })
        if ($actual.Count -ne 1 -or
            -not (Test-LabTlsRequestEnum $binding.Instance.Id @($InstanceId)) -or
            -not (Test-LabTlsRequestEnum $binding.Instance.Provider @($leaf.Provider)) -or
            -not (Test-LabTlsRequestEnum $binding.Instance.Version @($leaf.SqlVersion))) {
            $rejected.ErrorCode = 'TLS_TARGET_METADATA_MISMATCH'; return $rejected
        }
        $instance = $actual[0]
        $subRun = @($binding.Run.providerSubRuns | Where-Object { [string]::Equals($_.provider, $leaf.Provider, [StringComparison]::Ordinal) })
        if (-not (Test-LabTlsRequestEnum $binding.Run.state @('RUNNING')) -or $subRun.Count -ne 1 -or
            -not (Test-LabTlsRequestEnum $subRun[0].state @('RUNNING'))) {
            $rejected.ErrorCode = 'TLS_TARGET_STATE_UNSUPPORTED'; return $rejected
        }
        if (-not (Test-LabTlsRequestEnum $binding.Run.runId @($leaf.TargetRef)) -or
            -not (Test-LabTlsRequestReference $binding.Run.scopeId) -or
            -not (Test-LabTlsRequestEnum $instance.id @($InstanceId)) -or
            -not (Test-LabTlsRequestEnum $instance.provider @($leaf.Provider)) -or
            -not (Test-LabTlsRequestEnum $instance.version @($leaf.SqlVersion)) -or
            $instance.containerId -isnot [string] -or $instance.containerId -cnotmatch '\A[0-9a-f]{64}\z' -or
            ($instance.port -isnot [int] -and $instance.port -isnot [long]) -or $instance.port -ne $leaf.Port -or
            -not (Test-LabTlsRequestEnum $instance.host @($leaf.Identity.Value))) {
            $rejected.ErrorCode = 'TLS_TARGET_METADATA_MISMATCH'; return $rejected
        }
        # Ausschliesslich frische private Projektion, keine Run-/Sollzustandsobjekte weiterreichen.
        $value = [pscustomobject][ordered]@{
            ContractVersion = 'SqlServerLab.AuthenticatedTlsTargetMetadata/0.1'
            Status = 'RECORDED'; TargetRef = $leaf.TargetRef; InstanceId = $InstanceId; ScopeId = $binding.Run.scopeId
            Provider = $leaf.Provider; SqlVersion = $leaf.SqlVersion; ContainerId = $instance.containerId
            Port = $leaf.Port; Identity = [pscustomobject][ordered]@{ Kind = $leaf.Identity.Kind; Value = $leaf.Identity.Value }
            RuntimeStatus = 'NOT_EXECUTED'; AuthorizationStatus = 'NOT_EVALUATED'; MutationAllowed = $false
        }
        return [pscustomobject][ordered]@{ Success = $true; Value = $value; ErrorCode = $null }
    }
    catch {
        # Fehlende Felder, unlesbare/inkonsistente Dateien und Rohfehler bleiben geschlossen.
        $rejected.ErrorCode = 'TLS_TARGET_METADATA_UNAVAILABLE'; return $rejected
    }
}

function Get-LabAuthenticatedTlsHyperVTargetMetadata {
    [CmdletBinding()]
    param([object]$Request,[object]$InstanceId,[object]$SqlInstanceId,[object]$DataRoot)
    $ErrorActionPreference='Stop'
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_TARGET_REQUEST_INVALID'}
    $checked=Test-LabAuthenticatedTlsRequest -Request $Request
    if(-not $checked.Success -or -not (Test-LabTlsRequestEnum $checked.Value.Kind @('LEAF_PROFILE'))){return $bad}
    $leaf=$checked.Value
    if($InstanceId -isnot [string] -or $InstanceId -cnotmatch '\A[A-Za-z][A-Za-z0-9_-]{0,63}\z' -or
        $SqlInstanceId -isnot [string] -or $SqlInstanceId -cnotmatch '\A[A-Za-z][A-Za-z0-9_.-]{0,127}\z' -or
        $DataRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($DataRoot)){
        $bad.ErrorCode='TLS_TARGET_SELECTOR_INVALID';return $bad
    }
    if(-not (Test-LabTlsRequestEnum $leaf.Provider @('hyperv'))){$bad.ErrorCode='TLS_TARGET_PROVIDER_UNSUPPORTED';return $bad}
    try{
        $binding=Get-LabDiagnosticBinding -RunId $leaf.TargetRef -InstanceId $InstanceId -DataRoot $DataRoot -Provider hyperv
        if(-not (Test-LabTlsRequestEnum $binding.Run.metadata.workflowKind @('hyperv-lab')) -or
            -not (Test-LabTlsRequestEnum $binding.Instance.Version @($leaf.SqlVersion))){throw 'TLS_TARGET_METADATA_MISMATCH'}
        $sub=@($binding.Run.providerSubRuns|Where-Object { [string]::Equals($_.provider,'hyperv',[StringComparison]::Ordinal) })
        if(-not (Test-LabTlsRequestEnum $binding.Run.state @('RUNNING')) -or $sub.Count -ne 1 -or
            -not (Test-LabTlsRequestEnum $sub[0].state @('RUNNING'))){$bad.ErrorCode='TLS_TARGET_STATE_UNSUPPORTED';return $bad}
        # Hyper-V schreibt seine VM-/SQL-Daten in diese feste Datei; keine
        # Workflowfunktion aufrufen, die Namen reparieren oder VMs abfragen kann.
        $connection=Read-LabDiagnosticJson -Path (Join-Path $binding.Directory 'connection-info.json') -MaximumBytes 262144 -MaximumDepth 20
        if(($connection.schemaVersion -isnot [int] -and $connection.schemaVersion -isnot [long]) -or
            $connection.schemaVersion -ne 1 -or $connection.instances -isnot [array] -or $connection.instances.Count -ne 1){throw 'TLS_TARGET_METADATA_MISMATCH'}
        $vm=$connection.instances[0]
        if(-not (Test-LabTlsRequestEnum $vm.id @($InstanceId)) -or -not (Test-LabTlsRequestEnum $vm.provider @('hyperv')) -or
            -not (Test-LabTlsRequestEnum $vm.workload @('sql')) -or -not (Test-LabTlsRequestEnum $vm.sqlVersion @($leaf.SqlVersion)) -or
            $vm.vmId -isnot [string] -or -not (Test-LabDiagnosticGuid $vm.vmId) -or
            $vm.vmName -isnot [string] -or [string]::IsNullOrWhiteSpace($vm.vmName) -or $vm.vmName.Length -gt 256 -or
            -not (Test-LabTlsRequestEnum $vm.host @($leaf.Identity.Value)) -or
            ($vm.port -isnot [int] -and $vm.port -isnot [long]) -or $vm.port -ne $leaf.Port -or
            $vm.sqlInstances -isnot [array] -or $vm.sqlInstances.Count -lt 1 -or $vm.sqlInstances.Count -gt 64){throw 'TLS_TARGET_METADATA_MISMATCH'}
        $sqlIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($item in $vm.sqlInstances){
            if($item.InstanceId -isnot [string] -or $item.InstanceId -cnotmatch '\A[A-Za-z][A-Za-z0-9_.-]{0,127}\z' -or
                -not $sqlIds.Add($item.InstanceId)){throw 'TLS_TARGET_METADATA_MISMATCH'}
        }
        $selected=@($vm.sqlInstances|Where-Object { [string]::Equals($_.InstanceId,$SqlInstanceId,[StringComparison]::Ordinal) })
        if($selected.Count -ne 1){throw 'TLS_TARGET_METADATA_MISMATCH'}
        $sql=$selected[0]
        if($sql.ServiceName -isnot [string] -or $sql.ServiceName -cnotmatch '\A(?:MSSQLSERVER|MSSQL\$[A-Za-z][A-Za-z0-9_]{0,63})\z' -or
            -not (Test-LabTlsRequestEnum $sql.ServiceStatus @('Running')) -or
            ($sql.TcpPort -isnot [int] -and $sql.TcpPort -isnot [long]) -or $sql.TcpPort -ne $leaf.Port){throw 'TLS_TARGET_METADATA_MISMATCH'}
        if($sql.Name -isnot [string] -or $sql.Name -cnotmatch '\A[A-Za-z][A-Za-z0-9_]{0,63}\z' -or
            $sql.IsDefault -isnot [bool] -or
            ($sql.IsDefault -and -not (Test-LabTlsRequestEnum $sql.Name @('MSSQLSERVER'))) -or
            (-not $sql.IsDefault -and [string]::Equals($sql.Name,'MSSQLSERVER',[StringComparison]::OrdinalIgnoreCase))){throw 'TLS_TARGET_METADATA_MISMATCH'}
        $service=if($sql.IsDefault){'MSSQLSERVER'}else{'MSSQL$'+$sql.Name}
        if(-not [string]::Equals($sql.ServiceName,$service,[StringComparison]::Ordinal)){throw 'TLS_TARGET_METADATA_MISMATCH'}
        # Der reguläre Hyper-V-Producer lässt run.instances leer. Wenn dort
        # zusätzliche Istmetadaten vorliegen, dürfen sie die VM nicht ersetzen.
        foreach($actual in @($binding.Run.instances)){
            if(-not (Test-LabTlsRequestEnum $actual.id @($InstanceId)) -or
                -not (Test-LabTlsRequestEnum $actual.vmId @($vm.vmId))){throw 'TLS_TARGET_METADATA_MISMATCH'}
        }
        $value=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.AuthenticatedTlsHyperVTargetMetadata/0.1';Status='RECORDED';
            TargetRef=$leaf.TargetRef;InstanceId=$InstanceId;SqlInstanceId=$SqlInstanceId;ScopeId=$binding.Run.scopeId;
            Provider='hyperv';SqlVersion=$leaf.SqlVersion;VMId=$vm.vmId;ServiceName=$sql.ServiceName;Port=$leaf.Port;
            Identity=[pscustomobject][ordered]@{Kind=$leaf.Identity.Kind;Value=$leaf.Identity.Value};
            RuntimeStatus='NOT_EXECUTED';AuthorizationStatus='NOT_EVALUATED';MutationAllowed=$false}
        return [pscustomobject][ordered]@{Success=$true;Value=$value;ErrorCode=$null}
    }catch{$bad.ErrorCode='TLS_TARGET_METADATA_UNAVAILABLE';return $bad}
}
