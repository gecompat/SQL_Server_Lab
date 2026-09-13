#Requires -Version 7.2
<#
.SYNOPSIS
    Verifiziert die automatische Hyper-V-Manifestinstallation zweier Samples in zwei frischen Runs.
.DESCRIPTION
    Der Runner verwendet genau ein verifiziertes SQL-2025-Prepared-Artifact und einen
    pro Lauf gemeinsamen, isolierten Testdaten-Root. Run 1 installiert Chinook und
    Northwind über New-SqlServerLab -Manifest, validiert die Inhalte und die daraus
    erzeugten LAB_GENERATED-Baselines. Nach scopegebundenem Cleanup erstellt Run 2
    denselben Manifestvertrag erneut und verlangt exakt dieselben Baseline-Keys,
    Hashes und Manifest-Lock-Bindungen. Bei einem Fehler entfernt der Standardpfad
    ausschließlich die bereits erzeugten eigenen Runs.
#>
[CmdletBinding()]
param(
    [string]$ArtifactId,
    [string]$StateRoot,
    [string]$Run1OperationId,
    [string]$Run2OperationId,
    [ValidateRange(300,3600)][int]$OobeTimeoutSeconds = 1200,
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-sample-manifest-' + [guid]::NewGuid().ToString('N'))
$testDataRoot = Join-Path $testRoot 'testdata-library'
$manifestPath = Join-Path $testRoot 'samples.json'
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$previousTestDataRoot = $env:SQL_SERVER_LAB_TEST_DATA_ROOT
$module = $null
$activeLab = $null
$completed = $false
$mutex = [Threading.Mutex]::new($false, 'Global\SQL_Server_Lab_HyperV_Sample_Manifest_Acceptance')
$mutexAcquired = $false

function Assert-HyperVSampleManifestAcceptance {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Description,[string]$Evidence)
    if (-not $Condition) { throw "HYPERV_SAMPLE_MANIFEST_ACCEPTANCE_FAILED: $Description$(if ($Evidence) { ": $Evidence" })" }
    Write-Host "PASS: $Description" -ForegroundColor Green
}
function Invoke-Private {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock,[object[]]$Arguments=@())
    & $module $ScriptBlock @Arguments
}
function Test-ScopedTemporaryRoot {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $expected = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    return [IO.Directory]::GetParent($resolved).FullName.TrimEnd('\').Equals($expected,[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^sql-lab-hv-sample-manifest-[a-f0-9]{32}$'
}
function Write-SampleManifest {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$PreparedArtifactId)
    $manifest = [ordered]@{
        '$schema' = (Join-Path $repoRoot 'Schemas/lab-manifest.schema.json')
        name = 'hv-sample-manifest-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        automation = [ordered]@{mode='unattended'}
        instances = @([ordered]@{
            id='primary';version='2025';provider='hyperv';os='windows';profile='standard';autostart='off'
            network=[ordered]@{intent='hostOnly';exposure='host'}
            windowsActivation=[ordered]@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='EvaluationOnline';EgressPolicy='AllowTemporary'}
            hyperv=[ordered]@{preparedImageId=$PreparedArtifactId;memoryStartupMB=6144;processorCount=4;sqlPort=1433;guestPasswordMode='prompt'}
            storageIntent=[ordered]@{
                contractVersion='SqlServerLab.StorageIntent/1.0';placementPolicy='logical-only';physicalIsolation='not-required'
                roles=[ordered]@{defaultData=[ordered]@{selector='default'};defaultLog=[ordered]@{selector='default'};backup=[ordered]@{selector='default'}}
                tempDb=[ordered]@{distribution='single-location';dataFileCount=1;dataLocationSelectors=@('default');logPlacement=[ordered]@{selector='default';logicalName='templog';fileName='templog.ldf';sizeMB=64;growth='32MB'}}
                databaseFiles=@();restoreRules=@()
            }
            databases=@(
                [ordered]@{name='Chinook';sample=[ordered]@{id='chinook';variant='sql-server'}},
                [ordered]@{name='Northwind';sample=[ordered]@{id='northwind';variant='script'}}
            )
        })
    }
    $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}
