#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt den nativen Hyper-V-SQL-Konfigurations-Reconcile gegen SQL Server 2025 aus.
.DESCRIPTION
    Erstellt aus einem verifizierten SQL_PREPARED_SEALED-Artifact einen neuen,
    scopegebundenen Manifest-Run. Der Lauf prueft den oeffentlichen read-only
    Plan, WhatIf, Live-Konfiguration, additive und eigentumsgebundene Runtime-
    Trace-Flags, Fremdflag-Schutz, einen ausschliesslichen MSSQLSERVER-Restart,
    Desired-State-Rueckkehr, No-op und vollstaendigen Cleanup.
.PARAMETER ArtifactId
    Optionales SQL_PREPARED_SEALED-Artifact. Ohne Angabe wird das neueste
    verifizierte SQL-2025-Artifact im State Root verwendet.
.PARAMETER StateRoot
    Optionaler State Root. Der Runner erzeugt darin genau einen neuen Run.
.PARAMETER KeepOnFailure
    Belaesst einen fehlgeschlagenen Run samt Journal fuer den Recovery-Pfad.
#>
[CmdletBinding()]
param(
    [string]$ArtifactId,
    [string]$StateRoot,
    [switch]$KeepOnFailure
)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-sql-config-'+[Guid]::NewGuid().ToString('N'))
$baseManifestPath=Join-Path $testRoot 'base.json'
$liveManifestPath=Join-Path $testRoot 'live.json'
$restartManifestPath=Join-Path $testRoot 'restart.json'
$previousStateRoot=$env:SQL_SERVER_LAB_STATE
$module=$null;$lab=$null;$ownedPaths=@();$completed=$false
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_HyperV_SQL_Configuration_Acceptance')
$mutexAcquired=$false

function Assert-HyperVSqlConfigurationAcceptance {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Description,[string]$Evidence)
    if(-not $Condition){throw "HYPERV_SQL_CONFIGURATION_ACCEPTANCE_FAILED: $Description$(if($Evidence){": $Evidence"})"}
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function Invoke-Private {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock,[object[]]$Arguments=@())
    & $module $ScriptBlock @Arguments
}

function Write-SqlConfigurationManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LabName,
        [Parameter(Mandatory)][string]$PreparedArtifactId,
        [Parameter(Mandatory)][int]$CostThreshold,
        [Parameter(Mandatory)][int]$FillFactor,
        [int[]]$TraceFlags=@()
    )
    $manifest=[ordered]@{
        '$schema'=(Join-Path $repoRoot 'Schemas/lab-manifest.schema.json')
        name=$LabName;automation=[ordered]@{mode='unattended'}
        instances=@([ordered]@{
            id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off'
            network=[ordered]@{intent='hostOnly';exposure='host'}
            hyperv=[ordered]@{preparedImageId=$PreparedArtifactId;memoryStartupMB=6144;processorCount=4;sqlPort=1433;guestPasswordMode='prompt'}
            serverConfig=[ordered]@{
                memory=[ordered]@{minMB=512;maxMB=4096};maxDop=4;costThreshold=$CostThreshold
                traceFlags=@($TraceFlags);spConfigure=[ordered]@{'fill factor (%)'=$FillFactor}
            }
        })
    }
    $manifest|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $Path -Encoding utf8
}

function New-AcceptanceSqlConnection {
    $connection=[Data.SqlClient.SqlConnection]::new()
    $connection.ConnectionString="Server=$script:sqlAddress,$script:sqlPort;Database=master;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;"
    $connection.Credential=[Data.SqlClient.SqlCredential]::new('sa',$script:saPassword)
    $connection
}

function Invoke-AcceptanceScalar {
    param([Parameter(Mandatory)][string]$Query)
    $connection=New-AcceptanceSqlConnection
    try{$connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=120;$command.CommandText=$Query;$command.ExecuteScalar()}
    finally{$connection.Dispose()}
}

function Invoke-AcceptanceNonQuery {
    param([Parameter(Mandatory)][string]$Query)
    $connection=New-AcceptanceSqlConnection
    try{$connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=120;$command.CommandText=$Query;$null=$command.ExecuteNonQuery()}
    finally{$connection.Dispose()}
}

