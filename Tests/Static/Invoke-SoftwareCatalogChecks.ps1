#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Softwarekatalog, External-Runtime-Resolver und sichere Legacy-Grenze.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Software Catalog Checks' -ForegroundColor Cyan

$catalogPath = Join-Path $repoRoot 'Catalogs/software.json'
$schemaPath = Join-Path $repoRoot 'Schemas/software-catalog.schema.json'
$catalogValid = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 |
    Test-Json -SchemaFile $schemaPath -ErrorAction Stop
Add-CheckResult -Name 'Softwarekatalog entspricht dem versionierten JSON-Schema' -Success $catalogValid

$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
$softwareIds = @($catalog.software | ForEach-Object { [string]$_.id })
$variants = @($catalog.software | ForEach-Object { @($_.variants) })
Add-CheckResult -Name 'Python, R und Java besitzen eindeutige Katalog-IDs und Varianten' -Success (
    (@($softwareIds | Sort-Object) -join ',') -eq 'sql-java,sql-python,sql-r' -and
    @($softwareIds | Sort-Object -Unique).Count -eq $softwareIds.Count -and
    @($variants.id | Sort-Object -Unique).Count -eq $variants.Count
)

$invalidSupportedVariants = @($variants | Where-Object {
    [string]$_.status -eq 'SUPPORTED' -and
    (@($_.artifacts).Count -eq 0 -or @($_.artifacts | Where-Object {
        -not $_.version -or [string]$_.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or -not $_.integrityOrigin
    }).Count -gt 0)
})
Add-CheckResult -Name 'SUPPORTED erfordert versionierte Artefakte mit SHA-256 und Herkunft' -Success ($invalidSupportedVariants.Count -eq 0)

$javaLinux = @($variants | Where-Object { [string]$_.id -eq 'sql2022-java11-ubuntu2204-derived' })[0]
Add-CheckResult -Name 'Java katalogisiert SDK und synthetisches Probe-JAR als reproduzierbar erzeugte Artefakte' -Success (
    @($javaLinux.artifacts | Where-Object {
        [string]$_.sourceType -eq 'generated' -and [string]$_.id -in @('mssql-java-lang-extension-linux', 'sql-server-lab-java-probe')
    }).Count -eq 2
)

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -ErrorAction Stop
$module = Get-Module SqlServerLab

