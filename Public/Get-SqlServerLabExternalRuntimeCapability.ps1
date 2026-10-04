function Get-SqlServerLabExternalRuntimeCapability {
    <#
    .SYNOPSIS
        Bewertet eine explizite External-Languages-Kataloganforderung für einen Manifestentwurf.
    .DESCRIPTION
        Trennt Katalogunterstützung von optionaler aktueller Docker-/Podman-Hostbereitschaft.
        Standardmäßig wird kein Hostwerkzeug aufgerufen. CheckProviderReadiness liest einmal
        begrenzt info und prüft Linux, cgroup und rootful für genau den Launchmodus.
        READY bestätigt weder SQL-/Sprachausführung noch Zielbesitz oder Ausführungsrechte.
        Es werden keine Runs, Images oder Ressourcen erstellt und keine Daten persistiert.
    .PARAMETER SqlVersion
        Explizite SQL-Katalogversion der zukünftigen Instanz.
    .PARAMETER Provider
        Explizit docker oder podman; keine automatische Providerauswahl.
    .PARAMETER OperatingSystem
        Linux als explizites Containerziel.
    .PARAMETER SoftwareId
        sql-python, sql-r oder sql-java. C# gehört nicht zu diesem Vertrag.
    .PARAMETER RuntimeVersion
        Angeforderte Runtimeversion aus dem vorhandenen Softwarekatalog.
    .PARAMETER VariantId
        Exakte Katalogvariante; reduzierter SQL-2025-Isolationsmodus bleibt opt-in.
    .PARAMETER CheckProviderReadiness
        Bewusste einmalige read-only Hostprüfung; keine Runtime wird gestartet.
    .PARAMETER IncludeRecordedEvidence
        Opt-in: exakte historische Identität aus dem bestehenden Index; keine aktuelle Readiness.
    .EXAMPLE
        Get-SqlServerLabExternalRuntimeCapability -SqlVersion 2022 -Provider docker -OperatingSystem linux -SoftwareId sql-python -RuntimeVersion 3.10 -VariantId sql2022-python310-ubuntu2204-derived
    .OUTPUTS
        SqlServerLab.ExternalRuntimeCapability/1.0; mit IncludeRecordedEvidence Version 1.1, vollständige Antwort maximal 256 KiB UTF-8.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$OperatingSystem,
        [Parameter(Mandatory)][string]$SoftwareId,
        [Parameter(Mandatory)][string]$RuntimeVersion,
        [Parameter(Mandatory)][string]$VariantId,
        [switch]$CheckProviderReadiness,
        [switch]$IncludeRecordedEvidence
    )
    # Validate/catalog-resolve before optional native observation, never echo raw inputs/errors.
    $decision=New-LabExternalRuntimeCapabilityDecision -SqlVersion $SqlVersion -Provider $Provider -OperatingSystem $OperatingSystem `
        -SoftwareId $SoftwareId -RuntimeVersion $RuntimeVersion -VariantId $VariantId -IncludeRecordedEvidence:$IncludeRecordedEvidence
    if($CheckProviderReadiness -and $decision.CatalogDecision.Status -ceq 'DECLARED_SUPPORTED') {
        $observation=Read-LabExternalRuntimeHostFacts -Provider $Provider
        $decision=New-LabExternalRuntimeCapabilityDecision -SqlVersion $SqlVersion -Provider $Provider -OperatingSystem $OperatingSystem `
            -SoftwareId $SoftwareId -RuntimeVersion $RuntimeVersion -VariantId $VariantId -IncludeRecordedEvidence:$IncludeRecordedEvidence -HostObservation $observation
    }
    return $decision
}
