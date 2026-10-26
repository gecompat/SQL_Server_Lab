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
    .PARAMETER IncludeHostPrerequisites
        Opt-in Version 1.2: Controller, Profil-Gesamtkapazitaet und Grenzen des gemeinsamen Kernels.
        Ohne CheckProviderReadiness keine Hostabfrage; mit Pruefung weiterhin genau ein info-Aufruf.
    .PARAMETER ResourceProfile
        Vorhandenes Katalogprofil, nur mit IncludeHostPrerequisites ausgewertet; Default standard.
    .EXAMPLE
        Get-SqlServerLabExternalRuntimeCapability -SqlVersion 2022 -Provider docker -OperatingSystem linux -SoftwareId sql-python -RuntimeVersion 3.10 -VariantId sql2022-python310-ubuntu2204-derived
    .OUTPUTS
        SqlServerLab.ExternalRuntimeCapability/1.0; mit IncludeRecordedEvidence 1.1;
        mit IncludeHostPrerequisites 1.2, vollstaendige Antwort maximal 256 KiB UTF-8.
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
        [switch]$IncludeRecordedEvidence,
        [switch]$IncludeHostPrerequisites,
        [ValidatePattern('^[a-z][a-z0-9-]{0,31}$')][string]$ResourceProfile='standard'
    )
    # Validate/catalog-resolve before optional native observation, never echo raw inputs/errors.
    $decision=New-LabExternalRuntimeCapabilityDecision -SqlVersion $SqlVersion -Provider $Provider -OperatingSystem $OperatingSystem `
        -SoftwareId $SoftwareId -RuntimeVersion $RuntimeVersion -VariantId $VariantId -IncludeRecordedEvidence:$IncludeRecordedEvidence
    $requirements=$null;$observation=$null
    if($IncludeHostPrerequisites){
        try{$requirements=Get-LabResourceProfile -Name $ResourceProfile}catch{throw 'EXTERNAL_RUNTIME_RESOURCE_PROFILE_INVALID'}
        $ResourceProfile=$ResourceProfile.ToLowerInvariant()
    }
    if($CheckProviderReadiness -and $decision.CatalogDecision.Status -ceq 'DECLARED_SUPPORTED') {
        $observation=if($IncludeHostPrerequisites){Read-LabExternalRuntimeHostFacts -Provider $Provider -IncludeHostPrerequisites}
            else{Read-LabExternalRuntimeHostFacts -Provider $Provider}
        $decision=New-LabExternalRuntimeCapabilityDecision -SqlVersion $SqlVersion -Provider $Provider -OperatingSystem $OperatingSystem `
            -SoftwareId $SoftwareId -RuntimeVersion $RuntimeVersion -VariantId $VariantId -IncludeRecordedEvidence:$IncludeRecordedEvidence -HostObservation $observation
    }
    if($IncludeHostPrerequisites){
        return Add-LabExternalRuntimeHostPrerequisites -Decision $decision -ResourceProfile $ResourceProfile -Requirements $requirements -HostObservation $observation
    }
    return $decision
}