function Invoke-AcceptanceScalar {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][SecureString]$SaPassword,[Parameter(Mandatory)][string]$Database,[Parameter(Mandatory)][string]$Query)
    if (-not $SaPassword.IsReadOnly()) { $SaPassword.MakeReadOnly() }
    $connection = [Data.SqlClient.SqlConnection]::new()
    $connection.ConnectionString = "Server=$([string]$Context.Instance.host),$([int]$Context.Instance.port);Database=$Database;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;"
    $connection.Credential = [Data.SqlClient.SqlCredential]::new('sa',$SaPassword)
    try { $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=120;$command.CommandText=$Query;return $command.ExecuteScalar() }
    finally { $connection.Dispose() }
}
function Get-SampleBaselineEvidence {
    param([Parameter(Mandatory)]$RestoreDefinition)
    Invoke-Private {
        param($Definition,$Root,$LibraryRoot)
        Get-LabSampleBaselineRequest -RestoreDefinition $Definition -SqlVersion '2025' -StateRoot $Root -TestDataRoot $LibraryRoot
    } @($RestoreDefinition,$StateRoot,$testDataRoot)
}
function Get-ManifestSampleLockEntries {
    param([Parameter(Mandatory)]$Context)
    $lockPath = Join-Path ([string]$Context.RunDirectory) 'manifest.lock.json'
    Assert-HyperVSampleManifestAcceptance (Test-Path -LiteralPath $lockPath -PathType Leaf) 'Manifest-Lock ist vorhanden'
    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    return @($lock.artifacts | Where-Object { [string]$_.sampleId -in @('chinook','northwind') } | Sort-Object sampleId,sampleVariant)
}
function Remove-AcceptanceRun {
    param([Parameter(Mandatory)]$Lab,[Parameter(Mandatory)][string[]]$OwnedPaths)
    $result = Remove-SqlServerLab -RunId ([string]$Lab.RunId) -StateRoot $StateRoot -Force -Confirm:$false
    Assert-HyperVSampleManifestAcceptance ([string]$result.Status -in @('REMOVED','COMPLETED','ALREADY_REMOVED')) 'Run wurde scopegebunden entfernt' ([string]$result.Status)
    foreach ($path in @($OwnedPaths | Where-Object { $_ })) {
        Assert-HyperVSampleManifestAcceptance (-not (Test-Path -LiteralPath $path)) 'Run-eigene VHDX wurde entfernt'
    }
}
function New-SampleManifestRun {
    param([Parameter(Mandatory)][string]$OperationId)
    $guestPassword = Invoke-Private { New-HyperVSqlUnattendedPassword }
    $saPassword = Invoke-Private { New-HyperVSqlUnattendedPassword }
    $saPassword.MakeReadOnly()
    $newArguments = @{
        Manifest=$manifestPath;GuestPassword=$guestPassword;SqlSaPassword=$saPassword;NonInteractive=$true;StateRoot=$StateRoot
        Region='AT';SystemLocale='de-AT';UiLanguage='en-US';InputLocale='0407:00000407';TimeZone='W. Europe Standard Time'
    }
    $lab = if ([string]::IsNullOrWhiteSpace($OperationId)) {
        New-SqlServerLab @newArguments
    }
    else {
        Invoke-Private {
            param($ContextId,$NewArguments)
            Invoke-WithLabWorkflowOperationContext -OperationId $ContextId -ScriptBlock { New-SqlServerLab @NewArguments }
        } @($OperationId,$newArguments)
    }
    Assert-HyperVSampleManifestAcceptance ([string]$lab.State -eq 'RUNNING') 'Frischer SQL-Prepared-Manifest-Run ist bereit'
    $context = Invoke-Private { param($RunId,$Root) Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $Root } @([string]$lab.RunId,$StateRoot)
    $identity = Invoke-Private {
        param($VmName,$RunId,$ScopeId)
        (Get-HyperVManagedVM -VMName $VmName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId).Identity
    } @([string]$context.Instance.vmName,[string]$lab.RunId,[string]$context.Run.scopeId)
    Assert-HyperVSampleManifestAcceptance (
        -not [string]::IsNullOrWhiteSpace([string]$context.Instance.host) -and [int]$context.Instance.port -gt 0
    ) 'Host-SQL-Verbindung ist gebunden'
    return [pscustomobject]@{ Lab=$lab; Context=$context; SaPassword=$saPassword; OwnedPaths=@([string]$identity.childVhdxPath)+@($identity.additionalDrives|ForEach-Object {[string]$_.path}) }
}

