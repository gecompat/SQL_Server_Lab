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
    $ids=@($Package.DatabasePackages | ForEach-Object { [string]$_.DatabasePackageId })
    if(@($ids | Sort-Object -Unique).Count -ne $ids.Count){throw 'PORTABLE_LAB_PACKAGE_DATABASE_DUPLICATE'}
    return $true
}

function Get-LabPortableLabImportPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$TargetProvider,
        [string[]]$AvailableDatabasePackageId=@()
    )

    $null=Test-LabPortableLabPackage -Package $Package
    $available=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($id in @($AvailableDatabasePackageId)){if($id){$null=$available.Add([string]$id)}}
    $packages=@($Package.DatabasePackages | ForEach-Object {
        $id=[string]$_.DatabasePackageId
        [PSCustomObject][ordered]@{DatabasePackageId=$id;Status=if($available.Contains($id)){'AVAILABLE'}else{'MISSING'}}
    })
    $blockers=[Collections.Generic.List[string]]::new()
    if(@($packages | Where-Object Status -eq 'MISSING').Count -gt 0){$blockers.Add('DATABASE_PACKAGE_MISSING')}
    if(@($Package.SecretReferences).Count -gt 0){$blockers.Add('SECRET_REBINDING_REQUIRED')}
    $plan=[PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.PortableLabImportPlan/1.0'
        PackageContractVersion='SqlServerLab.PortableLabPackage/1.0'
        PackageId=[string]$Package.PackageId
        TargetProvider=$TargetProvider
        Status=if($blockers.Count -eq 0){'READY'}else{'BLOCKED'}
        ExecutionImplemented=$false
        DatabasePackages=$packages
        SecretReferenceCount=@($Package.SecretReferences).Count
        ArtifactReferences=@($Package.ArtifactReferences | Sort-Object -Unique)
        Blockers=@($blockers | Sort-Object -Unique)
        Steps=@(
            [PSCustomObject][ordered]@{Order=1;Action='VERIFY_DATABASE_PACKAGES';Mutation='NONE'},
            [PSCustomObject][ordered]@{Order=2;Action='REQUIRE_SECRET_REBINDING';Mutation='NONE'}
        )
        PlannedAt=Get-LabTimestamp
    }
    try { $valid=$plan | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $script:SchemasPath 'portable-lab-import-plan.schema.json') -ErrorAction Stop }
    catch { throw "PORTABLE_LAB_IMPORT_PLAN_INVALID: $($_.Exception.Message)" }
    if(-not $valid){throw 'PORTABLE_LAB_IMPORT_PLAN_INVALID'}
    return $plan
}