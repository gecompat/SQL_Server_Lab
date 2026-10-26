# Hostbezogene Fähigkeitsübersicht

## Zweck und Einstieg

`Get-SqlServerLabHostCapabilityMatrix -SqlVersion 2022` ist der erste
providerübergreifende Slice von CORE-102 / Issue #619. Er zeigt vor der
Funktionsauswahl Python, R und Java aus dem tatsächlich geladenen Software-
und SQL-Katalog sowie C# als `USER_DEFERRED`. Im Hauptmenü öffnet
**Hostfähigkeiten vor der Funktionsauswahl** dieselbe Public-Funktion über
die gemeinsame Cursor-/Fallback-Konsole. Zurück/Abbruch fragt keinen Provider ab.
Die Ergebnisansicht wartet auf Enter oder Escape; Hostbeobachtungen werden
direkt angezeigt und nicht in das allgemeine Meldungsjournal geschrieben.

Standardmäßig werden keine Hostwerkzeuge aufgerufen. Erst die ausdrückliche
Option `-CheckProviderReadiness` beziehungsweise die entsprechende
Konsolenauswahl führt je ausgewähltem Provider genau eine bestehende lesende
Bootstrap-Prüfung aus. `-Provider docker`, `podman` oder `hyperv` begrenzt
die Prüfung ohne Abhängigkeit von den anderen Providern.

## Autoritäten und Scope

Der Vertrag `SqlServerLab.HostCapabilityMatrix/1.0` kombiniert ausschließlich
den geladenen SQL-/Softwarekatalog und Provider-Metadaten über
`Resolve-LabExternalRuntimePlan`, das aktuelle Hostbetriebssystem als
`windows`, `linux` oder `unknown` und optional
`Get-LabDiagnosticReadiness -Operation Inspect` mit dem vorhandenen isolierten
`DiagnosticProviderReadiness/1.0`-Worker.

Docker und Podman werden für das Linux-Gastziel, Hyper-V für das Windows-
Gastziel dargestellt. Diese erste Übersicht wählt keine weiteren Gast-OS,
Architekturen oder Builds und verändert keine bestehende Instanzbewertung.
`SqlVersion` muss eine exakte ID des geladenen Versionskatalogs sein;
unbekannte IDs und freie CU-Aliase scheitern vor der ersten Hostabfrage.
Varianten werden mit exakter ID/Runtimeversion durch den vorhandenen Resolver
bewertet; Vorschau, explizite Variantenwahl und fehlende Zuordnungen bleiben sichtbar.

Der bestehende Worker besitzt eine Grenze von 45 Sekunden plus bis zu fünf
Sekunden Prozessbeendigung und 64 KiB gemeinsamer Ausgabe. Prüfungen laufen
sequenziell, höchstens dreimal. Es entstehen keine Runs, Images, Installationen,
Konfigurationsänderungen oder persistierten Hostbeobachtungen. Native Rohdaten,
Pfade und freie Fehler-/Hinweistexte werden nicht in die Matrix übernommen.
Die vollständige öffentliche Antwort ist auf 256 KiB UTF-8 begrenzt.

## Getrennte Entscheidungen

`Providers` enthält ausschließlich `Provider`, `Presence`, `Readiness`,
`ReasonCode`, `Source` und `ObservedAtUtc`. Installation ist `PRESENT`,
`MISSING`, `INCOMPLETE`, `HOST_UNSUPPORTED` oder `UNKNOWN`; aktuelle Bereitschaft
ist `NOT_CHECKED`, `READY`, `NOT_READY` oder `UNKNOWN`.
Ein aufgelöstes Werkzeug mit verweigertem Zugriff oder unerreichbarer Engine
bleibt vorhanden. Ein Probe-/Transportfehler beweist keine Abwesenheit.
Fehlerhafte oder widersprüchliche Beobachtungen bleiben `UNKNOWN`.

Bei vollständiger Auswahl unterscheidet `ProviderProfile` die acht Kombinationen
`NO_PROVIDER`, `DOCKER_ONLY`, `PODMAN_ONLY`, `HYPERV_ONLY`, `DOCKER_PODMAN`,
`DOCKER_HYPERV`, `PODMAN_HYPERV`, `ALL_PROVIDERS`. Nicht geprüfte Profile sind
`NOT_CHECKED`, unvollständig beweisbare Profile `UNKNOWN`. Eine eingeschränkte
Providerauswahl liefert immer `PARTIAL_SELECTION`.