$result = & $module {
    $legacyConfig = [PSCustomObject]@{
        enabled = $true
        installMethod = 'post-start'
        languages = @([PSCustomObject]@{ name = 'Python'; packages = @() })
    }
    $legacyRequest = @(ConvertTo-LabExternalRuntimeRequests -Software @() -ExternalScripts $legacyConfig)[0]
    $legacyPlan = Resolve-LabExternalRuntimePlan -SoftwareItem $legacyRequest -SqlVersion '2022' -Provider docker -OperatingSystem linux

    $catalogRequest = [PSCustomObject]@{
        Id = 'sql-python'; Version = $null; Variant = $null; Scope = 'sqlExternalRuntime'
        InstallMethod = 'catalog'; Optional = $false; Packages = @(); RequestSource = 'software'
    }
    $supportedPlan = Resolve-LabExternalRuntimePlan -SoftwareItem $catalogRequest -SqlVersion '2022' -Provider podman -OperatingSystem linux
    $sql2025Plan = Resolve-LabExternalRuntimePlan -SoftwareItem $catalogRequest -SqlVersion '2025' -Provider docker -OperatingSystem linux

    $packageRequest = [PSCustomObject]@{
        Id = 'sql-python'; Version = $null; Variant = $null; Scope = 'sqlExternalRuntime'
        InstallMethod = 'catalog'; Optional = $false
        Packages = @([PSCustomObject]@{ Name = 'pandas'; Version = '1.5.3'; Scope = 'instance' })
        RequestSource = 'software'
    }
    $packagePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $packageRequest -SqlVersion '2022' -Provider docker -OperatingSystem linux

    $javaRequest = [PSCustomObject]@{
        Id = 'sql-java'; Version = '17'; Variant = $null; Scope = 'sqlExternalRuntime'
        InstallMethod = 'catalog'; Optional = $false; Packages = @(); RequestSource = 'software'
    }
    $javaPlan = Resolve-LabExternalRuntimePlan -SoftwareItem $javaRequest -SqlVersion '2022' -Provider hyperv -OperatingSystem windows
    $dockerOptions = @(Get-LabExternalRuntimeSelectionOptions -SqlVersion '2022' -Provider docker -OperatingSystem linux)
    $sql2025Options = @(Get-LabExternalRuntimeSelectionOptions -SqlVersion '2025' -Provider docker -OperatingSystem linux)
    $containerPreview = Get-LabExternalRuntimePlanPreview -DesiredPlans @($supportedPlan)
    $noOpPreview = Get-LabExternalRuntimePlanPreview -DesiredPlans @($supportedPlan) -CurrentPlans @($supportedPlan)
    $windowsPreview = Get-LabExternalRuntimePlanPreview -DesiredPlans @($javaPlan)
    $receipt = New-LabSoftwareInstallationReceipt -Plan $supportedPlan -Postconditions @(
        [PSCustomObject]@{ Type='synthetic'; Status='PASS' }
    )

    $duplicateRejected = $false
    try {
        $null = ConvertTo-LabExternalRuntimeRequests -Software @([PSCustomObject]@{
            id = 'sql-python'; scope = 'sqlExternalRuntime'; optional = $false
        }) -ExternalScripts $legacyConfig
    }
    catch { $duplicateRejected = $_.Exception.Message -match 'EXTERNAL_RUNTIME_REQUEST_DUPLICATE' }

    $receiptRejected = $false
    try { $null = New-LabSoftwareInstallationReceipt -Plan $sql2025Plan -Postconditions @() }
    catch { $receiptRejected = $_.Exception.Message -match 'SOFTWARE_RECEIPT_REQUIRES_RESOLVED_PLAN' }

    $resolved = [PSCustomObject]@{
        name = 'Software intent check'
        instances = @([PSCustomObject]@{
            id = 'sql'; provider = 'docker'; os = 'linux'; version = '2022'; profile = 'standard'; autostart = 'off'
            databases = @(); drives = @(); networkName = $null; hyperv = $null; serverConfig = $null
            software = @([PSCustomObject]@{
                id = 'sql-python'; version = $null; variant = $null; scope = 'sqlExternalRuntime'
                installMethod = 'catalog'; packages = @(); optional = $false; requestSource = 'software'
            })
        })
    }
    $snapshot = New-LabDesiredStateSnapshot -ResolvedLab $resolved -ProvisioningMode manifest -PersistentData $false
    $softwareIntent = $snapshot.Instances[0].Intents.Software
    $serialized = $snapshot | ConvertTo-Json -Depth 30

    $legacyManifest = [PSCustomObject]@{
        name = 'legacy-normalization'
        instances = @([PSCustomObject]@{
            id = 'sql'; version = '2022'; provider = 'docker'; os = 'linux'; profile = 'standard'
            databases = @(); drives = @(); software = @(); postProvision = @(); hyperv = $null
            serverConfig = [PSCustomObject]@{ externalScripts = $legacyConfig }
        })
    }
    $normalizedLegacy = (Resolve-ManifestDefaults -Manifest $legacyManifest -ManifestPath (Join-Path $PWD 'legacy.json')).instances[0].software[0]

    [PSCustomObject]@{
        Legacy = $legacyRequest.RequestSource -eq 'externalScripts-legacy' -and
            $legacyPlan.Status -eq 'NON_REPRODUCIBLE' -and
            $legacyPlan.ReasonCode -eq 'LEGACY_POST_START_MUTATION'
        Supported = $supportedPlan.Status -eq 'RESOLVED' -and
            -not $supportedPlan.ReasonCode -and
            $supportedPlan.VariantId -eq 'sql2022-python310-ubuntu2204-derived' -and
            $supportedPlan.RecipeVersion -eq '5'
        Sql2025 = $sql2025Plan.Status -eq 'DECLARED_UNSUPPORTED' -and
            $sql2025Plan.ReasonCode -eq 'RUNTIME_COMBINATION_NOT_CATALOGUED'
        PackageLock = $packagePlan.ReasonCode -eq 'PACKAGE_NOT_LOCKED'
        HyperVJava = $javaPlan.Status -eq 'RESOLVED' -and -not $javaPlan.ReasonCode -and
            $javaPlan.VariantId -eq 'sql2022-java17-windows-hyperv'
        DuplicateRejected = $duplicateRejected
        ReceiptRejected = $receiptRejected
        Selection = $dockerOptions.Count -eq 3 -and
            (@($dockerOptions.SoftwareId | Sort-Object) -join ',') -eq 'sql-java,sql-python,sql-r' -and
            @($dockerOptions | Where-Object { [string]$_.PlanKey -notmatch '^[a-f0-9]{64}$' }).Count -eq 0 -and
            $sql2025Options.Count -eq 0
        PlanIdentity = [string]$supportedPlan.PlanKey -match '^[a-f0-9]{64}$' -and
            @($supportedPlan.PackageLocks).Count -gt 0 -and
            (($supportedPlan | ConvertTo-Json -Depth 30) -notmatch '(?i)https?://|Program Files|/usr/')
        ContainerPreview = $containerPreview.Entries.Count -eq 1 -and
            $containerPreview.Entries[0].BuildDerivedImage -and
            -not $containerPreview.Entries[0].GuestMutation -and
            $containerPreview.Entries[0].ChangeClassification.Artifact -eq 'rebuild' -and
            $containerPreview.Entries[0].ChangeClassification.Service -eq 'restart' -and
            $containerPreview.Entries[0].ChangeClassification.Activation -eq 'recreate' -and
            $containerPreview.Entries[0].Downtime -eq 'required' -and
            @($containerPreview.Entries[0].Downloads).Count -gt 0 -and
            @($containerPreview.Entries[0].PackageLocks).Count -gt 0 -and
            $containerPreview.Entries[0].Verification.type -eq 'spExecuteExternalScript'
        ChangePlanning = $noOpPreview.IsNoOp -and
            $noOpPreview.Entries[0].ChangeClassification.Highest -eq 'no-op' -and
            $windowsPreview.Entries[0].GuestMutation -and
            $windowsPreview.Entries[0].ChangeClassification.Activation -eq 'reprovision'
        ReceiptPlanBinding = $receipt.PlanKey -eq $supportedPlan.PlanKey -and
            $receipt.PlanContract.Name -eq 'SqlServerLab.SoftwarePlan' -and
            $receipt.ChangeClassification.Activation -eq 'recreate'
        Intent = $softwareIntent.RequiredCapability -eq 'software-catalog-planning' -and
            $softwareIntent.PlanningCapabilityStatus -eq 'DECLARED_SUPPORTED' -and
            $softwareIntent.CapabilityStatus -eq 'DECLARED_SUPPORTED' -and
            $softwareIntent.Items[0].Status -eq 'RESOLVED' -and
            -not $softwareIntent.Items[0].ReasonCode
        Sanitized = $serialized -notmatch '(?i)learn\.microsoft|sourceUrls|Program Files|/usr/|https://'
        ParserNormalization = $normalizedLegacy.id -eq 'sql-python' -and
            $normalizedLegacy.scope -eq 'sqlExternalRuntime' -and
            $normalizedLegacy.installMethod -eq 'legacy-post-start' -and
            $normalizedLegacy.requestSource -eq 'externalScripts-legacy'
    }
}

