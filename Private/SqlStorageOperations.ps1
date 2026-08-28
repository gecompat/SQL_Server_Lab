function Assert-LabStorageManifestDatabaseCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$StorageIntent,
        [Parameter(Mandatory)][object[]]$Databases
    )

    $databaseFiles = @($StorageIntent.DatabaseFiles)
    $restoreRules = @($StorageIntent.RestoreRules)
    foreach ($database in $Databases) {
        $databaseName = [string]$database.name
        if ($database.restore) {
            if ($database.restore.sampleId) {
                throw "HYPERV_STORAGE_SAMPLE_RESTORE_UNSUPPORTED: $databaseName"
            }
            $matches = @($restoreRules | Where-Object { [string]$_.Database -eq $databaseName })
            if ($matches.Count -ne 1) {
                throw "LAB_STORAGE_RESTORE_RULE_EXACTLY_ONE_REQUIRED: $databaseName"
            }
            if (@($databaseFiles | Where-Object { [string]$_.Database -eq $databaseName }).Count -gt 0) {
                throw "LAB_STORAGE_DATABASE_CREATE_AND_RESTORE_CONFLICT: $databaseName"
            }
            continue
        }

        $expected = @(
            @($database.files.data | ForEach-Object { "data:$([string]$_.name)" })
            @($database.files.log | ForEach-Object { "log:$([string]$_.name)" })
        ) | Sort-Object
        $planned = @(
            $databaseFiles |
                Where-Object { [string]$_.Database -eq $databaseName } |
                ForEach-Object { "$([string]$_.FileType):$([string]$_.LogicalName)" }
        ) | Sort-Object
        if ($expected.Count -eq 0 -or $expected.Count -ne $planned.Count -or
            (Compare-Object -ReferenceObject $expected -DifferenceObject $planned).Count -gt 0) {
            throw "LAB_STORAGE_DATABASE_FILE_COVERAGE_MISMATCH: $databaseName"
        }
        if (@($database.files.data + $database.files.log | Where-Object { $_.path }).Count -gt 0) {
            throw "LAB_STORAGE_DATABASE_EXPLICIT_PATH_CONFLICT: $databaseName"
        }
        if (@($restoreRules | Where-Object { [string]$_.Database -eq $databaseName }).Count -gt 0) {
            throw "LAB_STORAGE_DATABASE_CREATE_AND_RESTORE_CONFLICT: $databaseName"
        }
    }

    $declaredNames = @($Databases | ForEach-Object { [string]$_.name })
    $orphanFile = @($databaseFiles | Where-Object { [string]$_.Database -notin $declaredNames } | Select-Object -First 1)
    $orphanRule = @($restoreRules | Where-Object { [string]$_.Database -notin $declaredNames } | Select-Object -First 1)
    if ($orphanFile.Count -gt 0) { throw "LAB_STORAGE_ORPHAN_DATABASE_FILE: $($orphanFile[0].Database)" }
    if ($orphanRule.Count -gt 0) { throw "LAB_STORAGE_ORPHAN_RESTORE_RULE: $($orphanRule[0].Database)" }
    return $true
}

function Get-LabVerifiedStorageRuntimeContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $planPath = Join-Path $runDirectory 'storage-bound-plan.json'
    $receiptPath = Join-Path $runDirectory 'storage-runtime-receipt.json'
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { throw 'LAB_STORAGE_BOUND_PLAN_REQUIRED' }
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw 'LAB_STORAGE_RUNTIME_RECEIPT_REQUIRED' }
    $plan = Get-Content -LiteralPath $planPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    $null = Assert-LabStorageBoundPlan -Plan $plan
    $null = Assert-LabStorageRuntimeReceipt -Receipt $receipt
    if ([string]$plan.RunId -ne $RunId -or [string]$receipt.RunId -ne $RunId -or
        [string]$plan.InstanceId -ne $InstanceId -or [string]$receipt.InstanceId -ne $InstanceId -or
        [string]$plan.PlanId -ne [string]$receipt.PlanId -or [string]$plan.Provider -ne [string]$receipt.Provider) {
        throw 'LAB_STORAGE_PLAN_RECEIPT_IDENTITY_MISMATCH'
    }
    if ([string]$plan.Status -ne 'READY') { throw 'LAB_STORAGE_BOUND_PLAN_NOT_READY' }
    $retryableSqlOperation = [string]$receipt.Status -eq 'RECOVERY_REQUIRED' -and
        [string]$receipt.Recovery.Status -eq 'RETRY_SQL_OPERATION'
    if ([string]$receipt.Status -ne 'VERIFIED' -and -not $retryableSqlOperation) {
        throw "LAB_STORAGE_RUNTIME_NOT_VERIFIED: $($receipt.Status)"
    }
    return [PSCustomObject]@{
        RunDirectory=$runDirectory; PlanPath=$planPath; ReceiptPath=$receiptPath
        Plan=$plan; Receipt=$receipt; StateRoot=$StateRoot
    }
}

function Resolve-LabStorageDatabaseFilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][object[]]$DataFiles,
        [Parameter(Mandatory)][object[]]$LogFiles
    )

    $resolved = @{ DataFiles=@(); LogFiles=@() }
    foreach ($spec in @(
        [PSCustomObject]@{ Role='database-data'; FileType='data'; Input=@($DataFiles); Output='DataFiles' },
        [PSCustomObject]@{ Role='database-log'; FileType='log'; Input=@($LogFiles); Output='LogFiles' }
    )) {
        $planned = @($Context.Plan.SqlFiles | Where-Object {
            [string]$_.Database -eq $DatabaseName -and [string]$_.Role -eq [string]$spec.Role
        })
        if ($planned.Count -ne @($spec.Input).Count) {
            throw "LAB_STORAGE_DATABASE_FILE_COUNT_MISMATCH: $DatabaseName/$($spec.FileType)"
        }
        foreach ($inputFile in @($spec.Input)) {
            $logicalName = [string]$inputFile.name
            $planMatches = @($planned | Where-Object { [string]$_.LogicalName -eq $logicalName })
            $receiptMatches = @($Context.Receipt.FileBindings | Where-Object {
                [string]$_.Database -eq $DatabaseName -and [string]$_.Role -eq [string]$spec.Role -and
                [string]$_.LogicalName -eq $logicalName
            })
            if ($planMatches.Count -ne 1 -or $receiptMatches.Count -ne 1) {
                throw "LAB_STORAGE_DATABASE_FILE_BINDING_EXACTLY_ONE_REQUIRED: $DatabaseName/$logicalName"
            }
            $targetPath = [string]$receiptMatches[0].SqlPhysicalPath
            if (-not $targetPath -or [string]$planMatches[0].GuestPath -ne [string]$receiptMatches[0].GuestPath) {
                throw "LAB_STORAGE_DATABASE_FILE_RUNTIME_PATH_MISMATCH: $DatabaseName/$logicalName"
            }
            if ($inputFile.path -and -not [string]::Equals([string]$inputFile.path, $targetPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "LAB_STORAGE_DATABASE_EXPLICIT_PATH_CONFLICT: $DatabaseName/$logicalName"
            }
            $resolved[$spec.Output] += [PSCustomObject]@{
                name=$logicalName; path=$targetPath
                sizeMB=$(if ($null -ne $inputFile.sizeMB) { [int]$inputFile.sizeMB } elseif ($spec.FileType -eq 'log') { 32 } else { 64 })
                filegrowthMB=$(if ($null -ne $inputFile.filegrowthMB) { [int]$inputFile.filegrowthMB } elseif ($spec.FileType -eq 'log') { 32 } else { 64 })
            }
        }
    }
    return [PSCustomObject]$resolved
}