Jede Zeile in `Capabilities` hat ein Provider-/Gastziel, Sprache, nullable
Software-/Varianten-/Runtimeidentität, `CatalogStatus`, `CatalogReasonCode`,
`Availability`, `ReasonCode`, feste `Explanation`, `NextStep`, deklarierte
`RequiredCapabilities` und `ExplicitSelectionRequired`.

| Availability | Aussage | Zulässiger nächster Schritt |
|---|---|---|
| `NOT_CHECKED` | Katalogvariante aufgelöst; Provider ungeprüft | `CHECK_PROVIDER_READINESS` |
| `PRECONDITION_MISSING` | Provider nicht bereit | `REVIEW_PROVIDER_READINESS` |
| `INCOMPLETE` | Provider erreichbar; konkrete Launchanforderungen fehlen | `ASSESS_LAUNCH_REQUIREMENTS` |
| `CATALOG_BLOCKED` | Resolver kann diese Kataloganforderung nicht auflösen | `REVIEW_CATALOG_SCOPE` |
| `UNKNOWN` | Katalog oder aktuelle Beobachtung nicht verlässlich | `RECHECK_CATALOG` oder `RECHECK_PROVIDER_READINESS` |
| `USER_DEFERRED` | C# durch Benutzerentscheidung zurückgestellt | `USER_DECISION_REQUIRED` |

Katalogblockierung ist kein Beweis technischer Unmöglichkeit.
`READY` am Provider ist ausschließlich Bootstrap-Erreichbarkeit.
Keine Zeile dieser Vertragsversion behauptet eine native Sprachabnahme oder
vollständig erfüllte Launchvoraussetzungen.

## Geführter Browser

Im Bereich **Lab-Umgebungen** öffnet **Hostfähigkeiten vor der Funktionsauswahl**
dieselbe Matrix. Beim Öffnen werden ausschließlich die geladenen SQL-
Katalogversionen gelesen; erst die gewählte SQL-Version und **Übersicht ohne
Hostabfrage lesen** führen zur Matrix. Alle drei Provider können gemeinsam
angezeigt werden. Die bewusste aktuelle Prüfung verlangt genau einen Provider,
damit eine einzelne Anfrage auf dessen vorhandenen Worker begrenzt bleibt.

`POST /api/host-capability-matrix` akzeptiert nur exakt gebundene Loopback-
Origin/Authority, JSON bis 2048 Bytes und zwei geschlossene Aktionen:
`ReadVersions` mit ausschließlich `Action` oder `ReadMatrix` mit `Action`,
exakter `SqlVersion`, `Provider` (`all`, `docker`, `podman`, `hyperv`) und
echtem Boolean `CheckProviderReadiness`. Die Kombination `all` plus true
wird vor dem Public-Aufruf abgelehnt. Methode, Pfad, Query, doppelte beziehungsweise
unbekannte Felder und Typabweichungen sind fail-closed.

Die Antwort `HostCapabilityMatrixBrowser/1.0` liefert `VERSIONS` oder `MATRIX`.
Eine Matrixaktion ruft die Public-API genau einmal auf und projiziert deren
Entscheidung ohne freie `Explanation`-Texte. Der Browser beschreibt feste
Status-/Grund-/Folgeschrittcodes; er berechnet keine eigene Sprachkompatibilität.
Geschlossene Felder, Identitäten, Scope, Zeitbindung und verweigerte
Ausführungsautorität werden vor der Anzeige geprüft. Host-/Native-Rohtexte
werden nicht übernommen. Die vollständige Antwort bleibt auf 256 KiB begrenzt.

Providerstatus und Sprachvarianten bleiben sichtbar und ohne auswählbare
Ausführung. Ein Wechsel von SQL-Version oder Provider verwirft die vorige
Anzeige; Schließen/Wiederöffnen ebenso. Späte Antworten können keine neue
Auswahl befüllen. Solange eine Anfrage läuft, startet Wiederöffnen keine
weitere Hostprüfung. Es gibt keine Hintergrundprüfung oder Persistierung;
Abbruch verwirft die Anzeige, eine bereits angeforderte lesende Prüfung
läuft höchstens bis zur vorhandenen Workergrenze weiter.

