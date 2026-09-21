#Requires -Version 7.2
<#
.SYNOPSIS
    Charakterisiert den echten lokalen sqlcmd-Parser ohne SQL-Verbindung.
.DESCRIPTION
    Verwendet ausschliesslich synthetische Argumente und den Hilfeaufruf.
    Gibt weder Passwortwerte noch native Argumente oder Rohoutput aus.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Private/ConsoleUi.ps1')
. (Join-Path $repoRoot 'Private/ActionProgress.ps1')
. (Join-Path $repoRoot 'Private/SqlReadiness.ps1')
$command=Get-Command sqlcmd -CommandType Application -ErrorAction Stop|Select-Object -First 1
$synthetic='-SyntheticOnlyA1!'
$old=Invoke-LabProgressNativeCommand -FilePath $command.Source -ArgumentList @('-P',$synthetic,'-?') -Phase SqlQuery -TimeoutSeconds 10
if($old.ExitCode -eq 0 -or ($old.Output -join ' ') -notmatch 'Missing argument'){throw 'SQLCMD_PARSER_COUNTEREXAMPLE_NOT_REPRODUCED'}
$bound=Invoke-LabSqlcmdProgress -ArgumentList @('-P',$synthetic,'-?') -ProcessTimeoutSeconds 10
if($bound.ExitCode -ne 0 -or ($bound.Output -join ' ') -match 'Missing argument'){throw 'SQLCMD_PARSER_BOUND_ARGUMENT_FAILED'}
$synthetic=$null;$old=$null;$bound=$null
Write-Host 'PASS: Echter sqlcmd-Hilfeparser reproduziert getrennten Fehler und akzeptiert gebundenen Wert; keine SQL-Verbindung.'
