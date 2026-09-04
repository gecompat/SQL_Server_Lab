#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft die labelgebundene Ownership-Grenze vor einem Runtime-Volume-Delete.
.DESCRIPTION
    Verwendet ausschließlich einen simulierten Docker-Aufruf. Es wird weder
    eine lokale Runtime noch ein Volume verändert.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

try {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -ErrorAction Stop
    $module = Get-Module SqlServerLab
    $evidence = & $module {
        $runId = [Guid]::NewGuid().ToString('D'); $scopeId = [Guid]::NewGuid().ToString('D')
        $script:volumeLabels = [PSCustomObject]@{
            'sql-server-lab.run-id' = $runId; 'sql-server-lab.scope-id' = $scopeId
        }
        $script:removeCalls = 0
        function Get-LabHostToolInvocation { param([string]$Name) if ($Name -ne 'docker') { throw 'UNEXPECTED_RUNTIME' }; return 'docker' }
        function docker {
            param([string]$ResourceType,[string]$Action,[string]$ResourceId)
            if ($ResourceType -ne 'volume' -or $ResourceId -ne 'synthetic-owned-volume') { throw 'UNEXPECTED_RUNTIME_RESOURCE' }
            if ($Action -eq 'inspect') {
                [PSCustomObject]@{ Name=$ResourceId; Labels=$script:volumeLabels } | ConvertTo-Json -Compress
                $global:LASTEXITCODE = 0; return
            }
            if ($Action -eq 'rm') { $script:removeCalls++; $global:LASTEXITCODE = 0; return }
            throw 'UNEXPECTED_RUNTIME_ACTION'
        }
        try {
            Remove-LabRuntimeResourceForCleanup -Provider docker -ResourceType volume -ResourceId 'synthetic-owned-volume' -ExpectedRunId $runId -ExpectedScopeId $scopeId
            $ownedRemoved = $script:removeCalls -eq 1
            $script:volumeLabels.'sql-server-lab.scope-id' = [Guid]::NewGuid().ToString('D')
            $mismatchBlocked = $false
            try {
                Remove-LabRuntimeResourceForCleanup -Provider docker -ResourceType volume -ResourceId 'synthetic-owned-volume' -ExpectedRunId $runId -ExpectedScopeId $scopeId
            }
            catch { $mismatchBlocked = $_.Exception.Message -match '^RUNTIME_VOLUME_OWNERSHIP_MISMATCH:' }
            [PSCustomObject]@{ OwnedRemoved=$ownedRemoved; MismatchBlocked=$mismatchBlocked; RemoveCalls=$script:removeCalls }
        }
        finally {
            Remove-Item Function:docker -ErrorAction SilentlyContinue
            Remove-Item Function:Get-LabHostToolInvocation -ErrorAction SilentlyContinue
            Remove-Variable -Scope Script -Name volumeLabels,removeCalls -ErrorAction SilentlyContinue
        }
    }
    Add-CheckResult -Name 'Genau das zum Plan passende Run-/Scope-Volume darf entfernt werden' -Success $evidence.OwnedRemoved
    Add-CheckResult -Name 'Abweichendes Scope-Label blockiert das Volume vor dem Remove-Aufruf' -Success ($evidence.MismatchBlocked -and $evidence.RemoveCalls -eq 1)
}
catch {
    Add-CheckResult -Name 'Cleanup-Volume-Ownership-Testausführung' -Success $false -Message $_.Exception.Message
}

Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) { exit 1 }
