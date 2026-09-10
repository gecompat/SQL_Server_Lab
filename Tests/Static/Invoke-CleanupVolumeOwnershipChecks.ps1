#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft die labelgebundene Ownership-Grenze vor Volume-/Netzwerk-Delete.
.DESCRIPTION
    Verwendet ausschließlich simulierte Docker-/Podman-Aufrufe. Es wird weder
    eine lokale Runtime noch ein Volume oder Netzwerk verändert.
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

    foreach ($provider in @('docker','podman')) {
        $networkEvidence = & $module {
            param($Provider)
            $runId = [Guid]::NewGuid().ToString('D'); $scopeId = [Guid]::NewGuid().ToString('D')
            $script:networkLabels = [PSCustomObject]@{
                'sql-server-lab.run-id'=$runId; 'sql-server-lab.scope-id'=$scopeId
            }
            $script:networkRemoveCalls=0
            function Get-LabHostToolInvocation { param([string]$Name) return 'Invoke-SyntheticNetworkRuntime' }
            function Invoke-SyntheticNetworkRuntime {
                param([string]$ResourceType,[string]$Action,[string]$ResourceId)
                if($ResourceType -ne 'network' -or $ResourceId -ne 'synthetic-owned-network'){throw 'UNEXPECTED_NETWORK_RESOURCE'}
                if($Action -eq 'inspect'){
                    [pscustomobject]@{Name=$ResourceId;labels=$script:networkLabels} | ConvertTo-Json -Compress
                    $global:LASTEXITCODE=0; return
                }
                if($Action -eq 'rm'){$script:networkRemoveCalls++;$global:LASTEXITCODE=0;return}
                throw 'UNEXPECTED_NETWORK_ACTION'
            }
            try {
                Remove-LabRuntimeResourceForCleanup -Provider $Provider -ResourceType network -ResourceId 'synthetic-owned-network' -ExpectedRunId $runId -ExpectedScopeId $scopeId
                $ownedRemoved=$script:networkRemoveCalls -eq 1
                $blocked=0
                foreach($case in @('shared','foreign-run','foreign-scope','missing-expectation')){
                    $script:networkLabels=[pscustomobject]@{'sql-server-lab.run-id'=$runId;'sql-server-lab.scope-id'=$scopeId}
                    $expectedRun=$runId
                    switch($case){
                        'shared' {$script:networkLabels=[pscustomobject]@{'sql-server-lab.network'='managed'}}
                        'foreign-run' {$script:networkLabels.'sql-server-lab.run-id'=[guid]::NewGuid().ToString('D')}
                        'foreign-scope' {$script:networkLabels.'sql-server-lab.scope-id'=[guid]::NewGuid().ToString('D')}
                        'missing-expectation' {$expectedRun=$null}
                    }
                    try {Remove-LabRuntimeResourceForCleanup -Provider $Provider -ResourceType network -ResourceId 'synthetic-owned-network' -ExpectedRunId $expectedRun -ExpectedScopeId $scopeId}
                    catch {if($_.Exception.Message -match '^RUNTIME_NETWORK_OWNERSHIP_(MISMATCH|EXPECTATION_REQUIRED)'){$blocked++}else{throw}}
                }
                [pscustomobject]@{OwnedRemoved=$ownedRemoved;Blocked=$blocked;RemoveCalls=$script:networkRemoveCalls}
            }
            finally {
                Remove-Item Function:Invoke-SyntheticNetworkRuntime -ErrorAction SilentlyContinue
                Remove-Item Function:Get-LabHostToolInvocation -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name networkLabels,networkRemoveCalls -ErrorAction SilentlyContinue
            }
        } $provider
        Add-CheckResult -Name "$provider entfernt genau das run-eigene Netzwerk" -Success $networkEvidence.OwnedRemoved
        Add-CheckResult -Name "$provider blockiert Shared-/Fremdnetzwerke und fehlende Ownership-Erwartung" -Success ($networkEvidence.Blocked -eq 4 -and $networkEvidence.RemoveCalls -eq 1)
    }
}
catch {
    Add-CheckResult -Name 'Cleanup-Volume-Ownership-Testausführung' -Success $false -Message $_.Exception.Message
}

Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) { exit 1 }
