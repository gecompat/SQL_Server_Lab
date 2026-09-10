#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Gasttransport, Retry, Trust-Ruecknahme und gemeinsame Readiness-Anzeige ohne VM.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach($source in @('ConsoleUi','ActionProgress','JobProgress')){. (Join-Path $repoRoot "Private/$source.ps1")}
. (Join-Path $repoRoot 'Providers/HyperV/HyperVProvider.ps1')
$contexts=[Collections.Generic.List[object]]::new()
$calls=[Collections.Generic.List[object]]::new()
$trustWrites=[Collections.Generic.List[string]]::new()
$start=${function:Start-LabActionProgress}
function Start-LabActionProgress {param($Phase);$context=& $start -Phase $Phase -Now ([datetime]::UtcNow.AddSeconds(-6));$context.Enabled=$true;$contexts.Add($context);return $context}
function Write-Progress {param($Id,$Activity,$Status,$CurrentOperation,$PercentComplete,[switch]$Completed)}
function Write-LabInfo {param($Message)}
function Get-HyperVManagedVM {param($VMName,$ExpectedRunId,$ExpectedScopeId);if($mode -eq 'ownership'){throw 'SYNTHETIC_OWNERSHIP_MISMATCH'};return @{VM=@{State='Running'};Identity=@{guestTransport=$(if($mode -eq 'winrm'){'lab-winrm'}else{'psdirect'})}}}
function Wait-LabProgressDelay {param($Progress,$Milliseconds);$calls.Add(@{Kind='delay';Progress=$Progress;Milliseconds=$Milliseconds});if($mode -eq 'wait-timeout'){Start-Sleep -Milliseconds 100}}
function Initialize-HyperVLabWinRmClient {'synthetic-registry'}
function Get-ItemPropertyValue {param($LiteralPath,$Name);'synthetic-existing'}
function Set-ItemProperty {param($LiteralPath,$Name,$Value,$Type,[switch]$Force);$trustWrites.Add([string]$Value)}
function Invoke-Command {
    [CmdletBinding()]
    param($VMName,$ComputerName,$Credential,$Authentication,$ScriptBlock,$ArgumentList,[switch]$AsJob)
    $calls.Add(@{Kind='invoke';AsJob=[bool]$AsJob;Transport=$(if($ComputerName){'winrm'}else{'direct'})})
    if(-not $AsJob){throw 'SYNTHETIC_JOB_REQUIRED'}
    $count=@($calls | Where-Object Kind -eq invoke).Count
    if($mode -eq 'domain-error'){throw 'SYNTHETIC_DOMAIN_ERROR'}
    if(-not $ComputerName -and ($mode -eq 'fallback' -or ($mode -eq 'retry' -and $count -eq 1))){Write-Error -Message 'SYNTHETIC_TRANSPORT_OPEN_ERROR' -Category OpenError -ErrorAction Stop}
    return Start-Job { [pscustomobject]@{Value=17} }
}
function Assert-GuestProgress {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};Write-Host "PASS: $Name"}
$secure=[Security.SecureString]::new();foreach($character in 'SyntheticOnly_A7!'.ToCharArray()){$secure.AppendChar($character)}
$credential=[pscredential]::new('synthetic-user',$secure)
try {
    foreach($mode in @('success','retry','fallback','winrm','domain-error','ownership')) {
        $calls.Clear();$contexts.Clear();$trustWrites.Clear();$result=$null;$failure=''
        try{$result=Invoke-HyperVPowerShellDirect -VMName SyntheticVM -ExpectedRunId synthetic-run -ExpectedScopeId synthetic-scope -Credential $credential -FallbackAddress 127.0.0.1 -ScriptBlock {17}}catch{$failure=$_.Exception.Message}
        $invocations=@($calls | Where-Object Kind -eq invoke)
        $expectedCount=switch($mode){success{1} retry{2} fallback{11} winrm{1} domain-error{1} ownership{0}}
        Assert-GuestProgress ($invocations.Count -eq $expectedCount) "Begrenzte Transportaufrufe: $mode"
        if($mode -in @('domain-error','ownership')){Assert-GuestProgress ($failure -match 'SYNTHETIC_' -and @($invocations | Where-Object Transport -eq winrm).Count -eq 0) "Fach- oder Ownershipfehler verhindert Fallback: $mode"}
        else {Assert-GuestProgress ($result.Value -eq 17 -and -not $failure) "Job-Ergebnis erreicht den Aufrufer: $mode"}
        Assert-GuestProgress (@($contexts | Where-Object {-not $_.Completed}).Count -eq 0) "Gastreporter abgeschlossen: $mode"
        if($mode -in @('fallback','winrm')) {Assert-GuestProgress ($trustWrites.Count -eq 2 -and $trustWrites[-1] -eq 'synthetic-existing') "Temporaeres WinRM-Trust wird wiederhergestellt: $mode"}
    }
    $mode='wait-ready';$calls.Clear();$contexts.Clear();$script:probes=0
    function Invoke-HyperVPowerShellDirect {
        param($VMName,$ExpectedRunId,$ExpectedScopeId,$Credential,$FallbackAddress,$Progress,$TimeoutSeconds,$ScriptBlock)
        $script:probes++;$calls.Add(@{Kind='probe';Progress=$Progress;Timeout=$TimeoutSeconds})
        return @{computerName='SyntheticVM';imageState=$(if($mode -eq 'wait-ready' -and $script:probes -ge 2){'IMAGE_STATE_COMPLETE'}else{'SYNTHETIC_PENDING'})}
    }
    $result=Wait-HyperVPowerShellDirect -VMName SyntheticVM -ExpectedRunId synthetic-run -ExpectedScopeId synthetic-scope -Credential $credential -ExpectedComputerName SyntheticVM -TimeoutSeconds 3 -PollIntervalMilliseconds 100
    Assert-GuestProgress ($result.Ready -and $script:probes -eq 2 -and $contexts.Count -eq 1 -and $contexts[0].Completed) 'Mehrere Readiness-Probes teilen genau einen abgeschlossenen Reporter'
    Assert-GuestProgress (@($calls | Where-Object { -not [object]::ReferenceEquals($_.Progress,$contexts[0]) }).Count -eq 0) 'Readiness-Pause und Gastaufruf verwenden dieselbe Anzeige'
    $mode='wait-timeout';$calls.Clear();$contexts.Clear()
    $result=Wait-HyperVPowerShellDirect -VMName SyntheticVM -ExpectedRunId synthetic-run -ExpectedScopeId synthetic-scope -Credential $credential -TimeoutSeconds 1 -PollIntervalMilliseconds 100
    Assert-GuestProgress (-not $result.Ready -and $contexts[0].Completed -and @($calls | Where-Object {$_.Kind -eq 'probe' -and ($_.Timeout -lt 1 -or $_.Timeout -gt 1)}).Count -eq 0) 'Readiness-Deadline begrenzt die Gastaufrufe und beendet die Anzeige'
}
finally {$secure.Dispose()}
