#Requires -Version 7.2
<#
.SYNOPSIS
    Schließt ausschließlich receiptgebundene eigene Resource-Watch-Abnahmeissues.
.DESCRIPTION
    Erwarteter own-Scope, Repository, Issue-ID, Ressourcenmarker und Befund werden
    vor jeder Änderung erneut geprüft. Reguläre Watchissues bleiben ausgeschlossen.
    Schließen bewahrt das Issue; dieser Einstieg enthält keinen Löschpfad.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReceiptPath,[Parameter(Mandatory)][ValidatePattern('^own-[a-f0-9]{32}$')][string]$ExpectedIssueScope,[switch]$WhatIf,[switch]$AsJson)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common/VersionCatalogResourceWatchAutomation.ps1')
try{
    if((Get-Item -LiteralPath $ReceiptPath -Force -ErrorAction Stop).Length -gt 65536){throw 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID'}
    $receipt=Get-Content -LiteralPath $ReceiptPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 12 -ErrorAction Stop
}catch{throw 'RESOURCE_WATCH_FIXTURE_RECEIPT_INVALID'}
$result=Close-LabResourceWatchIssueFixture -Receipt $receipt -ExpectedIssueScope $ExpectedIssueScope -WhatIf:$WhatIf
if($AsJson){$result | ConvertTo-Json -Depth 8}else{$result}
