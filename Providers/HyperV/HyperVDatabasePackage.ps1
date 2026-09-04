<#
.SYNOPSIS
    Bindet unveraenderliche Datenbankpakete an ein verwaltetes Hyper-V-SQL-Ziel.
.DESCRIPTION
    Loest das Ziel ausschliesslich aus einem scopegebundenen Run und dem live
    von SQL Server gemeldeten Default-Data-Verzeichnis auf. Paketobjekte werden
    in eine unabhaengige Gastkopie uebertragen, dort erneut gehasht und erst
    danach per COPY_THEN_ATTACH eingebunden. Freie Host- oder Gastpfade sind
    kein Bestandteil des oeffentlichen Vertrags.
#>

function Get-LabHyperVDatabasePackageAttachContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [string]$StateRoot
    )

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    if ([string]$lab.Instance.id -ne $InstanceId -or [string]$lab.Instance.provider -ne 'hyperv') {
        throw 'DATABASE_PACKAGE_HYPERV_TARGET_INSTANCE_MISMATCH'
    }
    if ([string]$lab.Instance.workload -ne 'sql') {
        throw 'DATABASE_PACKAGE_HYPERV_SQL_TARGET_REQUIRED'
    }
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId)
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') {
        throw 'DATABASE_PACKAGE_HYPERV_TARGET_VM_NOT_RUNNING'
    }

    $databaseName = [string]$Package.Record.DatabaseName
    $packageId = [string]$Package.Record.DatabasePackageId
    $observation = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId) `
        -Credential $Credential -ArgumentList @($databaseName, $packageId) -ScriptBlock {
            param($DatabaseName, $DatabasePackageId)
            $ErrorActionPreference = 'Stop'
            Add-Type -AssemblyName System.Data
            $connection = [Data.SqlClient.SqlConnection]::new(
                'Server=localhost;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;')
            try {
                $connection.Open()
                $command = $connection.CreateCommand()
                $command.CommandText = @'
SELECT
    CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) AS SqlMajorVersion,
    CONVERT(int, ISNULL(SERVERPROPERTY('FilestreamEffectiveLevel'), 0)) AS FileStreamLevel,
    CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultDataPath')) AS DefaultDataPath,
    CASE WHEN DB_ID(@databaseName) IS NULL THEN 0 ELSE 1 END AS DatabaseExists;
'@
                $null = $command.Parameters.Add('@databaseName', [Data.SqlDbType]::NVarChar, 128)
                $command.Parameters['@databaseName'].Value = $DatabaseName
                $reader = $command.ExecuteReader()
                if (-not $reader.Read()) { throw 'DATABASE_PACKAGE_HYPERV_SQL_TARGET_EVIDENCE_INVALID' }
                $sqlMajorVersion = [int]$reader.GetValue(0)
                $fileStreamLevel = [int]$reader.GetValue(1)
                $defaultDataPath = if ($reader.IsDBNull(2)) { $null } else { [string]$reader.GetValue(2) }
                $databaseExists = [int]$reader.GetValue(3) -eq 1
                $reader.Dispose()
            }
            finally {
                $connection.Dispose()
            }
            if ([string]::IsNullOrWhiteSpace($defaultDataPath) -or $defaultDataPath -notmatch '^[A-Za-z]:\\') {
                throw 'DATABASE_PACKAGE_HYPERV_DEFAULT_DATA_PATH_UNVERIFIED'
            }
            $defaultDataPath = [IO.Path]::GetFullPath($defaultDataPath).TrimEnd('\')
            $targetDirectory = [IO.Path]::GetFullPath((Join-Path $defaultDataPath (Join-Path 'SqlServerLab\DatabasePackages' $DatabasePackageId)))
            if (-not $targetDirectory.StartsWith("$defaultDataPath\", [StringComparison]::OrdinalIgnoreCase)) {
                throw 'DATABASE_PACKAGE_HYPERV_TARGET_PATH_SCOPE_INVALID'
            }
            $targetDirectoryEmpty = -not (Test-Path -LiteralPath $targetDirectory) -or
                @(Get-ChildItem -LiteralPath $targetDirectory -Force -ErrorAction Stop).Count -eq 0
            [PSCustomObject]@{
                SqlMajorVersion = $sqlMajorVersion
                FileStreamEnabled = $fileStreamLevel -gt 0
                DatabaseExists = $databaseExists
                DefaultDataPath = $defaultDataPath
                TargetDirectory = $targetDirectory
                TargetDirectoryEmpty = $targetDirectoryEmpty
            }
        }
    $observation = @($observation)[-1]
    if (-not $observation -or [int]$observation.SqlMajorVersion -lt 1 -or
        [string]::IsNullOrWhiteSpace([string]$observation.TargetDirectory)) {
        throw 'DATABASE_PACKAGE_HYPERV_SQL_TARGET_EVIDENCE_INVALID'
    }

    $defaultDataPath = [IO.Path]::GetFullPath([string]$observation.DefaultDataPath).TrimEnd('\')
    $targetDirectory = [IO.Path]::GetFullPath([string]$observation.TargetDirectory)
    if (-not $targetDirectory.StartsWith("$defaultDataPath\", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'DATABASE_PACKAGE_HYPERV_TARGET_PATH_SCOPE_INVALID'
    }
    $operationDirectory = Join-Path $lab.RunDirectory (Join-Path 'operations\database-package-attach' $packageId)
    [PSCustomObject]@{
        Lab = $lab
        TargetDirectory = $targetDirectory
        OperationDirectory = $operationDirectory
        TargetEvidence = [PSCustomObject]@{
            SqlMajorVersion = [int]$observation.SqlMajorVersion
            FileStreamEnabled = [bool]$observation.FileStreamEnabled
            TdeKeyAvailable = $false
            DatabaseExists = [bool]$observation.DatabaseExists
            ExclusiveUseAvailable = [bool]$observation.TargetDirectoryEmpty
            PackageWriterCount = if ([bool]$observation.TargetDirectoryEmpty) { 0 } else { 1 }
            TargetDirectoryEmpty = [bool]$observation.TargetDirectoryEmpty
        }
    }
}

function Copy-LabDatabasePackageToHyperVGuest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][PSCredential]$Credential
    )

    $lab = $Context.Lab
    $managed = Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId)
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') {
        throw 'DATABASE_PACKAGE_HYPERV_TARGET_VM_NOT_RUNNING'
    }
    $session = $null
    try {
        $session = New-PSSession -VMName ([string]$lab.Instance.vmName) -Credential $Credential -ErrorAction Stop
        $relativePaths = @($Package.Record.Objects | ForEach-Object { [string]$_.RelativePath })
        $null = Invoke-Command -Session $session -ArgumentList @([string]$Context.TargetDirectory, $relativePaths) -ScriptBlock {
            param($TargetDirectory, $RelativePaths)
            $ErrorActionPreference = 'Stop'
            if (Test-Path -LiteralPath $TargetDirectory) {
                if (@(Get-ChildItem -LiteralPath $TargetDirectory -Force).Count -gt 0) {
                    throw 'DATABASE_PACKAGE_HYPERV_TARGET_DIRECTORY_NOT_EMPTY'
                }
            }
            else {
                $null = New-Item -ItemType Directory -Path $TargetDirectory -Force
            }
            foreach ($relativePath in @($RelativePaths)) {
                $destination = [IO.Path]::GetFullPath((Join-Path $TargetDirectory $relativePath))
                if (-not $destination.StartsWith(([IO.Path]::GetFullPath($TargetDirectory).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'DATABASE_PACKAGE_HYPERV_OBJECT_PATH_SCOPE_INVALID'
                }
                $parent = Split-Path -Parent $destination
                if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                    $null = New-Item -ItemType Directory -Path $parent -Force
                }
            }
        } -ErrorAction Stop

        foreach ($object in @($Package.Record.Objects)) {
            $source = Join-Path ([string]$Package.Path) ([string]$object.RelativePath)
            $destination = Join-Path ([string]$Context.TargetDirectory) ([string]$object.RelativePath)
            Copy-Item -LiteralPath $source -Destination $destination -ToSession $session -Force -ErrorAction Stop
        }

        $expectedJson = @($Package.Record.Objects | ForEach-Object {
            [PSCustomObject]@{ RelativePath = [string]$_.RelativePath; Bytes = [long]$_.Bytes; Sha256 = [string]$_.Sha256 }
        }) | ConvertTo-Json -Compress -Depth 8
        $verification = Invoke-Command -Session $session -ArgumentList @([string]$Context.TargetDirectory, $expectedJson) -ScriptBlock {
            param($TargetDirectory, $ExpectedJson)
            $ErrorActionPreference = 'Stop'
            # Windows PowerShell 5.1 gibt ein JSON-Array aus ConvertFrom-Json
            # als einzelnes Object[]-Pipelineobjekt aus. Ein zusaetzliches @()
            # wuerde dieses Array verschachteln und alle Pfade zu einer einzigen
            # durch Leerzeichen verbundenen Zeichenfolge konvertieren.
            $expected = $ExpectedJson | ConvertFrom-Json
            foreach ($object in $expected) {
                $path = Join-Path $TargetDirectory ([string]$object.RelativePath)
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'DATABASE_PACKAGE_HYPERV_OBJECT_INCOMPLETE' }
                $item = Get-Item -LiteralPath $path -Force
                $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                if ([long]$item.Length -ne [long]$object.Bytes -or $hash -ne [string]$object.Sha256) {
                    throw 'DATABASE_PACKAGE_HYPERV_OBJECT_HASH_MISMATCH'
                }
            }
            [PSCustomObject]@{ Status = 'VERIFIED'; ObjectCount = $expected.Count }
        } -ErrorAction Stop
        $verification = @($verification)[-1]
        if ([string]$verification.Status -ne 'VERIFIED' -or
            [int]$verification.ObjectCount -ne @($Package.Record.Objects).Count) {
            throw 'DATABASE_PACKAGE_HYPERV_COPY_POSTCONDITION_FAILED'
        }
        [PSCustomObject]@{ Status = 'VERIFIED'; TargetCopyVerified = $true }
    }
    finally {
        if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
}

function Invoke-LabHyperVDatabasePackageSqlAttach {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][PSCredential]$Credential
    )

    $databaseFiles = @($Package.Record.DatabaseFiles | ForEach-Object {
        $file = $_
        $object = @($Package.Record.Objects | Where-Object DatabaseFileLogicalName -eq ([string]$file.LogicalName) | Select-Object -First 1)
        $relative = if ([bool]$file.IsDirectory) { [string]$file.RelativeRoot } else { [string]$object.RelativePath }
        [PSCustomObject]@{
            LogicalName = [string]$file.LogicalName
            Type = [string]$file.Type
            IsDirectory = [bool]$file.IsDirectory
            Path = [IO.Path]::GetFullPath((Join-Path ([string]$Context.TargetDirectory) $relative))
        }
    })
    $filesJson = $databaseFiles | ConvertTo-Json -Compress -Depth 8
    $lab = $Context.Lab
    $result = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId) `
        -Credential $Credential -ArgumentList @(
            [string]$Package.Record.DatabaseName,
            $filesJson,
            [int]$Package.Record.Source.SqlMajorVersion,
            [bool]$Package.Record.DatabaseMetadata.HasFileStream
        ) -ScriptBlock {
            param($DatabaseName, $FilesJson, $SourceSqlMajorVersion, $RequiresFileStream)
            $ErrorActionPreference = 'Stop'
            # ConvertFrom-Json unter Windows PowerShell 5.1 liefert das
            # JSON-Array bereits als Object[]. Nicht erneut verschachteln.
            $files = $FilesJson | ConvertFrom-Json
            foreach ($file in $files) {
                $pathType = if ([bool]$file.IsDirectory) { 'Container' } else { 'Leaf' }
                if (-not (Test-Path -LiteralPath ([string]$file.Path) -PathType $pathType)) {
                    throw 'DATABASE_PACKAGE_HYPERV_DATABASE_FILE_MISSING'
                }
            }
            Add-Type -AssemblyName System.Data
            $connection = [Data.SqlClient.SqlConnection]::new(
                'Server=localhost;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;')
            try {
                $connection.Open()
                $evidence = $connection.CreateCommand()
                $evidence.CommandText = "SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion')),CONVERT(int,ISNULL(SERVERPROPERTY('FilestreamEffectiveLevel'),0)),CASE WHEN DB_ID(@databaseName) IS NULL THEN 0 ELSE 1 END;"
                $null = $evidence.Parameters.Add('@databaseName', [Data.SqlDbType]::NVarChar, 128)
                $evidence.Parameters['@databaseName'].Value = $DatabaseName
                $reader = $evidence.ExecuteReader()
                if (-not $reader.Read()) { throw 'DATABASE_PACKAGE_HYPERV_SQL_TARGET_EVIDENCE_INVALID' }
                $targetMajor = [int]$reader.GetValue(0)
                $fileStreamLevel = [int]$reader.GetValue(1)
                $databaseExists = [int]$reader.GetValue(2) -eq 1
                $reader.Dispose()
                if ($targetMajor -lt [int]$SourceSqlMajorVersion) { throw 'TARGET_SQL_VERSION_OLDER_THAN_SOURCE' }
                if ([bool]$RequiresFileStream -and $fileStreamLevel -lt 1) { throw 'TARGET_FILESTREAM_CAPABILITY_MISSING' }
                if ($databaseExists) { throw 'TARGET_DATABASE_ALREADY_EXISTS' }

                $escapedName = $DatabaseName.Replace(']', ']]')
                $clauses = @($files | ForEach-Object {
                    "(FILENAME = N'$(([string]$_.Path).Replace("'", "''"))')"
                }) -join ",`n"
                $attach = $connection.CreateCommand()
                $attach.CommandTimeout = 600
                $attach.CommandText = "CREATE DATABASE [$escapedName] ON $clauses FOR ATTACH; ALTER DATABASE [$escapedName] SET MULTI_USER;"
                $null = $attach.ExecuteNonQuery()

                $verify = $connection.CreateCommand()
                $verify.CommandText = "SELECT state_desc FROM sys.databases WHERE name=@databaseName; SELECT physical_name FROM sys.master_files WHERE database_id=DB_ID(@databaseName) ORDER BY file_id;"
                $null = $verify.Parameters.Add('@databaseName', [Data.SqlDbType]::NVarChar, 128)
                $verify.Parameters['@databaseName'].Value = $DatabaseName
                $reader = $verify.ExecuteReader()
                $state = if ($reader.Read()) { [string]$reader.GetValue(0) } else { 'UNKNOWN' }
                $null = $reader.NextResult()
                $actual = [Collections.Generic.List[string]]::new()
                while ($reader.Read()) { $actual.Add([IO.Path]::GetFullPath([string]$reader.GetValue(0))) }
                $reader.Dispose()
                $expected = @($files | ForEach-Object { [IO.Path]::GetFullPath([string]$_.Path) } | Sort-Object)
                $actualSorted = @($actual | Sort-Object)
                $pathsMatch = $expected.Count -eq $actualSorted.Count
                if ($pathsMatch) {
                    for ($index = 0; $index -lt $expected.Count; $index++) {
                        if (-not [string]::Equals($expected[$index], $actualSorted[$index], [StringComparison]::OrdinalIgnoreCase)) {
                            $pathsMatch = $false
                            break
                        }
                    }
                }
                [PSCustomObject]@{
                    DatabaseState = $state
                    AttachmentCount = if ($state -eq 'ONLINE') { 1 } else { 0 }
                    PathsMatch = $pathsMatch
                }
            }
            finally {
                $connection.Dispose()
            }
        }
    return @($result)[-1]
}

