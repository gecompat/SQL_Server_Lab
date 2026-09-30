#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft CU- und SqlPackage-Metadaten für die vorhandene monatliche Watch-Lane.
.DESCRIPTION
    Ohne PublishIssues werden keine GitHub-Issues verändert. Nur bereinigte
    Projektionen und Issue-Receipts werden ausgegeben; Rohdiagnosen bleiben privat.
    Unklare Prüfung und fehlgeschlagene Benachrichtigung sind getrennte Ergebnisse.
#>
[CmdletBinding()]
param([switch]$PublishIssues,[switch]$WhatIf,[switch]$AsJson,[ValidatePattern('^(catalog|own-[a-f0-9]{32})$')][string]$IssueScope='catalog')
$ErrorActionPreference='Stop'
if($IssueScope -cnotmatch '^(catalog|own-[a-f0-9]{32})$'){throw 'RESOURCE_WATCH_ISSUE_SCOPE_INVALID'}
. (Join-Path $PSScriptRoot 'Common/VersionCatalogResourceWatchAutomation.ps1')
$evaluation=Invoke-LabResourceWatchAutomationEvaluation -Check {
    $modulePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'SqlServerLab.psd1'
    $module=Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    & $module {
        $configuration=Get-LabResourceWatchConfiguration
        [pscustomobject]@{ExpectedId=@($configuration.CuVersions | ForEach-Object {'sql-cu-'+$_.Version})+@('sqlpackage');Result=(Invoke-LabResourceWatchRefresh)}
    }
}
$receipt=if($PublishIssues){Invoke-LabResourceWatchIssueProjection -Evaluation $evaluation -WhatIf:$WhatIf -IssueScope $IssueScope}else{
    [pscustomobject]@{Contract='SqlServerLab.ResourceWatchIssueReceipt/1.0';Repository='gecompat/SQL_Server_Lab';IssueScope=$IssueScope;ApiBoundary='NOT_EXECUTED';NotificationFailed=$false;CheckFailed=$evaluation.CheckFailed;Receipts=@([pscustomobject]@{Status='NOT_EXECUTED';ReasonCode='RESOURCE_WATCH_ISSUE_NOT_REQUESTED';Verified=$false})}
}
$result=[pscustomobject]@{Evaluation=$evaluation;IssueReceipt=$receipt}
if($AsJson){$result | ConvertTo-Json -Depth 12}else{$result}
