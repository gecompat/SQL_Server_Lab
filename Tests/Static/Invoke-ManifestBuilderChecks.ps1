#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Manifest-Builder, Schema- und Fachvalidierung ohne Labressourcen.
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Manifest Builder Checks' -ForegroundColor Cyan

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop

foreach ($commandName in @('New-SqlServerLabManifest', 'Test-SqlServerLabManifest')) {
    Add-CheckResult `
        -Name "Export verfuegbar: $commandName" `
        -Success ([bool](Get-Command $commandName -Module SqlServerLab -ErrorAction SilentlyContinue))
}

$module = Get-Module SqlServerLab
$schemaSupport = & $module {
    Test-LabManifestSchemaInputSupport -RootSchema (Get-LabManifestSchema)
}
Add-CheckResult `
    -Name 'Alle aktuellen Schemaknoten werden vom Wizard unterstuetzt' `
    -Success $schemaSupport.IsSupported `
    -Message ($schemaSupport.Errors -join '; ')

$pathUiContract = & $module {
    Test-LabManifestPathUiMetadata -RootSchema (Get-LabManifestSchema)
}
Add-CheckResult `
    -Name 'Alle Manifestpfade besitzen vollstaendige x-ui-Semantik' `
    -Success $pathUiContract.IsValid `
    -Message ($pathUiContract.Errors -join '; ')

$artifactContract = & $module {
    Resolve-LabSampleArtifact `
        -SampleDefinition ([PSCustomObject]@{ id = 'adventureworks-2022'; variant = 'full' }) `
        -SqlVersion '2022'
}
Add-CheckResult `
    -Name 'Sample-Katalog wird als typisierter Artifact-Vertrag aufgeloest' `
    -Success ($artifactContract.artifactType -eq 'backup' -and
        $artifactContract.handlerContractVersion -eq '1' -and
        $artifactContract.expectedOutputs.Count -eq 1 -and
        $artifactContract.expectedOutputs[0].name -eq 'AdventureWorks2022' -and
        $artifactContract.trustPolicy -eq 'interactive-once') `
    -Message "Artifact Type: $($artifactContract.artifactType); Outputs: $($artifactContract.expectedOutputs.name -join ', ')"

$wizardDraft = & $module {
    $originalString = (Get-Command Read-LabString).ScriptBlock
    $originalChoice = (Get-Command Read-LabManifestChoice).ScriptBlock
    try {
        Set-Item Function:Read-LabString -Value {
            param([string]$Prompt)
            switch -Regex ($Prompt) {
                '^manifest\.name$'                  { return 'wizard-check' }
                '^manifest\.instances\[1\]\.id$'      { return 'primary' }
                '^manifest\.instances\[1\]\.version$' { return '2025' }
                default { throw "Unerwartete Testeingabe: $Prompt" }
            }
        }
        Set-Item Function:Read-LabManifestChoice -Value { param() return 1 }
        New-LabManifestDraft -SchemaReference './Schemas/lab-manifest.schema.json'
    }
    finally {
        Set-Item Function:Read-LabString -Value $originalString
        Set-Item Function:Read-LabManifestChoice -Value $originalChoice
    }
}
$wizardResult = Test-SqlServerLabManifest -InputObject $wizardDraft
Add-CheckResult `
    -Name 'Schema-Wizard bewahrt eine einzelne Instanz als Array' `
    -Success ($wizardDraft.instances -is [array] -and
        $wizardDraft.instances.Count -eq 1 -and
        $wizardResult.IsValid) `
    -Message ($wizardResult.Errors -join '; ')

