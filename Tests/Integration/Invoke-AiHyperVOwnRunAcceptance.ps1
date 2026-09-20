#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft lokales RAG und Diagnose auf einer neuen eigenen Hyper-V-SQL-2025-VM.
.DESCRIPTION
    Verwendet ausschließlich ein explizites vorhandenes SQL_PREPARED_SEALED-
    Developer-Artifact und vorhandene Hostmodelle. Kein Bootstrap, Modellpull
    oder Hostdienstrestart. PreflightOnly liest ohne State-/Cache-Schreibzugriff.
    Der mutierende Lauf benötigt einen erhöhten Host und endet erst nach
    VM-/Child-VHDX-/IPAM-Cleanup sowie erneutem Parent-Integritätsnachweis.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^hyperv-sql-prepared-sealed-[a-f0-9]{64}$')][string]$ArtifactId,
    [string]$StateRoot,
    [ValidateRange(1024,65535)][int]$LocalPort=11434,
    [switch]$PreflightOnly
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/AiHyperVOwnRunAcceptance.ps1')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-ai-'+[guid]::NewGuid().ToString('N'))
$operation=[guid]::NewGuid().ToString('D')
$module=$null;$binding=$null;$arrangeStarted=$false;$complete=$false;$cleanupFailed=$false;$parent=$null
$guestPassword=$null;$saPassword=$null;$previousState=$env:SQL_SERVER_LAB_STATE
$locks=[Collections.Generic.List[object]]::new()
function Assert-HyperVAi {param([bool]$Condition,[string]$Name)if(-not $Condition){throw "AI_HYPERV_ACCEPTANCE_FAILED: $Name"};Write-Host "PASS: $Name"}
function Get-HyperVAiLoginCount {
    param($Binding,[SecureString]$Password)
    & $module {
        param($Binding,$Password)
        $rows=@(Invoke-LabAiSqlCommand -HostName $Binding.Instance.host -Port $Binding.Instance.port -Credential ([PSCredential]::new('sa',$Password)) -Sql "SELECT COUNT(*) AS LoginCount FROM sys.server_principals WHERE name LIKE 'sql_lab_ai_%';")
        if($rows.Count -ne 1){throw 'AI_HYPERV_LOGIN_PROBE_INVALID'}
        [int]$rows[0].LoginCount
    } $Binding $Password
}
try{
    foreach($name in @('Global\SQL_Server_Lab_Runtime_Smoke','Global\SQL_Server_Lab_HyperV_AI_OwnRun_Acceptance')){
        $mutex=[Threading.Mutex]::new($false,$name);$acquired=$false
        try{try{$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10))}catch [Threading.AbandonedMutexException]{$acquired=$true};if(-not $acquired){throw 'AI_HYPERV_HOST_LOCK_TIMEOUT'};$locks.Add($mutex)}catch{$mutex.Dispose();throw}
    }
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    if(-not $StateRoot){$StateRoot=& $module {Get-LabStateRoot}}
    $parent=Get-OwnHyperVAiPreflight -Module $module -ArtifactId $ArtifactId -StateRoot $StateRoot -LocalPort $LocalPort
    if($PreflightOnly){
        [pscustomobject]@{Contract='SqlServerLab.AiHyperVOwnRunPreflight/1.0';Status='READY';Provider='hyperv';ArtifactId=$ArtifactId;Models=@($parent.Models.ModelKey);MutationPerformed=$false}
        return
    }
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-HyperVAi ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Runner arbeitet erhöht'
    $null=Get-VMHost -ErrorAction Stop
    $env:SQL_SERVER_LAB_STATE=$StateRoot
    $null=New-Item -ItemType Directory -Path $testRoot
    $manifest=[ordered]@{
        name=('hv-ai-'+$operation.Substring(0,8));automation=@{mode='unattended'}
        instances=@(@{id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off';network=@{intent='hostOnly';exposure='host'}
            windowsActivation=@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='EvaluationOnline';EgressPolicy='AllowTemporary'}
            hyperv=@{preparedImageId=$ArtifactId;memoryStartupMB=6144;processorCount=4;sqlPort=1433;guestPasswordMode='prompt'}
            serverConfig=@{memory=@{minMB=512;maxMB=4096};maxDop=4}
        })
    }
    $manifestPath=Join-Path $testRoot 'manifest.json';$manifest|ConvertTo-Json -Depth 25|Set-Content -LiteralPath $manifestPath -Encoding utf8
    Assert-HyperVAi ((Test-SqlServerLabManifest -Path $manifestPath).IsValid) 'Eigenes Prepared-Manifest vor Mutation gültig'
    $guestPassword=& $module {New-HyperVSqlUnattendedPassword};$saPassword=& $module {New-HyperVSqlUnattendedPassword}
    $arrangeStarted=$true
    $lab=& $module {
        param($Operation,$Manifest,$State,$Guest,$Sa)
        Invoke-WithLabWorkflowOperationContext -OperationId $Operation -ScriptBlock {
            param($Manifest,$State,$Guest,$Sa)
            New-SqlServerLab -Manifest $Manifest -GuestPassword $Guest -SqlSaPassword $Sa -NonInteractive -StateRoot $State -Region AT -SystemLocale de-AT -UiLanguage en-US -InputLocale '0407:00000407' -TimeZone 'W. Europe Standard Time'
        } -ArgumentList @($Manifest,$State,$Guest,$Sa)
    } $operation $manifestPath $StateRoot $guestPassword $saPassword
    Assert-HyperVAi ($lab.State -eq 'RUNNING') 'Eigener SQL-Prepared-Run läuft'
    $boundArgs=@{Module=$module;RunId=[string]$lab.RunId;StateRoot=$StateRoot;OperationId=$operation;ArtifactId=$ArtifactId}
    $binding=Get-OwnHyperVAiBinding @boundArgs -RequireReady
    $boundArgs.ExpectedVmId=$binding.VmId
    $bootBefore=Get-OwnHyperVAiBootTime -VmId $binding.VmId -Credential ([PSCredential]::new('Administrator',$guestPassword))
    Assert-HyperVAi ((Get-HyperVAiLoginCount -Binding $binding -Password $saPassword) -eq 0) 'Keine Diagnose-Logins vor Beginn'
    $documents=@(@{Id='backup-policy';Content='SQL Server Lab überprüft synthetische Sicherungen täglich.'},@{Id='network-policy';Content='Das synthetische Labnetz verwendet ausschließlich isolierte Testadressen.'},@{Id='cleanup-policy';Content='Run-eigene Testressourcen werden nach der Abnahme vollständig entfernt.'})
    $rag=@{RunId=$binding.RunId;SaPassword=$saPassword;Document=$documents;Question='Wie oft werden synthetische Sicherungen überprüft?';TopK=2;EmbeddingModelKey='ollama-embeddinggemma-latest';GenerationModelKey='ollama-qwen25-coder-7b-local';GenerationTimeoutSeconds=230;GenerationRetryCount=0;LocalPort=$LocalPort;StateRoot=$StateRoot}
    $agent=@{RunId=$binding.RunId;SaPassword=$saPassword;Question='Fasse den SQL-Testserverzustand anhand der bereitgestellten Metriken knapp zusammen.';ToolId=@('server-summary','wait-statistics');GenerationModelKey='ollama-qwen25-coder-7b-local';LocalPort=$LocalPort;StateRoot=$StateRoot}
    $null=Invoke-SqlServerLabAiRag @rag -WhatIf;$null=Invoke-SqlServerLabAiDiagnosticAgent @agent -WhatIf
    Assert-HyperVAi ((Get-HyperVAiLoginCount -Binding $binding -Password $saPassword) -eq 0) 'WhatIf legt keine Diagnose-Logins an'
    foreach($phase in @('before','after')){
        $binding=Get-OwnHyperVAiBinding @boundArgs -RequireReady
        $r=Invoke-SqlServerLabAiRag @rag -Confirm:$false
        Assert-HyperVAi ($r.Status -eq 'SUCCEEDED' -and $r.Citations.Count -eq 2 -and $r.Citations[0] -ceq 'backup-policy' -and -not [string]::IsNullOrWhiteSpace($r.Answer)) "Exaktes SQL-RAG und lokale Generation $phase"
        $a=Invoke-SqlServerLabAiDiagnosticAgent @agent -Confirm:$false
        Assert-HyperVAi ($a.Status -eq 'SUCCEEDED' -and $a.ToolExecutions.Count -eq 2 -and $a.Metrics.RequestCount -eq 1 -and -not [string]::IsNullOrWhiteSpace($a.Answer)) "Read-only Diagnose und lokale Generation $phase"
        Assert-HyperVAi ((Get-HyperVAiLoginCount -Binding $binding -Password $saPassword) -eq 0) "Diagnose-Logins vollständig entfernt $phase"
        if($phase -eq 'before'){
            $binding=Get-OwnHyperVAiBinding @boundArgs -RequireReady
            $restart=Restart-SqlServerLab -RunId $binding.RunId -TimeoutSeconds 300 -Force -Confirm:$false
            Assert-HyperVAi ($restart.Action -notin @('CANCELLED','SKIPPED')) 'Eigener VMrestart ausgeführt'
            $binding=Get-OwnHyperVAiBinding @boundArgs -RequireReady
            $bootAfter=Get-OwnHyperVAiBootTime -VmId $binding.VmId -Credential ([PSCredential]::new('Administrator',$guestPassword))
            Assert-HyperVAi ([datetimeoffset]$bootAfter -gt [datetimeoffset]$bootBefore) 'Gebundene VM wurde tatsächlich neugestartet'
        }
    }
    $complete=$true
}finally{
    if($module -and $arrangeStarted){
        try{
            $owned=& $module {param($Op,$State)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $State} $operation $StateRoot
            if($owned){
                $arguments=@{Module=$module;RunId=[string]$owned.runId;StateRoot=$StateRoot;OperationId=$operation;ArtifactId=$ArtifactId}
                if($binding){$arguments.ExpectedVmId=$binding.VmId}
                $binding=Get-OwnHyperVAiBinding @arguments
                $removed=Remove-SqlServerLab -RunId $binding.RunId -StateRoot $StateRoot -Force -Confirm:$false
                if($removed.Status -notin @('REMOVED','COMPLETED')){throw 'AI_HYPERV_CLEANUP_INCOMPLETE'}
            }
            if(-not $binding){throw 'AI_HYPERV_CLEANUP_UNVERIFIABLE'}
            Assert-OwnHyperVAiNoResidue -Module $module -Binding $binding -StateRoot $StateRoot
        }catch{$cleanupFailed=$true;Write-Warning 'AI_HYPERV_OWN_CLEANUP_RECOVERY_REQUIRED'}
        try{
            $after=Get-OwnHyperVAiPreflight -Module $module -ArtifactId $ArtifactId -StateRoot $StateRoot -LocalPort $LocalPort
            if($after.ParentHash -cne $parent.ParentHash -or $after.ParentWriteTicks -ne $parent.ParentWriteTicks -or $after.ParentLength -ne $parent.ParentLength){throw 'parent drift'}
            $sameModels=& $module {param($Before,$After)(Get-LabAiPlanKey -InputObject $Before) -ceq (Get-LabAiPlanKey -InputObject $After)} $parent.Models $after.Models
            if(-not $sameModels){throw 'model drift'}
        }catch{$cleanupFailed=$true;Write-Warning 'AI_HYPERV_PARENT_OR_MODEL_REVALIDATION_FAILED'}
    }
    if($guestPassword){$guestPassword.Dispose()};if($saPassword){$saPassword.Dispose()}
    $env:SQL_SERVER_LAB_STATE=$previousState
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
    for($i=$locks.Count-1;$i -ge 0;$i--){$locks[$i].ReleaseMutex();$locks[$i].Dispose()}
    if(-not $cleanupFailed -and (Test-Path -LiteralPath $testRoot)){
        $resolved=[IO.Path]::GetFullPath($testRoot);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^sql-lab-hv-ai-[a-f0-9]{32}$'){throw 'AI_HYPERV_TEMP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
if($cleanupFailed -or -not $complete){throw 'AI_HYPERV_ACCEPTANCE_INCOMPLETE'}
[pscustomobject]@{Contract='SqlServerLab.AiHyperVOwnRunAcceptance/1.0';Status='PASSED';Provider='hyperv';Rag='PASSED';Agent='PASSED';VmRestart='PASSED';LoginCleanup='PASSED';RunCleanup='PASSED';ParentImmutable='PASSED';GenerationLane='local';GenerationRequests=4}
