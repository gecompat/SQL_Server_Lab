function Set-SqlServerLabLicenseProfile {
    <#
    .SYNOPSIS
        Speichert einen Product Key als lokales, geschuetztes Lizenzprofil.
    .DESCRIPTION
        Der Product Key wird ausserhalb des Repositorys im lokalen State Root
        mit dem bestehenden Windows-DPAPI-Vertrag gespeichert. Ausgaben und
        Metadaten enthalten weder den Key noch Fragmente davon. Evaluation,
        Developer und Express benoetigen kein Lizenzprofil.
    .PARAMETER Id
        Stabile lokale Profil-ID, die spaeter ausdruecklich ausgewaehlt wird.
    .PARAMETER Product
        SqlServer oder Windows.
    .PARAMETER Version
        Produktversion, beispielsweise 2016, 10 oder 11.
    .PARAMETER Edition
        Zum Product Key passende Edition.
    .PARAMETER Channel
        Bekannter Beschaffungs- beziehungsweise Aktivierungskanal.
    .PARAMETER Key
        Product Key als SecureString. Der Wert wird nie ausgegeben.
    .PARAMETER Force
        Ersetzt ein vorhandenes Profil derselben ID atomar.
    .PARAMETER StateRoot
        Optionaler lokaler State Root; primär für isolierte Tests und
        kontrollierte Hostkonfigurationen.
    .EXAMPLE
        $key = Read-Host 'Product Key' -AsSecureString
        Set-SqlServerLabLicenseProfile -Id sql2016-standard-01 -Product SqlServer -Version 2016 -Edition Standard -Channel Volume -Key $key
    .OUTPUTS
        PSCustomObject mit geheimnisfreien Profilmetadaten und Status.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9.-]{2,63}$')][string]$Id,
        [Parameter(Mandatory)][ValidateSet('SqlServer', 'Windows')][string]$Product,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$')][string]$Version,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9 ._-]{1,63}$')][string]$Edition,
        [Parameter(Mandatory)][ValidateSet('Retail', 'OEM', 'MAK', 'KMS', 'ADBA', 'Volume', 'VisualStudio', 'Other')][string]$Channel,
        [Parameter(Mandatory)][SecureString]$Key,
        [switch]$Force,
        [string]$StateRoot
    )

    if (-not $IsWindows) { throw 'LICENSE_PROFILE_WINDOWS_DPAPI_REQUIRED' }
    if (-not (Test-LabProductKeyFormat -Key $Key)) { throw 'LICENSE_PROFILE_KEY_FORMAT_INVALID' }
    $canonicalEdition = ConvertTo-LabLicenseEdition -Product $Product -Edition $Edition
    $root = Get-LabLicenseProfileRoot -StateRoot $StateRoot -Ensure
    $target = Join-Path $root $Id
    $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    if ($targetItem -and (-not $targetItem.PSIsContainer -or ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw "LICENSE_PROFILE_PATH_UNSAFE: $Id"
    }
    if ((Test-Path -LiteralPath $target) -and -not $Force) { throw "LICENSE_PROFILE_ALREADY_EXISTS: $Id" }
    if (-not $PSCmdlet.ShouldProcess($Id, 'Lokales DPAPI-geschuetztes Lizenzprofil speichern')) {
        return [PSCustomObject]@{ ContractVersion='SqlServerLab.LicenseProfileResult/1.0'; Id=$Id; Status='PLANNED'; Product=$Product; Version=$Version; Edition=$canonicalEdition; Channel=$Channel; KeyAvailable=$false }
    }

    $staging = Join-Path $root ('.staging-' + [guid]::NewGuid().ToString('N'))
    $backup = Join-Path $root ('.backup-' + [guid]::NewGuid().ToString('N'))
    $existingMetadata = @(Get-LabLicenseProfileMetadata -Id $Id -StateRoot $StateRoot | Select-Object -First 1)
    $now = Get-LabTimestamp
    try {
        $null = New-Item -Path $staging -ItemType Directory -Force
        Save-LabSecret -Path $staging -Name 'product-key' -Secret $Key
        Write-LabArtifactJsonAtomic -Path (Join-Path $staging 'metadata.json') -InputObject ([PSCustomObject][ordered]@{
            contractVersion = 'SqlServerLab.LicenseProfile/1.0'
            id = $Id; product = $Product; version = $Version; edition = $canonicalEdition; channel = $Channel
            createdAt = if ($existingMetadata.Count -eq 1) { [string]$existingMetadata[0].createdAt } else { $now }
            updatedAt = $now
        })
        if (Test-Path -LiteralPath $target -PathType Container) {
            [IO.Directory]::Move($target, $backup)
        }
        try { [IO.Directory]::Move($staging, $target) }
        catch {
            if (Test-Path -LiteralPath $backup -PathType Container) { [IO.Directory]::Move($backup, $target) }
            throw
        }
        if (Test-Path -LiteralPath $backup -PathType Container) {
            Remove-LabSecrets -Path $backup
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
        return Get-SqlServerLabLicenseProfile -Id $Id -StateRoot $StateRoot
    }
    finally {
        if (Test-Path -LiteralPath $staging -PathType Container) {
            Remove-LabSecrets -Path $staging
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-SqlServerLabLicenseProfile {
    <#
    .SYNOPSIS
        Listet lokale Lizenzprofile ohne geheime Werte auf.
    .DESCRIPTION
        Liefert nur Produkt-, Editions- und Kanalmetadaten sowie die Aussage,
        ob eine geschuetzte Secretdatei vorhanden ist. Key-Fragmente, lokale
        Pfade und entschluesselte Werte werden nicht ausgegeben.
    .PARAMETER Id
        Optionale exakte Profil-ID.
    .PARAMETER StateRoot
        Optionaler lokaler State Root; primär für isolierte Tests und
        kontrollierte Hostkonfigurationen.
    .EXAMPLE
        Get-SqlServerLabLicenseProfile
    .OUTPUTS
        PSCustomObject je lokalem Lizenzprofil, ohne Product Key oder Pfad.
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^[a-z][a-z0-9.-]{2,63}$')][string]$Id,
        [string]$StateRoot
    )

    $metadataArguments = @{ StateRoot = $StateRoot }
    if (-not [string]::IsNullOrWhiteSpace($Id)) { $metadataArguments.Id = $Id }
    foreach ($metadata in @(Get-LabLicenseProfileMetadata @metadataArguments)) {
        $profilePath = Get-LabLicenseProfilePath -Id ([string]$metadata.id) -StateRoot $StateRoot
        [PSCustomObject][ordered]@{
            ContractVersion = 'SqlServerLab.LicenseProfileResult/1.0'
            Id = [string]$metadata.id; Status = 'READY'; Product = [string]$metadata.product
            Version = [string]$metadata.version; Edition = [string]$metadata.edition; Channel = [string]$metadata.channel
            KeyAvailable = Test-Path -LiteralPath (Join-Path $profilePath 'secrets/product-key.secret') -PathType Leaf
            CreatedAt = [string]$metadata.createdAt; UpdatedAt = [string]$metadata.updatedAt
        }
    }
}

function Test-SqlServerLabLicenseProfile {
    <#
    .SYNOPSIS
        Prueft Metadaten, Secretverfuegbarkeit und das lokale Keyformat.
    .DESCRIPTION
        Die Pruefung kontaktiert keinen Aktivierungsdienst und verbraucht keine
        Aktivierung. READY bedeutet ausschliesslich, dass das lokale Profil
        strukturell verwendbar ist.
    .PARAMETER Id
        Exakte lokale Profil-ID.
    .PARAMETER StateRoot
        Optionaler lokaler State Root; primär für isolierte Tests und
        kontrollierte Hostkonfigurationen.
    .EXAMPLE
        Test-SqlServerLabLicenseProfile -Id sql2016-standard-01
    .OUTPUTS
        PSCustomObject mit strukturellem Prüfstatus; keine Aktivierungsaussage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9.-]{2,63}$')][string]$Id,
        [string]$StateRoot
    )

    $profile = Resolve-LabLicenseProfile -Id $Id -StateRoot $StateRoot
    [PSCustomObject][ordered]@{
        ContractVersion = 'SqlServerLab.LicenseProfileTest/1.0'; Id = [string]$profile.id
        Status = 'READY'; MetadataValid = $true; KeyAvailable = $true; KeyFormatValid = $true
        OnlineActivationTested = $false
    }
}

function Remove-SqlServerLabLicenseProfile {
    <#
    .SYNOPSIS
        Entfernt ein exaktes lokales Lizenzprofil.
    .DESCRIPTION
        Ueberschreibt und entfernt die geschuetzte Secretdatei und loescht
        danach ausschliesslich das exakt ausgewaehlte Profilverzeichnis.
    .PARAMETER Id
        Exakte lokale Profil-ID.
    .PARAMETER StateRoot
        Optionaler lokaler State Root; primär für isolierte Tests und
        kontrollierte Hostkonfigurationen.
    .EXAMPLE
        Remove-SqlServerLabLicenseProfile -Id sql2016-standard-01
    .OUTPUTS
        PSCustomObject mit `REMOVED`, `NOT_FOUND` oder `PLANNED`.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9.-]{2,63}$')][string]$Id,
        [string]$StateRoot
    )

    $profilePath = Get-LabLicenseProfilePath -Id $Id -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) {
        return [PSCustomObject]@{ ContractVersion='SqlServerLab.LicenseProfileResult/1.0'; Id=$Id; Status='NOT_FOUND' }
    }
    $profileItem = Get-Item -LiteralPath $profilePath -Force -ErrorAction Stop
    if ($profileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "LICENSE_PROFILE_PATH_UNSAFE: $Id"
    }
    if (-not $PSCmdlet.ShouldProcess($Id, 'Lokales Lizenzprofil dauerhaft entfernen')) {
        return [PSCustomObject]@{ ContractVersion='SqlServerLab.LicenseProfileResult/1.0'; Id=$Id; Status='PLANNED' }
    }
    Remove-LabSecrets -Path $profilePath
    Remove-Item -LiteralPath $profilePath -Recurse -Force
    [PSCustomObject]@{ ContractVersion='SqlServerLab.LicenseProfileResult/1.0'; Id=$Id; Status='REMOVED' }
}
