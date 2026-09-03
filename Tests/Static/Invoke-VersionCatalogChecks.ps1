#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -ErrorAction Stop
$module = Get-Module SqlServerLab

$versions = & $module { @(Get-SqlServerVersions -Status SUPPORTED | Where-Object { $_.docker.image }) }
Add-CheckResult -Name 'Container-Katalog enthält die unterstützten SQL-Versionen 2019 bis 2025' -Success (
    (@($versions.id | Sort-Object) -join ',') -eq '2019,2022,2025'
)

$deprecatedVersions = & $module { @(Get-SqlServerVersions -Status DEPRECATED | Where-Object { $_.docker.image }) }
Add-CheckResult -Name 'SQL Server 2017 bleibt als veralteter Containerpfad explizit katalogisiert' -Success (
    @($deprecatedVersions.id) -contains '2017'
)

$sql2017 = & $module { Get-SqlServerDockerImage -VersionId '2017' }
Add-CheckResult -Name 'SQL Server 2017 löst auf das offizielle latest-Image auf' -Success (
    $sql2017 -eq 'mcr.microsoft.com/mssql/server:2017-latest'
)

$sql2022Builds = & $module { @(Get-SqlServerBuilds -VersionId '2022') }
Add-CheckResult -Name 'SQL Server 2022 enthält eindeutige katalogisierte CU-Tags' -Success (
    $sql2022Builds.Count -eq 26 -and
    @($sql2022Builds.cu | Sort-Object -Unique).Count -eq $sql2022Builds.Count -and
    @($sql2022Builds.tag | Sort-Object -Unique).Count -eq $sql2022Builds.Count
)
$invalid2022Resolutions = @($sql2022Builds | Where-Object {
    $versionId = "2022-$($_.cu)"
    $resolvedImage = & $module { param($id) Get-SqlServerDockerImage -VersionId $id } $versionId
    $resolvedImage -ne "mcr.microsoft.com/mssql/server:$($_.tag)"
})
Add-CheckResult -Name 'Alle katalogisierten SQL-2022-CUs lösen auf ihren unveränderlichen MCR-Tag auf' -Success (
    $invalid2022Resolutions.Count -eq 0
)

$sql2019Builds = & $module { @(Get-SqlServerBuilds -VersionId '2019') }
Add-CheckResult -Name 'Unterstützte SQL-Versionen sind auf den verifizierten CU-Ständen katalogisiert' -Success (
    $sql2019Builds.Count -eq 31 -and @($sql2019Builds.cu) -notcontains 'CU7' -and
    $sql2019Builds[0].cu -eq 'CU32' -and $sql2019Builds[0].build -eq '15.0.4430.1' -and
    $sql2019Builds[0].kb -eq 'KB5054833' -and $sql2019Builds[0].released -eq '2025-02-27' -and
    $sql2022Builds[0].cu -eq 'CU26' -and $sql2022Builds[0].build -eq '16.0.4265.3' -and
    $sql2022Builds[0].kb -eq 'KB5093420' -and $sql2022Builds[0].released -eq '2026-07-16'
)

$sql2025Builds = & $module { @(Get-SqlServerBuilds -VersionId '2025') }
Add-CheckResult -Name 'SQL Server 2025 enthält CU1 bis CU8 ohne alten CTP-Eintrag' -Success (
    $sql2025Builds.Count -eq 8 -and @($sql2025Builds.cu) -notcontains 'CTP' -and
    $sql2025Builds[0].cu -eq 'CU8' -and $sql2025Builds[0].build -eq '17.0.4075.5' -and
    $sql2025Builds[0].kb -eq 'KB5104822' -and $sql2025Builds[0].released -eq '2026-08-13'
)

$catalog = Get-Content -LiteralPath (Join-Path $repoRoot 'Catalogs\sql-server-versions.json') -Raw | ConvertFrom-Json -Depth 30
$sql2025 = $catalog.versions | Where-Object id -eq '2025' | Select-Object -First 1
$sql2025Cus = @($sql2025.docker.builds | Where-Object { $_.cu -match '^CU\d+$' })
$supportedCus = @($catalog.versions | Where-Object status -eq 'SUPPORTED' | ForEach-Object { $_.docker.builds } | Where-Object { $_.cu -match '^CU\d+$' })
Add-CheckResult -Name 'Alle katalogisierten Builds unterstützter SQL-Versionen besitzen verifizierbare Kernmetadaten' -Success (
    @($catalog.versions | Where-Object status -eq 'SUPPORTED' | ForEach-Object { $_.docker.builds } | Where-Object {
        -not $_.build -or -not $_.kb -or -not $_.released
    }).Count -eq 0
)

