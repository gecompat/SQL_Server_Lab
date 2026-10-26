function Get-SqlServerLabHostCapabilityMatrix {
    <#
    .SYNOPSIS
        Zeigt die katalogbasierte External-Languages-Hostmatrix vor einer Funktionsauswahl.
    .DESCRIPTION
        Trennt geladene Katalogdeklaration, Providerinstallation und optionale aktuelle
        Providerbereitschaft. Standardmäßig werden keine Provider abgefragt. Die bewusste
        Prüfung verwendet je Provider einmal den bestehenden begrenzten Readiness-Worker.
        Erreichbarkeit ist kein Launch-, SQL-, Sprach- oder Herstellerfreigabenachweis.
        Fehlende Prüfung bleibt sichtbar; C# bleibt durch Benutzerentscheidung zurückgestellt.
        Kein Ergebnis erteilt Ausführungsrechte oder darf vor einer Mutation als Cache dienen.
    .PARAMETER SqlVersion
        Exakte ID aus dem geladenen SQL-Versionskatalog.
    .PARAMETER Provider
        Auswahl aus docker, podman und hyperv; Standard ist die vollständige Übersicht.
        Eine Teilmenge kann kein vollständiges Installationsprofil beweisen.
    .PARAMETER CheckProviderReadiness
        Bewusste read-only Prüfung ohne Start, Installation oder Konfigurationsänderung.
        Pro Provider höchstens 45 Sekunden plus fünf Sekunden Prozessbeendigung.
    .EXAMPLE
        Get-SqlServerLabHostCapabilityMatrix -SqlVersion 2022
    .EXAMPLE
        Get-SqlServerLabHostCapabilityMatrix -SqlVersion 2022 -CheckProviderReadiness
    .OUTPUTS
        SqlServerLab.HostCapabilityMatrix/1.0. Bootstrap- und Katalogübersicht ohne Aktionsfreigabe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlVersion,
        [ValidateSet('docker','podman','hyperv')][ValidateCount(1,3)][string[]]$Provider=@('docker','podman','hyperv'),
        [switch]$CheckProviderReadiness
    )
    $hostOperatingSystem=if($IsWindows){'windows'}elseif($IsLinux){'linux'}else{'unknown'}
    New-LabHostCapabilityMatrix -SqlVersion $SqlVersion -Provider $Provider -HostOperatingSystem $hostOperatingSystem -CheckProviderReadiness:$CheckProviderReadiness
}
