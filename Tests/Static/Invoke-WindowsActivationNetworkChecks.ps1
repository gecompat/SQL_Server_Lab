#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../../SqlServerLab.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-activation-network-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
try {
    & $module {
        param($Root)
        function Assert-Network {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};Write-Host "PASS: $Name"}
        $lab=[pscustomobject]@{RunDirectory=$Root;Run=@{runId='own-run';scopeId='own-scope'};Instance=@{vmName='synthetic-vm'}}
        $external=[pscustomobject]@{Id='own-switch';Name='synthetic-switch'}
        $script:adapters=@([pscustomobject]@{Id='foreign';VMId='own-vm';SwitchId='own-switch';Name='SQL_SERVER_LAB_ACTIVATION_TEMP'})
        $script:addPartialFailure=$false;$script:removeFailure=$false;$script:removed=@()
        function Get-HyperVManagedVM {[pscustomobject]@{VM=@{Id='own-vm';State='Running'}}}
        function Get-VMNetworkAdapter {$script:adapters}
        function Add-VMNetworkAdapter {
            param($Name)
            $script:adapters+=@([pscustomobject]@{Id='created-'+[guid]::NewGuid().ToString('N');VMId='own-vm';SwitchId=[string][guid]::Empty;Name=$Name;MacAddress='00155D010203'})
            if($script:addPartialFailure){throw 'INDUCED_ADD_PARTIAL_FAILURE'}
            $script:adapters[-1]
        }
        function Connect-VMNetworkAdapter {param($VMNetworkAdapter,$VMSwitch);$VMNetworkAdapter.SwitchId=$VMSwitch.Id}
        function Remove-VMNetworkAdapter {
            param([Parameter(ValueFromPipeline)]$VMNetworkAdapter)
            process {
                if($VMNetworkAdapter.Id -eq 'foreign'){throw 'FOREIGN_ADAPTER_MUTATION'}
                if($script:removeFailure){throw 'INDUCED_REMOVE_FAILURE'}
                $script:removed+=@($VMNetworkAdapter.Id)
                $script:adapters=@($script:adapters | Where-Object Id -ne $VMNetworkAdapter.Id)
            }
        }
        $adapter=New-LabWindowsActivationAdapter -Lab $lab -ExternalSwitch $external
        $path=Join-Path $Root 'windows-activation-network.json'
        $journal=Get-Content $path -Raw | ConvertFrom-Json
        Assert-Network ($journal.Status -eq 'CREATED' -and $journal.AdapterId -eq $adapter.Id -and $journal.BeforeAdapterIds -contains 'foreign') 'Journal bindet neue Adapter-ID, VM und Vorbestand'
        $journal.SwitchId=[string][guid]::Empty
        Write-LabArtifactJsonAtomic -Path $path -InputObject $journal
        Remove-LabWindowsActivationAdapter -Lab $lab
        Assert-Network ($script:adapters.Count -eq 1) 'Recovery nach Connect vor Journalupdate erkennt ausschliesslich die vorab gebundene Ziel-Switch-ID'
        Remove-LabWindowsActivationAdapter -Lab $lab
        Assert-Network ($script:removed.Count -eq 1 -and $script:adapters.Count -eq 1 -and $script:adapters[0].Id -eq 'foreign') 'Cleanup ist idempotent und erhaelt gleichnamigen fremden Adapter'
        $script:addPartialFailure=$true
        $failed=$false
        try{$null=New-LabWindowsActivationAdapter -Lab $lab -ExternalSwitch $external}catch{$failed=$_.Exception.Message -eq 'INDUCED_ADD_PARTIAL_FAILURE'}
        Remove-LabWindowsActivationAdapter -Lab $lab
        Assert-Network ($failed -and $script:adapters.Count -eq 1) 'Partieller Add-Fehler bleibt sichtbar und sein nachgewiesener Adapter wird entfernt'
        $script:addPartialFailure=$false
        $adapter=New-LabWindowsActivationAdapter -Lab $lab -ExternalSwitch $external
        $script:removeFailure=$true
        $failed=$false
        try{Remove-LabWindowsActivationAdapter -Lab $lab}catch{$failed=$_.Exception.Message -eq 'INDUCED_REMOVE_FAILURE'}
        $journal=Get-Content $path -Raw | ConvertFrom-Json
        Assert-Network ($failed -and $journal.Status -eq 'CREATED' -and $script:adapters.Count -eq 2) 'Entfernungsfehler bewahrt Recovery-Identitaet'
        $script:removeFailure=$false
        $adapter.SwitchId='changed-switch'
        $protected=$false
        try{Remove-LabWindowsActivationAdapter -Lab $lab}catch{$protected=$_.Exception.Message -eq 'WINDOWS_ACTIVATION_NETWORK_OWNERSHIP_MISMATCH'}
        Assert-Network ($protected -and $script:adapters.Count -eq 2) 'Nachtraeglich umgebundener Adapter bleibt fuer explizite Recovery erhalten'
        $adapter.SwitchId='own-switch'
        $journal.ScopeId='foreign-scope';Write-LabArtifactJsonAtomic -Path $path -InputObject $journal
        $protected=$false
        try{Remove-LabWindowsActivationAdapter -Lab $lab}catch{$protected=$_.Exception.Message -eq 'WINDOWS_ACTIVATION_NETWORK_OWNERSHIP_MISMATCH'}
        Assert-Network ($protected -and $script:adapters.Count -eq 2) 'Fremder Journal-Scope kann keinen Adapter entfernen'
        $journal.ScopeId='own-scope';$journal.AdapterId='foreign';Write-LabArtifactJsonAtomic -Path $path -InputObject $journal
        $protected=$false
        try{Remove-LabWindowsActivationAdapter -Lab $lab}catch{$protected=$_.Exception.Message -eq 'WINDOWS_ACTIVATION_NETWORK_RECOVERY_REQUIRED'}
        Assert-Network ($protected -and $script:adapters.Count -eq 2) 'Vorbestand wird trotz Journal-Verweis niemals zum eigenen temporaeren Adapter'
        $journal.AdapterId=$adapter.Id;Write-LabArtifactJsonAtomic -Path $path -InputObject $journal
        Remove-LabWindowsActivationAdapter -Lab $lab
        Assert-Network ($script:adapters.Count -eq 1) 'Recovery entfernt nach aufgeloestem Konflikt genau den eigenen Adapter'
    } $root
}
finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-activation-network-*'){throw 'ACTIVATION_TEST_CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'WINDOWS ACTIVATION NETWORK CHECKS: PASS'
