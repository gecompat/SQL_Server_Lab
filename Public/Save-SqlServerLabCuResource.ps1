function Save-SqlServerLabCuResource {
    <#
    .SYNOPSIS
        Lädt einen katalogisierten SQL-Server-CU für Windows oder Linux.
    .DESCRIPTION
        Windows-Pakete werden ausschließlich aus der katalogisierten
        Microsoft-Update-Catalog-Quelle in den Media Root geladen. Vor der
        Veröffentlichung prüft das Cmdlet SHA-256, Authenticode-Status und den
        Microsoft-Signer. Linux verwendet den expliziten unveränderlichen
        MCR-Tag und zieht ihn in den lokalen Docker- oder Podman-Imagecache.

        Bereits vorhandene Ressourcen werden erneut geprüft und nicht
        überschrieben. Containerimages bleiben als wiederverwendbarer lokaler
        Runtimecache erhalten.
    .PARAMETER SqlVersion
        SQL-Server-Produktjahr aus dem Versionskatalog, zum Beispiel 2022.
    .PARAMETER Cu
        Katalogisierter CU-Kurzbezeichner, zum Beispiel CU18.
    .PARAMETER Platform
        Windows lädt das x64-Updatepaket in den Media Root. Linux lädt den
        exakten MCR-Container-Tag.
    .PARAMETER Provider
        Container-Runtime für Linux. Auto bevorzugt Docker vor Podman. Für
        Windows muss Auto verwendet werden.
    .PARAMETER MediaRoot
        Zielroot für Windows. Ohne Angabe verwendet das Cmdlet den lokal
        konfigurierten SQL_Server_Lab Media Root.
    .EXAMPLE
        Save-SqlServerLabCuResource -SqlVersion 2022 -Cu CU18 -Platform Windows -MediaRoot 'D:\Lab_Base'
    .EXAMPLE
        Save-SqlServerLabCuResource -SqlVersion 2019 -Cu CU6 -Platform Linux -Provider Docker
    .OUTPUTS
        PSCustomObject mit Vertrag, Status, CU, Plattform, Provider,
        Ressourcenbezeichner und AlreadyPresent.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\d{4}$')]
        [string]$SqlVersion,

        [Parameter(Mandatory)]
        [ValidatePattern('^CU[1-9]\d*$')]
        [string]$Cu,

        [Parameter(Mandatory)]
        [ValidateSet('Windows', 'Linux')]
        [string]$Platform,

        [ValidateSet('Auto', 'Docker', 'Podman')]
        [string]$Provider = 'Auto',

        [string]$MediaRoot
    )

    $normalizedCu = $Cu.ToUpperInvariant()
    $versionId = "$SqlVersion-$normalizedCu"
    if ($Platform -eq 'Windows') {
        if ($Provider -ne 'Auto') {
            throw 'SQL_WINDOWS_CU_PROVIDER_NOT_APPLICABLE: Für Windows muss -Provider Auto verwendet werden.'
        }
        if ([string]::IsNullOrWhiteSpace($MediaRoot)) { $MediaRoot = Get-LabMediaRootDefault }
        if ([string]::IsNullOrWhiteSpace($MediaRoot)) {
            throw 'SQL_WINDOWS_CU_MEDIA_ROOT_REQUIRED: -MediaRoot angeben oder den Media Root im Lab konfigurieren.'
        }

        $patch = Get-SqlServerPatchOption -VersionId $SqlVersion -Cu $normalizedCu -MediaRoot $MediaRoot
        $target = [string]$patch.WindowsPath
        $alreadyPresent = Test-Path -LiteralPath $target -PathType Leaf
        if (-not $alreadyPresent -and -not $PSCmdlet.ShouldProcess($target, "SQL Server $versionId herunterladen und verifizieren")) {
            return [PSCustomObject][ordered]@{
                Contract = 'SqlServerLab.CuResource/1.0'; Status = 'PLANNED'; VersionId = $versionId
                Platform = 'Windows'; Provider = $null; Resource = $target; AlreadyPresent = $false
            }
        }
        $path = Save-SqlServerWindowsPatchPackage -Patch $patch -MediaRoot $MediaRoot
        return [PSCustomObject][ordered]@{
            Contract = 'SqlServerLab.CuResource/1.0'; Status = 'READY'; VersionId = $versionId
            Platform = 'Windows'; Provider = $null; Resource = $path; AlreadyPresent = [bool]$alreadyPresent
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($MediaRoot)) {
        throw 'SQL_LINUX_CU_MEDIA_ROOT_NOT_APPLICABLE: Linux-CU-Images werden im Runtimecache gespeichert.'
    }
    $patch = Get-SqlServerPatchOption -VersionId $SqlVersion -Cu $normalizedCu
    $image = Get-SqlServerDockerImage -VersionId $versionId
    $resolvedProvider = Resolve-SqlServerContainerImageProvider -Provider $Provider.ToLowerInvariant()
    $alreadyPresent = Test-SqlServerContainerImagePresent -Provider $resolvedProvider -Image $image
    if (-not $alreadyPresent -and -not $PSCmdlet.ShouldProcess("$resolvedProvider image cache", "$image herunterladen")) {
        return [PSCustomObject][ordered]@{
            Contract = 'SqlServerLab.CuResource/1.0'; Status = 'PLANNED'; VersionId = $versionId
            Platform = 'Linux'; Provider = $resolvedProvider; Resource = $image; AlreadyPresent = $false
        }
    }
    $result = Save-SqlServerContainerImageResource -Provider $resolvedProvider -Image $image
    return [PSCustomObject][ordered]@{
        Contract = 'SqlServerLab.CuResource/1.0'; Status = 'READY'; VersionId = $versionId
        Platform = 'Linux'; Provider = $resolvedProvider; Resource = $image; AlreadyPresent = [bool]$result.AlreadyPresent
    }
}
