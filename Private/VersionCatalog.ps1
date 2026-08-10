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

function Confirm-SqlServerWindowsPatchPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Patch)

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
    return $Patch.WindowsPath
}

function Save-SqlServerWindowsPatchPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Patch,
        [Parameter(Mandatory)][string]$MediaRoot
    )

    if (-not $Patch.CanAutoDownload) {
        throw "SQL_WINDOWS_CU_AUTODOWNLOAD_NOT_TRUSTED: $($Patch.Cu)"
    }
    $target = Join-Path $MediaRoot ([string]$Patch.WindowsRelativePath).Replace('/', [IO.Path]::DirectorySeparatorChar)
    $targetDirectory = Split-Path -Parent $target
    $null = New-Item -ItemType Directory -Path $targetDirectory -Force
    $temporary = "$target.download"
    try {
        Invoke-WebRequest -Uri $Patch.DownloadUrl -OutFile $temporary -UseBasicParsing -ErrorAction Stop
        $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($actual -ne [string]$Patch.Sha256) { throw "SQL_WINDOWS_CU_DOWNLOAD_HASH_MISMATCH: $($Patch.Cu)" }
        Move-Item -LiteralPath $temporary -Destination $target -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    return $target
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
