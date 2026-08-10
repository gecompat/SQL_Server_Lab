function Get-SqlServerLabCatalog {
    <#
    .SYNOPSIS
        Erzeugt den SQL_Server_Lab-Katalog als persistentes JSON-Artefakt.
    .DESCRIPTION
        Aggregiert die aktuelle `Get-SqlServerLabWorkflow`-Sicht inkl. aktiver
        Labs, Windows-/SQL-Imagestatus und Betriebsmetadaten und schreibt sie
        atomar als Maschinenkatalog in den State-Root.
        Der Katalog enthält keine geheimen Werte.
    .PARAMETER Path
        Zielpfad der Katalog-Datei. Standard: `<StateRoot>\catalog\sql-server-lab-catalog.json`.
    .PARAMETER StateRoot
        Optionaler abweichender Lab-State-Root.
    .PARAMETER MediaRoot
        Optionaler Medienpfad für die im Katalog enthaltene Medienauflistung.
    .OUTPUTS
        PSCustomObject. Enthält Kataloginhalt und den Pfad der geschriebenen Datei.
    .EXAMPLE
        Get-SqlServerLabCatalog
    .EXAMPLE
        Get-SqlServerLabCatalog -Path 'D:\state\catalog\katalog.json'
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$StateRoot,
        [string]$MediaRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $stateRoot = Initialize-LabStateRoot -StateRoot $StateRoot
    if (-not $Path) {
        $Path = Join-Path (Join-Path $stateRoot 'catalog') 'sql-server-lab-catalog.json'
    }

    $workflow = Get-SqlServerLabWorkflow -MediaRoot $MediaRoot
    $build = Get-LabBuildInfo
    $catalog = [PSCustomObject]@{
        CatalogFormat = '1'
        GeneratedAt = Get-LabTimestamp
        Module = [PSCustomObject]@{
            Version = [string]$build.Version
            Revision = [string]$build.Revision
            Source = [string]$build.Source
        }
        StateRoot = $stateRoot
        MediaRoot = $workflow.Defaults.MediaRoot
        GeneratedBy = 'Get-SqlServerLabCatalog'
        Summary = $workflow.Summary
        Workflow = $workflow
    }

    Write-LabArtifactJsonAtomic -Path $Path -InputObject $catalog
    return [PSCustomObject]@{
        Path = $Path
        GeneratedAt = $catalog.GeneratedAt
        Catalog = $catalog
    }
}