$expected2019Cus = @(32..8 | ForEach-Object { "CU$_" }) + @(6..1 | ForEach-Object { "CU$_" })
$expected2022Cus = @(26..1 | ForEach-Object { "CU$_" })
$expected2025Cus = @(8..1 | ForEach-Object { "CU$_" })
Add-CheckResult -Name 'Der Katalog enthält die vollständige offiziell verfügbare CU-Historie' -Success (
    (@($sql2019Builds.cu) -join ',') -eq ($expected2019Cus -join ',') -and
    (@($sql2022Builds.cu) -join ',') -eq ($expected2022Cus -join ',') -and
    (@($sql2025Builds.cu) -join ',') -eq ($expected2025Cus -join ',') -and
    $supportedCus.Count -eq 65
)

$allSupportedResolutions = @(
    foreach ($versionId in @('2019', '2022', '2025')) {
        foreach ($build in @(& $module { param($id) Get-SqlServerBuilds -VersionId $id } $versionId)) {
            $resolvedImage = & $module { param($id) Get-SqlServerDockerImage -VersionId $id } "$versionId-$($build.cu)"
            [PSCustomObject]@{ Expected = "mcr.microsoft.com/mssql/server:$($build.tag)"; Actual = $resolvedImage }
        }
    }
)
Add-CheckResult -Name 'Jeder verfügbare CU-Kurzbezeichner löst auf einen expliziten MCR-Tag auf' -Success (
    $allSupportedResolutions.Count -eq 65 -and
    @($allSupportedResolutions | Where-Object { $_.Actual -ne $_.Expected }).Count -eq 0
)

$cuWatchText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tools/Get-SqlServerCuStatus.ps1') -Raw -Encoding utf8
$containerAcceptanceText = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-ContainerCliAcceptance.ps1') -Raw -Encoding utf8
Add-CheckResult -Name 'Container-CLI-Abnahme bindet Parameter und SQL-Nachweis an denselben Referenzstand' -Success (
    $containerAcceptanceText -match "\[ValidateSet\('2022-CU18'\)\]\[string\]\`$Version = '2022-CU18'" -and
    $containerAcceptanceText -match "\^16\\\|" -and $containerAcceptanceText -match "CU18"
)
Add-CheckResult -Name 'CU-Watch verwendet den öffentlichen read-only CU-Abgleich und den wartbaren Quellenkatalog' -Success (
    $cuWatchText -match 'Get-SqlServerLabCuStatus' -and
    $cuWatchText -match 'sql-server-cu-status-sources\.json' -and
    $cuWatchText -match 'niemals automatisch'
)

