#Requires -Version 7.2
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryParent = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-hvr-binding-$([guid]::NewGuid().ToString('N'))"
$dataRoot = Join-Path $temporaryParent 'Lab_Data'
$stateRoot = Join-Path $temporaryParent 'state'
$stateDirectory = Join-Path $stateRoot 'runs/test-run'
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''; Write-Host 'SQL_Server_Lab - Hyper-V Resource Binding Checks' -ForegroundColor Cyan
try {
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    $marker = & $module {
        param($root)
        Initialize-LabManagedDataRoot -DataRoot $root -Confirm:$false
    } $dataRoot
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
    $unknownRejected = try {
        & $module {
            param($path, $state, $root)
            Resolve-LabHyperVMutationRoot -ExistingResourcePath $path -ResourceClass Run -StateRoot $state -DataRoot $root
        } (Join-Path $temporaryParent 'foreign/slot.vhdx') $stateRoot $dataRoot | Out-Null
        $false
    }
    catch { $_.Exception.Message -match 'HYPERV_RESOURCE_MUTATION_ROOT_UNKNOWN' }
    Add-CheckResult -Name 'Unbekannter Mutation-Root wird fail-closed abgewiesen' -Success $unknownRejected
}
catch {
    $failures.Add("Unerwarteter Testfehler: $($_.Exception.Message)")
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryParent) {
        Remove-Item -LiteralPath $temporaryParent -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
