<#
.SYNOPSIS
    Versionskatalog-Zugriff fuer SQL_Server_Lab.
.DESCRIPTION
    Liest und validiert SQL-Server-Versionen aus dem Katalog.
#>

function Get-SqlServerVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VersionId)
    if (-not $script:VersionCatalog) { throw "Versionskatalog nicht geladen." }
    $script:VersionCatalog.versions | Where-Object { $_.id -eq $VersionId }
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
        return [PSCustomObject]@{ Supported = $false; Status = 'UNKNOWN'; Message = "Version '$VersionId' nicht im Katalog." }
    }
    switch ($version.status) {
        'SUPPORTED' { return [PSCustomObject]@{ Supported = $true;  Status = 'SUPPORTED'; Message = '' } }
        'PREVIEW'   { return [PSCustomObject]@{ Supported = $true;  Status = 'PREVIEW';   Message = "Vorabversion." } }
        'DEPRECATED' {
            $ok = $AllowDeprecated.IsPresent
            return [PSCustomObject]@{ Supported = $ok; Status = 'DEPRECATED'; Message = "Veraltet.$(if(-not $ok){' -AllowDeprecated verwenden.'})" }
        }
        'RETIRED' {
            $ok = $AllowRetired.IsPresent
            return [PSCustomObject]@{ Supported = $ok; Status = 'RETIRED'; Message = "Nicht mehr gepflegt.$(if(-not $ok){' -AllowRetired verwenden.'})" }
        }
        'BLOCKED' { return [PSCustomObject]@{ Supported = $false; Status = 'BLOCKED'; Message = "Blockiert (Sicherheitsrisiko)." } }
        default   { return [PSCustomObject]@{ Supported = $false; Status = $version.status; Message = "Unbekannter Status." } }
    }
}

function Get-SqlServerVersions {
    [CmdletBinding()]
    param(
        [ValidateSet('SUPPORTED','PREVIEW','DEPRECATED','RETIRED','BLOCKED','ALL')]
        [string]$Status = 'ALL'
    )
    if (-not $script:VersionCatalog) { throw "Versionskatalog nicht geladen." }
    if ($Status -eq 'ALL') { return $script:VersionCatalog.versions }
    $script:VersionCatalog.versions | Where-Object { $_.status -eq $Status }
}

function Get-SqlServerDockerImage {
    <#
    .SYNOPSIS Loest Docker-Image-Tag auf (inkl. CU-spezifisch).
    .DESCRIPTION
        Unterstuetzte Formate:
        - '2022'         -> mcr.microsoft.com/mssql/server:2022-latest
        - '2022-CU16'    -> mcr.microsoft.com/mssql/server:2022-CU16-ubuntu-22.04
        - '2022-CU16-ubuntu-22.04' -> exakt dieser Tag (passthrough)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VersionId)

    # Pruefen ob CU-spezifisch (z.B. '2022-CU16')
    if ($VersionId -match '^(\d{4})-(CU\d+)

function Get-LabResourceProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('compact','standard','performance')]
        [string]$Name
    )
    if (-not $script:VersionCatalog -or -not $script:VersionCatalog.profiles) {
        throw "Katalog/Profile nicht geladen."
    }
    $profile = $script:VersionCatalog.profiles.$Name
    if (-not $profile) { throw "Profil '$Name' nicht gefunden." }
    $profile
}
) {
        $baseVersion = $Matches[1]
        $cuId = $Matches[2]
        $version = Get-SqlServerVersion -VersionId $baseVersion
        if (-not $version -or -not $version.docker) {
            throw "Kein Docker-Image fuer Basisversion '$baseVersion'."
        }
        # Suche im builds-Array
        $build = $version.docker.builds | Where-Object { $_.cu -eq $cuId }
        if ($build) {
            return "mcr.microsoft.com/mssql/server:$($build.tag)"
        }
        # Fallback: Standard-Tag-Konvention
        Write-LabWarning "$cuId nicht im Katalog, verwende Standard-Tag-Konvention."
        return "mcr.microsoft.com/mssql/server:$VersionId-ubuntu-22.04"
    }

    # Exakter Tag (Passthrough, z.B. '2022-CU16-ubuntu-22.04')
    if ($VersionId -match '^\d{4}-CU\d+-') {
        return "mcr.microsoft.com/mssql/server:$VersionId"
    }

    # Standard: Basisversion (z.B. '2022' -> latest)
    $version = Get-SqlServerVersion -VersionId $VersionId
    if (-not $version -or -not $version.docker) { throw "Kein Docker-Image fuer '$VersionId'." }
    $version.docker.image
}

function Get-SqlServerBuilds {
    <#
    .SYNOPSIS Listet verfuegbare CU-Builds fuer eine SQL-Server-Version.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VersionId
    )
    $version = Get-SqlServerVersion -VersionId $VersionId
    if (-not $version -or -not $version.docker -or -not $version.docker.builds) {
        return @()
    }
    $version.docker.builds
}

function Get-LabSampleDatabase {
    <#
    .SYNOPSIS Sucht eine Test-Datenbank im Sample-Katalog.
    .DESCRIPTION
        Sucht nach ID, Name oder Tags. Gibt Metadaten + Download-URL zurueck.
    .EXAMPLE
        Get-LabSampleDatabase -Id 'adventureworks-2022'
        Get-LabSampleDatabase -Tag 'performance'
        Get-LabSampleDatabase -Name 'WideWorldImporters'
    #>
    [CmdletBinding(DefaultParameterSetName='ById')]
    param(
        [Parameter(ParameterSetName='ById')][string]$Id,
        [Parameter(ParameterSetName='ByName')][string]$Name,
        [Parameter(ParameterSetName='ByTag')][string]$Tag,
        [Parameter(ParameterSetName='ByCategory')][string]$Category
    )

    if (-not $script:SampleCatalog) {
        $catalogPath = Join-Path $PSScriptRoot '..\Catalogs\sample-databases.json'
        if (Test-Path $catalogPath) {
            $script:SampleCatalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
        } else {
            throw "Sample-Katalog nicht gefunden: $catalogPath"
        }
    }

    $dbs = $script:SampleCatalog.databases
    if ($Id)       { return $dbs | Where-Object { $_.id -eq $Id } }
    if ($Name)     { return $dbs | Where-Object { $_.name -like "*$Name*" } }
    if ($Tag)      { return $dbs | Where-Object { $_.tags -contains $Tag } }
    if ($Category) { return $dbs | Where-Object { $_.category -eq $Category } }
    return $dbs
}

function Get-LabSampleDatabases {
    <#
    .SYNOPSIS Listet alle verfuegbaren Test-Datenbanken.
    #>
    [CmdletBinding()]
    param(
        [string]$MinVersion
    )
    $all = Get-LabSampleDatabase
    if ($MinVersion) {
        $all = $all | Where-Object { [int]($_.minSqlVersion) -le [int]$MinVersion }
    }
    $all | ForEach-Object {
        [PSCustomObject]@{
            Id          = $_.id
            Name        = $_.name
            Category    = $_.category
            Tags        = ($_.tags -join ', ')
            Variants    = ($_.versions.PSObject.Properties.Name -join ', ')
            License     = $_.license
        }
    }
}

function Get-LabResourceProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('compact','standard','performance')]
        [string]$Name
    )
    if (-not $script:VersionCatalog -or -not $script:VersionCatalog.profiles) {
        throw "Katalog/Profile nicht geladen."
    }
    $profile = $script:VersionCatalog.profiles.$Name
    if (-not $profile) { throw "Profil '$Name' nicht gefunden." }
    $profile
}
