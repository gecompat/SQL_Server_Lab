<#
.SYNOPSIS
    Katalogzugriff fuer SQL-Server-Versionen, Builds, Ressourcenprofile und Sample-Datenbanken.
.DESCRIPTION
    Liest die beim Modulimport geladenen Kataloge und stellt interne Aufloesungsfunktionen bereit.
#>

function Get-SqlServerVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VersionId
    )

    if (-not $script:VersionCatalog) {
        throw 'Versionskatalog nicht geladen.'
    }

    $exact = $script:VersionCatalog.versions | Where-Object { $_.id -eq $VersionId } | Select-Object -First 1
    if ($exact) {
        return $exact
    }

    if ($VersionId -match '^(\d{4})(?:-|$)') {
        $baseVersion = $Matches[1]
        return $script:VersionCatalog.versions | Where-Object { $_.id -eq $baseVersion } | Select-Object -First 1
    }

    return $null
}

function Test-SqlServerVersionSupported {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VersionId,
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
            $ok = $AllowDeprecated.IsPresent
            $message = if ($ok) { 'Veraltete Version wurde ausdruecklich zugelassen.' } else { 'Veraltet. -AllowDeprecated verwenden.' }
            return [PSCustomObject]@{ Supported = $ok; Status = 'DEPRECATED'; Message = $message }
        }
        'RETIRED' {
            $ok = $AllowRetired.IsPresent
            $message = if ($ok) { 'Nicht mehr gepflegte Version wurde ausdruecklich zugelassen.' } else { 'Nicht mehr gepflegt. -AllowRetired verwenden.' }
            return [PSCustomObject]@{ Supported = $ok; Status = 'RETIRED'; Message = $message }
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
        Loest einen Versionsbezeichner in ein SQL-Server-Container-Image auf.
    .DESCRIPTION
        Unterstuetzte Formate:
        - 2022
        - 2022-CU16
        - 2022-CU16-ubuntu-22.04
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VersionId
    )

    if ($VersionId -match '^\d{4}-CU\d+-.+$') {
        return "mcr.microsoft.com/mssql/server:$VersionId"
    }

    if ($VersionId -match '^(\d{4})-(CU\d+)$') {
        $baseVersion = $Matches[1]
        $cuId = $Matches[2]
        $version = Get-SqlServerVersion -VersionId $baseVersion

        if (-not $version -or -not $version.docker) {
            throw "Kein Docker-Image fuer Basisversion '$baseVersion'."
        }

        $build = $version.docker.builds | Where-Object { $_.cu -eq $cuId } | Select-Object -First 1
        if ($build) {
            return "mcr.microsoft.com/mssql/server:$($build.tag)"
        }

        throw "Build '$VersionId' ist nicht im Versionskatalog enthalten."
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
        [Parameter(Mandatory)]
        [string]$VersionId
    )

    $version = Get-SqlServerVersion -VersionId $VersionId
    if (-not $version -or -not $version.docker -or -not $version.docker.builds) {
        return @()
    }

    return @($version.docker.builds)
}

function Get-LabSampleDatabase {
    <#
    .SYNOPSIS
        Sucht Eintraege im Sample-Datenbank-Katalog.
    #>
    [CmdletBinding(DefaultParameterSetName = 'All')]
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
        if (-not (Test-Path $catalogPath)) {
            throw "Sample-Katalog nicht gefunden: $catalogPath"
        }

        $script:SampleCatalog = Get-Content $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
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
