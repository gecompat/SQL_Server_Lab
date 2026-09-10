function Remove-LabWindowsActivationAdapter {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lab)
    $path=Join-Path $Lab.RunDirectory 'windows-activation-network.json'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return}
    $journal=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 20
    $managed=Get-HyperVManagedVM -VMName $Lab.Instance.vmName -ExpectedRunId $Lab.Run.runId -ExpectedScopeId $Lab.Run.scopeId
    if($journal.ContractVersion -ne 'SqlServerLab.WindowsActivationNetwork/1.0' -or
        [string]$journal.RunId -ne [string]$Lab.Run.runId -or [string]$journal.ScopeId -ne [string]$Lab.Run.scopeId -or
        -not $managed -or -not $managed.VM.Id -or [string]$journal.VMId -ne [string]$managed.VM.Id){throw 'WINDOWS_ACTIVATION_NETWORK_OWNERSHIP_MISMATCH'}
    if($journal.Status -eq 'CLEANED'){return}
    if($journal.Status -ne 'CREATED' -or -not $journal.AdapterId -or [string]$journal.AdapterId -in @($journal.BeforeAdapterIds)){
        throw 'WINDOWS_ACTIVATION_NETWORK_RECOVERY_REQUIRED'
    }
    $adapters=@(Get-VMNetworkAdapter -VM $managed.VM -ErrorAction Stop | Where-Object {[string]$_.Id -eq [string]$journal.AdapterId})
    if($adapters.Count -gt 1){throw 'WINDOWS_ACTIVATION_NETWORK_IDENTITY_AMBIGUOUS'}
    if($adapters.Count -eq 1){
        $adapter=$adapters[0]
        $switchMatches=[string]$adapter.SwitchId -eq [string]$journal.SwitchId -or
            ([string]$journal.SwitchId -eq [string][guid]::Empty -and $journal.TargetSwitchId -and [string]$adapter.SwitchId -eq [string]$journal.TargetSwitchId)
        if([string]$adapter.VMId -ne [string]$journal.VMId -or -not $switchMatches){throw 'WINDOWS_ACTIVATION_NETWORK_OWNERSHIP_MISMATCH'}
        $adapter | Remove-VMNetworkAdapter -ErrorAction Stop
        if(@(Get-VMNetworkAdapter -VM $managed.VM -ErrorAction Stop | Where-Object {[string]$_.Id -eq [string]$journal.AdapterId}).Count){throw 'WINDOWS_ACTIVATION_NETWORK_REMOVE_NOT_CONFIRMED'}
    }
    $journal.Status='CLEANED'
    Write-LabArtifactJsonAtomic -Path $path -InputObject $journal
}

function New-LabWindowsActivationAdapter {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lab,[Parameter(Mandatory)]$ExternalSwitch)
    Remove-LabWindowsActivationAdapter -Lab $Lab
    $managed=Get-HyperVManagedVM -VMName $Lab.Instance.vmName -ExpectedRunId $Lab.Run.runId -ExpectedScopeId $Lab.Run.scopeId
    if(-not $managed.VM.Id -or -not $ExternalSwitch.Id){throw 'WINDOWS_ACTIVATION_NETWORK_IDENTITY_REQUIRED'}
    $before=@(Get-VMNetworkAdapter -VM $managed.VM -ErrorAction Stop)
    if(@($before | Where-Object {-not $_.Id -or [string]$_.VMId -ne [string]$managed.VM.Id}).Count){throw 'WINDOWS_ACTIVATION_NETWORK_IDENTITY_REQUIRED'}
    $name='SQL_SERVER_LAB_ACTIVATION_'+[guid]::NewGuid().ToString('N')
    $path=Join-Path $Lab.RunDirectory 'windows-activation-network.json'
    $journal=[pscustomobject]@{
        ContractVersion='SqlServerLab.WindowsActivationNetwork/1.0';Status='PREPARED'
        RunId=[string]$Lab.Run.runId;ScopeId=[string]$Lab.Run.scopeId;VMId=[string]$managed.VM.Id
        SwitchId=[string][guid]::Empty;TargetSwitchId=[string]$ExternalSwitch.Id;AdapterId=$null;BeforeAdapterIds=@($before | ForEach-Object {[string]$_.Id})
    }
    Write-LabArtifactJsonAtomic -Path $path -InputObject $journal
    try {
        $null=Add-VMNetworkAdapter -VM $managed.VM -Name $name -Passthru -ErrorAction Stop
    }
    finally {
        # The before-set and stable VM/switch IDs supplement the unique attempt name.
        # A partial Add failure may still have created exactly one own adapter.
        $created=@(Get-VMNetworkAdapter -VM $managed.VM -ErrorAction Stop | Where-Object {
            $_.Name -eq $name -and $_.Id -and [string]$_.Id -notin @($journal.BeforeAdapterIds) -and
            [string]$_.VMId -eq $journal.VMId -and [string]$_.SwitchId -eq $journal.SwitchId
        })
        if($created.Count -eq 1){$journal.AdapterId=[string]$created[0].Id;$journal.Status='CREATED'}
        else {$journal.Status='RECOVERY_REQUIRED'}
        Write-LabArtifactJsonAtomic -Path $path -InputObject $journal
    }
    if($journal.Status -ne 'CREATED'){throw 'WINDOWS_ACTIVATION_NETWORK_IDENTITY_REQUIRED'}
    try {
        $null=Connect-VMNetworkAdapter -VMNetworkAdapter $created[0] -VMSwitch $ExternalSwitch -ErrorAction Stop
    }
    finally {
        $attached=@(Get-VMNetworkAdapter -VM $managed.VM -ErrorAction Stop | Where-Object {[string]$_.Id -eq [string]$journal.AdapterId})
        if($attached.Count -eq 1 -and [string]$attached[0].VMId -eq $journal.VMId -and [string]$attached[0].SwitchId -eq $journal.TargetSwitchId){
            $journal.SwitchId=$journal.TargetSwitchId
            Write-LabArtifactJsonAtomic -Path $path -InputObject $journal
        }
    }
    if($journal.SwitchId -ne $journal.TargetSwitchId){throw 'WINDOWS_ACTIVATION_NETWORK_CONNECTION_NOT_CONFIRMED'}
    return $attached[0]
}
