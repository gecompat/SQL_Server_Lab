<#
.SYNOPSIS
    Katalogzugriff fuer SQL-Server-Versionen, Builds, Ressourcenprofile und Sample-Datenbanken.
.DESCRIPTION
    Liest die beim Modulimport geladenen Kataloge und stellt interne Aufloesungsfunktionen bereit.
#>

function Get-SqlServerVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VersionId
    )

    if (-not $script:VersionCatalog) {
        throw 'Versionskatalog nicht geladen.'
    }

    $exact = $script:VersionCatalog.versions |
        Where-Object { $_.id -eq $VersionId } |
        Select-Object -First 1
    if ($exact) {
        return $exact
    }

    if ($VersionId -match '^(\d{4})-CU\d+(?:-|$)') {
        $baseVersion = $Matches[1]
        return $script:VersionCatalog.versions |
            Where-Object { $_.id -eq $baseVersion } |
            Select-Object -First 1
    }

    return $null
}

function Test-SqlServerVersionSupported {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VersionId,
        [switch]$AllowDeprecated,
        [switch]$AllowRetired
    )

    $version = Get-SqlServerVersion -VersionId $VersionId
    if (-not $version) {
        return [PSCustomObject]@{
            Supported = $false
            Status    = 'UNKNOWN'
            Message   = "Version '$VersionId' nicht im Katalog."
        }
    }

    switch ($version.status) {
        'SUPPORTED' {
            return [PSCustomObject]@{ Supported = $true; Status = 'SUPPORTED'; Message = '' }
        }
        'PREVIEW' {
            return [PSCustomObject]@{ Supported = $true; Status = 'PREVIEW'; Message = 'Vorabversion.' }
        }
        'DEPRECATED' {
            $allowed = $AllowDeprecated.IsPresent
            $message = if ($allowed) {
                'Veraltete Version wurde ausdruecklich zugelassen.'
            }
            else {
                'Veraltet. -AllowDeprecated verwenden.'
            }
            return [PSCustomObject]@{ Supported = $allowed; Status = 'DEPRECATED'; Message = $message }
        }
        'RETIRED' {
            $allowed = $AllowRetired.IsPresent
            $message = if ($allowed) {
                'Nicht mehr gepflegte Version wurde ausdruecklich zugelassen.'
            }
            else {
                'Nicht mehr gepflegt. -AllowRetired verwenden.'
            }
            return [PSCustomObject]@{ Supported = $allowed; Status = 'RETIRED'; Message = $message }
        }
        'BLOCKED' {
            return [PSCustomObject]@{ Supported = $false; Status = 'BLOCKED'; Message = 'Blockiert (Sicherheitsrisiko).' }
        }
        default {
            return [PSCustomObject]@{ Supported = $false; Status = $version.status; Message = 'Unbekannter Status.' }
        }
    }
}

function Get-SqlServerVersions {
    [CmdletBinding()]
    param(
        [ValidateSet('SUPPORTED', 'PREVIEW', 'DEPRECATED', 'RETIRED', 'BLOCKED', 'ALL')]
        [string]$Status = 'ALL'
    )

    if (-not $script:VersionCatalog) {
        throw 'Versionskatalog nicht geladen.'
    }

    if ($Status -eq 'ALL') {
        return @($script:VersionCatalog.versions)
    }

    return @($script:VersionCatalog.versions | Where-Object { $_.status -eq $Status })
}

function Get-SqlServerDockerImage {
    <#
    .SYNOPSIS
        Loest Basisversion, katalogisierten CU-Kurzbezeichner oder exakten Tag auf.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VersionId
    )

    if ($VersionId -match '^(\d{4})-CU\d+-.+$') {
        $baseVersion = $Matches[1]
        if (-not (Get-SqlServerVersion -VersionId $baseVersion)) {
            throw "Basisversion '$baseVersion' ist nicht im Versionskatalog enthalten."
        }
        return "mcr.microsoft.com/mssql/server:$VersionId"
    }

    if ($VersionId -match '^(\d{4})-(CU\d+)$') {
        $baseVersion = $Matches[1]
        $cuId = $Matches[2]
        $version = Get-SqlServerVersion -VersionId $baseVersion

        if (-not $version -or -not $version.docker) {
            throw "Kein Docker-Image fuer Basisversion '$baseVersion'."
        }

        $build = $version.docker.builds |
            Where-Object { $_.cu -eq $cuId } |
            Select-Object -First 1
        if (-not $build) {
            throw "Build '$VersionId' ist nicht im Versionskatalog enthalten."
        }

        return "mcr.microsoft.com/mssql/server:$($build.tag)"
    }

    if ($VersionId -notmatch '^\d{4}$') {
        throw "Versionsbezeichner '$VersionId' hat kein unterstuetztes Format."
    }

    $version = Get-SqlServerVersion -VersionId $VersionId
    if (-not $version -or -not $version.docker -or -not $version.docker.image) {
        throw "Kein Docker-Image fuer '$VersionId'."
    }

    return $version.docker.image
}

