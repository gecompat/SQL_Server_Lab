#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-diagnostic-check-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru -WarningAction SilentlyContinue
try {
    & $module {
        param($Root,$Repo)
        $script:diagnosticAssertions=0
        function Assert-Diagnostic {param([bool]$Pass,[string]$Name)
            if(-not $Pass){throw "DIAGNOSTIC_CHECK_FAILED: $Name"}
            $script:diagnosticAssertions++;Write-Host "PASS: $Name"
        }
        function Write-FixtureJson {param($Path,$Value)
            $null=New-Item -ItemType Directory -Path (Split-Path $Path) -Force
            $Value | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $Path -Encoding utf8
        }
        function Reset-DiagnosticFixture {
            param([string]$Provider='docker',[switch]$Persistent)
            $script:dataRoot=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $controller=[guid]::NewGuid().ToString('D')
            # Use real modern state and desired-state producers; no runtime provisioning.
            $instance=[pscustomobject]@{id='primary';provider=$Provider;version='2025';profile='standard';autostart='manual';drives=@();databases=@();software=@()}
            $desired=New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name='Synthetic diagnostic fixture';instances=@($instance)}) -ProvisioningMode adhoc -PersistentData ([bool]$Persistent)
            $script:run=New-LabRunState -StateRoot (Join-Path $script:dataRoot 'State') -Metadata @{
                desiredState=$desired;persistentData=[bool]$Persistent;dataRoot=$(if($Persistent){$script:dataRoot}else{$null})
            } -ProviderSubRuns @([pscustomobject]@{provider=$Provider;instanceIds=@('primary')})
            $script:statePath=Join-Path $script:run.RunDir 'run-state.json'
            $script:state=Get-LabRunState -RunId $script:run.RunId -StateRoot $script:run.StateRoot
            $script:marker=[pscustomobject]@{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='synthetic-volume';DataRoot=$script:dataRoot}
            $script:catalog=[pscustomobject]@{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;DefaultLocationId=[guid]::NewGuid().ToString('D');LabDataLocations=@(
                [pscustomobject]@{LocationId=[guid]::NewGuid().ToString('D');ControllerId=$controller;LabDataRoot=$script:dataRoot;VolumeId='synthetic-volume'})}
            Write-FixtureJson (Join-Path $script:dataRoot '.sql-server-lab-root.json') $script:marker
            Write-FixtureJson (Join-Path $script:dataRoot 'Catalog/storage-locations.json') $script:catalog
            $script:diagnosticArguments=@{RunId=$script:run.RunId;InstanceId='primary';DataRoot=$script:dataRoot}
            $script:probeCalls=0;$script:readinessCode='PROVIDER_REACHABLE';$script:readinessMode='valid'
        }
        function Get-FixtureSnapshot {
            (@(Get-ChildItem -LiteralPath $script:dataRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
                [IO.Path]::GetRelativePath($script:dataRoot,$_.FullName)+':'+(Get-FileHash -LiteralPath $_.FullName).Hash
            }) -join '|')
        }
        function Assert-BundleSafe {param($Value)
            $json=$Value|ConvertTo-Json -Depth 16 -Compress
            Assert-Diagnostic ($json.Length -le 32768 -and ($json | Test-Json -SchemaFile (Join-Path $Repo 'Schemas/diagnostic-bundle.schema.json'))) 'DTO entspricht geschlossenem Schema und Ausgabelimit'
            Assert-Diagnostic ($json -notmatch 'CANARY_PRIVATE|synthetic-volume|sql-lab-diagnostic-check' -and $json -notmatch [regex]::Escape($script:run.RunId)) 'DTO enthält keine privaten Canary-, Pfad- oder Runwerte'
        }
        $realReadiness=${function:Invoke-LabDiagnosticReadinessProcess}
        function Invoke-LabDiagnosticReadinessProcess {
            param($Provider,$Operation)
            $script:probeCalls++
            if($script:readinessMode -eq 'throw') {
                Write-Warning 'CANARY_PRIVATE warning';Write-Verbose 'CANARY_PRIVATE verbose' -Verbose
                Write-Information 'CANARY_PRIVATE information' -InformationAction Continue
                Write-Debug 'CANARY_PRIVATE debug' -Debug
                throw 'CANARY_PRIVATE exception'
            }
            $status=if($script:readinessCode -ceq 'PROVIDER_REACHABLE'){'PASS'}else{'BLOCKED'}
            $value=[pscustomobject]@{ContractVersion='SqlServerLab.DiagnosticProviderReadiness/1.0';Provider=$Provider;Operation=$Operation
                Status=if($status -ceq 'PASS'){'READY'}else{'NOT_READY'}
                Checks=@([pscustomobject]@{Category='Reachability';Code=$script:readinessCode;Status=$status;NextStep='CANARY_PRIVATE next';Path='CANARY_PRIVATE path'})}
            if($script:readinessMode -eq 'wrong-provider'){$value.Provider='hyperv'}
            if($script:readinessMode -eq 'wrong-status'){$value.Status='READY_WITH_WARNINGS'}
            if($script:readinessMode -eq 'array-code'){$value.Checks[0].Code=@('PROVIDER_REACHABLE')}
            if($script:readinessMode -eq 'too-many'){$value.Checks=@(1..25|ForEach-Object{$value.Checks[0]})}
            [pscustomobject]@{Success=$true;Reason='NONE';Value=$value}
        }
        foreach($provider in @('docker','podman','hyperv')) {
            Reset-DiagnosticFixture -Provider $provider
            $before=Get-FixtureSnapshot
            $bundle=Get-SqlServerLabDiagnosticBundle @script:diagnosticArguments
            if($bundle.Status -cne 'OBSERVED'){throw ('DIAGNOSTIC_FIXTURE_BINDING_FAILED: '+$bundle.Binding.Reason)}
            Assert-Diagnostic ($bundle.Status -ceq 'OBSERVED' -and $bundle.Binding.Provider -ceq $provider -and $bundle.History.RunState -ceq 'INITIALIZING' -and $script:probeCalls -eq 1) "${provider}: realer nichtpersistenter Produzent und gebundene Readiness"
            Assert-Diagnostic ($before -ceq (Get-FixtureSnapshot) -and -not $bundle.Capabilities.MutationAllowed -and $bundle.History.RuntimeStatus -ceq 'NOT_EXECUTED') 'Keine Dateiänderung oder behauptete Runtime-/Mutationsfreigabe'
            Assert-BundleSafe $bundle
        }
        Reset-DiagnosticFixture -Persistent
        $script:state.state='REMOVED';$script:state.providerSubRuns[0].state='REMOVED'
        $script:state.errors=@([pscustomobject]@{message='CANARY_PRIVATE SQL password endpoint'});
        $script:state.metadata | Add-Member -NotePropertyName workflowOperationId -NotePropertyValue 'op-diagnostic-fixture'
        Write-FixtureJson $script:statePath $script:state
        $plan=New-CleanupPlan -RunDir $script:run.RunDir -RunId $script:run.RunId -ScopeId $script:run.ScopeId
        $plan.status='COMPLETED';$plan.steps=@([pscustomobject]@{state='COMPLETED';resourceId='CANARY_PRIVATE runtime';error='CANARY_PRIVATE log'})
        Write-FixtureJson (Join-Path $script:run.RunDir 'cleanup-plan.json') $plan
        $operation=[pscustomobject]@{contract='SqlServerLab.Operation/1.0';operationId='op-diagnostic-fixture';runId=$script:run.RunId;provider='docker';status='Completed';cleanupRequested=$true;steps=@();secretAlias='CANARY_PRIVATE alias'}
        $operationPath=Join-Path $script:run.StateRoot 'operations/op-diagnostic-fixture.json'
        Write-FixtureJson $operationPath $operation
        $bundle=Get-SqlServerLabDiagnosticBundle @script:diagnosticArguments -SkipReadiness
        Assert-Diagnostic ($bundle.Status -ceq 'OBSERVED' -and $bundle.History.RunState -ceq 'REMOVED' -and $bundle.Cleanup.CompletedSteps -eq 1 -and $bundle.Cleanup.LiveResidueStatus -ceq 'NOT_EXECUTED' -and $bundle.Operation.Status -ceq 'Completed' -and $script:probeCalls -eq 0) 'Terminale Historie und bidirektionale Operation ohne Live-Restbehauptung'
        Assert-BundleSafe $bundle
        $operation.runId=[guid]::NewGuid().ToString('D');Write-FixtureJson $operationPath $operation
        Assert-Diagnostic ((Get-SqlServerLabDiagnosticBundle @script:diagnosticArguments -SkipReadiness).Operation.Reason -ceq 'DIAGNOSTIC_OPERATION_UNVERIFIABLE') 'Fremde Operation bleibt blockiert'
        $plan.scopeId=[guid]::NewGuid().ToString('D');Write-FixtureJson (Join-Path $script:run.RunDir 'cleanup-plan.json') $plan
        Assert-Diagnostic ((Get-SqlServerLabDiagnosticBundle @script:diagnosticArguments -SkipReadiness).Cleanup.Reason -ceq 'DIAGNOSTIC_CLEANUP_UNVERIFIABLE') 'Fremder Cleanupplan bleibt blockiert'
        foreach($case in @('controller','root','registration','scope','run','legacy','desired','persistent-root','provider','subrun','duplicate','version','state','actual','array-shape','size','depth','duplicate-json','malformed','missing')) {
            Reset-DiagnosticFixture -Persistent
            switch($case) {
                controller {$script:catalog.ControllerId=[guid]::NewGuid().ToString('D')}
                root {$script:marker.DataRoot=Join-Path $Root 'unregistered'}
                registration {$script:catalog.LabDataLocations=@()}
                scope {$script:state.scopeId=[guid]::NewGuid().ToString('D')}
                run {$script:state.runId=[guid]::NewGuid().ToString('D')}
                legacy {$script:state.PSObject.Properties.Remove('contractVersion')}
                desired {$script:state.metadata.desiredState=$null}
                persistent-root {$script:state.metadata.dataRoot=Join-Path $Root 'other'}
                provider {$script:diagnosticArguments.Provider='podman'}
                subrun {$script:state.providerSubRuns[0].instanceIds=@('other')}
                duplicate {$script:state.metadata.desiredState.Instances=@($script:state.metadata.desiredState.Instances[0],$script:state.metadata.desiredState.Instances[0])}
                version {$script:state.metadata.desiredState.Instances[0].Version='CANARY_PRIVATE version'}
                state {$script:state.state='CANARY_PRIVATE state'}
                actual {$script:state.instances=@([pscustomobject]@{id='other';provider='docker';version='2025'})}
                array-shape {$script:state.errors=$null}
            }
            Write-FixtureJson (Join-Path $script:dataRoot '.sql-server-lab-root.json') $script:marker
            Write-FixtureJson (Join-Path $script:dataRoot 'Catalog/storage-locations.json') $script:catalog
            Write-FixtureJson $script:statePath $script:state
            switch($case) {
                size {[IO.File]::WriteAllText($script:statePath,(' ' * 1048577))}
                depth {[IO.File]::WriteAllText($script:statePath,(('{"a":'*35)+'{}'+('}'*35)))}
                duplicate-json {[IO.File]::WriteAllText($script:statePath,'{"runId":"a","RunId":"b"}')}
                malformed {[IO.File]::WriteAllText($script:statePath,'CANARY_PRIVATE invalid JSON')}
                missing {Remove-Item -LiteralPath $script:statePath}
            }
            $before=Get-FixtureSnapshot
            $bundle=Get-SqlServerLabDiagnosticBundle @script:diagnosticArguments
            Assert-Diagnostic ($bundle.Status -cin @('BLOCKED','UNAVAILABLE') -and $script:probeCalls -eq 0 -and $before -ceq (Get-FixtureSnapshot)) "$case blockiert vor Providerprobe ohne Mutation"
            Assert-BundleSafe $bundle
        }
        Reset-DiagnosticFixture
        foreach($bad in @('../escape','CANARY_PRIVATE target','00000000-0000-0000-0000-000000000000',@('CANARY_PRIVATE array'),42)) {
            $callArguments=$script:diagnosticArguments.Clone();$callArguments.RunId=$bad
            $streams=@(Get-SqlServerLabDiagnosticBundle @callArguments *>&1)
            Assert-Diagnostic ($streams.Count -eq 1 -and $streams[0].Status -ceq 'BLOCKED' -and ($streams|ConvertTo-Json -Depth 16) -notmatch 'CANARY_PRIVATE' -and $script:probeCalls -eq 0) 'Ungültige Eingabe bleibt innerhalb Privacy-Grenze'
        }
        foreach($badPath in @((Join-Path $script:dataRoot '../outside'),[IO.Path]::GetPathRoot($script:dataRoot),'relative/path','//synthetic-server/share')) {
            $callArguments=$script:diagnosticArguments.Clone();$callArguments.DataRoot=$badPath
            Assert-Diagnostic ((Get-SqlServerLabDiagnosticBundle @callArguments).Binding.Reason -ceq 'DIAGNOSTIC_ROOT_INVALID') 'Freier, traversierender, Wurzel- oder Netzwerkpfad blockiert'
        }
        foreach($code in @('TOOL_NOT_INSTALLED','TOOL_EXECUTION_DENIED','PROVIDER_ACCESS_DENIED','PROVIDER_UNREACHABLE','PROVIDER_PROBE_TIMEOUT','PROVIDER_RESPONSE_INVALID')) {
            $script:readinessCode=$code
            $bundle=Get-SqlServerLabDiagnosticBundle @script:diagnosticArguments
            Assert-Diagnostic ($bundle.Readiness.Status -ceq 'NOT_READY' -and $bundle.Readiness.Checks[0].Code -ceq $code) "Readinessklasse $code bleibt unterscheidbar"
            Assert-BundleSafe $bundle
        }
        $script:readinessCode='PROVIDER_REACHABLE'
        foreach($mode in @('wrong-provider','wrong-status','array-code','too-many','throw')) {
            $script:readinessMode=$mode
            $streams=@(Get-SqlServerLabDiagnosticBundle @script:diagnosticArguments -Verbose -Debug *>&1)
            Assert-Diagnostic ($streams.Count -eq 1 -and $streams[0].Readiness.EvidenceStatus -ceq 'UNAVAILABLE' -and ($streams|ConvertTo-Json -Depth 16) -notmatch 'CANARY_PRIVATE') "$mode Readinessfehler ist in allen Streams sanitisiert"
        }
        $script:readinessMode='valid'
        # Lock a forbidden source: a successful bundle must never try to consume it.
        $forbidden=Join-Path $script:run.RunDir 'connection-info.json'
        [IO.File]::WriteAllText($forbidden,'CANARY_PRIVATE connection')
        $lock=[IO.File]::Open($forbidden,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Assert-Diagnostic ((Get-SqlServerLabDiagnosticBundle @script:diagnosticArguments -SkipReadiness).Status -ceq 'OBSERVED') 'Exklusiv gesperrte Connection-Datei bleibt ungelesen' }
        finally {$lock.Dispose()}
        # A missing catalog must not expose even a nonterminating Get-FileHash
        # error when the caller explicitly keeps processing after errors.
        $savedModuleRoot=$script:ModuleRoot
        $savedErrorPreference=$ErrorActionPreference
        try {
            $script:ModuleRoot=Join-Path $Root 'CANARY_PRIVATE_missing_catalog'
            foreach($preference in @('Continue','Stop')) {
                $ErrorActionPreference=$preference
                $streams=@(Get-SqlServerLabDiagnosticBundle @script:diagnosticArguments -SkipReadiness -Verbose -Debug *>&1)
                Assert-Diagnostic ($streams.Count -eq 1 -and $streams[0].Status -ceq 'OBSERVED' -and
                    $streams[0].Reproduction.EvidenceStatus -ceq 'UNAVAILABLE' -and
                    $streams[0].Reproduction.Reason -ceq 'DIAGNOSTIC_CATALOG_UNAVAILABLE' -and
                    $null -eq $streams[0].Reproduction.VersionCatalogSha256 -and
                    ($streams|ConvertTo-Json -Depth 16) -notmatch 'CANARY_PRIVATE|sql-lab-diagnostic-check|Get-FileHash|ItemNotFoundException') "Fehlender Katalog bleibt in allen Streams sanitisiert bei $preference"
                Assert-BundleSafe $streams[0]
            }
        }
        finally {$script:ModuleRoot=$savedModuleRoot;$ErrorActionPreference=$savedErrorPreference}
        # Reparse handling is tested without an elevated symlink requirement on Windows.
        $link=Join-Path $Root 'linked-root'
        $linkType=if($IsWindows){'Junction'}else{'SymbolicLink'}
        $null=New-Item -ItemType $linkType -Path $link -Target $script:dataRoot
        try {
            $callArguments=$script:diagnosticArguments.Clone();$callArguments.DataRoot=$link
            Assert-Diagnostic ((Get-SqlServerLabDiagnosticBundle @callArguments).Binding.Reason -ceq 'DIAGNOSTIC_LINK_BLOCKED') 'Reparse-Root wird vor Metadatazugriff abgewiesen'
        }
        finally {Remove-Item -LiteralPath $link -Force}
        # Real bounded child processes use fixed synthetic commands, never a provider.
        foreach($case in @('json','invalid','output','timeout')) {
            $command=switch($case) {
                json {'[Console]::Out.Write(''{"safe":true}'')'}
                invalid {'[Console]::Out.Write(''CANARY_PRIVATE broken'')'}
                output {'[Console]::Error.Write((''X''*70000));Start-Sleep -Seconds 30'}
                timeout {'Start-Sleep -Seconds 30'}
            }
            $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))){$start.ArgumentList.Add($arg)}
            $watch=[Diagnostics.Stopwatch]::StartNew()
            $result=Invoke-LabDiagnosticBoundedProcess -StartInfo $start -TimeoutSeconds 4
            $expected=switch($case){json {'NONE'} invalid {'DIAGNOSTIC_READINESS_RESPONSE_INVALID'} output {'DIAGNOSTIC_READINESS_OUTPUT_LIMIT'} timeout {'DIAGNOSTIC_READINESS_TIMEOUT'}}
            Assert-Diagnostic ($result.Reason -ceq $expected -and $watch.Elapsed.TotalSeconds -lt 12 -and ($result|ConvertTo-Json -Depth 8) -notmatch 'CANARY_PRIVATE') "Echter Kindprozess $case ist begrenzt und sanitisiert"
        }
        Set-Item Function:Invoke-LabDiagnosticReadinessProcess -Value $realReadiness
        # Execute the unchanged production child and parent wrapper against a tiny
        # synthetic module; only the provider implementation is replaced here.
        $childRoot=Join-Path $Root 'worker-fixture'
        $null=New-Item -ItemType Directory -Path (Join-Path $childRoot 'Tools') -Force
        Copy-Item -LiteralPath (Join-Path $Repo 'Tools/Read-SqlServerLabDiagnosticReadiness.ps1') -Destination (Join-Path $childRoot 'Tools/Read-SqlServerLabDiagnosticReadiness.ps1')
        '@{RootModule="SqlServerLab.psm1";ModuleVersion="1.0.0";FunctionsToExport=@()}' | Set-Content -LiteralPath (Join-Path $childRoot 'SqlServerLab.psd1')
        @'