function ConvertFrom-LabRestoreFileListOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$FileListOutput)

    $files = [Collections.Generic.List[object]]::new()
    foreach ($value in $FileListOutput) {
        if ($value -isnot [string] -and $value.PSObject.Properties['LogicalName'] -and $value.PSObject.Properties['Type']) {
            $logicalName = [string]$value.LogicalName
            $fileType = [string]$value.Type
        }
        else {
            $line = ([string]$value).Trim()
            if ($line -notmatch '^([^|]+)\|[^|]*\|([DLFS])(?:\||$)') { continue }
            $logicalName = $Matches[1].Trim(); $fileType = $Matches[2]
        }
        if (-not $logicalName -or $fileType -notin @('D','L','S','F')) { continue }
        if (@($files | Where-Object { [string]$_.LogicalName -eq $logicalName }).Count -gt 0) {
            throw "LAB_STORAGE_RESTORE_LOGICAL_NAME_DUPLICATE: $logicalName"
        }
        $files.Add([PSCustomObject]@{ LogicalName=$logicalName; Type=$fileType })
    }
    if ($files.Count -eq 0) { throw 'LAB_STORAGE_RESTORE_FILELIST_EMPTY' }
    return @($files)
}

function Resolve-LabStorageRestoreFilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][object[]]$FileListOutput
    )

    $files = @(ConvertFrom-LabRestoreFileListOutput -FileListOutput $FileListOutput)
    $rules = @{}
    foreach ($role in @('restore-data-rule','restore-log-rule')) {
        $planMatches = @($Context.Plan.SqlFiles | Where-Object { [string]$_.Database -eq $DatabaseName -and [string]$_.Role -eq $role })
        $receiptMatches = @($Context.Receipt.FileBindings | Where-Object { [string]$_.Database -eq $DatabaseName -and [string]$_.Role -eq $role })
        if ($planMatches.Count -ne 1 -or $receiptMatches.Count -ne 1) {
            throw "LAB_STORAGE_RESTORE_RULE_BINDING_EXACTLY_ONE_REQUIRED: $DatabaseName/$role"
        }
        if ([string]$planMatches[0].GuestPath -ne [string]$receiptMatches[0].GuestPath) {
            throw "LAB_STORAGE_RESTORE_RULE_RUNTIME_PATH_MISMATCH: $DatabaseName/$role"
        }
        $rules[$role] = $receiptMatches[0]
    }

    $dataIndex=0; $logIndex=0; $specialIndex=0; $fullTextIndex=0
    $result = [Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        switch ([string]$file.Type) {
            'D' { $dataIndex++; $role='restore-data'; $rule=$rules['restore-data-rule']; $name=if($dataIndex -eq 1){"${DatabaseName}_Data1.mdf"}else{"${DatabaseName}_Data${dataIndex}.ndf"}; $sqlType=0 }
            'L' { $logIndex++; $role='restore-log'; $rule=$rules['restore-log-rule']; $name="${DatabaseName}_Log${logIndex}.ldf"; $sqlType=1 }
            'S' { $specialIndex++; $role='restore-special'; $rule=$rules['restore-data-rule']; $name="${DatabaseName}_SpecialData${specialIndex}"; $sqlType=2 }
            'F' { $fullTextIndex++; $role='restore-fulltext'; $rule=$rules['restore-data-rule']; $name="${DatabaseName}_FullText${fullTextIndex}"; $sqlType=4 }
        }
        $path = Get-LabStorageGuestChildPath -Root ([string]$rule.SqlPhysicalPath) -Child $name
        $result.Add([PSCustomObject]@{
            Database=$DatabaseName; Role=$role; LogicalName=[string]$file.LogicalName; FileType=[string]$file.Type
            SqlType=[int]$sqlType; SqlPhysicalPath=$path; LocationId=[string]$rule.LocationId
            HostPath=[string]$rule.HostPath; RuntimeStorageId=[string]$rule.RuntimeStorageId
            GuestDiskId=[string]$rule.GuestDiskId; GuestPath=$path
        })
    }
    if ($result.Count -ne $files.Count -or @($result.SqlPhysicalPath | Sort-Object -Unique).Count -ne $files.Count) {
        throw "LAB_STORAGE_RESTORE_TARGET_NOT_UNIQUE: $DatabaseName"
    }
    return @($result)
}

