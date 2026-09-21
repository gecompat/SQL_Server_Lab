#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft SQL-Gast-Capture auf genau einem eigenen Developer-Prepared-Run.
.DESCRIPTION
    Verwendet ausschließlich ein bereits vorhandenes SQL_PREPARED_SEALED-
    Artifact. Baut kein Image und installiert kein neues Windows. Die Abnahme
    benötigt einen erhöhten Hyper-V-Runner. Positive Evaluation und echte
    Ablaufdatum-Ermittlung bleiben ausdrücklich unbelegt.
.PARAMETER ArtifactId
    Explizites vorhandenes SQL-2025-Developer-Prepared-Artifact.
.PARAMETER StateRoot
    State-Root mit diesem registrierten Artifact. Nur der neue eigene Run wird verändert.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^hyperv-sql-prepared-sealed-[a-f0-9]{64}$')][string]$ArtifactId,[string]$StateRoot)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$operation=[guid]::NewGuid().ToString();$module=$null;$run=$null;$owned=$null;$guest=$null;$sa=$null;$mutex=$null;$acquired=$false;$passed=$false;$cleanupFailed=$false
$testRoot=Join-Path $repoRoot ('.artifacts/test-runs/sql-guest-capture-'+[guid]::NewGuid().ToString('N'))
$vmIds=@();$ownedPaths=@()
function Assert-CaptureAcceptance {param([bool]$Condition,[string]$Name)if(-not $Condition){throw "SQL_GUEST_CAPTURE_ACCEPTANCE_FAILED: $Name"};Write-Host "PASS: $Name"}
try {
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'SQL_GUEST_CAPTURE_ACCEPTANCE_ELEVATED_RUNNER_REQUIRED'}
    $mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke');$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10));if(-not $acquired){throw 'SQL_GUEST_CAPTURE_ACCEPTANCE_LOCK_TIMEOUT'}
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    if(-not $StateRoot){$StateRoot=& $module {Get-LabStateRoot}}
    $artifact=& $module {param($Id,$Root)Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root} $ArtifactId $StateRoot
    Assert-CaptureAcceptance ($artifact -and $artifact.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$artifact.sql.version -eq '2025' -and [string]$artifact.sql.edition -match 'Developer' -and $artifact.integrityVerification.status -in @('VERIFIED_HASH','VERIFIED_CACHE')) 'Vorhandenes Developer-Prepared-Artifact verifiziert'
    $parentHash=[string]$artifact.sha256
    $null=New-Item -ItemType Directory -Path $testRoot
    $manifestPath=Join-Path $testRoot 'manifest.json'
    $manifest=[ordered]@{
        name=('sql-capture-'+$operation.Substring(0,8));automation=@{mode='unattended'}
        instances=@(@{id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off';network=@{intent='hostOnly';exposure='host'}
            windowsActivation=@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='EvaluationOnline';EgressPolicy='AllowTemporary'}
            hyperv=@{preparedImageId=$ArtifactId;memoryStartupMB=6144;processorCount=4;sqlPort=1433;guestPasswordMode='prompt'}})
    }
    $manifest|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $manifestPath -Encoding utf8
    Assert-CaptureAcceptance (Test-SqlServerLabManifest -Path $manifestPath).IsValid 'Manifest vor Arrange gültig'
    $guest=& $module {New-HyperVSqlUnattendedPassword};$sa=& $module {New-HyperVSqlUnattendedPassword}
    $run=& $module {
        param($Manifest,$Guest,$Sql,$Root,$Operation)
        Invoke-WithLabWorkflowOperationContext -OperationId $Operation -ScriptBlock {
            param($Manifest,$Guest,$Sql,$Root)
            New-SqlServerLab -Manifest $Manifest -GuestPassword $Guest -SqlSaPassword $Sql -StateRoot $Root -NonInteractive
        } -ArgumentList @($Manifest,$Guest,$Sql,$Root)
    } $manifestPath $guest $sa $StateRoot $operation
    Assert-CaptureAcceptance ($run.State -eq 'RUNNING') 'Eigener SQL-2025-Developer-Run läuft'
    $context=& $module {param($Id,$Root)Get-LabSqlGuestCaptureContext -RunId $Id -StateRoot $Root} $run.RunId $StateRoot
    $statePath=Join-Path $context.RunDirectory 'run-state.json';$connectionPath=Join-Path $context.RunDirectory 'connection-info.json'
    $beforeState=(Get-FileHash -LiteralPath $statePath).Hash;$beforeConnection=(Get-FileHash -LiteralPath $connectionPath).Hash
    Update-SqlServerLabSqlGuestEvaluationEvidence -RunId $run.RunId -StateRoot $StateRoot -WhatIf
    Assert-CaptureAcceptance (-not(Test-Path -LiteralPath $context.ReceiptPath) -and -not(Test-Path -LiteralPath $context.LockPath)) 'WhatIf erzeugt weder Receipt noch Lock'
    $first=Update-SqlServerLabSqlGuestEvaluationEvidence -RunId $run.RunId -StateRoot $StateRoot -Confirm:$false
    Assert-CaptureAcceptance ($first.Status -eq 'UPDATED' -and $first.LicenseClassification -eq 'NOT_EVALUATION' -and $null -eq $first.EvaluationExpiresAt) 'Echte Developer-Capture ohne erfundene Frist'
    $watch=Get-SqlServerLabEvaluationWatch -StateRoot $StateRoot
    $items=@($watch.InstanceItems|Where-Object {$_.RunId -eq $run.RunId -and $_.Component -eq 'SqlServer'})
    Assert-CaptureAcceptance ($items.Count -eq 1 -and $items[0].Status -eq 'NOT_APPLICABLE') 'Read-only Watch projiziert NOT_APPLICABLE'
    $second=Update-SqlServerLabSqlGuestEvaluationEvidence -RunId $run.RunId -StateRoot $StateRoot -Confirm:$false
    Assert-CaptureAcceptance ($second.EvidenceId -ne $first.EvidenceId -and $second.PreviousEvidenceId -eq $first.EvidenceId) 'Zweite Beobachtung bildet Evidence-Kette'
    Assert-CaptureAcceptance ($beforeState -eq (Get-FileHash -LiteralPath $statePath).Hash -and $beforeConnection -eq (Get-FileHash -LiteralPath $connectionPath).Hash) 'Capture und Watch bewahren Run-/Connection-State bytegleich'
    $afterArtifact=& $module {param($Id,$Root)Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root} $ArtifactId $StateRoot
    Assert-CaptureAcceptance ($afterArtifact.sha256 -eq $parentHash) 'Prepared-Parent bleibt unverändert'
    $passed=$true
}
finally {
    if($module){
        try {
            # Operation-Bindung überlebt auch eine verlorene New-Rückgabe.
            $owned=& $module {param($Op,$Root)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $Root} $operation $StateRoot
            if($owned){
                if($run -and [string]$run.RunId -ne [string]$owned.runId){throw 'SQL_GUEST_CAPTURE_ACCEPTANCE_OWNERSHIP_CHANGED'}
                $resources=& $module {
                    param($Run)
                    $vms=@(Get-HyperVLabVMs -RunId ([string]$Run.runId) -ScopeId ([string]$Run.scopeId))
                    foreach($vm in $vms){$managed=Get-HyperVManagedVM -VMName ([string]$vm.VMName) -ExpectedRunId ([string]$Run.runId) -ExpectedScopeId ([string]$Run.scopeId);[pscustomobject]@{Id=[string]$managed.VM.Id;Paths=@([string]$managed.Identity.childVhdxPath)+@($managed.Identity.additionalVhdxPaths)}}
                } $owned
                $vmIds=@($resources|ForEach-Object {$_.Id});$ownedPaths=@($resources|ForEach-Object {$_.Paths})
                $removed=Remove-SqlServerLab -RunId ([string]$owned.runId) -StateRoot $StateRoot -Force -Confirm:$false
                Assert-CaptureAcceptance ($removed.Status -eq 'REMOVED' -and $removed.Cleanup -eq 'CLEANUP_SUCCEEDED') 'Eigener Run vollständig bereinigt'
                $remaining=& $module {param($Id,$Scope)@(Get-HyperVLabVMs -RunId $Id -ScopeId $Scope).Count} ([string]$owned.runId) ([string]$owned.scopeId)
                Assert-CaptureAcceptance ($remaining -eq 0 -and @($vmIds|Where-Object {Get-VM -Id ([guid]$_) -ErrorAction SilentlyContinue}).Count -eq 0 -and @($ownedPaths|Where-Object {$_ -and (Test-Path -LiteralPath $_)}).Count -eq 0) 'Keine eigenen VM- oder Diskreste'
            }
        }
        catch {$cleanupFailed=$true;Write-Host 'RECOVERY_REQUIRED: Eigener Acceptance-Run benötigt scopegebundene Prüfung.'}
    }
    if($guest){$guest.Dispose()};if($sa){$sa.Dispose()};if($acquired){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
}
if(-not $passed -or $cleanupFailed){throw 'SQL_GUEST_CAPTURE_ACCEPTANCE_FAILED'}
Write-Host 'SQL GUEST EVALUATION CAPTURE ACCEPTANCE: PASS'
