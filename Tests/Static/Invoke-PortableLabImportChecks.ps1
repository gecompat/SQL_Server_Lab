#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$results=[Collections.Generic.List[object]]::new()
function Add-CheckResult { param([string]$Name,[bool]$Success) $results.Add([PSCustomObject]@{Name=$Name;Success=$Success});Write-Host "$(if($Success){'PASS'}else{'FAIL'}): $Name" -ForegroundColor $(if($Success){'Green'}else{'Red'}) }
$testRoot=Join-Path ([IO.Path]::GetTempPath()) "sql-server-lab-portable-transfer-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path (Join-Path $testRoot 'runs/33333333-3333-3333-3333-333333333333') -Force|Out-Null
[PSCustomObject]@{runId='33333333-3333-3333-3333-333333333333';state='RUNNING';instances=@([PSCustomObject]@{id='primary';provider='docker'})}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $testRoot 'runs/33333333-3333-3333-3333-333333333333/run-state.json') -Encoding utf8
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $result=& $module {
        param($StateRoot)
        $package=[PSCustomObject][ordered]@{
            ContractVersion='SqlServerLab.PortableLabPackage/1.1';PackageId='11111111-1111-1111-1111-111111111111'
            Source=[PSCustomObject]@{Provider='podman';SqlMajorVersion='17'}
            BackupReferences=@([PSCustomObject]@{BackupSetId='22222222-2222-2222-2222-222222222222';Sha256=('a'*64);Bytes=1024;BackupChecksum=$true;RestoreVerifyOnly=$true})
        }
        $ready=Get-LabPortableLabImportPlan -Package ($package|ConvertTo-Json -Depth 10|ConvertFrom-Json -Depth 10) -TargetProvider docker -TargetRunId '33333333-3333-3333-3333-333333333333' -StateRoot $StateRoot
        $providerBlocked=Get-LabPortableLabImportPlan -Package ($package|ConvertTo-Json -Depth 10|ConvertFrom-Json -Depth 10) -TargetProvider podman -TargetRunId '33333333-3333-3333-3333-333333333333' -StateRoot $StateRoot
        $integrityPackage=$package|ConvertTo-Json -Depth 10|ConvertFrom-Json -Depth 10;$integrityPackage.BackupReferences[0].RestoreVerifyOnly=$false
        $integrityBlocked=Get-LabPortableLabImportPlan -Package $integrityPackage -TargetProvider docker -TargetRunId '33333333-3333-3333-3333-333333333333' -StateRoot $StateRoot
        $duplicate=$false;$copy=$package|ConvertTo-Json -Depth 10|ConvertFrom-Json -Depth 10;$copy.BackupReferences+=@($copy.BackupReferences[0])
        try{$null=Get-LabPortableLabImportPlan -Package $copy -TargetProvider docker -TargetRunId '33333333-3333-3333-3333-333333333333' -StateRoot $StateRoot}catch{$duplicate=$_.Exception.Message -match 'BACKUP_DUPLICATE'}
        [PSCustomObject]@{Ready=$ready;ProviderBlocked=$providerBlocked;IntegrityBlocked=$integrityBlocked;Duplicate=$duplicate}
    } $testRoot
    Add-CheckResult 'Transferplan ist an einen bestehenden Container-Ziel-Run gebunden und bleibt nicht ausführbar' ($result.Ready.Status -eq 'READY' -and $result.Ready.TargetRunId -eq '33333333-3333-3333-3333-333333333333' -and $result.Ready.TargetRunState -eq 'RUNNING' -and -not $result.Ready.ExecutionImplemented)
    Add-CheckResult 'Plan transportiert nur stabile Backup-Referenzen und Integritäts-Evidence' ($result.Ready.BackupReferences[0].BackupSetId -eq '22222222-2222-2222-2222-222222222222' -and $result.Ready.BackupReferences[0].IntegrityStatus -eq 'VERIFIED' -and (($result.Ready|ConvertTo-Json -Depth 20) -notmatch '(?i)secret|credential|password'))
    Add-CheckResult 'Nicht gebundener Zielprovider blockiert den Transfer fail-closed' ($result.ProviderBlocked.Status -eq 'BLOCKED' -and 'TARGET_PROVIDER_MISMATCH' -in $result.ProviderBlocked.Blockers)
    Add-CheckResult 'Unvollständige Backup-Integrität blockiert den Transfer fail-closed' ($result.IntegrityBlocked.Status -eq 'BLOCKED' -and $result.IntegrityBlocked.BackupReferences[0].IntegrityStatus -eq 'BLOCKED' -and 'BACKUP_INTEGRITY_UNVERIFIED' -in $result.IntegrityBlocked.Blockers)
    Add-CheckResult 'Doppelte stabile Backup-IDs werden abgelehnt' $result.Duplicate
    Add-CheckResult 'Transferplan erfüllt den versionierten JSON-Schema-Vertrag' ((($result.Ready|ConvertTo-Json -Depth 20)|Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/portable-lab-import-plan.schema.json') -ErrorAction SilentlyContinue))
}
finally {Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
$failed=@($results|Where-Object{-not $_.Success})
if($failed.Count -gt 0){throw "PORTABLE LAB IMPORT CHECKS FAILED: $($failed.Name -join '; ')"}
Write-Host "PORTABLE LAB IMPORT CHECKS: PASS ($($results.Count))" -ForegroundColor Green