$cuStatusSourceCatalog = Get-Content -LiteralPath (Join-Path $repoRoot 'Catalogs\sql-server-cu-status-sources.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 8
Add-CheckResult -Name 'CU-Status-Quellen sind wartbar katalogisiert und schließen den zurückgezogenen SQL-2019-CU7 explizit aus' -Success (
    [string]$cuStatusSourceCatalog.contract -eq 'SqlServerLab.CuStatusSources/1.0' -and
    @($cuStatusSourceCatalog.sources).Count -eq 1 -and
    [string]$cuStatusSourceCatalog.sources[0].url -eq 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates' -and
    @($cuStatusSourceCatalog.sources[0].excludedUpdates | Where-Object { $_.version -eq '2019' -and $_.update -eq 'CU7' -and $_.kb -eq 'KB4570012' }).Count -eq 1
)

$fixtureSource = [PSCustomObject]@{
    id = 'fixture'; url = 'https://learn.microsoft.com/fixture'; allowedHosts = @('learn.microsoft.com')
    excludedUpdates = @()
}
$fixtureRequest = {
    param($Uri)
    [PSCustomObject]@{ Content = @'
### SQL Server 2022

| Build number or version | Service pack | Update | Knowledge Base number | Release date |
| --- | --- | --- | --- | --- |
| 16.0.4270.1 | None | CU27 | KB9999999 | September 1, 2026 |
'@ }
}
$fixtureCuStatus = & $module {
    param($CatalogPath, $Source, $Request)
    Invoke-LabCuStatusCheck -CatalogPath $CatalogPath -Sources @($Source) -Version @('2022') -WebRequestAction $Request
} (Join-Path $repoRoot 'Catalogs\sql-server-versions.json') $fixtureSource $fixtureRequest
Add-CheckResult -Name 'Dynamischer CU-Abgleich erkennt eine neue Microsoft-CU, ohne den Katalog zu mutieren' -Success (
    $fixtureCuStatus.Contract -eq 'SqlServerLab.CuStatus/1.0' -and
    $fixtureCuStatus.Status -eq 'NEW' -and
    $fixtureCuStatus.Versions.Count -eq 1 -and
    $fixtureCuStatus.Versions[0].MissingCount -eq 1 -and
    $fixtureCuStatus.Versions[0].Missing[0].Kb -eq 'KB9999999' -and
    $fixtureCuStatus.Guidance -match 'Download'
)

$withdrawnFixtureSource = [PSCustomObject]@{
    id = 'fixture'; url = 'https://learn.microsoft.com/fixture'; allowedHosts = @('learn.microsoft.com')
    excludedUpdates = @([PSCustomObject]@{ version='2019'; update='CU7'; kb='KB4570012'; reason='withdrawn fixture' })
}
$withdrawnFixtureRequest = {
    param($Uri)
    [PSCustomObject]@{ Content = @'
### SQL Server 2019

| Build number or version | Service pack | Update | Knowledge Base number | Release date |
| --- | --- | --- | --- | --- |
| 15.0.4063.15 | None | CU7 | KB4570012 | September 02, 2020 |
'@ }
}
$withdrawnRows = & $module {
    param($Source, $Request)
    @(Get-LabCuStatusRows -Sources @($Source) -WebRequestAction $Request)
} $withdrawnFixtureSource $withdrawnFixtureRequest
Add-CheckResult -Name 'Dynamischer CU-Abgleich meldet einen dokumentiert zurückgezogenen CU nicht als neue Medienquelle' -Success ($withdrawnRows.Count -eq 0)
Add-CheckResult -Name 'Windows-CU-Metadaten sind vollständig und Downloads nur mit SHA-256 erlaubt' -Success (
    $supportedCus.Count -eq 65 -and
    @($supportedCus | Where-Object {
        -not $_.build -or -not $_.kb -or -not $_.released -or -not $_.articleUrl -or
        -not $_.windows.relativePath -or -not $_.windows.downloadUrl -or
        ([string]$_.windows.sha256 -notmatch '^[A-Fa-f0-9]{64}$')
    }).Count -eq 0
)

$patchOptions = @(@('2019', '2022', '2025') | ForEach-Object {
    & $module { param($id) @(Get-SqlServerPatchOptions -VersionId $id) } $_
})
Add-CheckResult -Name 'Alle verfügbaren Windows-CUs sind automatisch und hashgebunden beschaffbar' -Success (
    $patchOptions.Count -eq 65 -and
    @($patchOptions | Where-Object { -not $_.CanAutoDownload -or -not $_.Sha256 }).Count -eq 0
)

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-cu-resource-check-$([guid]::NewGuid().ToString('N'))"
try {
    $acquisition = & $module {
        param($Root)
        $null = New-Item -ItemType Directory -Path $Root -Force
        $payload = [byte[]](0x4D,0x5A,0x53,0x51,0x4C,0x2D,0x43,0x55)
        $payloadPath = Join-Path $Root 'fixture.exe'
        [IO.File]::WriteAllBytes($payloadPath, $payload)
        $sha256 = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $validSignature = {
            param($Path)
            [PSCustomObject]@{
                Status = 'Valid'
                SignerCertificate = [PSCustomObject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
            }
        }
        $download = {
            param($Uri, $OutFile)
            [IO.File]::WriteAllBytes($OutFile, [byte[]](0x4D,0x5A,0x53,0x51,0x4C,0x2D,0x43,0x55))
        }
        $patch = [PSCustomObject]@{
            BaseVersion='2025'; Cu='CU8'; WindowsRelativePath='SQL/2025/Updates/CU8/synthetic.exe'
            WindowsPath=$null; DownloadUrl='https://catalog.s.download.windowsupdate.com/synthetic.exe'
            Sha256=$sha256; CanAutoDownload=$true
        }
        $downloadedPath = Save-SqlServerWindowsPatchPackage -Patch $patch -MediaRoot $Root `
            -DownloadAction $download -SignatureAction $validSignature
        $confirmedPath = Confirm-SqlServerWindowsPatchPackage -Patch $patch -SignatureAction $validSignature

        $hashMismatch = $null
        $badHashPatch = [PSCustomObject]@{
            BaseVersion='2025'; Cu='CU7'; WindowsRelativePath='SQL/2025/Updates/CU7/bad-hash.exe'
            WindowsPath=$null; DownloadUrl='https://catalog.s.download.windowsupdate.com/bad-hash.exe'
            Sha256=('0' * 64); CanAutoDownload=$true
        }
        try { $null = Save-SqlServerWindowsPatchPackage -Patch $badHashPatch -MediaRoot $Root -DownloadAction $download -SignatureAction $validSignature }
        catch { $hashMismatch = $_.Exception.Message }

        $invalidSignature = $null
        $badSignaturePatch = [PSCustomObject]@{
            BaseVersion='2025'; Cu='CU6'; WindowsRelativePath='SQL/2025/Updates/CU6/bad-signature.exe'
            WindowsPath=$null; DownloadUrl='https://catalog.s.download.windowsupdate.com/bad-signature.exe'
            Sha256=$sha256; CanAutoDownload=$true
        }
        try {
            $null = Save-SqlServerWindowsPatchPackage -Patch $badSignaturePatch -MediaRoot $Root -DownloadAction $download -SignatureAction {
                param($Path) [PSCustomObject]@{ Status='NotSigned'; SignerCertificate=$null }
            }
        }
        catch { $invalidSignature = $_.Exception.Message }

        $pathTraversal = $null
        $outsidePatch = [PSCustomObject]@{
            BaseVersion='2025'; Cu='CU5'; WindowsRelativePath='../outside.exe'; WindowsPath=$null
            DownloadUrl='https://catalog.s.download.windowsupdate.com/outside.exe'; Sha256=$sha256; CanAutoDownload=$true
        }
        try { $null = Save-SqlServerWindowsPatchPackage -Patch $outsidePatch -MediaRoot $Root -DownloadAction $download -SignatureAction $validSignature }
        catch { $pathTraversal = $_.Exception.Message }

        $script:CuTestImagePresent = $false
        $containerResult = Save-SqlServerContainerImageResource -Provider docker -Image 'mcr.microsoft.com/mssql/server:2025-CU8-test' `
            -InspectAction { param($Provider,$Image) $script:CuTestImagePresent } `
            -PullAction { param($Provider,$Image) $script:CuTestImagePresent = $true; $true }

        [PSCustomObject]@{
            WindowsReady = $downloadedPath -eq $confirmedPath -and (Test-Path -LiteralPath $confirmedPath -PathType Leaf)
            HashMismatchFailsClosed = $hashMismatch -like 'SQL_WINDOWS_CU_DOWNLOAD_HASH_MISMATCH*' -and
                -not (Test-Path -LiteralPath (Join-Path $Root 'SQL/2025/Updates/CU7/bad-hash.exe'))
            InvalidSignatureFailsClosed = $invalidSignature -like 'SQL_WINDOWS_CU_AUTHENTICODE_INVALID*' -and
                -not (Test-Path -LiteralPath (Join-Path $Root 'SQL/2025/Updates/CU6/bad-signature.exe'))
            PathTraversalRejected = $pathTraversal -like 'SQL_WINDOWS_CU_RELATIVE_PATH_INVALID*'
            NoTemporaryFiles = @(Get-ChildItem -LiteralPath $Root -Filter '*.download-*.exe' -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0
            ContainerPullReady = -not $containerResult.AlreadyPresent -and $script:CuTestImagePresent
        }
    } $temporaryRoot

    Add-CheckResult -Name 'Windows-CU-Acquisition veröffentlicht nur nach SHA-256 und Microsoft-Authenticode' -Success $acquisition.WindowsReady
    Add-CheckResult -Name 'Hash- und Signaturfehler hinterlassen weder Ziel noch temporäre Datei' -Success (
        $acquisition.HashMismatchFailsClosed -and $acquisition.InvalidSignatureFailsClosed -and $acquisition.NoTemporaryFiles
    )
    Add-CheckResult -Name 'Windows-CU-Acquisition blockiert Pfadtraversal außerhalb des Media Root' -Success $acquisition.PathTraversalRejected
    Add-CheckResult -Name 'Linux-CU-Acquisition zieht einen fehlenden exakten Image-Tag in den Providercache' -Success $acquisition.ContainerPullReady
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$runtimeWorkflowPaths = @(
    (Join-Path $repoRoot '.github/workflows/runtime-smoke-docker.yml'),
    (Join-Path $repoRoot '.github/workflows/runtime-smoke-podman.yml')
)
$invalidRuntimeWorkflows = @($runtimeWorkflowPaths | Where-Object {
    $workflowText = Get-Content -LiteralPath $_ -Raw -Encoding utf8
    $workflowText -match '(?m)-FullMatrix|(?m)-IncludeParallel' -or
    @([regex]::Matches($workflowText, '(?m)-ReferenceVersion\s+2025')).Count -ne 1 -or
    @([regex]::Matches($workflowText, '(?m)-Version\s+2025')).Count -ne 2 -or
    @([regex]::Matches($workflowText, '(?m)-Version\s+2022-CU18')).Count -ne 1 -or
    $workflowText -match '(?m)-(?:Reference)?Version\s+(?:2017|2019)(?:\s|$)' -or
    $workflowText -match '(?m)-(?:Reference)?Version\s+2022(?!-CU18)(?:\s|$)'
})
Add-CheckResult -Name 'Docker- und Podman-Gates trennen SQL-2025-Lifecycle von SQL-2022-CU18-CLI-Acceptance' -Success (
    $invalidRuntimeWorkflows.Count -eq 0
) -Message (($invalidRuntimeWorkflows | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')

$referenceFiles = @(
    (Join-Path $repoRoot 'Tests/Integration/Invoke-RestoreSmokeTest.ps1'),
    (Join-Path $repoRoot 'Tests/Integration/Invoke-AdapterSmokeTest.ps1'),
    (Join-Path $repoRoot 'Tests/Integration/Invoke-MixedProviderSmokeTest.ps1'),
    (Join-Path $repoRoot 'Schemas/example-mixed-provider-lab.json'),
    (Join-Path $repoRoot '.github/workflows/runtime-smoke-docker-github-hosted.yml'),
    (Join-Path $repoRoot '.github/workflows/adapter-smoke-github-hosted.yml'),
    (Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv-sql-fresh-acceptance.yml')
)
$nonReferenceRuntimeHits = @($referenceFiles | Where-Object {
    (Get-Content -LiteralPath $_ -Raw -Encoding utf8) -match '(?m)(?:Version\s*=\s*|Version\s+|"version"\s*:\s*|versions=\()["'']?(?:2019|2022)'
})
Add-CheckResult -Name 'Reguläre Runtime-, Mixed-, Restore-, Adapter- und Hyper-V-Gates sind auf SQL 2025 vereinheitlicht' -Success (
    $nonReferenceRuntimeHits.Count -eq 0
)

$defaultCollationFiles = @(
    (Join-Path $repoRoot 'Private/ManifestParser.ps1'),
    (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1'),
    (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1'),
    (Join-Path $repoRoot 'Public/New-SqlServerLab.ps1'),
    (Join-Path $repoRoot 'Public/New-SqlServerLabDatabase.ps1'),
    (Join-Path $repoRoot 'Schemas/lab-manifest.schema.json')
)
$invalidDefaultCollationFiles = @($defaultCollationFiles | Where-Object {
    (Get-Content -LiteralPath $_ -Raw -Encoding utf8) -notmatch 'SQL_Latin1_General_CP1_CI_AS'
})
$manifestSchemaText = Get-Content -LiteralPath (Join-Path $repoRoot 'Schemas/lab-manifest.schema.json') -Raw -Encoding utf8
Add-CheckResult -Name 'Standardpfade verwenden die native SQL-Containercollation CI_AS' -Success (
    $invalidDefaultCollationFiles.Count -eq 0 -and
    $manifestSchemaText -match '"default"\s*:\s*"SQL_Latin1_General_CP1_CI_AS"'
)

$containerProviderText = @(
    Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1') -Raw -Encoding utf8
    Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1') -Raw -Encoding utf8
) -join "`n"
Add-CheckResult -Name 'Provider übergeben MSSQL_COLLATION nur für eine explizite Custom-Collation' -Success (
    @([regex]::Matches($containerProviderText, "Collation\s+-ne\s+'SQL_Latin1_General_CP1_CI_AS'")).Count -eq 2 -and
    @([regex]::Matches($containerProviderText, 'MSSQL_COLLATION=\$Collation')).Count -eq 2
)

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "Version Catalog Checks: $passed PASS" -ForegroundColor Green
