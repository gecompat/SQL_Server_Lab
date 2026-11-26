#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft Windows-Lizenz und SQL-Bereitschaft eines separaten SQL-2025-Ziellabs auf Hyper-V.
.DESCRIPTION
    Erstellt zwei eigene Labs aus demselben expliziten Developer-Prepared-Image.
    Die Quelle wird vor dem Start des Ziels gestoppt. Beide Bindungen bleiben
    bis zum Ende erhalten. Die Bereitstellung darf die Windows-Evaluation der
    eigenen VMs mit vorübergehender Netzfreigabe aktivieren. Die Gastprüfungen
    lesen den aktuellen Zustand. Cleanup entfernt ausschließlich eigene Runs.
.PARAMETER CompareFileAllocation
    Startet die eigene Quelle nach der Zielprüfung erneut, legt eine
    synthetische Quelldatenbank an und prüft die gebundene Speichervorschau,
    während beide eigenen VMs laufen. Der Test führt keinen Transfer aus.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^hyperv-sql-prepared-sealed-[a-f0-9]{64}$')][string]$ArtifactId,
    [switch]$CompareFileAllocation
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/SqlGuestAllocationAcceptanceFixture.ps1')
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot = Join-Path $repo ('.artifacts/test-runs/evaluation-target-license-' + [guid]::NewGuid().ToString('N'))
$sourceOperation = [guid]::NewGuid().ToString('D')
$targetOperation = [guid]::NewGuid().ToString('D')
$source = $null
$target = $null
$module = $null
$stateRoot = $null
$acquired = $false
$cleanupFailed = $false
$phase = 'PREFLIGHT'

function Assert-TargetLicenseAcceptance {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw ('EVALUATION_TARGET_LICENSE_ASSERTION_FAILED: ' + $Name) }
    Write-Host "PASS: $Name"
}