$wizardNavigation = & $module {
    $schema = [PSCustomObject]@{
        type = 'object'
        required = @('first', 'second')
        properties = [PSCustomObject][ordered]@{
            first = [PSCustomObject]@{ type='string'; description='Erster Wert' }
            second = [PSCustomObject]@{ type='string'; description='Zweiter Wert' }
        }
    }
    $originalString = (Get-Command Read-LabString).ScriptBlock
    $script:ManifestNavigationInputs = [System.Collections.Generic.Queue[string]]::new()
    @('alpha', '<', 'beta', '=', 'omega') | ForEach-Object { $script:ManifestNavigationInputs.Enqueue($_) }
    try {
        Set-Item Function:Read-LabString -Value { param() $script:ManifestNavigationInputs.Dequeue() }
        $draft = Read-LabManifestSchemaValue -Node $schema -RootSchema $schema -Path 'navigation'
        [PSCustomObject]@{
            Draft = $draft
            RemainingInputs = $script:ManifestNavigationInputs.Count
        }
    }
    finally {
        Set-Item Function:Read-LabString -Value $originalString
        Remove-Variable ManifestNavigationInputs -Scope Script -ErrorAction SilentlyContinue
    }
}
Add-CheckResult `
    -Name 'Wizard kann zu einem vorherigen Schritt zurueckkehren und eine Zusammenfassung anzeigen' `
    -Success ($wizardNavigation.Draft.first -eq 'beta' -and
        $wizardNavigation.Draft.second -eq 'omega' -and
        $wizardNavigation.RemainingInputs -eq 0) `
    -Message ($wizardNavigation | ConvertTo-Json -Depth 10 -Compress)

$cancelTarget = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-manifest-cancel-$([guid]::NewGuid().ToString('N')).json"
$wizardCancel = & $module {
    param($Target)
    $originalString = (Get-Command Read-LabString).ScriptBlock
    try {
        Set-Item Function:Read-LabString -Value { param() return '!' }
        New-SqlServerLabManifest -Path $Target
        -not (Test-Path -LiteralPath $Target)
    }
    finally {
        Set-Item Function:Read-LabString -Value $originalString
    }
} $cancelTarget
Add-CheckResult `
    -Name 'Wizard-Abbruch schreibt keine partielle Manifestdatei' `
    -Success $wizardCancel

$spConfigure = & $module {
    $originalString = (Get-Command Read-LabString).ScriptBlock
    $script:ManifestBuilderReadHostCall = 0
    try {
        Set-Item Function:Read-Host -Value {
            $script:ManifestBuilderReadHostCall++
            if ($script:ManifestBuilderReadHostCall -eq 1) {
                return 'optimize for ad hoc workloads'
            }
            return ''
        }
        Set-Item Function:Read-LabString -Value { param() return '1' }

        $schema = Get-LabManifestSchema
        $node = $schema.definitions.serverConfig.properties.spConfigure
        Read-LabManifestSchemaValue `
            -Node $node `
            -RootSchema $schema `
            -Path 'manifest.instances[1].serverConfig.spConfigure'
    }
    finally {
        Remove-Item Function:Read-Host -Force -ErrorAction SilentlyContinue
        Set-Item Function:Read-LabString -Value $originalString
        Remove-Variable ManifestBuilderReadHostCall -Scope Script -ErrorAction SilentlyContinue
    }
}
Add-CheckResult `
    -Name 'Freie spConfigure-Schluessel werden erfasst' `
    -Success ($spConfigure.'optimize for ad hoc workloads' -eq 1)

$minimal = [ordered]@{
    name      = 'manifest-check'
    instances = @(
        [ordered]@{
            id       = 'primary'
            version  = '2025'
            provider = 'docker'
        }
    )
}
$minimalResult = Test-SqlServerLabManifest -InputObject $minimal
Add-CheckResult `
    -Name 'Minimales Manifest ist gueltig' `
    -Success $minimalResult.IsValid `
    -Message ($minimalResult.Errors -join '; ')
Add-CheckResult `
    -Name 'Container-Manifest plant standardmaessig NAT mit Host-Exposure' `
    -Success ($minimalResult.Plan.Contract.Version -eq '1.2' -and
        $minimalResult.Plan.Instances[0].Network.Status -eq 'RESOLVED' -and
        $minimalResult.Plan.Instances[0].Network.Intent -eq 'nat' -and
        $minimalResult.Plan.Instances[0].Network.Exposure -eq 'host')

$externalRuntimeManifest = [ordered]@{
    name = 'external-runtime-plan-check'
    instances = @(
        [ordered]@{
            id = 'primary'; version = '2022'; provider = 'docker'; os = 'linux'
            software = @([ordered]@{
                id = 'sql-python'; version = '3.10'; variant = 'sql2022-python310-ubuntu2204-derived'
                scope = 'sqlExternalRuntime'; installMethod = 'catalog'; optional = $false
            })
        }
    )
}
$externalRuntimeResult = Test-SqlServerLabManifest -InputObject $externalRuntimeManifest
$externalRuntimePlan = @($externalRuntimeResult.Plan.Instances[0].ExternalRuntimes.Entries)[0]
Add-CheckResult `
    -Name 'Manifestpruefung liefert eine strukturierte External-Runtime-Planvorschau' `
    -Success ($externalRuntimeResult.IsValid -and
        $externalRuntimeResult.Plan.Contract.Name -eq 'SqlServerLab.ManifestPlanPreview' -and
        $externalRuntimePlan.Status -eq 'RESOLVED' -and
        $externalRuntimePlan.ChangeClassification.Artifact -eq 'rebuild' -and
        $externalRuntimePlan.ChangeClassification.Service -eq 'restart' -and
        $externalRuntimePlan.ChangeClassification.Activation -eq 'recreate' -and
        $externalRuntimePlan.BuildDerivedImage -and
        @($externalRuntimePlan.Downloads).Count -gt 0 -and
        @($externalRuntimePlan.PackageLocks).Count -gt 0 -and
        $externalRuntimePlan.Verification.type -eq 'spExecuteExternalScript') `
    -Message (($externalRuntimeResult.Errors + $externalRuntimeResult.Warnings) -join '; ')

