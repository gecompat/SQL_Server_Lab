<#
.SYNOPSIS
    Plant und fuehrt den sicheren Lifecycle katalogisierter Hyper-V-Daten-VHDX aus.
.DESCRIPTION
    Die stabile PersistentStorageId wird gegen Katalog, registriertes Lab_Data,
    VHDX-DiskIdentifier, Attachments, Checkpoints, VM-Identitaet und explizite
    Clean-Detach-/Gastpfad-Evidenz revalidiert. REATTACH und RELEASE mutieren nur
    eine ausgeschaltete, eindeutig gebundene Ziel-VM. CLONE konvertiert eine
    ungebundene Quelle in eine eigenstaendige VHDX und veraendert die Quelle nie.
    Vorhandene Datenbankdateien werden ausdruecklich nicht als online ausgegeben.
#>

function Test-LabHyperVPersistentDataIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Intent)

    $schemaPath = Join-Path $script:SchemasPath 'hyperv-persistent-data-intent.schema.json'
    try {
        $valid = $Intent | ConvertTo-Json -Depth 40 | Test-Json -SchemaFile $schemaPath -ErrorAction Stop
    }
    catch { throw "HYPERV_PERSISTENT_DATA_INTENT_SCHEMA_INVALID: $($_.Exception.Message)" }
    if (-not $valid) { throw 'HYPERV_PERSISTENT_DATA_INTENT_SCHEMA_INVALID' }
    return $true
}

function Test-LabHyperVPathWithinRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return $resolvedPath.StartsWith("$resolvedRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)
}

function Get-LabHyperVPersistentDataRuntimeInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TargetVMName
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $vhd = $null
    if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
        try { $vhd = Get-VHD -Path $resolvedPath -ErrorAction Stop }
        catch { throw "HYPERV_PERSISTENT_DATA_VHD_INSPECTION_FAILED: $($_.Exception.Message)" }
    }

    $attachments = [Collections.Generic.List[object]]::new()
    $checkpointReferences = [Collections.Generic.List[object]]::new()
    foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue)) {
        foreach ($drive in @($vm | Get-VMHardDiskDrive -ErrorAction SilentlyContinue)) {
            if ($drive.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$drive.Path), $resolvedPath, [StringComparison]::OrdinalIgnoreCase)) {
                $attachments.Add([PSCustomObject]@{
                    VMName=[string]$vm.Name; VMId=[string]$vm.Id; VMState=[string]$vm.State
                    ControllerType=[string]$drive.ControllerType; ControllerNumber=[int]$drive.ControllerNumber
                    ControllerLocation=[int]$drive.ControllerLocation
                })
            }
        }
        foreach ($snapshot in @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)) {
            foreach ($drive in @($snapshot | Get-VMHardDiskDrive -ErrorAction SilentlyContinue)) {
                if ($drive.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$drive.Path), $resolvedPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $checkpointReferences.Add([PSCustomObject]@{ VMName=[string]$vm.Name; VMId=[string]$vm.Id; CheckpointId=[string]$snapshot.Id })
                }
            }
        }
    }

    $targetMatches = @(Get-VM -Name $TargetVMName -ErrorAction SilentlyContinue)
    $target = if ($targetMatches.Count -eq 1) { $targetMatches[0] } else { $null }
    $targetIdentity = if ($target) { ConvertFrom-HyperVLabNotes -Notes ([string]$target.Notes) } else { $null }
    $targetDrives = if ($target) { @($target | Get-VMHardDiskDrive -ErrorAction SilentlyContinue) } else { @() }
    $targetCheckpoints = if ($target) { @(Get-VMSnapshot -VM $target -ErrorAction SilentlyContinue) } else { @() }

    [PSCustomObject]@{
        Status=if ($vhd) { 'AVAILABLE' } else { 'MISSING' }
        Path=$resolvedPath
        DiskIdentifier=if ($vhd) { ([string]$vhd.DiskIdentifier).ToUpperInvariant() } else { $null }
        VhdType=if ($vhd) { [string]$vhd.VhdType } else { $null }
        SizeBytes=if ($vhd) { [long]$vhd.Size } else { 0 }
        FileSizeBytes=if ($vhd) { [long]$vhd.FileSize } else { 0 }
        ParentPath=if ($vhd) { [string]$vhd.ParentPath } else { $null }
        Attachments=@($attachments)
        CheckpointReferences=@($checkpointReferences)
        Target=[PSCustomObject]@{
            Status=if ($targetMatches.Count -eq 1) { 'AVAILABLE' } elseif ($targetMatches.Count -gt 1) { 'AMBIGUOUS' } else { 'MISSING' }
            VMName=$TargetVMName; VMId=if ($target) { [string]$target.Id } else { $null }
            State=if ($target) { [string]$target.State } else { $null }
            AutomaticCheckpointsEnabled=if ($target) { [bool]$target.AutomaticCheckpointsEnabled } else { $null }
            RunId=if ($targetIdentity) { [string]$targetIdentity.runId } else { $null }
            ScopeId=if ($targetIdentity) { [string]$targetIdentity.scopeId } else { $null }
            InstanceId=if ($targetIdentity) { [string]$targetIdentity.instanceId } else { $null }
            GuestPaths=if ($targetIdentity) { @($targetIdentity.additionalDrives | ForEach-Object { [string]$_.guestPath } | Where-Object { $_ }) } else { @() }
            CheckpointCount=$targetCheckpoints.Count
            Attachments=@($targetDrives | ForEach-Object {
                [PSCustomObject]@{ Path=[string]$_.Path; ControllerType=[string]$_.ControllerType; ControllerNumber=[int]$_.ControllerNumber; ControllerLocation=[int]$_.ControllerLocation }
            })
        }
    }
}

function Get-LabHyperVPersistentDataDetachEvidencePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    return [IO.Path]::ChangeExtension($resolvedPath, '.detach-evidence.json')
}

function Write-LabHyperVPersistentDataDetachEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PersistentStorageId,
        [Parameter(Mandatory)][string]$ControllerId,
        [Parameter(Mandatory)]$DetachEvidence,
        [string]$SourceRunId,
        [string]$SourceScopeId,
        [string]$SourceVMId
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $file = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop
    $document = [PSCustomObject][ordered]@{
        ContractVersion = 'SqlServerLab.HyperVPersistentDataDetachEvidence/1.0'
        PersistentStorageId = $PersistentStorageId
        ControllerId = $ControllerId
        SourceRunId = if ($SourceRunId) { $SourceRunId } else { $null }
        SourceScopeId = if ($SourceScopeId) { $SourceScopeId } else { $null }
        SourceVMId = if ($SourceVMId) { $SourceVMId } else { $null }
        SourceFileLength = [long]$file.Length
        SourceLastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
        DetachEvidence = $DetachEvidence
        RecordedAt = Get-LabTimestamp
    }
    $schemaPath = Join-Path $script:SchemasPath 'hyperv-persistent-data-detach-evidence.schema.json'
    if (-not (($document | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw 'HYPERV_PERSISTENT_DATA_DETACH_EVIDENCE_SCHEMA_INVALID'
    }
    Write-LabArtifactJsonAtomic -Path (Get-LabHyperVPersistentDataDetachEvidencePath -Path $resolvedPath) -InputObject $document
    return $document
}

function Get-LabHyperVPersistentDataDetachEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PersistentStorageId,
        [Parameter(Mandatory)][string]$ControllerId,
        [Parameter(Mandatory)][string]$DiskIdentifier
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $evidencePath = Get-LabHyperVPersistentDataDetachEvidencePath -Path $resolvedPath
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) { return $null }
    try {
        $document = Get-Content -LiteralPath $evidencePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        $schemaPath = Join-Path $script:SchemasPath 'hyperv-persistent-data-detach-evidence.schema.json'
        if (-not (($document | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $schemaPath -ErrorAction Stop)) { return $null }
        $file = Get-Item -LiteralPath $resolvedPath -ErrorAction Stop
        if ([string]$document.PersistentStorageId -ne $PersistentStorageId -or
            [string]$document.ControllerId -ne $ControllerId -or
            [string]$document.DetachEvidence.DiskIdentifier -ne $DiskIdentifier -or
            [long]$document.SourceFileLength -ne [long]$file.Length -or
            [datetime]$document.SourceLastWriteTimeUtc -ne $file.LastWriteTimeUtc) {
            return $null
        }
        return $document
    }
    catch { return $null }
}

