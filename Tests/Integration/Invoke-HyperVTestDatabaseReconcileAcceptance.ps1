#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt den nativen Hyper-V-Testdatenbank-Reconcile gegen SQL Server 2025 aus.
.DESCRIPTION
    Erstellt aus einem verifizierten SQL_PREPARED_SEALED-Artifact einen neuen,
    scopegebundenen Manifest-Run. Der Lauf prueft den oeffentlichen read-only
    Plan, WhatIf, Addition, No-op, eigentumsgebundene Entfernung, erneuten No-op,
    Fremddatenbankschutz, VM-Restart und vollstaendigen Cleanup.
.PARAMETER ArtifactId
    Optionales SQL_PREPARED_SEALED-Artifact. Ohne Angabe wird das neueste
    verifizierte SQL-2025-Artifact im State Root verwendet.
.PARAMETER StateRoot
    Optionaler State Root. Der Runner erzeugt darin genau einen neuen Run.
.PARAMETER OobeTimeoutSeconds
    Timeout fuer Windows-Spezialisierung, CompleteImage und SQL-Readiness.
.PARAMETER KeepOnFailure
    Belaesst einen fehlgeschlagenen Run samt Journal fuer den Recovery-Pfad.
#>
[CmdletBinding()]
param(
    [string]$ArtifactId,
    [string]$StateRoot,
    [ValidateRange(300, 3600)][int]$OobeTimeoutSeconds = 1200,
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-db-reconcile-' + [Guid]::NewGuid().ToString('N'))
$baseManifestPath = Join-Path $testRoot 'base.json'
$addManifestPath = Join-Path $testRoot 'add-chinook.json'
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$module = $null
$lab = $null
$ownedPaths = @()
$completed = $false
$mutex = [Threading.Mutex]::new($false, 'Global\SQL_Server_Lab_HyperV_Test_Database_Acceptance')
$mutexAcquired = $false

function Assert-HyperVTestDatabaseAcceptance {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description,
        [string]$Evidence
    )
    if (-not $Condition) {
        throw "HYPERV_TEST_DATABASE_ACCEPTANCE_FAILED: $Description$(if ($Evidence) { ": $Evidence" })"
    }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function Invoke-Private {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$Arguments=@())
    & $module $ScriptBlock @Arguments
}

function Write-TestDatabaseManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LabName,
        [Parameter(Mandatory)][string]$PreparedArtifactId,
        [switch]$IncludeChinook
    )

    $instance = [ordered]@{
        id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off'
        network=[ordered]@{intent='hostOnly';exposure='host'}
        hyperv=[ordered]@{
            preparedImageId=$PreparedArtifactId;memoryStartupMB=6144;processorCount=4
            sqlPort=1433;guestPasswordMode='prompt'
        }
        storageIntent=[ordered]@{
            contractVersion='SqlServerLab.StorageIntent/1.0';placementPolicy='logical-only';physicalIsolation='not-required'
            roles=[ordered]@{
                defaultData=[ordered]@{selector='default'}
                defaultLog=[ordered]@{selector='default'}
                backup=[ordered]@{selector='default'}
            }
            tempDb=[ordered]@{
                distribution='single-location';dataFileCount=1;dataLocationSelectors=@('default')
                logPlacement=[ordered]@{selector='default';logicalName='templog';fileName='templog.ldf';sizeMB=64;growth='32MB'}
            }
            databaseFiles=@();restoreRules=@()
        }
    }
    if ($IncludeChinook) {
        $instance.databases = @([ordered]@{name='Chinook';sample=[ordered]@{id='chinook';variant='sql-server'}})
    }
    $manifest = [ordered]@{
        '$schema'=(Join-Path $repoRoot 'Schemas/lab-manifest.schema.json')
        name=$LabName
        automation=[ordered]@{mode='unattended'}
        instances=@($instance)
    }
    $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Invoke-AcceptanceQuery {
    param([Parameter(Mandatory)][string]$Query, [string]$Database = 'master')
    $connection = [Data.SqlClient.SqlConnection]::new()
    $connection.ConnectionString = "Server=$script:sqlAddress,$script:sqlPort;Database=$Database;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;"
    $connection.Credential = [Data.SqlClient.SqlCredential]::new('sa', $script:saPassword)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 120
        $command.CommandText = $Query
        $reader = $command.ExecuteReader()
        $values = [Collections.Generic.List[string]]::new()
        while ($reader.Read()) {
            if (-not $reader.IsDBNull(0)) { $values.Add([string]$reader.GetValue(0)) }
        }
        $reader.Dispose()
        return @($values)
    }
    finally { $connection.Dispose() }
}

