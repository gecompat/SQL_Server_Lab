#Requires -Version 7.2
<#
.SYNOPSIS
    Verifiziert die native Hyper-V-vCPU/RAM-Reconcile gegen zwei isolierte SQL-2025-Runs.
.DESCRIPTION
    Der Runner erzeugt ausschliesslich zwei eigene Prepared-Artifact-Runs: zuerst
    dynamischen RAM mit einer live steuerbaren Min/Max-Drift, danach statischen
    RAM mit CPU-, Startup- und Modusdrift. Fuer beide Faelle prueft er den
    oeffentlichen read-only Plan, WhatIf ohne Journalmutation und die
    eigentumsgebundene oeffentliche Reparatur. Der Runner injiziert keinen
    Start-VM-Fehler; ein nativer, VM-ID-gebundener Failure-Injection-Nachweis
    bleibt daher bewusst offen.
#>
[CmdletBinding()]
param(
    [string]$ArtifactId,
    [string]$StateRoot,
    [Parameter(Mandatory)][ValidatePattern('^github-[0-9]+-[0-9]+-resource-r[12]$')][string]$Run1OperationId,
    [Parameter(Mandatory)][ValidatePattern('^github-[0-9]+-[0-9]+-resource-r[12]$')][string]$Run2OperationId,
    [switch]$DeferCleanup
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-resource-reconcile-'+[guid]::NewGuid().ToString('N'))
$previousStateRoot=$env:SQL_SERVER_LAB_STATE
$module=$null;$createdRunIds=@();$completed=$false;$stage='INITIALIZATION'
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_HyperV_Resource_Reconcile_Acceptance');$mutexAcquired=$false
function Assert-HyperVResourceAcceptance { param([bool]$Condition,[string]$Description) if(-not $Condition){throw "HYPERV_RESOURCE_ACCEPTANCE_FAILED: $Description"};Write-Host "PASS: $Description" -ForegroundColor Green }
function Invoke-Private { param([scriptblock]$ScriptBlock,[object[]]$Arguments=@()) & $module $ScriptBlock @Arguments }
function Write-ResourceManifest {
    param([string]$Path,[string]$Name,[string]$PreparedArtifactId,[int]$Cpu,[bool]$Dynamic,[int]$Minimum,[int]$Startup,[int]$Maximum)
    $value=[ordered]@{
        '$schema'=(Join-Path $repoRoot 'Schemas/lab-manifest.schema.json');name=$Name;automation=[ordered]@{mode='unattended'}
        instances=@([ordered]@{id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off'
            network=[ordered]@{intent='hostOnly';exposure='host'}
            windowsActivation=[ordered]@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='EvaluationOnline';EgressPolicy='AllowTemporary'}
            hyperv=[ordered]@{preparedImageId=$PreparedArtifactId;memoryStartupMB=$Startup;memoryMinimumMB=$Minimum;memoryMaximumMB=$Maximum;dynamicMemoryEnabled=$Dynamic;processorCount=$Cpu;sqlPort=1433;guestPasswordMode='prompt'}
        })
    }
    $value|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $Path -Encoding utf8
}
function Get-Context { param([string]$RunId) Invoke-Private {param($Id,$Root)Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root} @($RunId,$StateRoot) }
function Get-OwnedVm { param($Context) Invoke-Private {param($Name,$Id,$Scope)Get-HyperVManagedVM -VMName $Name -ExpectedRunId $Id -ExpectedScopeId $Scope} @([string]$Context.Instance.vmName,[string]$Context.Run.runId,[string]$Context.Run.scopeId) }
function Get-ResourceValues { param($Context) $vm=(Get-OwnedVm $Context).VM;[pscustomobject]@{Id=[string]$vm.Id;State=[string]$vm.State;Cpu=[int]$vm.ProcessorCount;Dynamic=[bool]$vm.DynamicMemoryEnabled;Minimum=[int]([long]$vm.MemoryMinimum/1MB);Startup=[int]([long]$vm.MemoryStartup/1MB);Maximum=[int]([long]$vm.MemoryMaximum/1MB)} }
function New-SqlConnection { param($Context,[securestring]$Password) if(-not $Password.IsReadOnly()){$Password.MakeReadOnly()};$connection=[Data.SqlClient.SqlConnection]::new();$connection.ConnectionString="Server=$([string]$Context.Instance.host),$([int]$Context.Instance.port);Database=master;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;";$connection.Credential=[Data.SqlClient.SqlCredential]::new('sa',$Password);$connection }
function Invoke-Scalar { param($Context,[securestring]$Password,[string]$Query) $connection=New-SqlConnection $Context $Password;try{$connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=120;$command.CommandText=$Query;[string]$command.ExecuteScalar()}finally{$connection.Dispose()} }
function Invoke-NonQuery { param($Context,[securestring]$Password,[string]$Query) $connection=New-SqlConnection $Context $Password;try{$connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=120;$command.CommandText=$Query;$null=$command.ExecuteNonQuery()}finally{$connection.Dispose()} }
function Wait-ResourceSqlMarker { param($Context,[securestring]$Password) $deadline=[datetime]::UtcNow.AddMinutes(5);do{try{$value=Invoke-Scalar $Context $Password 'SELECT COUNT(*) FROM tempdb.dbo.SqlLabHvResourceMarker WHERE Marker=2025;';if($value -eq '1'){return $value}}catch{};Start-Sleep -Seconds 5}while([datetime]::UtcNow -lt $deadline);throw 'HYPERV_RESOURCE_ACCEPTANCE_POST_RESTART_SQL_READINESS_TIMEOUT' }
function New-OwnedRun {
    param([string]$ManifestPath,[string]$OperationId,[securestring]$GuestPassword,[securestring]$SqlPassword)
    $lab=Invoke-Private {param($Path,$Op,$Guest,$Sql,$Root)Invoke-WithLabWorkflowOperationContext -OperationId $Op -ScriptBlock { New-SqlServerLab -Manifest $Path -GuestPassword $Guest -SqlSaPassword $Sql -NonInteractive -StateRoot $Root -Region AT -SystemLocale de-AT -UiLanguage en-US -InputLocale '0407:00000407' -TimeZone 'W. Europe Standard Time' }} @($ManifestPath,$OperationId,$GuestPassword,$SqlPassword,$StateRoot)
    $createdRunIds += [string]$lab.RunId
    Assert-HyperVResourceAcceptance ([string]$lab.State -eq 'RUNNING') 'Isolierter SQL-2025-Prepared-Run ist bereit'
    return $lab
}
function Assert-WhatIfUnchanged {
    param([string]$RunId,[string]$JournalPath,$Context,[securestring]$Password)
    $before=if(Test-Path -LiteralPath $JournalPath){Get-Content -LiteralPath $JournalPath -Raw -Encoding utf8}else{$null}
    $markerBefore=Invoke-Scalar $Context $Password "SELECT COUNT(*) FROM tempdb.sys.objects WHERE name=N'__sql_lab_hv_resource_marker_never_exists';"
    $whatIf=Invoke-SqlServerLabReconcileAction -RunId $RunId -RepairHyperVResources -InstanceId primary -StateRoot $StateRoot -WhatIf
    $after=if(Test-Path -LiteralPath $JournalPath){Get-Content -LiteralPath $JournalPath -Raw -Encoding utf8}else{$null}
    Assert-HyperVResourceAcceptance ([string]$whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and $before -ceq $after -and $markerBefore -eq '0') 'WhatIf veraendert weder Ressourcen noch Journal'
}
function Remove-OwnRuns { foreach($id in @($createdRunIds|Sort-Object -Unique)){try{Remove-SqlServerLab -RunId $id -StateRoot $StateRoot -Force -Confirm:$false|Out-Null}catch{Write-Warning "HYPERV_RESOURCE_ACCEPTANCE_OWNED_CLEANUP_FAILED"}} }
try {
    $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(15));if(-not $mutexAcquired){throw 'HYPERV_RESOURCE_ACCEPTANCE_HOST_LOCK_TIMEOUT'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());Assert-HyperVResourceAcceptance $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) 'Runner arbeitet erhoeht'
    Get-Command Get-VM,Set-VMMemory,Set-VMProcessor,Stop-VM,Start-VM -ErrorAction Stop|Out-Null
    $null=New-Item -ItemType Directory -Path $testRoot -Force
    $module=Import-Module $modulePath -Force -PassThru
    if(-not $StateRoot){$StateRoot=Invoke-Private {Get-LabStateRoot}};$env:SQL_SERVER_LAB_STATE=$StateRoot
    if(-not $ArtifactId){$artifact=Invoke-Private {param($Root)@(Get-HyperVImageArtifact -StateRoot $Root|Where-Object{[string]$_.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$_.sql.version -eq '2025' -and [string]$_.licenseType -ne 'test-only'}|Sort-Object{[datetime]$_.registeredAt} -Descending|Select-Object -First 1)[0]} @($StateRoot);if(-not $artifact){throw 'HYPERV_RESOURCE_ACCEPTANCE_SQL_PREPARED_ARTIFACT_NOT_FOUND'};$ArtifactId=[string]$artifact.artifactId}
    $artifact=Invoke-Private {param($Id,$Root)Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root} @($ArtifactId,$StateRoot)
    $eligibility=Invoke-Private {param($Candidate)[pscustomobject]@{Evaluation=Test-HyperVImageArtifactEvaluationEligibility -Artifact $Candidate;Child=Test-HyperVImageArtifactChildValidationEligibility -Artifact $Candidate}} @($artifact)
    Assert-HyperVResourceAcceptance ([string]$artifact.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$artifact.sql.version -eq '2025' -and [string]$artifact.integrityVerification.status -in @('VERIFIED_CACHE','VERIFIED_HASH') -and [bool]$eligibility.Evaluation.Eligible -and [bool]$eligibility.Child.Eligible) 'Verifiziertes SQL-2025-Prepared-Artifact ist verfuegbar'
    $guest=Invoke-Private {New-HyperVSqlUnattendedPassword};$sa=Invoke-Private {New-HyperVSqlUnattendedPassword}
    # Run 1: running dynamic memory permits exactly min/max live repair.
    $stage='DYNAMIC_MANIFEST';
    $dynamicManifest=Join-Path $testRoot 'dynamic.json';Write-ResourceManifest $dynamicManifest ('hv-resource-dynamic-'+[guid]::NewGuid().ToString('N').Substring(0,8)) $ArtifactId 4 $true 1024 6144 8192
    Assert-HyperVResourceAcceptance (Test-SqlServerLabManifest -Path $dynamicManifest).IsValid 'Dynamisches Zielmanifest ist gueltig'
    $stage='DYNAMIC_PROVISION';
    $dynamicLab=New-OwnedRun $dynamicManifest $Run1OperationId $guest $sa;$dynamicContext=Get-Context $dynamicLab.RunId
    Invoke-NonQuery $dynamicContext $sa "CREATE TABLE tempdb.dbo.SqlLabHvResourceMarker (Marker int NOT NULL); INSERT tempdb.dbo.SqlLabHvResourceMarker VALUES (2025);"
    $stage='DYNAMIC_DRIFT';
    $dynamicVm=(Get-OwnedVm $dynamicContext).VM;Set-VMMemory -VM $dynamicVm -DynamicMemoryEnabled $true -MinimumBytes 2048MB -MaximumBytes 7168MB -ErrorAction Stop
    $dynamicValues=Get-ResourceValues $dynamicContext;Assert-HyperVResourceAcceptance ($dynamicValues.Dynamic -and $dynamicValues.Minimum -eq 2048 -and $dynamicValues.Maximum -eq 7168) 'Run-eigene dynamische Min/Max-Drift ist hergestellt'
    $stage='DYNAMIC_PLAN';
    $dynamicJournal=Join-Path $dynamicContext.RunDirectory 'hyperv-resource-reconcile.local.journal.json';$dynamicPlan=Get-SqlServerLabReconcilePlan -RunId $dynamicLab.RunId -HyperVResources -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVResourceAcceptance ([string]$dynamicPlan.HighestChangeClass -eq 'live' -and @($dynamicPlan.Diff.Field) -contains 'MemoryMinimumMB' -and @($dynamicPlan.Diff.Field) -contains 'MemoryMaximumMB') 'Read-only Plan klassifiziert dynamische Drift als live'
    $stage='DYNAMIC_WHATIF';
    Assert-WhatIfUnchanged $dynamicLab.RunId $dynamicJournal $dynamicContext $sa
    $stage='DYNAMIC_APPLY';
    $dynamicResult=Invoke-SqlServerLabReconcileAction -RunId $dynamicLab.RunId -RepairHyperVResources -InstanceId primary -StateRoot $StateRoot -Confirm:$false;$dynamicValues=Get-ResourceValues $dynamicContext;$dynamicReceipt=Get-Content -LiteralPath $dynamicJournal -Raw -Encoding utf8|ConvertFrom-Json -Depth 30
    Assert-HyperVResourceAcceptance ([string]$dynamicResult.ExecutionSummary.Status -eq 'SUCCEEDED' -and $dynamicValues.Dynamic -and $dynamicValues.Minimum -eq 1024 -and $dynamicValues.Startup -eq 6144 -and $dynamicValues.Maximum -eq 8192 -and [string]$dynamicReceipt.Status -eq 'COMPLETED') 'Live-Reconcile stellt dynamische RAM-Werte und Journal wieder her'
    $stage='DYNAMIC_NOOP';
    Assert-HyperVResourceAcceptance (Get-SqlServerLabReconcilePlan -RunId $dynamicLab.RunId -HyperVResources -InstanceId primary -StateRoot $StateRoot).IsNoOp 'Dynamischer Wiederholungsplan ist No-op'
    # Run 2: CPU, startup RAM and mode must pass through the owned restart path.
    $stage='STATIC_MANIFEST';
    $staticManifest=Join-Path $testRoot 'static.json';Write-ResourceManifest $staticManifest ('hv-resource-static-'+[guid]::NewGuid().ToString('N').Substring(0,8)) $ArtifactId 4 $false 6144 6144 6144
    Assert-HyperVResourceAcceptance (Test-SqlServerLabManifest -Path $staticManifest).IsValid 'Statisches Zielmanifest ist gueltig'
    $stage='STATIC_PROVISION';
    $staticLab=New-OwnedRun $staticManifest $Run2OperationId $guest $sa;$staticContext=Get-Context $staticLab.RunId
    Invoke-NonQuery $staticContext $sa "CREATE TABLE tempdb.dbo.SqlLabHvResourceMarker (Marker int NOT NULL); INSERT tempdb.dbo.SqlLabHvResourceMarker VALUES (2025);"
    $stage='STATIC_DRIFT';
    $staticVm=(Get-OwnedVm $staticContext).VM;Stop-VM -VM $staticVm -Confirm:$false -ErrorAction Stop
    $deadline=[datetime]::UtcNow.AddMinutes(3);do{Start-Sleep -Seconds 2;$staticVm=(Get-OwnedVm $staticContext).VM}while([string]$staticVm.State -ne 'Off' -and [datetime]::UtcNow -lt $deadline);Assert-HyperVResourceAcceptance ([string]$staticVm.State -eq 'Off') 'Run-eigene VM ist fuer statische Drift gestoppt'
    Set-VMProcessor -VM $staticVm -Count 2 -ErrorAction Stop;Set-VMMemory -VM $staticVm -DynamicMemoryEnabled $true -MinimumBytes 1024MB -StartupBytes 4096MB -MaximumBytes 8192MB -ErrorAction Stop;Start-VM -VM $staticVm -ErrorAction Stop
    $deadline=[datetime]::UtcNow.AddMinutes(5);do{Start-Sleep -Seconds 3;$values=Get-ResourceValues $staticContext}while([string]$values.State -ne 'Running' -and [datetime]::UtcNow -lt $deadline);Assert-HyperVResourceAcceptance ($values.Cpu -eq 2 -and $values.Dynamic -and $values.Startup -eq 4096) 'CPU-, Startup-RAM- und Modusdrift sind rungebunden hergestellt'
    $stage='STATIC_PLAN';
    $staticJournal=Join-Path $staticContext.RunDirectory 'hyperv-resource-reconcile.local.journal.json';$staticPlan=Get-SqlServerLabReconcilePlan -RunId $staticLab.RunId -HyperVResources -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVResourceAcceptance ([string]$staticPlan.HighestChangeClass -eq 'restart' -and $staticPlan.Actions[0].RequiresRestart -and @($staticPlan.Diff.Field) -contains 'ProcessorCount' -and @($staticPlan.Diff.Field) -contains 'DynamicMemoryEnabled') 'Read-only Plan klassifiziert CPU-, RAM- und Modusdrift als Restart'
    $stage='STATIC_WHATIF';
    Assert-WhatIfUnchanged $staticLab.RunId $staticJournal $staticContext $sa
    $stage='STATIC_APPLY';
    $staticResult=Invoke-SqlServerLabReconcileAction -RunId $staticLab.RunId -RepairHyperVResources -InstanceId primary -StateRoot $StateRoot -Confirm:$false;$staticValues=Get-ResourceValues $staticContext;$staticReceipt=Get-Content -LiteralPath $staticJournal -Raw -Encoding utf8|ConvertFrom-Json -Depth 30
    $stage='STATIC_SQL_READINESS';
    $marker=Wait-ResourceSqlMarker $staticContext $sa
    Assert-HyperVResourceAcceptance ([string]$staticResult.ExecutionSummary.Status -eq 'SUCCEEDED' -and $staticValues.Cpu -eq 4 -and -not $staticValues.Dynamic -and $staticValues.Minimum -eq 6144 -and $staticValues.Startup -eq 6144 -and $staticValues.Maximum -eq 6144 -and [string]$staticReceipt.Status -eq 'COMPLETED' -and $marker -eq '1') 'Restart-Reconcile stellt CPU, statischen RAM, SQL-Readiness und Datenmarker wieder her'
    $stage='STATIC_NOOP';
    Assert-HyperVResourceAcceptance (Get-SqlServerLabReconcilePlan -RunId $staticLab.RunId -HyperVResources -InstanceId primary -StateRoot $StateRoot).IsNoOp 'Statischer Wiederholungsplan ist No-op'
    $completed=$true} catch {
    $allowedStages=@('INITIALIZATION','DYNAMIC_MANIFEST','DYNAMIC_PROVISION','DYNAMIC_DRIFT','DYNAMIC_PLAN','DYNAMIC_WHATIF','DYNAMIC_APPLY','DYNAMIC_NOOP','STATIC_MANIFEST','STATIC_PROVISION','STATIC_DRIFT','STATIC_PLAN','STATIC_WHATIF','STATIC_APPLY','STATIC_SQL_READINESS','STATIC_NOOP')
    $safeStage=if($stage -in $allowedStages){$stage}else{'INITIALIZATION'}
    throw "HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_${safeStage}_FAILED"
} finally {
    if(-not $DeferCleanup -or -not $completed){Remove-OwnRuns}
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
    if($previousStateRoot){$env:SQL_SERVER_LAB_STATE=$previousStateRoot}else{Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue}
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue};if($mutexAcquired){$mutex.ReleaseMutex()};$mutex.Dispose()
}
Write-Host 'Native Hyper-V-Ressourcen-Reconcile-Akzeptanz erfolgreich.' -ForegroundColor Green
