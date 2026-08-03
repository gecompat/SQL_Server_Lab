#Requires -Version 7.2
<#
.SYNOPSIS
    Native-Smoke-Test fuer die Hyper-V-Lifecycle-Grundlage.
.DESCRIPTION
    Erzeugt eine kleine synthetische read-only Parent-VHDX und prueft daraus
    eine Generation-2-VM mit Differencing Child, Secure Boot, Status, Start,
    Stop und scopegebundenem Cleanup. Der Test installiert weder ein
    Betriebssystem noch SQL Server und verwendet kein Netzwerk.
.PARAMETER KeepOnFailure
    Behaelt Testressourcen fuer eine lokale Diagnose. Nicht fuer CI verwenden.
#>
[CmdletBinding()]
param([switch]$KeepOnFailure)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-hyperv-smoke-$([guid]::NewGuid().ToString('N'))"
$runDirectory = Join-Path $testRoot 'run'
$stateRoot = Join-Path $testRoot 'state'
$parentPath = Join-Path $testRoot 'synthetic-parent.vhdx'
$isoPath = Join-Path $testRoot 'synthetic-windows.iso'
$runId = [guid]::NewGuid().ToString()
$scopeId = [guid]::NewGuid().ToString()
$instance = $null
$module = $null
$cleanupComplete = $false
$mutexName = 'Global\SQL_Server_Lab_Runtime_Smoke'
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
$mutexAcquired = $false

function Assert-HyperVSmoke {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description
    )
    if (-not $Condition) {
        throw $Description
    }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