Add-CheckResult -Name 'Legacy-post-start bleibt vor jeder Mutation NON_REPRODUCIBLE' -Success $result.Legacy
Add-CheckResult -Name 'SQL-2022-Python wird fuer Podman deterministisch als freigegeben aufgeloest' -Success $result.Supported
Add-CheckResult -Name 'SQL Server 2025 erbt keine unbelegte SQL-2022-Runtimeannahme' -Success $result.Sql2025
Add-CheckResult -Name 'Nicht katalogisierte Zusatzpakete werden vor der Mutation abgelehnt' -Success $result.PackageLock
Add-CheckResult -Name 'Hyper-V/Windows-Java besitzt einen nativ belegten deterministischen Plan' -Success $result.HyperVJava
Add-CheckResult -Name 'Doppelte Legacy- und software-Anforderung wird abgelehnt' -Success $result.DuplicateRejected
Add-CheckResult -Name 'Installation Receipt erfordert einen RESOLVED-Plan' -Success $result.ReceiptRejected
Add-CheckResult -Name 'Wizard-Auswahl enthaelt nur resolverfreigegebene Varianten des Instanzkontexts' -Success $result.Selection
Add-CheckResult -Name 'Softwareplan bindet alle Package Locks und eine portable PlanKey-Identitaet' -Success $result.PlanIdentity
Add-CheckResult -Name 'Planvorschau nennt Downloads, Build, Restart, Recreate, Downtime, Locks und Verification' -Success $result.ContainerPreview
Add-CheckResult -Name 'Aenderungsplanung unterscheidet No-op und sichere Gast-Reprovisionierung' -Success $result.ChangePlanning
Add-CheckResult -Name 'Installation Receipt bindet denselben Softwareplan und Aenderungsweg' -Success $result.ReceiptPlanBinding
Add-CheckResult -Name 'Desired State bindet Planning-Capability und freigegebene Runtime getrennt' -Success $result.Intent
Add-CheckResult -Name 'Desired State persistiert keine Quellen- oder Gastpfade' -Success $result.Sanitized
Add-CheckResult -Name 'Manifestparser normalisiert Legacy-Sprachen in Software-Intents' -Success $result.ParserNormalization

