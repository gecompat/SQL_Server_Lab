param([Parameter(Mandatory)]$Module)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../Common/TestTemporaryDirectory.ps1')
$owned = New-TestTemporaryDirectory -ParentPath ([IO.Path]::GetTempPath())
try {
    & $Module {
        param([string]$Root)

        $script:migrationMember = 'c' * 64
        $script:migrationOldNetwork = 'a' * 64
        $script:migrationTemporaryNetwork = 'b' * 64
        $script:migrationNewNetwork = 'd' * 64
        $script:migrationNativeSteps = [Collections.Generic.List[string]]::new()
        $script:migrationNetworks = @{}
        $script:migrationFailDisconnect = $false
        $script:migrationRejectAlias = $false
        function Get-LabHostToolInvocation { 'synthetic-network-runtime' }
        function Resolve-LabTemporaryContainerNetwork {
            param($Provider,$Name,$DesiredNetwork)
            [pscustomobject]@{Name=$Name;Subnet='198.18.1.0/24'}
        }
        function Get-LabManagedContainersOnNetwork {
            param($Provider,$NetworkName,$StateRoot)
            if ($NetworkName -cne 'LabNetwork') { throw 'UNEXPECTED_NETWORK_READ' }
            [pscustomobject]@{Id=$script:migrationMember;WasRunning=$true
                Aliases=@(if (-not $script:migrationRejectAlias) { 'lab-alias' })}
        }
        function Invoke-LabRunArtifactPinnedProcess {
            param($Context,$Arguments,$Invocation,$TimeoutSeconds)
            if ($Context.Provider -cne 'docker' -or $Context.Endpoint -cne 'npipe://synthetic-network-runtime' -or
                $Invocation -cne 'synthetic-network-runtime' -or $TimeoutSeconds -ne 90) {
                throw 'UNEXPECTED_MIGRATION_ROUTE'
            }
            $ArgumentList = $Arguments
            $script:migrationNativeSteps.Add($ArgumentList -join ' ')
            $exitCode = 0
            $stdout = ''
            if ($ArgumentList[0] -ceq 'network') {
                $target = $ArgumentList[-1]
                switch ($ArgumentList[1]) {
                    'create' {
                        $id = if ($target -ceq 'LabNetwork') { $script:migrationNewNetwork } else { $script:migrationTemporaryNetwork }
                        $mark = @($ArgumentList | Where-Object { $_ -cmatch '^sql-server-lab\.migration-id=[0-9a-f-]{36}$' })
                        if ($mark.Count -ne 1 -or 'sql-server-lab.network=managed' -cnotin $ArgumentList) { throw 'OWNERSHIP_MARKER_NOT_SET' }
                        $script:migrationNetworks[$target] = @{
                            Name=$target; Id=$id; Labels=@{'sql-server-lab.network'='managed';'sql-server-lab.migration-id'=($mark[0] -split '=')[1]}
                            IPAM=@{Config=@(@{Subnet=$ArgumentList[5]})}
                        }
                    }
                    'inspect' {
                        $record = $script:migrationNetworks[$target]
                        if (-not $record) { throw 'UNEXPECTED_NETWORK_INSPECT' }
                        $stdout = ConvertTo-Json -InputObject @($record) -Depth 6 -Compress
                    }
                    'connect' {
                        if ($target -cne $script:migrationMember -or $ArgumentList[-2] -cnotin @($script:migrationTemporaryNetwork,$script:migrationNewNetwork)) {
                            throw 'MUTABLE_NETWORK_OR_MEMBER_TARGET'
                        }
                    }
                    'disconnect' {
                        if ($target -cne $script:migrationMember -or $ArgumentList[-2] -cnotin @($script:migrationTemporaryNetwork,$script:migrationOldNetwork)) {
                            throw 'MUTABLE_NETWORK_OR_MEMBER_TARGET'
                        }
                        if ($script:migrationFailDisconnect) { $exitCode = 1 }
                    }
                    'rm' {
                        if ($target -cnotin @($script:migrationOldNetwork,$script:migrationTemporaryNetwork)) { throw 'FOREIGN_NETWORK_REMOVE' }
                    }
                    default { throw 'UNEXPECTED_NETWORK_OPERATION' }
                }
            } elseif ($ArgumentList[0] -cin @('start','stop')) {
                if ($ArgumentList[-1] -cne $script:migrationMember) { throw 'MUTABLE_POWER_TARGET' }
            } else { throw 'UNEXPECTED_MIGRATION_COMMAND' }
            [pscustomobject]@{ExitCode=$exitCode;Stdout=$stdout}
        }
        $route = @{
            Provider='docker'; StateRoot=$null; Binding=('a'*64); Invocation='synthetic-network-runtime'
            Context=[pscustomobject]@{ Provider='docker'; Endpoint='npipe://synthetic-network-runtime' }
        }

        $plan = [pscustomobject]@{
            ConfiguredSubnet='172.26.0.0/16'
            Actual=[pscustomobject]@{Name='LabNetwork';Subnet='172.26.0.0/16';Id=$script:migrationOldNetwork}
            Desired=[pscustomobject]@{Name='LabNetwork';Subnet='198.18.0.0/24'}
            ManagedContainers=@([pscustomobject]@{Id=$script:migrationMember;RunId='11111111-1111-1111-1111-111111111111'
                Name='synthetic-member';WasRunning=$true;Aliases=@('lab-alias')})
        }
        $successfulRoot = Join-Path $Root 'success'
        $route.StateRoot=$successfulRoot
        $result = Invoke-LabBoundContainerNetworkMigration -Route $route -Plan $plan
        $journal = Read-LabWorkflowJson -Path (Get-LabContainerNetworkMigrationJournalPath -Provider docker -StateRoot $successfulRoot)
        $aliasStep = @($script:migrationNativeSteps | Where-Object { $_ -ceq ('network connect --alias lab-alias '+$script:migrationNewNetwork+' '+$script:migrationMember) })
        $temporaryStep = @($script:migrationNativeSteps | Where-Object { $_ -clike 'network create --driver bridge --subnet 198.18.1.0/24 *-migration-*' })
        if ($result.Status -cne 'SUCCEEDED' -or $journal.Status -cne 'COMPLETED' -or $journal.NewNetwork.Id -cne $script:migrationNewNetwork -or
            $journal.TemporaryNetwork.Id -cne $script:migrationTemporaryNetwork -or $journal.TemporaryNetwork.Subnet -cne '198.18.1.0/24' -or
            $journal.TemporaryNetwork.Subnet -ceq $journal.NewNetwork.Subnet -or $temporaryStep.Count -ne 1 -or $aliasStep.Count -ne 1) {
            throw 'BOUND_MIGRATION_SYNTHETIC_POSTCONDITION'
        }
        $configured = [pscustomobject]@{Name='LabNetwork';Subnet='172.26.0.0/16';PrefixLength=16;HostAddress='172.26.0.1'}
        $record = $script:migrationNetworks.LabNetwork | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        if (-not (Test-LabSettledContainerNetworkMigration -Provider docker -StateRoot $successfulRoot -ConfiguredNetwork $configured -ObservedNetwork $record -ObservedSubnet '198.18.0.0/24')) {
            throw 'BOUND_MIGRATION_SETTLED_NETWORK_REJECTED'
        }
        $record.Id = 'e' * 64
        if (Test-LabSettledContainerNetworkMigration -Provider docker -StateRoot $successfulRoot -ConfiguredNetwork $configured -ObservedNetwork $record -ObservedSubnet '198.18.0.0/24') {
            throw 'BOUND_MIGRATION_REPLACEMENT_FALLBACK_ACCEPTED'
        }
        Set-LabMigratedContainerNetworkSubnet -Network $configured -Subnet '198.18.0.0/24'
        if ($configured.PrefixLength -ne 24 -or $configured.Subnet -cne '198.18.0.0/24' -or $configured.HostAddress -cne '198.18.0.1') {
            throw 'BOUND_MIGRATION_SETTLED_NETWORK_NOT_PROJECTED'
        }

        $script:migrationNativeSteps.Clear()
        $script:migrationFailDisconnect = $true
        $failedRoot = Join-Path $Root 'failed'
        $route.StateRoot=$failedRoot
        $failure = try { Invoke-LabBoundContainerNetworkMigration -Route $route -Plan $plan | Out-Null; '' }
            catch { $_.Exception.Message }
        $failedPath = Get-LabContainerNetworkMigrationJournalPath -Provider docker -StateRoot $failedRoot
        $failed = Read-LabWorkflowJson -Path $failedPath
        $before = (Get-FileHash -LiteralPath $failedPath -Algorithm SHA256).Hash
        $stepCount = $script:migrationNativeSteps.Count
        $blocked = New-LabContainerNetworkMigrationPlan -Provider docker -StateRoot $failedRoot
        if ($failure -cne 'LAB_NETWORK_MIGRATION_DISCONNECT_FAILED' -or $failed.Status -cne 'RECOVERY_REQUIRED' -or
            $failed.TemporaryNetwork.Id -cne $script:migrationTemporaryNetwork -or
            @($script:migrationNativeSteps | Where-Object { $_ -like 'network rm *' }).Count -or
            $blocked.Reason -cne 'LAB_NETWORK_MIGRATION_PENDING_RECOVERY' -or
            $blocked.Recovery.LastRecordedPhase -cne 'TEMPORARY_NETWORK_READY' -or
            $blocked.Recovery.FailureCode -cne $failure -or
            $stepCount -ne $script:migrationNativeSteps.Count -or
            $before -cne (Get-FileHash -LiteralPath $failedPath -Algorithm SHA256).Hash) {
            throw 'BOUND_MIGRATION_RECOVERY_GUARD'
        }
        function Get-LabStateRoot { $failedRoot }
        function Read-LabConfirm { throw 'BLOCKED_RECOVERY_OFFERED_MUTATION' }
        function Select-LabConsoleDataItem { 'docker' }
        function Read-LabConsoleTextInput { [pscustomobject]@{Status='Confirmed';Value=''} }
        function Wait-LabConsoleAcknowledgement { }
        $query = [Collections.Specialized.NameValueCollection]::new()
        $query.Add('provider','docker')
        $http = Invoke-LabContainerNetworkPlanRequest -Method GET -Query $query
        $console = @(Show-LabContainerNetworkMigrationPlanInteractive 6>&1) -join "`n"
        if ($http.StatusCode -ne 200 -or $http.View.Status -cne 'MIGRATION_BLOCKED' -or
            $http.View.Recovery.FailureCode -cne $failure -or
            $http.View.Recovery.PSObject.Properties.Name.Count -ne 2 -or $http.View.Contains('PlanKey') -or
            $console -notmatch 'TEMPORARY_NETWORK_READY.*LAB_NETWORK_MIGRATION_DISCONNECT_FAILED') {
            throw 'BOUND_MIGRATION_RECOVERY_VIEW_NOT_GUIDED'
        }
        $failed.PSObject.Properties.Remove('LastRecordedPhase')
        $failed.Error = 'LAB_NETWORK_MIGRATION_UNKNOWN_PRIVATE_DETAIL'
        Write-LabArtifactJsonAtomic -Path $failedPath -InputObject $failed
        $legacy = New-LabContainerNetworkMigrationPlan -Provider docker -StateRoot $failedRoot
        if ($legacy.Recovery.LastRecordedPhase -cne 'UNKNOWN' -or $legacy.Recovery.FailureCode -cne 'UNKNOWN') {
            throw 'BOUND_MIGRATION_UNKNOWN_JOURNAL_FIELD_DISCLOSED'
        }
        Set-Content -LiteralPath $failedPath -Value '{' -Encoding utf8
        $unreadable = New-LabContainerNetworkMigrationPlan -Provider docker -StateRoot $failedRoot
        if ($unreadable.Reason -cne 'LAB_NETWORK_MIGRATION_PENDING_RECOVERY' -or $unreadable.Recovery.FailureCode -cne 'UNKNOWN') {
            throw 'BOUND_MIGRATION_UNREADABLE_JOURNAL_NOT_BLOCKED'
        }

        $script:migrationFailDisconnect = $false
        $script:migrationRejectAlias = $true
        $aliasRoot = Join-Path $Root 'alias'
        $route.StateRoot=$aliasRoot
        $failure = try { Invoke-LabBoundContainerNetworkMigration -Route $route -Plan $plan | Out-Null; '' }
            catch { $_.Exception.Message }
        $aliasJournal = Read-LabWorkflowJson -Path (Get-LabContainerNetworkMigrationJournalPath -Provider docker -StateRoot $aliasRoot)
        if ($failure -cne 'LAB_NETWORK_MIGRATION_POSTCONDITION_UNCONFIRMED' -or $aliasJournal.Status -cne 'RECOVERY_REQUIRED') {
            throw 'BOUND_MIGRATION_FALSE_SUCCESS'
        }
        Write-Host 'PASS: Netz-Effekte verwenden gebundene IDs. Teilfehler sperren weitere Ausführung und fehlende Aliasse verhindern Erfolg.'
    } $owned.Path
}
finally { Remove-TestTemporaryDirectory -OwnedDirectory $owned }