function Get-LabHyperVPersistentDataGuestDetachObservation {
    <#
    .SYNOPSIS
        Prüft SQL-Dateibindungen im laufenden Gast und startet danach einen sauberen Shutdown.
    .DESCRIPTION
        Die Abfrage verbindet sich innerhalb der verwalteten VM per SQL-Login mit
        jeder registrierten SQL-Instanz. Eine VHDX wird nur freigabefähig, wenn
        unter ihrem Gastpfad keine aktive Datenbankdatei gebunden ist. Der
        Shutdown wird erst nach der erfolgreichen, vollständigen Abfrage geplant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Lab,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][SecureString]$SqlSaPassword,
        [Parameter(Mandatory)][string]$GuestPath,
        [Parameter(Mandatory)][string]$ExpectedSqlMajorVersion,
        [ValidateRange(30, 600)][int]$ShutdownTimeoutSeconds = 180
    )

    $managed = Get-HyperVManagedVM -VMName ([string]$Lab.Instance.vmName) `
        -ExpectedRunId ([string]$Lab.Run.runId) -ExpectedScopeId ([string]$Lab.Run.scopeId)
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') {
        throw 'HYPERV_PERSISTENT_DATA_EVIDENCE_VM_MUST_BE_RUNNING'
    }
    $ready = Wait-HyperVPowerShellDirect -VMName ([string]$Lab.Instance.vmName) `
        -ExpectedRunId ([string]$Lab.Run.runId) -ExpectedScopeId ([string]$Lab.Run.scopeId) `
        -Credential $Credential -TimeoutSeconds ([Math]::Min($ShutdownTimeoutSeconds, 300))
    if (-not $ready.Ready) { throw "HYPERV_PERSISTENT_DATA_EVIDENCE_GUEST_TIMEOUT: $($ready.Message)" }

    $result = Invoke-HyperVPowerShellDirect -VMName ([string]$Lab.Instance.vmName) `
        -ExpectedRunId ([string]$Lab.Run.runId) -ExpectedScopeId ([string]$Lab.Run.scopeId) `
        -Credential $Credential -ArgumentList @($GuestPath, $ExpectedSqlMajorVersion, $SqlSaPassword) -ScriptBlock {
            param($ExpectedGuestPath, $ExpectedSqlVersion, [SecureString]$SaPassword)
            $ErrorActionPreference = 'Stop'
            $root = [IO.Path]::GetFullPath([string]$ExpectedGuestPath).TrimEnd('\','/')
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                throw 'HYPERV_PERSISTENT_DATA_GUEST_PATH_NOT_FOUND'
            }
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
            $plain = $null
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                $instancePath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
                if (-not (Test-Path -LiteralPath $instancePath)) { throw 'HYPERV_PERSISTENT_DATA_SQL_INSTANCE_REGISTRY_NOT_FOUND' }
                $instanceMap = Get-ItemProperty -LiteralPath $instancePath -ErrorAction Stop
                $instances = @($instanceMap.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })
                if ($instances.Count -eq 0) { throw 'HYPERV_PERSISTENT_DATA_SQL_INSTANCE_NOT_FOUND' }
                $rows = [Collections.Generic.List[object]]::new()
                $observedVersions = [Collections.Generic.List[string]]::new()
                foreach ($instance in $instances) {
                    $dataSource = if ([string]$instance.Name -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$([string]$instance.Name)" }
                    $builder = [Data.SqlClient.SqlConnectionStringBuilder]::new()
                    $builder.DataSource = $dataSource
                    $builder.InitialCatalog = 'master'
                    $builder.UserID = 'sa'
                    $builder.Password = $plain
                    $builder.Encrypt = $true
                    $builder.TrustServerCertificate = $true
                    $builder.ConnectTimeout = 15
                    $connection = [Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
                    try {
                        $connection.Open()
                        $versionCommand = $connection.CreateCommand()
                        $versionCommand.CommandText = "SELECT CONVERT(nvarchar(10),SERVERPROPERTY('ProductMajorVersion'));"
                        $productMajor = [int]$versionCommand.ExecuteScalar()
                        $sqlVersion = switch ($productMajor) { 15 { '2019' } 16 { '2022' } 17 { '2025' } default { $null } }
                        if (-not $sqlVersion) { throw "HYPERV_PERSISTENT_DATA_SQL_VERSION_UNSUPPORTED: $productMajor" }
                        $observedVersions.Add($sqlVersion)
                        $command = $connection.CreateCommand()
                        $command.CommandText = 'SELECT DB_NAME(mf.database_id),COALESCE(d.state_desc,N''UNKNOWN''),mf.physical_name FROM sys.master_files mf LEFT JOIN sys.databases d ON d.database_id=mf.database_id;'
                        $reader = $command.ExecuteReader()
                        try {
                            while ($reader.Read()) {
                                $physicalPath = [string]$reader.GetString(2)
                                if (-not $physicalPath) { continue }
                                try { $fullPath = [IO.Path]::GetFullPath($physicalPath) } catch { continue }
                                if ($fullPath.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                                    $rows.Add([PSCustomObject]@{ Database=[string]$reader.GetString(0); State=[string]$reader.GetString(1); Path=$fullPath })
                                }
                            }
                        }
                        finally { $reader.Dispose() }
                    }
                    finally { $connection.Dispose() }
                }
                $versions = @($observedVersions | Sort-Object -Unique)
                if ($versions.Count -ne 1 -or [string]$versions[0] -ne [string]$ExpectedSqlVersion) {
                    throw "HYPERV_PERSISTENT_DATA_SQL_VERSION_MISMATCH: $($versions -join ',')"
                }
                $active = @($rows | Where-Object { [string]$_.State -ne 'OFFLINE' })
                if ($active.Count -gt 0) {
                    throw "HYPERV_PERSISTENT_DATA_DATABASE_FILES_ONLINE: $(@($active.Database | Sort-Object -Unique) -join ',')"
                }
                $databaseFiles = @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction Stop | Where-Object {
                    [string]$_.Extension -in @('.mdf','.ndf','.ldf')
                })
                $databaseState = if ($databaseFiles.Count -eq 0 -and $rows.Count -eq 0) { 'NO_DATABASE_FILES' } else { 'OFFLINE_OR_DETACHED' }
                $shutdownPath = Join-Path $env:SystemRoot 'System32\shutdown.exe'
                $null = Start-Process -FilePath $shutdownPath -ArgumentList @('/s','/t','3','/d','p:4:1') -WindowStyle Hidden -PassThru
                [PSCustomObject]@{
                    SqlMajorVersion = [string]$versions[0]
                    GuestPath = $root
                    DatabasesState = $databaseState
                    ObservedDatabaseFileCount = [int]$databaseFiles.Count
                    ObservedSqlFileBindingCount = [int]$rows.Count
                    ObservedAt = [datetime]::UtcNow.ToString('o')
                    ShutdownRequested = $true
                }
            }
            finally {
                $plain = $null
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
    $observation = @($result)[-1]
    if (-not $observation -or -not [bool]$observation.ShutdownRequested -or
        [string]$observation.SqlMajorVersion -ne $ExpectedSqlMajorVersion -or
        [string]$observation.DatabasesState -notin @('NO_DATABASE_FILES','OFFLINE_OR_DETACHED')) {
        throw 'HYPERV_PERSISTENT_DATA_GUEST_EVIDENCE_INVALID'
    }

    $deadline = [datetime]::UtcNow.AddSeconds($ShutdownTimeoutSeconds)
    do {
        $managed = Get-HyperVManagedVM -VMName ([string]$Lab.Instance.vmName) `
            -ExpectedRunId ([string]$Lab.Run.runId) -ExpectedScopeId ([string]$Lab.Run.scopeId)
        if ($managed -and [string]$managed.VM.State -eq 'Off') { break }
        Start-Sleep -Seconds 2
    } while ([datetime]::UtcNow -lt $deadline)
    if (-not $managed -or [string]$managed.VM.State -ne 'Off') {
        throw 'HYPERV_PERSISTENT_DATA_CLEAN_SHUTDOWN_TIMEOUT'
    }
    return $observation
}