$example = Get-Content -LiteralPath (Join-Path $repoRoot 'Schemas/example-lab.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
$example.instances[0] | Add-Member -NotePropertyName software -NotePropertyValue @([PSCustomObject]@{
    id = 'sql-python'; scope = 'sqlExternalRuntime'; optional = $false; command = 'python -c unsafe'
}) -Force
$unsafeJson = $example | ConvertTo-Json -Depth 50
$unsafeValid = $unsafeJson | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-manifest.schema.json') -ErrorAction SilentlyContinue
Add-CheckResult -Name 'External Runtimes verbieten freie command-Ausfuehrung im Manifest-Schema' -Success (-not $unsafeValid)

$serverConfigSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ServerConfig.ps1') -Raw -Encoding utf8
$newLabSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1') -Raw -Encoding utf8
$legacyInstallerSource = [regex]::Match(
    $serverConfigSource,
    '(?s)function Install-LabExternalLanguages\s*\{.*?(?=\r?\nfunction\s|\z)'
).Value
Add-CheckResult -Name 'Legacy-Installer bleibt nach Katalogpruefung mutationsfrei deaktiviert' -Success (
    $legacyInstallerSource -match 'Resolve-LabExternalRuntimePlan' -and
    $legacyInstallerSource -match 'EXTERNAL_RUNTIME_LEGACY_POST_START_DISABLED' -and
    $legacyInstallerSource -notmatch 'Resolve-LabContainerProvider|apt-get|&\s+\$runtime|mssql-conf|install\.packages|pip install'
)
Add-CheckResult -Name 'Provisionierung bindet SQL-Version und gespeicherten Provider an External Languages' -Success (
    $newLabSource -match '-SqlVersion\s+\$instance\.version' -and
    $newLabSource -match '-Provider\s+\$instance\.provider'
)

$legacyExampleResult = Test-SqlServerLabManifest -Path (Join-Path $repoRoot 'Schemas/example-ml-services.json')
Add-CheckResult -Name 'Legacy-ML-Beispiel wird vor Provisionierung sichtbar als nicht reproduzierbar abgelehnt' -Success (
    -not $legacyExampleResult.IsValid -and
    ($legacyExampleResult.Errors -join ' ') -match 'LEGACY_POST_START_MUTATION'
)

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "Software Catalog Checks: $passed PASS" -ForegroundColor Green
