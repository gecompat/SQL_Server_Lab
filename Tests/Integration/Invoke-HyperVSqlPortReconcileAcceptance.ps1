#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt den nativen Hyper-V-SQL-Port-Reconcile gegen SQL Server 2025 aus.
.DESCRIPTION
    Erstellt aus einem verifizierten SQL_PREPARED_SEALED-Artifact einen neuen,
    scopegebundenen Manifest-Run. Der Runner erzeugt in genau diesem Gast eine
    kontrollierte TCP-/Firewall-Drift und prueft Plan, WhatIf, ausschliesslichen
    MSSQLSERVER-Restart, Connection-State, No-op und vollstaendigen Cleanup.
.PARAMETER ArtifactId
    Optionales SQL_PREPARED_SEALED-Artifact. Ohne Angabe wird das neueste
    verifizierte SQL-2025-Artifact im State Root verwendet.
.PARAMETER StateRoot
    Optionaler State Root. Der Runner erzeugt darin genau einen neuen Run.
.PARAMETER KeepOnFailure
    Belaesst einen fehlgeschlagenen Run samt Journal fuer den Recovery-Pfad.
#>
[CmdletBinding()]
param([string]$ArtifactId,[string]$StateRoot,[switch]$KeepOnFailure)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-sql-port-'+[Guid]::NewGuid().ToString('N'))
$manifestPath=Join-Path $testRoot 'port.json'
$previousStateRoot=$env:SQL_SERVER_LAB_STATE
$module=$null;$lab=$null;$ownedPaths=@();$completed=$false
$desiredPort=14333;$driftPort=15433
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_HyperV_SQL_Port_Acceptance');$mutexAcquired=$false