function Get-SqlServerBuilds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VersionId
    )

    $version = Get-SqlServerVersion -VersionId $VersionId
    if (-not $version -or -not $version.docker -or -not $version.docker.builds) {
        return @()
    }

    return @($version.docker.builds)
}

function Get-SqlServerPatchOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VersionId,
        [string]$MediaRoot
    )

    $builds = @(Get-SqlServerBuilds -VersionId $VersionId | Where-Object { [string]$_.cu -match '^CU\d+$' })
    return @($builds | Sort-Object { [int](([string]$_.cu) -replace '^CU', '') } -Descending | ForEach-Object {
        $build = $_
        $windows = if ($build.PSObject.Properties['windows']) { $build.windows } else { $null }
        $relativePath = if ($windows -and $windows.relativePath) {
            [string]$windows.relativePath
        }
        elseif ($build.kb) {
            "SQL/$VersionId/Updates/$($build.cu)/SQLServer$VersionId-$($build.kb)-x64.exe"
        }
        else { $null }
        $localPath = if ($MediaRoot -and $relativePath) {
            Join-Path $MediaRoot ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
        }
        else { $null }
        $present = $localPath -and (Test-Path -LiteralPath $localPath -PathType Leaf)
        $sha256 = if ($windows -and $windows.sha256) { ([string]$windows.sha256).ToLowerInvariant() } else { $null }
        [PSCustomObject]@{
            VersionId = "$VersionId-$($build.cu)"
            BaseVersion = $VersionId
            Cu = [string]$build.cu
            Build = [string]$build.build
            Kb = [string]$build.kb
            Released = [string]$build.released
            ContainerTag = [string]$build.tag
            ArticleUrl = [string]$build.articleUrl
            WindowsRelativePath = $relativePath
            WindowsPath = $localPath
            WindowsStatus = if ($present) { if ($sha256) { 'PRESENT_HASH_CATALOGUED' } else { 'PRESENT_UNVERIFIED' } } else { 'MISSING' }
            DownloadUrl = if ($windows) { [string]$windows.downloadUrl } else { $null }
            Sha256 = $sha256
            CanAutoDownload = [bool]($windows -and $windows.downloadUrl -and $sha256)
        }
    })
}

function Get-SqlServerPatchOption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VersionId,
        [Parameter(Mandatory)][string]$Cu,
        [string]$MediaRoot
    )

    $normalizedCu = $Cu.ToUpperInvariant()
    $matches = @(Get-SqlServerPatchOptions -VersionId $VersionId -MediaRoot $MediaRoot |
        Where-Object { [string]::Equals([string]$_.Cu, $normalizedCu, [StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -ne 1) {
        throw "SQL_CU_NOT_CATALOGUED: $VersionId-$normalizedCu"
    }
    return $matches[0]
}

function Test-SqlServerWindowsPatchAuthenticode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$SignatureAction
    )

    if (-not $SignatureAction) {
        if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
            throw 'SQL_WINDOWS_CU_AUTHENTICODE_UNAVAILABLE: Get-AuthenticodeSignature ist auf diesem Host nicht verfügbar.'
        }
        $SignatureAction = { param($FilePath) Get-AuthenticodeSignature -LiteralPath $FilePath -ErrorAction Stop }
    }

    $signature = @(& $SignatureAction $Path) | Select-Object -Last 1
    $subject = if ($signature -and $signature.SignerCertificate) {
        [string]$signature.SignerCertificate.Subject
    }
    else { '' }
    if (-not $signature -or [string]$signature.Status -ne 'Valid') {
        $status = if ($signature) { [string]$signature.Status } else { 'Missing' }
        throw "SQL_WINDOWS_CU_AUTHENTICODE_INVALID: Status $status"
    }
    if ($subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw 'SQL_WINDOWS_CU_SIGNER_NOT_MICROSOFT'
    }

    return [PSCustomObject]@{
        Status = 'Valid'
        SignerSubject = $subject
    }
}

function Confirm-SqlServerWindowsPatchPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Patch,
        [scriptblock]$SignatureAction
    )

    if (-not $Patch.WindowsPath -or -not (Test-Path -LiteralPath $Patch.WindowsPath -PathType Leaf)) {
        throw "SQL_WINDOWS_CU_PACKAGE_MISSING: $($Patch.WindowsRelativePath)"
    }
    if (-not $Patch.Sha256) {
        throw "SQL_WINDOWS_CU_HASH_NOT_CATALOGUED: $($Patch.Cu) · $($Patch.ArticleUrl)"
    }
    $actual = (Get-FileHash -LiteralPath $Patch.WindowsPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actual -ne [string]$Patch.Sha256) {
        throw "SQL_WINDOWS_CU_HASH_MISMATCH: $($Patch.WindowsRelativePath)"
    }
    $null = Test-SqlServerWindowsPatchAuthenticode -Path $Patch.WindowsPath -SignatureAction $SignatureAction
    return $Patch.WindowsPath
}

function Save-SqlServerWindowsPatchPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Patch,
        [Parameter(Mandatory)][string]$MediaRoot,
        [scriptblock]$DownloadAction,
        [scriptblock]$SignatureAction
    )

    if (-not $Patch.CanAutoDownload) {
        throw "SQL_WINDOWS_CU_AUTODOWNLOAD_NOT_TRUSTED: $($Patch.Cu)"
    }
    if (-not (Test-Path -LiteralPath $MediaRoot -PathType Container)) {
        throw "SQL_WINDOWS_CU_MEDIA_ROOT_NOT_FOUND: $MediaRoot"
    }
    $resolvedRoot = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    $rootItem = Get-Item -LiteralPath $resolvedRoot -Force -ErrorAction Stop
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'SQL_WINDOWS_CU_MEDIA_ROOT_REPARSE_POINT'
    }

    $relativePath = [string]$Patch.WindowsRelativePath
    if ([string]::IsNullOrWhiteSpace($relativePath) -or [IO.Path]::IsPathRooted($relativePath) -or
        @($relativePath -split '[\\/]' | Where-Object { $_ -eq '..' }).Count -gt 0 -or
        [IO.Path]::GetExtension($relativePath) -ne '.exe') {
        throw "SQL_WINDOWS_CU_RELATIVE_PATH_INVALID: $relativePath"
    }
    $target = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    $pathBoundary = Test-LabPathWithinRoot -Root $resolvedRoot -Path $target
    if (-not $pathBoundary.Valid) {
        throw "SQL_WINDOWS_CU_PATH_OUTSIDE_MEDIA_ROOT: $($pathBoundary.Reason)"
    }

    $downloadUri = try { [uri]$Patch.DownloadUrl } catch { $null }
    if (-not $downloadUri -or $downloadUri.Scheme -ne 'https' -or
        $downloadUri.Host -notmatch '(^|\.)download\.windowsupdate\.com$') {
        throw "SQL_WINDOWS_CU_DOWNLOAD_SOURCE_NOT_ALLOWED: $($Patch.DownloadUrl)"
    }

    $Patch | Add-Member -NotePropertyName WindowsPath -NotePropertyValue $target -Force
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        return Confirm-SqlServerWindowsPatchPackage -Patch $Patch -SignatureAction $SignatureAction
    }

    $targetDirectory = Split-Path -Parent $target
    $null = New-Item -ItemType Directory -Path $targetDirectory -Force
    $pathBoundary = Test-LabPathWithinRoot -Root $resolvedRoot -Path $target
    if (-not $pathBoundary.Valid) {
        throw "SQL_WINDOWS_CU_PATH_OUTSIDE_MEDIA_ROOT: $($pathBoundary.Reason)"
    }
    $temporary = Join-Path $targetDirectory (([IO.Path]::GetFileNameWithoutExtension($target)) + ".download-$([guid]::NewGuid().ToString('N')).exe")
    if (-not $DownloadAction) {
        $DownloadAction = {
            param($Uri, $OutFile)
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop
        }
    }
    try {
        $null = & $DownloadAction $downloadUri $temporary
        if (-not (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            throw "SQL_WINDOWS_CU_DOWNLOAD_MISSING: $($Patch.Cu)"
        }
        $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actual -ne [string]$Patch.Sha256) { throw "SQL_WINDOWS_CU_DOWNLOAD_HASH_MISMATCH: $($Patch.Cu)" }
        $null = Test-SqlServerWindowsPatchAuthenticode -Path $temporary -SignatureAction $SignatureAction
        Move-Item -LiteralPath $temporary -Destination $target -ErrorAction Stop
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    return $target
}

