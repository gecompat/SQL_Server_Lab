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
Add-CheckResult -Name 'External Runtimes und SqlPackage besitzen eindeutige Katalog-IDs und Varianten' -Success (
    (@($softwareIds | Sort-Object) -join ',') -eq 'sql-csharp,sql-java,sql-python,sql-r,sqlpackage' -and
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
$csharpWindows = @($variants | Where-Object { [string]$_.id -eq 'sql2019plus-dotnet8-windows-hyperv-source' })[0]
Add-CheckResult -Name 'C#/.NET 8 ist für SQL 2019 bis 2025 Windows explizit katalogisiert, aber ohne Native Evidence fail-closed' -Success (
    $csharpWindows.status -eq 'PREVIEW' -and $csharpWindows.language -eq 'CSharp' -and
    (@($csharpWindows.sqlMajorVersions) -join ',') -eq '15,16,17' -and
    $csharpWindows.operatingSystem -eq 'windows' -and (@($csharpWindows.providers) -join ',') -eq 'hyperv' -and
    $csharpWindows.artifacts[0].sha256 -eq '5eedb40bdc9b38d5b48f9e6fb0b94e76f805e8d855536a867c7ba670d6535bf1'
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
    $csharpPlan = Resolve-LabExternalRuntimePlan -SoftwareItem ([PSCustomObject]@{
        Id='sql-csharp'; Version=$null; Variant=$null; Scope='sqlExternalRuntime'; InstallMethod='catalog'
        Optional=$false; Packages=@(); RequestSource='software'
    }) -SqlVersion '2019' -Provider hyperv -OperatingSystem windows
    $generalRequest = [PSCustomObject]@{
        Id='sqlpackage'; Version='170.4.83.3'; Variant=$null; Scope='instance'; InstallMethod='catalog'
        Optional=$false; Packages=@(); RequestSource='software'
    }
    $generalPlan = Resolve-LabExternalRuntimePlan -SoftwareItem $generalRequest -SqlVersion '2022' -Provider docker -OperatingSystem linux
    $toolImagePlan = New-LabContainerToolImagePlan -Provider docker -SqlVersion '2022' -SoftwarePlans @($generalPlan)
    $nullFreeInputPlan = @(Resolve-LabSoftwarePlansForInstance -Instance ([PSCustomObject]@{
        version='2022'; provider='docker'; os='linux'; serverConfig=$null
        software=@([PSCustomObject]@{ id='sqlpackage'; scope='instance'; source=$null; package=$null; url=$null; command=$null })
    }))[0]
    $freeInputPlan = @(Resolve-LabSoftwarePlansForInstance -Instance ([PSCustomObject]@{
        version='2022'; provider='docker'; os='linux'; serverConfig=$null
        software=@([PSCustomObject]@{ id='sqlpackage'; scope='instance'; source='https://invalid.example/sqlpackage'; package=$null; url=$null; command=$null })
    }))[0]
    $dockerRuntimePlan = Resolve-LabExternalRuntimePlan -SoftwareItem ([PSCustomObject]@{
        Id = 'sql-python'; Version = $null; Variant = $null; Scope = 'sqlExternalRuntime'
        InstallMethod = 'catalog'; Optional = $false; Packages = @(); RequestSource = 'software'
    }) -SqlVersion '2022' -Provider docker -OperatingSystem linux
    $externalRuntimeImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion '2022' -SoftwarePlans @($dockerRuntimePlan)
    $combinedToolRuntimeImagePlan = New-LabContainerToolExternalRuntimeImagePlan `
        -ExternalRuntimeImagePlan $externalRuntimeImagePlan -ContainerToolImagePlan $toolImagePlan

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
    $podmanOptions = @(Get-LabExternalRuntimeSelectionOptions -SqlVersion '2022' -Provider podman -OperatingSystem linux)
    $sql2025Options = @(Get-LabExternalRuntimeSelectionOptions -SqlVersion '2025' -Provider docker -OperatingSystem linux)
    $sql2019Options = @(Get-LabExternalRuntimeSelectionOptions -SqlVersion '2019' -Provider docker -OperatingSystem linux)
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
    $unresolvedPlan = $sql2025Plan | Select-Object *
    $unresolvedPlan.Status = 'DECLARED_UNSUPPORTED'
    try { $null = New-LabSoftwareInstallationReceipt -Plan $unresolvedPlan -Postconditions @() }
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
            $supportedPlan.RecipeVersion -eq '6'
        Sql2025 = $sql2025Plan.Status -eq 'RESOLVED' -and
            $sql2025Plan.RecipeVersion -eq '6'
        CSharp = $csharpPlan.Status -eq 'DECLARED_UNSUPPORTED' -and $csharpPlan.ReasonCode -eq 'VARIANT_PREVIEW' -and
            $csharpPlan.Language -eq 'CSharp'
        GeneralSoftware = $generalPlan.Kind -eq 'generalSoftware' -and
            $generalPlan.Status -eq 'RESOLVED' -and
            $generalPlan.RuntimeVersion -eq '170.4.83.3' -and
            @($generalPlan.ArtifactRefs).Count -eq 2 -and
            [string]$toolImagePlan.Contract.Name -eq 'SqlServerLab.ContainerToolImagePlan' -and
            [string]$toolImagePlan.ImageKey -match '^[a-f0-9]{64}$' -and
            [string]$toolImagePlan.SqlPackageArchiveSha256 -eq 'e81ede2429f3a15d9e752845c8928569c7706b3a911fad2d1717c0f03e0fc7c3'
        GeneralSoftwareNullInput = $nullFreeInputPlan.Status -eq 'RESOLVED' -and
            $freeInputPlan.Status -eq 'DECLARED_UNSUPPORTED' -and
            $freeInputPlan.ReasonCode -eq 'GENERAL_SOFTWARE_FREE_INPUT_FORBIDDEN'
        CombinedContainerImage = [string]$combinedToolRuntimeImagePlan.Contract.Name -eq 'SqlServerLab.ContainerToolExternalRuntimeImagePlan' -and
            [string]$combinedToolRuntimeImagePlan.ImageKey -match '^[a-f0-9]{64}$' -and
            [string]$combinedToolRuntimeImagePlan.ExternalRuntimeImageKey -eq [string]$externalRuntimeImagePlan.ImageKey -and
            [string]$combinedToolRuntimeImagePlan.ContainerToolImageKey -eq [string]$toolImagePlan.ImageKey -and
            [string]$combinedToolRuntimeImagePlan.LaunchMode -eq 'sql2022-namespace-v1' -and
            (@($combinedToolRuntimeImagePlan.ToolIds) -join ',') -eq 'sqlpackage'
        PackageLock = $packagePlan.ReasonCode -eq 'PACKAGE_NOT_LOCKED'
        HyperVJava = $javaPlan.Status -eq 'RESOLVED' -and -not $javaPlan.ReasonCode -and
            $javaPlan.VariantId -eq 'sql2022-java17-windows-hyperv'
        DuplicateRejected = $duplicateRejected
        ReceiptRejected = $receiptRejected
        Selection = $dockerOptions.Count -eq 3 -and
            (@($dockerOptions.SoftwareId | Sort-Object) -join ',') -eq 'sql-java,sql-python,sql-r' -and
            @($dockerOptions | Where-Object { [string]$_.PlanKey -notmatch '^[a-f0-9]{64}$' }).Count -eq 0 -and
            $podmanOptions.Count -eq 3 -and
            (@($podmanOptions.SoftwareId | Sort-Object) -join ',') -eq 'sql-java,sql-python,sql-r' -and
            @($podmanOptions | Where-Object { [string]$_.Provider -ne 'podman' -or [string]$_.PlanKey -notmatch '^[a-f0-9]{64}$' }).Count -eq 0 -and
            $sql2025Options.Count -eq 3 -and
            $sql2019Options.Count -eq 1 -and $sql2019Options[0].SoftwareId -eq 'sql-java'
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
Add-CheckResult -Name 'C# bleibt ohne freigegebenen Binär- und Native-Evidence-Pfad explizit fail-closed' -Success $result.CSharp
Add-CheckResult -Name 'SqlPackage erhält einen kataloggebundenen Tool-Image-Plan mit SHA-256-Artefakten' -Success $result.GeneralSoftware
Add-CheckResult -Name 'Leere Manifestfelder bleiben erlaubt, freie allgemeine Softwarequellen werden abgelehnt' -Success $result.GeneralSoftwareNullInput
Add-CheckResult -Name 'SqlPackage und SQL-2022-External-Runtime erhalten einen gemeinsam gebundenen Derived-Image-Plan' -Success $result.CombinedContainerImage
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
$getLabSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Get-SqlServerLab.ps1') -Raw -Encoding utf8
$toolProbeSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Test-SqlServerLabContainerTool.ps1') -Raw -Encoding utf8
$toolAcceptanceSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-ContainerToolAcceptance.ps1') -Raw -Encoding utf8
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
Add-CheckResult -Name 'Provisionierung löst sämtliche Software-Intents vor jeder Mutation fail-closed auf' -Success (
    $newLabSource -match 'Resolve-LabSoftwarePlansForInstance' -and
    $newLabSource -match 'SOFTWARE_PLAN_REJECTED' -and
    $newLabSource.IndexOf('Resolve-LabSoftwarePlansForInstance') -lt $newLabSource.IndexOf('New-LabRunState')
)
Add-CheckResult -Name 'Provisionierung bindet den Container-Tool-Plan vor Run-State und Containerstart' -Success (
    $newLabSource -match 'New-LabContainerToolImagePlan' -and
    $newLabSource -match 'Invoke-LabContainerToolImageBuild' -and
    $newLabSource -match "SqlServerLab\.ContainerToolImageArtifact" -and
    $newLabSource -match 'AllowStandardLaunchResolvedImage:\$allowStandardLaunchResolvedImage' -and
    $newLabSource.IndexOf('New-LabContainerToolImagePlan') -lt $newLabSource.IndexOf('New-LabRunState') -and
    $newLabSource.IndexOf('Invoke-LabContainerToolImageBuild') -lt $newLabSource.LastIndexOf('New-LabProviderContainer')
)
Add-CheckResult -Name 'Provisionierung komponiert Tool und External Runtime vor dem Containerstart ohne Freitext-Installationspfad' -Success (
    $newLabSource -notmatch 'CONTAINER_TOOL_EXTERNAL_RUNTIME_COMBINATION_NOT_IMPLEMENTED' -and
    $newLabSource -match 'New-LabContainerToolExternalRuntimeImagePlan' -and
    $newLabSource -match 'Invoke-LabContainerToolExternalRuntimeImageBuild' -and
    $newLabSource.IndexOf('New-LabContainerToolExternalRuntimeImagePlan') -lt $newLabSource.IndexOf('New-LabRunState') -and
    $newLabSource.IndexOf('Invoke-LabContainerToolExternalRuntimeImageBuild') -lt $newLabSource.LastIndexOf('New-LabProviderContainer')
)
Add-CheckResult -Name 'Statussicht zeigt nur sanitisierte Container-Tool-Identität und -Version' -Success (
    $getLabSource -match 'ContainerTools\s*=\s*if \(\$instance\.containerTools\)' -and
    $getLabSource -match 'ToolIds\s*=\s*@\(\$instance\.containerTools\.toolIds' -and
    $getLabSource -match 'RuntimeVersion\s*=\s*\[string\]\$instance\.containerTools\.runtimeVersion' -and
    $newLabSource -match 'containerTools\s*=\s*\$_\.ContainerTools' -and
    $getLabSource -notmatch 'containerTools\.(source|receipt|localImageId)'
)
Add-CheckResult -Name 'Container-Tool-Probe bindet Run und Scope und akzeptiert keine freien Toolargumente' -Success (
    $toolProbeSource -match 'Get-LabRunState' -and
    $toolProbeSource -match 'sql-server-lab\.run-id' -and
    $toolProbeSource -match 'sql-server-lab\.scope-id' -and
    $toolProbeSource -match '/opt/sql-server-lab/tools/sqlpackage/sqlpackage /Version' -and
    $toolProbeSource -notmatch '\[string\[\]\]\$Arguments|\[string\]\$Command|Copy-Item|docker cp|podman cp'
)
Add-CheckResult -Name 'Container-Tool-Akzeptanz prueft Manifest, Probe, Restart und scoped Cleanup nativ' -Success (
    $toolAcceptanceSource -match 'New-SqlServerLab -Manifest' -and
    $toolAcceptanceSource -match 'Test-SqlServerLabContainerTool' -and
    $toolAcceptanceSource -match 'Restart-SqlServerLab' -and
    $toolAcceptanceSource -match 'Remove-SqlServerLab' -and
    $toolAcceptanceSource -match 'image rm --force' -and
    $toolAcceptanceSource -match "ValidateSet\('docker', 'podman'\)"
)

$containerToolManifest = [PSCustomObject]@{
    name = 'container-tool-manifest-check'
    automation = [PSCustomObject]@{ mode = 'unattended' }
    instances = @([PSCustomObject]@{
        id = 'container-tool'; version = '2022'; provider = 'docker'; profile = 'compact'
        software = @([PSCustomObject]@{ id = 'sqlpackage'; scope = 'instance' })
    })
}
$containerToolManifestResult = Test-SqlServerLabManifest -InputObject $containerToolManifest
Add-CheckResult -Name 'Docker-Manifest akzeptiert den kataloggebundenen SqlPackage-Tool-Intent' -Success $containerToolManifestResult.IsValid -Message ($containerToolManifestResult.Errors -join '; ')

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
