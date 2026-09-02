$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVExternalRuntimeReconcile.ps1') -Raw -Encoding utf8
$windowsSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ExternalRuntimeWindows.ps1') -Raw -Encoding utf8
$publicPlanSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Get-SqlServerLabReconcilePlan.ps1') -Raw -Encoding utf8
$publicActionSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLabReconcileAction.ps1') -Raw -Encoding utf8
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-external-runtime-' + [guid]::NewGuid().ToString('N'))
$runId = [guid]::NewGuid().ToString('D')
$scopeId = [guid]::NewGuid().ToString('D')
$runDirectory = Join-Path (Join-Path $testRoot 'runs') $runId
New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru

try {
    $result = & $module {
        param($Root,$RunId,$ScopeId)
        $runDirectory = Join-Path (Join-Path $Root 'runs') $RunId
        $connectionPath = Join-Path $runDirectory 'connection-info.json'
        $request = [PSCustomObject]@{Id='sql-python';Version=$null;Variant=$null;Scope='sqlExternalRuntime';InstallMethod='catalog';Optional=$false;Packages=@();RequestSource='software'}
        $pythonPlan = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion 2022 -Provider hyperv -OperatingSystem windows
        $rRequest = $request | Select-Object *
        $rRequest.Id = 'sql-r'
        $rPlan = Resolve-LabExternalRuntimePlan -SoftwareItem $rRequest -SqlVersion 2022 -Provider hyperv -OperatingSystem windows
        $script:hvRuntimeDesired = @($pythonPlan)
        $script:hvRuntimeCurrent = @()
        $script:hvRuntimeInstallCount = 0
        $script:hvRuntimeFailOnce = $false
        $script:hvRuntimeConnectionInstance = [PSCustomObject]@{
            id='primary';provider='hyperv';sqlVersion='2022';vmName='synthetic-vm';vmId='synthetic-vm-id';host='synthetic-host';port=1433
            externalRuntime=$null
        }
        $script:hvRuntimeConnection = [PSCustomObject]@{instances=@($script:hvRuntimeConnectionInstance)}
        $script:hvRuntimeRun = [PSCustomObject]@{runId=$RunId;scopeId=$ScopeId;state='RUNNING';metadata=[PSCustomObject]@{desiredState=[PSCustomObject]@{Revision='current'}}}
        Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject $script:hvRuntimeConnection
        Write-LabArtifactJsonAtomic -Path (Join-Path $runDirectory 'run-state.json') -InputObject $script:hvRuntimeRun

        function Resolve-LabExternalRuntimeReconcileTarget {
            [PSCustomObject]@{Provider='hyperv';InstanceId='primary'}
        }
        function Get-LabHyperVExternalRuntimeReconcileCredentials {
            $password = [Security.SecureString]::new()
            foreach ($character in 'Synthetic-Passw0rd!'.ToCharArray()) { $password.AppendChar($character) }
            $password.MakeReadOnly()
            [PSCustomObject]@{GuestCredential=[PSCredential]::new('Administrator',$password);SqlSaPassword=$password}
        }
        function Get-LabMediaRootDefault { return $Root }
        function Get-LabHyperVExternalRuntimeReconcileContext {
            $targetHash = Get-LabHyperVExternalRuntimeTargetHash -Plans $script:hvRuntimeDesired
            $context = [PSCustomObject]@{
                RunId=$RunId;ScopeId=$ScopeId;InstanceId='primary';StateRoot=$Root;Run=$script:hvRuntimeRun
                RunDirectory=$runDirectory;ConnectionPath=$connectionPath;Connection=$script:hvRuntimeConnection
                ConnectionInstance=$script:hvRuntimeConnectionInstance;VM=[PSCustomObject]@{Id='synthetic-vm-id';State='Running'}
                DesiredSnapshot=[PSCustomObject]@{Revision=($script:hvRuntimeDesired.PlanKey -join ',')}
                ResolvedInstance=[PSCustomObject]@{serverConfig=[PSCustomObject]@{externalScripts=[PSCustomObject]@{resourceGovernor=$null}}}
                DesiredPlans=@($script:hvRuntimeDesired);CurrentReceipts=@($script:hvRuntimeCurrent);TargetHash=$targetHash
            }
            $journalPath = Get-LabHyperVExternalRuntimeReconcileJournalPath -RunDirectory $runDirectory
            $journal = Read-LabHyperVExternalRuntimeReconcileJournal -Path $journalPath -Context $context
            $context | Add-Member -NotePropertyName JournalPath -NotePropertyValue $journalPath
            $context | Add-Member -NotePropertyName Journal -NotePropertyValue $journal
            return $context
        }
        function Install-LabHyperVExternalRuntimes {
            param($SoftwarePlans,$RunId,$Credential,$SqlSaPassword,$MediaRoot,$ResourceGovernorConfig,$StateRoot)
            $script:hvRuntimeInstallCount++
            if ($script:hvRuntimeFailOnce) { $script:hvRuntimeFailOnce=$false; throw 'SYNTHETIC_HYPERV_RUNTIME_INSTALL_FAILURE' }
            $receipts = @($SoftwarePlans | ForEach-Object {
                New-LabSoftwareInstallationReceipt -Plan $_ -Postconditions @([PSCustomObject]@{Id='synthetic-sql-probe';Status='PASS'})
            })
            $null = Save-LabExternalRuntimeInstallationReceipts -RunDirectory $runDirectory -InstanceId primary -Receipts $receipts
            $script:hvRuntimeCurrent = @($receipts)
            $script:hvRuntimeConnectionInstance.externalRuntime = [PSCustomObject]@{
                status='EXTENSIONS_READY_RUN';receipts=@($receipts | ForEach-Object {
                    [PSCustomObject]@{SoftwareId=$_.SoftwareId;PlanKey=$_.PlanKey;VariantId=$_.VariantId;RuntimeVersion=$_.RuntimeVersion;Status=$_.Status;CompletedAt=$_.CompletedAt}
                })
            }
            $script:hvRuntimeConnection.instances = @($script:hvRuntimeConnectionInstance)
            Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject $script:hvRuntimeConnection
            return $receipts
        }

        $planWithoutInstance = Get-SqlServerLabReconcilePlan -RunId $RunId -ManifestPath 'synthetic.json' -StateRoot $Root
        $plan = Get-SqlServerLabReconcilePlan -RunId $RunId -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root
        $whatIf = Invoke-SqlServerLabReconcileAction -RunId $RunId -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root -WhatIf
        $journalPath = Get-LabHyperVExternalRuntimeReconcileJournalPath -RunDirectory $runDirectory
        $whatIfSafe = $script:hvRuntimeInstallCount -eq 0 -and -not (Test-Path -LiteralPath $journalPath)
        $applied = Invoke-SqlServerLabReconcileAction -RunId $RunId -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root -Confirm:$false
        $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
        $persistedRun = Get-Content -LiteralPath (Join-Path $runDirectory 'run-state.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
        $noOp = Get-SqlServerLabReconcilePlan -RunId $RunId -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root

        $script:hvRuntimeDesired = @($pythonPlan,$rPlan)
        $script:hvRuntimeFailOnce = $true
        $failed = Invoke-SqlServerLabReconcileAction -RunId $RunId -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root -Confirm:$false
        $failedJournal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
        $resumePlan = Get-SqlServerLabReconcilePlan -RunId $RunId -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root
        $resumed = Invoke-SqlServerLabReconcileAction -RunId $RunId -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root -Confirm:$false
        $resumedJournal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
        $script:hvRuntimeDesired = @($rPlan)
        $unsupported = Get-SqlServerLabReconcilePlan -RunId $RunId -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root
        $unsupportedAction = Invoke-SqlServerLabReconcileAction -RunId $RunId -ManifestPath 'synthetic.json' -InstanceId primary -StateRoot $Root -Confirm:$false

        [PSCustomObject]@{
            PlansResolved=@($pythonPlan,$rPlan | Where-Object Status -eq 'RESOLVED').Count -eq 2
            Plan=$plan.PlanKind -eq 'ExternalRuntime' -and $plan.Desired.Provider -eq 'hyperv' -and $plan.HighestChangeClass -eq 'reprovision' -and $plan.Actions[0].Operation -eq 'InstallHyperVExternalRuntime'
            PlanWarning=@($plan.Warnings).Count -eq 1 -and [string]$plan.Warnings[0] -match 'SQL Server und Launchpad' -and [string]$plan.Warnings[0] -match 'VM bleibt gestartet'
            ImplicitInstance=$planWithoutInstance.InstanceId -eq 'primary'
            WhatIf=$whatIfSafe -and $whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE'
            Apply=$applied.ExecutionSummary.Status -eq 'SUCCEEDED' -and $journal.Status -eq 'COMPLETED' -and $script:hvRuntimeInstallCount -ge 1
            StateCommit=[string]$persistedRun.metadata.desiredState.Revision -eq [string]$pythonPlan.PlanKey
            NoOp=$noOp.IsNoOp -and $noOp.HighestChangeClass -eq 'no-op' -and @($noOp.Warnings).Count -eq 0
            Failure=$failed.ExecutionSummary.Status -eq 'FAILED' -and $failedJournal.Status -eq 'RECOVERY_REQUIRED' -and $failedJournal.Recovery.ErrorCode -eq 'SYNTHETIC_HYPERV_RUNTIME_INSTALL_FAILURE'
            Resume=$resumePlan.Actions[0].Operation -eq 'ResumeHyperVExternalRuntime' -and $resumed.ExecutionSummary.Status -eq 'SUCCEEDED' -and $resumedJournal.Status -eq 'COMPLETED' -and $resumedJournal.Recovery.Attempts -eq 1
            Unsupported=$unsupported.HighestChangeClass -eq 'unsupported' -and @($unsupported.Actions).Count -eq 0 -and $unsupportedAction.ExecutionSummary.Status -eq 'UNSUPPORTED' -and @($unsupported.Warnings).Count -eq 1 -and [string]$unsupported.Warnings[0] -eq 'HYPERV_EXTERNAL_RUNTIME_REMOVAL_UNSUPPORTED'
            CurrentPlanKeys=@($script:hvRuntimeConnectionInstance.externalRuntime.receipts | Where-Object { [string]$_.PlanKey -match '^[a-f0-9]{64}$' }).Count -eq 2
        }
    } $testRoot $runId $scopeId

    $schema = Get-Content -LiteralPath (Join-Path $repoRoot 'Schemas/hyperv-external-runtime-reconcile-journal.schema.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    $checks = [ordered]@{
        'SQL-2022-Hyper-V-Python und -R loesen ueber denselben Softwarekatalog auf'=$result.PlansResolved
        'Read-only Plan klassifiziert die erste Hyper-V-Gastinstallation als reprovision'=$result.Plan
        'Mutierender Plan weist den SQL-/Launchpad-Neustart ohne VM-Neustart aus'=$result.PlanWarning
        'Eindeutige Hyper-V-Zielinstanz kann ohne InstanceId aufgeloest werden'=$result.ImplicitInstance
        'WhatIf schreibt weder Journal noch Gastmutation'=$result.WhatIf
        'Apply installiert, verifiziert und schliesst das VM-gebundene Journal ab'=$result.Apply
        'Desired State wird erst nach persistierten Runtime-Postconditions fortgeschrieben'=$result.StateCommit
        'Konvergierte Software-PlanKeys bleiben No-op ohne falsche Downtime-Warnung'=$result.NoOp
        'Installationsfehler bleibt mit sanitisiertem Recovery-Code sichtbar'=$result.Failure
        'Resume setzt denselben Zielhash idempotent vorwaerts fort'=$result.Resume
        'Removal bleibt mit stabilem Reason-Code ohne Action fail-closed und wird nicht mutiert'=$result.Unsupported
        'Hyper-V-Connection-Receipt persistiert portable PlanKeys'=$result.CurrentPlanKeys
        'Journalvertrag ist streng, versioniert und enthaelt keine Hostpfade'=($schema.title -eq 'SqlServerLab.HyperVExternalRuntimeReconcileJournal/1.0' -and $schema.additionalProperties -eq $false -and -not (($schema | ConvertTo-Json -Depth 40) -match '(?i)MediaRoot|GuestPath|HostPath'))
        'Public Plan routet External Runtime providergebunden zu Hyper-V'=($publicPlanSource -match 'Resolve-LabExternalRuntimeReconcileTarget' -and $publicPlanSource -match 'New-LabHyperVExternalRuntimeReconcilePlan')
        'Public Action bindet ShouldProcess, SecureString, MediaRoot und Hyper-V-Executor'=($publicActionSource -match 'ShouldProcess' -and $publicActionSource -match '\[SecureString\]\$SqlSaPassword' -and $publicActionSource -match '\[string\]\$MediaRoot' -and $publicActionSource -match 'Invoke-LabHyperVExternalRuntimeReconcileRepair')
        'Executor bindet Migration-Guard, VM-Identitaet, Journal vor Mutation und SQL-Postconditions'=($source -match 'Get-LabHyperVResourceMigrationLifecycleGuard' -and $source -match 'Get-HyperVManagedVM' -and $source.IndexOf('Write-LabHyperVExternalRuntimeReconcileJournal') -lt $source.IndexOf('Install-LabHyperVExternalRuntimes') -and $source -match 'CONNECTION_POSTCONDITION_FAILED')
        'Erstinstallation schreibt den PlanKey auch in den Hyper-V-Connection-State'=($windowsSource -match 'SoftwareId=\$_.SoftwareId; PlanKey=\$_.PlanKey')
    }
    $failedChecks = @($checks.GetEnumerator() | Where-Object { -not $_.Value })
    foreach ($check in $checks.GetEnumerator()) {
        $color = if ($check.Value) { 'Green' } else { 'Red' }
        Write-Host ("  {0}  {1}" -f $(if($check.Value){'PASS'}else{'FAIL'}),$check.Key) -ForegroundColor $color
    }
    if ($failedChecks.Count) { throw "Hyper-V external runtime reconcile checks failed: $($failedChecks.Key -join ', ')" }
    Write-Host "Hyper-V External Runtime Reconcile Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green
}
finally {
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
