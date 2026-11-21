function Invoke-LabCmsBoundSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('\A[a-f0-9]{64}\z')][string]$ExpectedRegistrationKey,
        [string]$StateRoot
    )

    $mutex = $null
    $acquired = $false
    $password = $null
    $export = $null
    try {
        $selection = Get-LabCmsInspectionSelection -StateRoot $StateRoot
        if (-not $selection -or $selection.Key -cne $ExpectedRegistrationKey) { throw 'CMS_BOUND_SYNC_SELECTION_CHANGED' }
        if ($selection.Provider -cnotin @('docker','podman') -or $selection.Layout.CmsShowGeneratedPasswordInName -ne $false) {
            throw 'CMS_BOUND_SYNC_SCOPE_UNSUPPORTED'
        }
        $mutex = [Threading.Mutex]::new($false, (Get-LabContainerResourceLockName -StateRoot $selection.StateRoot -RunId $selection.RunId))
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
            throw 'CMS_BOUND_SYNC_SELECTION_CHANGED'
        }
        if (-not $acquired) { throw 'CMS_BOUND_SYNC_BUSY' }

        $current = Get-LabCmsInspectionSelection -StateRoot $selection.StateRoot
        if (-not $current -or $current.Key -cne $ExpectedRegistrationKey) { throw 'CMS_BOUND_SYNC_SELECTION_CHANGED' }
        $binding = Get-LabCmsInspectionRuntimeBinding -Selection $current
        $export = Export-SqlServerLabCmsSyncScript -StateRoot $current.StateRoot -CmsProvider $current.Provider -InMemory -ErrorAction Stop 3>$null 4>$null 5>$null 6>$null
        if ($export.IncludesGeneratedPasswordAliases -ne $false -or [string]::IsNullOrWhiteSpace($export.ScriptContent) -or
            [Text.Encoding]::UTF8.GetByteCount($export.ScriptContent) -gt 4194304 -or $export.Entries -lt 0) {
            throw 'CMS_BOUND_SYNC_SCRIPT_UNAVAILABLE'
        }
        $fresh = Get-LabCmsInspectionSelection -StateRoot $current.StateRoot
        if (-not $fresh -or $fresh.Key -cne $ExpectedRegistrationKey -or
            (Get-LabCmsInspectionRuntimeBinding -Selection $fresh).Key -cne $binding.Key) { throw 'CMS_BOUND_SYNC_SELECTION_CHANGED' }

        $runDirectory = Join-Path $fresh.StateRoot ('runs/' + $fresh.RunId)
        Assert-LabCmsInspectionReadPath -Root $fresh.StateRoot -Path (Join-Path $runDirectory 'secrets/sa-password.secret')
        $password = Get-LabSecret -Path $runDirectory -Name 'sa-password' -ErrorAction Stop
        if ($password -isnot [SecureString]) { throw 'CMS_BOUND_SYNC_SECRET_UNAVAILABLE' }
        $arguments = @{
            HostName=$binding.HostName; Port=$binding.Port; ExpectedSqlMajor=$binding.ExpectedMajor
            SaPassword=$password; Query=$export.ScriptContent
        }
        $execution = Invoke-LabCmsSqlInMemory @arguments
        if (-not $execution.Success) { throw 'CMS_BOUND_SYNC_SQL_UNCONFIRMED' }

        return [pscustomobject]@{
            Status='SYNCHRONIZED'; RunId=$fresh.RunId; Provider=$fresh.Provider; Entries=[int]$export.Entries
        }
    }
    catch {
        $reason = $_.Exception.Message
        if ($reason -cnotin @('CMS_BOUND_SYNC_SELECTION_CHANGED','CMS_BOUND_SYNC_SCOPE_UNSUPPORTED','CMS_BOUND_SYNC_BUSY',
            'CMS_BOUND_SYNC_SCRIPT_UNAVAILABLE','CMS_BOUND_SYNC_SECRET_UNAVAILABLE','CMS_BOUND_SYNC_SQL_UNCONFIRMED')) {
            $reason = 'CMS_BOUND_SYNC_UNAVAILABLE'
        }
        throw $reason
    }
    finally {
        try {
            if ($password -is [SecureString]) { $password.Dispose() }
            if ($export -and $export.PSObject.Properties['ScriptContent']) { $export.ScriptContent = $null }
        }
        finally {
            if ($acquired) { $mutex.ReleaseMutex() }
            if ($mutex) { $mutex.Dispose() }
        }
    }
}
