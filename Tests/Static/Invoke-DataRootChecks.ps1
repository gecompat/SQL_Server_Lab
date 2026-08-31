#Requires -Version 7.2
[CmdletBinding()] param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$toolPath = Join-Path $repoRoot 'Tools/Initialize-SqlServerLabDataRoot.ps1'
$consolePath = Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1'
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryParent = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-data-root-$([guid]::NewGuid().ToString('N'))"
$temporaryRoot = Join-Path $temporaryParent 'Lab_Data'
$previousDataRoot = $env:SQL_SERVER_LAB_DATA_ROOT
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Data Root Checks' -ForegroundColor Cyan
try {
    $receipt = & $toolPath -RootPath $temporaryRoot -LabId evaluation-refresh
    Add-CheckResult -Name 'Zentraler Data Root wird ausserhalb von Run-State angelegt' -Success ($receipt.DataRoot -eq $temporaryRoot)
    $marker = Get-Content -LiteralPath (Join-Path $temporaryRoot '.sql-server-lab-root.json') -Raw -Encoding utf8 | ConvertFrom-Json
    Add-CheckResult -Name 'Data Root besitzt einen controllergebundenen Contract-2.0-Marker' -Success (
        $marker.ContractVersion -eq 'SqlServerLab.DataRoot/2.0' -and $marker.ManagedBy -eq 'SQL_Server_Lab' -and $marker.ControllerId
    )
    $storageConfiguration = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.Storage/2.0'; ControllerId = [string]$marker.ControllerId; DefaultDataRoot = $temporaryRoot
        LabDataLocations = @([PSCustomObject]@{ VolumeId=[string]$marker.VolumeId; DriveLetter=[System.IO.Path]::GetPathRoot($temporaryRoot); LabDataParent=$temporaryParent; LabDataRoot=$temporaryRoot })
    }
    $storageConfiguration | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'Catalog/storage-locations.json') -Encoding utf8NoBOM
    $env:SQL_SERVER_LAB_DATA_ROOT = $temporaryRoot
    foreach ($version in @('2019','2022','2025')) {
        Add-CheckResult -Name "SQL-$version-Datendateien sind versionsgetrennt" -Success (
            Test-Path -LiteralPath (Join-Path $temporaryRoot "Labs/evaluation-refresh/Versions/$version/Data")
        )
    }
    Add-CheckResult -Name 'Portable Full-Backup-Ebene wird pro Lab angelegt' -Success (
        Test-Path -LiteralPath (Join-Path $temporaryRoot 'Labs/evaluation-refresh/Backups/Full')
    )
    $rootReadme = Get-Content -LiteralPath (Join-Path $temporaryRoot 'README.md') -Raw -Encoding utf8
    Add-CheckResult -Name 'Lokale Anleitung beschreibt Evaluation-Refresh und Backup/Restore' -Success (
        $rootReadme -match 'Evaluation' -and $rootReadme -match 'Full-Backup' -and $rootReadme -match 'nicht rueckwaertskompatibel|nicht.*Downgrade'
    )
    $second = & $toolPath -RootPath $temporaryRoot -LabId evaluation-refresh
    Add-CheckResult -Name 'Data-Root-Initialisierung ist idempotent' -Success (
        @($second.CreatedDirectories).Count -eq 0 -and @($second.SkippedReadmeFiles).Count -eq 0
    )
    $consoleText = Get-Content -LiteralPath $consolePath -Raw -Encoding utf8
    $storageContractText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/StorageContract.ps1') -Raw -Encoding utf8
    $dataRootToolText = Get-Content -LiteralPath $toolPath -Raw -Encoding utf8
    Add-CheckResult -Name 'Konsolen-Neuanlage bietet den gespeicherten Data Root optional an' -Success (
        $consoleText -match 'Get-LabDataRootDefault' -and
        $consoleText -match 'SQL-System- und Datenbanken persistent im Data Root einbinden' -and
        $consoleText -match '\$newLabArguments\.PersistentData = \$true' -and
        $consoleText -match '\$newLabArguments\.DataRoot = \$defaultDataRoot' -and
        $consoleText -match "New-LabConsoleItem -Id 'storage' -Label 'Medien, Testdaten und Speicher'.+-Shortcut '5'" -and
        $consoleText -match "New-LabConsoleItem -Id 'DataRoot' -Label 'Lab_Data verwalten'.+-Shortcut 'd'" -and
        $consoleText -match "'DataRoot'\s*\{\s*Invoke-LabStorageInteractive" -and
        $consoleText -match 'Invoke-LabStorageInteractive'
    )
    Add-CheckResult -Name 'Storage-UI zeigt das normalisierte Ziel vor der bestätigten Mutation' -Success (
        $storageContractText -match 'Normalisiertes Ziel:' -and
        $storageContractText -match 'Diese Lab_Data-Location initialisieren und registrieren\?' -and
        $storageContractText -match 'Set-LabDataLocation\s+-LabDataParent\s+\$parent\s+-Confirm:\$false'
    )
    Add-CheckResult -Name 'Standalone-Initialisierung verwendet denselben nicht-administrativen Volume-GUID-Fallback' -Success (
        $dataRootToolText -match 'mountvol\.exe' -and $dataRootToolText -match "'/L'" -and
        $dataRootToolText -match 'Volume\\\{\[0-9A-Fa-f-\]\{36\}'
    )
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    if ($IsWindows) {
        $testDrive = [IO.Path]::GetPathRoot($temporaryRoot).Substring(0, 2).ToUpperInvariant()
        $mountvolPath = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\mountvol.exe'
        $expectedVolumeId = @(& $mountvolPath "$testDrive\" '/L' 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object {
            $_ -match '^\\\\\?\\Volume\{[0-9A-Fa-f-]{36}\}\\$'
        } | Select-Object -First 1)
        $resolvedVolume = & $module { param($root) Get-LabVolumeIdentity -Path $root } $temporaryRoot
        Add-CheckResult -Name 'Volume-Identität bleibt vor UAC über die Windows-Mountzuordnung stabil' -Success (
            $expectedVolumeId.Count -eq 1 -and [string]$resolvedVolume.VolumeId -eq [string]$expectedVolumeId[0]
        )
    }
    $legacyConfiguration = & $module { Get-LabStorageConfiguration }
    $legacyLocationId = [string]$legacyConfiguration.LabDataLocations[0].LocationId
    Add-CheckResult -Name 'Legacy-Storage-Katalog wird mit stabilem LocationId und erhaltener Default-Bindung gelesen' -Success (
        $legacyLocationId -match '^[0-9a-f-]{36}$' -and
        [string]$legacyConfiguration.DefaultLocationId -eq $legacyLocationId -and
        [string]$legacyConfiguration.DefaultDataRoot -eq $temporaryRoot -and
        [string]$legacyConfiguration.LegacyMigrationReceipt.Status -eq 'IN_MEMORY_UPGRADE' -and
        [bool]$legacyConfiguration.LegacyMigrationReceipt.DefaultPreserved
    )
    $persistentDriveContract = & $module {
        param($root)
        $storage = Get-LabPersistentInstanceStorage -DataRoot $root -LabName 'persistent-test' -Provider docker -InstanceId primary -SqlVersion 2025 -Create
        $instance = [PSCustomObject]@{ drives = @() }
        $null = Add-LabPersistentContainerDrive -Instance $instance -Storage $storage -IncludeExternalRuntimeState
        return $instance.drives
    } $temporaryRoot
    $sqlSystemDrive = @($persistentDriveContract | Where-Object id -eq 'persistent-mssql')[0]
    $backupDrive = @($persistentDriveContract | Where-Object id -eq 'persistent-backups')[0]
    Add-CheckResult -Name 'Container-SQL-System nutzt ein stabiles Runtime-Volume statt eines NTFS-Bind-Mounts' -Success (
        $sqlSystemDrive -and $sqlSystemDrive.containerPath -eq '/var/opt/mssql' -and
        $sqlSystemDrive.volumeName -match '^sql-lab-persistent-' -and -not $sqlSystemDrive.hostPath -and
        $sqlSystemDrive.persistence -eq 'data-root-runtime-volume'
    )
    Add-CheckResult -Name 'Persistente Container-Labs binden nur External-Artefakte, nicht LaunchPad-Arbeitszustand' -Success (
        @($persistentDriveContract | Where-Object containerPath -in @(
            '/var/opt/mssql-extensibility/externallanguages',
            '/var/opt/mssql-extensibility/externallibraries'
        )).Count -eq 2 -and
        @($persistentDriveContract | Where-Object containerPath -in @(
            '/var/opt/mssql-extensibility',
            '/var/opt/mssql-extensibility/data',
            '/var/opt/mssql-extensibility/sandboxes'
        )).Count -eq 0
    )
    Add-CheckResult -Name 'Container-Backups bleiben im sichtbaren Data Root eingebunden' -Success (
        $backupDrive -and $backupDrive.containerPath -eq '/var/opt/mssql/backup' -and
        $backupDrive.hostPath -eq (Join-Path $temporaryRoot 'Labs/persistent-test/Instances/docker/primary/SqlServer/2025/backups')
    )
    $runScopedDriveContract = & $module {
        $instance = [PSCustomObject]@{ drives = @([PSCustomObject]@{ id='data'; containerPath='/sqldata' }) }
        $null = Add-LabRunScopedContainerSystemDrive -Instance $instance -IncludeExternalRuntimeState
        $null = Add-LabRunScopedContainerSystemDrive -Instance $instance -IncludeExternalRuntimeState
        return $instance.drives
    }
    $runScopedSystemDrives = @($runScopedDriveContract | Where-Object containerPath -eq '/var/opt/mssql')
    Add-CheckResult -Name 'Kurzlebige Container-Labs behalten SQL-Systemdaten ueber einen Recreate' -Success (
        $runScopedSystemDrives.Count -eq 1 -and
        $runScopedSystemDrives[0].id -eq 'runtime-mssql' -and
        $runScopedSystemDrives[0].persistence -eq 'run-scoped-runtime-volume'
    )
    Add-CheckResult -Name 'Kurzlebige Container-Labs erhalten External-Artefakte ohne LaunchPad-Arbeitsverzeichnisse' -Success (
        @($runScopedDriveContract | Where-Object containerPath -in @(
            '/var/opt/mssql-extensibility/externallanguages',
            '/var/opt/mssql-extensibility/externallibraries'
        )).Count -eq 2 -and
        @($runScopedDriveContract | Where-Object containerPath -in @(
            '/var/opt/mssql-extensibility',
            '/var/opt/mssql-extensibility/data',
            '/var/opt/mssql-extensibility/sandboxes'
        )).Count -eq 0
    )

    $secondaryRoot = Join-Path (Join-Path $temporaryParent 'secondary') 'Lab_Data'
    & $module {
        $script:StorageContractTestSecondaryDrive = 'E:'
        Set-Item -Path Function:script:Get-LabVolumeIdentity -Value {
            param([Parameter(Mandatory)][string]$Path)
            $fullPath = [IO.Path]::GetFullPath($Path)
            $secondary = $fullPath -match '[\\/]secondary[\\/]'
            return [PSCustomObject]@{
                VolumeId = if ($secondary) { 'test-volume-secondary' } else { 'test-volume-primary' }
                DriveLetter = if ($secondary) { $script:StorageContractTestSecondaryDrive } else { 'D:' }
                VolumeRoot = [IO.Path]::GetPathRoot($fullPath)
            }
        }
        Set-Item -Path Function:script:Get-LabStorageTopology -Value {
            param([Parameter(Mandatory)][string]$Path, $VolumeIdentity)
            return [PSCustomObject]@{
                BackingDeviceIds = @("device-$($VolumeIdentity.VolumeId)")
                TopologyStatus = 'Proven'; MediaType = 'SSD'; BusType = 'NVMe'
                HealthStatus = 'Healthy'; FreeBytes = [long]1TB
            }
        }
        Set-Item -Path Function:script:Get-LabActiveRuns -Value { return @() }
        Set-Item -Path Function:script:Get-LabHyperVHardDiskDriveInventory -Value { return @() }
    }
    $primaryBeforeRegistration = & $module { Get-LabStorageConfiguration }
    $primaryLocationId = [string]$primaryBeforeRegistration.LabDataLocations[0].LocationId
    $controllerId = [string]$primaryBeforeRegistration.ControllerId
    & $module {
        param($root, $controller)
        $null = Initialize-LabManagedDataRoot -DataRoot $root -ControllerId $controller -Confirm:$false
        $null = Register-LabDataRoot -DataRoot $root
    } $secondaryRoot $controllerId
    $registeredConfiguration = & $module { Get-LabStorageConfiguration }
    $secondaryLocation = @($registeredConfiguration.LabDataLocations | Where-Object LabDataRoot -eq $secondaryRoot)[0]
    Add-CheckResult -Name 'Zusätzliche Location ändert den bestehenden Default nicht implizit' -Success (
        @($registeredConfiguration.LabDataLocations).Count -eq 2 -and
        [string]$registeredConfiguration.DefaultLocationId -eq $primaryLocationId -and
        [string]$registeredConfiguration.DefaultDataRoot -eq $temporaryRoot
    )
    Add-CheckResult -Name 'Storage-Registry persistiert Topologiebeleg und Legacy-Migrationsreceipt auf allen Roots' -Success (
        [string]$secondaryLocation.TopologyStatus -eq 'Proven' -and
        @($secondaryLocation.BackingDeviceIds) -contains 'device-test-volume-secondary' -and
        [string]$registeredConfiguration.LegacyMigrationReceipt.Status -eq 'PERSISTED' -and
        (Test-Path -LiteralPath (Join-Path $secondaryRoot 'Catalog/storage-locations.json') -PathType Leaf)
    )
    $storageCatalogJson = Get-Content -LiteralPath (Join-Path $secondaryRoot 'Catalog/storage-locations.json') -Raw -Encoding utf8
    Add-CheckResult -Name 'Persistierter Storage-Katalog erfüllt das aktuelle JSON-Schema' -Success (
        $storageCatalogJson | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-storage-contract.schema.json') -ErrorAction SilentlyContinue
    )
    $driveRelativeRejected = try { & $module { Resolve-LabStorageParentPath -Path 'D:' }; $false } catch { $_.Exception.Message -match 'LAB_STORAGE_PARENT_NOT_FULLY_QUALIFIED' }
    Add-CheckResult -Name 'Drive-relative Eingabe D: wird abgewiesen' -Success $driveRelativeRejected

    & $module { $script:StorageContractTestSecondaryDrive = 'Z:' }
    $afterDriveLetterChange = & $module { Get-LabStorageConfiguration }
    $secondaryAfterDriveLetterChange = @($afterDriveLetterChange.LabDataLocations | Where-Object LabDataRoot -eq $secondaryRoot)[0]
    Add-CheckResult -Name 'LocationId bleibt bei geändertem Laufwerksbuchstaben stabil' -Success (
        [string]$secondaryAfterDriveLetterChange.LocationId -eq [string]$secondaryLocation.LocationId -and
        [string]$secondaryAfterDriveLetterChange.DriveLetter -eq 'Z:'
    )

    $metadataLocationId = [string]$secondaryLocation.LocationId
    $null = & $module {
        param($id)
        Set-LabDataLocationMetadata -LocationId $id -DisplayName 'Schnelle Daten' -Selectors @('DATA-FAST','temp-01') -Confirm:$false
    } $metadataLocationId
    $afterMetadata = & $module { param($root) Get-LabStorageConfiguration -DataRoot $root } $temporaryRoot
    $secondaryAfterMetadata = @($afterMetadata.LabDataLocations | Where-Object { [string]$_.LocationId -eq $metadataLocationId })[0]
    Add-CheckResult -Name 'Anzeigename und portable Selektoren werden normalisiert und persistiert' -Success (
        [string]$secondaryAfterMetadata.DisplayName -eq 'Schnelle Daten' -and
        @($secondaryAfterMetadata.Selectors).Count -eq 2 -and
        @($secondaryAfterMetadata.Selectors) -contains 'data-fast' -and
        @($secondaryAfterMetadata.Selectors) -contains 'temp-01'
    ) -Message ("DisplayName={0}; Selectors={1}" -f $secondaryAfterMetadata.DisplayName, (@($secondaryAfterMetadata.Selectors) -join ','))
    $selectorConflictRejected = try {
        & $module { param($id) Set-LabDataLocationMetadata -LocationId $id -DisplayName 'Konflikt' -Selectors @('data-fast') -Confirm:$false } $primaryLocationId
        $false
    } catch { $_.Exception.Message -match 'LAB_STORAGE_SELECTOR_NOT_UNIQUE' }
    Add-CheckResult -Name 'Portable Selektoren bleiben registry-weit eindeutig' -Success $selectorConflictRejected

    $secondaryLocationId = [string]$secondaryLocation.LocationId
    $null = & $module { param($id) Set-LabDefaultDataLocation -LocationId $id -ProcessEnvironmentOnly -Confirm:$false } $secondaryLocationId
    $afterDefaultSwitch = & $module { param($root) Get-LabStorageConfiguration -DataRoot $root } $temporaryRoot
    Add-CheckResult -Name 'Default-Wechsel erfolgt nur über die explizite LocationId-Aktion' -Success (
        [string]$afterDefaultSwitch.DefaultLocationId -eq $secondaryLocationId -and
        [string]$afterDefaultSwitch.DefaultDataRoot -eq $secondaryRoot -and
        [string]$env:SQL_SERVER_LAB_DATA_ROOT -eq $secondaryRoot
    )
    $defaultRemovalRejected = try { & $module { param($id) Unregister-LabDataLocation -LocationId $id -Confirm:$false } $secondaryLocationId; $false } catch { $_.Exception.Message -match 'LAB_STORAGE_DEFAULT_LOCATION_PROTECTED' }
    Add-CheckResult -Name 'Default-Location kann nicht deregistriert werden' -Success $defaultRemovalRejected

    & $module {
        Set-Item -Path Function:script:Get-LabDataLocationReferences -Value {
            return @([PSCustomObject]@{ Kind='run'; Id='referenced-test-run' })
        }
    }
    $referencedRemovalRejected = try { & $module { param($id) Unregister-LabDataLocation -LocationId $id -Confirm:$false } $primaryLocationId; $false } catch { $_.Exception.Message -match 'LAB_STORAGE_LOCATION_REFERENCED.*referenced-test-run' }
    Add-CheckResult -Name 'Noch referenzierte Nicht-Default-Location bleibt geschützt' -Success $referencedRemovalRejected
    & $module { Set-Item -Path Function:script:Get-LabDataLocationReferences -Value { return @() } }
    $removed = & $module { param($id) Unregister-LabDataLocation -LocationId $id -Confirm:$false } $primaryLocationId
    $removedRootCatalog = Get-Content -LiteralPath (Join-Path $temporaryRoot 'Catalog/storage-locations.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    Add-CheckResult -Name 'Unreferenzierte Location wird registry-only und ohne veralteten Root-Katalog deregistriert' -Success (
        $removed -and @($removedRootCatalog.LabDataLocations).Count -eq 1 -and
        [string]$removedRootCatalog.DefaultLocationId -eq $secondaryLocationId -and
        (Test-Path -LiteralPath $temporaryRoot -PathType Container)
    )
}
catch { Add-CheckResult -Name 'Data-Root-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally {
    $env:SQL_SERVER_LAB_DATA_ROOT = $previousDataRoot
    if (Test-Path -LiteralPath $temporaryParent) { Remove-Item -LiteralPath $temporaryParent -Recurse -Force }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0