function New-LabStorageRestoreMoveStatements {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$FilePlan)
    return @($FilePlan | ForEach-Object {
        "MOVE N'$(([string]$_.LogicalName).Replace("'", "''"))' TO N'$(([string]$_.SqlPhysicalPath).Replace("'", "''"))'"
    })
}

function New-LabStorageMasterFilesVerificationQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][object[]]$FilePlan
    )

    $databaseLiteral = $DatabaseName.Replace("'", "''")
    $rows = @($FilePlan | ForEach-Object {
        $logical = ([string]$(if ($_.PSObject.Properties['name']) { $_.name } else { $_.LogicalName })).Replace("'", "''")
        $path = ([string]$(if ($_.PSObject.Properties['path']) { $_.path } else { $_.SqlPhysicalPath })).Replace("'", "''")
        $type = if ($_.PSObject.Properties['SqlType']) { [int]$_.SqlType } elseif ([string]$_.Role -match 'log' -or $path -match '\.ldf$') { 1 } else { 0 }
        "(N'$logical',N'$path',$type)"
    })
    if ($rows.Count -eq 0) { throw "LAB_STORAGE_SQL_VERIFICATION_FILES_REQUIRED: $DatabaseName" }
    return @"
DECLARE @Expected TABLE(LogicalName sysname NOT NULL, PhysicalPath nvarchar(4000) NOT NULL, FileType tinyint NOT NULL);
INSERT @Expected(LogicalName,PhysicalPath,FileType) VALUES $($rows -join ',');
IF DB_ID(N'$databaseLiteral') IS NULL THROW 51000, 'LAB_STORAGE_SQL_DATABASE_NOT_FOUND', 1;
IF EXISTS (
    SELECT LogicalName,PhysicalPath COLLATE Latin1_General_100_CI_AS,FileType FROM @Expected
    EXCEPT
    SELECT name,physical_name COLLATE Latin1_General_100_CI_AS,type FROM sys.master_files WHERE database_id=DB_ID(N'$databaseLiteral')
) OR EXISTS (
    SELECT name,physical_name COLLATE Latin1_General_100_CI_AS,type FROM sys.master_files WHERE database_id=DB_ID(N'$databaseLiteral')
    EXCEPT
    SELECT LogicalName,PhysicalPath COLLATE Latin1_General_100_CI_AS,FileType FROM @Expected
) THROW 51000, 'LAB_STORAGE_SQL_MASTER_FILES_POSTCONDITION_FAILED', 1;
"@
}

function Start-LabStorageSqlOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$OperationId, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$DatabaseName)
    $receipt=$Context.Receipt
    $receipt.Status='APPLYING'
    $receipt.Postconditions=@($receipt.Postconditions | Where-Object { [string]$_.OperationId -ne $OperationId }) + @(
        [PSCustomObject]@{ Name="sql-storage-$Kind"; OperationId=$OperationId; Database=$DatabaseName; Status='PENDING' }
    )
    $receipt.Recovery=[PSCustomObject]@{ Status='RETRY_SQL_OPERATION'; OperationId=$OperationId; ReceiptPath=$Context.ReceiptPath }
    $null=Assert-LabStorageRuntimeReceipt -Receipt $receipt
    Write-LabArtifactJsonAtomic -Path $Context.ReceiptPath -InputObject $receipt
    return $Context
}

