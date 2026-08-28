#Requires -Version 7.2
[CmdletBinding()] param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArgs)

if ($ShowHelp -or @($RemainingArgs) -match '^(/\?|-\?|-h|--help)$') {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryParent = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-storage-plan-$([Guid]::NewGuid().ToString('N'))"
$ownedRoot = Join-Path $temporaryParent 'Lab_Data'
$failures = [Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Storage File Placement Checks' -ForegroundColor Cyan

try {
    $module = Import-Module $modulePath -Force -PassThru
    $controllerId = [Guid]::NewGuid().ToString('D')
    $selectorNames = @('data-fast','log-durable','backup-capacity','temp-01','temp-02','temp-03','temp-04','temp-log')
    $locations = for ($index = 0; $index -lt $selectorNames.Count; $index++) {
        [PSCustomObject]@{
            LocationId = [Guid]::NewGuid().ToString('D')
            VolumeId = "volume-$index"
            DriveLetter = "$('D'..'K' | Select-Object -Index $index):"
            LabDataParent = if ($index -eq 0) { $temporaryParent } else { Join-Path $temporaryParent "Storage$index" }
            LabDataRoot = if ($index -eq 0) { $ownedRoot } else { Join-Path (Join-Path $temporaryParent "Storage$index") 'Lab_Data' }
            DisplayName = "Storage $index"
            Selectors = @($selectorNames[$index])
            BackingDeviceIds = @("device-$index")
            TopologyStatus = 'Proven'
            MediaType = 'SSD'; BusType = 'NVMe'; HealthStatus = 'Healthy'; FreeBytes = [long]1TB
        }
    }
    $configuration = [PSCustomObject]@{
        ContractVersion='SqlServerLab.Storage/2.0'; ControllerId=$controllerId
        DefaultLocationId=[string]$locations[0].LocationId; DefaultDataRoot=$ownedRoot
        LabDataLocations=$locations; LegacyMigrationReceipt=$null
    }
    $intent = [PSCustomObject]@{
        contractVersion='SqlServerLab.StorageIntent/1.0'; placementPolicy='explicit'; physicalIsolation='required'
        roles=[PSCustomObject]@{
            defaultData=[PSCustomObject]@{ selector='data-fast' }
            defaultLog=[PSCustomObject]@{ selector='log-durable' }
            backup=[PSCustomObject]@{ selector='backup-capacity' }
        }
        tempDb=[PSCustomObject]@{
            distribution='one-file-per-physical-device'; dataFileCount=4
            dataLocationSelectors=@('temp-01','temp-02','temp-03','temp-04')
            dataFiles=@(
                [PSCustomObject]@{ logicalName='tempdev'; fileName='tempdev.mdf'; selector='temp-01'; sizeMB=256; growth='64MB' }
                [PSCustomObject]@{ logicalName='temp2'; fileName='temp2.ndf'; selector='temp-02'; sizeMB=256; growth='64MB' }
                [PSCustomObject]@{ logicalName='temp3'; fileName='temp3.ndf'; selector='temp-03'; sizeMB=256; growth='64MB' }
                [PSCustomObject]@{ logicalName='temp4'; fileName='temp4.ndf'; selector='temp-04'; sizeMB=256; growth='64MB' }
            )
            logPlacement=[PSCustomObject]@{ selector='temp-log'; logicalName='templog'; fileName='templog.ldf'; sizeMB=256; growth='64MB' }
        }
        databaseFiles=@(
            [PSCustomObject]@{ database='AppDb'; logicalName='AppDb'; fileType='data'; fileName='AppDb.mdf'; selector='data-fast' }
            [PSCustomObject]@{ database='AppDb'; logicalName='AppDb_log'; fileType='log'; fileName='AppDb_log.ldf'; selector='log-durable' }
        )
        restoreRules=@([PSCustomObject]@{ database='RestoreDb'; dataSelector='data-fast'; logSelector='log-durable' })
    }

    $intentJson = $intent | ConvertTo-Json -Depth 30
    Add-CheckResult -Name 'Portabler Storage-Intent erfüllt das eigenständige Schema' -Success (
        $intentJson | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-storage-intent.schema.json') -ErrorAction SilentlyContinue)

    $beforeFiles = @(Get-ChildItem -LiteralPath $temporaryParent -Recurse -File -ErrorAction SilentlyContinue).Count
    $runId = [Guid]::NewGuid().ToString('D')
    $plan = & $module { param($i,$r,$c) New-LabStorageBoundPlan -StorageIntent $i -RunId $r -LabName 'placement-test' -InstanceId 'sql01' -Provider hyperv -StorageConfiguration $c } $intent $runId $configuration
    $afterFiles = @(Get-ChildItem -LiteralPath $temporaryParent -Recurse -File -ErrorAction SilentlyContinue).Count
    Add-CheckResult -Name 'Planung bleibt read-only' -Success ($beforeFiles -eq $afterFiles)
    Add-CheckResult -Name 'Physisch getrennte Hyper-V-Planung ist READY mit Topologie-PASS' -Success (
        $plan.Status -eq 'READY' -and $plan.TopologyEvidence.Status -eq 'PASS' -and @($plan.Blockers).Count -eq 0)
    $tempDataFiles = @($plan.SqlFiles | Where-Object Role -eq 'tempdb-data')
    $tempBindings = @($tempDataFiles | ForEach-Object { $file=$_; $plan.Bindings | Where-Object LocationId -eq $file.LocationId | Select-Object -First 1 })
    Add-CheckResult -Name 'Vier TempDB-Dateien binden vier Volumes und vier Backing Devices' -Success (
        $tempDataFiles.Count -eq 4 -and @($tempBindings.VolumeId | Sort-Object -Unique).Count -eq 4 -and
        @($tempBindings.BackingDeviceIds | Sort-Object -Unique).Count -eq 4)
    Add-CheckResult -Name 'Bound Plan enthält alle Rollen und einzeln prüfbare Gastpfade' -Success (
        @($plan.SqlFiles).Count -eq 12 -and @($plan.SqlFiles | Where-Object { -not $_.GuestPath }).Count -eq 0 -and
        @($plan.SqlFiles.Role | Sort-Object -Unique).Count -eq 9 -and
        @($tempDataFiles | Where-Object { $_.SizeMB -ne 256 -or $_.Growth -ne '64MB' }).Count -eq 0)
    Add-CheckResult -Name 'Bound Plan erfüllt sein JSON-Schema' -Success (
        ($plan | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-storage-bound-plan.schema.json') -ErrorAction SilentlyContinue)

    $hyperVDrives = & $module { param($p) ConvertTo-LabHyperVStorageDrivePlan -Plan $p } $plan
    Add-CheckResult -Name 'Jede lokale Storage-Bindung erzeugt genau eine externe Hyper-V-Lane' -Success (
        @($hyperVDrives).Count -eq @($plan.Bindings).Count -and
        @($hyperVDrives.id | Sort-Object -Unique).Count -eq @($hyperVDrives).Count -and
        @($hyperVDrives | Where-Object { -not $_.hostRoot -or -not $_.hostPath -or $_.sizeBytes -lt 4GB }).Count -eq 0 -and
        @($hyperVDrives | Where-Object vhdType -ne 'dynamic').Count -eq 0)

    $mockDriveReceipts = @($hyperVDrives | ForEach-Object {
        [PSCustomObject]@{ id=$_.id; diskIdentifier="guest-$($_.id)"; guestPath=$_.guestPath }
    })
    $mockManagedDrives = @($hyperVDrives | ForEach-Object {
        [PSCustomObject]@{ id=$_.id; diskIdentifier="vhdx-$($_.id)"; path=(Join-Path $_.hostPath "$($_.id).vhdx") }
    })
    $runtimePlan = & $module { param($p,$r,$m) Resolve-LabStorageRuntimeSqlPlan -Plan $p -DriveReceipts $r -ManagedDrives $m } $plan $mockDriveReceipts $mockManagedDrives
    $sqlApplyQuery = & $module { param($f) New-LabStorageSqlApplyQuery -SqlFiles $f } @($runtimePlan.SqlFiles)
    Add-CheckResult -Name 'Runtime-Plan verbindet Host-VHDX, Gastdisk und jede SQL-Datei lückenlos' -Success (
        @($runtimePlan.SqlFiles).Count -eq @($plan.SqlFiles).Count -and
        @($runtimePlan.SqlFiles | Where-Object { -not $_.HostPath -or -not $_.RuntimeStorageId -or -not $_.GuestDiskId -or -not $_.SqlPhysicalPath }).Count -eq 0)
    Add-CheckResult -Name 'SQL-Anwendungsplan enthält Defaultpfade, vollständigen TempDB-Plan und Extra-File-Abgleich' -Success (
        $sqlApplyQuery -match 'xp_instance_regwrite' -and $sqlApplyQuery -match "N'DefaultData'" -and
        $sqlApplyQuery -match "N'DefaultLog'" -and $sqlApplyQuery -match "N'BackupDirectory'" -and
        ([regex]::Matches($sqlApplyQuery, 'ALTER DATABASE tempdb')).Count -ge 5 -and $sqlApplyQuery -match 'REMOVE FILE')

    $runtimeReceiptDirectory = Join-Path $temporaryParent 'runtime-receipt'
    $null = New-Item -Path $runtimeReceiptDirectory -ItemType Directory -Force
    $verifiedRuntimeReceipt = & $module {
        param($p,$r,$m,$directory)
        function Get-HyperVLabWorkflowRun {
            [PSCustomObject]@{
                RunDirectory=$directory; StateRoot=$directory
                Run=[PSCustomObject]@{ runId=[string]$p.RunId; scopeId=[Guid]::NewGuid().ToString('D') }
                Instance=[PSCustomObject]@{ vmName='storage-runtime-mock' }
            }
        }
        function Get-HyperVManagedVM { [PSCustomObject]@{ Identity=[PSCustomObject]@{ guestDriveInitialization=$r; additionalDrives=$m } } }
        function Invoke-HyperVPowerShellDirect { [PSCustomObject]@{ Status='VERIFIED'; ServiceStatus='Running'; DefaultPaths='PASS'; TempDb='PASS'; ObservedAt=[datetime]::UtcNow.ToString('o') } }
        $password=New-HyperVSqlUnattendedPassword
        Invoke-HyperVLabStoragePlan -RunId ([string]$p.RunId) -Plan $p -Credential ([PSCredential]::new('Administrator',$password)) -SqlSaPassword $password
    } $plan $mockDriveReceipts $mockManagedDrives $runtimeReceiptDirectory
    Add-CheckResult -Name 'Runtime-Anwendung schreibt erst APPLYING und endet nur mit vollständigem VERIFIED-Receipt' -Success (
        $verifiedRuntimeReceipt.Status -eq 'VERIFIED' -and $verifiedRuntimeReceipt.Recovery.Status -eq 'NOT_REQUIRED' -and
        @($verifiedRuntimeReceipt.Postconditions | Where-Object Status -ne 'PASS').Count -eq 0 -and
        ((Get-Content -LiteralPath (Join-Path $runtimeReceiptDirectory 'storage-runtime-receipt.json') -Raw -Encoding utf8) |
            Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-storage-runtime-receipt.schema.json') -ErrorAction SilentlyContinue))
    $recoveryReceiptDirectory = Join-Path $temporaryParent 'runtime-recovery'
    $null = New-Item -Path $recoveryReceiptDirectory -ItemType Directory -Force
    $recoveryThrown = try {
        $null = & $module {
            param($p,$r,$m,$directory)
            function Get-HyperVLabWorkflowRun { [PSCustomObject]@{ RunDirectory=$directory; StateRoot=$directory; Run=[PSCustomObject]@{ runId=[string]$p.RunId; scopeId=[Guid]::NewGuid().ToString('D') }; Instance=[PSCustomObject]@{ vmName='storage-recovery-mock' } } }
            function Get-HyperVManagedVM { [PSCustomObject]@{ Identity=[PSCustomObject]@{ guestDriveInitialization=$r; additionalDrives=$m } } }
            function Invoke-HyperVPowerShellDirect { throw 'SQL_STORAGE_TEMPDB_POSTCONDITION_FAILED_tempdev sensitive-detail' }
            $password=New-HyperVSqlUnattendedPassword
            Invoke-HyperVLabStoragePlan -RunId ([string]$p.RunId) -Plan $p -Credential ([PSCredential]::new('Administrator',$password)) -SqlSaPassword $password
        } $plan $mockDriveReceipts $mockManagedDrives $recoveryReceiptDirectory
        $false
    }
    catch { $true }
    $recoveryReceipt = Get-Content -LiteralPath (Join-Path $recoveryReceiptDirectory 'storage-runtime-receipt.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    Add-CheckResult -Name 'Fehler hinterlassen ein schema-valides, sanitisiertes Recovery-Receipt' -Success (
        $recoveryThrown -and $recoveryReceipt.Status -eq 'RECOVERY_REQUIRED' -and
        $recoveryReceipt.Recovery.Status -eq 'RETRY_APPLY' -and
        $recoveryReceipt.Recovery.ErrorCode -eq 'SQL_STORAGE_TEMPDB_POSTCONDITION_FAILED' -and
        (($recoveryReceipt | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-storage-runtime-receipt.schema.json') -ErrorAction SilentlyContinue)) `
        -Message ($recoveryReceipt | ConvertTo-Json -Compress -Depth 8)

    $reorderedIntent = $intent | Select-Object restoreRules,databaseFiles,tempDb,roles,physicalIsolation,placementPolicy,contractVersion
    $hashes = & $module { param($a,$b) @((Get-LabStorageIntentSha256 $a),(Get-LabStorageIntentSha256 $b)) } $intent $reorderedIntent
    Add-CheckResult -Name 'Intent-Hash ist unabhängig von der Property-Reihenfolge' -Success ($hashes[0] -eq $hashes[1])

    $overlapConfiguration = $configuration | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $overlapConfiguration.LabDataLocations[4].BackingDeviceIds = @('device-3')
    $overlapPlan = & $module { param($i,$r,$c) New-LabStorageBoundPlan -StorageIntent $i -RunId $r -LabName lab -InstanceId sql01 -Provider hyperv -StorageConfiguration $c } $intent $runId $overlapConfiguration
    Add-CheckResult -Name 'Überlappende Backing Devices blockieren physische Verteilung' -Success (
        $overlapPlan.Status -eq 'BLOCKED' -and @($overlapPlan.Blockers) -match '^STORAGE_BACKING_DEVICE_OVERLAP:')

    $unknownConfiguration = $configuration | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $unknownConfiguration.LabDataLocations[3].TopologyStatus = 'Unknown'
    $unknownConfiguration.LabDataLocations[3].BackingDeviceIds = @()
    $unknownPlan = & $module { param($i,$r,$c) New-LabStorageBoundPlan -StorageIntent $i -RunId $r -LabName lab -InstanceId sql01 -Provider hyperv -StorageConfiguration $c } $intent $runId $unknownConfiguration
    Add-CheckResult -Name 'Unbekannte physische Topologie ist fail-closed' -Success (
        $unknownPlan.Status -eq 'BLOCKED' -and $unknownPlan.TopologyEvidence.Status -eq 'UNKNOWN' -and
        @($unknownPlan.Blockers) -contains 'TEMPDB_PHYSICAL_TOPOLOGY_UNKNOWN')

    $dockerPlan = & $module { param($i,$r,$c) New-LabStorageBoundPlan -StorageIntent $i -RunId $r -LabName lab -InstanceId sql01 -Provider docker -StorageConfiguration $c } $intent $runId $configuration
    Add-CheckResult -Name 'Container versprechen keine physische Device-Trennung' -Success (
        $dockerPlan.Status -eq 'BLOCKED' -and @($dockerPlan.Blockers) -contains 'PROVIDER_PHYSICAL_STORAGE_UNSUPPORTED')

    $logicalIntent = $intent | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $logicalIntent.physicalIsolation = 'not-required'; $logicalIntent.tempDb.distribution = 'round-robin'; $logicalIntent.tempDb.PSObject.Properties.Remove('dataFiles')
    $logicalPlan = & $module { param($i,$r,$c) New-LabStorageBoundPlan -StorageIntent $i -RunId $r -LabName lab -InstanceId sql01 -Provider docker -StorageConfiguration $c } $logicalIntent $runId $unknownConfiguration
    Add-CheckResult -Name 'Logische Container-Verteilung bleibt ohne physischen Anspruch planbar' -Success (
        $logicalPlan.Status -eq 'READY' -and $logicalPlan.TopologyEvidence.Status -eq 'NOT_REQUIRED')

    $invalidIntent = $intent | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $invalidIntent.tempDb.distribution = 'explicit'; $invalidIntent.tempDb.dataFiles = @($invalidIntent.tempDb.dataFiles | Select-Object -First 3)
    $invalidRejected = try { & $module { param($i) Assert-LabStorageIntent $i } $invalidIntent; $false } catch { $_.Exception.Message -match 'EXPLICIT_FILE_COUNT_MISMATCH' }
    Add-CheckResult -Name 'Explizite TempDB-Dateianzahl wird semantisch geprüft' -Success $invalidRejected

    $null = & $module { param($root,$controller) Initialize-LabManagedDataRoot -DataRoot $root -ControllerId $controller -Confirm:$false } $ownedRoot $controllerId
    $null = & $module { param($c) Write-LabStorageConfiguration -Configuration $c } $configuration
    $ownedDriveIntent = @($hyperVDrives | Where-Object { [string]$_.hostRoot -eq $ownedRoot }) | Select-Object -First 1
    $externalProviderPlan = & $module {
        param($drive,$runDirectory)
        Resolve-HyperVAdditionalDrivePlan -AdditionalDrives @($drive) -ResourceRoot (Join-Path $runDirectory 'resources/hyperv') `
            -VMName 'storage-owned-static' -RunDirectory $runDirectory
    } $ownedDriveIntent (Join-Path $temporaryParent 'provider-run')
    $unownedProviderRejected = try {
        $foreignDrive = $ownedDriveIntent | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
        $foreignDrive.hostRoot = Join-Path $temporaryParent 'foreign-root'
        $foreignDrive.hostPath = Join-Path $foreignDrive.hostRoot 'Labs/lab/Instances/hyperv/sql01/Storage/data-fast'
        $null = & $module {
            param($drive,$runDirectory)
            Resolve-HyperVAdditionalDrivePlan -AdditionalDrives @($drive) -ResourceRoot (Join-Path $runDirectory 'resources/hyperv') `
                -VMName 'storage-foreign-static' -RunDirectory $runDirectory
        } $foreignDrive (Join-Path $temporaryParent 'provider-run')
        $false
    }
    catch { $_.Exception.Message -match 'HOST_BINDING_NOT_OWNED' }
    Add-CheckResult -Name 'Provider akzeptiert externe VHDX nur unter registriertem controller-eigenem Root' -Success (
        @($externalProviderPlan).Count -eq 1 -and [string]$externalProviderPlan[0].HostRoot -eq $ownedRoot -and
        ([string]$externalProviderPlan[0].Path).StartsWith([string]$ownedDriveIntent.hostPath,[StringComparison]::OrdinalIgnoreCase) -and
        $unownedProviderRejected)
    $cleanupRunDirectory = Join-Path $temporaryParent 'cleanup-run'
    $null = New-Item -Path $cleanupRunDirectory -ItemType Directory -Force
    $null = & $module { param($path,$id) Write-LabArtifactJsonAtomic -Path $path -InputObject ([PSCustomObject]@{ runId=$id }) } `
        (Join-Path $cleanupRunDirectory 'run-state.json') $runId
    $runPrefix = $runId.Replace('-','').Substring(0,8).ToLowerInvariant()
    $ownedVhdxDirectory = [string]$ownedDriveIntent.hostPath
    $null = New-Item -Path $ownedVhdxDirectory -ItemType Directory -Force
    $ownedVhdxPath = Join-Path $ownedVhdxDirectory "placement-test-$runPrefix-sfp-02.vhdx"
    $foreignRunVhdxPath = Join-Path $ownedVhdxDirectory 'placement-test-deadbeef-sfp-02.vhdx'
    $null = New-Item -Path $ownedVhdxPath -ItemType File -Force
    $null = New-Item -Path $foreignRunVhdxPath -ItemType File -Force
    $null = & $module {
        param($path,$runDirectory,$root)
        function Get-VM { @() }
        Remove-HyperVVhdxForCleanup -Path $path -ExpectedRunDirectory $runDirectory -SafetyRoot $root
    } $ownedVhdxPath $cleanupRunDirectory $ownedRoot
    $foreignRunCleanupRejected = try {
        $null = & $module {
            param($path,$runDirectory,$root)
            function Get-VM { @() }
            Remove-HyperVVhdxForCleanup -Path $path -ExpectedRunDirectory $runDirectory -SafetyRoot $root
        } $foreignRunVhdxPath $cleanupRunDirectory $ownedRoot
        $false
    }
    catch { $_.Exception.Message -match 'HYPERV_RESOURCE_SCOPE_VIOLATION' }
    Add-CheckResult -Name 'Externer VHDX-Cleanup ist zusätzlich an die Run-ID im Dateinamen gebunden' -Success (
        -not (Test-Path -LiteralPath $ownedVhdxPath) -and $foreignRunCleanupRejected -and
        (Test-Path -LiteralPath $foreignRunVhdxPath -PathType Leaf))
    $savedPath = & $module { param($p,$root) Save-LabStorageBoundPlan -Plan $p -DataRoot $root -Confirm:$false } $plan $ownedRoot
    Add-CheckResult -Name 'Explizites Speichern schreibt nur in einen verwalteten Root' -Success (
        (Test-Path -LiteralPath $savedPath -PathType Leaf) -and
        ((Get-Content -LiteralPath $savedPath -Raw -Encoding utf8) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-storage-bound-plan.schema.json') -ErrorAction SilentlyContinue))
    $unownedRejected = try { & $module { param($p,$root) Save-LabStorageBoundPlan -Plan $p -DataRoot $root -Confirm:$false } $plan (Join-Path $temporaryParent 'foreign'); $false } catch { $_.Exception.Message -match 'ROOT_NOT_OWNED|CONFIGURATION_REQUIRED' }
    Add-CheckResult -Name 'Unverwaltete Zielroots werden beim Speichern abgewiesen' -Success $unownedRejected

    $receipt = [PSCustomObject]@{
        ContractVersion='SqlServerLab.StorageRuntimeReceipt/1.0'; PlanId=$plan.PlanId; RunId=$runId; InstanceId='sql01'; Provider='hyperv'; Status='VERIFIED'
        FileBindings=@([PSCustomObject]@{ Role='tempdb-data'; LogicalName='tempdev'; LocationId=$locations[3].LocationId; HostPath='X:\Storage3\Lab_Data\file'; RuntimeStorageId='vhdx-1'; GuestDiskId='disk-1'; GuestPath='T:\SQLLab\TempDB\tempdev.mdf'; SqlPhysicalPath='T:\SQLLab\TempDB\tempdev.mdf' })
        Postconditions=@([PSCustomObject]@{ Name='sys.master_files'; Status='PASS' }); Recovery=[PSCustomObject]@{ Status='NOT_REQUIRED' }
    }
    Add-CheckResult -Name 'Separater Runtime-Receipt-Vertrag bildet die gesamte Pfadkette ab' -Success (
        (($receipt | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-storage-runtime-receipt.schema.json') -ErrorAction SilentlyContinue) -and
        $plan.RuntimeApplicationStatus -eq 'READY_TO_APPLY')

    $snapshot = & $module { param($instance) New-LabInstanceIntentSnapshot -Instance $instance -ProviderCapability ([PSCustomObject]@{ Capabilities=@() }) } ([PSCustomObject]@{ storageIntent=$intent; drives=@(); software=@() })
    $snapshotJson = $snapshot.Storage | ConvertTo-Json -Depth 30
    Add-CheckResult -Name 'Desired State trägt nur portablen Intent, keine lokalen Bindungen' -Success (
        $snapshot.Storage.BindingStatus -eq 'LOCAL_BINDING_REQUIRED' -and $snapshotJson -notmatch 'LocationId|BackingDevice|HostRoot|HostPath|GuestRoot')

    $manifest = [PSCustomObject]@{ name='storage-intent-test'; instances=@([PSCustomObject]@{ id='sql01'; version='2025'; storageIntent=$intent }) }
    $manifestResult = Test-SqlServerLabManifest -InputObject $manifest
    Add-CheckResult -Name 'Storage-Intent ist im Manifest schema-validierbar' -Success $manifestResult.IsValid -Message (@($manifestResult.Errors) -join '; ')

    $uiText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/StorageContract.ps1') -Raw -Encoding utf8
    $placementText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/StorageFilePlacement.ps1') -Raw -Encoding utf8
    $hyperVEnvironmentText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Storage-UI bietet Metadaten und vollständige Dateiplan-Prüfung an' -Success (
        $uiText -match "-Id 'metadata'" -and $uiText -match "-Id 'file-plan'" -and
        $placementText -match 'foreach \(\$file in @\(\$plan\.SqlFiles\)\)')
    Add-CheckResult -Name 'Hyper-V-Lifecycle bindet, appliziert und quittiert den Storage-Plan' -Success (
        $hyperVEnvironmentText -match 'New-LabStorageBoundPlan' -and
        $hyperVEnvironmentText -match 'ConvertTo-LabHyperVStorageDrivePlan' -and
        $hyperVEnvironmentText -match 'Invoke-HyperVLabStoragePlan' -and
        $placementText -match "Status='RECOVERY_REQUIRED'" -and $placementText -match "Status='VERIFIED'")
}
catch { Add-CheckResult -Name 'Storage-File-Placement-Testausführung' -Success $false -Message $_.Exception.Message }
finally {
    if (Test-Path -LiteralPath $temporaryParent) { Remove-Item -LiteralPath $temporaryParent -Recurse -Force }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
