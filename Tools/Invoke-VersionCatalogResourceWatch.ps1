#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft CU- und SqlPackage-Metadaten für die vorhandene monatliche Watch-Lane.
.DESCRIPTION
    Ohne PublishIssues werden keine GitHub-Issues verändert. Nur bereinigte
    Projektionen und Issue-Receipts werden ausgegeben; Rohdiagnosen bleiben privat.
    Unklare Prüfung und fehlgeschlagene Benachrichtigung sind getrennte Ergebnisse.
    Own-Abnahmen benötigen genau eine AcceptanceResourceId aus dem vollständigen
    Ressourcenbestand. Nach unbekanntem Write nur mit ContinuationReceiptPath
    gebunden wiederaufnehmen; ohne frisch gefundenen Marker erfolgt kein Create.
#>
[CmdletBinding()]
param([switch]$PublishIssues,[switch]$WhatIf,[switch]$AsJson,[ValidatePattern('^(catalog|own-[a-f0-9]{32})$')][string]$IssueScope='catalog',
    [string]$AcceptanceResourceId,[string]$ContinuationReceiptPath)
$ErrorActionPreference='Stop'
if($IssueScope -cnotmatch '^(catalog|own-[a-f0-9]{32})$'){throw 'RESOURCE_WATCH_ISSUE_SCOPE_INVALID'}
. (Join-Path $PSScriptRoot 'Common/VersionCatalogResourceWatchAutomation.ps1')
$own=$IssueScope -cne 'catalog';$continuation=$null;$head=$null
if(($own -and $PublishIssues -and $AcceptanceResourceId -cnotmatch '^(sql-cu-\d{4}|sqlpackage)$') -or
    (-not $own -and ($AcceptanceResourceId -or $ContinuationReceiptPath))){throw 'RESOURCE_WATCH_ISSUE_ACCEPTANCE_INVALID'}
if($own -and $PublishIssues){
    $git=(Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $output=@(& $git -C (Split-Path $PSScriptRoot -Parent) rev-parse HEAD 2>$null)
    if($LASTEXITCODE -ne 0 -or $output.Count -ne 1 -or $output[0] -cnotmatch '^[a-f0-9]{40}$'){throw 'RESOURCE_WATCH_ISSUE_ACCEPTANCE_INVALID'}
    $head=[string]$output[0]
}
if($ContinuationReceiptPath){
    $file=Get-Item -LiteralPath $ContinuationReceiptPath -ErrorAction Stop
    if($file.PSIsContainer -or $file.Length -gt 65536){throw 'RESOURCE_WATCH_ISSUE_CONTINUATION_INVALID'}
    try{$continuation=Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 12 -ErrorAction Stop}catch{throw 'RESOURCE_WATCH_ISSUE_CONTINUATION_INVALID'}
}
$binding=@{ExpectedId=@()}
$evaluation=Invoke-LabResourceWatchAutomationEvaluation -Check {
    $modulePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'SqlServerLab.psd1'
    $module=Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    & $module {
        param($Binding)
        $configuration=Get-LabResourceWatchConfiguration
        $Binding.ExpectedId=@($configuration.CuVersions | ForEach-Object {'sql-cu-'+$_.Version})+@('sqlpackage')
        [pscustomobject]@{ExpectedId=@($configuration.CuVersions | ForEach-Object {'sql-cu-'+$_.Version})+@('sqlpackage');Result=(Invoke-LabResourceWatchRefresh)}
    } $binding
}
$acceptance=@{}
if($own -and $PublishIssues){$acceptance=@{AcceptanceResourceId=$AcceptanceResourceId;ExpectedId=$binding.ExpectedId;PublicationHead=$head;ContinuationReceipt=$continuation}}
$receipt=if($PublishIssues){Invoke-LabResourceWatchIssueProjection -Evaluation $evaluation -WhatIf:$WhatIf -IssueScope $IssueScope @acceptance}else{
    [pscustomobject]@{Contract='SqlServerLab.ResourceWatchIssueReceipt/1.0';Repository='gecompat/SQL_Server_Lab';IssueScope=$IssueScope;ApiBoundary='NOT_EXECUTED';NotificationFailed=$false;CheckFailed=$evaluation.CheckFailed;Receipts=@([pscustomobject]@{Status='NOT_EXECUTED';ReasonCode='RESOURCE_WATCH_ISSUE_NOT_REQUESTED';Verified=$false})}
}
$result=[pscustomobject]@{Evaluation=$evaluation;IssueReceipt=$receipt}
if($AsJson){$result | ConvertTo-Json -Depth 12}else{$result}
