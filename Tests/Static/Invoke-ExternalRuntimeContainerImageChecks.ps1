#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Derived-Image-Key, sichere Launchgrenzen und Receipt-Vertrag.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - External Runtime Container Image Checks' -ForegroundColor Cyan

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -ErrorAction Stop
$module = Get-Module SqlServerLab
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("sql-lab-external-runtime-checks-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
try {
    $result = & $module {
        param($Root)
        $request = [PSCustomObject]@{
            Id='sql-python'; Version=$null; Variant=$null; Scope='sqlExternalRuntime'; InstallMethod='catalog'
            Optional=$false; Packages=@(); RequestSource='software'
        }
        $dockerSoftwarePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion 2022 -Provider docker -OperatingSystem linux
        $podmanSoftwarePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion 2022 -Provider podman -OperatingSystem linux
        $rRequest = $request | Select-Object *
        $rRequest.Id = 'sql-r'
        $dockerRSoftwarePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $rRequest -SqlVersion 2022 -Provider docker -OperatingSystem linux
        $podmanRSoftwarePlan = Resolve-LabExternalRuntimePlan -SoftwareItem $rRequest -SqlVersion 2022 -Provider podman -OperatingSystem linux
        $dockerImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 -SoftwarePlans @($dockerSoftwarePlan) -AllowPreview
        $podmanImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider podman -SqlVersion 2022 -SoftwarePlans @($podmanSoftwarePlan) -AllowPreview
        $dockerRImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 -SoftwarePlans @($dockerRSoftwarePlan) -AllowPreview
        $podmanRImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider podman -SqlVersion 2022 -SoftwarePlans @($podmanRSoftwarePlan) -AllowPreview
        $combinedImagePlan = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 `
            -SoftwarePlans @($dockerSoftwarePlan, $dockerRSoftwarePlan) -AllowPreview

        $arbitraryRejected = $false
        try {
            $invalid = $dockerSoftwarePlan | Select-Object *
            $invalid.Status = 'RESOLVED_BY_USER'
            $null = New-LabExternalRuntimeContainerImagePlan -Provider docker -SqlVersion 2022 -SoftwarePlans @($invalid) -AllowPreview
        }
        catch { $arbitraryRejected = $_.Exception.Message -match 'SOFTWARE_PLAN_REJECTED' }

        $resolved = $dockerSoftwarePlan | Select-Object *
        $resolved.Status = 'RESOLVED'
        $resolved.ReasonCode = $null
        $resolved.Reason = $null
        $receipt = New-LabSoftwareInstallationReceipt -Plan $resolved -Postconditions @(
            [PSCustomObject]@{ Id='python-data-roundtrip'; Status='PASS'; RuntimeVersion='3.10.12'; WorkerIdentity='mssql_satellite' }
        )
        $runDirectory = Join-Path $Root 'run'
        New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null
        $null = Save-LabExternalRuntimeInstallationReceipts -RunDirectory $runDirectory -InstanceId sql -Receipts @($receipt)
        $receiptText = Get-Content -LiteralPath (Join-Path $runDirectory 'software-installation-receipts.json') -Raw -Encoding utf8

        [PSCustomObject]@{
            Recipe = Get-LabExternalRuntimeContainerRecipe
            DockerPlan = $dockerImagePlan
            PodmanPlan = $podmanImagePlan
            DockerRPlan = $dockerRImagePlan
            PodmanRPlan = $podmanRImagePlan
            CombinedPlan = $combinedImagePlan
            ArbitraryRejected = $arbitraryRejected
            ReceiptSanitized = $receiptText -notmatch '(?i)https?://|[A-Z]:\\|/usr/|RecipeRoot|Containerfile'
            ReceiptContract = ($receiptText | ConvertFrom-Json -Depth 30).contract.name
        }
    } $testRoot

    Add-CheckResult -Name 'Rezept ist versioniert und bindet SQL-Basisimage per MCR-Digest' -Success (
        $result.Recipe.contract.name -eq 'SqlServerLab.ExternalRuntimeContainerRecipe' -and
        $result.Recipe.baseImage.reference -match '@sha256:[a-f0-9]{64}$' -and
        $result.Recipe.baseImage.reference -notmatch ':latest'
    )
    Add-CheckResult -Name 'Python-Lock und Rezept besitzen dieselben acht versionierten SHA-256-Artefakte' -Success (
        @($result.Recipe.runtimes.Python.artifacts).Count -eq 8 -and
        @($result.Recipe.runtimes.Python.artifacts | Where-Object { [string]$_.sha256 -match '^[a-f0-9]{64}$' }).Count -eq 8
    )
    Add-CheckResult -Name 'R-Rezept bindet R 4.2.3, OCI-Stage und sechs Paketarchive per SHA-256' -Success (
        $result.Recipe.runtimes.R.runtimeVersion -eq '4.2.3' -and
        $result.Recipe.runtimes.R.runtimeImage.reference -match '@sha256:[a-f0-9]{64}$' -and
        @($result.Recipe.runtimes.R.artifacts).Count -eq 6 -and
        @($result.Recipe.runtimes.R.artifacts | Where-Object { [string]$_.sha256 -match '^[a-f0-9]{64}$' }).Count -eq 6
    )
    Add-CheckResult -Name 'Docker und Podman konsumieren denselben providerneutralen OCI-Image-Key' -Success (
        $result.DockerPlan.ImageKey -eq $result.PodmanPlan.ImageKey -and
        $result.DockerPlan.Image -eq $result.PodmanPlan.Image -and
        $result.DockerPlan.ImageKey -match '^[a-f0-9]{64}$'
    )
    Add-CheckResult -Name 'Image-Key bindet alle sechs Python-Kontextdateien mit SHA-256' -Success (
        @($result.DockerPlan.ContextEvidence).Count -eq 6 -and
        @($result.DockerPlan.ContextEvidence | Where-Object { $_.sha256 -match '^[a-f0-9]{64}$' }).Count -eq 6
    )
    Add-CheckResult -Name 'R-Image-Key ist providerneutral und bindet genau den runtime-r-Stage' -Success (
        $result.DockerRPlan.ImageKey -eq $result.PodmanRPlan.ImageKey -and
        $result.DockerRPlan.BuildStage -eq 'runtime-r' -and
        $result.DockerRPlan.BuildTokens -join ',' -eq 'r' -and
        @($result.DockerRPlan.ContextEvidence).Count -eq 5
    )
    Add-CheckResult -Name 'Kombinierter R-Python-Plan verwendet kanonische Reihenfolge und vollständigen Kontext' -Success (
        $result.CombinedPlan.BuildStage -eq 'runtime-r-python' -and
        $result.CombinedPlan.BuildTokens -join ',' -eq 'r,python' -and
        @($result.CombinedPlan.ContextEvidence).Count -eq 8 -and
        $result.CombinedPlan.ImageKey -notin @($result.DockerPlan.ImageKey, $result.DockerRPlan.ImageKey)
    )
    Add-CheckResult -Name 'Beliebig behauptete Softwareplan-Status werden abgelehnt' -Success $result.ArbitraryRejected
    Add-CheckResult -Name 'Run-Receipt bleibt geheimnis- und hostpfadfrei' -Success (
        $result.ReceiptSanitized -and $result.ReceiptContract -eq 'SqlServerLab.RunSoftwareInstallationReceipts'
    )

    $containerfile = Get-Content -LiteralPath (Join-Path $repoRoot 'Images/ExternalLanguages/Linux/Containerfile') -Raw -Encoding utf8
    $launcher = Get-Content -LiteralPath (Join-Path $repoRoot 'Images/ExternalLanguages/Linux/launch-external-runtime.sh') -Raw -Encoding utf8
    $rInstaller = Get-Content -LiteralPath (Join-Path $repoRoot 'Images/ExternalLanguages/Linux/install-r-runtime.sh') -Raw -Encoding utf8
    Add-CheckResult -Name 'Containerfile bindet Microsoft-Paket, EULA und sichere Launch-Metadaten' -Success (
        $containerfile -match 'mssql-server-extensibility_16\.0\.4265\.3-1_amd64\.deb' -and
        $containerfile -match '50df89ac3d1176f6227a9db46d1d8128cb3a326718515082f5ca161028610226' -and
        $containerfile -match 'accepteulaml Y' -and
        $containerfile -match 'required-cgroup-version="1"' -and
        $containerfile -match 'namespace-isolation="true"' -and
        $containerfile -match 'outbound-access="false"'
    )
    Add-CheckResult -Name 'Launcher deaktiviert weder Namespace-Isolation noch Outbound-Schutz' -Success (
        $launcher -match '/opt/mssql/bin/launchpadd &' -and
        $launcher -notmatch '(?i)-usens=false|enableOutboundAccess=true'
    )
    Add-CheckResult -Name 'R-Build bleibt hashgebunden, compilerfrei im Ziel und ABI-minimal' -Success (
        $containerfile -match 'rocker/r-ver@sha256:22202dfb31f3a1b515936bac559a9f56b67585adce2c14d063f97478940d374a' -and
        $containerfile -match 'FROM runtime-base AS runtime-r' -and
        $containerfile -match 'FROM runtime-r AS runtime-r-python' -and
        $containerfile -match 'libgfortran\.so\.5' -and $containerfile -match 'liblapack\.so\.3' -and
        $containerfile -notmatch '(?m)^FROM runtime-r.*\b(gcc|g\+\+|build-essential)\b' -and
        $rInstaller -match 'sha256sum --check --strict' -and
        $rInstaller -notmatch 'install\.packages\s*\('
    )

    $artifactSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ContainerImageArtifact.ps1') -Raw -Encoding utf8
    $dockerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1') -Raw -Encoding utf8
    $podmanSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1') -Raw -Encoding utf8
    $newLabSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1') -Raw -Encoding utf8
    $lifecycleSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ExternalRuntimeLifecycle.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Build akzeptiert nur bekannte Provider und arraygebundene Argumente' -Success (
        $artifactSource -match "ValidateSet\('docker', 'podman'\)" -and
        $artifactSource -match '& \$provider @buildArguments' -and
        $artifactSource -notmatch '(?i)Invoke-Expression|ScriptBlock\.Create'
    )
    Add-CheckResult -Name 'Paketlocks binden sichere Dateinamen an den exakten URL-Pfad' -Success (
        $artifactSource -match 'EXTERNAL_RUNTIME_PACKAGE_LOCK_FILENAME_MISMATCH' -and
        $artifactSource -match 'GetFileName\(\$sourceUri\.AbsolutePath\)'
    )
    Add-CheckResult -Name 'Image-Reuse und Build sind je Artifact Store serialisiert' -Success (
        $artifactSource -match '(?s)function Invoke-LabExternalRuntimeContainerImageBuild\s*\{.*?Invoke-LabArtifactStoreLock.*?Invoke-LabExternalRuntimeContainerImageBuildCore'
    )
    Add-CheckResult -Name 'SYS_ADMIN wird in beiden Providern nur durch den exakten Launchmodus gebunden' -Success (
        $dockerSource -match "ExternalRuntimeLaunchMode -eq 'sql2022-namespace-v1'" -and
        $dockerSource -match "@\('--cap-add', 'SYS_ADMIN'\)" -and
        $podmanSource -match "ExternalRuntimeLaunchMode -eq 'sql2022-namespace-v1'" -and
        $podmanSource -match "@\('--cap-add', 'SYS_ADMIN'\)"
    )
    Add-CheckResult -Name 'Software- und Host-Gates laufen vor Run-State und jeder Provider-Mutation' -Success (
        $newLabSource.IndexOf('Resolve-LabExternalRuntimePlansForInstance') -ge 0 -and
        $newLabSource.IndexOf('Resolve-LabExternalRuntimePlansForInstance') -lt $newLabSource.IndexOf('New-LabRunState') -and
        $newLabSource.IndexOf('Test-LabExternalRuntimeContainerHost') -lt $newLabSource.IndexOf('New-LabRunState')
    )
    Add-CheckResult -Name 'Image-Build erfolgt erst nach Cleanup-Plan und bleibt außerhalb normaler Run-Cleanup-Schritte' -Success (
        $newLabSource.IndexOf('New-CleanupPlan') -lt $newLabSource.IndexOf('Invoke-LabExternalRuntimeContainerImageBuild') -and
        $newLabSource -notmatch "ResourceType 'image'"
    )
    Add-CheckResult -Name 'Run-State persistiert Image-Key und verifizierte Software-Receipt-Zusammenfassung' -Success (
        $newLabSource -match "Status = 'IMAGE_READY'" -and
        $newLabSource -match "ExternalRuntime\.Status = 'EXTENSIONS_READY_RUN'" -and
        $newLabSource -match 'externalRuntime\s+= \$_\.ExternalRuntime'
    )
    Add-CheckResult -Name 'R-Postcondition prueft SQL-Datenroundtrip, Paketversionen und Workeridentitaet' -Success (
        $lifecycleSource -match "@language = N'R'" -and
        $lifecycleSource -match "EXTERNAL_RUNTIME_R_EVIDENCE_INVALID" -and
        $lifecycleSource -match 'packageVersion\("RevoScaleR"\)' -and
        $lifecycleSource -match 'packageVersion\("jsonlite"\)' -and
        $lifecycleSource -match "mssql_satellite"
    )
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "External Runtime Container Image Checks: $passed PASS" -ForegroundColor Green
