$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVSqlPortReconcile.ps1') -Raw -Encoding utf8
$provisioningSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1') -Raw -Encoding utf8
$publicProvisioningSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1') -Raw -Encoding utf8
$acceptanceSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVSqlPortReconcileAcceptance.ps1') -Raw -Encoding utf8
$bootstrapSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVSqlPortReconcileAcceptanceBootstrap.ps1') -Raw -Encoding utf8
$manifestSchema = Get-Content -LiteralPath (Join-Path $repoRoot 'Schemas/lab-manifest.schema.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
$sqlPortSchema = $manifestSchema.definitions.instance.properties.hyperv.properties.sqlPort
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-sql-port-reconcile-' + [Guid]::NewGuid().ToString('N'))
$runId = [Guid]::NewGuid().ToString('D')
$scopeId = [Guid]::NewGuid().ToString('D')
$runDirectory = Join-Path (Join-Path $testRoot 'runs') $runId
New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru

try {
    $result = & $module {
        param($Root,$RunId,$ScopeId)
        $providerCapability=[PSCustomObject]@{Capabilities=@([PSCustomObject]@{SourceKey='hyperv-sql-port-reconcile'})}
        $declaredPortManifest=[ordered]@{
            name='hyperv-sql-port-manifest-contract'
            instances=@([ordered]@{
                id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off'
                hyperv=[ordered]@{sqlPort=14333}
            })
        }
        $declaredPortManifestJson=$declaredPortManifest|ConvertTo-Json -Depth 20
        $declaredPortManifestSchema=Test-LabManifestSchema -Json $declaredPortManifestJson
        $declaredPortResolved=Resolve-ManifestDefaults -Manifest ($declaredPortManifestJson|ConvertFrom-Json -Depth 20)
        $declaredPortIntent=New-LabSqlEndpointIntentSnapshot -Instance $declaredPortResolved.instances[0] -ProviderCapability $providerCapability

        $defaultPortManifest=[ordered]@{
            name='hyperv-sql-port-default-contract'
            instances=@([ordered]@{
                id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off'
                hyperv=[ordered]@{}
            })
        }
        $defaultPortManifestJson=$defaultPortManifest|ConvertTo-Json -Depth 20
        $defaultPortManifestSchema=Test-LabManifestSchema -Json $defaultPortManifestJson
        $defaultPortResolved=Resolve-ManifestDefaults -Manifest ($defaultPortManifestJson|ConvertFrom-Json -Depth 20)
        $defaultPortIntent=New-LabSqlEndpointIntentSnapshot -Instance $defaultPortResolved.instances[0] -ProviderCapability $providerCapability

        $invalidPortManifest=[ordered]@{
            name='hyperv-sql-port-invalid-contract'
            instances=@([ordered]@{
                id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off'
                hyperv=[ordered]@{sqlPort=65536}
            })
        }
        $invalidPortManifestSchema=Test-LabManifestSchema -Json ($invalidPortManifest|ConvertTo-Json -Depth 20)
        $intentContractValid=$declaredPortManifestSchema.IsValid -and $defaultPortManifestSchema.IsValid -and -not $invalidPortManifestSchema.IsValid -and
            $declaredPortIntent.Contract.Name -eq 'SqlServerLab.SqlEndpointIntent' -and $declaredPortIntent.CapabilityStatus -eq 'DECLARED_SUPPORTED' -and
            [int]$declaredPortResolved.instances[0].hyperv.sqlPort -eq 14333 -and [int]$declaredPortIntent.Port -eq 14333 -and
            [int]$defaultPortResolved.instances[0].hyperv.sqlPort -eq 1433 -and [int]$defaultPortIntent.Port -eq 1433

        # Exercise the real persisted-snapshot path. Only the Hyper-V ownership
        # lookup and guest read are substituted; manifest resolution, state
        # persistence, context selection, and the public plan remain real.
        $persistedSnapshot=New-LabDesiredStateSnapshot -ResolvedLab $declaredPortResolved -ProvisioningMode manifest -PersistentData $false
        $persistedRun=New-LabRunState -StateRoot $Root -ScopeId $ScopeId -Metadata @{
            name='persisted-sql-port-contract';workflowKind='hyperv-lab';desiredState=$persistedSnapshot
        } -ProviderSubRuns @([PSCustomObject]@{id='provider-hyperv';provider='hyperv';instanceIds=@('primary')})
        foreach($state in @('PROVISIONING','SQL_READY','DATABASES_CREATED','RUNNING')){
            Set-LabRunState -RunId $persistedRun.RunId -NewState $state -Reason 'Static persisted SQL port fixture' -StateRoot $Root
        }
        $persistedConnection=[PSCustomObject]@{instances=@([PSCustomObject]@{
            id='primary';provider='hyperv';vmName='private-persisted-port-vm';vmId='private-persisted-port-vm-id';port=15433
            hostSqlAccess=[PSCustomObject]@{state='READY'}
            labNetwork=[PSCustomObject]@{intent='hostOnly';hostAddress='private-persisted-host-address'}
        })}
        Write-LabArtifactJsonAtomic -Path (Join-Path $persistedRun.RunDir 'connection-info.json') -InputObject $persistedConnection
        $secretDirectory=Join-Path $persistedRun.RunDir 'secrets';New-Item -Path $secretDirectory -ItemType Directory -Force|Out-Null
        New-Item -Path (Join-Path $secretDirectory 'guest-administrator-password.secret') -ItemType File -Force|Out-Null
        $script:persistedPortActual=[PSCustomObject]@{
            Status='AVAILABLE';SqlInstanceId='MSSQL16.MSSQLSERVER';ServiceName='MSSQLSERVER';ServiceStatus='Running'
            TcpEnabled=$true;StaticPort=$true;Port=15433;SqlReachable=$true;FirewallRuleCount=1;FirewallPorts=@('15433');FirewallProtocols=@('TCP')
            FirewallRemoteAddresses=@('private-persisted-host-address');FirewallEnabled=$true;FirewallInbound=$true;FirewallAllow=$true
        }
        function Get-HyperVManagedVM {
            param([string]$VMName,[string]$ExpectedRunId,[string]$ExpectedScopeId)
            if($VMName -ne 'private-persisted-port-vm' -or $ExpectedRunId -ne [string]$persistedRun.RunId -or $ExpectedScopeId -ne [string]$persistedRun.ScopeId){
                throw 'SYNTHETIC_PERSISTED_PORT_VM_IDENTITY_MISMATCH'
            }
            [PSCustomObject]@{VM=[PSCustomObject]@{Id='private-persisted-port-vm-id';State='Running'}}
        }
        function Get-LabHyperVSqlPortReconcileCredential { param([string]$RunDirectory) $null }
        function Get-LabHyperVSqlPortActualState { param($Context,$Credential) $script:persistedPortActual }
        $persistedJournalPath=Get-LabHyperVSqlPortReconcileJournalPath -RunDirectory $persistedRun.RunDir
        $persistedStatePath=Join-Path $persistedRun.RunDir 'run-state.json'
        $persistedStateBefore=Get-Content -LiteralPath $persistedStatePath -Raw -Encoding utf8
        $persistedContext=Get-LabHyperVSqlPortReconcileContext -RunId ([string]$persistedRun.RunId) -InstanceId primary -StateRoot $Root
        $persistedPlan=Get-SqlServerLabReconcilePlan -RunId ([string]$persistedRun.RunId) -HyperVSqlPort -InstanceId primary -StateRoot $Root
        $persistedStateAfter=Get-Content -LiteralPath $persistedStatePath -Raw -Encoding utf8

        function Set-StaticPersistedPortSnapshot {
            param($Snapshot)
            $state=Get-LabRunState -RunId ([string]$persistedRun.RunId) -StateRoot $Root
            $state.metadata.desiredState=$Snapshot
            Write-LabArtifactJsonAtomic -Path $persistedStatePath -InputObject $state
        }
        function Get-StaticPersistedPortReason {
            try {
                $null=Get-LabHyperVSqlPortReconcileContext -RunId ([string]$persistedRun.RunId) -InstanceId primary -StateRoot $Root
                return 'NO_ERROR'
            }
            catch { return [string]$_.Exception.Message }
        }
        $missingIntentSnapshot=$persistedSnapshot|ConvertTo-Json -Depth 50|ConvertFrom-Json -Depth 50
        $missingIntentSnapshot.Instances[0].Intents.PSObject.Properties.Remove('SqlEndpoint')
        Set-StaticPersistedPortSnapshot -Snapshot $missingIntentSnapshot
        $missingIntentReason=Get-StaticPersistedPortReason
        $duplicateSnapshot=$persistedSnapshot|ConvertTo-Json -Depth 50|ConvertFrom-Json -Depth 50
        $duplicateSnapshot.Instances=@($duplicateSnapshot.Instances)+@($duplicateSnapshot.Instances[0])
        Set-StaticPersistedPortSnapshot -Snapshot $duplicateSnapshot
        $duplicateReason=Get-StaticPersistedPortReason
        $wrongProviderSnapshot=$persistedSnapshot|ConvertTo-Json -Depth 50|ConvertFrom-Json -Depth 50
        $wrongProviderSnapshot.Instances[0].Provider='docker'
        Set-StaticPersistedPortSnapshot -Snapshot $wrongProviderSnapshot
        $wrongProviderReason=Get-StaticPersistedPortReason
        $unsupportedSnapshot=$persistedSnapshot|ConvertTo-Json -Depth 50|ConvertFrom-Json -Depth 50
        $unsupportedSnapshot.Instances[0].Intents.SqlEndpoint.CapabilityStatus='DECLARED_UNSUPPORTED'
        Set-StaticPersistedPortSnapshot -Snapshot $unsupportedSnapshot
        $unsupportedIntentReason=Get-StaticPersistedPortReason
        $invalidSnapshot=$persistedSnapshot|ConvertTo-Json -Depth 50|ConvertFrom-Json -Depth 50
        $invalidSnapshot.Contract.Version='invalid'
        Set-StaticPersistedPortSnapshot -Snapshot $invalidSnapshot
        $invalidDesiredStateReason=Get-StaticPersistedPortReason
        Set-StaticPersistedPortSnapshot -Snapshot $persistedSnapshot
        $persistedPathContract=([int]$persistedSnapshot.Instances[0].Intents.SqlEndpoint.Port -eq 14333 -and
            [int]$persistedContext.Desired.Port -eq 14333 -and [int]$persistedContext.ConnectionInstance.port -eq 15433 -and
            [int]$persistedContext.Desired.Port -ne [int]$persistedContext.ConnectionInstance.port)
        $persistedPlanContract=($persistedPlan.HighestChangeClass -eq 'restart' -and @($persistedPlan.Diff.Kind) -contains 'tcp-binding' -and
            @($persistedPlan.Diff.Kind) -contains 'firewall-binding' -and @($persistedPlan.Actions).Count -eq 1 -and
            $persistedPlan.Actions[0].RequiresServiceRestart -and -not $persistedPlan.Actions[0].RequiresVmRestart -and -not $persistedPlan.MutationAllowed)
        $persistedReadOnlyContract=($persistedStateBefore -ceq $persistedStateAfter -and -not(Test-Path -LiteralPath $persistedJournalPath))
        $persistedFailClosedContract=($missingIntentReason -eq 'HYPERV_SQL_PORT_RECONCILE_INTENT_MISSING' -and
            $duplicateReason -eq 'HYPERV_SQL_PORT_RECONCILE_INSTANCE_NOT_UNIQUE' -and
            $wrongProviderReason -eq 'HYPERV_SQL_PORT_RECONCILE_HYPERV_INSTANCE_REQUIRED' -and
            $unsupportedIntentReason -eq 'HYPERV_SQL_PORT_RECONCILE_INTENT_UNSUPPORTED' -and
            $invalidDesiredStateReason -eq 'HYPERV_SQL_PORT_RECONCILE_DESIRED_STATE_INVALID')

        $script:portDesired=$defaultPortIntent
        $script:portContext=[PSCustomObject]@{
            RunId=$RunId;ScopeId=$ScopeId;InstanceId='primary';StateRoot=$Root
            RunDirectory=(Join-Path (Join-Path $Root 'runs') $RunId)
            ConnectionInstance=[PSCustomObject]@{vmName='private-port-vm';hostSqlAccess=[PSCustomObject]@{state='READY'}}
            VM=[PSCustomObject]@{Id='private-port-vm-id';State='Running'};Desired=$script:portDesired
            FirewallRequired=$true;FirewallRemoteAddress='private-host-address';CredentialAvailable=$true
        }
        $script:portActual=[PSCustomObject]@{
            Status='AVAILABLE';SqlInstanceId='MSSQL16.MSSQLSERVER';ServiceName='MSSQLSERVER';ServiceStatus='Running'
            TcpEnabled=$true;StaticPort=$true;Port=1433;SqlReachable=$true;FirewallRuleCount=1;FirewallPorts=@('1433');FirewallProtocols=@('TCP')
            FirewallRemoteAddresses=@('private-host-address');FirewallEnabled=$true;FirewallInbound=$true;FirewallAllow=$true
        }
        $script:portApplyCount=0;$script:portSyncCount=0;$script:portFailOnce=$false
        function Get-LabHyperVSqlPortReconcileContext {
            $script:portContext.Desired=$script:portDesired
            return $script:portContext
        }
        function Get-LabHyperVSqlPortReconcileCredential { return $null }
        function Get-LabHyperVSqlPortActualState { return $script:portActual }
        function Set-LabHyperVSqlPortBinding {
            $script:portApplyCount++
            $script:portActual.TcpEnabled=$true;$script:portActual.StaticPort=$true;$script:portActual.Port=[int]$script:portDesired.Port
            $script:portActual.SqlReachable=$true
            $script:portActual.FirewallRuleCount=1;$script:portActual.FirewallPorts=@([string][int]$script:portDesired.Port)
            $script:portActual.FirewallProtocols=@('TCP');$script:portActual.FirewallRemoteAddresses=@('private-host-address')
            $script:portActual.FirewallEnabled=$true;$script:portActual.FirewallInbound=$true;$script:portActual.FirewallAllow=$true
            if($script:portFailOnce){$script:portFailOnce=$false;throw 'SYNTHETIC_PORT_FAILURE'}
            return [PSCustomObject]@{Status='APPLIED';SqlInstanceId=$script:portActual.SqlInstanceId;ServiceName='MSSQLSERVER';ServiceStatus='Running';Port=[int]$script:portDesired.Port}
        }
        function Sync-LabHyperVSqlPortConnectionState {$script:portSyncCount++}

        $noOp=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlPort -InstanceId primary -StateRoot $Root
        $sanitized=($noOp|ConvertTo-Json -Depth 30) -notmatch '1433|15433|private-port-vm|private-host-address|MSSQL16'
        $script:portActual.FirewallRemoteAddresses=@('Any')
        $firewallScopeDrift=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlPort -InstanceId primary -StateRoot $Root
        $script:portActual.FirewallRemoteAddresses=@('private-host-address')

        $script:portDesired.Port=15433
        $restart=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlPort -InstanceId primary -StateRoot $Root
        $whatIf=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlPort -InstanceId primary -StateRoot $Root -WhatIf
        $journalPath=Get-LabHyperVSqlPortReconcileJournalPath -RunDirectory $script:portContext.RunDirectory
        $whatIfSafe=$script:portApplyCount -eq 0 -and -not(Test-Path -LiteralPath $journalPath)
        $apply=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlPort -InstanceId primary -StateRoot $Root -Confirm:$false
        $firstJournal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        $applied=$apply.ExecutionSummary.Status -eq 'SUCCEEDED' -and $script:portApplyCount -eq 1 -and $script:portSyncCount -eq 1 -and $firstJournal.Status -eq 'COMPLETED'

        $script:portDesired.Port=16433;$script:portFailOnce=$true
        $failed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlPort -InstanceId primary -StateRoot $Root -Confirm:$false
        $failedJournal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        $resumePlan=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlPort -InstanceId primary -StateRoot $Root
        $resumed=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVSqlPort -InstanceId primary -StateRoot $Root -Confirm:$false
        $resumedJournal=Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json

        $script:portDesired.Port=17433;$script:portActual.FirewallRuleCount=2;$script:portActual.FirewallPorts=@('16433')
        $unsupported=Get-SqlServerLabReconcilePlan -RunId $RunId -HyperVSqlPort -InstanceId primary -StateRoot $Root

        [PSCustomObject]@{
            Intent=$intentContractValid
            PersistedPath=$persistedPathContract;PersistedPlan=$persistedPlanContract;PersistedReadOnly=$persistedReadOnlyContract;PersistedFailClosed=$persistedFailClosedContract
            NoOp=$noOp.IsNoOp -and $noOp.HighestChangeClass -eq 'no-op';Sanitized=$sanitized
            FirewallScope=$firewallScopeDrift.HighestChangeClass -eq 'restart' -and @($firewallScopeDrift.Diff.Kind) -contains 'firewall-binding'
            Restart=$restart.HighestChangeClass -eq 'restart' -and @($restart.Actions).Count -eq 1 -and
                $restart.Actions[0].RequiresServiceRestart -and -not $restart.Actions[0].RequiresVmRestart
            WhatIf=$whatIfSafe -and $whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE';Apply=$applied
            Recovery=$failed.ExecutionSummary.Status -eq 'FAILED' -and $failedJournal.Status -eq 'RECOVERY_REQUIRED' -and
                $resumePlan.Actions[0].Operation -eq 'ResumeHyperVSqlPort' -and @($resumePlan.Actions[0].RepairKinds) -contains 'recovery-finalize'
            Resume=$resumed.ExecutionSummary.Status -eq 'SUCCEEDED' -and $resumedJournal.Status -eq 'COMPLETED' -and $script:portApplyCount -eq 2
            Unsupported=$unsupported.HighestChangeClass -eq 'unsupported' -and @($unsupported.Actions).Count -eq 0
        }
    } $testRoot $runId $scopeId

    $checks=[ordered]@{
        'Manifest-Schema begrenzt hyperv.sqlPort auf einen statischen TCP-Port'=($sqlPortSchema.type -eq 'integer' -and [int]$sqlPortSchema.minimum -eq 1 -and [int]$sqlPortSchema.maximum -eq 65535 -and [int]$sqlPortSchema.default -eq 1433)
        'Persistierter Hyper-V-SQL-Portintent ist capability-gebunden und defaultstabil'=$result.Intent
        'SQL-Port-Reconcile liest den exakt persistierten Intents.SqlEndpoint statt eines Connection-Portwerts'=$result.PersistedPath
        'Persistierter TCP- und Firewall-Drift ergibt oeffentlich exakt einen restart-only SQL-Plan'=$result.PersistedPlan
        'Persistierter SQL-Port-Plan bleibt ohne State- oder Journalmutation read-only'=$result.PersistedReadOnly
        'Fehlender, ungueltiger, doppelter, fremder oder nicht faehiger Persistenzintent bleibt fail-closed'=$result.PersistedFailClosed
        'Semantisch passende TCP- und Firewallbindung bleibt No-op'=$result.NoOp
        'Oeffentlicher SQL-Portplan enthaelt keine Port-, VM-, SQL- oder Hostwerte'=$result.Sanitized
        'Abweichende Firewall-RemoteAddress wird als sicherheitsrelevante Portbindung erkannt'=$result.FirewallScope
        'Portdrift verlangt nur einen SQL-Dienstrestart und keinen VM-Neustart'=$result.Restart
        'WhatIf mutiert weder Gast noch Journal'=$result.WhatIf
        'Portreparatur journalisiert, synchronisiert Connection-State und erfuellt die Postcondition'=$result.Apply
        'Fehler nach Gastmutation bleibt als Recovery sichtbar'=$result.Recovery
        'Recovery finalisiert den bereits erreichten Sollzustand ohne zweiten Dienstrestart'=$result.Resume
        'Mehrdeutige Firewallidentitaet bleibt fail-closed'=$result.Unsupported
        'Produktpfad verwendet nur den validen Persistenzsnapshot und keinen generischen Desired-State-Projektor'=($source -match 'Get-LabPersistedDesiredState' -and $source -match '\$persisted\.Snapshot\.Instances' -and $source -match '\.Intents\.SqlEndpoint' -and $source -notmatch 'New-LabDesiredState')
        'Gastmutation setzt statischen TCP-Port, bindet die Lab-Firewall eng und startet nur SQL neu'=($source -match 'Set-ItemProperty.+TcpDynamicPorts' -and $source -match 'Set-NetFirewallPortFilter' -and $source -match 'Set-NetFirewallAddressFilter' -and $source -match 'Set-NetFirewallRule -Enabled True -Direction Inbound -Action Allow' -and $source -match "Restart-Service -Name 'MSSQLSERVER'" -and $source -notmatch 'Restart-VM|Stop-VM|Start-VM')
        'Plan und Postcondition pruefen SQL tatsaechlich ueber den statischen Port'=([regex]::Matches($source,"Server=localhost,\$").Count -ge 2 -and $source -match "CommandText='SELECT DB_NAME\(\);'")
        'Manifest-Erstbereitstellung reicht den deklarativen SQL-Port bis CompleteImage und Isolation durch'=($publicProvisioningSource -match '-SqlPort \$hyperVSqlPort' -and $provisioningSource -match '(?s)Complete-HyperVLabSqlImage.+?-SqlPort \$SqlPort' -and $provisioningSource -match '(?s)Enable-HyperVLabHostSqlAccess.+?-SqlPort \$SqlPort' -and $provisioningSource -match 'Set-LabHyperVSqlPortBinding -Context \$isolatedPortContext')
        'Nativer SQL-Port-Runner fordert expliziten temporaeren Aktivierungsintent bei unveraendertem hostOnly-Host-Netz'=($acceptanceSource -match "windowsActivation\s*=\s*\[ordered\]@\{ContractVersion='SqlServerLab\.WindowsActivationIntent/1\.0';Strategy='EvaluationOnline';EgressPolicy='AllowTemporary'\}" -and $acceptanceSource -match "network=\[ordered\]@\{intent='hostOnly';exposure='host'\}" -and $acceptanceSource -match 'Test-SqlServerLabManifest')
        'Nativer Runner bindet isolierte Drift, Plan, WhatIf, SQL-Restart, Connection-State und No-op'=($acceptanceSource -match 'Set-AcceptanceGuestPortDrift' -and $acceptanceSource -match 'Get-SqlServerLabReconcilePlan' -and $acceptanceSource -match 'RepairHyperVSqlPort' -and $acceptanceSource -match 'RequiresServiceRestart' -and $acceptanceSource -match 'updated.Instance.port' -and $acceptanceSource -match 'noOp.IsNoOp')
        'Nativer Runner bindet das SA-Kennwort als schreibgeschuetztes SecureString an SqlCredential'=($acceptanceSource -match 'if\(-not \$script:saPassword\.IsReadOnly\(\)\)\{\$script:saPassword\.MakeReadOnly\(\)\}' -and $acceptanceSource -match '\[Data\.SqlClient\.SqlCredential\]::new\(''sa'',\$script:saPassword\)')
        'Nativer Runner beweist SQL-Restart ohne VM-Neustart und scopegebundenen Cleanup'=($acceptanceSource -match 'Get-AcceptanceGuestBootTime' -and $acceptanceSource -match 'sqlStartAfter -ne \$driftSqlStart' -and $acceptanceSource -notmatch 'Restart-VM|Stop-VM|Start-VM' -and $acceptanceSource -match 'Remove-SqlServerLab' -and $acceptanceSource -match 'Run-eigene VHDX wurde entfernt')
        'Bootstrap bindet isoliertes Prepared-Artifact, Recovery-Marker und strikten Cleanup'=($bootstrapSource -match 'RetainPreparedArtifact' -and $bootstrapSource -match 'RETAINED_STATE_ROOT' -and $bootstrapSource -match 'RETAINED_ARTIFACT_ID' -and $bootstrapSource -match 'Remove-HyperVImageArtifact' -and $bootstrapSource -match 'RECOVERY_REQUIRED')
    }
    $failedChecks=@($checks.GetEnumerator()|Where-Object{-not $_.Value})
    foreach($check in $checks.GetEnumerator()){$color=if($check.Value){'Green'}else{'Red'};Write-Host("  {0}  {1}" -f $(if($check.Value){'PASS'}else{'FAIL'}),$check.Key)-ForegroundColor $color}
    if($failedChecks.Count){throw "Hyper-V SQL port reconcile checks failed: $($failedChecks.Key -join ', ')"}
    Write-Host "Hyper-V SQL Port Reconcile Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
}
finally {
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
}