function Wait-TargetLicenseAcceptanceSourceSql {
    param($Module,[guid]$RunId,[guid]$ScopeId,[guid]$VmId,[string]$StateRoot)
    & $Module {
        param($Id,$Scope,$Vm,$Root)
        $deadline = [datetime]::UtcNow.AddSeconds(180)
        do {
            $context = Get-LabSqlGuestCaptureContext -RunId $Id -StateRoot $Root
            if ([guid]$context.Run.scopeId -ne $Scope -or [guid]$context.Instance.vmId -ne $Vm -or
                $context.Instance.id -cne 'primary') {
                throw 'EVALUATION_TARGET_LICENSE_SOURCE_OWNERSHIP_CHANGED'
            }
            $remaining = [int][Math]::Ceiling(($deadline - [datetime]::UtcNow).TotalSeconds)
            if ($remaining -lt 1) { break }
            try {
                $observed = Invoke-LabSqlGuestCaptureProbe -Context $context -TimeoutSeconds ([Math]::Min(30,$remaining))
                if ($observed.MajorVersion -ne 17 -or $observed.InstanceName -cne $context.Instance.sqlReadiness.instanceName -or
                    $observed.Edition -cne $context.Instance.sqlReadiness.edition) {
                    throw 'EVALUATION_TARGET_LICENSE_SOURCE_SQL_IDENTITY_MISMATCH'
                }
                return
            } catch {
                if ($_.Exception.Message -cnotin @('SQL_GUEST_CAPTURE_PROBE_FAILED','GUEST_JOB_OPERATION_TIMEOUT')) { throw }
            }
            if ([datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 750 }
        } while ([datetime]::UtcNow -lt $deadline)
        throw 'EVALUATION_TARGET_LICENSE_SOURCE_SQL_TIMEOUT'
    } $RunId $ScopeId $VmId $StateRoot
}

function Get-TargetLicenseActivationFailure {
    param([string]$Message)

    $match = [regex]::Match($Message,'\AHYPERV_WINDOWS_ACTIVATION_FAILED: (?<Code>[A-Z0-9_]{1,90})(?: \[(?<Details>[^\r\n]{1,160})\])?\z')
    if (-not $match.Success) { return }
    $code = $match.Groups['Code'].Value
    if ($code -cnotin @('WINDOWS_ACTIVATION_NETWORK_CONFIGURATION_FAILED','WINDOWS_ACTIVATION_NETWORK_NOT_READY','WINDOWS_ACTIVATION_GUEST_ADAPTER_NOT_FOUND',
        'WINDOWS_ACTIVATION_LICENSE_DISCOVERY_FAILED','WINDOWS_ACTIVATION_REQUEST_FAILED','WINDOWS_ACTIVATION_VERIFICATION_FAILED',
        'WINDOWS_ACTIVATION_GUEST_OPERATION_FAILED','WINDOWS_EVALUATION_EDITION_REQUIRED','WINDOWS_ACTIVATION_PRODUCT_NOT_FOUND',
        'HYPERV_WINDOWS_ACTIVATION_GUEST_RECEIPT_INVALID','HYPERV_WINDOWS_ACTIVATION_VERIFICATION_FAILED',
        'HYPERV_WINDOWS_ACTIVATION_OPERATION_FAILED')) { return }
    $details = $match.Groups['Details'].Value
    if ($details -cnotmatch '\Adns=(?:not_checked|resolved|unresolved);ipv4=(?:not_checked|present|missing);route=(?:not_checked|present|missing)(?:;(?:apiReturn|hresult)=0x[0-9A-F]{8}|;api=exception)?\z') {
        $details = $null
    }
    [pscustomobject]@{Code=$code;Details=$details}
}

function New-TargetLicenseAcceptanceRun {
    param([string]$Role, [string]$Operation)
    $manifestPath = Join-Path $testRoot ($Role + '.json')
    $manifest = @{
        name=('eval-license-' + $Role + '-' + $Operation.Substring(0,8)); automation=@{mode='unattended'}
        instances=@(@{
            id='primary'; version='2025'; provider='hyperv'; os='windows'; profile='standard'; autostart='off'
            network=@{intent='hostOnly';exposure='host'}
            windowsActivation=@{ContractVersion='SqlServerLab.WindowsActivationIntent/1.0';Strategy='EvaluationOnline';EgressPolicy='AllowTemporary'}
            hyperv=@{preparedImageId=$ArtifactId;memoryStartupMB=6144;processorCount=4;sqlPort=1433;guestPasswordMode='prompt'}
        })
    }
    $manifest | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    if (-not (Test-SqlServerLabManifest -Path $manifestPath -ErrorAction Stop).IsValid) { throw 'ACCEPTANCE_MANIFEST_INVALID' }
    $guest = $null
    $sql = $null
    try {
        $guest = & $module { New-HyperVSqlUnattendedPassword }
        $sql = & $module { New-HyperVSqlUnattendedPassword }
        & $module {
            param($Manifest, $Guest, $Sql, $Root, $OperationId)
            Invoke-WithLabWorkflowOperationContext -OperationId $OperationId -ScriptBlock {
                param($Path, $GuestPassword, $SqlPassword, $State)
                New-SqlServerLab -Manifest $Path -GuestPassword $GuestPassword -SqlSaPassword $SqlPassword -StateRoot $State -NonInteractive
            } -ArgumentList @($Manifest, $Guest, $Sql, $Root)
        } $manifestPath $guest $sql $stateRoot $Operation 3>$null 4>$null 5>$null 6>$null
    } finally {
        if ($guest) { $guest.Dispose() }
        if ($sql) { $sql.Dispose() }
    }
}

function Remove-TargetLicenseAcceptanceRun {
    param([string]$Operation, $ObservedRun)
    $owned = & $module { param($Id,$Root) Get-LabOperationOwnedRun -OperationId $Id -StateRoot $Root } $Operation $stateRoot
    if (-not $owned) {
        if ($ObservedRun) { throw 'EVALUATION_TARGET_LICENSE_OWNERSHIP_MISSING' }
        return 'NO_OWNED_RUN'
    }
    if ($ObservedRun -and [string]$owned.runId -cne [string]$ObservedRun.RunId) { throw 'EVALUATION_TARGET_LICENSE_OWNERSHIP_CHANGED' }
    $resources = @(& $module {
        param($Run)
        foreach ($vm in @(Get-HyperVLabVMs -RunId ([string]$Run.runId) -ScopeId ([string]$Run.scopeId))) {
            $managed = Get-HyperVManagedVM -VMName ([string]$vm.VMName) -ExpectedRunId ([string]$Run.runId) -ExpectedScopeId ([string]$Run.scopeId)
            [pscustomobject]@{Id=[guid]$managed.VM.Id;Paths=@($managed.Identity.childVhdxPath)+@($managed.Identity.additionalVhdxPaths)}
        }
    } $owned)
    $removed = Remove-SqlServerLab -RunId ([string]$owned.runId) -StateRoot $stateRoot -Force -Confirm:$false 3>$null 4>$null 5>$null 6>$null
    if ($removed.Status -cne 'REMOVED' -or $removed.Cleanup -cne 'CLEANUP_SUCCEEDED') { throw 'EVALUATION_TARGET_LICENSE_CLEANUP_INCOMPLETE' }
    $remaining = & $module { param($Id,$Scope) @(Get-HyperVLabVMs -RunId $Id -ScopeId $Scope).Count } ([string]$owned.runId) ([string]$owned.scopeId)
    if ($remaining -ne 0) { throw 'EVALUATION_TARGET_LICENSE_VM_REMAINS' }
    $currentVmIds = @(Get-VM -ErrorAction Stop | ForEach-Object Id)
    foreach ($item in $resources) {
        if ($item.Id -in $currentVmIds) { throw 'EVALUATION_TARGET_LICENSE_VM_REMAINS' }
        foreach ($path in $item.Paths) {
            if ($path -and (Test-Path -LiteralPath $path -ErrorAction Stop)) { throw 'EVALUATION_TARGET_LICENSE_DISK_REMAINS' }
        }
    }
    return 'REMOVED'
}

$mutex = [Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke')
try {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'ELEVATED_HYPERV_RUNNER_REQUIRED' }
    $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(10))
    if (-not $acquired) { throw 'RUNTIME_SMOKE_LEASE_TIMEOUT' }
    $module = Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru 3>$null 4>$null 5>$null 6>$null
    $dataRoot = & $module { Assert-LabDiagnosticPath -Path (Resolve-LabDataRootForUse) }
    $stateRoot = & $module { param($Data) Assert-LabDiagnosticPath -Path (Join-Path $Data 'State') } $dataRoot
    Assert-TargetLicenseAcceptance ([IO.Directory]::Exists($stateRoot)) 'Expliziter State Root des registrierten Lab_Data existiert'
    $artifacts = @(& $module { param($Id,$Root) Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root } $ArtifactId $stateRoot)
    Assert-TargetLicenseAcceptance ($artifacts.Count -eq 1 -and $artifacts[0].artifactState -ceq 'SQL_PREPARED_SEALED' -and
        $artifacts[0].sql.version -ceq '2025' -and $artifacts[0].sql.edition -match 'Developer' -and
        $artifacts[0].integrityVerification.status -cin @('VERIFIED_HASH','VERIFIED_CACHE')) 'Explizite SQL-2025-Developer-Vorlage ist verifiziert'
    $artifact = $artifacts[0]
    $parentHash = [string]$artifact.sha256
    $null = New-Item -ItemType Directory -Path $testRoot

    $phase = 'SOURCE_ARRANGE'
    $source = New-TargetLicenseAcceptanceRun -Role source -Operation $sourceOperation
    Assert-TargetLicenseAcceptance ($source.State -ceq 'RUNNING') 'Eigener Quell-Run wurde angelegt'
    $ownedSource = & $module { param($Id,$Root) Get-LabOperationOwnedRun -OperationId $Id -StateRoot $Root } $sourceOperation $stateRoot
    if ([string]$ownedSource.runId -cne [string]$source.RunId) { throw 'EVALUATION_TARGET_LICENSE_SOURCE_OWNERSHIP_CHANGED' }
    $null = Stop-SqlServerLab -RunId $source.RunId -StateRoot $stateRoot -SkipHostMemoryRelease -Force -Confirm:$false 3>$null 4>$null 5>$null 6>$null
    $sourceState = & $module { param($Id,$Root) Get-LabRunState -RunId $Id -StateRoot $Root } $source.RunId $stateRoot
    $stoppedSourceVm = & $module {
        param($Id,$Data)
        $snapshot = Read-LabEvaluationRefreshSnapshot -RunId $Id -InstanceId primary -DataRoot $Data
        $vm = Get-VM -Id ([guid]$snapshot.Instance.vmId) -ErrorAction Stop
        [pscustomobject]@{Id=[guid]$vm.Id;State=[string]$vm.State}
    } $source.RunId $dataRoot
    Assert-TargetLicenseAcceptance ($sourceState.state -ceq 'STOPPED' -and $stoppedSourceVm.State -ceq 'Off') 'Eigene Quelle vor dem Zielstart gestoppt'

    $phase = 'TARGET_ARRANGE'
    $target = New-TargetLicenseAcceptanceRun -Role target -Operation $targetOperation
    $ownedTarget = & $module { param($Id,$Root) Get-LabOperationOwnedRun -OperationId $Id -StateRoot $Root } $targetOperation $stateRoot
    Assert-TargetLicenseAcceptance ($target.State -ceq 'RUNNING' -and $target.RunId -cne $source.RunId -and
        [string]$ownedTarget.runId -ceq [string]$target.RunId) 'Separates eigenes Ziellab läuft'

    $phase = 'BOUND_TARGET_OBSERVATION'
    $request = @{
        RunId=$source.RunId; InstanceId='primary'; DataRoot=$dataRoot
        TargetRunId=$target.RunId; TargetInstanceId='primary'
    }
    $plan = Get-SqlServerLabEvaluationRefreshPlan @request -Mode STATEFUL_MIGRATION
    Assert-TargetLicenseAcceptance ($plan.TargetAssessment.Status -ceq 'METADATA_ONLY' -and $plan.TargetAssessment.RegisteredState -ceq 'RUNNING' -and
        $plan.Status -ceq 'BLOCKED' -and $plan.TransferAuthority -ceq 'NONE') 'Vorschau bindet getrennte Quelle und Ziel ohne Transferfreigabe'
    $paths = @(foreach ($runId in @($source.RunId,$target.RunId)) {
        $directory = Join-Path $stateRoot ('runs/' + $runId)
        Join-Path $directory 'run-state.json'
        Join-Path $directory 'connection-info.json'
    })
    $before = @($paths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    $operationRequest = $request.Clone()
    $operationRequest.ExpectedPlanKey = $plan.ObservedContentSha256
    $operationRequest.ExpectedTargetPlanKey = $plan.TargetAssessment.ObservedContentSha256
    $result = (Invoke-SqlServerLabWorkflowAction @operationRequest -Action ReadHyperVEvaluationWindowsLicense).Result
    $license = $result.WindowsLicenseObservation
    Assert-TargetLicenseAcceptance ($result.TargetRunId -ceq $target.RunId -and $result.TargetInstanceId -ceq 'primary' -and
        $license.Status -ceq 'OBSERVED' -and $license.ObservedAt -and
        (($license.LicenseState -ceq 'LICENSED' -and $null -eq $license.EvaluationExpiresAt) -or
            ($license.LicenseState -ceq 'EVALUATION_ACTIVE' -and $license.EvaluationExpiresAt))) 'Live-Windows-Lizenz der gebundenen Ziel-VM bestätigt'
    $phase = 'TARGET_SQL_READINESS'
    $readiness = (Invoke-SqlServerLabWorkflowAction @operationRequest -Action ReadHyperVEvaluationTargetSqlReadiness).Result
    Assert-TargetLicenseAcceptance ($readiness.TargetRunId -ceq $target.RunId -and $readiness.TargetInstanceId -ceq 'primary' -and
        $readiness.SqlReadinessObservation.Status -ceq 'OBSERVED' -and $readiness.SqlReadinessObservation.ObservedAt) 'SQL-Bereitschaft der gebundenen Ziel-VM bestätigt'
    Assert-TargetLicenseAcceptance ($readiness.SqlEditionObservation.Status -ceq 'OBSERVED' -and
        $readiness.SqlEditionObservation.Classification -ceq 'NOT_EVALUATION' -and
        $readiness.SqlEditionObservation.EvaluationDeadlineStatus -ceq 'NOT_APPLICABLE') 'Gebundener Developer-Gast als Nicht-Evaluation erkannt'
    $phase = 'TARGET_STORAGE_CAPACITY'
    $storage = (Invoke-SqlServerLabWorkflowAction @operationRequest -Action ReadHyperVEvaluationTargetStorage).Result
    $observation = $storage.StorageObservation
    $roles = @($observation.Volumes | ForEach-Object Roles | Sort-Object)
    Assert-TargetLicenseAcceptance ($storage.TargetRunId -ceq $target.RunId -and $storage.TargetInstanceId -ceq 'primary' -and
        $observation.Status -ceq 'OBSERVED' -and $observation.ObservedAt -and
        ($roles -join ',') -ceq 'Backup,Data,Log' -and
        @($observation.Volumes | Where-Object { $_.AvailableBytes -isnot [long] -or $_.AvailableBytes -lt 0 }).Count -eq 0) 'Freier Gastspeicher für Daten, Log und Backup ist am gebundenen Ziel beobachtet'
    $fresh = Get-SqlServerLabEvaluationRefreshPlan @request -Mode STATEFUL_MIGRATION
    $after = @($paths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    Assert-TargetLicenseAcceptance (($before -join ',') -ceq ($after -join ',') -and
        $fresh.ObservedContentSha256 -ceq $plan.ObservedContentSha256 -and
        $fresh.TargetAssessment.ObservedContentSha256 -ceq $plan.TargetAssessment.ObservedContentSha256) 'Quell- und Zielmetadaten blieben bytegleich'
    if ($CompareFileAllocation) {
        $phase = 'COMPARE_OWN_SOURCE_RESUME'
        $currentSource = & $module { param($Id,$Root) Get-LabOperationOwnedRun -OperationId $Id -StateRoot $Root } $sourceOperation $stateRoot
        Assert-TargetLicenseAcceptance ([string]$currentSource.runId -ceq [string]$source.RunId -and
            [string]$currentSource.scopeId -ceq [string]$ownedSource.scopeId) 'Quellbesitz vor dem erneuten Start bestätigt'
        $null = Start-SqlServerLab -RunId $source.RunId -StateRoot $stateRoot -TimeoutSeconds 180 3>$null 4>$null 5>$null 6>$null
        $runningSource = & $module { param($Id,$Root) Get-LabRunState -RunId $Id -StateRoot $Root } $source.RunId $stateRoot
        Assert-TargetLicenseAcceptance ($runningSource.state -ceq 'RUNNING') 'Eigene Quelle läuft neben dem eigenen Ziellab'
        $phase = 'COMPARE_SOURCE_SQL_READY'
        Wait-TargetLicenseAcceptanceSourceSql -Module $module -RunId $source.RunId -ScopeId $ownedSource.scopeId `
            -VmId $stoppedSourceVm.Id -StateRoot $stateRoot
        Write-Host 'PASS: SQL Server der erneut gestarteten eigenen Quelle ist erreichbar'
        $phase = 'COMPARE_SOURCE_BASELINE'
        $beforeSource = Get-SqlServerLabEvaluationRefreshPlan @request -Mode STATEFUL_MIGRATION -ObserveSqlSource
        if ($beforeSource.SqlSourceInventory.Status -ceq 'NOT_OBSERVED') {
            throw 'EVALUATION_TARGET_LICENSE_SOURCE_INVENTORY_UNCONFIRMED'
        }
        $beforeAllocation = $beforeSource.SqlSourceInventory.AllocatedFileStorage
        Assert-TargetLicenseAcceptance ($beforeAllocation.Status -ceq 'OBSERVED' -and
            $beforeAllocation.DataBytes -is [long] -and $beforeAllocation.LogBytes -is [long]) 'Dateizuweisung der laufenden Quelle vor der Fixture beobachtet'

        $phase = 'COMPARE_SOURCE_FIXTURE'
        $sourceContext = & $module {
            param($Id,$Root) Get-LabSqlGuestCaptureContext -RunId $Id -StateRoot $Root
        } $source.RunId $stateRoot
        if ($sourceContext.Run.scopeId -cne $ownedSource.scopeId -or $sourceContext.Instance.id -cne 'primary') {
            throw 'EVALUATION_TARGET_LICENSE_SOURCE_OWNERSHIP_CHANGED'
        }
        $credentials = & $module {
            param($Context)
            $guestCredential = $null
            $sqlPassword = $null
            try {
                $guestCredential = Get-LabSecret -Path $Context.RunDirectory -Name 'guest-administrator-password'
                $sqlPassword = Get-LabSecret -Path $Context.RunDirectory -Name 'generated-sql-sa-password'
                if (-not $sqlPassword) { $sqlPassword = Get-LabSecret -Path $Context.RunDirectory -Name 'sa-password' }
                if (-not $guestCredential -or -not $sqlPassword) { throw 'SQL_GUEST_ALLOCATION_FIXTURE_CREDENTIAL_REQUIRED' }
                [pscustomobject]@{Guest=$guestCredential;Sql=$sqlPassword}
            } catch {
                if ($guestCredential) { $guestCredential.Dispose() }
                if ($sqlPassword) { $sqlPassword.Dispose() }
                throw
            }
        } $sourceContext
        try {
            $fixtureArgs = @{Module=$module;Context=$sourceContext;GuestPassword=$credentials.Guest;SqlPassword=$credentials.Sql
                DatabaseName='SqlLabAllocationComparisonFixture'}
            $fixturePages = New-SqlGuestAllocationAcceptanceFixture @fixtureArgs
        } finally {
            $credentials.Guest.Dispose()
            $credentials.Sql.Dispose()
        }
        Write-Host 'PASS: Eigene SQL-Testdatenbank hat bestätigte Daten- und Logseiten'
        $phase = 'COMPARE_SOURCE_ALLOCATION'
        $sourcePlan = Get-SqlServerLabEvaluationRefreshPlan @request -Mode STATEFUL_MIGRATION -ObserveSqlSource
        $sourceAllocation = $sourcePlan.SqlSourceInventory.AllocatedFileStorage
        Assert-TargetLicenseAcceptance ($sourceAllocation.Status -ceq 'OBSERVED' -and
            $sourceAllocation.DataBytes -eq ($beforeAllocation.DataBytes + 8KB * [decimal]$fixturePages.DataPages) -and
            $sourceAllocation.LogBytes -eq ($beforeAllocation.LogBytes + 8KB * [decimal]$fixturePages.LogPages)) 'Quellsummen enthalten exakt die Dateigrößen der eigenen Testdatenbank'
        $operationRequest.ExpectedPlanKey = $sourcePlan.ObservedContentSha256
        $operationRequest.ExpectedTargetPlanKey = $sourcePlan.TargetAssessment.ObservedContentSha256
        $compareBefore = @($paths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
        $phase = 'BOUND_FILE_ALLOCATION_COMPARISON'
        $result = (Invoke-SqlServerLabWorkflowAction @operationRequest -Action ReadHyperVEvaluationFileAllocationComparison).Result
        $comparison = $result.FileAllocationComparison
        $compareRoles = @($comparison.Volumes | ForEach-Object Roles | Sort-Object)
        Assert-TargetLicenseAcceptance ($result.TargetRunId -ceq $target.RunId -and
            $result.TargetInstanceId -ceq 'primary' -and ($compareRoles -join ',') -ceq 'Data,Log' -and
            $comparison.Status -cin @('WITHIN_REPORTED_FREE_SPACE','EXCEEDS_REPORTED_FREE_SPACE')) 'Vergleich bindet Ziel und zeigt Daten und Log genau einmal'
        $allFit = $true
        foreach ($volume in $comparison.Volumes) {
            $expectedBytes = [decimal]0
            if ('Data' -cin $volume.Roles) { $expectedBytes += $sourceAllocation.DataBytes }
            if ('Log' -cin $volume.Roles) { $expectedBytes += $sourceAllocation.LogBytes }
            $available = [long]0
            $parsed = $volume.AvailableBytes -is [string] -and $volume.AvailableBytes -cmatch '^[0-9]{1,19}$' -and
                [long]::TryParse($volume.AvailableBytes,[ref]$available)
            $volumeFits = $expectedBytes -le $available
            Assert-TargetLicenseAcceptance ($parsed -and $volume.AllocatedBytes -ceq $expectedBytes.ToString('0',[Globalization.CultureInfo]::InvariantCulture) -and
                $volume.FitsObservedSpace -is [bool] -and $volume.FitsObservedSpace -eq $volumeFits) 'Vergleich übernimmt je Zielvolume exakt die gebundenen Bytes'
            $allFit = $allFit -and $volumeFits
        }
        $expectedStatus = if ($allFit) { 'WITHIN_REPORTED_FREE_SPACE' } else { 'EXCEEDS_REPORTED_FREE_SPACE' }
        Assert-TargetLicenseAcceptance ($comparison.Status -ceq $expectedStatus) 'Gesamtergebnis entspricht den beobachteten Volumes'
        $compareAfter = @($paths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
        Assert-TargetLicenseAcceptance (($compareBefore -join ',') -ceq ($compareAfter -join ',')) 'Der Vergleich hielt die fertigen Run- und Verbindungsmetadaten unverändert'
    }
    $parentAfter = & $module { param($Id,$Root) Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root } $ArtifactId $stateRoot
    Assert-TargetLicenseAcceptance ($parentAfter.sha256 -ceq $parentHash) 'Prepared-Vorlage blieb unverändert'
} catch {
    $failure = [regex]::Match([string]$_.Exception.Message,'^[A-Z][A-Z0-9_]{2,100}(?=:|$)')
    $code = if ($failure.Success) { $failure.Value } else { 'UNCLASSIFIED_ERROR' }
    if ($code -ceq 'EVALUATION_TARGET_LICENSE_ASSERTION_FAILED') { Write-Host $_.Exception.Message }
    if ($code -ceq 'HYPERV_WINDOWS_ACTIVATION_FAILED') {
        $activation = Get-TargetLicenseActivationFailure -Message $_.Exception.Message
        if ($activation) {
            Write-Host ('Windows activation {0} {1}' -f $activation.Code,$activation.Details)
        }
    }
    throw "EVALUATION_TARGET_LICENSE_FAILED: $phase / $code"
} finally {
    if ($module -and $acquired -and $stateRoot) {
        foreach ($entry in @(@{Role='target';Operation=$targetOperation;Run=$target},@{Role='source';Operation=$sourceOperation;Run=$source})) {
            try {
                $cleanup = Remove-TargetLicenseAcceptanceRun -Operation $entry.Operation -ObservedRun $entry.Run
                Write-Host ('Own run cleanup {0} {1}' -f $entry.Role,$cleanup)
            }
            catch { $cleanupFailed = $true; Write-Host 'RECOVERY_REQUIRED: Eigener Acceptance-Run benötigt scopegebundene Prüfung.' }
        }
    }
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
if ($cleanupFailed) { throw 'EVALUATION_TARGET_LICENSE_CLEANUP_FAILED' }
Write-Host 'PASS: Eigene Quell- und Ziel-Runs, VMs und Disks vollständig bereinigt'
Write-Host 'EVALUATION TARGET WINDOWS LICENSE ACCEPTANCE: PASS'
