# Synthetic provider boundary; product identity, journal and recovery code remain real.
function New-LabCpuFaultRuntimeBinding {
    param($Provider)
    [ordered]@{ Provider=$Provider; Invocation='synthetic'; Arguments=@(); Identity=('a' * 64) }
}
function Get-LabCpuFaultRuntimeIdentity { param($Binding) if ($script:faultMode -eq 'RuntimeChanged') { return ('b' * 64) }; 'a' * 64 }
function Invoke-LabCpuFaultNative {
    param($Binding,[string[]]$Arguments,[int]$TimeoutMilliseconds=5000,[Security.SecureString]$Password)
    $state = [IO.File]::ReadAllText($script:providerPath) | ConvertFrom-Json -AsHashtable
    switch ($Arguments[0]) {
        'inspect' {
            if ($script:faultMode -eq 'InspectFailure' -and $state.Updates -gt 0) { throw 'CPU_FAULT_NATIVE_FAILED' }
            return ($state.Container | ConvertTo-Json -Depth 15 -Compress)
        }
        'update' {
            $restore = $Arguments -contains '2' -or $Arguments -contains '200000'
            if ($restore -and $script:faultMode -eq 'RestoreFailure') { throw 'CPU_FAULT_NATIVE_FAILED' }
            if ($Arguments -contains '--cpus') { $state.Container.HostConfig.NanoCpus= $(if ($restore) { 2000000000 } else { 1000000000 }) }
            else {
                $state.Container.HostConfig.CpuQuota=$(if ($restore) { 200000 } else { 100000 })
                if ($state.Container.HostConfig.NanoCpus -gt 0) { $state.Container.HostConfig.NanoCpus=$(if ($restore) { 2000000000 } else { 1000000000 }) }
            }
            $state.Updates++
            if ($restore) { $state.Restores++ } else { $state.Activations++ }
            [IO.File]::WriteAllText($script:providerPath,($state | ConvertTo-Json -Depth 15 -Compress))
            if (-not $restore -and $script:faultMode -eq 'CancelAfterApply') { $script:cancelSource.Cancel() }
            if (-not $restore -and $script:faultMode -eq 'Crash') { [Threading.Thread]::Sleep(30000) }
            if (-not $restore -and $script:faultMode -eq 'ApplyFailure') { throw 'CPU_FAULT_NATIVE_FAILED' }
            return $state.Container.Id
        }
        'exec' {
            if ($script:faultMode -eq 'SqlNotReady' -or ($script:faultMode -eq 'ObservationFailure' -and $state.Activations -gt 0 -and $state.Restores -eq 0)) { throw 'CPU_FAULT_SQL_NOT_READY' }
            if ($script:faultMode -eq 'Timeout' -and $state.Activations -gt 0 -and $state.Restores -eq 0) { throw 'CPU_FAULT_NATIVE_TIMEOUT' }
            return 'SQL_READY'
        }
        default { throw 'FAKE_UNEXPECTED_COMMAND' }
    }
}
