#Requires -Version 7.5
<# .SYNOPSIS
    Fordert ohne Erhöhung ausschließlich Ready, Run oder Close eines gebundenen Runners an.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunnerId,[Parameter(Mandatory)][ValidateSet('Ready','Run','Close')][string]$Operation)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$root=Get-BoundedTlsRoot $RunnerId
$plan=Read-BoundedTlsJson (Join-Path $root 'plan.private.json')
Assert-BoundedTlsPlan $plan -Installed
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $plan.ActorSid){throw 'BOUNDED_TLS_REQUEST_ACTOR_CHANGED'}
$state=Read-BoundedTlsJson (Join-Path $root 'state.private.json')
if($state.Status -ceq 'RUNNING'){throw 'BOUNDED_TLS_ALREADY_ACTIVE'}
$decision=Get-BoundedTlsDecision $plan $state $Operation
if($decision -cin @('CLOSED','EXHAUSTED')){throw ('BOUNDED_TLS_'+$decision)}
$request=@{ContractVersion='SqlServerLab.BoundedTlsRequest/0.1';RunnerId=$RunnerId;RequestId=[guid]::NewGuid().ToString('D');Operation=$Operation}
Write-BoundedTlsJson (Join-Path $root 'requests/request.private.json') $request -Replace
Start-ScheduledTask -TaskName $plan.TaskName -ErrorAction Stop
[pscustomobject]@{Status='REQUESTED';RunnerId=$RunnerId;Operation=$Operation;RequestId=$request.RequestId}