function Invoke-LabHyperVDatabasePackageAttachPlan {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][PSCredential]$Credential
    )

    if ([string]$Plan.ContractVersion -ne 'SqlServerLab.DatabasePackageAttachPlan/1.0' -or
        [string]$Plan.Status -ne 'READY') {
        throw 'DATABASE_PACKAGE_HYPERV_READY_ATTACH_PLAN_REQUIRED'
    }
    if ([string]$Plan.DatabasePackageId -ne [string]$Package.Record.DatabasePackageId -or
        -not [string]::Equals([string]$Plan.TargetDirectory, [string]$Context.TargetDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'DATABASE_PACKAGE_HYPERV_ATTACH_CONTEXT_MISMATCH'
    }
    if (-not $PSCmdlet.ShouldProcess(
            "$($Context.Lab.Run.runId)/$($Context.Lab.Instance.id)",
            "Copy and attach database package $($Plan.DatabasePackageId)")) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $Context.OperationDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $Context.OperationDirectory -Force
    }
    $journalPath = Join-Path $Context.OperationDirectory 'database-package-attach-journal.json'
    $journal = [PSCustomObject][ordered]@{
        ContractVersion = 'SqlServerLab.DatabasePackageAttachJournal/1.0'
        DatabasePackageId = [string]$Plan.DatabasePackageId
        Status = 'COPYING'
        TargetDirectory = [string]$Plan.TargetDirectory
        TargetCopyVerified = $false
        AttachInvoked = $false
        PostconditionVerified = $false
        Recovery = 'REMOVE_UNATTACHED_TARGET_COPY'
        UpdatedAt = Get-LabTimestamp
    }
    Write-LabDatabasePackageAttachJournal -Journal $journal -Path $journalPath
    try {
        $copy = Copy-LabDatabasePackageToHyperVGuest -Context $Context -Package $Package -Credential $Credential
        if (-not [bool]$copy.TargetCopyVerified) { throw 'DATABASE_PACKAGE_HYPERV_COPY_POSTCONDITION_FAILED' }
        $journal.TargetCopyVerified = $true
        $journal.Status = 'ATTACHING'
        $journal.AttachInvoked = $true
        $journal.Recovery = 'DETACH_TARGET_COPY_AND_PRESERVE_PACKAGE'
        Write-LabDatabasePackageAttachJournal -Journal $journal -Path $journalPath

        $postcondition = Invoke-LabHyperVDatabasePackageSqlAttach -Context $Context -Package $Package -Credential $Credential
        $journal.Status = 'VERIFYING'
        Write-LabDatabasePackageAttachJournal -Journal $journal -Path $journalPath
        if ([string]$postcondition.DatabaseState -ne 'ONLINE' -or
            [int]$postcondition.AttachmentCount -ne 1 -or
            -not [bool]$postcondition.PathsMatch) {
            throw 'DATABASE_PACKAGE_ATTACH_POSTCONDITION_FAILED'
        }
        $journal.PostconditionVerified = $true
        $journal.Status = 'COMPLETED'
        $journal.Recovery = 'NOT_REQUIRED'
        Write-LabDatabasePackageAttachJournal -Journal $journal -Path $journalPath
        [PSCustomObject]@{
            Status = 'ATTACHED'
            DatabasePackageId = [string]$Plan.DatabasePackageId
            DatabaseName = [string]$Plan.DatabaseName
            JournalPath = $journalPath
        }
    }
    catch {
        $journal.Status = 'RECOVERY_REQUIRED'
        $journal.Recovery = if ($journal.AttachInvoked) {
            'DETACH_TARGET_COPY_AND_PRESERVE_PACKAGE'
        }
        else {
            'REMOVE_UNATTACHED_TARGET_COPY'
        }
        Write-LabDatabasePackageAttachJournal -Journal $journal -Path $journalPath
        throw
    }
}

