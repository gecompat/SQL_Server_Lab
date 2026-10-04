#Requires -Version 7.2
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryParent = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-hvr-binding-$([guid]::NewGuid().ToString('N'))"
$dataRoot = Join-Path $temporaryParent 'Lab_Data'
$stateRoot = Join-Path $temporaryParent 'state'
$stateDirectory = Join-Path $stateRoot 'runs/test-run'
$previousDataRoot = $env:SQL_SERVER_LAB_DATA_ROOT
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
$custodyRoots = [Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''; Write-Host 'SQL_Server_Lab - Hyper-V Resource Binding Checks' -ForegroundColor Cyan
try {
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    $largeMigrationCapacity = & $module { Get-LabHyperVMigrationRequiredBytes -ContentBytes ([long]23GB) }
    Add-CheckResult -Name 'Migrationsreserve bleibt für reale VHDX-Größen oberhalb Int32 stabil' -Success (
        $largeMigrationCapacity -eq [long][Math]::Ceiling([double]([long]23GB) * 1.10) -and
        $largeMigrationCapacity -gt [int]::MaxValue
    )
    $marker = & $module {
        param($root)
        Initialize-LabManagedDataRoot -DataRoot $root -Confirm:$false
    } $dataRoot
    $env:SQL_SERVER_LAB_DATA_ROOT = $dataRoot
    New-Item -Path $stateDirectory -ItemType Directory -Force | Out-Null

    foreach ($relativePath in @('HyperV/Runs', 'HyperV/Builds', 'HyperV/Images', 'HyperV/Staging', 'HyperV/Recovery')) {
        Add-CheckResult -Name "Data-Root-Layout enthaelt $relativePath" -Success (
            Test-Path -LiteralPath (Join-Path $dataRoot $relativePath) -PathType Container
        )
    }

    $resourceId = [guid]::NewGuid().ToString('D')
    $binding = & $module {
        param($id, $root)
        Resolve-LabHyperVResourceBinding -ResourceId $id -ResourceClass Run -DataRoot $root
    } $resourceId $dataRoot
    Add-CheckResult -Name 'Create-Binding ist versioniert und controller-/location-/volumegebunden' -Success (
        [string]$binding.ContractVersion -eq 'SqlServerLab.HyperVResourceBinding/1.0' -and
        [string]$binding.BindingMode -eq 'CREATE' -and
        [string]$binding.ControllerId -eq [string]$marker.ControllerId -and
        [string]$binding.LocationId -match '^[0-9a-f-]{36}$' -and
        [string]$binding.VolumeId -eq [string]$marker.VolumeId -and
        $binding.AllowsCreate -eq $true -and $binding.AllowsExistingLifecycle -eq $true
    )
    $expectedPrefix = Join-Path $dataRoot 'HyperV/Runs'
    Add-CheckResult -Name 'Create-Root liegt kurz und deterministisch unter registriertem Lab_Data' -Success (
        [string]$binding.ResourceKey -match '^[a-f0-9]{20}$' -and
        [string]$binding.HyperVResourceRoot -eq (Join-Path $expectedPrefix ([string]$binding.ResourceKey)) -and
        ([string]$binding.HyperVResourceRoot).Length -le 180
    )

    $preview = Get-SqlServerLabHyperVResourcePreview -ResourceClass Run,Build,Image,Staging -DataRoot $dataRoot
    Add-CheckResult -Name 'Öffentliche Preview zeigt Location, Kapazität und reproduzierbare Klassenroots ohne Provider-Mutation' -Success (
        [string]$preview.ContractVersion -eq 'SqlServerLab.HyperVResourceLocationPreview/1.0' -and
        [string]$preview.ControllerId -eq [string]$marker.ControllerId -and
        [string]$preview.LocationId -eq [string]$binding.LocationId -and
        [string]$preview.LabDataRoot -eq [string]$dataRoot -and
        [long]$preview.ObservedFreeBytes -ge 0 -and
        @($preview.Targets).Count -eq 4 -and
        @($preview.Targets | Where-Object {
            [string]$_.ClassRoot -notlike "$dataRoot*" -or
            [string]$_.ResourceRootPattern -notmatch '<20-character-resource-key>$'
        }).Count -eq 0
    )
    $tamperedPreview = $preview | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
    $tamperedPreview.Targets[0].ClassRoot = Join-Path $temporaryParent 'foreign'
    $previewTamperRejected = try {
        & $module { param($value) Assert-LabHyperVResourceLocationPreview -Preview $value | Out-Null } $tamperedPreview
        $false
    }
    catch { $_.Exception.Message -match 'HYPERV_RESOURCE_PREVIEW_TARGET_CHANGED' }
    Add-CheckResult -Name 'UAC-Handoff mit abweichendem Klassenroot wird bei Revalidierung blockiert' -Success $previewTamperRejected
    $secondBinding = & $module {
        param($id, $root)
        Resolve-LabHyperVResourceBinding -ResourceId $id -ResourceClass Run -DataRoot $root
    } $resourceId $dataRoot
    Add-CheckResult -Name 'Resource-Key und Create-Root sind unabhaengig vom StateRoot stabil' -Success (
        [string]$binding.ResourceKey -eq [string]$secondBinding.ResourceKey -and
        [string]$binding.HyperVResourceRoot -eq [string]$secondBinding.HyperVResourceRoot -and
        [string]$binding.HyperVResourceRoot -notlike "$stateRoot*"
    )
    $classBindings = @(& $module {
        param($root)
        foreach ($definition in @(
            @{ Class='Build'; Directory='Builds' },
            @{ Class='Image'; Directory='Images' },
            @{ Class='Staging'; Directory='Staging' },
            @{ Class='Recovery'; Directory='Recovery' }
        )) {
            $value = Resolve-LabHyperVResourceBinding -ResourceId "$($definition.Class)-test" `
                -ResourceClass $definition.Class -DataRoot $root
            [PSCustomObject]@{ Binding=$value; Directory=$definition.Directory }
        }
    } $dataRoot)
    Add-CheckResult -Name 'Builder-, Image-, Staging- und Recovery-Roots erhalten eigene kurze Keys' -Success (
        @($classBindings | Where-Object {
            [string]$_.Binding.HyperVResourceRoot -ne (
                Join-Path (Join-Path $dataRoot "HyperV/$($_.Directory)") ([string]$_.Binding.ResourceKey)
            )
        }).Count -eq 0
    )

    $builderStateDirectory = Join-Path $stateRoot 'image-builds/hyperv-sql/bound-build'
    New-Item -Path $builderStateDirectory -ItemType Directory -Force | Out-Null
    $builderBinding = & $module {
        param($directory, $root)
        Initialize-LabHyperVResourceBinding -ResourceId 'bound-build' -ResourceClass Build `
            -StateDirectory $directory -DataRoot $root
    } $builderStateDirectory $dataRoot
    $builderFixture = [PSCustomObject]@{
        BuildDirectory = $builderStateDirectory
        builder = [PSCustomObject]@{
            osDiskRelativePath = 'resources/hyperv/builder.vhdx'
            resourceRelativePath = 'builder.vhdx'
        }
    }
    $boundBuilderDisk = & $module {
        param($build)
        Resolve-LabHyperVBuilderDiskPath -Build $build
    } $builderFixture
    $legacyBuilderDirectory = Join-Path $stateRoot 'image-builds/hyperv-sql/legacy-build'
    New-Item -Path $legacyBuilderDirectory -ItemType Directory -Force | Out-Null
    $legacyBuilderFixture = [PSCustomObject]@{
        BuildDirectory = $legacyBuilderDirectory
        builder = [PSCustomObject]@{ osDiskRelativePath = 'resources/hyperv/legacy.vhdx' }
    }
    $legacyBuilderDisk = & $module {
        param($build)
        Resolve-LabHyperVBuilderDiskPath -Build $build
    } $legacyBuilderFixture
    Add-CheckResult -Name 'Builder-Diskaufloesung trennt gebundenen Lab_Data-Root vom Legacy-StateRoot' -Success (
        [string]$boundBuilderDisk -eq (Join-Path ([string]$builderBinding.HyperVResourceRoot) 'builder.vhdx') -and
        [string]$boundBuilderDisk -notlike "$builderStateDirectory*" -and
        [string]$legacyBuilderDisk -eq (Join-Path $legacyBuilderDirectory 'resources/hyperv/legacy.vhdx')
    )

    $bindingPath = & $module {
        param($value, $directory, $root)
        Write-LabHyperVResourceBinding -Binding $value -StateDirectory $directory -DataRoot $root
    } $binding $stateDirectory $dataRoot
    $bindingJson = Get-Content -LiteralPath $bindingPath -Raw -Encoding utf8
    Add-CheckResult -Name 'Persistierte lokale Binding erfuellt ihr JSON-Schema' -Success (
        $bindingJson | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/hyperv-resource-binding.schema.json') -ErrorAction SilentlyContinue
    )
    $roundTrip = & $module {
        param($directory, $root)
        Read-LabHyperVResourceBinding -StateDirectory $directory -DataRoot $root
    } $stateDirectory $dataRoot
    Add-CheckResult -Name 'Binding wird vor Wiederverwendung gegen Registry und Marker revalidiert' -Success (
        [string]$roundTrip.ResourceKey -eq [string]$binding.ResourceKey -and
        [string]$roundTrip.HyperVResourceRoot -eq [string]$binding.HyperVResourceRoot
    )

    $tampered = $binding | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
    $tampered.ControllerId = [guid]::NewGuid().ToString('D')
    $tamperRejected = & $module {
        param($value, $root)
        $result = Test-LabHyperVResourceBinding -Binding $value -DataRoot $root
        return (-not $result.Valid -and [string]$result.Code -eq 'HYPERV_RESOURCE_BINDING_IDENTITY_CHANGED')
    } $tampered $dataRoot
    Add-CheckResult -Name 'Abweichende Controller-Evidence blockiert fail-closed' -Success $tamperRejected

    $unregisteredRejected = try {
        & $module {
            param($root)
            Resolve-LabHyperVResourceBinding -ResourceId ([guid]::NewGuid().ToString('D')) -ResourceClass Build `
                -LocationId ([guid]::NewGuid().ToString('D')) -DataRoot $root
        } $dataRoot | Out-Null
        $false
    }
    catch { $_.Exception.Message -match 'HYPERV_RESOURCE_BINDING_LOCATION_NOT_FOUND' }
    Add-CheckResult -Name 'Nicht registrierte Location wird als Create-Root abgewiesen' -Success $unregisteredRejected

    $discoveryRoots = @(& $module {
        param($state, $root)
        Get-LabHyperVResourceDiscoveryRoots -ResourceClass Run -StateRoot $state -DataRoot $root
    } $stateRoot $dataRoot)
    $registeredDiscovery = @($discoveryRoots | Where-Object RootKind -eq 'REGISTERED')
    $legacyDiscovery = @($discoveryRoots | Where-Object RootKind -eq 'LEGACY_READ_ONLY')
    Add-CheckResult -Name 'Discovery trennt registrierte Create-Roots von read-only Legacy-Roots' -Success (
        $registeredDiscovery.Count -eq 1 -and $registeredDiscovery[0].AllowsCreate -eq $true -and
        $legacyDiscovery.Count -eq 1 -and $legacyDiscovery[0].AllowsCreate -eq $false -and
        $legacyDiscovery[0].AllowsExistingLifecycle -eq $true
    )

    $registeredMutation = & $module {
        param($path, $state, $root)
        Resolve-LabHyperVMutationRoot -ExistingResourcePath $path -ResourceClass Run -StateRoot $state -DataRoot $root
    } (Join-Path $binding.HyperVResourceRoot 'slot.vhdx') $stateRoot $dataRoot
    $legacyMutation = & $module {
        param($path, $state, $root)
        Resolve-LabHyperVMutationRoot -ExistingResourcePath $path -ResourceClass Run -StateRoot $state -DataRoot $root
    } (Join-Path $stateRoot 'runs/legacy-run/resources/hyperv/slot.vhdx') $stateRoot $dataRoot
    Add-CheckResult -Name 'Mutation-Root erhaelt registrierte Ressourcen und klassifiziert Legacy read-only' -Success (
        [string]$registeredMutation.RootKind -eq 'REGISTERED' -and $registeredMutation.AllowsCreate -eq $true -and
        [string]$legacyMutation.RootKind -eq 'LEGACY_READ_ONLY' -and $legacyMutation.AllowsCreate -eq $false -and
        $legacyMutation.AllowsExistingLifecycle -eq $true
    )
    $markerPath = Join-Path $dataRoot '.sql-server-lab-root.json'
    $originalMarkerJson = Get-Content -LiteralPath $markerPath -Raw -Encoding utf8
    $markerDocument = $originalMarkerJson | ConvertFrom-Json -Depth 10
    $markerDocument.VolumeId = 'tampered-volume-id'
    $markerDocument | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $markerPath -Encoding utf8
    $staleMutationRejected = try {
        & $module {
            param($path, $state, $root)
            Resolve-LabHyperVMutationRoot -ExistingResourcePath $path -ResourceClass Run -StateRoot $state -DataRoot $root | Out-Null
        } (Join-Path $binding.HyperVResourceRoot 'slot.vhdx') $stateRoot $dataRoot
        $false
    }
    catch { $_.Exception.Message -match 'HYPERV_RESOURCE_MUTATION_ROOT_REVALIDATION_FAILED' }
    Set-Content -LiteralPath $markerPath -Value $originalMarkerJson -Encoding utf8NoBOM
    Add-CheckResult -Name 'Registrierter Mutation-Root wird vor bestehendem Lifecycle erneut gegen Ownership geprüft' -Success $staleMutationRejected
    $unknownRejected = try {
        & $module {
            param($path, $state, $root)
            Resolve-LabHyperVMutationRoot -ExistingResourcePath $path -ResourceClass Run -StateRoot $state -DataRoot $root
        } (Join-Path $temporaryParent 'foreign/slot.vhdx') $stateRoot $dataRoot | Out-Null
        $false
    }
    catch { $_.Exception.Message -match 'HYPERV_RESOURCE_MUTATION_ROOT_UNKNOWN' }
    Add-CheckResult -Name 'Unbekannter Mutation-Root wird fail-closed abgewiesen' -Success $unknownRejected

    $initialized = & $module {
        param($id, $directory, $root)
        Initialize-LabHyperVResourceBinding -ResourceId $id -ResourceClass Run `
            -StateDirectory $directory -DataRoot $root
    } $resourceId $stateDirectory $dataRoot
    $boundPath = & $module {
        param($value, $root)
        Assert-LabHyperVBoundPath -Binding $value -Path (Join-Path $value.HyperVResourceRoot 'slot.vhdx') -DataRoot $root
    } $initialized $dataRoot
    Add-CheckResult -Name 'Initialisierung verwendet das persistierte Binding idempotent und prueft den Zielpfad' -Success (
        [string]$initialized.ResourceKey -eq [string]$binding.ResourceKey -and
        [string]$boundPath -eq (Join-Path $binding.HyperVResourceRoot 'slot.vhdx')
    )
    $identityMismatchRejected = try {
        & $module {
            param($directory, $root)
            Initialize-LabHyperVResourceBinding -ResourceId 'other-run' -ResourceClass Run `
                -StateDirectory $directory -DataRoot $root | Out-Null
        } $stateDirectory $dataRoot
        $false
    }
    catch { $_.Exception.Message -match 'HYPERV_RESOURCE_BINDING_STATE_IDENTITY_MISMATCH' }
    Add-CheckResult -Name 'Persistiertes Binding kann nicht fuer eine andere Ressourcenidentitaet wiederverwendet werden' -Success $identityMismatchRejected
    $longPathRejected = try {
        & $module {
            param($value, $root)
            Assert-LabHyperVBoundPath -Binding $value -Path (Join-Path $value.HyperVResourceRoot (('x' * 190) + '.vhdx')) -DataRoot $root | Out-Null
        } $initialized $dataRoot
        $false
    }
    catch { $_.Exception.Message -match 'HYPERV_RESOURCE_PATH_TOO_LONG' }
    Add-CheckResult -Name 'Zu lange physische Ressourcenpfade werden vor der Mutation abgewiesen' -Success $longPathRejected

    # Execute the native harness's real finalizer and helpers with synthetic
    # provider commands, including failures before a creation result is returned.
    $smokeTokens = $null; $smokeErrors = $null
    $smokeAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVSmokeTest.ps1'), [ref]$smokeTokens, [ref]$smokeErrors)
    $helperNames = @('Add-HyperVSmokeCreatedVM', 'Assert-HyperVSmokeCreatedVMAbsence',
        'Assert-HyperVSmokeOwnedPaths', 'Remove-HyperVSmokeOwnedRoot')
    $helperDefinitions = @($smokeAst.FindAll({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $helperNames
    }, $true))
    $mainTry = @($smokeAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
    if ($smokeErrors.Count -or $helperDefinitions.Count -ne 4 -or $mainTry.Count -ne 1) {
        throw 'HYPERV_SMOKE_CUSTODY_FIXTURE_SOURCE_INVALID'
    }
    $finallyText = $mainTry[0].Finally.Extent.Text
    Add-CheckResult -Name 'Publication does not prematurely close the builder reference' -Success (
        $mainTry[0].Body.Extent.Text -notmatch '\$builderCleanupComplete\s*=\s*\$true')
    $custodyModule = New-Module -ScriptBlock {
        param($Helpers, $FinallyBody)
        Invoke-Expression $Helpers
        $script:ActualFinalizer = [scriptblock]::Create($FinallyBody)
        function Get-VM {
            [CmdletBinding()]param([string]$Name)
            $script:InventoryCalls++
            switch ($script:CustodyMode) {
                'READ_ERROR' { Write-Error 'SYNTHETIC_INVENTORY_UNKNOWN'; return }
                'VM_RENAMED' { [pscustomobject]@{Id=$script:CreatedId;Name='synthetic-renamed'} }
                'NAME_REUSED' { [pscustomobject]@{Id=[guid]::NewGuid().ToString('D');Name='synthetic-smoke'} }
                'NATIVE_ID_NONCANONICAL' { [pscustomobject]@{Id=('{'+$script:CreatedId+'}');Name='synthetic-renamed'} }
                default { @() }
            }
        }
        function Test-Path {
            [CmdletBinding()]param([string]$LiteralPath,[string]$PathType)
            if ($LiteralPath -like '*cleanup-plan.json' -and
                $script:CustodyMode -in @('LIFECYCLE_PLAN_READ_ERROR','BUILDER_PLAN_READ_ERROR')) {
                Write-Error 'SYNTHETIC_PLAN_READ_UNKNOWN'; return
            }
            $arguments=@{LiteralPath=$LiteralPath;ErrorAction='Stop'}
            if ($PathType) { $arguments.PathType=$PathType }
            Microsoft.PowerShell.Management\Test-Path @arguments
        }
        function Invoke-CleanupPlan {
            param($RunDir,$ScopeId)
            if ($script:CustodyMode -eq 'CLEANUP_ERROR') { throw 'SYNTHETIC_CLEANUP_FAILED' }
            [pscustomobject]@{Status='CLEANUP_SUCCEEDED'}
        }
        function Remove-SqlServerLab {
            param($RunId,$StateRoot,[switch]$Force)
            [pscustomobject]@{Status='REMOVED';Cleanup='CLEANUP_FAILED'}
        }
        function Remove-HyperVWindowsImageBuild {
            param($BuildId,$StateRoot)
            $script:BuilderCalls++
            if ($script:CustodyMode -eq 'PUBLISHED_BUILDER_SUCCESS') {
                $script:BuilderTerminal=$true
                return [pscustomobject]@{Status='CLEANUP_SUCCEEDED';Build=[pscustomobject]@{state='CLEANED_UP'}}
            }
            if ($script:CustodyMode -eq 'PUBLISHED_BUILDER_STATE_ERROR') {
                return [pscustomobject]@{Status='CLEANUP_SUCCEEDED';Build=[pscustomobject]@{state='TEST_ARTIFACT_PUBLISHED'}}
            }
            [pscustomobject]@{Status='CLEANUP_FAILED';Build=[pscustomobject]@{state='FAILED'}}
        }
        function Remove-HyperVImageArtifact {
            param($ArtifactId,$StateRoot)
            $script:ArtifactCalls++
            if ($script:CustodyMode -like 'PUBLISHED_BUILDER_*' -and -not $script:BuilderTerminal) {
                throw 'SYNTHETIC_PUBLISHED_BUILD_REFERENCE_IN_USE'
            }
            [pscustomobject]@{Status=$(if($script:CustodyMode -eq 'ARTIFACT_ERROR'){'IN_USE'}else{'REMOVED'})}
        }
        function Remove-Module { [CmdletBinding()]param($Name,[switch]$Force) }
        Export-ModuleMember -Function @()
    } -ArgumentList (($helperDefinitions.Extent.Text) -join "`n"), $finallyText.Substring(1,$finallyText.Length-2)

    foreach ($mode in @('UNRETURNED_LIFECYCLE','UNRETURNED_RECONCILE','UNRETURNED_BUILDER',
        'CLEANUP_ERROR','LIFECYCLE_PLAN_READ_ERROR','BUILDER_PLAN_READ_ERROR','RECONCILE_ERROR','BUILDER_ERROR','READ_ERROR','VM_RENAMED','NAME_REUSED',
        'NATIVE_ID_NONCANONICAL','ARTIFACT_ERROR','ROOT_LINK','PARENT_ANCESTOR_LINK',
        'PUBLISHED_BUILDER_SUCCESS','PUBLISHED_BUILDER_STATUS_ERROR','PUBLISHED_BUILDER_STATE_ERROR','SUCCESS')) {
        $custodyRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hyperv-smoke-'+[guid]::NewGuid().ToString('N'))
        $custodyRoots.Add($custodyRoot)
        $custodyParent = Join-Path $custodyRoot 'synthetic-parent.vhdx'
        if ($mode -in @('ROOT_LINK','PARENT_ANCESTOR_LINK')) {
            $targetRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hyperv-smoke-'+[guid]::NewGuid().ToString('N'))
            $custodyRoots.Add($targetRoot)
            $null = New-Item -ItemType Directory -Path $targetRoot
            $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            if ($mode -eq 'ROOT_LINK') {
                $null = New-Item -ItemType $linkType -Path $custodyRoot -Target $targetRoot
            }
            else {
                $null = New-Item -ItemType Directory -Path $custodyRoot
                $link = Join-Path $custodyRoot 'linked'
                $null = New-Item -ItemType $linkType -Path $link -Target $targetRoot
                $custodyParent = Join-Path $link 'synthetic-parent.vhdx'
            }
        }
        else { $null = New-Item -ItemType Directory -Path $custodyRoot }
        [IO.File]::WriteAllText($custodyParent, 'synthetic immutable parent')
        (Get-Item -LiteralPath $custodyParent).IsReadOnly = $true
        $case = & $custodyModule {
            param($Root,$Parent,$Mode,$Self)
            $script:CustodyMode=$Mode; $script:InventoryCalls=0; $script:ArtifactCalls=0
            $script:BuilderCalls=0; $script:BuilderTerminal=$false
            $script:CreatedId=[guid]::NewGuid().ToString('D')
            $testRoot=$Root; $parentPath=$Parent; $stateRoot=Join-Path $Root 'state'
            $runId=[guid]::NewGuid().ToString('D'); $scopeId=[guid]::NewGuid().ToString('D')
            $runDirectory=Join-Path (Join-Path $stateRoot 'runs') $runId
            if ($Mode -ne 'ROOT_LINK') {
                $null=New-Item -ItemType Directory -Path $runDirectory -Force
                [IO.File]::WriteAllText((Join-Path $runDirectory 'cleanup-plan.json'),'{}')
            }
            $module=$Self; $KeepOnFailure=$false
            $imageArtifact=[pscustomobject]@{artifactId='synthetic-owned-image'}
            $reconcileImageArtifact=$null; $published=$null; $builder=$null; $reconcileRun=$null
            $cleanupComplete=$Mode -in @('ROOT_LINK','PARENT_ANCESTOR_LINK','NATIVE_ID_NONCANONICAL')
            $builderCleanupComplete=$false; $reconcileCleanupComplete=$false
            $lifecycleCreationStarted=$true; $lifecycleCreationUnreturned=$Mode -eq 'UNRETURNED_LIFECYCLE'
            $reconcileCreationStarted=$false; $reconcileCreationUnreturned=$false
            $builderCreationStarted=$false; $builderCreationUnreturned=$false
            $instance=[pscustomobject]@{VMId=$script:CreatedId;VMName='synthetic-smoke'}
            $createdVMs=[Collections.Generic.List[object]]::new()
            if ($Mode -like 'UNRETURNED_*') {
                $instance=$null
                if ($Mode -eq 'UNRETURNED_RECONCILE') {
                    $lifecycleCreationStarted=$false; $reconcileCreationStarted=$true; $reconcileCreationUnreturned=$true
                }
                if ($Mode -eq 'UNRETURNED_BUILDER') {
                    $lifecycleCreationStarted=$false; $builderCreationStarted=$true; $builderCreationUnreturned=$true
                }
            }
            else {
                Add-HyperVSmokeCreatedVM -Ledger $createdVMs -VMId $instance.VMId -VMName $instance.VMName
                if ($Mode -eq 'RECONCILE_ERROR') {
                    $lifecycleCreationStarted=$false; $reconcileCreationStarted=$true
                    $reconcileRun=[pscustomobject]@{RunId=$runId;ScopeId=$scopeId}
                }
                if ($Mode -in @('BUILDER_ERROR','BUILDER_PLAN_READ_ERROR') -or $Mode -like 'PUBLISHED_BUILDER_*') {
                    $lifecycleCreationStarted=$false; $builderCreationStarted=$true
                    $builder=[pscustomobject]@{BuildDirectory=$runDirectory;buildId=$runId}
                    if ($Mode -like 'PUBLISHED_BUILDER_*') {
                        $published=[pscustomobject]@{Artifact=$imageArtifact}
                    }
                }
            }
            $artifactCleanupFailures=[Collections.Generic.List[string]]::new()
            $runtimeCleanupFailures=[Collections.Generic.List[string]]::new()
            $mutexAcquired=$true
            $mutex=[pscustomobject]@{Disposed=$false;Released=$false}
            $mutex | Add-Member -MemberType ScriptMethod -Name Dispose -Value {$this.Disposed=$true}
            $mutex | Add-Member -MemberType ScriptMethod -Name ReleaseMutex -Value {$this.Released=$true}
            $primary=$null
            try { try { throw 'SYNTHETIC_PRIMARY_FAILURE' } finally { & $script:ActualFinalizer } }
            catch { $primary=$_.Exception.Message }
            [pscustomobject]@{
                Primary=$primary;RootPresent=(Test-Path -LiteralPath $Root)
                ParentPreserved=((Test-Path -LiteralPath $Parent -PathType Leaf) -and
                    (Get-Item -LiteralPath $Parent).IsReadOnly -and [IO.File]::ReadAllText($Parent) -ceq 'synthetic immutable parent')
                ArtifactCalls=$script:ArtifactCalls;InventoryCalls=$script:InventoryCalls;MutexDisposed=$mutex.Disposed;MutexReleased=$mutex.Released
                BuilderCalls=$script:BuilderCalls;BuilderTerminal=$script:BuilderTerminal
            }
        } $custodyRoot $custodyParent $mode $custodyModule
        $success = if ($mode -in @('SUCCESS','PUBLISHED_BUILDER_SUCCESS')) {
            -not $case.RootPresent -and $case.ArtifactCalls -eq 1 -and $case.InventoryCalls -ge 2
        } else {
            $case.RootPresent -and $case.ParentPreserved -and
                (($mode -eq 'ARTIFACT_ERROR' -and $case.ArtifactCalls -eq 1) -or $case.ArtifactCalls -eq 0)
        }
        if ($mode -like 'PUBLISHED_BUILDER_*') {
            $success = $success -and $case.BuilderCalls -eq 1 -and
                $case.BuilderTerminal -eq ($mode -eq 'PUBLISHED_BUILDER_SUCCESS')
        }
        Add-CheckResult -Name "Echter Smoke-Finalizer bewahrt Primaryfehler und Custody: $mode" -Success (
            $success -and $case.Primary -ceq 'SYNTHETIC_PRIMARY_FAILURE' -and $case.MutexDisposed -and $case.MutexReleased)
    }
    $invalidLedger = & $custodyModule {
        $ledger=[Collections.Generic.List[object]]::new(); $blocked=0
        foreach ($id in @('',[guid]::Empty.ToString('D'),('{'+[guid]::NewGuid().ToString('D')+'}'))) {
            try { Add-HyperVSmokeCreatedVM -Ledger $ledger -VMId $id -VMName 'synthetic-smoke' }
            catch { if($_.Exception.Message -ceq 'HYPERV_SMOKE_CREATION_BINDING_UNKNOWN'){$blocked++} }
        }
        $blocked -eq 3 -and $ledger.Count -eq 0
    }
    Add-CheckResult -Name 'Leere, Null-GUID und nichtkanonische Creation-ID erzeugen keine scheinbare Quittung' -Success $invalidLedger

    $providerText = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/HyperV/HyperVProvider.ps1') -Raw -Encoding utf8
    $imageBuilderText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVImageBuilder.ps1') -Raw -Encoding utf8
    $sqlBuilderText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVSqlImageBuilder.ps1') -Raw -Encoding utf8
    $registryText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVImageRegistry.ps1') -Raw -Encoding utf8
    $environmentText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1') -Raw -Encoding utf8
    $sqlAcceptanceEnvironmentText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVSqlAcceptanceEnvironment.ps1') -Raw -Encoding utf8
    $sqlPreparedAcceptanceText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVSqlPreparedImageAcceptance.ps1') -Raw -Encoding utf8
    $generalizeAcceptanceText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVWindowsGeneralizeAcceptance.ps1') -Raw -Encoding utf8
    $hyperVSmokeText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVSmokeTest.ps1') -Raw -Encoding utf8
    $menuText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Run-Provider bindet VHDX, VM-Konfiguration, Paging und Snapshots an denselben Root' -Success (
        $providerText -match 'Initialize-LabHyperVResourceBinding[\s\S]+ResourceClass\s+\$ResourceClass[\s\S]+New-VHD' -and
        $providerText -match 'SmartPagingFilePath\s+\$resourceRoot[\s\S]+SnapshotFileLocation\s+\$resourceRoot' -and
        $providerText -match 'Assert-HyperVVMResourceBinding'
    )
    Add-CheckResult -Name 'Windows- und SQL-Builder mutieren nur nach Build-Binding und Pfadpostcondition' -Success (
        $imageBuilderText -match 'Initialize-LabHyperVResourceBinding[\s\S]+ResourceClass\s+Build[\s\S]+Assert-LabHyperVBoundPath[\s\S]+New-VHD' -and
        $sqlBuilderText -match 'Initialize-LabHyperVResourceBinding[\s\S]+ResourceClass\s+Build[\s\S]+Assert-LabHyperVBoundPath[\s\S]+New-VHD' -and
        $sqlBuilderText -match 'Resolve-LabHyperVStateResourcePath[\s\S]+Convert-VHD'
    )
    Add-CheckResult -Name 'Produktive und reale Builder-Consumer verwenden dieselbe gebundene Diskaufloesung' -Success (
        $sqlAcceptanceEnvironmentText -match 'Resolve-LabHyperVBuilderDiskPath\s+-Build\s+\$build' -and
        $sqlPreparedAcceptanceText -match 'Resolve-LabHyperVBuilderDiskPath\s+-Build\s+\$Build' -and
        $generalizeAcceptanceText -match 'Resolve-LabHyperVBuilderDiskPath\s+-Build\s+\$Build' -and
        $hyperVSmokeText -match 'Resolve-LabHyperVBuilderDiskPath\s+-Build\s+\$Build'
    )
    Add-CheckResult -Name 'Nativer Hyper-V-Smoke räumt Buildreferenzen und alle synthetischen Registry-Artefakte auf' -Success (
        $hyperVSmokeText -match 'Remove-HyperVWindowsImageBuild' -and
        $hyperVSmokeText -match 'Remove-HyperVImageArtifact' -and
        $hyperVSmokeText -match 'Hyper-V-Smoke hinterliess Registry-Artefakte'
    )
    Add-CheckResult -Name 'Nativer Hyper-V-Smoke liefert nach erfolgreichem Abschluss keinen veralteten nativen Exitcode' -Success (
        $hyperVSmokeText.Contains('$global:LASTEXITCODE = 0') -and
        $hyperVSmokeText.LastIndexOf('$global:LASTEXITCODE = 0', [System.StringComparison]::Ordinal) -gt
            $hyperVSmokeText.LastIndexOf('Hyper-V-Lifecycle-Smoke-Test erfolgreich.', [System.StringComparison]::Ordinal)
    )
    Add-CheckResult -Name 'Image-Registry trennt Control-State von gebundenem Image- und Staging-Store' -Success (
        $registryText -match "ResourceId\s+'hyperv-image-store'[\s\S]+ResourceClass\s+Image" -and
        $registryText -match "ResourceId\s+'hyperv-staging-store'[\s\S]+ResourceClass\s+Staging" -and
        $registryText -match 'Assert-LabHyperVBoundPath[\s\S]+Copy-LabProgressFile[\s\S]+Move-Item'
    )
    Add-CheckResult -Name 'Existing-VM-Konvertierung bindet Ziel und prueft die erzeugte Parent-Kopie' -Success (
        $environmentText -match 'Initialize-LabHyperVResourceBinding[\s\S]+Convert-VHD[\s\S]+HYPERV_SOURCE_PARENT_COPY_POSTCONDITION_FAILED'
    )
    Add-CheckResult -Name 'Console-UI zeigt Run-, Build-, Image- und Staging-Ziele vor den Hyper-V-Erstellungsaktionen' -Success (
        $menuText -match "Betriebssystem-Slot aus Windows-OS-Vorlage'.+-Action .+-ResourceClass Run" -and
        $menuText -match "Neue SQL-Prepared-Vorlage'.+-Action .+-ResourceClass Build,Image,Staging" -and
        $menuText -match "Automatischen Abschluss fortsetzen'.+-Action .+-ResourceClass Build,Image,Staging" -and
        $menuText -match "Windows-Image veröffentlichen'.+-Action .+-ResourceClass Image,Staging" -and
        $menuText -match 'Write-LabHyperVResourceLocationPreview'
    )
}
catch {
    $failures.Add("Unerwarteter Testfehler: $($_.Exception.Message)")
}
finally {
    $env:SQL_SERVER_LAB_DATA_ROOT = $previousDataRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    foreach ($root in $custodyRoots) {
        $full=[IO.Path]::GetFullPath($root)
        $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $full) -cnotmatch '^sql-lab-hyperv-smoke-[a-f0-9]{32}$') { throw 'CUSTODY_FIXTURE_CLEANUP_SCOPE_INVALID' }
        if (Test-Path -LiteralPath $full) {
            $item=Get-Item -LiteralPath $full -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Remove-Item -LiteralPath $full -Force
            }
            else {
                Get-ChildItem -LiteralPath $full -File -Recurse | ForEach-Object { $_.IsReadOnly=$false }
                Remove-Item -LiteralPath $full -Recurse -Force
            }
        }
    }
    if (Test-Path -LiteralPath $temporaryParent) {
        Remove-Item -LiteralPath $temporaryParent -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
