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
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VersionId)
    $version = Get-SqlServerVersion -VersionId $VersionId
    if (-not $version -or -not $version.docker) { throw "Kein Docker-Image fuer '$VersionId'." }
    $version.docker.image
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
