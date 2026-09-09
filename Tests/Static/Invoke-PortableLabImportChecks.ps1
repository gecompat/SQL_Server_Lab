#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$results=[Collections.Generic.List[object]]::new()
function Add-CheckResult { param([string]$Name,[bool]$Success) $results.Add([PSCustomObject]@{Name=$Name;Success=$Success});Write-Host "$(if($Success){'PASS'}else{'FAIL'}): $Name" -ForegroundColor $(if($Success){'Green'}else{'Red'}) }
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $result=& $module {
        $package=[PSCustomObject][ordered]@{ContractVersion='SqlServerLab.PortableLabPackage/1.0';PackageId='11111111-1111-1111-1111-111111111111';Source=[PSCustomObject]@{Provider='docker';SqlMajorVersion='17'};DatabasePackages=@([PSCustomObject]@{DatabasePackageId='22222222-2222-2222-2222-222222222222'});SecretReferences=@('SQL_SERVER_LAB_SECRET_SA_PASSWORD');ArtifactReferences=@('sql2025-linux')}
        $ready=Get-LabPortableLabImportPlan -Package ($package | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10) -TargetProvider podman -AvailableDatabasePackageId '22222222-2222-2222-2222-222222222222'
        $blocked=Get-LabPortableLabImportPlan -Package ($package | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10) -TargetProvider docker
        $duplicate=$false;$copy=$package | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10;$copy.DatabasePackages+=@([PSCustomObject]@{DatabasePackageId='22222222-2222-2222-2222-222222222222'})
        try{$null=Get-LabPortableLabImportPlan -Package $copy -TargetProvider docker}catch{$duplicate=$_.Exception.Message -match 'DATABASE_DUPLICATE'}
        [PSCustomObject]@{Ready=$ready;Blocked=$blocked;Duplicate=$duplicate}
    }
    Add-CheckResult 'Portabler Preflight akzeptiert verfügbare Paket-IDs ohne Runtime- oder State-Mutation' ($result.Ready.Status -eq 'BLOCKED' -and -not $result.Ready.ExecutionImplemented -and $result.Ready.DatabasePackages[0].Status -eq 'AVAILABLE')
    Add-CheckResult 'Secret-Referenzen werden nur als anonymer Rebind-Blocker projektiert' ($result.Ready.SecretReferenceCount -eq 1 -and 'SECRET_REBINDING_REQUIRED' -in $result.Ready.Blockers -and (($result.Ready|ConvertTo-Json -Depth 20) -notmatch 'SQL_SERVER_LAB_SECRET_SA_PASSWORD'))
    Add-CheckResult 'Fehlende Datenbankpakete blockieren den Import fail-closed' ($result.Blocked.Status -eq 'BLOCKED' -and $result.Blocked.DatabasePackages[0].Status -eq 'MISSING' -and 'DATABASE_PACKAGE_MISSING' -in $result.Blocked.Blockers)
    Add-CheckResult 'Doppelte stabile Datenbankpaket-IDs werden abgelehnt' $result.Duplicate
    Add-CheckResult 'Importplan erfüllt den versionierten JSON-Schema-Vertrag' ((($result.Blocked|ConvertTo-Json -Depth 20)|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/portable-lab-import-plan.schema.json') -ErrorAction SilentlyContinue))
}
finally {Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue}
$failed=@($results|Where-Object{-not $_.Success})
if($failed.Count -gt 0){throw "PORTABLE LAB IMPORT CHECKS FAILED: $($failed.Name -join '; ')"}
Write-Host "PORTABLE LAB IMPORT CHECKS: PASS ($($results.Count))" -ForegroundColor Green