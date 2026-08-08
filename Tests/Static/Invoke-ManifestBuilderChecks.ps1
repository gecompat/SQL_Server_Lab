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
    $originalConfirm = (Get-Command Read-LabConfirm).ScriptBlock
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
        Set-Item Function:Read-LabConfirm -Value { param() return $false }
        New-LabManifestDraft -SchemaReference './Schemas/lab-manifest.schema.json'
    }
    finally {
        Set-Item Function:Read-LabString -Value $originalString
        Set-Item Function:Read-LabConfirm -Value $originalConfirm
    }
}
$wizardResult = Test-SqlServerLabManifest -InputObject $wizardDraft
Add-CheckResult `
    -Name 'Schema-Wizard bewahrt eine einzelne Instanz als Array' `
    -Success ($wizardDraft.instances -is [array] -and
        $wizardDraft.instances.Count -eq 1 -and
        $wizardResult.IsValid) `
    -Message ($wizardResult.Errors -join '; ')

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
        $podmanProviderSource -match '\$drive\.hostPath -and \$drive\.readOnly -eq \$true' -and $podmanProviderSource -match '\$\{volumeTarget\}:ro' -and
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
            hyperv = [ordered]@{ preparedImageId = ('hyperv-sql-prepared-sealed-' + ('a' * 64)); memoryStartupMB = 4096; processorCount = 4; guestPasswordMode = 'generated' }
        }
    )
}
$hyperVManifestResult = Test-SqlServerLabManifest -InputObject $hyperVManifest
Add-CheckResult `
    -Name 'Hyper-V-Manifest referenziert ein Prepared-Image ohne Klartextpasswort' `
    -Success $hyperVManifestResult.IsValid `
    -Message ($hyperVManifestResult.Errors -join '; ')

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

$preparedField = [ordered]@{
    name      = 'prepared-field'
    instances = @(
        [ordered]@{
            id           = 'primary'
            version      = '2025'
            provider     = 'docker'
            serverConfig = [ordered]@{ sqlAgent = $true }
        }
    )
}
$preparedResult = Test-SqlServerLabManifest -InputObject $preparedField
Add-CheckResult `
    -Name 'Vorbereitete Runtimefelder erzeugen Warnungen' `
    -Success ($preparedResult.IsValid -and $preparedResult.Warnings -match 'noch nicht zuverlaessig') `
    -Message (($preparedResult.Errors + $preparedResult.Warnings) -join '; ')

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



