# Synthetic transport only; memory identity, snapshots, journal and rollback stay real.
function New-LabCpuFaultRuntimeBinding {
    param($Provider)
    [ordered]@{Provider=$Provider; Invocation='synthetic'; Arguments=@(); Identity=('a'*64)}
}
function Get-LabCpuFaultRuntimeIdentity {
    param($Binding)
    if ($script:faultMode -eq 'RuntimeChanged') { return ('b'*64) }; 'a'*64
}
function Invoke-LabCpuFaultNative {
    param($Binding,[string[]]$Arguments,[int]$TimeoutMilliseconds=5000,[Security.SecureString]$Password)
    $state=[IO.File]::ReadAllText($script:providerPath) | ConvertFrom-Json -AsHashtable
    switch ($Arguments[0]) {
        'info' {
            $expected=if ($Binding.Provider -eq 'docker') { '{{json .CgroupVersion}}' } else { '{{json .Host.CgroupsVersion}}' }
            if ($Arguments.Count -ne 3 -or $Arguments[1] -cne '--format' -or $Arguments[2] -cne $expected) { throw 'FAKE_UNEXPECTED_CGROUP_PROJECTION' }
            if ($script:faultMode -eq 'CgroupUnknown') { return '"unknown"' }
            if ($script:faultMode -eq 'CgroupV1') { return $(if ($Binding.Provider -eq 'docker') { '"1"' } else { '"v1"' }) }
            return $(if ($Binding.Provider -eq 'docker') { '"2"' } else { '"v2"' })
        }
        'inspect' {
            $id=if ($Binding.Provider -eq 'podman') { '{{json .ID}}' } else { '{{json .Id}}' }
            if ($Arguments.Count -ne 4 -or $Arguments[1] -cne '--format' -or -not $Arguments[2].Contains($id) -or $Arguments[2] -match '\.Config(\s|}})|\.Env') { throw 'FAKE_UNSAFE_INSPECT' }
            if ($script:faultMode -eq 'InspectFailure' -and $state.Updates -gt 0) { throw 'CPU_FAULT_NATIVE_FAILED' }
            return ($state.Container | ConvertTo-Json -Depth 15 -Compress)
        }
        'update' {
            if ($Arguments.Count -ne 6 -or $Arguments[1] -cne '--memory' -or $Arguments[3] -cne '--memory-swap' -or $Arguments[4] -cne '6442450944' -or $Arguments[5] -cne $state.Container.Id -or $Arguments[2] -notin @('3221225472','2684354560')) { throw 'FAKE_UNEXPECTED_UPDATE' }
            $restore=$Arguments[2] -eq '3221225472'
            if ($restore -and $script:faultMode -eq 'RestoreFailure') { throw 'CPU_FAULT_NATIVE_FAILED' }
            # Podman 6.0.2 can retain the previous OCI inspect projection while
            # stopped. A successful update exit alone is not restore evidence.
            if (-not ($restore -and $Binding.Provider -eq 'podman' -and -not $state.Container.State.Running)) {
                $state.Container.HostConfig.Memory=[long]$Arguments[2]
            }
            $state.Updates++
            if ($restore) { $state.Restores++ } else { $state.Activations++ }
            if (-not $restore -and $script:faultMode -eq 'StopAfterApply') { $state.Container.State.Running=$false }
            if (-not $restore -and $script:faultMode -eq 'DriftAfterApply') { $state.Container.HostConfig.MemoryReservation=123 }
            [IO.File]::WriteAllText($script:providerPath,($state | ConvertTo-Json -Depth 15 -Compress))
            if (-not $restore -and $script:faultMode -eq 'CancelAfterApply') { $script:cancelSource.Cancel() }
            if (-not $restore -and $script:faultMode -eq 'ApplyFailure') { throw 'CPU_FAULT_NATIVE_FAILED' }
            return $state.Container.Id
        }
        'exec' {
            $state.SqlCalls++
            [IO.File]::WriteAllText($script:providerPath,($state | ConvertTo-Json -Depth 15 -Compress))
            if (-not $state.Container.State.Running) { throw 'FAKE_SQL_WHILE_STOPPED' }
            if ($script:faultMode -eq 'SqlNotReady' -or ($script:faultMode -eq 'ObservationFailure' -and $state.Activations -gt 0 -and $state.Restores -eq 0) -or ($script:faultMode -eq 'RestoreSqlFailure' -and $state.Restores -gt 0)) { throw 'MEMORY_FAULT_SQL_NOT_READY' }
            if ($script:faultMode -eq 'Timeout' -and $state.Activations -gt 0 -and $state.Restores -eq 0) { throw 'CPU_FAULT_NATIVE_TIMEOUT' }
            return 'SQL_READY'
        }
        default { throw 'FAKE_UNEXPECTED_COMMAND' }
    }
}