function Get-LabHyperVPersistentDataSelection {
    <#
    .SYNOPSIS
        Liefert eine sanitisierte Auswahl katalogisierter Hyper-V-Daten-VHDX.
    .DESCRIPTION
        Die Auswahl bindet ausschliesslich die stabile PersistentStorageId an
        den Katalog und eine frische read-only Runtime-Pruefung. Hostpfade und
        DiskIdentifier bleiben intern. Eine angehaengte, konsistente Quelle kann
        ueber RELEASE selbst neue Clean-Detach-Evidenz erzeugen. Abgehaengte
        Quellen werden nur mit weiterhin dateigebundener Evidenz freigegeben.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        $Catalog,
        [switch]$InspectRuntime,
        [scriptblock]$RuntimeInspector
    )

    if (-not $Catalog) { $Catalog = Get-LabPersistentStorageCatalog -Configuration $Configuration }
    if ([string]$Catalog.Status -notin @('AVAILABLE','EMPTY')) { return @() }
    if (-not $RuntimeInspector) {
        $RuntimeInspector = {
            param($Path)
            Get-LabHyperVPersistentDataRuntimeInspection -Path $Path -TargetVMName '__sql_server_lab_inventory__'
        }
    }

    return @(
        foreach ($store in @($Catalog.Document.Stores | Where-Object {
            [string]$_.StorageClass -eq 'INSTANCE_STORE' -and [string]$_.Provider -eq 'hyperv'
        })) {
            $issues = [Collections.Generic.List[string]]::new()
            $inspection = $null
            $path = $null
            $attachmentState = 'UNKNOWN'
            $attachedVmName = $null
            $detachEvidenceStatus = 'MISSING'
            $sourceSqlMajorVersion = $null

            if ([string]$store.Retention -ne 'RETAINED' -or [string]$store.CleanupDisposition -ne 'PRESERVE') {
                $issues.Add('SOURCE_RETENTION_NOT_PERSISTENT')
            }
            if ([string]$store.LocationBinding.Residency -ne 'LAB_DATA' -or
                -not $store.LocationBinding.LocationId -or -not $store.LocationBinding.RelativePath) {
                $issues.Add('SOURCE_LAB_DATA_BINDING_INVALID')
            }
            else {
                $locations = @($Configuration.LabDataLocations | Where-Object {
                    [string]$_.LocationId -eq [string]$store.LocationBinding.LocationId
                })
                if ($locations.Count -ne 1) { $issues.Add('SOURCE_LOCATION_NOT_REGISTERED') }
                else {
                    try {
                        $root = [IO.Path]::GetFullPath([string]$locations[0].LabDataRoot)
                        $path = [IO.Path]::GetFullPath((Join-Path $root ([string]$store.LocationBinding.RelativePath)))
                        if (-not (Test-LabHyperVPathWithinRoot -Path $path -Root $root)) {
                            $issues.Add('SOURCE_PATH_OUTSIDE_LAB_DATA'); $path = $null
                        }
                    }
                    catch { $issues.Add('SOURCE_PATH_INVALID'); $path = $null }
                }
            }

            if (-not $InspectRuntime) { $issues.Add('HYPERV_RUNTIME_NOT_INSPECTED') }
            elseif ($path) {
                try {
                    $inspection = & $RuntimeInspector $path
                    if ([string]$inspection.Status -ne 'AVAILABLE') { $issues.Add('SOURCE_VHDX_NOT_OBSERVED') }
                    if ([string]$inspection.DiskIdentifier -ne [string]$store.LocationBinding.ProviderResourceId) {
                        $issues.Add('SOURCE_DISK_IDENTIFIER_MISMATCH')
                    }
                    if ([string]$inspection.ParentPath) { $issues.Add('SOURCE_DIFFERENCING_VHDX_UNSUPPORTED') }
                    if (@($inspection.CheckpointReferences).Count -gt 0) { $issues.Add('SOURCE_CHECKPOINT_REFERENCE_ACTIVE') }

                    $attachments = @($inspection.Attachments)
                    $attachmentState = if ($attachments.Count -eq 0) { 'DETACHED' } elseif ($attachments.Count -eq 1) { 'ATTACHED' } else { 'AMBIGUOUS' }
                    if ($attachments.Count -eq 1) { $attachedVmName = [string]$attachments[0].VMName }
                    if ($attachments.Count -gt 1) { $issues.Add('SOURCE_MULTIPLE_ATTACHMENTS') }
                    if ([string]$store.State -eq 'IN_USE' -and $attachments.Count -ne 1) { $issues.Add('CATALOG_RUNTIME_STATE_MISMATCH') }
                    if ([string]$store.State -in @('AVAILABLE','DETACHED') -and $attachments.Count -ne 0) { $issues.Add('CATALOG_RUNTIME_STATE_MISMATCH') }
                }
                catch { $issues.Add('HYPERV_RUNTIME_UNAVAILABLE') }
            }

            $activeReferences = @($store.References | Where-Object { [string]$_.State -eq 'ACTIVE' })
            $availableActions = @()
            if ([string]$store.State -eq 'IN_USE') {
                if (-not $store.Lease -or $activeReferences.Count -eq 0) { $issues.Add('SOURCE_ACTIVE_BINDING_INCOMPLETE') }
                $lifecycleActions = @('RELEASE')
                if (@($issues).Count -eq 0) { $availableActions = @('RELEASE') }
                else { $issues.Add('CLEAN_DETACH_EVIDENCE_GENERATION_BLOCKED') }
            }
            elseif ([string]$store.State -in @('AVAILABLE','DETACHED')) {
                if ($store.Lease -or $activeReferences.Count -gt 0) { $issues.Add('SOURCE_REFERENCE_ACTIVE') }
                $lifecycleActions = @('REATTACH','CLONE')
                if ($path -and $inspection -and [string]$inspection.DiskIdentifier) {
                    $detachEvidence = Get-LabHyperVPersistentDataDetachEvidence `
                        -Path $path -PersistentStorageId ([string]$store.PersistentStorageId) `
                        -ControllerId ([string]$Configuration.ControllerId) `
                        -DiskIdentifier ([string]$inspection.DiskIdentifier)
                    if ($detachEvidence) {
                        $detachEvidenceStatus = 'VERIFIED'
                        $sourceSqlMajorVersion = [string]$detachEvidence.DetachEvidence.SqlMajorVersion
                    }
                    else { $issues.Add('CLEAN_DETACH_EVIDENCE_REQUIRED') }
                }
                else { $issues.Add('CLEAN_DETACH_EVIDENCE_REQUIRED') }
                if (@($issues).Count -eq 0) { $availableActions = @('REATTACH','CLONE') }
            }
            else {
                $lifecycleActions = @()
                $issues.Add('SOURCE_STATE_NOT_SELECTABLE')
            }

            [PSCustomObject]@{
                PersistentStorageId = [string]$store.PersistentStorageId
                DisplayName = [string]$store.DisplayName
                State = [string]$store.State
                AttachmentState = $attachmentState
                AttachedVMName = $attachedVmName
                BoundRunId = if ($store.Lease) { [string]$store.Lease.RunId } else { $null }
                LifecycleActions = @($lifecycleActions)
                AvailableActions = @($availableActions)
                Issues = @($issues | Sort-Object -Unique)
                DetachEvidenceStatus = $detachEvidenceStatus
                SqlMajorVersion = $sourceSqlMajorVersion
                DatabaseFilesOnline = $false
                DatabaseActionRequired = 'EXPLICIT_RESTORE_OR_ATTACH'
            }
        }
    )
}

function Resolve-LabHyperVPersistentDataCatalogBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Intent,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Issues
    )

    $catalogStatus = if ($Catalog.PSObject.Properties['Status']) { [string]$Catalog.Status } else { 'AVAILABLE' }
    $document = if ($Catalog.PSObject.Properties['Document']) { $Catalog.Document } else { $Catalog }
    if ($catalogStatus -ne 'AVAILABLE') { $Issues.Add("CATALOG_$catalogStatus") }
    if (-not $document -or [string]$document.ContractVersion -ne 'SqlServerLab.PersistentStorageCatalog/1.0') { $Issues.Add('CATALOG_CONTRACT_INVALID') }
    elseif ([string]$document.ControllerId -ne [string]$Configuration.ControllerId) { $Issues.Add('CATALOG_CONTROLLER_MISMATCH') }

    $stores = @($document.Stores | Where-Object { [string]$_.PersistentStorageId -eq [string]$Intent.SourcePersistentStorageId })
    if ($stores.Count -ne 1) { $Issues.Add('SOURCE_STORAGE_NOT_FOUND'); return $null }
    $store = $stores[0]
    if ([string]$store.StorageClass -ne 'INSTANCE_STORE') { $Issues.Add('SOURCE_STORAGE_CLASS_INVALID') }
    if ([string]$store.Provider -ne 'hyperv') { $Issues.Add('SOURCE_PROVIDER_MISMATCH') }
    if ([string]$store.LocationBinding.Residency -ne 'LAB_DATA' -or -not $store.LocationBinding.LocationId -or -not $store.LocationBinding.RelativePath) {
        $Issues.Add('SOURCE_LAB_DATA_BINDING_INVALID')
        return [PSCustomObject]@{ Store=$store; Path=$null; Root=$null }
    }
    $locations = @($Configuration.LabDataLocations | Where-Object { [string]$_.LocationId -eq [string]$store.LocationBinding.LocationId })
    if ($locations.Count -ne 1) { $Issues.Add('SOURCE_LOCATION_NOT_REGISTERED'); return [PSCustomObject]@{ Store=$store; Path=$null; Root=$null } }
    $root = [IO.Path]::GetFullPath([string]$locations[0].LabDataRoot)
    $path = [IO.Path]::GetFullPath((Join-Path $root ([string]$store.LocationBinding.RelativePath)))
    if (-not (Test-LabHyperVPathWithinRoot -Path $path -Root $root)) { $Issues.Add('SOURCE_PATH_OUTSIDE_LAB_DATA') }
    return [PSCustomObject]@{ Store=$store; Path=$path; Root=$root; Document=$document }
}

function Get-LabHyperVPersistentDataPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Intent,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)]$RuntimeInspection
    )

    $null = Test-LabHyperVPersistentDataIntent -Intent $Intent
    $issues = [Collections.Generic.List[string]]::new()
    $binding = Resolve-LabHyperVPersistentDataCatalogBinding -Intent $Intent -Catalog $Catalog -Configuration $Configuration -Issues $issues
    $store = if ($binding) { $binding.Store } else { $null }
    $action = [string]$Intent.Action

    if ($store) {
        if ($action -eq 'RELEASE') {
            if ([string]$store.State -ne 'IN_USE') { $issues.Add('SOURCE_STATE_NOT_IN_USE') }
            if (-not $store.Lease -or [string]$store.Lease.RunId -ne [string]$Intent.TargetRunId -or [string]$store.Lease.ScopeId -ne [string]$Intent.TargetScopeId) { $issues.Add('SOURCE_LEASE_TARGET_MISMATCH') }
        }
        else {
            $operationReferences = @($store.References | Where-Object {
                [string]$_.ReferenceId -eq [string]$Intent.OperationId -and [string]$_.Kind -eq 'RUN' -and
                [string]$_.State -eq 'ACTIVE' -and [string]$_.TargetId -eq [string]$Intent.TargetRunId
            })
            $sameOperationLease = [string]$store.State -in @('INCOMPLETE','RECOVERY_REQUIRED') -and $store.Lease -and
                [string]$store.Lease.LeaseId -eq [string]$Intent.OperationId -and
                [string]$store.Lease.RunId -eq [string]$Intent.TargetRunId -and
                [string]$store.Lease.ScopeId -eq [string]$Intent.TargetScopeId -and $operationReferences.Count -eq 1
            if (-not $sameOperationLease) {
                if ([string]$store.State -notin @('AVAILABLE','DETACHED')) { $issues.Add('SOURCE_STATE_NOT_DETACHED') }
                if ($store.Lease) { $issues.Add('SOURCE_LEASE_ACTIVE') }
                if (@($store.References | Where-Object State -eq 'ACTIVE').Count -gt 0) { $issues.Add('SOURCE_REFERENCE_ACTIVE') }
            }
        }
        if ([string]$store.Retention -ne 'RETAINED' -or [string]$store.CleanupDisposition -ne 'PRESERVE') { $issues.Add('SOURCE_RETENTION_NOT_PERSISTENT') }
    }

    if ([string]$RuntimeInspection.Status -ne 'AVAILABLE') { $issues.Add('SOURCE_VHDX_NOT_OBSERVED') }
    if ($binding -and $binding.Path -and -not [string]::Equals([string]$RuntimeInspection.Path, [string]$binding.Path, [StringComparison]::OrdinalIgnoreCase)) { $issues.Add('SOURCE_PATH_BINDING_MISMATCH') }
    if ([string]$RuntimeInspection.DiskIdentifier -notmatch '^[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$') { $issues.Add('SOURCE_DISK_IDENTIFIER_INVALID') }
    if ($store -and [string]$store.LocationBinding.ProviderResourceId -ne [string]$RuntimeInspection.DiskIdentifier) { $issues.Add('SOURCE_DISK_IDENTIFIER_MISMATCH') }
    if ([string]$RuntimeInspection.ParentPath) { $issues.Add('SOURCE_DIFFERENCING_VHDX_UNSUPPORTED') }
    if (@($RuntimeInspection.CheckpointReferences).Count -gt 0) { $issues.Add('SOURCE_CHECKPOINT_REFERENCE_ACTIVE') }

    $detach = $Intent.DetachEvidence
    if ([string]$detach.Status -ne 'CLEAN_DETACHED' -or [string]$detach.DirtyState -ne 'CLEAN') { $issues.Add('SOURCE_CLEAN_DETACH_UNVERIFIED') }
    if ([string]$detach.DiskIdentifier -ne [string]$RuntimeInspection.DiskIdentifier) { $issues.Add('SOURCE_DETACH_DISK_IDENTIFIER_MISMATCH') }
    if ([string]$detach.SqlMajorVersion -ne [string]$Intent.TargetSqlMajorVersion) { $issues.Add('SOURCE_SQL_VERSION_INCOMPATIBLE') }
    if ([string]$detach.GuestPath -ne [string]$Intent.TargetGuestPath) { $issues.Add('SOURCE_GUEST_PATH_MISMATCH') }

    $target = $RuntimeInspection.Target
    if ([string]$target.Status -ne 'AVAILABLE') { $issues.Add('TARGET_VM_NOT_FOUND') }
    if ([string]$target.State -ne 'Off') { $issues.Add('TARGET_VM_MUST_BE_OFF') }
    if ([string]$target.RunId -ne [string]$Intent.TargetRunId -or [string]$target.ScopeId -ne [string]$Intent.TargetScopeId) { $issues.Add('TARGET_VM_IDENTITY_MISMATCH') }
    if ([string]$Intent.TargetEvidence.VMId -ne [string]$target.VMId) { $issues.Add('TARGET_VM_EVIDENCE_MISMATCH') }
    if ([string]$Intent.TargetEvidence.SqlMajorVersion -ne [string]$Intent.TargetSqlMajorVersion) { $issues.Add('TARGET_SQL_VERSION_UNVERIFIED') }
    if (-not [bool]$Intent.TargetEvidence.GuestPathAvailable -or [string]$Intent.TargetEvidence.GuestPath -ne [string]$Intent.TargetGuestPath) { $issues.Add('TARGET_GUEST_PATH_NOT_FREE') }
    if ($action -ne 'RELEASE' -and [string]$Intent.TargetGuestPath -in @($target.GuestPaths | ForEach-Object { [string]$_ })) { $issues.Add('TARGET_GUEST_PATH_ALREADY_BOUND') }
    if ([int]$target.CheckpointCount -gt 0) { $issues.Add('TARGET_VM_CHECKPOINTS_PRESENT') }
    if ([bool]$target.AutomaticCheckpointsEnabled) { $issues.Add('TARGET_AUTOMATIC_CHECKPOINTS_ENABLED') }

    $sourceAttachments = @($RuntimeInspection.Attachments)
    if ($action -eq 'RELEASE') {
        if ($sourceAttachments.Count -ne 1 -or [string]$sourceAttachments[0].VMId -ne [string]$target.VMId) { $issues.Add('SOURCE_NOT_EXCLUSIVELY_ATTACHED_TO_TARGET') }
    }
    elseif ($sourceAttachments.Count -gt 0) { $issues.Add('SOURCE_VHDX_ATTACHED') }

    $occupied = @(
        $target.Attachments |
            Where-Object { [string]$_.ControllerType -eq 'SCSI' -and [int]$_.ControllerNumber -eq 0 } |
            ForEach-Object { [int]$_.ControllerLocation }
    )
    $availableSlots = @(1..63 | Where-Object { $_ -notin $occupied })
    $controllerLocation = if ($action -eq 'RELEASE' -and $sourceAttachments.Count -eq 1) { [int]$sourceAttachments[0].ControllerLocation } elseif ($availableSlots.Count -gt 0) { [int]$availableSlots[0] } else { $null }
    if ($null -eq $controllerLocation) { $issues.Add('TARGET_SCSI_SLOT_UNAVAILABLE') }

    $targetPath = $null
    if ($action -eq 'CLONE') {
        $targetIds = if ($binding -and $binding.Document) { @($binding.Document.Stores | Where-Object { [string]$_.PersistentStorageId -eq [string]$Intent.TargetPersistentStorageId }) } else { @() }
        if ($targetIds.Count -gt 0 -or [string]$Intent.TargetPersistentStorageId -eq [string]$Intent.SourcePersistentStorageId) { $issues.Add('TARGET_STORAGE_ID_ALREADY_USED') }
        $targetLocation = @($Configuration.LabDataLocations | Where-Object { [string]$_.LocationId -eq [string]$Intent.TargetLocationId })
        if ($targetLocation.Count -ne 1) { $issues.Add('TARGET_LOCATION_NOT_REGISTERED') }
        else {
            $targetRoot = [IO.Path]::GetFullPath([string]$targetLocation[0].LabDataRoot)
            $targetPath = [IO.Path]::GetFullPath((Join-Path $targetRoot ([string]$Intent.TargetRelativePath)))
            if (-not (Test-LabHyperVPathWithinRoot -Path $targetPath -Root $targetRoot)) { $issues.Add('TARGET_PATH_OUTSIDE_LAB_DATA') }
            if (Test-Path -LiteralPath $targetPath) { $issues.Add('TARGET_VHDX_ALREADY_EXISTS') }
            if (-not $targetLocation[0].PSObject.Properties['FreeBytes']) { $issues.Add('TARGET_FREE_SPACE_UNVERIFIED') }
            elseif ([long]$targetLocation[0].FreeBytes -lt ([long]$RuntimeInspection.FileSizeBytes + 64MB)) { $issues.Add('TARGET_CAPACITY_INSUFFICIENT') }
        }
    }

    $blockers = @($issues | Sort-Object -Unique)
    $steps = switch ($action) {
        'REATTACH' { @('REVALIDATE_SOURCE_AND_TARGET','ATTACH_EXISTING_VHDX','UPDATE_VM_IDENTITY','VERIFY_HOST_ATTACHMENT','REQUIRE_EXPLICIT_DATABASE_RESTORE_OR_ATTACH') }
        'RELEASE' { @('REVALIDATE_CLEAN_RELEASE','DETACH_VHDX','UPDATE_VM_IDENTITY','VERIFY_HOST_DETACH','RELEASE_CATALOG_LEASE_REQUIRED') }
        'CLONE' { @('REVALIDATE_DETACHED_SOURCE','CONVERT_SOURCE_TO_INDEPENDENT_VHDX','VERIFY_SOURCE_UNCHANGED','VERIFY_TARGET_IDENTITY','REGISTER_TARGET_CANDIDATE') }
    }
    $plan = [PSCustomObject]@{
        ContractVersion='SqlServerLab.HyperVPersistentDataPlan/1.0'; OperationId=[string]$Intent.OperationId
        Status=if ($blockers.Count -eq 0) { 'READY' } else { 'BLOCKED' }; Action=$action
        Source=[PSCustomObject]@{
            PersistentStorageId=[string]$Intent.SourcePersistentStorageId; Path=if ($binding) { [string]$binding.Path } else { $null }
            LocationId=if ($store) { [string]$store.LocationBinding.LocationId } else { $null }
            RelativePath=if ($store) { [string]$store.LocationBinding.RelativePath } else { $null }
            InventoryObjectId=if ($store) { [string]$store.LocationBinding.InventoryObjectId } else { $null }
            DiskIdentifier=[string]$RuntimeInspection.DiskIdentifier; VhdType=[string]$RuntimeInspection.VhdType
            SizeBytes=[long]$RuntimeInspection.SizeBytes; SqlMajorVersion=[string]$detach.SqlMajorVersion; GuestPath=[string]$detach.GuestPath
            DatabasesState=[string]$detach.DatabasesState
            Retention=if ($store) { [string]$store.Retention } else { $null }; CleanupDisposition=if ($store) { [string]$store.CleanupDisposition } else { $null }
        }
        Target=[PSCustomObject]@{
            PersistentStorageId=if ($action -eq 'CLONE') { [string]$Intent.TargetPersistentStorageId } else { $null }; Path=$targetPath
            LocationId=if ($action -eq 'CLONE') { [string]$Intent.TargetLocationId } else { $null }
            RelativePath=if ($action -eq 'CLONE') { (([string]$Intent.TargetRelativePath) -replace '\\','/') } else { $null }
            VMName=[string]$Intent.TargetVMName; VMId=[string]$target.VMId; RunId=[string]$Intent.TargetRunId; ScopeId=[string]$Intent.TargetScopeId
            InstanceId=[string]$target.InstanceId; SqlMajorVersion=[string]$Intent.TargetSqlMajorVersion; GuestPath=[string]$Intent.TargetGuestPath
            ControllerNumber=0; ControllerLocation=$controllerLocation
        }
        Steps=@($steps | ForEach-Object -Begin { $order=0 } -Process { $order++; [PSCustomObject]@{ Order=$order; Action=$_ } })
        Blockers=$blockers
        Preview=[PSCustomObject]@{ SourceMutation=$false; SourceDeletion=$false; RequiresCleanDetach=$true; RequiresTargetVMOff=$true; DatabaseFilesOnline=$false; DatabaseActionRequired='EXPLICIT_RESTORE_OR_ATTACH'; CatalogCommitRequired=$true }
    }
    $schemaPath = Join-Path $script:SchemasPath 'hyperv-persistent-data-plan.schema.json'
    if (-not (($plan | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) { throw 'HYPERV_PERSISTENT_DATA_PLAN_SCHEMA_INVALID' }
    return $plan
}

function Get-LabHyperVPersistentDataJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OperationDirectory)
    return (Join-Path $OperationDirectory 'hyperv-persistent-data-journal.json')
}

function Write-LabHyperVPersistentDataJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    return $Journal
}

function Set-LabHyperVPersistentDataVMIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][ValidateSet('ATTACH','RELEASE')][string]$Action
    )

    $managed = Get-HyperVManagedVM -VMName ([string]$Plan.Target.VMName) -ExpectedRunId ([string]$Plan.Target.RunId) -ExpectedScopeId ([string]$Plan.Target.ScopeId)
    if (-not $managed -or [string]$managed.VM.State -ne 'Off') { throw 'HYPERV_PERSISTENT_DATA_MANAGED_VM_REVALIDATION_FAILED' }
    $sourcePath = [IO.Path]::GetFullPath([string]$Plan.Source.Path)
    $drives = @($managed.Identity.additionalDrives | Where-Object {
        -not $_.path -or -not [string]::Equals([IO.Path]::GetFullPath([string]$_.path), $sourcePath, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($Action -eq 'ATTACH') {
        $driveLetter = ([string]$Plan.Target.GuestPath).Substring(0,1).ToUpperInvariant()
        $drives += [PSCustomObject]@{
            id="persistent-$(([string]$Plan.Source.PersistentStorageId).Substring(0,8))"; role='sqlData'
            sizeBytes=[long]$Plan.Source.SizeBytes; vhdType=([string]$Plan.Source.VhdType).ToLowerInvariant(); path=$sourcePath
            diskIdentifier=[string]$Plan.Source.DiskIdentifier; controllerNumber=[int]$Plan.Target.ControllerNumber
            controllerLocation=[int]$Plan.Target.ControllerLocation; guestPath=[string]$Plan.Target.GuestPath; driveLetter=$driveLetter
            fileSystem='NTFS'; allocationUnitKB=64; volumeLabel='SQLLAB_DATA'; maximumIops=0
            hostRoot=(Split-Path -Parent $sourcePath); locationId=[string]$Plan.Source.LocationId; selector=$null
            persistentStorageId=[string]$Plan.Source.PersistentStorageId; retention=[string]$Plan.Source.Retention
            cleanupDisposition=[string]$Plan.Source.CleanupDisposition
        }
    }
    $managed.Identity | Add-Member -NotePropertyName additionalDrives -NotePropertyValue @($drives) -Force
    $managed.Identity | Add-Member -NotePropertyName additionalVhdxPaths -NotePropertyValue @($drives | ForEach-Object { [IO.Path]::GetFullPath([string]$_.path) }) -Force
    $managed.Identity | Add-Member -NotePropertyName contractVersion -NotePropertyValue '0.7' -Force
    $notes = $script:HyperVLabNotesPrefix + ($managed.Identity | ConvertTo-Json -Compress -Depth 12)
    $null = Set-VM -VM $managed.VM -Notes $notes -AutomaticCheckpointsEnabled $false -ErrorAction Stop
    return @($drives)
}

function Invoke-LabHyperVPersistentDataPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$OperationDirectory,
        [Parameter(Mandatory)]$Configuration
    )

    if ([string]$Plan.Status -ne 'READY') { throw 'HYPERV_PERSISTENT_DATA_READY_PLAN_REQUIRED' }
    if (-not (Test-Path -LiteralPath $OperationDirectory -PathType Container)) { $null = New-Item -ItemType Directory -Path $OperationDirectory -Force }
    $journalPath = Get-LabHyperVPersistentDataJournalPath -OperationDirectory $OperationDirectory
    $journal = if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    }
    else {
        [PSCustomObject]@{
            ContractVersion='SqlServerLab.HyperVPersistentDataJournal/1.0'; OperationId=[string]$Plan.OperationId
            Action=[string]$Plan.Action; Status='PREPARED'; Source=$Plan.Source; Target=$Plan.Target
            SourceSha256=$null; TargetDiskIdentifier=$null; TargetOwnedByOperation=$false
            CatalogLeaseAcquired=$false; CatalogCommitted=$false; CatalogRevision=$null; CatalogRecoveryErrorCode=$null
            Recovery=[PSCustomObject]@{ Status='RETRY'; Attempts=0; ErrorCode=$null }; UpdatedAt=Get-LabTimestamp
        }
    }
    if ([string]$journal.OperationId -ne [string]$Plan.OperationId -or [string]$journal.Action -ne [string]$Plan.Action -or
        [string]$journal.Source.PersistentStorageId -ne [string]$Plan.Source.PersistentStorageId -or
        [string]$journal.Source.Path -ne [string]$Plan.Source.Path -or
        [string]$journal.Target.RunId -ne [string]$Plan.Target.RunId -or
        [string]$journal.Target.VMId -ne [string]$Plan.Target.VMId -or
        [string]$journal.Target.PersistentStorageId -ne [string]$Plan.Target.PersistentStorageId -or
        [string]$journal.Target.Path -ne [string]$Plan.Target.Path) { throw 'HYPERV_PERSISTENT_DATA_JOURNAL_IDENTITY_MISMATCH' }
    foreach ($field in @(
        @{ Name='CatalogLeaseAcquired'; Value=$false }, @{ Name='CatalogCommitted'; Value=$false },
        @{ Name='CatalogRevision'; Value=$null }, @{ Name='CatalogRecoveryErrorCode'; Value=$null }
    )) {
        if (-not $journal.PSObject.Properties[$field.Name]) {
            $journal | Add-Member -NotePropertyName $field.Name -NotePropertyValue $field.Value
        }
    }
    if ([string]$journal.Status -eq 'COMPLETED' -and [bool]$journal.CatalogCommitted) { return $journal }
    $journal.Recovery.Attempts = [int]$journal.Recovery.Attempts + 1

    try {
        if ([string]$Plan.Action -in @('CLONE','REATTACH')) {
            $lease = Set-LabHyperVPersistentDataOperationLease -Plan $Plan -Configuration $Configuration
            $journal.CatalogLeaseAcquired = $true
            $journal.CatalogRevision = [int]$lease.CatalogRevision
            $journal.Status = if ([bool]$lease.CatalogCommitted) { 'CATALOG_COMMITTED' } else { 'CATALOG_LEASED' }
            $null = Write-LabHyperVPersistentDataJournal -Journal $journal -Path $journalPath
        }
        $inspection = Get-LabHyperVPersistentDataRuntimeInspection -Path ([string]$Plan.Source.Path) -TargetVMName ([string]$Plan.Target.VMName)
        if ([string]$inspection.Status -ne 'AVAILABLE' -or [string]$inspection.DiskIdentifier -ne [string]$Plan.Source.DiskIdentifier -or
            [string]$inspection.Target.VMId -ne [string]$Plan.Target.VMId -or [string]$inspection.Target.State -ne 'Off' -or
            [int]$inspection.Target.CheckpointCount -gt 0 -or [bool]$inspection.Target.AutomaticCheckpointsEnabled -or
            @($inspection.CheckpointReferences).Count -gt 0) {
            throw 'HYPERV_PERSISTENT_DATA_EXECUTION_REVALIDATION_FAILED'
        }
        switch ([string]$Plan.Action) {
            'CLONE' {
                if (@($inspection.Attachments).Count -gt 0) { throw 'HYPERV_PERSISTENT_DATA_CLONE_PRECONDITION_FAILED' }
                $reuseVerifiedTarget = $false
                if (Test-Path -LiteralPath ([string]$Plan.Target.Path)) {
                    if (-not [bool]$journal.TargetOwnedByOperation) { throw 'HYPERV_PERSISTENT_DATA_CLONE_TARGET_OWNERSHIP_UNVERIFIED' }
                    $targetAttachments = @(
                        Get-VM -ErrorAction SilentlyContinue | Get-VMHardDiskDrive -ErrorAction SilentlyContinue | Where-Object {
                            $_.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.Path), [IO.Path]::GetFullPath([string]$Plan.Target.Path), [StringComparison]::OrdinalIgnoreCase)
                        }
                    )
                    if ($targetAttachments.Count -gt 0) { throw 'HYPERV_PERSISTENT_DATA_CLONE_TARGET_ATTACHED' }
                    if ([string]$journal.SourceSha256 -and [string]$journal.TargetDiskIdentifier) {
                        $sourceHash = (Get-FileHash -LiteralPath ([string]$Plan.Source.Path) -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                        $targetVhd = Get-VHD -Path ([string]$Plan.Target.Path) -ErrorAction Stop
                        $reuseVerifiedTarget = $sourceHash -eq [string]$journal.SourceSha256 -and
                            [long]$targetVhd.Size -eq [long]$inspection.SizeBytes -and
                            [string]$targetVhd.DiskIdentifier -eq [string]$journal.TargetDiskIdentifier -and
                            [string]$targetVhd.DiskIdentifier -ne [string]$Plan.Source.DiskIdentifier
                    }
                    if (-not $reuseVerifiedTarget) {
                        Remove-Item -LiteralPath ([string]$Plan.Target.Path) -Force -ErrorAction Stop
                    }
                }
                if (-not $reuseVerifiedTarget) {
                    $journal.SourceSha256 = (Get-FileHash -LiteralPath ([string]$Plan.Source.Path) -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                    $targetParent = Split-Path -Parent ([string]$Plan.Target.Path)
                    if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) { $null = New-Item -ItemType Directory -Path $targetParent -Force }
                    $targetDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([string]$Plan.Target.Path))
                    if ([long]$targetDrive.AvailableFreeSpace -lt ([long]$inspection.FileSizeBytes + 64MB)) { throw 'HYPERV_PERSISTENT_DATA_CLONE_CAPACITY_INSUFFICIENT' }
                    $journal.TargetOwnedByOperation=$true; $journal.Status='TARGET_CREATING'
                    $null = Write-LabHyperVPersistentDataJournal -Journal $journal -Path $journalPath
                    $null = Convert-VHD -Path ([string]$Plan.Source.Path) -DestinationPath ([string]$Plan.Target.Path) -VHDType Dynamic -ErrorAction Stop
                    $null = Set-VHD -Path ([string]$Plan.Target.Path) -ResetDiskIdentifier -Force -ErrorAction Stop
                    $sourceAfter = (Get-FileHash -LiteralPath ([string]$Plan.Source.Path) -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                    $targetVhd = Get-VHD -Path ([string]$Plan.Target.Path) -ErrorAction Stop
                    if ($sourceAfter -ne [string]$journal.SourceSha256 -or [long]$targetVhd.Size -ne [long]$inspection.SizeBytes -or
                        [string]$targetVhd.DiskIdentifier -eq [string]$Plan.Source.DiskIdentifier) { throw 'HYPERV_PERSISTENT_DATA_CLONE_POSTCONDITION_FAILED' }
                    $journal.TargetDiskIdentifier = ([string]$targetVhd.DiskIdentifier).ToUpperInvariant()
                }
                $cloneDetachEvidence = [PSCustomObject][ordered]@{
                    Status='CLEAN_DETACHED'; DirtyState='CLEAN'; DiskIdentifier=[string]$journal.TargetDiskIdentifier
                    SqlMajorVersion=[string]$Plan.Source.SqlMajorVersion; GuestPath=[string]$Plan.Source.GuestPath
                    DatabasesState=[string]$Plan.Source.DatabasesState; ObservedAt=Get-LabTimestamp
                }
                $null = Write-LabHyperVPersistentDataDetachEvidence `
                    -Path ([string]$Plan.Target.Path) -PersistentStorageId ([string]$Plan.Target.PersistentStorageId) `
                    -ControllerId ([string]$Configuration.ControllerId) -DetachEvidence $cloneDetachEvidence `
                    -SourceRunId ([string]$Plan.Target.RunId) -SourceScopeId ([string]$Plan.Target.ScopeId) `
                    -SourceVMId ([string]$Plan.Target.VMId)
                $journal.Status = 'TARGET_VERIFIED'
            }
            'REATTACH' {
                $attachments=@($inspection.Attachments)
                if ($attachments.Count -eq 0) {
                    $null = Add-VMHardDiskDrive -VMName ([string]$Plan.Target.VMName) -ControllerType SCSI -ControllerNumber 0 -ControllerLocation ([int]$Plan.Target.ControllerLocation) -Path ([string]$Plan.Source.Path) -ErrorAction Stop
                }
                elseif ($attachments.Count -ne 1 -or [string]$attachments[0].VMId -ne [string]$Plan.Target.VMId -or
                    [int]$attachments[0].ControllerNumber -ne [int]$Plan.Target.ControllerNumber -or [int]$attachments[0].ControllerLocation -ne [int]$Plan.Target.ControllerLocation) {
                    throw 'HYPERV_PERSISTENT_DATA_ATTACH_PRECONDITION_FAILED'
                }
                $null = Set-LabHyperVPersistentDataVMIdentity -Plan $Plan -Action ATTACH
                $post = Get-LabHyperVPersistentDataRuntimeInspection -Path ([string]$Plan.Source.Path) -TargetVMName ([string]$Plan.Target.VMName)
                if (@($post.Attachments).Count -ne 1 -or [string]$post.Attachments[0].VMId -ne [string]$Plan.Target.VMId) { throw 'HYPERV_PERSISTENT_DATA_ATTACH_POSTCONDITION_FAILED' }
                $journal.Status = 'ATTACHED_FILES_OFFLINE'
            }
            'RELEASE' {
                $drive = @($inspection.Target.Attachments | Where-Object { $_.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.Path), [IO.Path]::GetFullPath([string]$Plan.Source.Path), [StringComparison]::OrdinalIgnoreCase) })
                if ($drive.Count -gt 1) { throw 'HYPERV_PERSISTENT_DATA_RELEASE_PRECONDITION_FAILED' }
                if ($drive.Count -eq 1) {
                    Get-VMHardDiskDrive -VMName ([string]$Plan.Target.VMName) -ControllerType SCSI -ControllerNumber ([int]$drive[0].ControllerNumber) -ControllerLocation ([int]$drive[0].ControllerLocation) -ErrorAction Stop | Remove-VMHardDiskDrive -ErrorAction Stop
                }
                $null = Set-LabHyperVPersistentDataVMIdentity -Plan $Plan -Action RELEASE
                $post = Get-LabHyperVPersistentDataRuntimeInspection -Path ([string]$Plan.Source.Path) -TargetVMName ([string]$Plan.Target.VMName)
                if (@($post.Attachments).Count -gt 0) { throw 'HYPERV_PERSISTENT_DATA_RELEASE_POSTCONDITION_FAILED' }
                $journal.Status = 'CLEAN_DETACHED'
            }
        }
        $null = Write-LabHyperVPersistentDataJournal -Journal $journal -Path $journalPath
        $catalogCommit = Complete-LabHyperVPersistentDataCatalogOperation -Plan $Plan -Journal $journal -Configuration $Configuration
        $journal.CatalogCommitted=$true; $journal.CatalogRevision=[int]$catalogCommit.CatalogRevision
        $journal.Recovery.Status='NOT_REQUIRED'; $journal.Recovery.ErrorCode=$null; $journal.CatalogRecoveryErrorCode=$null
        $journal.Status='CATALOG_COMMITTED'
        $null = Write-LabHyperVPersistentDataJournal -Journal $journal -Path $journalPath
        $journal.Status='COMPLETED'
        return (Write-LabHyperVPersistentDataJournal -Journal $journal -Path $journalPath)
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}') { [string]$Matches[0] } else { 'HYPERV_PERSISTENT_DATA_EXECUTION_FAILED' }
        try {
            $recovery = Set-LabHyperVPersistentDataOperationRecoveryRequired -Plan $Plan -Configuration $Configuration
            $journal.CatalogRevision = [int]$recovery.CatalogRevision
        }
        catch {
            $journal.CatalogRecoveryErrorCode = if ($_.Exception.Message -cmatch '[A-Z][A-Z0-9_]{5,127}') { [string]$Matches[0] } else { 'HYPERV_PERSISTENT_DATA_CATALOG_RECOVERY_FAILED' }
        }
        $journal.Status='RECOVERY_REQUIRED'; $journal.Recovery.Status='RETRY'; $journal.Recovery.ErrorCode=$code
        $null = Write-LabHyperVPersistentDataJournal -Journal $journal -Path $journalPath
        throw "HYPERV_PERSISTENT_DATA_RECOVERY_REQUIRED: $code"
    }
}

function Set-LabHyperVPersistentDataConnectionState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Interner Postcondition-Commit des bestaetigten Lifecycle-Flows.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Lab,
        [Parameter(Mandatory)][ValidateSet('REATTACH','RELEASE')][string]$Action,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Journal
    )

    if ($Action -eq 'RELEASE') {
        if (-not $Lab.Instance.persistentStorage -or
            [string]$Lab.Instance.persistentStorage.persistentStorageId -ne [string]$Plan.Source.PersistentStorageId) {
            throw 'HYPERV_PERSISTENT_DATA_CONNECTION_SOURCE_MISMATCH'
        }
        $Lab.Instance.persistentStorage.state = 'DETACHED'
        $Lab.Instance.persistentStorage | Add-Member -NotePropertyName detachedAt -NotePropertyValue (Get-LabTimestamp) -Force
    }
    else {
        if ($Lab.Instance.persistentStorage -and
            [string]$Lab.Instance.persistentStorage.persistentStorageId -ne [string]$Plan.Source.PersistentStorageId -and
            [string]$Lab.Instance.persistentStorage.state -notin @('DETACHED','RELEASED')) {
            throw 'HYPERV_PERSISTENT_DATA_CONNECTION_TARGET_OCCUPIED'
        }
        $Lab.Instance | Add-Member -NotePropertyName persistentStorage -NotePropertyValue ([PSCustomObject][ordered]@{
            mode = 'cataloged-data-root-vhdx'
            root = [string]$Plan.Target.GuestPath
            hostPath = [string]$Plan.Source.Path
            persistentStorageId = [string]$Plan.Source.PersistentStorageId
            locationId = [string]$Plan.Source.LocationId
            relativePath = [string]$Plan.Source.RelativePath
            diskIdentifier = [string]$Plan.Source.DiskIdentifier
            guestPath = [string]$Plan.Target.GuestPath
            backupGuestPath = Join-Path ([string]$Plan.Target.GuestPath) 'Backups'
            backupMode = 'guest-data-vhdx'
            state = 'ATTACHED_REQUIRES_DATABASE_ACTION'
            databaseFilesOnline = $false
            databaseActionRequired = 'EXPLICIT_RESTORE_OR_ATTACH'
            attachedAt = Get-LabTimestamp
            catalogRevision = [int]$Journal.CatalogRevision
        }) -Force
    }
    Write-LabArtifactJsonAtomic -Path (Join-Path ([string]$Lab.RunDirectory) 'connection-info.json') -InputObject $Lab.Connection
    return $Lab.Instance.persistentStorage
}

function Invoke-LabHyperVPersistentDataLifecycle {
    <#
    .SYNOPSIS
        Bindet den pfadfreien Workflow-Aufruf an Evidence, Planner und Executor.
    .DESCRIPTION
        Quelle und Ziel werden ausschliesslich ueber stabile IDs aufgeloest.
        RELEASE erzeugt die Clean-Detach-Evidenz im laufenden Gast und wartet
        den sauberen Shutdown ab. REATTACH und CLONE akzeptieren nur eine noch
        zur unveraenderten VHDX passende persistierte Evidenz.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('REATTACH','RELEASE','CLONE')][string]$Action,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$PersistentStorageId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TargetRunId,
        [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TargetLocationId,
        [PSCredential]$GuestCredential,
        [SecureString]$SqlSaPassword,
        [string]$DataRoot,
        [string]$StateRoot,
        [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$OperationId
    )

    if (-not $DataRoot) { $DataRoot = Get-LabDataRootDefault }
    if (-not $DataRoot) { throw 'LAB_DATA_ROOT_REQUIRED' }
    $DataRoot = Resolve-LabDataRootForUse -DataRoot $DataRoot
    $configuration = Get-LabStorageConfiguration -DataRoot $DataRoot
    $catalog = Get-LabPersistentStorageCatalog -Configuration $configuration
    if ([string]$catalog.Status -ne 'AVAILABLE') {
        throw "HYPERV_PERSISTENT_DATA_CATALOG_UNAVAILABLE: $([string]$catalog.Status)"
    }
    $targetLab = Get-HyperVLabWorkflowRun -RunId $TargetRunId -StateRoot $StateRoot
    $sqlVersion = [string]$targetLab.Instance.sqlVersion
    if ($sqlVersion -notin @('2019','2022','2025')) { throw 'HYPERV_PERSISTENT_DATA_TARGET_SQL_VERSION_REQUIRED' }

    $bindingIssues = [Collections.Generic.List[string]]::new()
    $lookupIntent = [PSCustomObject]@{ SourcePersistentStorageId=$PersistentStorageId }
    $binding = Resolve-LabHyperVPersistentDataCatalogBinding -Intent $lookupIntent -Catalog $catalog `
        -Configuration $configuration -Issues $bindingIssues
    if (-not $binding -or @($bindingIssues).Count -gt 0) {
        throw "HYPERV_PERSISTENT_DATA_SOURCE_UNAVAILABLE: $(@($bindingIssues) -join ',')"
    }
    $inspection = Get-LabHyperVPersistentDataRuntimeInspection -Path ([string]$binding.Path) `
        -TargetVMName ([string]$targetLab.Instance.vmName)
    if ([string]$inspection.Status -ne 'AVAILABLE' -or -not [string]$inspection.DiskIdentifier) {
        throw 'HYPERV_PERSISTENT_DATA_SOURCE_VHDX_UNAVAILABLE'
    }

    $evidenceDocument = Get-LabHyperVPersistentDataDetachEvidence `
        -Path ([string]$binding.Path) -PersistentStorageId $PersistentStorageId `
        -ControllerId ([string]$configuration.ControllerId) -DiskIdentifier ([string]$inspection.DiskIdentifier)
    if ($Action -eq 'RELEASE') {
        if ([string]$binding.Store.State -ne 'IN_USE' -or -not $binding.Store.Lease -or
            [string]$binding.Store.Lease.RunId -ne [string]$targetLab.Run.runId -or
            [string]$binding.Store.Lease.ScopeId -ne [string]$targetLab.Run.scopeId) {
            throw 'HYPERV_PERSISTENT_DATA_RELEASE_SOURCE_RUN_MISMATCH'
        }
        $guestPath = [string]$targetLab.Instance.persistentStorage.guestPath
        if (-not $guestPath -or [string]$targetLab.Instance.persistentStorage.persistentStorageId -ne $PersistentStorageId) {
            throw 'HYPERV_PERSISTENT_DATA_RELEASE_CONNECTION_BINDING_INVALID'
        }
        if ([string]$inspection.Target.State -eq 'Running') {
            if (-not $GuestCredential) {
                $guestPassword = Get-LabSecret -Path ([string]$targetLab.RunDirectory) -Name 'guest-administrator-password'
                if ($guestPassword) { $GuestCredential = [PSCredential]::new('Administrator', $guestPassword) }
            }
            if (-not $GuestCredential) { throw 'HYPERV_PERSISTENT_DATA_GUEST_CREDENTIAL_REQUIRED' }
            if (-not $SqlSaPassword) {
                $SqlSaPassword = Get-LabSecret -Path ([string]$targetLab.RunDirectory) -Name 'generated-sql-sa-password'
                if (-not $SqlSaPassword) { $SqlSaPassword = Get-LabSecret -Path ([string]$targetLab.RunDirectory) -Name 'sa-password' }
                if (-not $SqlSaPassword) { $SqlSaPassword = $GuestCredential.Password }
            }
            $guestObservation = Get-LabHyperVPersistentDataGuestDetachObservation `
                -Lab $targetLab -Credential $GuestCredential -SqlSaPassword $SqlSaPassword `
                -GuestPath $guestPath -ExpectedSqlMajorVersion $sqlVersion
            $inspection = Get-LabHyperVPersistentDataRuntimeInspection -Path ([string]$binding.Path) `
                -TargetVMName ([string]$targetLab.Instance.vmName)
            if ([string]$inspection.Target.State -ne 'Off') { throw 'HYPERV_PERSISTENT_DATA_TARGET_VM_MUST_BE_OFF' }
            $detachEvidence = [PSCustomObject][ordered]@{
                Status='CLEAN_DETACHED'; DirtyState='CLEAN'; DiskIdentifier=[string]$inspection.DiskIdentifier
                SqlMajorVersion=$sqlVersion; GuestPath=$guestPath
                DatabasesState=[string]$guestObservation.DatabasesState; ObservedAt=[string]$guestObservation.ObservedAt
            }
            $evidenceDocument = Write-LabHyperVPersistentDataDetachEvidence `
                -Path ([string]$binding.Path) -PersistentStorageId $PersistentStorageId `
                -ControllerId ([string]$configuration.ControllerId) -DetachEvidence $detachEvidence `
                -SourceRunId ([string]$targetLab.Run.runId) -SourceScopeId ([string]$targetLab.Run.scopeId) `
                -SourceVMId ([string]$inspection.Target.VMId)
        }
        elseif ([string]$inspection.Target.State -ne 'Off') {
            throw 'HYPERV_PERSISTENT_DATA_TARGET_VM_MUST_BE_RUNNING_OR_OFF'
        }
        elseif (-not $evidenceDocument -or [string]$evidenceDocument.SourceRunId -ne [string]$targetLab.Run.runId -or
            [string]$evidenceDocument.SourceScopeId -ne [string]$targetLab.Run.scopeId -or
            [string]$evidenceDocument.SourceVMId -ne [string]$inspection.Target.VMId) {
            throw 'HYPERV_PERSISTENT_DATA_CLEAN_DETACH_EVIDENCE_REQUIRED: VM starten und Release erneut ausführen.'
        }
    }
    elseif (-not $evidenceDocument) {
        throw 'HYPERV_PERSISTENT_DATA_CLEAN_DETACH_EVIDENCE_REQUIRED'
    }

    $detach = $evidenceDocument.DetachEvidence
    if ([string]$detach.SqlMajorVersion -ne $sqlVersion) { throw 'HYPERV_PERSISTENT_DATA_SOURCE_SQL_VERSION_INCOMPATIBLE' }
    $guestPath = [string]$detach.GuestPath
    $guestPathAvailable = $Action -eq 'RELEASE' -or $guestPath -notin @($inspection.Target.GuestPaths | ForEach-Object { [string]$_ })
    $targetEvidence = [PSCustomObject][ordered]@{
        VMId=[string]$inspection.Target.VMId; SqlMajorVersion=$sqlVersion; GuestPath=$guestPath
        GuestPathAvailable=[bool]$guestPathAvailable; ObservedAt=Get-LabTimestamp
    }
    if (-not $OperationId) { $OperationId = [Guid]::NewGuid().ToString('D') }
    $targetStorageId = if ($Action -eq 'CLONE') { $OperationId } else { $null }
    if ($Action -eq 'CLONE') {
        if (-not $TargetLocationId) { $TargetLocationId = [string]$configuration.DefaultLocationId }
        if (-not $TargetLocationId) { throw 'HYPERV_PERSISTENT_DATA_TARGET_LOCATION_REQUIRED' }
    }
    $relativePath = if ($Action -eq 'CLONE') { "HyperV/Staging/PersistentData/$targetStorageId.vhdx" } else { $null }
    $intent = [PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.HyperVPersistentDataIntent/1.0'; OperationId=$OperationId; Action=$Action
        SourcePersistentStorageId=$PersistentStorageId; TargetPersistentStorageId=$targetStorageId
        TargetLocationId=if ($Action -eq 'CLONE') { $TargetLocationId } else { $null }
        TargetRelativePath=$relativePath; TargetRunId=[string]$targetLab.Run.runId; TargetScopeId=[string]$targetLab.Run.scopeId
        TargetVMName=[string]$targetLab.Instance.vmName; TargetSqlMajorVersion=$sqlVersion; TargetGuestPath=$guestPath
        DetachEvidence=$detach; TargetEvidence=$targetEvidence; DatabaseDisposition='EXPLICIT_RESTORE_OR_ATTACH_REQUIRED'
    }
    $plan = Get-LabHyperVPersistentDataPlan -Intent $intent -Catalog $catalog `
        -Configuration $configuration -RuntimeInspection $inspection
    if ([string]$plan.Status -ne 'READY') {
        throw "HYPERV_PERSISTENT_DATA_PLAN_BLOCKED: $(@($plan.Blockers) -join ',')"
    }
    $operationDirectory = Join-Path (Join-Path (Join-Path $DataRoot 'HyperV\Recovery') 'PersistentData') $OperationId
    $journal = Invoke-LabHyperVPersistentDataPlan -Plan $plan -OperationDirectory $operationDirectory -Configuration $configuration

    $connectionStateStatus = 'NOT_APPLICABLE'
    if ($Action -in @('REATTACH','RELEASE')) {
        try {
            $null = Set-LabHyperVPersistentDataConnectionState -Lab $targetLab -Action $Action -Plan $plan -Journal $journal
            $connectionStateStatus = 'COMMITTED'
        }
        catch {
            $connectionStateStatus = 'UPDATE_REQUIRED'
            Write-Warning "HYPERV_PERSISTENT_DATA_CONNECTION_STATE_UPDATE_REQUIRED: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{
        Action=$Action; Status=[string]$journal.Status; OperationId=$OperationId
        SourcePersistentStorageId=$PersistentStorageId
        TargetPersistentStorageId=if ($Action -eq 'CLONE') { [string]$plan.Target.PersistentStorageId } else { $null }
        TargetRunId=[string]$targetLab.Run.runId; CatalogRevision=[int]$journal.CatalogRevision
        DetachEvidenceStatus='VERIFIED'; DatabasesState=[string]$detach.DatabasesState
        ConnectionStateStatus=$connectionStateStatus
        DatabaseFilesOnline=$false; DatabaseActionRequired='EXPLICIT_RESTORE_OR_ATTACH'
    }
}
