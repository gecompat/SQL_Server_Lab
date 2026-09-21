# Internal child entry: no files, exports, runtime lifecycle or free command input.
# The existing readiness module import is isolated from the API caller.
[CmdletBinding()]
param([ValidateSet('docker','podman','hyperv')][string]$Provider,
    [ValidateSet('Inspect','Validate','Create','Start','Stop','Remove','PrepareImage')][string]$Operation)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$repo=Split-Path $PSScriptRoot -Parent
try {
    $module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -PassThru -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false
    $check=& $module { param($name) Get-LabClientRuntimeReadiness -Provider $name } $Provider `
        2>$null 3>$null 4>$null 5>$null 6>$null
    $result=[pscustomobject]@{
        ContractVersion='SqlServerLab.DiagnosticProviderReadiness/1.0';Provider=$Provider;Operation=$Operation
        Status=if($check.Status -ceq 'PASS'){'READY'}else{'NOT_READY'}
        Checks=@($check)
    }
    [Console]::Out.Write(($result | ConvertTo-Json -Depth 8 -Compress))
}
catch { exit 1 }