function Invoke-LabHyperVDatabasePackageAttachRecovery {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][PSCredential]$Credential
    )

    if ([string]$Journal.ContractVersion -ne 'SqlServerLab.DatabasePackageAttachJournal/1.0' -or
        [string]$Journal.DatabasePackageId -ne [string]$Package.Record.DatabasePackageId -or
        [string]$Journal.Status -ne 'RECOVERY_REQUIRED' -or
        -not [string]::Equals([string]$Journal.TargetDirectory, [string]$Context.TargetDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'DATABASE_PACKAGE_ATTACH_RECOVERY_JOURNAL_INVALID'
    }
    if (-not $PSCmdlet.ShouldProcess(
            "$($Context.Lab.Run.runId)/$($Context.Lab.Instance.id)",
            "Recover database package attach $($Package.Record.DatabasePackageId)")) {
        return $null
    }
    $lab = $Context.Lab
    $result = Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId ([string]$lab.Run.runId) -ExpectedScopeId ([string]$lab.Run.scopeId) `
        -Credential $Credential -ArgumentList @(
            [string]$Package.Record.DatabaseName,
            [string]$Context.TargetDirectory,
            [string]$Journal.Recovery
        ) -ScriptBlock {
            param($DatabaseName, $TargetDirectory, $Recovery)
            $ErrorActionPreference = 'Stop'
            $target = [IO.Path]::GetFullPath($TargetDirectory).TrimEnd('\\')
            if ($target -notmatch '^[A-Za-z]:\\') { throw 'DATABASE_PACKAGE_HYPERV_TARGET_PATH_SCOPE_INVALID' }
            Add-Type -AssemblyName System.Data
            $connection = [Data.SqlClient.SqlConnection]::new(
                'Server=localhost;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;')
            try {
                $connection.Open()
                $query = $connection.CreateCommand()
                $query.CommandText = 'SELECT physical_name FROM sys.master_files WHERE database_id=DB_ID(@databaseName) ORDER BY file_id;'
                $null = $query.Parameters.Add('@databaseName', [Data.SqlDbType]::NVarChar, 128)
                $query.Parameters['@databaseName'].Value = $DatabaseName
                $reader = $query.ExecuteReader()
                $paths = [Collections.Generic.List[string]]::new()
                while ($reader.Read()) { $paths.Add([IO.Path]::GetFullPath([string]$reader.GetValue(0))) }
                $reader.Dispose()
                if ($Recovery -eq 'DETACH_TARGET_COPY_AND_PRESERVE_PACKAGE' -and $paths.Count -gt 0) {
                    foreach ($path in $paths) {
                        if (-not $path.StartsWith($target + '\\', [StringComparison]::OrdinalIgnoreCase)) {
                            throw 'DATABASE_PACKAGE_ATTACH_RECOVERY_FOREIGN_DATABASE_PATH'
                        }
                    }
                    $detach = $connection.CreateCommand()
                    $detach.CommandTimeout = 600
                    $detach.CommandText = 'ALTER DATABASE [' + $DatabaseName.Replace(']', ']]') + '] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; EXEC master.dbo.sp_detach_db @dbname = @databaseName;'
                    $null = $detach.Parameters.Add('@databaseName', [Data.SqlDbType]::NVarChar, 128)
                    $detach.Parameters['@databaseName'].Value = $DatabaseName
                    $null = $detach.ExecuteNonQuery()
                }
                elseif ($Recovery -eq 'REMOVE_UNATTACHED_TARGET_COPY') {
                    if ($paths.Count -ne 0) { throw 'DATABASE_PACKAGE_ATTACH_RECOVERY_DATABASE_STILL_ATTACHED' }
                    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
                }
                else { throw 'DATABASE_PACKAGE_ATTACH_RECOVERY_ACTION_INVALID' }
                $verify = $connection.CreateCommand()
                $verify.CommandText = 'SELECT CASE WHEN DB_ID(@databaseName) IS NULL THEN 0 ELSE 1 END;'
                $null = $verify.Parameters.Add('@databaseName', [Data.SqlDbType]::NVarChar, 128)
                $verify.Parameters['@databaseName'].Value = $DatabaseName
                $databaseAbsent = [int]$verify.ExecuteScalar() -eq 0
                if (-not $databaseAbsent) { throw 'DATABASE_PACKAGE_ATTACH_RECOVERY_POSTCONDITION_FAILED' }
                [PSCustomObject]@{ Status = 'RECOVERED'; DatabaseAbsent = $databaseAbsent }
            }
            finally { $connection.Dispose() }
        }
    $result = @($result)[-1]
    if ([string]$result.Status -ne 'RECOVERED' -or -not [bool]$result.DatabaseAbsent) {
        throw 'DATABASE_PACKAGE_ATTACH_RECOVERY_POSTCONDITION_FAILED'
    }
    return $result
}