try {
    $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(15)); if(-not $mutexAcquired){throw 'HYPERV_SAMPLE_MANIFEST_ACCEPTANCE_HOST_LOCK_TIMEOUT'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-HyperVSampleManifestAcceptance $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) 'Runner arbeitet erhoeht'
    Get-Command Get-VM -ErrorAction Stop | Out-Null
    $null=New-Item -Path $testRoot -ItemType Directory -Force
    $env:SQL_SERVER_LAB_TEST_DATA_ROOT=$testDataRoot
    $module=Import-Module $modulePath -Force -PassThru
    Invoke-Private { param($Root) Initialize-LabManagedDataRoot -DataRoot $Root -Confirm:$false } @($testDataRoot) | Out-Null
    if(-not $StateRoot){$StateRoot=Invoke-Private {Get-LabStateRoot}};$env:SQL_SERVER_LAB_STATE=$StateRoot
    if(-not $ArtifactId){
        $artifact=Invoke-Private {param($Root)@(Get-HyperVImageArtifact -StateRoot $Root -SkipIntegrityCheck|Where-Object{[string]$_.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$_.sql.version -eq '2025' -and [string]$_.licenseType -ne 'test-only'}|Sort-Object{[datetime]$_.registeredAt} -Descending|Select-Object -First 1)[0]} @($StateRoot)
        if(-not $artifact){throw 'HYPERV_SAMPLE_MANIFEST_SQL_PREPARED_ARTIFACT_NOT_FOUND'};$ArtifactId=[string]$artifact.artifactId
    }
    $artifact=Invoke-Private {param($Id,$Root)Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root} @($ArtifactId,$StateRoot)
    $eligibility=Invoke-Private {param($Candidate)[pscustomobject]@{Evaluation=Test-HyperVImageArtifactEvaluationEligibility -Artifact $Candidate;Child=Test-HyperVImageArtifactChildValidationEligibility -Artifact $Candidate}} @($artifact)
    Assert-HyperVSampleManifestAcceptance (
        [string]$artifact.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$artifact.sql.version -eq '2025' -and
        [string]$artifact.integrityVerification.status -in @('VERIFIED_CACHE','VERIFIED_HASH') -and [bool]$eligibility.Evaluation.Eligible -and [bool]$eligibility.Child.Eligible
    ) 'Verifiziertes SQL-2025-Prepared-Artifact ist fuer Evaluation und Child-Run zugelassen'
    $storageConfiguration=Invoke-Private {param($Artifact)Get-HyperVArtifactStorageConfiguration -Artifact $Artifact} @($artifact)
    Write-SampleManifest -Path $manifestPath -PreparedArtifactId $ArtifactId
    $validation=Test-SqlServerLabManifest -Path $manifestPath
    Assert-HyperVSampleManifestAcceptance $validation.IsValid 'Mehrfach-Sample-Manifest ist vor Mutation gueltig' ($validation.Errors -join '; ')
    $manifest=(Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 30)
    $storagePlan=Invoke-Private {param($Intent,$Storage)New-LabStorageBoundPlan -StorageIntent $Intent -RunId ([guid]::NewGuid().ToString('D')) -LabName 'hv-sample-manifest-preflight' -InstanceId 'primary' -Provider hyperv -StorageConfiguration $Storage} @($manifest.instances[0].storageIntent,$storageConfiguration)
    Assert-HyperVSampleManifestAcceptance ([string]$storagePlan.Status -eq 'READY') 'Artifact-gebundene Default-, Log- und Backup-Lanes sind vor Provisionierung aufloesbar' (@($storagePlan.Blockers)-join '; ')
    $chinookDefinition=Invoke-Private {Resolve-LabSampleRestore -SampleDefinition ([pscustomobject]@{id='chinook';variant='sql-server'}) -SqlVersion '2025' -TargetDatabaseName 'Chinook'}
    $northwindDefinition=Invoke-Private {Resolve-LabSampleRestore -SampleDefinition ([pscustomobject]@{id='northwind';variant='script'}) -SqlVersion '2025' -TargetDatabaseName 'Northwind'}
    $definitions=@($chinookDefinition,$northwindDefinition)
    Assert-HyperVSampleManifestAcceptance (@($definitions|Where-Object{[string]$_.expectedSha256 -notmatch '^[a-f0-9]{64}$' -or [string]$_.trustPolicy -ne 'catalog-only'}).Count -eq 0) 'Beide Samplequellen sind katalog- und hashgebunden'

    $run1=New-SampleManifestRun -OperationId $Run1OperationId;$activeLab=$run1.Lab
    $chinookCount=[long](Invoke-AcceptanceScalar -Context $run1.Context -SaPassword $run1.SaPassword -Database 'Chinook' -Query 'SELECT COUNT_BIG(*) FROM dbo.Artist;')
    $northwindCount=[long](Invoke-AcceptanceScalar -Context $run1.Context -SaPassword $run1.SaPassword -Database 'Northwind' -Query 'SELECT COUNT_BIG(*) FROM dbo.Customers;')
    Assert-HyperVSampleManifestAcceptance ($chinookCount -gt 0 -and $northwindCount -gt 0) 'Run 1 installiert beide katalogisierten Samples mit echtem SQL-Inhalt'
    $run1Locks=Get-ManifestSampleLockEntries -Context $run1.Context
    $expectedSourceBindings=@($definitions|ForEach-Object{"$([string]$_.sampleId)|$([string]$_.sampleVariant)|$(([string]$_.expectedSha256).ToLowerInvariant())"}|Sort-Object)
    $actualSourceBindings=@($run1Locks|ForEach-Object{"$([string]$_.sampleId)|$([string]$_.sampleVariant)|$(([string]$_.sha256).ToLowerInvariant())"}|Sort-Object)
    Assert-HyperVSampleManifestAcceptance ($run1Locks.Count -eq 2 -and @($run1Locks|Where-Object{$_.PSObject.Properties['resolvedArtifact']}).Count -eq 0 -and ($expectedSourceBindings -join ';') -ceq ($actualSourceBindings -join ';')) 'Run 1 bindet beide katalogisierten Originalquellen mit exakten Source-Pins ohne vorbestehenden Baseline-Hit'
    $run1Baselines=@($definitions|ForEach-Object{Get-SampleBaselineEvidence -RestoreDefinition $_})
    Assert-HyperVSampleManifestAcceptance (@($run1Baselines|Where-Object{$_ -eq $null -or [string]$_.Selection.MatchType -ne 'exact' -or [string]$_.Selection.Record.origin -ne 'LAB_GENERATED' -or -not(Test-Path -LiteralPath ([string]$_.Selection.Path) -PathType Leaf) -or (Get-FileHash -LiteralPath ([string]$_.Selection.Path) -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$_.Selection.Sha256}).Count -eq 0) 'Run 1 erzeugt zwei hashverifizierte LAB_GENERATED-Baselines'
    $run1Snapshot=@($run1Baselines|ForEach-Object{[pscustomobject]@{KeyId=[string]$_.Selection.KeyId;Sha256=[string]$_.Selection.Sha256;BaselineId=[string]$_.Selection.Record.baselineId}}|Sort-Object KeyId)
    Remove-AcceptanceRun -Lab $run1.Lab -OwnedPaths $run1.OwnedPaths;$activeLab=$null;$run1.SaPassword=$null

    $run2=New-SampleManifestRun -OperationId $Run2OperationId;$activeLab=$run2.Lab
    $chinookCount=[long](Invoke-AcceptanceScalar -Context $run2.Context -SaPassword $run2.SaPassword -Database 'Chinook' -Query 'SELECT COUNT_BIG(*) FROM dbo.Artist;')
    $northwindCount=[long](Invoke-AcceptanceScalar -Context $run2.Context -SaPassword $run2.SaPassword -Database 'Northwind' -Query 'SELECT COUNT_BIG(*) FROM dbo.Customers;')
    $run2Locks=Get-ManifestSampleLockEntries -Context $run2.Context
    $run2Baselines=@($definitions|ForEach-Object{Get-SampleBaselineEvidence -RestoreDefinition $_})
    $run2Snapshot=@($run2Baselines|ForEach-Object{[pscustomobject]@{KeyId=[string]$_.Selection.KeyId;Sha256=[string]$_.Selection.Sha256;BaselineId=[string]$_.Selection.Record.baselineId}}|Sort-Object KeyId)
    $baselineEquivalent=($run1Snapshot|ConvertTo-Json -Depth 10 -Compress) -ceq ($run2Snapshot|ConvertTo-Json -Depth 10 -Compress)
    $expectedResolvedBindings=@($run1Snapshot|ForEach-Object{"$([string]$_.KeyId)|$([string]$_.Sha256)"}|Sort-Object)
    $actualResolvedBindings=@($run2Locks|Where-Object{[string]$_.resolvedArtifact.origin -eq 'LAB_GENERATED'}|ForEach-Object{"$([string]$_.resolvedArtifact.keyId)|$([string]$_.resolvedArtifact.sha256)"}|Sort-Object)
    $lockEquivalent=$actualResolvedBindings.Count -eq 2 -and ($expectedResolvedBindings -join ';') -ceq ($actualResolvedBindings -join ';')
    Assert-HyperVSampleManifestAcceptance ($chinookCount -gt 0 -and $northwindCount -gt 0 -and $baselineEquivalent -and $lockEquivalent) 'Run 2 verwendet dieselben Baseline-IDs, Key-/Hash-Paare und Manifest-Locks fuer beide Samples'
    Remove-AcceptanceRun -Lab $run2.Lab -OwnedPaths $run2.OwnedPaths;$activeLab=$null;$run2.SaPassword=$null
    $completed=$true
}
catch { if($activeLab -and $KeepOnFailure){Write-Host "RECOVERY_RUN_ID=$([string]$activeLab.RunId)"};throw }
finally {
    if($activeLab -and -not $KeepOnFailure){try{Remove-SqlServerLab -RunId ([string]$activeLab.RunId) -StateRoot $StateRoot -Force -Confirm:$false|Out-Null}catch{Write-Warning 'Der Fehler-Cleanup des Hyper-V-Sample-Manifest-Runs schlug fehl.'}}
    if(($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)){if(-not(Test-ScopedTemporaryRoot $testRoot)){throw 'HYPERV_SAMPLE_MANIFEST_ACCEPTANCE_TEMP_SCOPE_INVALID'};Remove-Item -LiteralPath $testRoot -Recurse -Force}
    if($previousStateRoot){$env:SQL_SERVER_LAB_STATE=$previousStateRoot}else{Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue}
    if($previousTestDataRoot){$env:SQL_SERVER_LAB_TEST_DATA_ROOT=$previousTestDataRoot}else{Remove-Item Env:SQL_SERVER_LAB_TEST_DATA_ROOT -ErrorAction SilentlyContinue}
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue};if($mutexAcquired){$mutex.ReleaseMutex()};$mutex.Dispose()
}
Write-Host 'Native Hyper-V-Mehrfach-Sample-Manifest-Akzeptanz erfolgreich.' -ForegroundColor Green