## Anschluss an konkrete Container-Launchdetails

Für aufgelöste Docker-/Podman-Linux-Varianten mit SQL 2019, 2022 oder 2025
öffnet **Varianten- und Launchdetails öffnen** die bestehende
[External-Runtime-Entscheidung](EXTERNAL_RUNTIME_CAPABILITY.md). Die Matrix
wird geschlossen und geleert. Provider, SQL-Version, Software-ID, Runtime-
und Varianten-ID werden als geschlossenes Tupel übergeben. Die Zielansicht
liest ihren Katalog erneut und wählt nur exakt diese weiterhin unterstützte
Variante aus; fehlende oder geänderte Varianten führen zu keiner Ersatzwahl.
Öffnen startet weder Hostprüfung noch Bewertung oder historischen Lookup.
Die vorhandenen Aktionen für Bewertung beziehungsweise bewusste Hostprüfung
bleiben getrennte Benutzerschritte.

Cursor- und Fallback-Konsole bieten nach der lesbaren Matrixausgabe dieselbe
Vertiefung über **Konkrete Container-Variante näher prüfen**. Nach exakter
Variantenwahl wird zwischen reiner Katalog-/Launchdeklaration und bewusster
aktueller Prüfung gewählt. Erst danach erfolgt genau ein Aufruf von
`Get-SqlServerLabExternalRuntimeCapability` mit dem ausgewählten Tupel und
ausdrücklichem Readiness-Switch. Zurück/Abbruch erfolgt vorher ohne Abfrage.
Die Ausgabe bleibt nicht persistierend und wartet auf Bestätigung.

Die bestehende Prüfung liest höchstens einmal begrenzt Providerinfo für
Linux, cgroup-Version und Rootful. Sie verändert keine Runtime und prüft
keine SQL-Sprachausführung. Ihr `READY` ist ausschließlich an diese
Container-Grundlagen gebunden; Controller, WSL-Konflikte, Ressourcen und
Zielrechte bleiben offen. Die Matrix übernimmt dieses getrennte Ergebnis
nicht als gecachten Freigabestatus. Hyper-V-Zeilen, nicht aufgelöste Varianten
und zurückgestelltes C# bleiben sichtbar und ohne diese Detailaktion.
Abbruch oder Auswahlwechsel während der Katalogantwort verhindert die
spätere Wiederherstellung einer übergebenen Auswahl.

## Frische, Grenzen und Fortsetzung

`GeneratedAtUtc` und die einzelnen Beobachtungszeiten binden die Abfrage an
ihren Zeitpunkt. `CatalogFingerprint` ist SHA-256 der tatsächlich geladenen
SQL-/Software-/Providerautoritäten, kein Hash eines eventuell neueren
Dateistands. Dies ist kein Cache oder Freigabetoken: Vor einer Mutation gelten
die aktuellen Prüfungen des jeweiligen Executors erneut.

`Unassessed` nennt SQL-Build, tatsächliches Gast-OS, Kernel/cgroup-Controller,
WSL-Shared-Kernel, Rootless/Launchmodus, Ressourcen, Zielautorisierung,
historische Evidence und tatsächliche SQL-Sprachausführung. Herstellerstatus
und Projektabnahme bleiben separat `NOT_ASSESSED`. `ExecutionSupported` und
`MutationAllowed` sind immer false; `Actions` ist leer.

Offen bleiben die umfassende Host-/Launchmatrix, aktuelle Ressourcen-/Kernel-
und WSL-Konfliktbewertung sowie scopegebundene Native-
Sprachnachweise. Der bereits vorhandene engere
[External-Runtime-Vertrag](EXTERNAL_RUNTIME_CAPABILITY.md) bleibt für einzelne
Linux-Manifestanforderungen einschließlich cgroup-/Rootful-Prüfung zuständig.
Historische Nachweise werden weder gelöscht noch zu aktueller Readiness gemacht.
Die [Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md) trennt
synthetische Matrixprüfungen von tatsächlich ausgeführten Provider-/SQL-Checks.