function Get-AcceptanceTraceFlags {
    $connection=New-AcceptanceSqlConnection
    try{
        $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=120
        $command.CommandText='DBCC TRACESTATUS(-1) WITH NO_INFOMSGS;'
        $table=[Data.DataTable]::new();$reader=$command.ExecuteReader();$table.Load($reader);$reader.Dispose()
        @($table.Rows|Where-Object{[int]$_.Global -eq 1 -and [int]$_.Status -eq 1}|ForEach-Object{[int]$_.TraceFlag}|Sort-Object -Unique)
    }
    finally{$connection.Dispose()}
}

function Get-AcceptanceConfigurationValue {
    param([Parameter(Mandatory)][string]$Name)
    $escaped=$Name.Replace("'","''")
    [string](Invoke-AcceptanceScalar -Query "SELECT CONCAT(CONVERT(varchar(30),value),':',CONVERT(varchar(30),value_in_use)) FROM sys.configurations WHERE name=N'$escaped';")
}

function Get-AcceptanceGuestBootTime {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][PSCredential]$Credential)
    [string](Invoke-Private {
        param($VmName,$RunId,$ScopeId,$Credential)
        $result=Invoke-HyperVPowerShellDirect -VMName $VmName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId -Credential $Credential -ScriptBlock {
            (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        }
        [string]@($result)[-1]
    } @([string]$Context.Instance.vmName,[string]$Context.Run.runId,[string]$Context.Run.scopeId,$Credential))
}

