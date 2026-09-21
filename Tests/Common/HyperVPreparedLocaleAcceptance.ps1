function Assert-HyperVPreparedLocaleDispatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    if ($Context.EventName -cne 'workflow_dispatch') { throw 'PREPARED_LOCALE_MANUAL_DISPATCH_REQUIRED' }
    if (-not $Context.Repository -or $Context.EventRepository -cne $Context.Repository) { throw 'PREPARED_LOCALE_REPOSITORY_MISMATCH' }
    if ($Context.CloneSourceRunId) { throw 'PREPARED_LOCALE_CLONE_SOURCE_FORBIDDEN' }
    if ($Context.ArtifactId -cnotmatch '^hyperv-sql-prepared-sealed-[a-f0-9]{64}$') { throw 'PREPARED_LOCALE_EXPLICIT_ARTIFACT_REQUIRED' }
    if ($Context.ExpectedCommit -cnotmatch '^[a-f0-9]{40}$' -or $Context.CheckoutCommit -cne $Context.ExpectedCommit) {
        throw 'PREPARED_LOCALE_CHECKOUT_MISMATCH'
    }
}

function New-HyperVPreparedLocaleManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArtifactId, [Parameter(Mandatory)][string]$OperationId)
    [ordered]@{
        name = 'prepared-locale-' + $OperationId.Substring(0,8)
        automation = @{ mode = 'unattended' }
        instances = @(@{
            id='primary'; version='2025'; provider='hyperv'; os='windows'; profile='standard'; autostart='off'
            network = @{ intent='hostOnly'; exposure='host' }
            windowsActivation = @{
                ContractVersion='SqlServerLab.WindowsActivationIntent/1.0'
                Strategy='EvaluationOnline'; EgressPolicy='AllowTemporary'
            }
            windowsLocale = @{
                ContractVersion='SqlServerLab.WindowsLocaleIntent/1.0'; Region='US'
                SystemLocale='en-US'; UiLanguage='en-US'; InputLocale='0409:00000409'; TimeZone='Pacific Standard Time'
            }
            hyperv = @{
                preparedImageId=$ArtifactId; memoryStartupMB=6144; processorCount=4; sqlPort=1433; guestPasswordMode='prompt'
            }
        })
    }
}

function Get-HyperVPreparedLocaleGuestProbe {
    [CmdletBinding()]
    param()
    return {
        $ErrorActionPreference='Stop'
        [pscustomobject]@{
            GeoId=[int](Get-WinHomeLocation).GeoId
            SystemLocale=[string](Get-WinSystemLocale)
            UiLanguage=[string](Get-WinUILanguageOverride)
            InputLocale=[string](Get-WinDefaultInputMethodOverride).InputMethodTip
            TimeZone=[string](Get-TimeZone).Id
        }
    }
}

function Assert-HyperVPreparedLocaleObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Observation)
    if ($Observation.GeoId -ne 244 -or $Observation.SystemLocale -cne 'en-US' -or
        $Observation.UiLanguage -cne 'en-US' -or $Observation.InputLocale -cne '0409:00000409' -or
        $Observation.TimeZone -cne 'Pacific Standard Time') { throw 'PREPARED_LOCALE_GUEST_MISMATCH' }
}

function Get-HyperVPreparedLocaleBoundContext {
    [CmdletBinding()]
    param([string]$OperationId, [string]$RunId, [string]$ScopeId, [string]$VmId, [string]$StateRoot)
    $parsedId=[guid]::Empty
    if (-not [guid]::TryParse($VmId,[ref]$parsedId) -or $parsedId -eq [guid]::Empty) { throw 'PREPARED_LOCALE_VM_ID_REQUIRED' }
    $owned=Get-LabOperationOwnedRun -OperationId $OperationId -StateRoot $StateRoot
    if (-not $owned -or $owned.runId -cne $RunId -or $owned.scopeId -cne $ScopeId -or
        $owned.metadata.workflowOperationId -cne $OperationId) { throw 'PREPARED_LOCALE_OPERATION_MISMATCH' }
    $context=Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    if ($context.Run.runId -cne $RunId -or $context.Run.scopeId -cne $ScopeId -or
        $context.Run.metadata.workflowOperationId -cne $OperationId -or $context.Instance.vmId -cne $VmId) {
        throw 'PREPARED_LOCALE_CONTEXT_CHANGED'
    }
    $managed=Get-HyperVManagedVM -VMName $context.Instance.vmName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId
    if (-not $managed -or [string]$managed.VM.Id -cne $VmId -or $managed.Identity.instanceId -cne 'primary') {
        throw 'PREPARED_LOCALE_VM_ID_MISMATCH'
    }
    $context | Add-Member -NotePropertyName BoundVmState -NotePropertyValue ([string]$managed.VM.State) -Force
    return $context
}

