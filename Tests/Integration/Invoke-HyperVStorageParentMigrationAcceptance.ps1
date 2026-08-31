#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt die allgemeine Lab_Data-Parent-Migration mit einer isolierten Hyper-V-Test-VM.
.DESCRIPTION
    Der erhöhte Runner verlangt die exakte LocationId einer kleinen, nicht
    standardmäßigen und vollständig unreferenzierten Lab_Data-Location. Er
    erzeugt dort eine ausgeschaltete Generation-2-Test-VM samt VHDX, migriert
    die Location auf demselben Volume in einen eindeutig scopegebundenen
    temporären Parent und anschließend an den ursprünglichen Parent zurück.
    Erst nach vollständigen VM-, VHDX-, Katalog- und Dateipostconditions werden
    Test-VM, Testdateien und die beiden Acceptance-Journale entfernt.

    Bei einem Fehler bleiben der aktuelle Root, die Test-VM und das
    Migrationsjournal für den journalisierten Recovery-Pfad erhalten.
.PARAMETER SourceLocationId
    Exakte LocationId einer nicht standardmäßigen, unreferenzierten Location.
.PARAMETER MaximumSourceBytes
    Maximale Größe des bestehenden Location-Inhalts vor dem Test.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SourceLocationId,

    [ValidateRange(1MB, 1GB)]
    [long]$MaximumSourceBytes = 16MB
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$vmName = $null
$sourceRoot = $null
$targetParent = $null
$forwardPlanId = $null
$reversePlanId = $null
$phase = 'initialize'

function Test-ParentMigrationAcceptanceAdministrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ParentMigrationAcceptancePathPrefix {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)

    $candidate = [IO.Path]::GetFullPath($Path)
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return $candidate.StartsWith($normalizedRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)
}