$samplePlanManifest = [ordered]@{
    name = 'sample-plan-check'
    instances = @([ordered]@{
        id='primary'; version='2022'; provider='docker'
        databases = @([ordered]@{
            name='AdventureWorks2022'
            sample=[ordered]@{ id='adventureworks-2022'; variant='full' }
        })
    })
}
$samplePlanResult = Test-SqlServerLabManifest -InputObject $samplePlanManifest
$samplePlan = @($samplePlanResult.Plan.Instances[0].Samples)[0]
Add-CheckResult `
    -Name 'Manifestpruefung liefert Sample- und Artifact-Planvorschau' `
    -Success ($samplePlanResult.IsValid -and
        $samplePlanResult.Plan.Contract.Version -eq '1.2' -and
        $samplePlan.Status -eq 'RESOLVED' -and
        $samplePlan.ArtifactType -eq 'backup' -and
        $samplePlan.Source -match '^https://' -and
        $samplePlan.License -and
        @($samplePlan.ExpectedOutputs).Count -eq 1 -and
        $samplePlan.IntegrityStatus -in @('catalog-sha256', 'trust-required') -and
        $samplePlan.InstallationKind -eq 'backup') `
    -Message (($samplePlanResult.Errors + $samplePlanResult.Warnings) -join '; ')

$wizardExternalRuntimeSelection = & $module {
    $originalChoice = (Get-Command Read-LabChoice).ScriptBlock
    $script:ExternalRuntimeChoiceCall = 0
    try {
        Set-Item Function:Read-LabChoice -Value {
            param([string[]]$Options)
            $script:ExternalRuntimeChoiceCall++
            if ($script:ExternalRuntimeChoiceCall -eq 1) { return 0 }
            return [array]::IndexOf($Options, 'Auswahl abschliessen')
        }
        Select-LabManifestExternalRuntimeReferences -InstanceDraft ([ordered]@{
            id='primary'; version='2022'; provider='podman'; os='linux'
        }) -Path 'manifest.instances[1].software'
    }
    finally {
        Set-Item Function:Read-LabChoice -Value $originalChoice
        Remove-Variable ExternalRuntimeChoiceCall -Scope Script -ErrorAction SilentlyContinue
    }
}
Add-CheckResult `
    -Name 'Manifest-Wizard schreibt nur die exakt resolverfreigegebene Katalogvariante' `
    -Success (@($wizardExternalRuntimeSelection).Count -eq 1 -and
        [string]$wizardExternalRuntimeSelection[0].id -in @('sql-python', 'sql-r', 'sql-java') -and
        [string]$wizardExternalRuntimeSelection[0].variant -match '^sql2022-' -and
        [string]$wizardExternalRuntimeSelection[0].scope -eq 'sqlExternalRuntime' -and
        [string]$wizardExternalRuntimeSelection[0].installMethod -eq 'catalog' -and
        $wizardExternalRuntimeSelection[0].optional -eq $false)

$automatedManifest = [ordered]@{
    name = 'automated-manifest-check'
    automation = [ordered]@{
        mode = 'unattended'
        secrets = [ordered]@{ saPassword = 'SQL_SERVER_LAB_SECRET_SA_PASSWORD' }
    }
    instances = @(
        [ordered]@{ id = 'primary'; version = '2025'; provider = 'docker' }
    )
}
$automatedManifestResult = Test-SqlServerLabManifest -InputObject $automatedManifest
Add-CheckResult `
    -Name 'Automationsmanifest referenziert nur eine eng benannte externe Secret-Variable' `
    -Success $automatedManifestResult.IsValid `
    -Message ($automatedManifestResult.Errors -join '; ')

$plainSecretManifest = [ordered]@{
    name = 'plain-secret-rejected'
    automation = [ordered]@{
        secrets = [ordered]@{ saPassword = 'NotASecretEnvironmentVariable' }
    }
    instances = @(
        [ordered]@{ id = 'primary'; version = '2025'; provider = 'docker' }
    )
}
$plainSecretManifestResult = Test-SqlServerLabManifest -InputObject $plainSecretManifest
Add-CheckResult `
    -Name 'Manifest lehnt Klartext-Secretwerte ab' `
    -Success (-not $plainSecretManifestResult.IsValid -and $plainSecretManifestResult.Errors -match 'Schema:') `
    -Message ($plainSecretManifestResult.Errors -join '; ')

$unsafeHostWriteManifest = [ordered]@{
    name = 'unsafe-host-write-rejected'
    instances = @(
        [ordered]@{
            id = 'primary'; version = '2025'; provider = 'docker'
            drives = @([ordered]@{ id = 'external'; containerPath = '/external'; hostPath = 'C:\\external'; accessMode = 'readWrite' })
        }
    )
}
$unsafeHostWriteManifestResult = Test-SqlServerLabManifest -InputObject $unsafeHostWriteManifest
Add-CheckResult `
    -Name 'Schreibende beliebige Host-Mounts werden ohne Expertenfreigabe abgelehnt' `
    -Success (-not $unsafeHostWriteManifestResult.IsValid -and $unsafeHostWriteManifestResult.Errors -match 'expertActions.hostWriteMounts') `
    -Message ($unsafeHostWriteManifestResult.Errors -join '; ')

