#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/SsisPrerequisite.ps1')
. (Join-Path $repoRoot 'Public/Get-SqlServerLabSsisCatalogCapability.ps1')
$passed=0;$failed=0
function Check { param([string]$Name,[bool]$Success) if($Success){$script:passed++;Write-Host "PASS $Name"}else{$script:failed++;Write-Host "FAIL $Name"} }
$runId=[guid]'11111111-1111-1111-1111-111111111111'
$valid=[pscustomobject]@{Sql='SQL_2025_OBSERVED';Edition='EnterpriseDeveloper';DefaultPathComponents='OBSERVED';SsisDb='ONLINE_CATALOG_OBSERVED';ReasonCode='NONE'}
$cases=& {
    function Test-LabSsisWindowsHost { $true }
    function Invoke-LabSsisPrerequisite { param($RunId,$InstanceId,$StateRoot,$TimeoutSeconds) $script:seen=@{RunId=$RunId;InstanceId=$InstanceId;StateRoot=$StateRoot;TimeoutSeconds=$TimeoutSeconds};$script:next }
    $all=@{}
    foreach($name in @('ready','older','catalog','components','target','drift','probe')) {
        $script:next=$valid.PSObject.Copy()
        switch($name) {
            'older' {$script:next.Sql='SQL_2022_OBSERVED'}
            'catalog' {$script:next.SsisDb='MISSING'}
            'components' {$script:next.DefaultPathComponents='NOT_OBSERVED'}
            'target' {$script:next.ReasonCode='SSIS_TARGET_UNAVAILABLE'}
            'drift' {$script:next.ReasonCode='SSIS_BINDING_CHANGED'}
            'probe' {$script:next.ReasonCode='SSIS_PROBE_UNAVAILABLE'}
        }
        $all[$name]=Get-SqlServerLabSsisCatalogCapability -RunId $runId -InstanceId primary -StateRoot synthetic -TimeoutSeconds 17
    }
    [pscustomobject]@{Values=$all;Seen=$script:seen}
}
$ready=$cases.Values.ready
Check 'Read-only capability binds exactly one run, instance and bounded transport' ($cases.Seen.RunId -eq $runId -and $cases.Seen.InstanceId -ceq 'primary' -and $cases.Seen.StateRoot -ceq 'synthetic' -and $cases.Seen.TimeoutSeconds -eq 17)
Check 'Ready is limited to observed owned Windows SQL, components and online catalog' ($ready.Status -ceq 'READY_FOR_FIXTURE_IMPLEMENTATION' -and $ready.Target.BindingStatus -ceq 'BOUND' -and $ready.Source.Status -ceq 'OBSERVED')
$olderResult=$cases.Values.older
Check 'Korrekt bezeichnete eigene SQL-2022-Quelle bleibt für den Fixture-Slice zulässig' ($olderResult.Status -ceq 'READY_FOR_FIXTURE_IMPLEMENTATION' -and $olderResult.Sql.Status -ceq 'SQL_2022_OBSERVED')
Check 'Ready does not grant consumer connection, rights or fixture mutation' ($ready.Source.ConnectionBinding -ceq 'NOT_PROVISIONED' -and $ready.Source.ConsumerRights -ceq 'NOT_ASSESSED' -and $ready.Fixture.Status -ceq 'NOT_IMPLEMENTED' -and -not $ready.Fixture.MutationAllowed -and @($ready.Fixture.ManagedExecutionIds).Count -eq 0)
Check 'Catalog and component deviations block fixture preparation' ($cases.Values.catalog.Status -ceq 'BLOCKED' -and $cases.Values.catalog.Source.Status -ceq 'NOT_READY' -and $cases.Values.components.Status -ceq 'BLOCKED')
Check 'Target and binding faults remain sanitized public block codes' ($cases.Values.target.ReasonCode -ceq 'TARGET_UNAVAILABLE' -and $cases.Values.drift.ReasonCode -ceq 'BINDING_CHANGED' -and $cases.Values.probe.ReasonCode -ceq 'PROBE_UNAVAILABLE')
Check 'Public response projects no endpoint, credential, path or raw fault field' ((($ready|ConvertTo-Json -Depth 16) -notmatch '(?i)(password|secret|credential|connectionstring|vmname|endpoint|synthetic)'))
Check 'Public contract is explicit Windows Hyper-V read-only capability version' ($ready.ContractVersion -ceq 'SqlServerLab.SsisCatalogCapability/1.0' -and $ready.Provider -ceq 'hyperv' -and $ready.OperatingSystem -ceq 'windows' -and $ready.ReadOnly)
$source=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Get-SqlServerLabSsisCatalogCapability.ps1') -Raw
Check 'Capability source permits no installation, creation or execution primitive' ($source -notmatch '(?i)(Install-|New-SqlServerLab|Start-SqlServerLab|create_execution|start_execution|Invoke-Sqlcmd)')
$manifest=Import-PowerShellDataFile (Join-Path $repoRoot 'SqlServerLab.psd1')
Check 'Public capability is a declared module export' ('Get-SqlServerLabSsisCatalogCapability' -cin @($manifest.FunctionsToExport))
if($failed){throw "SSIS CATALOG CAPABILITY CHECKS: FAIL ($failed of $($passed+$failed))"}
Write-Host "SSIS CATALOG CAPABILITY CHECKS: PASS ($passed)"