function Assert-HyperVSqlPortAcceptance {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Description,[string]$Evidence)
    if(-not $Condition){throw "HYPERV_SQL_PORT_ACCEPTANCE_FAILED: $Description$(if($Evidence){": $Evidence"})"}
    Write-Host "PASS: $Description" -ForegroundColor Green
}
function Invoke-Private {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock,[object[]]$Arguments=@())
    & $module $ScriptBlock @Arguments
}
function New-AcceptanceSqlConnection {
    param([Parameter(Mandatory)][int]$Port)
    $connection=[Data.SqlClient.SqlConnection]::new()
    $connection.ConnectionString="Server=$script:sqlAddress,$Port;Database=master;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;"
    $connection.Credential=[Data.SqlClient.SqlCredential]::new('sa',$script:saPassword)
    $connection
}
function Get-AcceptanceSqlStartTime {
    param([Parameter(Mandatory)][int]$Port)
    $connection=New-AcceptanceSqlConnection -Port $Port
    try{$connection.Open();$command=$connection.CreateCommand();$command.CommandText="SELECT CONVERT(varchar(33),sqlserver_start_time,126) FROM sys.dm_os_sys_info;";[string]$command.ExecuteScalar()}
    finally{$connection.Dispose()}
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
function Set-AcceptanceGuestPortDrift {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][PSCredential]$Credential,[Parameter(Mandatory)][int]$Port)
    Invoke-Private {
        param($VmName,$RunId,$ScopeId,$Credential,$Port)
        $result=Invoke-HyperVPowerShellDirect -VMName $VmName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId -Credential $Credential `
            -ArgumentList @($Port,'SQL_Server_Lab SQL TCP Host') -ScriptBlock {
            param($Port,$FirewallRuleName)
            $ErrorActionPreference='Stop'
            $instanceRoot='HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
            $map=Get-ItemProperty -LiteralPath $instanceRoot -ErrorAction Stop
            $instances=@($map.PSObject.Properties|Where-Object{$_.Name -notmatch '^PS'})
            $defaults=@($instances|Where-Object{[string]$_.Name -eq 'MSSQLSERVER'})
            if($instances.Count -ne 1 -or $defaults.Count -ne 1){throw 'HYPERV_SQL_PORT_ACCEPTANCE_DEFAULT_INSTANCE_NOT_UNIQUE'}
            $tcpRoot="HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$([string]$defaults[0].Value)\MSSQLServer\SuperSocketNetLib\Tcp"
            $ipAll=Join-Path $tcpRoot 'IPAll'
            $rules=@(Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction Stop)
            if($rules.Count -ne 1){throw 'HYPERV_SQL_PORT_ACCEPTANCE_FIREWALL_RULE_NOT_UNIQUE'}
            Set-ItemProperty -LiteralPath $tcpRoot -Name Enabled -Value 1 -Type DWord
            Set-ItemProperty -LiteralPath $ipAll -Name TcpDynamicPorts -Value ''
            Set-ItemProperty -LiteralPath $ipAll -Name TcpPort -Value ([string][int]$Port)
            $filters=@($rules[0]|Get-NetFirewallPortFilter -ErrorAction Stop)
            if($filters.Count -ne 1){throw 'HYPERV_SQL_PORT_ACCEPTANCE_FIREWALL_FILTER_NOT_UNIQUE'}
            $filters[0]|Set-NetFirewallPortFilter -Protocol TCP -LocalPort $Port -ErrorAction Stop|Out-Null
            Restart-Service -Name MSSQLSERVER -ErrorAction Stop
            (Get-Service -Name MSSQLSERVER).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(120))
            [PSCustomObject]@{Status='DRIFTED';Port=[int]$Port}
        }
        @($result)[-1]
    } @([string]$Context.Instance.vmName,[string]$Context.Run.runId,[string]$Context.Run.scopeId,$Credential,$Port)
}
function Test-ScopedTemporaryRoot {
    param([Parameter(Mandatory)][string]$Path)
    $resolved=[IO.Path]::GetFullPath($Path).TrimEnd('\');$expected=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    [IO.Directory]::GetParent($resolved).FullName.TrimEnd('\').Equals($expected,[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^sql-lab-hv-sql-port-[a-f0-9]{32}$'
}

try{
    $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(15));if(-not $mutexAcquired){throw 'HYPERV_SQL_PORT_ACCEPTANCE_HOST_LOCK_TIMEOUT'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-HyperVSqlPortAcceptance ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Runner arbeitet erhoeht'
    Get-Command Get-VM -ErrorAction Stop|Out-Null
    $null=New-Item -Path $testRoot -ItemType Directory -Force
    $module=Import-Module $modulePath -Force -PassThru
    if(-not $StateRoot){$StateRoot=Invoke-Private {Get-LabStateRoot}};$env:SQL_SERVER_LAB_STATE=$StateRoot
    if(-not $ArtifactId){
        $artifact=Invoke-Private {param($Root)@(Get-HyperVImageArtifact -StateRoot $Root -SkipIntegrityCheck|Where-Object{[string]$_.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$_.sql.version -eq '2025' -and [string]$_.licenseType -ne 'test-only'}|Sort-Object{[datetime]$_.registeredAt} -Descending|Select-Object -First 1)[0]} @($StateRoot)
        if(-not $artifact){throw 'HYPERV_SQL_PORT_ACCEPTANCE_SQL_PREPARED_ARTIFACT_NOT_FOUND'};$ArtifactId=[string]$artifact.artifactId
    }
    $artifact=Invoke-Private {param($Id,$Root)Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root} @($ArtifactId,$StateRoot)
    Assert-HyperVSqlPortAcceptance ([string]$artifact.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$artifact.sql.version -eq '2025') 'Verifiziertes SQL-2025-Prepared-Artifact ist verfuegbar' $ArtifactId
    $manifest=[ordered]@{
        '$schema'=(Join-Path $repoRoot 'Schemas/lab-manifest.schema.json');name=('hv-sql-port-'+[Guid]::NewGuid().ToString('N').Substring(0,8));automation=[ordered]@{mode='unattended'}
        instances=@([ordered]@{id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off';network=[ordered]@{intent='hostOnly';exposure='host'};hyperv=[ordered]@{preparedImageId=$ArtifactId;memoryStartupMB=6144;processorCount=4;sqlPort=$desiredPort;guestPasswordMode='prompt'}})
    }
    $manifest|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $manifestPath -Encoding utf8
    $validation=Test-SqlServerLabManifest -Path $manifestPath
    Assert-HyperVSqlPortAcceptance $validation.IsValid 'SQL-Port-Manifest ist vor Mutation gueltig'
    $guestPassword=Invoke-Private {New-HyperVSqlUnattendedPassword};$script:saPassword=Invoke-Private {New-HyperVSqlUnattendedPassword}
    $guestCredential=[PSCredential]::new('Administrator',$guestPassword)
    $lab=New-SqlServerLab -Manifest $manifestPath -GuestPassword $guestPassword -SqlSaPassword $script:saPassword -NonInteractive -StateRoot $StateRoot -Region AT -SystemLocale de-AT -UiLanguage en-US -InputLocale '0407:00000407' -TimeZone 'W. Europe Standard Time'
    Assert-HyperVSqlPortAcceptance ([string]$lab.State -eq 'RUNNING') 'Isolierter SQL-Prepared-Manifest-Run ist bereit'
    $runId=[string]$lab.RunId;$context=Invoke-Private {param($Id,$Root)Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root} @($runId,$StateRoot)
    $identity=Invoke-Private {param($Vm,$Run,$Scope)(Get-HyperVManagedVM -VMName $Vm -ExpectedRunId $Run -ExpectedScopeId $Scope).Identity} @([string]$context.Instance.vmName,$runId,[string]$context.Run.scopeId)
    $ownedPaths=@([string]$identity.childVhdxPath)+@($identity.additionalDrives|ForEach-Object{[string]$_.path})
    $script:sqlAddress=[string]$context.Instance.host
    Assert-HyperVSqlPortAcceptance ((Get-AcceptanceSqlStartTime -Port $desiredPort).Length -gt 0 -and [int]$context.Instance.port -eq $desiredPort) 'Initialer SQL-Port und Connection-State sind aktiv'
    $bootBefore=Get-AcceptanceGuestBootTime -Context $context -Credential $guestCredential
    $drift=Set-AcceptanceGuestPortDrift -Context $context -Credential $guestCredential -Port $driftPort
    $driftSqlStart=Get-AcceptanceSqlStartTime -Port $driftPort
    Assert-HyperVSqlPortAcceptance ([string]$drift.Status -eq 'DRIFTED' -and $driftSqlStart.Length -gt 0) 'Isolierte Testdrift ist am alternativen Port erreichbar'
    $plan=Get-SqlServerLabReconcilePlan -RunId $runId -HyperVSqlPort -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVSqlPortAcceptance ([string]$plan.HighestChangeClass -eq 'restart' -and @($plan.Diff.Kind) -contains 'tcp-binding' -and @($plan.Diff.Kind) -contains 'firewall-binding' -and $plan.Actions[0].RequiresServiceRestart -and -not $plan.Actions[0].RequiresVmRestart) 'Read-only Plan erkennt TCP- und Firewall-Drift als SQL-Restart'
    $journalPath=Join-Path $context.RunDirectory 'hyperv-sql-port-reconcile.local.journal.json'
    $whatIf=Invoke-SqlServerLabReconcileAction -RunId $runId -RepairHyperVSqlPort -InstanceId primary -StateRoot $StateRoot -WhatIf
    Assert-HyperVSqlPortAcceptance ([string]$whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and -not(Test-Path -LiteralPath $journalPath) -and (Get-AcceptanceSqlStartTime -Port $driftPort).Length -gt 0) 'WhatIf schreibt weder Journal noch Portbindung'
    $result=Invoke-SqlServerLabReconcileAction -RunId $runId -RepairHyperVSqlPort -InstanceId primary -StateRoot $StateRoot -Confirm:$false
    $bootAfter=Get-AcceptanceGuestBootTime -Context $context -Credential $guestCredential;$sqlStartAfter=Get-AcceptanceSqlStartTime -Port $desiredPort
    $updated=Invoke-Private {param($Id,$Root)Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root} @($runId,$StateRoot)
    $journal=Get-Content -LiteralPath $journalPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 30
    Assert-HyperVSqlPortAcceptance ([string]$result.ExecutionSummary.Status -eq 'SUCCEEDED' -and $sqlStartAfter -ne $driftSqlStart -and $bootAfter -eq $bootBefore -and [int]$updated.Instance.port -eq $desiredPort -and [string]$journal.Status -eq 'COMPLETED') 'Reconcile stellt Port und Connection-State mit SQL-, aber ohne VM-Neustart wieder her'
    $noOp=Get-SqlServerLabReconcilePlan -RunId $runId -HyperVSqlPort -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVSqlPortAcceptance $noOp.IsNoOp 'Wiederholter SQL-Port-Plan ist No-op'
    $cleanup=Remove-SqlServerLab -RunId $runId -StateRoot $StateRoot -Force -Confirm:$false
    Assert-HyperVSqlPortAcceptance ([string]$cleanup.Status -in @('REMOVED','COMPLETED')) 'Run wurde scopegebunden entfernt' ([string]$cleanup.Status)
    $lab=$null;foreach($path in @($ownedPaths|Where-Object{$_})){Assert-HyperVSqlPortAcceptance (-not(Test-Path -LiteralPath $path)) 'Run-eigene VHDX wurde entfernt'};$completed=$true
}
catch{if($lab -and $KeepOnFailure){Write-Host "RECOVERY_RUN_ID=$([string]$lab.RunId)";Write-Host "RECOVERY_MANIFEST_ROOT=$testRoot"};throw}
finally{
    $script:saPassword=$null
    if($lab -and -not $KeepOnFailure){try{Remove-SqlServerLab -RunId ([string]$lab.RunId) -StateRoot $StateRoot -Force -Confirm:$false|Out-Null}catch{Write-Warning "Fehler-Cleanup des Hyper-V-SQL-Port-Runs schlug fehl: $($_.Exception.Message)"}}
    if(($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)){if(-not(Test-ScopedTemporaryRoot $testRoot)){throw 'HYPERV_SQL_PORT_ACCEPTANCE_TEMP_SCOPE_INVALID'};Remove-Item -LiteralPath $testRoot -Recurse -Force}
    if($previousStateRoot){$env:SQL_SERVER_LAB_STATE=$previousStateRoot}else{Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue}
    if($mutexAcquired){$mutex.ReleaseMutex()};$mutex.Dispose()
}
Write-Host 'Native Hyper-V-SQL-Port-Reconcile-Akzeptanz erfolgreich.' -ForegroundColor Green
