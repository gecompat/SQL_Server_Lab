#Requires -Version 7.2
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryParent = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-storage-migration-$([Guid]::NewGuid().ToString('N'))"
$sourceRoot = Join-Path (Join-Path $temporaryParent 'source') 'Lab_Data'
$targetParent = Join-Path $temporaryParent 'target'
$targetRoot = Join-Path $targetParent 'Lab_Data'
$previousDataRoot = $env:SQL_SERVER_LAB_DATA_ROOT
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Storage Migration Checks' -ForegroundColor Cyan

try {
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    & $module {
        Set-Item -Path Function:script:Get-LabHyperVHardDiskDriveInventory -Value { return @() }
    }
    $storageContractText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\StorageContract.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Hyper-V-Diskinventur übergibt den verpflichtenden VM-Namen' -Success (
        $storageContractText -match 'Get-VMHardDiskDrive\s+-VMName\s+'
    )
    $setup = & $module {
        param($source)
        $marker = Initialize-LabManagedDataRoot -DataRoot $source -Confirm:$false
        $volume = Get-LabVolumeIdentity -Path $source
        $configuration = [PSCustomObject]@{
            ContractVersion='SqlServerLab.Storage/2.0'; ControllerId=[string]$marker.ControllerId; DefaultDataRoot=$source
            LabDataLocations=@([PSCustomObject]@{ VolumeId=$volume.VolumeId; DriveLetter=$volume.DriveLetter; LabDataParent=(Split-Path -Parent $source); LabDataRoot=$source })
        }
        Write-LabArtifactJsonAtomic -Path (Join-Path (Join-Path $source 'Catalog') 'storage-locations.json') -InputObject $configuration
        return $configuration
    } $sourceRoot
    $env:SQL_SERVER_LAB_DATA_ROOT = $sourceRoot
    $payloadPath = Join-Path $sourceRoot 'Labs/sample/payload.txt'
    $payloadDirectory = Split-Path -Parent $payloadPath
    New-Item -Path $payloadDirectory -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath $payloadPath -Value 'storage-migration-contract' -Encoding utf8NoBOM
    $referencePath = Join-Path $sourceRoot 'Catalog/reference.json'
    [PSCustomObject]@{ dataRoot=$sourceRoot; payload=$payloadPath } | ConvertTo-Json | Set-Content -LiteralPath $referencePath -Encoding utf8NoBOM
    $sourceHash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash

    $migrationContract = & $module {
        param($source, $targetParentPath)
        $plan = New-LabDataMigrationPlan -SourceDataRoot $source -TargetParent $targetParentPath
        if ($plan.Plan.Status -ne 'READY') { throw "Plan ist blockiert: $(@($plan.Plan.Blockers) -join ', ')" }
        $result = Invoke-LabDataMigration -PlanPath $plan.Path -ProcessEnvironmentOnly -Confirm:$false
        return [PSCustomObject]@{ Plan=$plan.Plan; Result=$result }
    } $sourceRoot $targetParent
    $result = $migrationContract.Result

    Add-CheckResult -Name 'Journalisierte Storage-Migration wird abgeschlossen' -Success ($result.Status -eq 'COMPLETED')
    Add-CheckResult -Name 'Storage-Migrationsplan erfüllt das aktuelle JSON-Schema' -Success (
        ($migrationContract.Plan | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-storage-migration-plan.schema.json') -ErrorAction SilentlyContinue
    )
    Add-CheckResult -Name 'Parent-Migration bindet Quelle und Ziel an dieselbe stabile LocationId' -Success (
        [string]$migrationContract.Plan.Source.LocationId -match '^[0-9a-f-]{36}$' -and
        [string]$migrationContract.Plan.Source.LocationId -eq [string]$migrationContract.Plan.Target.LocationId
    )
    Add-CheckResult -Name 'Migrierte Nutzdatei ist hashidentisch' -Success (
        (Test-Path -LiteralPath (Join-Path $targetRoot 'Labs/sample/payload.txt') -PathType Leaf) -and
        (Get-FileHash -LiteralPath (Join-Path $targetRoot 'Labs/sample/payload.txt') -Algorithm SHA256).Hash -eq $sourceHash
    )
    $reference = Get-Content -LiteralPath (Join-Path $targetRoot 'Catalog/reference.json') -Raw -Encoding utf8 | ConvertFrom-Json
    Add-CheckResult -Name 'Absolute JSON-Referenzen zeigen auf den Zielroot' -Success (
        [string]$reference.dataRoot -eq $targetRoot -and [string]$reference.payload -eq (Join-Path $targetRoot 'Labs/sample/payload.txt')
    )
    $storage = Get-Content -LiteralPath (Join-Path $targetRoot 'Catalog/storage-locations.json') -Raw -Encoding utf8 | ConvertFrom-Json
    Add-CheckResult -Name 'Storage-Katalog wird erst auf den Zielroot umgeschaltet' -Success (
        [string]$storage.DefaultDataRoot -eq $targetRoot -and
        [string]$storage.DefaultLocationId -eq [string]$migrationContract.Plan.Source.LocationId -and
        @($storage.LabDataLocations | Where-Object {
            $_.LabDataRoot -eq $targetRoot -and $_.LocationId -eq $migrationContract.Plan.Source.LocationId
        }).Count -eq 1
    )
    Add-CheckResult -Name 'ProcessEnvironmentOnly schreibt keine persistente Projektpräferenz' -Success (
        -not (Test-Path -LiteralPath (Join-Path $targetRoot 'Catalog/preferences.json') -PathType Leaf)
    )
    $journal = Get-Content -LiteralPath $result.JournalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    Add-CheckResult -Name 'Storage-Migrationsjournal erfüllt das aktuelle JSON-Schema' -Success (
        (Get-Content -LiteralPath $result.JournalPath -Raw -Encoding utf8) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-storage-migration-journal.schema.json') -ErrorAction SilentlyContinue
    )
    Add-CheckResult -Name 'Abschlussjournal bleibt mit Location-Bindung am Ziel erhalten' -Success (
        $journal.Status -eq 'COMPLETED' -and $journal.PlanSha256 -match '^[a-f0-9]{64}$' -and
        [string]$journal.LocationId -eq [string]$migrationContract.Plan.Source.LocationId
    )
    Add-CheckResult -Name 'Verifizierter leerer Quellroot wird entfernt' -Success (-not (Test-Path -LiteralPath $sourceRoot))
}
catch { Add-CheckResult -Name 'Storage-Migration-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally {
    $env:SQL_SERVER_LAB_DATA_ROOT = $previousDataRoot
    if (Test-Path -LiteralPath $temporaryParent) { Remove-Item -LiteralPath $temporaryParent -Recurse -Force }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
