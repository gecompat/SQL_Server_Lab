# Actual public recreate and conflict boundaries; all runtime leaves are synthetic.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        param($Repo)
        $state=Join-Path ([IO.Path]::GetTempPath()) ('sql-feature-reconcile-'+[guid]::NewGuid().ToString('N'))
        $run=[guid]::NewGuid().ToString();$scope=[guid]::NewGuid().ToString()
        $directory=Join-Path (Join-Path $state 'runs') $run
        $null=New-Item -ItemType Directory -Path $directory -Force
        $checks=0
        function Assert-FeatureReconcile {param([bool]$Condition,[string]$Name)if(-not $Condition){throw "SQL_FEATURE_RECONCILE_CHECK_FAILED: $Name"};Write-Host "PASS: $Name"}
        try {
            $selection=& (Join-Path $Repo 'Tools/Get-CiTestSelection.ps1') -ChangedPath 'Tests/Static/Fixtures/SqlFeatureReconcileChecks.ps1'
            Assert-FeatureReconcile ('Invoke-SqlFeatureChecks.ps1' -in $selection.StaticChecks) 'Standalone reconcile fixture selects the feature suite'
            $checks++
            $selection=& (Join-Path $Repo 'Tools/Get-CiTestSelection.ps1') -ChangedPath 'Private/HyperVSqlPortReconcile.ps1'
            Assert-FeatureReconcile ('Invoke-SqlFeatureChecks.ps1' -in $selection.StaticChecks -and 'Invoke-HyperVSqlPortReconcileChecks.ps1' -in $selection.StaticChecks) 'Coupled SQL-port changes retain feature recovery and existing port coverage'
            $checks++
            # Execute the real immutable projections, including the container closure.
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'Private/ExternalRuntimeReconcile.ps1'),[ref]$tokens,[ref]$errors)
            $assignment=$ast.Find({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$toImmutableFingerprint'},$true)
            $projection=$assignment.Find({param($node)$node -is [Management.Automation.Language.ScriptBlockExpressionAst]},$true).ScriptBlock.GetScriptBlock()
            foreach($project in @($projection,${function:Get-LabHyperVExternalRuntimeInstanceFingerprint},${function:Get-LabHyperVSqlConfigurationInstanceFingerprint},${function:Get-LabHyperVTestDatabaseInstanceFingerprint})){
                $item=[pscustomobject]@{Id='primary';Provider='docker';Version='2025';Intents=[pscustomobject]@{Drives=@();SqlFeatures=[pscustomobject]@{fullText=$true;fileStream=$false}}}
                $before=(& $project $item)|ConvertTo-Json -Depth 20 -Compress
                $item.Intents.SqlFeatures=[pscustomobject]@{fileStream=$false;fullText=$true}
                Assert-FeatureReconcile ((& $project $item|ConvertTo-Json -Depth 20 -Compress) -ceq $before) 'Feature field order does not create immutable drift'
                $item.Intents.SqlFeatures.fullText=$false
                Assert-FeatureReconcile ((& $project $item|ConvertTo-Json -Depth 20 -Compress) -cne $before) 'Non-feature reconcile cannot silently change explicit FullText intent'
                $item.Intents.SqlFeatures=$null
                Assert-FeatureReconcile ((& $project $item|ConvertTo-Json -Depth 20 -Compress) -cne $before) 'Omitting feature intent cannot overwrite persisted feature selection'
                $checks+=3
            }

            # A separate process must observe the actual production guard held here.
            $child=Join-Path $state 'guard-child.ps1'
            @'
param($Repo,$State,$Run,$Expected)
$ErrorActionPreference='Stop'
. (Join-Path $Repo 'Private/ContainerReconcile.ps1')
. (Join-Path $Repo 'Private/SqlFeatures.ps1')
try {
    $guard=Enter-LabSqlFeatureConflictGuard -RunId $Run -StateRoot $State
    try { if($Expected -ne 'FREE'){throw 'EXPECTED_CONFLICT'} } finally {$guard.ReleaseMutex();$guard.Dispose()}
} catch {if($Expected -ne 'BUSY' -or $_.Exception.Message -cne 'SQL_FEATURE_OPERATION_BUSY'){throw}}
Write-Output 'GUARD_CHILD_PASS'
'@|Set-Content -LiteralPath $child
            foreach($held in @($true,$false)){
                $guard=if($held){Enter-LabSqlFeatureConflictGuard -RunId $run -StateRoot $state}else{$null}
                try {
                    $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
                    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
                    foreach($argument in @('-NoLogo','-NoProfile','-File',$child,'-Repo',$Repo,'-State',$state,'-Run',$run,'-Expected',$(if($held){'BUSY'}else{'FREE'}))){$start.ArgumentList.Add($argument)}
                    $process=[Diagnostics.Process]::Start($start)
                    try {
                        $output=$process.StandardOutput.ReadToEndAsync();$errorText=$process.StandardError.ReadToEndAsync()
                        if(-not $process.WaitForExit(15000)){$process.Kill($true);throw 'FEATURE_GUARD_CHILD_TIMEOUT'}
                        Assert-FeatureReconcile ($process.ExitCode -eq 0 -and $output.GetAwaiter().GetResult().Trim() -ceq 'GUARD_CHILD_PASS') "Separate process observes guard held=$held"
                        $null=$errorText.GetAwaiter().GetResult();$checks++
                    } finally {$process.Dispose()}
                } finally {if($guard){$guard.ReleaseMutex();$guard.Dispose()}}
            }

            # Execute the complete public updater with a resolved single-instance context.
            $script:featureAudit=@();$script:featureApplications=@()
            function Test-LabAutomatedTestEnvironmentRun {$false}
            function Repair-LabContainerReconcileJournal {[pscustomobject]@{Status='ROLLED_BACK'}}
            function Get-LabContainerReconcileContext {$script:featureContext}
            function New-LabContainerReconcilePlan {[pscustomobject]@{IsNoOp=$false;HighestChangeClass='recreate';Desired=[pscustomobject]@{Port=14334;Cpu=1;MemoryMB=2048;SqlMemoryLimitMB=1024;SqlMaxMemoryMB=$null;AutoStart='off'}}}
            function Get-LabContainerRecreateMountArguments {@()}
            function Test-LabEndpointBinding {[pscustomobject]@{Available=$true}}
            function New-LabContainerReconcileJournal {[pscustomobject]@{Path='synthetic-journal';Journal=[pscustomobject]@{Runtime=[pscustomobject]@{BackupName='';ReplacementId=''};Target=[pscustomobject]@{MountFingerprint='synthetic-mounts'};OperationId=[guid]::NewGuid().ToString();Status='PREPARED'}}}
            function Write-LabContainerReconcileJournal {param($Journal,$Path)$Journal}
            function Set-LabContainerReconcileJournalStatus {param($Journal,$Path,$Status)$Journal.Status=$Status;$Journal}
            function Invoke-LabContainerReconcileCommand {param($Provider,$Arguments,$ErrorCode)$script:featureAudit+=,$Arguments[0]}
            function Assert-LabContainerReconcileRuntimeIdentity {$script:featureReplacement}
            function Get-LabSecret {
                $secret=[securestring]::new()
                $secret.AppendChar([char]0x78)
                $secret.MakeReadOnly()
                $secret
            }
            function Wait-SqlReady {[pscustomobject]@{Ready=$true}}
            function Invoke-LabInitialContainerSqlFeatures {param($Instance,$RunState,$Container,$SaPassword)$script:featureApplications+=,[pscustomobject]@{Instance=$Instance;Container=$Container};$script:featureAudit+='features'}
            function Get-LabContainerMountFingerprint {'synthetic-mounts'}
            function New-SqlConnectionString {'synthetic-connection'}
            function Write-LabArtifactJsonAtomic {}
            foreach($provider in @('docker','podman')){
                foreach($explicit in @($true,$false)){
                    foreach($enabled in @($true,$false)){
                        $instance=[pscustomobject]@{id='primary';version='2025';provider=$provider;host='127.0.0.1'}
                        $labels=[pscustomobject]@{'sql-server-lab.autostart'='off'}
                        $script:featureContext=[pscustomobject]@{Instance=$instance;InstanceId='primary';Provider=$provider;ContainerName='synthetic-sql';WasRunning=$true;CurrentPort=14333;RunDirectory=$directory;ConnectionPath='synthetic-connection';Connection=[pscustomobject]@{instances=@($instance)};Run=[pscustomobject]@{scopeId=$scope;metadata=[pscustomobject]@{desiredState=[pscustomobject]@{Instances=@([pscustomobject]@{Id='primary';Intents=[pscustomobject]@{SqlFeatures=[pscustomobject]@{fullText=$enabled;fileStream=$false}}})}}};Inspect=[pscustomobject]@{Config=[pscustomobject]@{Hostname='';Env=@();Image='synthetic-image';Labels=$labels};NetworkSettings=[pscustomobject]@{Networks=[pscustomobject]@{}}}}
                        $script:featureReplacement=[pscustomobject]@{Id=('b'*64);Mounts=@();Config=[pscustomobject]@{Labels=$labels};HostConfig=[pscustomobject]@{RestartPolicy=[pscustomobject]@{Name='no'}};NetworkSettings=[pscustomobject]@{Ports=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostPort=14334})}}}
                        $script:featureAudit=@();$script:featureApplications=@()
                        $arguments=@{RunId=$run;StateRoot=$state;Port=14334;Confirm=$false};if($explicit){$arguments.InstanceId='primary'}
                        $result=Update-SqlServerLabContainer @arguments
                        $applied=$script:featureApplications
                        Assert-FeatureReconcile ($result.Status -ceq 'SUCCEEDED' -and $applied.Count -eq 1 -and $applied[0].Instance.id -ceq 'primary' -and $applied[0].Instance.sqlFeatures.fullText -is [bool] -and $applied[0].Instance.sqlFeatures.fullText -eq $enabled -and $applied[0].Container.Provider -ceq $provider -and $applied[0].Container.ContainerId -ceq ('b'*64) -and $script:featureAudit.IndexOf('features') -lt $script:featureAudit.IndexOf('rm')) "Public recreate preserves $provider feature=$enabled explicitInstance=$explicit before removing original"
                        $checks++
                    }
                }
            }

            # Every coupled mutation must reject recovery before reaching any leaf.
            function Assert-LabWindowsPoolMutationAllowed {throw 'SYNTHETIC_MUTATION_BOUNDARY_REACHED'}
            function Get-LabExternalRuntimeReconcileContext {throw 'SYNTHETIC_CONTEXT_REACHED'}
            '{"Status":"RECOVERY_REQUIRED"}'|Set-Content -LiteralPath (Join-Path $directory 'sql-feature-primary-FullText.json')
            $commands=@(
                @{Name='Update-SqlServerLabContainer';Extra=@{Port=14334}},
                @{Name='Set-SqlServerLabContainerAutoStart';Extra=@{InstanceId='primary';AutoStart='on';ExpectedAutoStartPlanKey=('a'*64)}},
                @{Name='Resume-SqlServerLabContainerAutoStart';Extra=@{InstanceId='primary'}},
                @{Name='Invoke-LabExternalRuntimeReconcileRefresh';Extra=@{ManifestPath='synthetic-manifest'}},
                @{Name='Invoke-LabHyperVExternalRuntimeReconcileRepair';Extra=@{InstanceId='primary';ManifestPath='synthetic-manifest'}},
                @{Name='Invoke-LabHyperVResourceReconcileRepair';Extra=@{InstanceId='primary'}},
                @{Name='Invoke-LabHyperVStorageReconcileRepair';Extra=@{InstanceId='primary'}},
                @{Name='Invoke-LabHyperVSqlPortReconcileRepair';Extra=@{InstanceId='primary'}},
                @{Name='Invoke-LabHyperVSqlConfigurationReconcileRepair';Extra=@{InstanceId='primary'}},
                @{Name='Invoke-LabHyperVTestDatabaseReconcileRepair';Extra=@{InstanceId='primary';ManifestPath='synthetic-manifest'}}
            )
            foreach($command in $commands){
                $arguments=$command.Extra;$message='';$before=$script:featureAudit.Count
                try{$null=& $command.Name -RunId $run -StateRoot $state @arguments}catch{$message=$_.Exception.Message}
                Assert-FeatureReconcile ($message -ceq 'SQL_FEATURE_RECOVERY_REQUIRED_NO_REPLAY' -and $script:featureAudit.Count -eq $before) ($command.Name+' rejects pending feature recovery before mutation')
                $checks++
            }
            Write-Host "SQL FEATURE RECONCILE CHECKS: PASS ($checks assertions; synthetic leaves; real process locks)"
        } finally {
            if((Resolve-Path -LiteralPath $state).Path -cne [IO.Path]::GetFullPath($state)){throw 'FEATURE_FIXTURE_CLEANUP_BINDING_CHANGED'}
            Remove-Item -LiteralPath $state -Recurse -Force
        }
    } $repo
} finally {Remove-Module $module.Name -Force}