function Get-LabClientRuntimeReadiness {
    param($Provider)
    [pscustomobject]@{Category='Reachability';Code=if($Provider -eq 'docker'){'PROVIDER_REACHABLE'}else{'PROVIDER_UNREACHABLE'};
        Status=if($Provider -eq 'docker'){'PASS'}else{'BLOCKED'};NextStep='CANARY_PRIVATE module';Path='CANARY_PRIVATE endpoint'}
}
'@ | Set-Content -LiteralPath (Join-Path $childRoot 'SqlServerLab.psm1')
        $savedModuleRoot=$script:ModuleRoot
        try {
            $script:ModuleRoot=$childRoot
            foreach($provider in @('docker','podman')) {
                $observed=Get-LabDiagnosticReadiness -Provider $provider -Operation Inspect
                $expected=if($provider -ceq 'docker'){'READY'}else{'NOT_READY'}
                Assert-Diagnostic ($observed.EvidenceStatus -ceq 'OBSERVED' -and $observed.Status -ceq $expected -and
                    ($observed|ConvertTo-Json -Depth 8) -notmatch 'CANARY_PRIVATE') "Produktiver Kindentry und Parent projizieren $provider sicher"
            }
        }
        finally {$script:ModuleRoot=$savedModuleRoot}
        Write-Host "DIAGNOSTIC_BUNDLE_CHECKS: PASS ($script:diagnosticAssertions assertions)"
    } $testRoot $repo
}
finally {
    # The only disposable root is the UUID directory created by this test invocation.
    if([IO.Path]::GetFullPath($testRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($testRoot) -match '^sql-lab-diagnostic-check-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