try {
    if (-not (Test-ParentMigrationAcceptanceAdministrator)) {
        throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_ELEVATION_REQUIRED'
    }
    Import-Module $modulePath -Force
    $module = Get-Module SqlServerLab
    $token = [Guid]::NewGuid().ToString('N').Substring(0, 8)

    $inventory = & $module {
        param($LocationId, $Token, $MaximumBytes)

        $configuration = Get-LabStorageConfiguration
        $location = @($configuration.LabDataLocations | Where-Object {
            [string]$_.LocationId -eq $LocationId
        })
        if ($location.Count -ne 1) { throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_LOCATION_NOT_FOUND' }
        if ([string]$location[0].LocationId -eq [string]$configuration.DefaultLocationId) {
            throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_DEFAULT_LOCATION_PROTECTED'
        }

        $root = [IO.Path]::GetFullPath([string]$location[0].LabDataRoot).TrimEnd('\', '/')
        if (-not (Test-LabDataRootOwnership -DataRoot $root -ControllerId ([string]$configuration.ControllerId))) {
            throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_SOURCE_OWNERSHIP_INVALID'
        }
        $targetParent = Join-Path ([IO.Path]::GetPathRoot($root)) ("SqlServerLab-Parent-Acceptance-$Token")
        $targetRoot = Join-Path $targetParent 'Lab_Data'
        if (Test-Path -LiteralPath $targetParent) {
            throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_TARGET_COLLISION'
        }

        $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction Stop)
        $totalBytes = [long](($files | Measure-Object Length -Sum).Sum)
        if ($totalBytes -gt $MaximumBytes) {
            throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_SOURCE_TOO_LARGE'
        }
        if (@(Get-LabDataLocationReferences -Location $location[0] -Configuration $configuration).Count -gt 0) {
            throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_SOURCE_REFERENCED'
        }
        if (@(Get-LabStorageMigrationHyperVBindingInventory -DataRoot $root -StateRoot (Get-LabStateRoot)).Count -gt 0) {
            throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_SOURCE_HAS_BINDINGS'
        }
        if (@(Get-LabStorageMigrationHyperVVMConfigurationInventory `
                -DataRoot $root -TargetRoot $targetRoot).Count -gt 0) {
            throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_SOURCE_HAS_VM_CONFIGURATION'
        }

        [PSCustomObject]@{
            LocationId=[string]$location[0].LocationId
            SourceRoot=$root
            TargetParent=$targetParent
            InitialFiles=@($files | ForEach-Object {
                [PSCustomObject]@{
                    RelativePath=[IO.Path]::GetRelativePath($root, $_.FullName)
                    Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            })
        }
    } $SourceLocationId $token $MaximumSourceBytes

    $sourceRoot = [string]$inventory.SourceRoot
    $targetParent = [string]$inventory.TargetParent
    $targetRoot = Join-Path $targetParent 'Lab_Data'
    $testRoot = Join-Path $sourceRoot "Acceptance/ParentMigration/$token"
    $vmPath = Join-Path $testRoot 'vm'
    $diskPath = Join-Path $testRoot 'os.vhdx'
    $pagingPath = Join-Path $testRoot 'paging'
    $vmName = "SqlLab-ParentMove-$token"
    if (Test-Path -LiteralPath $testRoot) { throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_SCOPE_COLLISION' }

    $phase = 'create-test-vm'
    New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
    $vm = New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 256MB `
        -NewVHDPath $diskPath -NewVHDSizeBytes 128MB -Path $vmPath -ErrorAction Stop
    Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Disabled `
        -SmartPagingFilePath $pagingPath -ErrorAction Stop
    $vm = Get-VM -Name $vmName -ErrorAction Stop
    if ([string]$vm.State -ne 'Off') { throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_TEST_VM_NOT_OFF' }

    $phase = 'forward-plan'
    $forward = & $module {
        param($Source, $Target)
        New-LabDataMigrationPlan -SourceDataRoot $Source -TargetParent $Target
    } $sourceRoot $targetParent
    $forwardPlanId = [string]$forward.Plan.PlanId
    if ([string]$forward.Plan.Status -ne 'READY' -or @($forward.Plan.Blockers).Count -ne 0 -or
        @($forward.Plan.HyperVVMConfigurations).Count -ne 1 -or
        @($forward.Plan.HyperVVMConfigurations[0].Paths).Count -ne 3) {
        throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_FORWARD_PLAN_NOT_READY'
    }

    $phase = 'forward-apply'
    $forwardResult = & $module {
        param($Path)
        Invoke-LabDataMigration -PlanPath $Path -ProcessEnvironmentOnly -Confirm:$false
    } ([string]$forward.Path)
    if ([string]$forwardResult.Status -ne 'COMPLETED') {
        throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_FORWARD_INCOMPLETE'
    }
    $movedDisk = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction Stop | Select-Object -First 1)
    $movedVMConfiguration = & $module {
        param($Source, $Target)
        @(Get-LabStorageMigrationHyperVVMConfigurationInventory -DataRoot $Source -TargetRoot $Target)
    } $targetRoot $sourceRoot
    if (@($movedVMConfiguration).Count -ne 1 -or @($movedDisk).Count -ne 1 -or
        -not (Test-ParentMigrationAcceptancePathPrefix -Path ([string]$movedDisk[0].Path) -Root $targetRoot) -or
        (Test-Path -LiteralPath $sourceRoot)) {
        throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_FORWARD_POSTCONDITION_FAILED'
    }

    $phase = 'reverse-plan'
    $originalParent = Split-Path -Parent $sourceRoot
    $reverse = & $module {
        param($Source, $Target)
        New-LabDataMigrationPlan -SourceDataRoot $Source -TargetParent $Target
    } $targetRoot $originalParent
    $reversePlanId = [string]$reverse.Plan.PlanId
    if ([string]$reverse.Plan.Status -ne 'READY' -or @($reverse.Plan.Blockers).Count -ne 0 -or
        @($reverse.Plan.HyperVVMConfigurations).Count -ne 1 -or
        @($reverse.Plan.HyperVVMConfigurations[0].Paths).Count -ne 3) {
        throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_REVERSE_PLAN_NOT_READY'
    }

    $phase = 'reverse-apply'
    $reverseResult = & $module {
        param($Path)
        Invoke-LabDataMigration -PlanPath $Path -ProcessEnvironmentOnly -Confirm:$false
    } ([string]$reverse.Path)
    if ([string]$reverseResult.Status -ne 'COMPLETED') {
        throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_REVERSE_INCOMPLETE'
    }
    $restoredDisk = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction Stop | Select-Object -First 1)
    if (@($restoredDisk).Count -ne 1 -or
        -not (Test-ParentMigrationAcceptancePathPrefix -Path ([string]$restoredDisk[0].Path) -Root $sourceRoot) -or
        -not (Test-Path -LiteralPath $sourceRoot -PathType Container) -or
        (Test-Path -LiteralPath $targetRoot)) {
        throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_REVERSE_POSTCONDITION_FAILED'
    }

    $phase = 'cleanup'
    Remove-VM -Name $vmName -Force -ErrorAction Stop
    $vmName = $null
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
    }
    $migrationDirectory = Join-Path $sourceRoot 'Catalog/storage-migrations'
    foreach ($planId in @($forwardPlanId, $reversePlanId)) {
        foreach ($suffix in @('plan.json', 'journal.json')) {
            $path = Join-Path $migrationDirectory "$planId.$suffix"
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }
        }
    }
    if ((Test-Path -LiteralPath $migrationDirectory -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $migrationDirectory -Force -ErrorAction Stop | Select-Object -First 1)) {
        Remove-Item -LiteralPath $migrationDirectory -Force -ErrorAction Stop
    }
    $catalogDirectory = Split-Path -Parent $migrationDirectory
    if ((Test-Path -LiteralPath $catalogDirectory -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $catalogDirectory -Force -ErrorAction Stop | Select-Object -First 1)) {
        Remove-Item -LiteralPath $catalogDirectory -Force -ErrorAction Stop
    }
    if ((Test-Path -LiteralPath $targetParent -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $targetParent -Force -ErrorAction Stop | Select-Object -First 1)) {
        Remove-Item -LiteralPath $targetParent -Force -ErrorAction Stop
    }

    $remainingVM = Get-VM -Name "SqlLab-ParentMove-$token" -ErrorAction SilentlyContinue
    $remainingFiles = @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force -ErrorAction Stop)
    $remainingMap = @($remainingFiles | ForEach-Object {
        [PSCustomObject]@{
            RelativePath=[IO.Path]::GetRelativePath($sourceRoot, $_.FullName)
            Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $initialPaths = @($inventory.InitialFiles.RelativePath | Sort-Object)
    $remainingPaths = @($remainingMap.RelativePath | Sort-Object)
    $initialHashes = @($inventory.InitialFiles | Where-Object {
        [string]$_.RelativePath -ne 'Catalog\storage-locations.json'
    } | ForEach-Object { "$($_.RelativePath)|$($_.Sha256)" } | Sort-Object)
    $remainingHashes = @($remainingMap | Where-Object {
        [string]$_.RelativePath -ne 'Catalog\storage-locations.json'
    } | ForEach-Object { "$($_.RelativePath)|$($_.Sha256)" } | Sort-Object)
    $restoredLocation = & $module {
        param($LocationId, $Root)
        $configuration = Get-LabStorageConfiguration
        @($configuration.LabDataLocations | Where-Object {
            [string]$_.LocationId -eq $LocationId -and
            [string]::Equals([string]$_.LabDataRoot, $Root, [StringComparison]::OrdinalIgnoreCase)
        })
    } ([string]$inventory.LocationId) $sourceRoot
    if ($remainingVM -or @($restoredLocation).Count -ne 1 -or
        @(Compare-Object $initialPaths $remainingPaths).Count -ne 0 -or
        @(Compare-Object $initialHashes $remainingHashes).Count -ne 0) {
        throw 'HYPERV_STORAGE_PARENT_ACCEPTANCE_FINAL_CLEANUP_FAILED'
    }

    Write-Host 'PASS: Allgemeine Parent-Migration mit VM-Konfiguration, VHDX-Rebind, Rückmigration und Cleanup.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "RECOVERY_REQUIRED [$phase]: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Test-VM, aktueller Lab_Data-Root und Migrationsjournale bleiben für den journalisierten Recovery-Pfad erhalten.' -ForegroundColor Yellow
    exit 1
}