function Test-ScopedTemporaryRoot {
    param([Parameter(Mandatory)][string]$Path)
    $resolved=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    $expectedParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $actualParent=[IO.Directory]::GetParent($resolved).FullName.TrimEnd('\')
    $actualParent.Equals($expectedParent,[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^sql-lab-hv-sql-config-[a-f0-9]{32}$'
}

try{
    $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(15))
    if(-not $mutexAcquired){throw 'HYPERV_SQL_CONFIGURATION_ACCEPTANCE_HOST_LOCK_TIMEOUT'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-HyperVSqlConfigurationAcceptance ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Runner arbeitet erhoeht'
    Get-Command Get-VM -ErrorAction Stop|Out-Null
    $null=New-Item -Path $testRoot -ItemType Directory -Force
    $module=Import-Module $modulePath -Force -PassThru
    if(-not $StateRoot){$StateRoot=Invoke-Private {Get-LabStateRoot}}
    $env:SQL_SERVER_LAB_STATE=$StateRoot

    if(-not $ArtifactId){
        $artifact=Invoke-Private {
            param($Root)
            @(Get-HyperVImageArtifact -StateRoot $Root -SkipIntegrityCheck|Where-Object{
                [string]$_.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$_.sql.version -eq '2025' -and [string]$_.licenseType -ne 'test-only'
            }|Sort-Object{[datetime]$_.registeredAt} -Descending|Select-Object -First 1)[0]
        } @($StateRoot)
        if(-not $artifact){throw 'HYPERV_SQL_CONFIGURATION_SQL_PREPARED_ARTIFACT_NOT_FOUND'}
        $ArtifactId=[string]$artifact.artifactId
    }
    $artifact=Invoke-Private {param($Id,$Root)Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root} @($ArtifactId,$StateRoot)
    Assert-HyperVSqlConfigurationAcceptance (
        [string]$artifact.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$artifact.sql.version -eq '2025'
    ) 'Verifiziertes SQL-2025-Prepared-Artifact ist verfuegbar' $ArtifactId

    $labName='hv-sql-config-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    Write-SqlConfigurationManifest -Path $baseManifestPath -LabName $labName -PreparedArtifactId $ArtifactId -CostThreshold 25 -FillFactor 0
    Write-SqlConfigurationManifest -Path $liveManifestPath -LabName $labName -PreparedArtifactId $ArtifactId -CostThreshold 30 -FillFactor 0 -TraceFlags @(1117)
    Write-SqlConfigurationManifest -Path $restartManifestPath -LabName $labName -PreparedArtifactId $ArtifactId -CostThreshold 25 -FillFactor 80
    $validations=@(@($baseManifestPath,$liveManifestPath,$restartManifestPath)|ForEach-Object{Test-SqlServerLabManifest -Path $_})
    Assert-HyperVSqlConfigurationAcceptance (@($validations|Where-Object{-not $_.IsValid}).Count -eq 0) 'Alle SQL-Konfigurations-Zielmanifeste sind vor Mutation gueltig'

    $guestPassword=Invoke-Private {New-HyperVSqlUnattendedPassword}
    $script:saPassword=Invoke-Private {New-HyperVSqlUnattendedPassword}
    $guestCredential=[PSCredential]::new('Administrator',$guestPassword)
    $lab=New-SqlServerLab -Manifest $baseManifestPath -GuestPassword $guestPassword -SqlSaPassword $script:saPassword `
        -NonInteractive -StateRoot $StateRoot -Region AT -SystemLocale de-AT -UiLanguage en-US `
        -InputLocale '0407:00000407' -TimeZone 'W. Europe Standard Time'
    Assert-HyperVSqlConfigurationAcceptance ([string]$lab.State -eq 'RUNNING') 'Isolierter SQL-Prepared-Manifest-Run ist bereit'
    $runId=[string]$lab.RunId
    $context=Invoke-Private {param($Id,$Root)Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root} @($runId,$StateRoot)
    $identity=Invoke-Private {
        param($VmName,$RunId,$ScopeId)
        (Get-HyperVManagedVM -VMName $VmName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId).Identity
    } @([string]$context.Instance.vmName,$runId,[string]$context.Run.scopeId)
    $ownedPaths=@([string]$identity.childVhdxPath)+@($identity.additionalDrives|ForEach-Object{[string]$_.path})
    $script:sqlAddress=[string]$context.Instance.host;$script:sqlPort=[int]$context.Instance.port
    Assert-HyperVSqlConfigurationAcceptance (
        -not[string]::IsNullOrWhiteSpace($script:sqlAddress) -and $script:sqlPort -gt 0
    ) 'Host-SQL-Zugriff ist gebunden'
    Assert-HyperVSqlConfigurationAcceptance (
        (Get-AcceptanceConfigurationValue 'cost threshold for parallelism') -eq '25:25' -and
        (Get-AcceptanceConfigurationValue 'fill factor (%)') -eq '0:0'
    ) 'Initialer dynamischer und restartpflichtiger Sollzustand ist aktiv'

    Invoke-AcceptanceNonQuery 'DBCC TRACEON (3604,-1) WITH NO_INFOMSGS;'
    $livePlan=Get-SqlServerLabReconcilePlan -RunId $runId -HyperVSqlConfiguration -ManifestPath $liveManifestPath -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVSqlConfigurationAcceptance (
        [string]$livePlan.HighestChangeClass -eq 'live' -and @($livePlan.Diff.Kind) -contains 'configuration' -and
        @($livePlan.Diff.Kind) -contains 'trace-flag-add' -and -not $livePlan.MutationAllowed
    ) 'Read-only Plan erkennt dynamische Konfiguration und Trace-Flag-Addition als live'
    $journalPath=Join-Path $context.RunDirectory 'hyperv-sql-configuration-reconcile.local.journal.json'
    $whatIf=Invoke-SqlServerLabReconcileAction -RunId $runId -RepairHyperVSqlConfiguration -ManifestPath $liveManifestPath -InstanceId primary -StateRoot $StateRoot -WhatIf
    Assert-HyperVSqlConfigurationAcceptance (
        [string]$whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and -not(Test-Path -LiteralPath $journalPath) -and
        (Get-AcceptanceConfigurationValue 'cost threshold for parallelism') -eq '25:25' -and 1117 -notin @(Get-AcceptanceTraceFlags)
    ) 'WhatIf schreibt weder Journal noch SQL-Konfiguration'

    $liveResult=Invoke-SqlServerLabReconcileAction -RunId $runId -RepairHyperVSqlConfiguration -ManifestPath $liveManifestPath -InstanceId primary -StateRoot $StateRoot -Confirm:$false
    $ownershipPath=Join-Path $context.RunDirectory 'hyperv-sql-configuration-ownership.local.json'
    $ownership=Get-Content -LiteralPath $ownershipPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 20
    Assert-HyperVSqlConfigurationAcceptance (
        [string]$liveResult.ExecutionSummary.Status -eq 'SUCCEEDED' -and
        (Get-AcceptanceConfigurationValue 'cost threshold for parallelism') -eq '30:30' -and
        1117 -in @(Get-AcceptanceTraceFlags) -and 3604 -in @(Get-AcceptanceTraceFlags) -and 1117 -in @($ownership.TraceFlags)
    ) 'Live-Apply aktiviert nur den Zielwert und erfasst das neue run-eigene Trace Flag'
    $liveNoOp=Get-SqlServerLabReconcilePlan -RunId $runId -HyperVSqlConfiguration -ManifestPath $liveManifestPath -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVSqlConfigurationAcceptance $liveNoOp.IsNoOp 'Wiederholter Live-Plan ist No-op'

    $removePlan=Get-SqlServerLabReconcilePlan -RunId $runId -HyperVSqlConfiguration -ManifestPath $baseManifestPath -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVSqlConfigurationAcceptance (
        [string]$removePlan.HighestChangeClass -eq 'live' -and @($removePlan.Diff.Kind) -contains 'trace-flag-remove'
    ) 'Read-only Plan erlaubt die eigentumsgebundene Runtime-Trace-Flag-Entfernung'
    $removeResult=Invoke-SqlServerLabReconcileAction -RunId $runId -RepairHyperVSqlConfiguration -ManifestPath $baseManifestPath -InstanceId primary -StateRoot $StateRoot -Confirm:$false
    $ownership=Get-Content -LiteralPath $ownershipPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 20
    Assert-HyperVSqlConfigurationAcceptance (
        [string]$removeResult.ExecutionSummary.Status -eq 'SUCCEEDED' -and 1117 -notin @(Get-AcceptanceTraceFlags) -and
        3604 -in @(Get-AcceptanceTraceFlags) -and @($ownership.TraceFlags).Count -eq 0 -and
        (Get-AcceptanceConfigurationValue 'cost threshold for parallelism') -eq '25:25'
    ) 'Removal entfernt nur das run-eigene Flag und bewahrt das fremde aktive Flag'
    $baseNoOp=Get-SqlServerLabReconcilePlan -RunId $runId -HyperVSqlConfiguration -ManifestPath $baseManifestPath -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVSqlConfigurationAcceptance $baseNoOp.IsNoOp 'Wiederholter Remove-Plan ist No-op'
    Invoke-AcceptanceNonQuery 'DBCC TRACEOFF (3604,-1) WITH NO_INFOMSGS;'

    $bootBefore=Get-AcceptanceGuestBootTime -Context $context -Credential $guestCredential
    $sqlStartBefore=[string](Invoke-AcceptanceScalar "SELECT CONVERT(varchar(33),sqlserver_start_time,126) FROM sys.dm_os_sys_info;")
    $restartPlan=Get-SqlServerLabReconcilePlan -RunId $runId -HyperVSqlConfiguration -ManifestPath $restartManifestPath -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVSqlConfigurationAcceptance (
        [string]$restartPlan.HighestChangeClass -eq 'restart' -and $restartPlan.Actions[0].RequiresServiceRestart -and -not $restartPlan.Actions[0].RequiresVmRestart
    ) 'Nicht dynamischer Zielwert plant ausschliesslich einen SQL-Dienstrestart'
    $restartResult=Invoke-SqlServerLabReconcileAction -RunId $runId -RepairHyperVSqlConfiguration -ManifestPath $restartManifestPath -InstanceId primary -StateRoot $StateRoot -Confirm:$false
    $bootAfter=Get-AcceptanceGuestBootTime -Context $context -Credential $guestCredential
    $sqlStartAfter=[string](Invoke-AcceptanceScalar "SELECT CONVERT(varchar(33),sqlserver_start_time,126) FROM sys.dm_os_sys_info;")
    $managedAfter=Invoke-Private {
        param($VmName,$RunId,$ScopeId)Get-HyperVManagedVM -VMName $VmName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId
    } @([string]$context.Instance.vmName,$runId,[string]$context.Run.scopeId)
    Assert-HyperVSqlConfigurationAcceptance (
        [string]$restartResult.ExecutionSummary.Status -eq 'SUCCEEDED' -and
        (Get-AcceptanceConfigurationValue 'fill factor (%)') -eq '80:80' -and
        $sqlStartAfter -ne $sqlStartBefore -and $bootAfter -eq $bootBefore -and
        [string]$managedAfter.VM.Id -eq [string]$context.Instance.vmId -and [string]$managedAfter.VM.State -eq 'Running'
    ) 'Restart aktiviert den statischen Wert, startet SQL neu und laesst dieselbe VM laufen'
    $restartNoOp=Get-SqlServerLabReconcilePlan -RunId $runId -HyperVSqlConfiguration -ManifestPath $restartManifestPath -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVSqlConfigurationAcceptance $restartNoOp.IsNoOp 'Wiederholter Restart-Plan ist No-op'

    $restoreResult=Invoke-SqlServerLabReconcileAction -RunId $runId -RepairHyperVSqlConfiguration -ManifestPath $baseManifestPath -InstanceId primary -StateRoot $StateRoot -Confirm:$false
    $finalPlan=Get-SqlServerLabReconcilePlan -RunId $runId -HyperVSqlConfiguration -ManifestPath $baseManifestPath -InstanceId primary -StateRoot $StateRoot
    $journal=Get-Content -LiteralPath $journalPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 30
    Assert-HyperVSqlConfigurationAcceptance (
        [string]$restoreResult.ExecutionSummary.Status -eq 'SUCCEEDED' -and
        (Get-AcceptanceConfigurationValue 'fill factor (%)') -eq '0:0' -and $finalPlan.IsNoOp -and [string]$journal.Status -eq 'COMPLETED'
    ) 'Basismanifest, Desired State und Abschlussjournal sind wieder konvergiert'

    $cleanup=Remove-SqlServerLab -RunId $runId -StateRoot $StateRoot -Force -Confirm:$false
    Assert-HyperVSqlConfigurationAcceptance ([string]$cleanup.Status -in @('REMOVED','COMPLETED')) 'Run wurde scopegebunden entfernt' ([string]$cleanup.Status)
    $lab=$null
    foreach($path in @($ownedPaths|Where-Object{$_})){
        Assert-HyperVSqlConfigurationAcceptance (-not(Test-Path -LiteralPath $path)) 'Run-eigene VHDX wurde entfernt'
    }
    $completed=$true
}
catch{
    if($lab -and $KeepOnFailure){
        Write-Host "RECOVERY_RUN_ID=$([string]$lab.RunId)"
        Write-Host "RECOVERY_MANIFEST_ROOT=$testRoot"
    }
    throw
}
finally{
    $script:saPassword=$null
    if($lab -and -not $KeepOnFailure){
        try{Remove-SqlServerLab -RunId ([string]$lab.RunId) -StateRoot $StateRoot -Force -Confirm:$false|Out-Null}
        catch{Write-Warning "Fehler-Cleanup des Hyper-V-SQL-Konfigurations-Runs schlug fehl: $($_.Exception.Message)"}
    }
    if(($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)){
        if(-not(Test-ScopedTemporaryRoot -Path $testRoot)){throw 'HYPERV_SQL_CONFIGURATION_ACCEPTANCE_TEMP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
    }
    if($previousStateRoot){$env:SQL_SERVER_LAB_STATE=$previousStateRoot}else{Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue}
    if($mutexAcquired){$mutex.ReleaseMutex()};$mutex.Dispose()
}

Write-Host 'Native Hyper-V-SQL-Konfigurations-Reconcile-Akzeptanz erfolgreich.' -ForegroundColor Green