$explicitHostWriteManifest = [ordered]@{
    name = 'explicit-host-write-expert'
    expertActions = [ordered]@{ hostWriteMounts = $true }
    instances = @(
        [ordered]@{
            id = 'primary'; version = '2025'; provider = 'docker'
            drives = @([ordered]@{ id = 'external'; containerPath = '/external'; hostPath = 'C:\\external'; accessMode = 'readWrite' })
        }
    )
}
$explicitHostWriteManifestResult = Test-SqlServerLabManifest -InputObject $explicitHostWriteManifest
$dockerProviderSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1') -Raw -Encoding utf8
$podmanProviderSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1') -Raw -Encoding utf8
$mountProjection = & $module {
    $manifest = [PSCustomObject]@{
        name = 'mount-projection'
        instances = @([PSCustomObject]@{
            id = 'primary'; version = '2025'; provider = 'docker'; os = 'linux'; profile = 'standard'; collation = $null
            databases = @(); software = @(); postProvision = @(); serverConfig = $null; hyperv = $null
            drives = @(
                [PSCustomObject]@{ id = 'host'; containerPath = '/reference'; hostPath = 'reference'; accessMode = $null; sizeLimitGB = $null; type = 'auto' },
                [PSCustomObject]@{ id = 'volume'; containerPath = '/data'; hostPath = $null; accessMode = $null; sizeLimitGB = $null; type = 'auto' }
            )
        })
        persistentData = $null; resourceOverrides = $null; automation = $null; expertActions = $null
    }
    (Resolve-ManifestDefaults -Manifest $manifest -ManifestPath (Join-Path $PWD 'in-memory.json')).instances[0].drives
}
Add-CheckResult `
    -Name 'Host-Mounts sind standardmäßig read-only und Containerprovider geben den Modus weiter' `
    -Success ($explicitHostWriteManifestResult.IsValid -and
        $dockerProviderSource -match '\$drive\.hostPath -and \$drive\.readOnly -eq \$true' -and $dockerProviderSource -match '\$\{volumeTarget\}:ro' -and
        $podmanProviderSource -match '\$drive\.readOnly -eq \$true' -and
        $podmanProviderSource -match "\$volumeOptions \+= 'ro'" -and $podmanProviderSource -match '\$volumeOptions -join' -and
        @($mountProjection | Where-Object id -eq 'host')[0].readOnly -and
        -not @($mountProjection | Where-Object id -eq 'volume')[0].readOnly) `
    -Message (($explicitHostWriteManifestResult.Errors + $explicitHostWriteManifestResult.Warnings) -join '; ')

$remoteRestoreWithoutHash = [ordered]@{
    name = 'remote-restore-warning'
    instances = @(
        [ordered]@{
            id = 'primary'; version = '2025'; provider = 'docker'
            databases = @([ordered]@{ name = 'Demo'; restore = [ordered]@{ source = 'https://example.invalid/Demo.bak' } })
        }
    )
}
$remoteRestoreWithoutHashResult = Test-SqlServerLabManifest -InputObject $remoteRestoreWithoutHash
Add-CheckResult `
    -Name 'Ungehashter Remote-Restore wird vor unbeaufsichtigter Ausführung sichtbar gewarnt' `
    -Success ($remoteRestoreWithoutHashResult.IsValid -and $remoteRestoreWithoutHashResult.Warnings -match 'TRUST_REQUIRED') `
    -Message (($remoteRestoreWithoutHashResult.Errors + $remoteRestoreWithoutHashResult.Warnings) -join '; ')