function Invoke-HyperVPreparedLocaleColdStart {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Binding)
    $context=Get-HyperVPreparedLocaleBoundContext @Binding
    if ($context.BoundVmState -cne 'Running') { throw 'PREPARED_LOCALE_INITIAL_VM_NOT_RUNNING' }
    $null=Stop-SqlServerLab -RunId $Binding.RunId -StateRoot $Binding.StateRoot -Force -Confirm:$false
    $context=Get-HyperVPreparedLocaleBoundContext @Binding
    if ($context.BoundVmState -cne 'Off') { throw 'PREPARED_LOCALE_COLD_STOP_REQUIRED' }
    # Revalidated immediately before the existing run-bound start operation.
    $null=Start-HyperVLabEnvironment -RunId $Binding.RunId -StateRoot $Binding.StateRoot
    $context=Get-HyperVPreparedLocaleBoundContext @Binding
    if ($context.BoundVmState -cne 'Running') { throw 'PREPARED_LOCALE_COLD_START_FAILED' }
    return $context
}

function Wait-HyperVPreparedLocaleGuest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Binding, [ValidateRange(1,600)][int]$TimeoutSeconds=600)
    $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $loaded=$null; $password=$null
    try {
        $context=Get-HyperVPreparedLocaleBoundContext @Binding
        $loaded=Get-LabSecret -Path $context.RunDirectory -Name 'guest-administrator-password'
        if (-not $loaded) { throw 'PREPARED_LOCALE_GUEST_CREDENTIAL_REQUIRED' }
        $password=$loaded.Copy(); $password.MakeReadOnly()
        do {
            $context=Get-HyperVPreparedLocaleBoundContext @Binding
            try {
                $remaining=[math]::Max(1,[int][math]::Ceiling(($deadline-[datetime]::UtcNow).TotalSeconds))
                $results=@(Invoke-HyperVPowerShellDirect -VMName $context.Instance.vmName -ExpectedRunId $Binding.RunId `
                    -ExpectedScopeId $Binding.ScopeId -ExpectedVmId ([guid]$Binding.VmId) `
                    -Credential ([pscredential]::new('Administrator',$password)) -TimeoutSeconds ([math]::Min(30,$remaining)) `
                    -ScriptBlock (Get-HyperVPreparedLocaleGuestProbe))
                if ($results.Count -ne 1) { throw 'PREPARED_LOCALE_GUEST_PROBE_INVALID' }
                Assert-HyperVPreparedLocaleObservation -Observation $results[0]
                return $results[0]
            }
            catch {
                # Only transport startup is retried; identity and locale failures stop immediately.
                if ($_.CategoryInfo.Category -ne 'OpenError' -and $_.Exception.Message -notmatch '^GUEST_JOB_OPERATION_TIMEOUT') { throw }
            }
            if ([datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 500 }
        } while ([datetime]::UtcNow -lt $deadline)
        throw 'PREPARED_LOCALE_GUEST_TIMEOUT'
    }
    finally {
        if ($password) { $password.Dispose() }
        if ($loaded) { $loaded.Dispose() }
    }
}

function Wait-HyperVPreparedLocaleSql {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Binding, [ValidateRange(1,300)][int]$TimeoutSeconds=300)
    $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $null=Get-HyperVPreparedLocaleBoundContext @Binding
        $context=Get-LabSqlGuestCaptureContext -RunId ([guid]$Binding.RunId) -StateRoot $Binding.StateRoot
        if ($context.Instance.vmId -cne $Binding.VmId) { throw 'PREPARED_LOCALE_SQL_VM_CHANGED' }
        try {
            $remaining=[math]::Max(1,[int][math]::Ceiling(($deadline-[datetime]::UtcNow).TotalSeconds))
            $sql=Invoke-LabSqlGuestCaptureProbe -Context $context -TimeoutSeconds ([math]::Min(30,$remaining))
            if ($sql.MajorVersion -ne 17 -or $sql.InstanceName -cne $context.Instance.sqlReadiness.instanceName -or
                $sql.Edition -cne $context.Instance.sqlReadiness.edition) { throw 'PREPARED_LOCALE_SQL_IDENTITY_MISMATCH' }
            return $sql
        }
        catch { if ($_.Exception.Message -cne 'SQL_GUEST_CAPTURE_PROBE_FAILED') { throw } }
        if ([datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 500 }
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'PREPARED_LOCALE_SQL_TIMEOUT'
}

function Remove-HyperVPreparedLocaleOwnRun {
    [CmdletBinding()]
    param([string]$OperationId, [string]$StateRoot, [string]$RunId, [string]$ScopeId, [string]$VmId)
    $owned=Get-LabOperationOwnedRun -OperationId $OperationId -StateRoot $StateRoot
    if (-not $owned) {
        if ($RunId) { throw 'PREPARED_LOCALE_CLEANUP_OWNERSHIP_LOST' }
        return
    }
    if ($owned.metadata.workflowOperationId -cne $OperationId -or ($RunId -and $owned.runId -cne $RunId) -or
        ($ScopeId -and $owned.scopeId -cne $ScopeId)) { throw 'PREPARED_LOCALE_CLEANUP_OPERATION_MISMATCH' }
    $resources=@(foreach ($vm in @(Get-HyperVLabVMs -RunId $owned.runId -ScopeId $owned.scopeId)) {
        $managed=Get-HyperVManagedVM -VMName $vm.VMName -ExpectedRunId $owned.runId -ExpectedScopeId $owned.scopeId
        $resourceId=[guid]::Empty
        if (-not $managed -or -not [guid]::TryParse([string]$managed.VM.Id,[ref]$resourceId) -or
            $resourceId -eq [guid]::Empty -or ($VmId -and [string]$managed.VM.Id -cne $VmId)) {
            throw 'PREPARED_LOCALE_CLEANUP_VM_MISMATCH'
        }
        [pscustomobject]@{Id=$resourceId; Paths=@($managed.Identity.childVhdxPath)+@($managed.Identity.additionalVhdxPaths)}
    })
    $ids=@($resources.Id)
    if ($VmId -and ([guid]$VmId) -notin $ids) { $ids+=([guid]$VmId) }
    $removed=Remove-SqlServerLab -RunId $owned.runId -StateRoot $StateRoot -Force -Confirm:$false
    if ($removed.Status -cne 'REMOVED' -or $removed.Cleanup -cne 'CLEANUP_SUCCEEDED' -or
        @(Get-HyperVLabVMs -RunId $owned.runId -ScopeId $owned.scopeId).Count -ne 0) { throw 'PREPARED_LOCALE_CLEANUP_FAILED' }
    foreach ($id in $ids) {
        try { $remaining=@(Get-VM -Id $id -ErrorAction Stop) }
        catch { if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }; $remaining=@() }
        if ($remaining.Count -ne 0) { throw 'PREPARED_LOCALE_CLEANUP_VM_REMAINS' }
    }
    if (@($resources.Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) }).Count -ne 0) { throw 'PREPARED_LOCALE_CLEANUP_DISK_REMAINS' }
    Write-Host 'PASS: CLEANUP_SUCCEEDED; operation-owned VM IDs and child disks absent'
}

function Invoke-HyperVPreparedLocaleScenario {
    [CmdletBinding()]
    param([string]$ArtifactId, [string]$StateRoot, [string]$OperationId, [string]$WorkingDirectory, [switch]$DeferCleanup)
    $run=$null; $binding=$null; $guest=$null; $sa=$null; $primaryFailure=$null; $cleanupFailure=$null
    $arrangeStarted=$false
    try {
        $artifact=Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot
        if ($artifact.artifactState -cne 'SQL_PREPARED_SEALED' -or $artifact.sql.version -cne '2025' -or
            $artifact.operatingSystem.language -cne 'en-US' -or
            $artifact.integrityVerification.status -cnotin @('VERIFIED_HASH','VERIFIED_CACHE')) {
            throw 'PREPARED_LOCALE_ARTIFACT_INVALID'
        }
        $parentHash=(Get-FileHash -LiteralPath $artifact.Path -Algorithm SHA256).Hash
        if ($parentHash -ine $artifact.sha256) { throw 'PREPARED_LOCALE_PARENT_HASH_INVALID' }
        $null=New-Item -ItemType Directory -Path $WorkingDirectory -Force
        $manifestPath=Join-Path $WorkingDirectory 'manifest.json'
        $manifest=New-HyperVPreparedLocaleManifest -ArtifactId $ArtifactId -OperationId $OperationId
        $manifest | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $manifestPath -Encoding utf8
        if (-not (Test-SqlServerLabManifest -Path $manifestPath).IsValid) { throw 'PREPARED_LOCALE_MANIFEST_INVALID' }
        $guest=New-HyperVSqlUnattendedPassword; $sa=New-HyperVSqlUnattendedPassword
        $arrangeStarted=$true
        $run=Invoke-WithLabWorkflowOperationContext -OperationId $OperationId -ScriptBlock {
            param($Path,$GuestPassword,$SqlPassword,$Root)
            New-SqlServerLab -Manifest $Path -GuestPassword $GuestPassword -SqlSaPassword $SqlPassword -StateRoot $Root -NonInteractive
        } -ArgumentList @($manifestPath,$guest,$sa,$StateRoot)
        if ($run.State -cne 'RUNNING') { throw 'PREPARED_LOCALE_INITIAL_SQL_NOT_READY' }
        $binding=@{
            OperationId=$OperationId; RunId=[string]$run.RunId; ScopeId=[string]$run.ScopeId
            VmId=[string]$run.Instances[0].vmId; StateRoot=$StateRoot
        }
        $null=Invoke-HyperVPreparedLocaleColdStart -Binding $binding
        $observed=Wait-HyperVPreparedLocaleGuest -Binding $binding
        $sql=Wait-HyperVPreparedLocaleSql -Binding $binding
        Write-Host 'PASS: exact own VM identity, US locale and SQL SELECT major 17 after cold start'
        $context=Get-HyperVPreparedLocaleBoundContext @binding
        $license=Get-HyperVWindowsSlotLicenseStatus -RunId $run.RunId -StateRoot $StateRoot
        if ($license.State -cnotin @('LICENSED','EVALUATION_ACTIVE')) { throw 'PREPARED_LOCALE_ACTIVATION_REQUIRED' }
        $activationPath=Join-Path $context.RunDirectory 'windows-activation-network.json'
        if (Test-Path -LiteralPath $activationPath) {
            $activation=Get-Content -LiteralPath $activationPath -Raw | ConvertFrom-Json -Depth 20
            $managed=Get-HyperVManagedVM -VMName $context.Instance.vmName -ExpectedRunId $binding.RunId -ExpectedScopeId $binding.ScopeId
            if ($activation.Status -cne 'CLEANED' -or
                @(Get-VMNetworkAdapter -VM $managed.VM | Where-Object Id -eq $activation.AdapterId).Count -ne 0) {
                throw 'PREPARED_LOCALE_ACTIVATION_ADAPTER_REMAINS'
            }
        }
        $receipt=Get-Content -LiteralPath (Join-Path $context.RunDirectory 'windows-locale-receipt.json') -Raw | ConvertFrom-Json -Depth 20
        Assert-LabWindowsLocaleReceipt -Receipt $receipt -Intent $manifest.instances[0].windowsLocale -RunId $binding.RunId
        foreach ($field in @('Region','SystemLocale','UiLanguage','InputLocale','TimeZone')) {
            if ($receipt.Intent.$field -cne $manifest.instances[0].windowsLocale.$field -or
                $context.Instance.windowsLocale.$field -cne $manifest.instances[0].windowsLocale.$field) {
                throw 'PREPARED_LOCALE_RECEIPT_INTENT_MISMATCH'
            }
        }
        if ((Get-FileHash -LiteralPath $artifact.Path -Algorithm SHA256).Hash -cne $parentHash) { throw 'PREPARED_LOCALE_PARENT_CHANGED' }
        Write-Host 'PASS: locale receipt, active Windows and unchanged Prepared parent'
        [pscustomobject]@{Status='VERIFIED';SqlMajorVersion=$sql.MajorVersion;GeoId=$observed.GeoId}
    }
    catch { $primaryFailure=$_ }
    finally {
        try {
            $cleanup=@{OperationId=$OperationId;StateRoot=$StateRoot}
            if ($run) { $cleanup.RunId=[string]$run.RunId }
            if ($binding) { $cleanup.ScopeId=$binding.ScopeId; $cleanup.VmId=$binding.VmId }
            if ($arrangeStarted -and -not $DeferCleanup) { Remove-HyperVPreparedLocaleOwnRun @cleanup }
        }
        catch { $cleanupFailure=$_ }
        finally {
            if ($guest) { $guest.Dispose() }
            if ($sa) { $sa.Dispose() }
        }
    }
    if ($cleanupFailure) {
        if ($primaryFailure) {
            $code=[regex]::Match($primaryFailure.Exception.Message,'^(?:PREPARED_LOCALE_|SQL_GUEST_CAPTURE_|WINDOWS_ACTIVATION_)[A-Z0-9_]+').Value
            Write-Warning ('PRIMARY_FAILURE: '+$(if($code){$code}else{'UNCLASSIFIED_NATIVE_FAILURE'}))
        }
        Write-Warning 'RECOVERY_REQUIRED: operation-owned Prepared-locale cleanup failed; preserve its run state.'
        throw 'PREPARED_LOCALE_CLEANUP_REQUIRED'
    }
    if ($primaryFailure) { throw $primaryFailure }
}