function Test-ScopedTemporaryRoot {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $actualParent = [IO.Directory]::GetParent($resolved).FullName.TrimEnd('\')
    return $actualParent.Equals($expectedParent, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^sql-lab-hv-db-reconcile-[a-f0-9]{32}$'
}

try {
    $mutexAcquired = $mutex.WaitOne([TimeSpan]::FromMinutes(15))
    if (-not $mutexAcquired) { throw 'HYPERV_TEST_DATABASE_ACCEPTANCE_HOST_LOCK_TIMEOUT' }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-HyperVTestDatabaseAcceptance `
        $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) `
        'Runner arbeitet erhoeht'
    Get-Command Get-VM -ErrorAction Stop | Out-Null

    $null = New-Item -Path $testRoot -ItemType Directory -Force
    $module = Import-Module $modulePath -Force -PassThru
    if (-not $StateRoot) { $StateRoot = Invoke-Private { Get-LabStateRoot } }
    $env:SQL_SERVER_LAB_STATE = $StateRoot

    if (-not $ArtifactId) {
        $artifact = Invoke-Private {
            param($Root)
            @(Get-HyperVImageArtifact -StateRoot $Root -SkipIntegrityCheck | Where-Object {
                [string]$_.artifactState -eq 'SQL_PREPARED_SEALED' -and
                [string]$_.sql.version -eq '2025' -and [string]$_.licenseType -ne 'test-only'
            } | Sort-Object { [datetime]$_.registeredAt } -Descending | Select-Object -First 1)[0]
        } @($StateRoot)
        if (-not $artifact) { throw 'HYPERV_TEST_DATABASE_SQL_PREPARED_ARTIFACT_NOT_FOUND' }
        $ArtifactId = [string]$artifact.artifactId
    }
    $artifact = Invoke-Private {
        param($Id,$Root)
        Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root
    } @($ArtifactId,$StateRoot)
    Assert-HyperVTestDatabaseAcceptance (
        [string]$artifact.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$artifact.sql.version -eq '2025'
    ) 'Verifiziertes SQL-2025-Prepared-Artifact ist verfuegbar' $ArtifactId

    $labName = 'hv-db-reconcile-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    Write-TestDatabaseManifest -Path $baseManifestPath -LabName $labName -PreparedArtifactId $ArtifactId
    Write-TestDatabaseManifest -Path $addManifestPath -LabName $labName -PreparedArtifactId $ArtifactId -IncludeChinook
    $baseValidation = Test-SqlServerLabManifest -Path $baseManifestPath
    $addValidation = Test-SqlServerLabManifest -Path $addManifestPath
    Assert-HyperVTestDatabaseAcceptance ($baseValidation.IsValid -and $addValidation.IsValid) `
        'Basis- und Sample-Zielmanifest sind vor Mutation gueltig' (($baseValidation.Errors + $addValidation.Errors) -join '; ')

    $guestPassword = Invoke-Private { New-HyperVSqlUnattendedPassword }
    $script:saPassword = Invoke-Private { New-HyperVSqlUnattendedPassword }
    $lab = New-SqlServerLab -Manifest $baseManifestPath -GuestPassword $guestPassword `
        -SqlSaPassword $script:saPassword -NonInteractive -StateRoot $StateRoot `
        -Region AT -SystemLocale de-AT -UiLanguage en-US -InputLocale '0407:00000407' `
        -TimeZone 'W. Europe Standard Time'
    Assert-HyperVTestDatabaseAcceptance ([string]$lab.State -eq 'RUNNING') 'Isolierter SQL-Prepared-Manifest-Run ist bereit'
    $runId = [string]$lab.RunId
    $context = Invoke-Private { param($Id,$Root) Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root } @($runId,$StateRoot)
    $identity = Invoke-Private {
        param($VmName,$RunId,$ScopeId)
        (Get-HyperVManagedVM -VMName $VmName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId).Identity
    } @([string]$context.Instance.vmName,$runId,[string]$context.Run.scopeId)
    $ownedPaths = @([string]$identity.childVhdxPath) + @($identity.additionalDrives | ForEach-Object { [string]$_.path })
    $script:sqlAddress = [string]$context.Instance.host
    $script:sqlPort = [int]$context.Instance.port
    Assert-HyperVTestDatabaseAcceptance (
        -not [string]::IsNullOrWhiteSpace($script:sqlAddress) -and $script:sqlPort -gt 0
    ) 'Host-SQL-Zugriff fuer den Sample-Handler ist gebunden'

    $null = Invoke-AcceptanceQuery -Query 'CREATE DATABASE [NativeForeignEvidence];'
    $null = Invoke-AcceptanceQuery -Database NativeForeignEvidence -Query `
        "CREATE TABLE dbo.Marker(Id int NOT NULL PRIMARY KEY, Value nvarchar(64) NOT NULL); INSERT dbo.Marker VALUES(1,N'foreign-preserved');"
    $initialDatabases = @(Invoke-AcceptanceQuery -Query "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name IN (N'Chinook',N'NativeForeignEvidence') ORDER BY name;")
    Assert-HyperVTestDatabaseAcceptance (
        $initialDatabases -contains 'NativeForeignEvidence' -and $initialDatabases -notcontains 'Chinook'
    ) 'Fremde Schutzdatenbank existiert und Chinook ist anfangs abwesend'

    $addPlan = Get-SqlServerLabReconcilePlan -RunId $runId -HyperVTestDatabases `
        -ManifestPath $addManifestPath -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVTestDatabaseAcceptance (
        [string]$addPlan.HighestChangeClass -eq 'live' -and
        @($addPlan.Diff | Where-Object Kind -eq 'add-sample').Count -eq 1 -and -not $addPlan.MutationAllowed
    ) 'Read-only Plan erkennt genau eine katalogisierte Addition'
    $whatIf = Invoke-SqlServerLabReconcileAction -RunId $runId -RepairHyperVTestDatabases `
        -ManifestPath $addManifestPath -InstanceId primary -SqlSaPassword $script:saPassword `
        -StateRoot $StateRoot -WhatIf
    $journalPath = Join-Path $context.RunDirectory 'hyperv-test-database-reconcile-journal.local.json'
    Assert-HyperVTestDatabaseAcceptance (
        [string]$whatIf.ExecutionSummary.Status -eq 'WOULD_EXECUTE' -and
        -not (Test-Path -LiteralPath $journalPath) -and
        @(Invoke-AcceptanceQuery -Query "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name=N'Chinook';").Count -eq 0
    ) 'WhatIf schreibt weder Journal noch Datenbankzustand'

    $addResult = Invoke-SqlServerLabReconcileAction -RunId $runId -RepairHyperVTestDatabases `
        -ManifestPath $addManifestPath -InstanceId primary -SqlSaPassword $script:saPassword `
        -StateRoot $StateRoot -Confirm:$false
    Assert-HyperVTestDatabaseAcceptance ([string]$addResult.ExecutionSummary.Status -eq 'SUCCEEDED') `
        'Katalogisiertes Chinook-Sample wurde ueber den oeffentlichen Executor hinzugefuegt' `
        ($addResult.ExecutionSummary.Errors -join '; ')
    $artistCount = @(Invoke-AcceptanceQuery -Database Chinook -Query 'SET NOCOUNT ON; SELECT COUNT_BIG(*) FROM dbo.Artist;')[0]
    $foreignMarker = @(Invoke-AcceptanceQuery -Database NativeForeignEvidence -Query "SET NOCOUNT ON; SELECT Value FROM dbo.Marker WHERE Id=1;")[0]
    Assert-HyperVTestDatabaseAcceptance ([long]$artistCount -gt 0 -and $foreignMarker -eq 'foreign-preserved') `
        'Sample-Inhalt ist echt und die fremde Datenbank blieb unveraendert'

    $ownershipPath = Join-Path $context.RunDirectory 'hyperv-test-database-ownership.local.json'
    $ownership = Get-Content -LiteralPath $ownershipPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $addNoOp = Get-SqlServerLabReconcilePlan -RunId $runId -HyperVTestDatabases `
        -ManifestPath $addManifestPath -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVTestDatabaseAcceptance (
        @($ownership.Entries).Count -eq 1 -and [string]$ownership.Entries[0].SampleId -eq 'chinook' -and $addNoOp.IsNoOp
    ) 'VM-gebundenes Ownership-Receipt und zweiter Add-Lauf sind konvergiert'

    $removePlan = Get-SqlServerLabReconcilePlan -RunId $runId -HyperVTestDatabases `
        -ManifestPath $baseManifestPath -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVTestDatabaseAcceptance (
        [string]$removePlan.HighestChangeClass -eq 'live' -and
        @($removePlan.Diff | Where-Object Kind -eq 'remove-owned-sample').Count -eq 1
    ) 'Read-only Plan erlaubt nur die eigentumsgebundene Sample-Entfernung'
    $removeResult = Invoke-SqlServerLabReconcileAction -RunId $runId -RepairHyperVTestDatabases `
        -ManifestPath $baseManifestPath -InstanceId primary -StateRoot $StateRoot -Confirm:$false
    Assert-HyperVTestDatabaseAcceptance ([string]$removeResult.ExecutionSummary.Status -eq 'SUCCEEDED') `
        'Ownership-gebundene Entfernung wurde mit verifiziertem Recovery-Backup abgeschlossen' `
        ($removeResult.ExecutionSummary.Errors -join '; ')
    $remainingDatabases = @(Invoke-AcceptanceQuery -Query "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name IN (N'Chinook',N'NativeForeignEvidence') ORDER BY name;")
    $foreignMarker = @(Invoke-AcceptanceQuery -Database NativeForeignEvidence -Query "SET NOCOUNT ON; SELECT Value FROM dbo.Marker WHERE Id=1;")[0]
    Assert-HyperVTestDatabaseAcceptance (
        $remainingDatabases -notcontains 'Chinook' -and $remainingDatabases -contains 'NativeForeignEvidence' -and
        $foreignMarker -eq 'foreign-preserved'
    ) 'Entfernung loescht nur das eigene Sample und bewahrt die fremde Datenbank'

    $finalOwnership = Get-Content -LiteralPath $ownershipPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $removeNoOp = Get-SqlServerLabReconcilePlan -RunId $runId -HyperVTestDatabases `
        -ManifestPath $baseManifestPath -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVTestDatabaseAcceptance (
        @($finalOwnership.Entries).Count -eq 0 -and [string]$journal.Status -eq 'COMPLETED' -and $removeNoOp.IsNoOp
    ) 'Ownership, Journal und zweiter Remove-Lauf sind konvergiert'

    Restart-SqlServerLab -RunId $runId -TimeoutSeconds $OobeTimeoutSeconds -Force -Confirm:$false | Out-Null
    $foreignMarkerAfterRestart = @(Invoke-AcceptanceQuery -Database NativeForeignEvidence -Query "SET NOCOUNT ON; SELECT Value FROM dbo.Marker WHERE Id=1;")[0]
    Assert-HyperVTestDatabaseAcceptance ($foreignMarkerAfterRestart -eq 'foreign-preserved') `
        'Fremde Datenbank bleibt nach vollstaendigem VM-Restart erhalten'

    $cleanup = Remove-SqlServerLab -RunId $runId -StateRoot $StateRoot -Force -Confirm:$false
    Assert-HyperVTestDatabaseAcceptance ([string]$cleanup.Status -in @('REMOVED','COMPLETED')) `
        'Run wurde scopegebunden entfernt' ([string]$cleanup.Status)
    $lab = $null
    foreach ($path in @($ownedPaths | Where-Object { $_ })) {
        Assert-HyperVTestDatabaseAcceptance (-not (Test-Path -LiteralPath $path)) 'Run-eigene VHDX wurde entfernt'
    }
    $completed = $true
}
catch {
    if ($lab -and $KeepOnFailure) {
        Write-Host "RECOVERY_RUN_ID=$([string]$lab.RunId)"
        Write-Host "RECOVERY_MANIFEST_ROOT=$testRoot"
    }
    throw
}
finally {
    $script:saPassword = $null
    if ($lab -and -not $KeepOnFailure) {
        try { Remove-SqlServerLab -RunId ([string]$lab.RunId) -StateRoot $StateRoot -Force -Confirm:$false | Out-Null }
        catch { Write-Warning "Fehler-Cleanup des Hyper-V-Testdatenbank-Runs schlug fehl: $($_.Exception.Message)" }
    }
    if (($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)) {
        if (-not (Test-ScopedTemporaryRoot -Path $testRoot)) { throw 'HYPERV_TEST_DATABASE_ACCEPTANCE_TEMP_SCOPE_INVALID' }
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
    }
    if ($previousStateRoot) { $env:SQL_SERVER_LAB_STATE = $previousStateRoot }
    else { Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue }
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

Write-Host 'Native Hyper-V-Testdatenbank-Reconcile-Akzeptanz erfolgreich.' -ForegroundColor Green