try {
    $mutexAcquired = $mutex.WaitOne([TimeSpan]::FromMinutes(10))
    if (-not $mutexAcquired) {
        throw 'Runtime-Smoke-Hostlock konnte innerhalb von 10 Minuten nicht erworben werden.'
    }

    New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module $modulePath -Force -PassThru

    $availability = & $module { Test-HyperVAvailable }
    Assert-HyperVSmoke -Condition $availability.Available -Description 'Hyper-V-Host ist erreichbar'

    $null = New-VHD -Path $parentPath -Dynamic -SizeBytes 64MB -ErrorAction Stop
    (Get-Item -LiteralPath $parentPath).IsReadOnly = $true
    $parentHash = (Get-FileHash -LiteralPath $parentPath -Algorithm SHA256).Hash

    $imageArtifact = & $module {
        param($ParentPath, $ParentHash, $StateRoot)
        Import-HyperVImageArtifact `
            -VhdxPath $ParentPath `
            -ExpectedSha256 $ParentHash `
            -ArtifactState 'LIFECYCLE_TEST_ONLY' `
            -OperatingSystemId 'synthetic-ci' `
            -OperatingSystemVersion '1' `
            -Edition 'none' `
            -InstallationType 'synthetic' `
            -LicenseType 'test-only' `
            -IntegrityOrigin 'synthetic-test' `
            -StateRoot $StateRoot
    } $parentPath $parentHash $stateRoot
    Assert-HyperVSmoke -Condition ($imageArtifact.artifactState -eq 'LIFECYCLE_TEST_ONLY') -Description 'Synthetische VHDX wurde als Test-Artifact registriert'
    Assert-HyperVSmoke -Condition ((Get-Item -LiteralPath $imageArtifact.Path).IsReadOnly) -Description 'Registrierte Parent-VHDX ist immutable'

    $instance = & $module {
        param($RunDirectory, $RunId, $ScopeId, $ArtifactId, $StateRoot)
        $providerSubRuns = @([PSCustomObject]@{ id = 'provider-hyperv'; provider = 'hyperv' })
        $null = New-CleanupPlan `
            -RunDir $RunDirectory `
            -RunId $RunId `
            -ScopeId $ScopeId `
            -ProviderSubRuns $providerSubRuns
        New-HyperVInstance `
            -ImageArtifactId $ArtifactId `
            -StateRoot $StateRoot `
            -AllowLifecycleTestArtifact `
            -RunDirectory $RunDirectory `
            -RunId $RunId `
            -ScopeId $ScopeId `
            -InstanceId 'lifecycle-smoke' `
            -MemoryStartupBytes 512MB `
            -ProcessorCount 1
    } $runDirectory $runId $scopeId $imageArtifact.artifactId $stateRoot

    Assert-HyperVSmoke -Condition ($instance.Provider -eq 'hyperv') -Description 'Providerbindung ist hyperv'
    Assert-HyperVSmoke -Condition (-not $instance.SqlReady) -Description 'Lifecycle-Slice behauptet keine SQL-Bereitschaft'
    Assert-HyperVSmoke -Condition (Test-Path -LiteralPath $instance.ChildVhdxPath -PathType Leaf) -Description 'Differencing Child-VHDX wurde erzeugt'

    $createdStatus = & $module {
        param($VMName, $RunId, $ScopeId)
        Get-HyperVInstanceStatus -VMName $VMName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId
    } $instance.VMName $runId $scopeId
    Assert-HyperVSmoke -Condition ($createdStatus.Exists -and $createdStatus.State -eq 'Off') -Description 'Generation-2-VM ist initial ausgeschaltet'

    $vm = Get-VM -Name $instance.VMName -ErrorAction Stop
    Assert-HyperVSmoke -Condition ($vm.Generation -eq 2) -Description 'VM verwendet Generation 2'
    $firmware = Get-VMFirmware -VM $vm -ErrorAction Stop
    Assert-HyperVSmoke -Condition ($firmware.SecureBoot -eq 'On') -Description 'Secure Boot ist aktiviert'
    Assert-HyperVSmoke -Condition (@(Get-VMNetworkAdapter -VM $vm).Count -eq 0) -Description 'Smoke-VM besitzt keine Netzwerkverbindung'

    $started = & $module {
        param($VMName, $RunId, $ScopeId)
        Start-HyperVInstance -VMName $VMName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId
    } $instance.VMName $runId $scopeId
    Assert-HyperVSmoke -Condition ($started.State -eq 'Running') -Description 'VM wurde gestartet'

    $stopped = & $module {
        param($VMName, $RunId, $ScopeId)
        Stop-HyperVInstance -VMName $VMName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId
    } $instance.VMName $runId $scopeId
    Assert-HyperVSmoke -Condition ($stopped.State -eq 'Off') -Description 'VM wurde gestoppt'

    $cleanup = & $module {
        param($RunDirectory, $ScopeId)
        Invoke-CleanupPlan -RunDir $RunDirectory -ScopeId $ScopeId
    } $runDirectory $scopeId
    Assert-HyperVSmoke -Condition ($cleanup.Status -eq 'CLEANUP_SUCCEEDED') -Description 'Scopegebundener Cleanup war erfolgreich'
    Assert-HyperVSmoke -Condition (-not (Get-VM -Name $instance.VMName -ErrorAction SilentlyContinue)) -Description 'VM wurde entfernt'
    Assert-HyperVSmoke -Condition (-not (Test-Path -LiteralPath $instance.ChildVhdxPath)) -Description 'Child-VHDX wurde entfernt'
    Assert-HyperVSmoke -Condition (Test-Path -LiteralPath $parentPath -PathType Leaf) -Description 'Parent-VHDX blieb erhalten'
    Assert-HyperVSmoke -Condition (Test-Path -LiteralPath $imageArtifact.Path -PathType Leaf) -Description 'Registriertes Image-Artifact blieb erhalten'
    $manifestLock = Get-Content -LiteralPath (Join-Path $runDirectory 'manifest.lock.json') -Raw | ConvertFrom-Json -Depth 20
    Assert-HyperVSmoke -Condition ($manifestLock.artifacts[0].artifactId -eq $imageArtifact.artifactId) -Description 'Manifest Lock referenziert Artifact-ID ohne Hostpfad'

    $isoBytes = [byte[]]::new(65536)
    [System.Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($isoBytes, 32769)
    [System.IO.File]::WriteAllBytes($isoPath, $isoBytes)
    $isoHash = (Get-FileHash -LiteralPath $isoPath -Algorithm SHA256).Hash
    $builder = & $module {
        param($IsoPath, $IsoHash, $StateRoot)
        $plan = New-HyperVWindowsImageBuildPlan -IsoPath $IsoPath -ExpectedSha256 $IsoHash `
            -OperatingSystemId synthetic-ci -Edition none -InstallationType synthetic `
            -LicenseType test-only -OsDiskSizeBytes 64MB -StateRoot $StateRoot
        New-HyperVWindowsImageBuilder -BuildId $plan.buildId -MemoryStartupBytes 512MB -ProcessorCount 1 -StateRoot $StateRoot
    } $isoPath $isoHash $stateRoot
    Assert-HyperVSmoke -Condition ($builder.state -eq 'BUILDER_READY') -Description 'Windows-Image-Builder ist resumierbar bereit'
    $builderVm = Get-VM -Name $builder.builder.vmName -ErrorAction Stop
    Assert-HyperVSmoke -Condition ($builderVm.Generation -eq 2) -Description 'Image-Builder verwendet Generation 2'
    Assert-HyperVSmoke -Condition (@(Get-VMDvdDrive -VM $builderVm).Count -eq 1) -Description 'Verifiziertes Installationsmedium ist eingebunden'
    $manual = & $module { param($BuildId, $StateRoot) Set-HyperVImageBuildManualAction -BuildId $BuildId -StateRoot $StateRoot } $builder.buildId $stateRoot
    Assert-HyperVSmoke -Condition ($manual.state -eq 'MANUAL_ACTION_REQUIRED') -Description 'Nicht automatisierte OS-Installation wird ehrlich persistiert'
    $builderCleanup = & $module { param($Dir, $Scope) Invoke-CleanupPlan -RunDir $Dir -ScopeId $Scope } $builder.BuildDirectory $builder.scopeId
    Assert-HyperVSmoke -Condition ($builderCleanup.Status -eq 'CLEANUP_SUCCEEDED') -Description 'Image-Builder-Cleanup war erfolgreich'
    Assert-HyperVSmoke -Condition (-not (Get-VM -Name $builder.builder.vmName -ErrorAction SilentlyContinue)) -Description 'Image-Builder-VM wurde entfernt'
    $cleanupComplete = $true
}
finally {
    if (-not $KeepOnFailure) {
        if ($module -and -not $cleanupComplete -and (Test-Path -LiteralPath (Join-Path $runDirectory 'cleanup-plan.json'))) {
            try {
                $null = & $module {
                    param($RunDirectory, $ScopeId)
                    Invoke-CleanupPlan -RunDir $RunDirectory -ScopeId $ScopeId
                } $runDirectory $scopeId
            }
            catch {
                Write-Warning "Hyper-V-Smoke-Cleanup fehlgeschlagen: $($_.Exception.Message)"
            }
        }

        if (Test-Path -LiteralPath $parentPath -PathType Leaf) {
            (Get-Item -LiteralPath $parentPath).IsReadOnly = $false
        }
        $safeTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        if (
            $resolvedTestRoot.StartsWith($safeTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedTestRoot) -like 'sql-lab-hyperv-smoke-*' -and
            (Test-Path -LiteralPath $resolvedTestRoot -PathType Container)
        ) {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        }
    }

    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if ($mutexAcquired) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}

Write-Host 'Hyper-V-Lifecycle-Smoke-Test erfolgreich.' -ForegroundColor Green