function Complete-LabStorageSqlOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$OperationId,[Parameter(Mandatory)][string]$Kind,[Parameter(Mandatory)][string]$DatabaseName,[Parameter(Mandatory)][object[]]$Files)
    $receipt=$Context.Receipt
    $receipt.Postconditions=@($receipt.Postconditions | Where-Object { [string]$_.OperationId -ne $OperationId }) + @(
        [PSCustomObject]@{ Name="sql-storage-$Kind"; OperationId=$OperationId; Database=$DatabaseName; Status='PASS'; FileCount=@($Files).Count; VerifiedAt=[datetime]::UtcNow.ToString('o') }
    )
    if ($Kind -eq 'restore') {
        $staticBindings=@($receipt.FileBindings | Where-Object { [string]$_.OperationId -ne $OperationId })
        $dynamicBindings=@($Files | ForEach-Object {
            [PSCustomObject]@{
                OperationId=$OperationId; Database=$DatabaseName; Role=[string]$_.Role; LogicalName=[string]$_.LogicalName
                LocationId=[string]$_.LocationId; HostPath=[string]$_.HostPath; RuntimeStorageId=[string]$_.RuntimeStorageId
                GuestDiskId=[string]$_.GuestDiskId; GuestPath=[string]$_.GuestPath; SqlPhysicalPath=[string]$_.SqlPhysicalPath
            }
        })
        $receipt.FileBindings=@($staticBindings + $dynamicBindings)
    }
    $receipt.Status='VERIFIED'; $receipt.Recovery=[PSCustomObject]@{ Status='NOT_REQUIRED' }
    $null=Assert-LabStorageRuntimeReceipt -Receipt $receipt
    Write-LabArtifactJsonAtomic -Path $Context.ReceiptPath -InputObject $receipt
    return $receipt
}

function Fail-LabStorageSqlOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$OperationId,[Parameter(Mandatory)][string]$ErrorMessage)
    $receipt=$Context.Receipt; $receipt.Status='RECOVERY_REQUIRED'
    $errorCode=if($ErrorMessage -cmatch '[A-Z][A-Z0-9_]{5,127}'){([string]$Matches[0]).TrimEnd('_')}else{'SQL_STORAGE_OPERATION_FAILED'}
    $receipt.Postconditions=@($receipt.Postconditions | ForEach-Object { if([string]$_.OperationId -eq $OperationId){$_.Status='FAIL';$_}else{$_} })
    $receipt.Recovery=[PSCustomObject]@{ Status='RETRY_SQL_OPERATION'; OperationId=$OperationId; ErrorCode=$errorCode; ReceiptPath=$Context.ReceiptPath }
    $null=Assert-LabStorageRuntimeReceipt -Receipt $receipt
    Write-LabArtifactJsonAtomic -Path $Context.ReceiptPath -InputObject $receipt
    return $receipt
}

function Copy-LabFileToHyperVGuest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [string]$StateRoot
    )
    $lab=Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $managed=Get-HyperVManagedVM -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if(-not $managed -or [string]$managed.VM.State -ne 'Running'){throw 'HYPERV_STORAGE_FILE_COPY_VM_NOT_RUNNING'}
    $session=$null
    try{
        $session=New-PSSession -VMName ([string]$lab.Instance.vmName) -Credential $Credential -ErrorAction Stop
        $directory=Split-Path -Parent $DestinationPath
        Invoke-Command -Session $session -ArgumentList $directory -ScriptBlock { param($Path) if(-not(Test-Path -LiteralPath $Path)){New-Item -Path $Path -ItemType Directory -Force|Out-Null} } -ErrorAction Stop
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -ToSession $session -Force -ErrorAction Stop
    }
    finally{if($session){Remove-PSSession -Session $session -ErrorAction SilentlyContinue}}
    return $DestinationPath
}

function Remove-LabHyperVGuestFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][PSCredential]$Credential,[string]$StateRoot)
    $lab=Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $null=Invoke-HyperVPowerShellDirect -VMName ([string]$lab.Instance.vmName) -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId -Credential $Credential -ArgumentList @($Path) -ScriptBlock { param($Target) if(Test-Path -LiteralPath $Target -PathType Leaf){Remove-Item -LiteralPath $Target -Force -ErrorAction Stop}; [PSCustomObject]@{Removed=(-not(Test-Path -LiteralPath $Target))} }
}
