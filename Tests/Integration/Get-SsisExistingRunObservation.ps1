#Requires -Version 7.2
<#
.SYNOPSIS
    Liest vorhandene Gast-Ereignisse eines gebundenen eigenen SSIS-Diagnoseruns.
.DESCRIPTION
    Keine Fixture-, Installations-, Logging- oder Konfigurationsmutation.
    Rohdaten bleiben ausschließlich im lokalen State Root außerhalb des Checkout.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$RunId,[Parameter(Mandatory)][string]$StateRoot)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
& $module {param($Root,$Repo) Assert-LabSsisEvidenceLocation -StateRoot $Root -RepositoryRoot $Repo} $StateRoot $repoRoot
$diagnostics=Join-Path $StateRoot 'diagnostics'
$null=New-Item -ItemType Directory -Path $diagnostics -Force
$privateLog=Join-Path $diagnostics ('ssis-observation-'+$RunId.ToString()+'.private.json')
try {
    $observation=@(& $module {
        param($Id,$Root)
        $context=Get-LabSsisPrerequisiteContext -RunId $Id -InstanceId primary -StateRoot $Root
        $guest=$null
        try {
            $guest=Get-LabSecret -Path $context.Directory -Name 'guest-administrator-password'
            if(-not $guest){throw 'SSIS_OBSERVATION_GUEST_CREDENTIAL_REQUIRED'}
            Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $Id.ToString() `
                -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) `
                -Credential ([PSCredential]::new('Administrator',$guest)) -TimeoutSeconds 120 -ScriptBlock {
                $start=(Get-Date).AddHours(-2)
                foreach($log in @('Application','System','Microsoft-Windows-CAPI2/Operational','Microsoft-Windows-User Profile Service/Operational')){
                    $info=Get-WinEvent -ListLog $log -ErrorAction SilentlyContinue
                    [pscustomobject]@{Kind='LOG_STATE';Log=$log;Enabled=[bool]$info.IsEnabled}
                    if($info.IsEnabled){
                        $events=@(Get-WinEvent -FilterHashtable @{LogName=$log;StartTime=$start} -MaxEvents 200 -ErrorAction SilentlyContinue)
                        foreach($event in $events){
                            if($log -eq 'Application' -and $event.ProviderName -notmatch 'Perflib|User Profile|SQL|Application Error|Windows Error Reporting|\.NET'){continue}
                            if($log -eq 'System' -and $event.ProviderName -notmatch 'Service Control Manager|DistributedCOM'){continue}
                            [pscustomobject]@{Kind='EVENT';Log=$log;Id=$event.Id;Provider=$event.ProviderName;TimeUtc=$event.TimeCreated.ToUniversalTime().ToString('o');Message=$event.Message;Xml=$event.ToXml()}
                        }
                    }
                }
            } -ErrorAction Stop
        } finally {if($guest){$guest.Dispose()}}
    } $RunId $StateRoot)
    $observation|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $privateLog
    $summary=[ordered]@{Contract='SqlServerLab.SsisExistingRunObservation/1.0';Status='READ_ONLY_OBSERVATION_RECORDED';RunId=$RunId.ToString();EventCount=@($observation|Where-Object Kind -eq EVENT).Count;FixtureMutations=0}
    $summary|ConvertTo-Json
    if($env:GITHUB_STEP_SUMMARY){$summary|ConvertTo-Json|Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY}
} catch {
    $_|Out-String|Set-Content -LiteralPath ($privateLog+'.error')
    throw 'SSIS_EXISTING_RUN_OBSERVATION_FAILED: private diagnostics retained.'
}