function Test-SqlServerContainerImagePresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][string]$Image,
        [scriptblock]$InspectAction
    )

    if ($InspectAction) {
        return [bool](& $InspectAction $Provider $Image)
    }
    $runtimeResolution = Resolve-LabHostTool -Name $Provider
    if (-not $runtimeResolution.Available) { return $false }
    $runtimeInvocation = [string]$runtimeResolution.Invocation
    $null = & $runtimeInvocation image inspect $Image 2>&1
    return $LASTEXITCODE -eq 0
}

function Resolve-SqlServerContainerImageProvider {
    [CmdletBinding()]
    param([ValidateSet('auto', 'docker', 'podman')][string]$Provider = 'auto')

    $candidates = if ($Provider -eq 'auto') { @('docker', 'podman') } else { @($Provider) }
    foreach ($candidate in $candidates) {
        $runtimeResolution = Resolve-LabHostTool -Name $candidate
        if (-not $runtimeResolution.Available) { continue }
        $runtimeInvocation = [string]$runtimeResolution.Invocation
        $null = & $runtimeInvocation info 2>&1
        if ($LASTEXITCODE -eq 0) { return $candidate }
    }
    throw "SQL_LINUX_CU_PROVIDER_UNAVAILABLE: $Provider"
}

function Save-SqlServerContainerImageResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][string]$Image,
        [scriptblock]$InspectAction,
        [scriptblock]$PullAction
    )

    if (Test-SqlServerContainerImagePresent -Provider $Provider -Image $Image -InspectAction $InspectAction) {
        return [PSCustomObject]@{ Provider = $Provider; Image = $Image; AlreadyPresent = $true }
    }

    if ($PullAction) {
        $pullSucceeded = [bool](& $PullAction $Provider $Image)
    }
    else {
        $runtimeInvocation = Get-LabHostToolInvocation -Name $Provider
        $null = & $runtimeInvocation pull $Image
        $pullSucceeded = $LASTEXITCODE -eq 0
    }
    if (-not $pullSucceeded -or
        -not (Test-SqlServerContainerImagePresent -Provider $Provider -Image $Image -InspectAction $InspectAction)) {
        throw "SQL_LINUX_CU_IMAGE_PULL_FAILED: $Provider · $Image"
    }
    return [PSCustomObject]@{ Provider = $Provider; Image = $Image; AlreadyPresent = $false }
}

function Get-LabSampleDatabase {
    <#
    .SYNOPSIS
        Sucht Eintraege im Sample-Datenbank-Katalog.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(ParameterSetName = 'ById')]
        [string]$Id,
        [Parameter(ParameterSetName = 'ByName')]
        [string]$Name,
        [Parameter(ParameterSetName = 'ByTag')]
        [string]$Tag,
        [Parameter(ParameterSetName = 'ByCategory')]
        [string]$Category
    )

    if (-not $script:SampleCatalog) {
        $catalogPath = Join-Path $script:CatalogsPath 'sample-databases.json'
        if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
            throw "Sample-Katalog nicht gefunden: $catalogPath"
        }

        $script:SampleCatalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 20
    }

    $databases = @($script:SampleCatalog.databases)

    if ($Id) {
        return $databases | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    }
    if ($Name) {
        return @($databases | Where-Object { $_.name -like "*$Name*" })
    }
    if ($Tag) {
        return @($databases | Where-Object { $_.tags -contains $Tag })
    }
    if ($Category) {
        return @($databases | Where-Object { $_.category -eq $Category })
    }

    return $databases
}

function Get-LabSampleDatabases {
    [CmdletBinding()]
    param(
        [string]$MinVersion
    )

    $all = @(Get-LabSampleDatabase)
    if ($MinVersion) {
        if ($MinVersion -notmatch '^\d{4}$') {
            throw "MinVersion '$MinVersion' ist ungueltig."
        }
        $all = @($all | Where-Object { [int]$_.minSqlVersion -le [int]$MinVersion })
    }

    return @($all | ForEach-Object {
        [PSCustomObject]@{
            Id       = $_.id
            Name     = $_.name
            Category = $_.category
            Tags     = ($_.tags -join ', ')
            Variants = ($_.versions.PSObject.Properties.Name -join ', ')
            License  = $_.license
        }
    })
}

function Get-LabResourceProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('compact', 'standard', 'performance')]
        [string]$Name
    )

    if (-not $script:VersionCatalog -or -not $script:VersionCatalog.profiles) {
        throw 'Katalog/Profile nicht geladen.'
    }

    $profile = $script:VersionCatalog.profiles.$Name
    if (-not $profile) {
        throw "Profil '$Name' nicht gefunden."
    }

    return $profile
}
