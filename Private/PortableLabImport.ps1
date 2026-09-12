<#
.SYNOPSIS
    Plant den Import eines portablen Container-Lab-Pakets ohne Mutation.
#>

function Test-LabPortableLabPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package)
    try { $valid=$Package | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $script:SchemasPath 'portable-lab-package.schema.json') -ErrorAction Stop }
    catch { throw "PORTABLE_LAB_PACKAGE_INVALID: $($_.Exception.Message)" }
    if(-not $valid){throw 'PORTABLE_LAB_PACKAGE_INVALID'}
    $ids=@($Package.BackupReferences | ForEach-Object { [string]$_.BackupSetId })
    if(@($ids | Sort-Object -Unique).Count -ne $ids.Count){throw 'PORTABLE_LAB_PACKAGE_BACKUP_DUPLICATE'}
    return $true
}

function Get-LabPortableLabImportPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$TargetProvider,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TargetRunId,
        [string]$StateRoot
    )

    $null=Test-LabPortableLabPackage -Package $Package
    try { $targetRun=Get-LabRunState -RunId $TargetRunId -StateRoot $StateRoot }
    catch { throw "CONTAINER_TRANSFER_TARGET_RUN_NOT_FOUND: $TargetRunId" }
    if([string]$targetRun.runId -ne $TargetRunId){throw 'CONTAINER_TRANSFER_TARGET_RUN_ID_MISMATCH'}

    $targetProviderPresent=@($targetRun.instances | Where-Object { [string]$_.provider -eq $TargetProvider }).Count -gt 0
    $backups=@($Package.BackupReferences | ForEach-Object {
        [PSCustomObject][ordered]@{
            BackupSetId=[string]$_.BackupSetId
            Sha256=[string]$_.Sha256
            Bytes=[long]$_.Bytes
            BackupChecksum=[bool]$_.BackupChecksum
            RestoreVerifyOnly=[bool]$_.RestoreVerifyOnly
            IntegrityStatus=if([bool]$_.BackupChecksum -and [bool]$_.RestoreVerifyOnly){'VERIFIED'}else{'BLOCKED'}
        }
    })
    $blockers=[Collections.Generic.List[string]]::new()
    if([string]$targetRun.state -notin @('RUNNING','STOPPED')){$blockers.Add('TARGET_RUN_NOT_ACTIVE')}
    if(-not $targetProviderPresent){$blockers.Add('TARGET_PROVIDER_MISMATCH')}
    if(@($backups | Where-Object IntegrityStatus -eq 'BLOCKED').Count -gt 0){$blockers.Add('BACKUP_INTEGRITY_UNVERIFIED')}
    $plan=[PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.PortableContainerTransferPlan/1.0'
        PackageContractVersion='SqlServerLab.PortableLabPackage/1.1'
        PackageId=[string]$Package.PackageId
        SourceProvider=[string]$Package.Source.Provider
        TargetProvider=$TargetProvider
        TargetRunId=$TargetRunId.ToLowerInvariant()
        TargetRunState=[string]$targetRun.state
        Status=if($blockers.Count -eq 0){'READY'}else{'BLOCKED'}
        ExecutionImplemented=$false
        BackupReferences=$backups
        Blockers=@($blockers | Sort-Object -Unique)
        Steps=@(
            [PSCustomObject][ordered]@{Order=1;Action='VERIFY_TARGET_RUN';Mutation='NONE'},
            [PSCustomObject][ordered]@{Order=2;Action='VERIFY_BACKUP_INTEGRITY';Mutation='NONE'},
            [PSCustomObject][ordered]@{Order=3;Action='REQUIRE_TARGET_INSTANCE_BINDING';Mutation='NONE'}
        )
        PlannedAt=Get-LabTimestamp
    }
    try { $valid=$plan | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $script:SchemasPath 'portable-lab-import-plan.schema.json') -ErrorAction Stop }
    catch { throw "PORTABLE_LAB_IMPORT_PLAN_INVALID: $($_.Exception.Message)" }
    if(-not $valid){throw 'PORTABLE_LAB_IMPORT_PLAN_INVALID'}
    return $plan
}