$environmentSecretResult = $null
try {
    [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_SECRET_MANIFEST_TEST', 'Manifest_Automation_42!', 'Process')
    $environmentSecretResult = & $module {
        $secret = Get-LabManifestEnvironmentSecret -Name 'SQL_SERVER_LAB_SECRET_MANIFEST_TEST'
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
        try { Test-SaPasswordComplexity -Password ([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}
finally {
    [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_SECRET_MANIFEST_TEST', $null, 'Process')
}
Add-CheckResult `
    -Name 'Extern bereitgestelltes Manifest-Secret wird als SecureString verarbeitet' `
    -Success ($environmentSecretResult -and $environmentSecretResult.Valid) `
    -Message $(if ($environmentSecretResult) { $environmentSecretResult.Reasons -join '; ' } else { 'Secret konnte nicht aufgelöst werden.' })

$unknownField = [ordered]@{
    name      = 'unknown-field'
    instances = @(
        [ordered]@{
            id       = 'primary'
            version  = '2025'
            provider = 'docker'
            unknown  = $true
        }
    )
}
$unknownResult = Test-SqlServerLabManifest -InputObject $unknownField
Add-CheckResult `
    -Name 'Unbekannte Felder werden vom Schema abgelehnt' `
    -Success (-not $unknownResult.IsValid -and $unknownResult.Errors -match 'Schema:') `
    -Message ($unknownResult.Errors -join '; ')

$duplicateIds = [ordered]@{
    name      = 'duplicate-ids'
    instances = @(
        [ordered]@{ id = 'primary'; version = '2025'; provider = 'docker' },
        [ordered]@{ id = 'primary'; version = '2025'; provider = 'docker' }
    )
}
$duplicateResult = Test-SqlServerLabManifest -InputObject $duplicateIds
Add-CheckResult `
    -Name 'Doppelte Instanz-IDs werden abgelehnt' `
    -Success (-not $duplicateResult.IsValid -and $duplicateResult.Errors -match 'nicht eindeutig') `
    -Message ($duplicateResult.Errors -join '; ')

$mixedProviders = [ordered]@{
    name      = 'mixed-providers'
    instances = @(
        [ordered]@{ id = 'docker'; version = '2025'; provider = 'docker' },
        [ordered]@{ id = 'podman'; version = '2025'; provider = 'podman' }
    )
}
$mixedResult = Test-SqlServerLabManifest -InputObject $mixedProviders
Add-CheckResult `
    -Name 'Gemischte Docker-/Podman-Provider werden akzeptiert' `
    -Success $mixedResult.IsValid `
    -Message ($mixedResult.Errors -join '; ')

$hyperVManifest = [ordered]@{
    name = 'hyperv-manifest-check'
    persistentData = [ordered]@{ enabled = $true; dataDiskGB = 128 }
    instances = @(
        [ordered]@{
            id = 'primary'; version = '2025'; provider = 'hyperv'; os = 'windows'
            hyperv = [ordered]@{ preparedImageId = ('hyperv-sql-prepared-sealed-' + ('a' * 64)); dynamicMemoryEnabled = $true; memoryMinimumMB = 1024; memoryStartupMB = 4096; memoryMaximumMB = 8192; processorCount = 4; autostart = 'on'; guestPasswordMode = 'generated' }
        }
    )
}
$hyperVManifestResult = Test-SqlServerLabManifest -InputObject $hyperVManifest
Add-CheckResult `
    -Name 'Hyper-V-Manifest referenziert ein Prepared-Image ohne Klartextpasswort' `
    -Success $hyperVManifestResult.IsValid `
    -Message ($hyperVManifestResult.Errors -join '; ')
Add-CheckResult `
    -Name 'Hyper-V-Manifest plant standardmaessig HostOnly mit internem Switch' `
    -Success ($hyperVManifestResult.Plan.Instances[0].Network.Status -eq 'RESOLVED' -and
        $hyperVManifestResult.Plan.Instances[0].Network.Intent -eq 'hostOnly' -and
        $hyperVManifestResult.Plan.Instances[0].Network.Binding -eq 'internal-switch')

$resolvedHyperVResources = & $module {
    param($Manifest)
    $resolved = Resolve-ManifestDefaults -Manifest $Manifest -ManifestPath (Join-Path $PWD 'in-memory-hyperv-resources.json')
    (New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode manifest -PersistentData $false).Instances[0].Intents.Resources
} $hyperVManifest
Add-CheckResult `
    -Name 'Hyper-V-Manifest bindet dynamisches Min-/Startup-/Max-RAM und vCPU portabel' `
    -Success ($resolvedHyperVResources.Contract.Name -eq 'SqlServerLab.HyperVResourceIntent' -and
        $resolvedHyperVResources.DynamicMemoryEnabled -and $resolvedHyperVResources.MemoryMinimumMB -eq 1024 -and
        $resolvedHyperVResources.MemoryStartupMB -eq 4096 -and $resolvedHyperVResources.MemoryMaximumMB -eq 8192 -and
        $resolvedHyperVResources.ProcessorCount -eq 4)

$invalidHyperVRange = $hyperVManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$invalidHyperVRange.instances[0].hyperv.memoryMinimumMB = 6144
$invalidHyperVRangeResult = Test-SqlServerLabManifest -InputObject $invalidHyperVRange
Add-CheckResult `
    -Name 'Hyper-V-Manifest lehnt eine ungueltige dynamische RAM-Reihenfolge ab' `
    -Success (-not $invalidHyperVRangeResult.IsValid -and $invalidHyperVRangeResult.Errors -match 'memoryMinimumMB <= memoryStartupMB <= memoryMaximumMB') `
    -Message ($invalidHyperVRangeResult.Errors -join '; ')

$invalidHyperVStatic = $hyperVManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$invalidHyperVStatic.instances[0].hyperv.dynamicMemoryEnabled = $false
$invalidHyperVStaticResult = Test-SqlServerLabManifest -InputObject $invalidHyperVStatic
Add-CheckResult `
    -Name 'Statisches Hyper-V-RAM verbietet abweichende Min-/Max-Werte' `
    -Success (-not $invalidHyperVStaticResult.IsValid -and $invalidHyperVStaticResult.Errors -match 'Statisches RAM') `
    -Message ($invalidHyperVStaticResult.Errors -join '; ')

$hyperVIsolatedManifest = $hyperVManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$hyperVIsolatedManifest.instances[0] | Add-Member -NotePropertyName network -NotePropertyValue ([PSCustomObject]@{ intent='isolated'; exposure='none' }) -Force
$hyperVIsolatedResult = Test-SqlServerLabManifest -InputObject $hyperVIsolatedManifest
$resolvedHyperVIsolated = & $module {
    param($Manifest)
    (Resolve-ManifestDefaults -Manifest $Manifest -ManifestPath (Join-Path $PWD 'in-memory-hyperv-isolated.json')).instances[0].network
} $hyperVIsolatedManifest
Add-CheckResult `
    -Name 'Hyper-V-Isolated-Intent wird validiert und portabel aufgeloest' `
    -Success ($hyperVIsolatedResult.IsValid -and $resolvedHyperVIsolated.Intent -eq 'isolated' -and
        $resolvedHyperVIsolated.Exposure -eq 'none' -and $resolvedHyperVIsolated.Binding -eq 'private-switch') `
    -Message ($hyperVIsolatedResult.Errors -join '; ')

$hyperVNatManifest = $hyperVManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$hyperVNatManifest.instances[0] | Add-Member -NotePropertyName network -NotePropertyValue ([PSCustomObject]@{ intent='nat'; exposure='host' }) -Force
$hyperVNatResult = Test-SqlServerLabManifest -InputObject $hyperVNatManifest
Add-CheckResult `
    -Name 'Hyper-V-NAT wird portabel auf das gemeinsame interne WinNAT gebunden' `
    -Success ($hyperVNatResult.IsValid -and $hyperVNatResult.Plan.Instances[0].Network.Status -eq 'RESOLVED' -and `
        $hyperVNatResult.Plan.Instances[0].Network.Binding -eq 'shared-internal-nat') `
    -Message ($hyperVNatResult.Errors -join '; ')

$hyperVLanManifest = $hyperVManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$hyperVLanManifest.instances[0] | Add-Member -NotePropertyName network -NotePropertyValue ([PSCustomObject]@{ intent='lan'; exposure='lan' }) -Force
$hyperVLanResult = Test-SqlServerLabManifest -InputObject $hyperVLanManifest
Add-CheckResult `
    -Name 'Hyper-V-LAN bleibt portabel und verlangt erst zur Laufzeit die lokale External-Switch-Bindung' `
    -Success ($hyperVLanResult.IsValid -and $hyperVLanResult.Plan.Instances[0].Network.Status -eq 'RESOLVED' -and `
        $hyperVLanResult.Plan.Instances[0].Network.Binding -eq 'external-switch' -and `
        $hyperVLanResult.Plan.Instances[0].Network.RequiredCapability -eq 'external-network-binding') `
    -Message ($hyperVLanResult.Errors -join '; ')

$hyperVLegacyConflictManifest = $hyperVIsolatedManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$hyperVLegacyConflictManifest.instances[0].hyperv | Add-Member -NotePropertyName switchName -NotePropertyValue 'SQL_LAB_HYPERV' -Force
$hyperVLegacyConflictResult = Test-SqlServerLabManifest -InputObject $hyperVLegacyConflictManifest
Add-CheckResult `
    -Name 'Legacy-Hyper-V-Switch und Isolated-Intent werden nicht stillschweigend vermischt' `
    -Success (-not $hyperVLegacyConflictResult.IsValid -and $hyperVLegacyConflictResult.Errors -match 'NETWORK_LEGACY_SWITCH_CONFLICT') `
    -Message ($hyperVLegacyConflictResult.Errors -join '; ')

$hyperVExposureConflictManifest = $hyperVIsolatedManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$hyperVExposureConflictManifest.instances[0].network.exposure = 'host'
$hyperVExposureConflictResult = Test-SqlServerLabManifest -InputObject $hyperVExposureConflictManifest
Add-CheckResult `
    -Name 'Widerspruechliche Network-Exposure scheitert vor Provider-Mutation' `
    -Success (-not $hyperVExposureConflictResult.IsValid -and $hyperVExposureConflictResult.Errors -match 'NETWORK_EXPOSURE_CONFLICT') `
    -Message ($hyperVExposureConflictResult.Errors -join '; ')

$resolvedHyperVAutoStart = & $module {
    param($Manifest)
    (Resolve-ManifestDefaults -Manifest $Manifest -ManifestPath (Join-Path $PWD 'in-memory-hyperv.json')).instances[0].hyperv.autostart
} $hyperVManifest
Add-CheckResult `
    -Name 'Hyper-V-Manifest reicht autostart=on in den aufgelösten Vertrag weiter' `
    -Success ($resolvedHyperVAutoStart -eq 'on')

$invalidHyperVAutoStart = $hyperVManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$invalidHyperVAutoStart.instances[0].hyperv.autostart = 'always'
$invalidHyperVAutoStartResult = Test-SqlServerLabManifest -InputObject $invalidHyperVAutoStart
Add-CheckResult `
    -Name 'Hyper-V-Manifest lehnt unbekannte Autostart-Werte ab' `
    -Success (-not $invalidHyperVAutoStartResult.IsValid -and $invalidHyperVAutoStartResult.Errors -match 'autostart') `
    -Message ($invalidHyperVAutoStartResult.Errors -join '; ')

$hyperVFallbackManifest = $hyperVManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$hyperVFallbackManifest.instances[0].PSObject.Properties.Remove('hyperv')
$hyperVFallbackResult = Test-SqlServerLabManifest -InputObject $hyperVFallbackManifest
Add-CheckResult `
    -Name 'Hyper-V-Manifest ohne explizites Image aktiviert den sicheren lokalen Standard-Desktop-Fallback' `
    -Success ($hyperVFallbackResult.IsValid -and $hyperVFallbackResult.Warnings -match 'SQL_PREPARED_SEALED.*Standard Evaluation.*Desktop Experience') `
    -Message (($hyperVFallbackResult.Errors + $hyperVFallbackResult.Warnings) -join '; ')

$hyperVDriveManifest = $hyperVManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$hyperVDriveManifest.instances[0] | Add-Member -NotePropertyName drives -NotePropertyValue @(
    [PSCustomObject]@{ id = 'data'; containerPath = 'D:\SQLData'; sizeLimitGB = 64; type = 'ssd' },
    [PSCustomObject]@{ id = 'log'; containerPath = 'L:\SQLLog'; sizeLimitGB = 32; type = 'ssd' }
) -Force
$hyperVDriveResult = Test-SqlServerLabManifest -InputObject $hyperVDriveManifest
Add-CheckResult `
    -Name 'Hyper-V-Manifest bindet sichere run-lokale Zusatz-VHDX' `
    -Success $hyperVDriveResult.IsValid `
    -Message ($hyperVDriveResult.Errors -join '; ')

$hyperVUnsafeDriveManifest = $hyperVManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$hyperVUnsafeDriveManifest.instances[0] | Add-Member -NotePropertyName drives -NotePropertyValue @(
    [PSCustomObject]@{ id = 'unsafe'; containerPath = 'D:\Unsafe'; hostPath = 'C:\HostData'; type = 'tmpfs' }
) -Force
$hyperVUnsafeDriveResult = Test-SqlServerLabManifest -InputObject $hyperVUnsafeDriveManifest
Add-CheckResult `
    -Name 'Hyper-V-Manifest blockiert Host-Mount, tmpfs und fehlende VHDX-Groesse' `
    -Success (-not $hyperVUnsafeDriveResult.IsValid -and @($hyperVUnsafeDriveResult.Errors | Where-Object { $_ -match 'hostPath|tmpfs|sizeLimitGB' }).Count -ge 3) `
    -Message ($hyperVUnsafeDriveResult.Errors -join '; ')

$hyperVWindowsManifest = [ordered]@{
    name = 'hyperv-manifest-windows-check'
    persistentData = [ordered]@{ enabled = $true; dataDiskGB = 128 }
    instances = @(
        [ordered]@{
            id = 'primary'; version = '2025'; provider = 'hyperv'; os = 'windows'
            hyperv = [ordered]@{ preparedImageId = ('hyperv-os-sealed-' + ('a' * 64)); memoryStartupMB = 4096; processorCount = 4; autostart = 'off'; guestPasswordMode = 'generated' }
        }
    )
}
$hyperVWindowsManifestResult = Test-SqlServerLabManifest -InputObject $hyperVWindowsManifest
Add-CheckResult `
    -Name 'Hyper-V-Manifest referenziert ein OS_SEALED-Image ohne Klartextpasswort' `
    -Success $hyperVWindowsManifestResult.IsValid `
    -Message ($hyperVWindowsManifestResult.Errors -join '; ')

$mixedHyperVManifest = [ordered]@{
    name = 'mixed-hyperv-container'
    instances = @(
        $hyperVManifest.instances[0],
        [ordered]@{ id = 'container'; version = '2025'; provider = 'docker' }
    )
}
$mixedHyperVManifestResult = Test-SqlServerLabManifest -InputObject $mixedHyperVManifest
Add-CheckResult `
    -Name 'Hyper-V-Manifest lehnt nicht atomare Mischläufe klar ab' `
    -Success (-not $mixedHyperVManifestResult.IsValid -and $mixedHyperVManifestResult.Errors -match 'genau eine Hyper-V-Instanz') `
    -Message ($mixedHyperVManifestResult.Errors -join '; ')

$incompatibleDatabase = [ordered]@{
    name      = 'compatibility-check'
    instances = @(
        [ordered]@{
            id        = 'primary'
            version   = '2019'
            provider  = 'docker'
            databases = @(
                [ordered]@{
                    name    = 'AppDB'
                    options = [ordered]@{ compatibility = 170 }
                }
            )
        }
    )
}
$compatibilityResult = Test-SqlServerLabManifest -InputObject $incompatibleDatabase
Add-CheckResult `
    -Name 'Zu hohes Compatibility Level wird abgelehnt' `
    -Success (-not $compatibilityResult.IsValid -and $compatibilityResult.Errors -match 'zu hoch') `
    -Message ($compatibilityResult.Errors -join '; ')

$reservedFieldValues = [ordered]@{
    collation          = 'SQL_Latin1_General_CP1_CS_AS'
    defaultPaths       = [ordered]@{ data = '/sqldata' }
    sqlAgent           = $true
    clrEnabled         = $true
    filestream         = $true
    containedDatabases = $true
    authMode           = 'mixed'
    errorLogRetention  = 12
    instantFileInit    = $true
}
$manifestSchema = Get-Content -LiteralPath (Join-Path $repoRoot 'Schemas/lab-manifest.schema.json') -Raw -Encoding utf8 |
    ConvertFrom-Json -Depth 100
$schemaReservedFields = @(
    $manifestSchema.definitions.serverConfig.properties.PSObject.Properties |
        Where-Object { $_.Value.'x-runtimeStatus' -eq 'reserved' } |
        Select-Object -ExpandProperty Name
)
$reservedCoverageMatchesSchema = @($reservedFieldValues.Keys).Count -eq $schemaReservedFields.Count -and
    @($reservedFieldValues.Keys | Where-Object { $_ -notin $schemaReservedFields }).Count -eq 0
$reservedFieldFailures = [System.Collections.Generic.List[string]]::new()
foreach ($reservedFieldName in $reservedFieldValues.Keys) {
    $reservedManifest = [ordered]@{
        name      = "reserved-$reservedFieldName"
        instances = @(
            [ordered]@{
                id = 'primary'; version = '2025'; provider = 'docker'
                serverConfig = [ordered]@{ $reservedFieldName = $reservedFieldValues[$reservedFieldName] }
            }
        )
    }
    $reservedResult = Test-SqlServerLabManifest -InputObject $reservedManifest
    if ($reservedResult.IsValid -or
        $reservedResult.Errors -notmatch 'MANIFEST_RESERVED_RUNTIME_FIELD' -or
        $reservedResult.Errors -notmatch "serverConfig\.$([regex]::Escape($reservedFieldName))") {
        $reservedFieldFailures.Add("${reservedFieldName}: $($reservedResult.Errors -join ', ')")
    }
}
Add-CheckResult `
    -Name 'Alle reservierten serverConfig-Felder werden schemaabgeleitet abgelehnt' `
    -Success ($reservedCoverageMatchesSchema -and $reservedFieldFailures.Count -eq 0) `
    -Message (($reservedFieldFailures + @($(if (-not $reservedCoverageMatchesSchema) { 'Testwerte und Schema-Klassifikation weichen ab.' }))) -join '; ')

foreach ($reservedExternalScriptsCase in @(
    [ordered]@{ Name = 'customImage'; Config = [ordered]@{ customImage = 'example.invalid/sql:reserved' }; Code = 'MANIFEST_RESERVED_RUNTIME_FIELD' },
    [ordered]@{ Name = 'installMethod=custom-image'; Config = [ordered]@{ installMethod = 'custom-image' }; Code = 'MANIFEST_RESERVED_RUNTIME_VALUE' },
    [ordered]@{ Name = 'installMethod=pre-built'; Config = [ordered]@{ installMethod = 'pre-built' }; Code = 'MANIFEST_RESERVED_RUNTIME_VALUE' }
)) {
    $reservedExternalScriptsManifest = [ordered]@{
        name = "reserved-external-scripts-$($reservedExternalScriptsCase.Name)"
        instances = @(
            [ordered]@{
                id = 'primary'; version = '2025'; provider = 'docker'
                serverConfig = [ordered]@{ externalScripts = $reservedExternalScriptsCase.Config }
            }
        )
    }
    $reservedExternalScriptsResult = Test-SqlServerLabManifest -InputObject $reservedExternalScriptsManifest
    Add-CheckResult `
        -Name "Reservierter External-Scripts-Vertrag wird abgelehnt: $($reservedExternalScriptsCase.Name)" `
        -Success (-not $reservedExternalScriptsResult.IsValid -and
            $reservedExternalScriptsResult.Errors -match $reservedExternalScriptsCase.Code) `
        -Message ($reservedExternalScriptsResult.Errors -join '; ')
}

$reservedReadDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-reserved-read-$([guid]::NewGuid().ToString('N'))"
$reservedReadPath = Join-Path $reservedReadDirectory 'reserved.json'
try {
    $null = New-Item -ItemType Directory -Path $reservedReadDirectory -Force
    $reservedReadManifest = [ordered]@{
        name = 'reserved-read'
        instances = @(
            [ordered]@{
                id = 'primary'; version = '2025'; provider = 'docker'
                serverConfig = [ordered]@{ sqlAgent = $true }
            }
        )
    }
    $reservedReadManifest | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $reservedReadPath -Encoding utf8
    $reservedReadError = $null
    try {
        & $module { param($ManifestPath) Read-LabManifest -Path $ManifestPath } $reservedReadPath
    }
    catch {
        $reservedReadError = $_.Exception.Message
    }
    Add-CheckResult `
        -Name 'Manifestparser stoppt reservierte Felder vor der Defaultaufloesung' `
        -Success ($reservedReadError -match 'Manifest-Fachvalidierung fehlgeschlagen' -and
            $reservedReadError -match 'MANIFEST_RESERVED_RUNTIME_FIELD') `
        -Message $reservedReadError
}
finally {
    Remove-Item -LiteralPath $reservedReadDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

$unsupportedSample = [ordered]@{
    name      = 'unsupported-sample'
    instances = @(
        [ordered]@{
            id        = 'primary'
            version   = '2022'
            provider  = 'docker'
            databases = @(
                [ordered]@{
                    name   = 'StackOverflow'
                    sample = [ordered]@{ id = 'stackoverflow-50gb'; variant = '10gb' }
                }
            )
        }
    )
}
$sampleResult = Test-SqlServerLabManifest -InputObject $unsupportedSample
Add-CheckResult `
    -Name 'Nicht provisionierbare Samplevarianten werden abgelehnt' `
    -Success (-not $sampleResult.IsValid -and $sampleResult.Errors -match 'beschreibend katalogisiert') `
    -Message ($sampleResult.Errors -join '; ')

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-manifest-check-$([guid]::NewGuid().ToString('N'))"
$temporaryManifest = Join-Path $temporaryDirectory 'generated.json'
try {
    $null = New-Item -ItemType Directory -Path $temporaryDirectory -Force
    $saved = New-SqlServerLabManifest `
        -Path $temporaryManifest `
        -InputObject $minimal `
        -PassThru
    $roundTrip = Test-SqlServerLabManifest -Path $temporaryManifest

    Add-CheckResult `
        -Name 'Nichtinteraktiver Entwurf wird atomar gespeichert und erneut validiert' `
        -Success ((Test-Path -LiteralPath $temporaryManifest -PathType Leaf) -and
            $saved.name -eq $minimal.name -and
            $roundTrip.IsValid) `
        -Message ($roundTrip.Errors -join '; ')
}
finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`nMANIFEST BUILDER CHECKS: FAIL ($passed bestanden, $($failures.Count) fehlgeschlagen)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host "`nMANIFEST BUILDER CHECKS: PASS ($passed Pruefungen)" -ForegroundColor Green
exit 0



