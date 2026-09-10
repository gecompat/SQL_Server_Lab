# Autonome Entwicklungswelle nach der Repository-Durchsicht

| Merkmal | Wert |
|---|---|
| Status | `in_progress` |
| Stand | 2026-09-10 |
| Auftrag | Plan per geprüftem Pull Request nach `origin/main` übernehmen und anschließend alle Punkte autonom abarbeiten |
| Ausgangspunkt | Durchsicht von `9cfd144`, vor Veröffentlichung gegen `ca9f09e` abgeglichen |
| Ziel | vollständige Abarbeitung der Implementierungs-, Abnahme- und Bewertungsaufgaben bei konsistentem Gesamtsystem |
| Reihenfolge | Konkretisierung des nachgelagerten Horizonts aus Abschnitt 12 des [Ausführungsplans](DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md) |

## Auftrag, Abschluss und Fortsetzung

Dieser Plan übernimmt die vollständige priorisierte Repository-Durchsicht.
Er bleibt zusammen mit Code, Tests und den verlinkten Fachverträgen ausreichend,
um die Arbeit ohne frühere Chat-Historie fortzusetzen. Bestehende Task-IDs werden
beibehalten; die beschreibenden Tabellenzeilen eröffnen keinen neuen
Sequenznummernraum und ersetzen keine vorhandene Registration Authority.

Reparaturen und ausdrücklich vorgesehene Funktionen werden implementiert und
abgenommen. Als Bewertung vorgesehene größere Erweiterungen werden mit einer
begründeten Entscheidung, Nutzen, Aufwand, Abhängigkeiten, Risiken und einem
konkreten Folgeschritt abgeschlossen. Eine Bewertung ist kein Runtime-Nachweis
und autorisiert keine unbeschränkte Umsetzung einer neuen Plattform.

Das Ziel eines fehlerfreien Gesamtsystems bedeutet überprüfbar: keine bekannten
offenen Fehler in den erforderlichen Gates des vereinbarten Scopes, getrennte
erfolgreiche Providernachweise, konsistente öffentliche Verträge, sichere
Recovery und vollständiger Cleanup. Es ist keine mathematische Zusicherung
unentdeckter Fehlerfreiheit. `NOT_EXECUTED`, `FAIL`,
`INFRASTRUCTURE_UNAVAILABLE` und `RECOVERY_REQUIRED` bleiben sichtbar offen;
sie dürfen weder in `PASS` umbenannt noch durch Abschwächen von Tests beseitigt
werden. Bewusst nicht unterstützte Funktionen sind mit ihrer Grenze zu führen.

Die Abarbeitung verwendet genau einen aktiven Implementierungsverantwortlichen
pro kohärenter Änderung. Jeder abgeschlossene Slice umfasst Code, passende
Verträge, Dokumentation und Tests, wird separat per geprüftem PR integriert und
aktualisiert diesen Arbeitsstand. Vor jeder Fortsetzung sind aktueller
`origin/main`, offene PRs, Regelkontext, Ressourcen und bestehende Evidence
abzugleichen. Neue Erkenntnisse ändern den nächsten Slice, löschen aber keinen
offenen Planpunkt stillschweigend.

## Bestandsaufnahme und bereits integrierte Arbeit

Die Durchsicht auf `9cfd144` erfasste 86 öffentliche Befehle, 108 statische Suiten
und 56 Integrationstestdateien. Die Capability-Inventur meldete keine Parser-
oder Exportfehler; der Dokumentationscheck bestand 994 Prüfungen. Diese Zahlen
sind datierte Inventur, kein Qualitätsnachweis für spätere Revisionen.
Die [Nightly vom 2026-09-10](https://github.com/gecompat/SQL_Server_Lab/actions/runs/34441571461)
scheiterte auf beiden statischen Plattformen; die dort ausgeführten Docker-,
Podman-, Mixed-, Hyper-V-, Adapter- und gemeinsamen Testumgebungsjobs bestanden.

Vor Veröffentlichung dieses Plans wurden folgende damalige offene PRs bereits
integriert. Ihre verbleibenden Grenzen werden in die Arbeit übernommen:

| Arbeit | Aktueller Stand | Verbleibende Grenze |
|---|---|---|
| [Container-Export-Recovery #393](https://github.com/gecompat/SQL_Server_Lab/pull/393) | auf `main` integriert | Regression der integrierten Revision beibehalten; kein doppelter Recovery-Kern |
| [Windows-Aktivierungsintent #396](https://github.com/gecompat/SQL_Server_Lab/pull/396) | auf `main` integriert; temporärer Evaluationspfad separat nativ dokumentiert | permanente NIC sowie weitere Aktivierungsarten benötigen eigene Evidence |
| [Szenariovertrag #400](https://github.com/gecompat/SQL_Server_Lab/pull/400) | interner Metadatenvertrag integriert | allgemeiner Executor und fachliche Szenarien fehlen |
| [Re-Embedding-Plan #401](https://github.com/gecompat/SQL_Server_Lab/pull/401) | read-only Plan integriert | Modell-/SQL-Ausführung, Persistierung und Generationenumschaltung fehlen |

## Erste Welle: stabile Tests und sichere Releases

Diese Welle verändert zunächst keine öffentliche Produkt-API. Die Aufgaben
werden als getrennte kohärente PRs abgeschlossen; Fehlerreproduktion steht vor
Reparatur, abhängige Regression vor Integration.

| Arbeit | Status | Konkrete Änderung und Abnahme |
|---|---|---|
| Netzwerk-Testregression | `validated` (offline) | Der Mock liefert einen tatsächlichen Job; Ergebnisweitergabe, leerer Fallback, Ablehnung einer ungültigen IP vor dem Gastaufruf und Job-Cleanup sind geprüft. Die produktive IP-Validierung bleibt unverändert. |
| Sample-Baseline-Testregression | `validated` (offline) | Die produktive Exportfunktion ist mit synthetischen Session-/Transfergrenzen für Erfolg, gestoppte VM, Verzeichnis, leere Quelle, fehlendes/leeres Ziel und Transferfehler geprüft; jede erzeugte Session wird geschlossen. Native Sample-Parität bleibt separat offen. |
| Betroffene Testauswahl | `validated` | Hyper-V-Provider → Netzwerkcheck; SQL-Storage-/Session-Helfer → Sample-Baseline, Storage und Hyper-V; gemeinsame KI-Verträge und SQL-Observability → getrennte Docker-/Podman-/Hyper-V-Gates. State-Upgrade, portabler Import, Evaluation-Watch und Recovery-Point-Plan wählen ihre eigenen Suiten. Einzelpfad- und Kombinationstests bestehen nach der Reparatur (64 PASS); Runtime-Gates werden pro Datei vereinigt, damit bekannte Dateien den Fallback unbekannter Produktdateien nicht unterdrücken. Betroffene statische Regression und alle fünf lokalen Provider-Smokes bestanden. |
| Release-Sicherheit und Funktion | `validated` | Fester sauberer Git-Snapshot, gemeinsame `ShouldProcess`-Grenze, korrigierte Ausschlüsse, relative Metadaten und getrennte Datumsformate umgesetzt. Staging, Pfad-/Symlink-Prüfung und Rollback bei gewöhnlichen Ausnahmen sind auf Windows und Linux geprüft. Harte Prozessabbrüche bleiben Teil der gesonderten Recovery-Härtung. |
| Paketabnahme | `validated` | Isolierte Git-Fixtures prüfen `WhatIf`, dirty/unversionierte Quellen, sensible Pfade, umgeleitete Ziele, Teilpublikation, ZIP-/Hash-Integrität und den Import des tatsächlichen entpackten Moduls: 20 PASS. Die Suite ist in Selektor, Vollregression und Repo-Map eingebunden; alle 97 Suiten des lokalen Abschlusslaufs bestanden. PR #407 wurde nach grünen Windows-/Linux- und allen fünf Runtime-Gates integriert. |
| Statuswahrheit | `validated` (lokaler Dokumentations-/Metadatenabgleich) | Vorhandene Readiness-/Validierungs-/Operate-Skills, öffentliche Daten-VHDX-Aktionen und getrennte Hyper-V-Template-/Prepared-/CLI-Pfade sind mit Code und datierter Evidence abgeglichen. Veraltete pauschale Grenzen sind korrigiert; allgemeine Provisionierung, breite Versionsmatrizen und synthetische CI bleiben getrennt. Provider-Vertrag fokussiert 63 PASS; alle elf ausgewählten statischen Suiten bestanden. Keine neue native Ausführung oder breitere Providerfreigabe. |
| Nachweisindex | `validated` (lokaler Inventurvertrag) | Kleiner schema-validierter historischer Index ist an die bestehende Capability-Inventur angebunden: Fähigkeit, Provider, SQL-Version, Plattform, Scope, Quellrevision, Test, Ergebnis, Cleanup und Quellenreferenz. Vorhandene Tests bestätigen keine aktuelle Ausführung; externe Quellen werden nicht automatisch verifiziert. Inventur einschließlich Negativtests und kanonischem SQL-2008R2-Wert 24 PASS, Selektor 70 PASS und alle sechs ausgewählten statischen Suiten bestanden. Historische Fehler und spätere erfolgreiche Revisionen bleiben getrennt. |

Die bekannten Fehlerstellen liegen in
[`Invoke-LabNetworkChecks.ps1`](../../Tests/Static/Invoke-LabNetworkChecks.ps1),
[`Invoke-SampleBaselineRuntimeChecks.ps1`](../../Tests/Static/Invoke-SampleBaselineRuntimeChecks.ps1),
[`Get-CiTestSelection.ps1`](../../Tools/Get-CiTestSelection.ps1) und
[`Prepare-LocalRelease.ps1`](../../Tools/Prepare-LocalRelease.ps1).
Der Release-Ausschlussfilter traf in der ursprünglichen Reproduktion weder
`.local/example.json` noch `.secrets/example.json`; bestehende Git-Ignore-Regeln
waren davon unabhängig weiterhin wirksam. Es wurde kein Paket mit realen
Secrets veröffentlicht. Die Dirty-Prüfung scheiterte auf dem sauberen Checkout
an `.Trim()` auf einer leeren Git-Ausgabe.

**Gate:** Die beiden Reproduktionen und alle neuen fokussierten Prüfungen sind
grün. Der Selektor erfasst die betroffenen Verträge. Ein erforderlicher
statischer Gesamtlauf auf Windows und Linux ist erfolgreich; Runtime-Gates
werden nach tatsächlichem Änderungsscope getrennt erfüllt. Der Pakettest
belegt Inhalt, Portabilität, Integrität und mutationsfreies `WhatIf`.

## Vorhandene Funktionen fertigstellen

Reihenfolge und Abnahme sind innerhalb dieser Tabelle von oben nach unten
vorgegeben. Unabhängige Offlinearbeit darf bei einem konkret dokumentierten
Runtimeblocker weitergehen, ohne den blockierten Punkt abzuschließen.

| Arbeit | Status | Abschlusskriterium |
|---|---|---|
| Hyper-V-Reconcile | `planned` | Isolierte native Runner für SQL-Konfiguration, SQL-Port, Testdatenbanken und External Runtimes ausführen; Ressourcen-, Netzwerk- und Storage-Reparatur separat mit No-op, Mutation, Resume, Persistenz und Cleanup nachweisen. Allgemeine CLI-Evidence ersetzt diese Einzelverträge nicht. Der read-only `PrepareImage`-Readiness-Check meldet am 2026-09-10 `NOT_READY` mit ausschließlich `ELEVATION_REQUIRED`; neue Gastabnahmen benötigen eine erhöhte Windows-Ausführung. |
| Hyper-V-Sample-Parität | `planned` | `LAB_GENERATED`-Export und automatische Sample-Manifestausführung nativ mit Hash-/Identitätsbindung, Wiederverwendung und Cleanup prüfen. |
| Recovery-Härtung | `planned` | Prozessabbruch, wiederholtes Cleanup, manipulierte Ownership, Junctions und gemischte Provider-Teilfehler gezielt induzieren; fremde Objekte unverändert lassen und idempotente Wiederaufnahme belegen. |
| Evaluation-Watch | `planned` | Bestehende Image-Inventur um registrierte laufende Instanzen und deren getrennte Windows-/SQL-Fristen ergänzen; lokalen begrenzten Zeittrigger und deduplizierte Benachrichtigung ohne Cloudpflicht anbinden. Kein automatischer Lizenz- oder Refresh-Eingriff. |
| State-Upgrades | `planned` | Vorhandenen read-only Plan um eine begrenzte Migration historischer synthetischer States mit gesicherter Ausgangsrevision, atomarem Commit, Resume und Rollback erweitern; unbekannte Versionen blockieren. |
| Persistenzlücken | `planned` | Bestandsübernahme, weitere kompatible Paketprovider und explizite Löschung retained Stores getrennt fertigstellen. Stabile IDs, Referenzen, Leases, Plan und Recovery vor Mutation; TDE/FILESTREAM besitzen eigene Freigabegates. |
| Portabler Lab-Transfer | `planned` | Zunächst Container-Lab-Roundtrip aus Export, Zielbindung, Secret-Rebind, Import und Inhaltsvergleich liefern. Weder read-only Plan noch Archiv allein zählt als erfolgreicher Transfer. |
| SQL-Observability | `planned` | Vorhandene aggregierte Evidence nativ je betroffenen Provider prüfen; Größenbegrenzung, Aufbewahrung und gezielte Diagnoseprofile ergänzen. Rohqueries, Secrets und reale Objektnamen nicht exportieren. |
| Breitere Hyper-V-Provisionierung | `planned` | OS-Baseline→SQL-Pfad, Post-Provisioning und Softwarebindung unter dem vorhandenen Cold-Path-/Prepared-Vertrag vervollständigen. SQL 2025 bleibt Core-Referenz; breite Versionsmatrizen gehören weiterhin zu den Partnerprojekten. |

Fachliche Quellen bleiben der
[Persistenzbacklog](PERSISTENT_STORAGE_REUSE_AND_LAB_DATA_BACKLOG.md),
der [Plattformbacklog](CROSS_CUTTING_PLATFORM_CAPABILITIES_BACKLOG.md),
der [Hyper-V-Vertrag](../Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md)
und die [Known Limitations](../Quality/KNOWN_LIMITATIONS.md).

## Szenarien, Bedienung und KI

| Arbeit | Status | Abschlusskriterium |
|---|---|---|
| Allgemeiner Szenariokern | `planned` | Auf dem integrierten internen Vertrag aufbauen; begrenzte Arrange-/Act-/Observe-/Assert-/Cleanup-Ausführung mit Ownership, Abbruch, Resume und sanitisiertem Ergebnis liefern. Keine parallele AI-Szenario- oder Providerimplementierung. |
| Upgrade-/Regressionsszenario | `planned` | Synthetische Datenbank mit festgelegter Workload vor/nach Zielwechsel vergleichen; Compatibility Level getrennt behandeln, funktionale Assertions und nachvollziehbare Messwerte samt Cleanup liefern. Fachliche Partnerzuständigkeit erhalten. |
| Point-in-Time-Recovery-Szenario | `planned` | Kleine Full-/Log-Kette und markierte Transaktionsfolge bis vor eine synthetische Fehlmutation wiederherstellen; erwarteten Zeilenstand, Integrität, Recoverydauer und Cleanup prüfen. |
| Collation-Auswahl | `planned` | `COL-001` mit versionsgebundenem Katalog, Suche und SQL-seitiger Validierung abschließen. |
| Direkter SQL-Prepared-Locale-Pfad | `planned` | Bestehenden portablen Locale-Intent separat im direkten Manifestpfad nach Kaltstart und mit Cleanup abnehmen. |
| Legacy-WMI-Fortschritt | `planned` | Verbleibende Wartepfade inventarisieren und an bestehenden Reporter anbinden; Blockierung, Fehler, Abbruch und Reporter-Cleanup prüfen. Bereits integrierte Fortschrittshelfer wiederverwenden. |
| Reservierte Manifestfelder | `validated` (Bewertung) | [Einzelbewertung](RESERVED_MANIFEST_FIELDS_ASSESSMENT_2026-09-10.md) für alle neun direkten reservierten `serverConfig`-Felder, `customImage`, zwei `installMethod`-Werte und die gesonderten Adapterfelder abgeschlossen. Bestehende Collation-/Storage-/Derived-Image-Verträge haben Vorrang; direkte erste PITR-/Upgrade-Szenarien benötigen keine zusätzlichen Agent-/CLR-/Authentifizierungsschalter. Jeder spätere Bedarf besitzt Nutzen, Abhängigkeit, Risiko, relativen Aufwand und konkreten Folgeschritt. Felder bleiben reserviert; keine neue Runtimefreigabe. |
| Podman Golden RAG | `planned` | Bisher vor RAG am Modell-Pull beendeten Nachweis unter geändertem, nachvollziehbarem Input erfolgreich einschließlich Restart und Cleanup ausführen. |
| Hyper-V RAG/Agent | `planned` | Isoliertes SQL-Ziel verwenden und bisher fehlenden VM-Neustart samt Login-/Modell-/Lab-Cleanup nachweisen; Schutz gemeinsamer Testgruppen nicht umgehen. |
| Modellcache | `planned` | Kontrollierten digestgebundenen Cache nach Kosten, Ownership, Integrität und Cleanup bewerten; Entscheidung und erste kleine Umsetzung oder begründete Nichtübernahme dokumentieren. |
| Persistentes Retrieval/Re-Embedding | `planned` | Integrierten read-only Plan zu begrenzter Modell-/SQL-Ausführung ausbauen; stabile Inhalte/Generationen, Aktualisierung/Löschung, Dimensionen, Resume und atomare Umschaltung mit Negativtests belegen. |

Die [neuen SQL-Anwendungsfälle](NEW_SQL_LAB_USE_CASES_BACKLOG.md), der
[KI-Plattformbacklog](SQL2025_AI_PLATFORM_BACKLOG.md), der
[Vector-Backlog](SQL2025_VECTOR_EMBEDDING_BACKLOG.md) und
[`COL-001`](CONSOLE_LIFECYCLE_AND_STORAGE_CONSOLIDATION_PLAN_2026-08-12.md)
bleiben fachliche Referenzen. Die erste Version einer neuen Fähigkeit muss
einen kleinen echten Ende-zu-Ende-Nutzen liefern; reine Schemas und Planer sind
als Zwischenstand auszuweisen.

## Vollständig zu bearbeitende Bewertungen

Für jede Zeile ist eine Entscheidung mit Nutzen, Abhängigkeiten, Risiko,
zulässigem Scope und nächstem Arbeitsschritt erforderlich. `validated` bedeutet
hier nur abgeschlossene Bewertung, niemals implementierte Produktfähigkeit.
Neue externe Dienste, Kosten, Lizenz-, Mehrbenutzer- oder Hostverwaltungsgrenzen
werden nicht allein durch Aufnahme in diese Liste freigegeben.

| Gegenstand | Status | Bewertungsziel und bestehender Vertrag |
|---|---|---|
| Vollständiger Evaluation-Refresh | `validated` (Bewertung) | [Bewertung](REFRESH_AND_RECOVERY_ASSESSMENT_2026-09-10.md) bestätigt den begrenzten Hyper-V-Evaluationsfall und konkretisiert Inventar, Datenbank-/Login-/Job-/Konfigurationsübernahme, Schlüssel-/Service-Blocker sowie parallelen Aufbau. Cutover erlaubt genau eine Schreibseite; Rückfall nach Zielschreibzugriffen benötigt einen eigenen Rücksynchronisierungsnachweis. Nutzen, Abhängigkeiten, Risiken, Aufwand und nächste Abnahme je Teilvertrag sind dokumentiert; kein Executor freigeschaltet. |
| Recovery Points | `validated` (Bewertung) | [Bewertung](REFRESH_AND_RECOVERY_ASSESSMENT_2026-09-10.md) fordert nachgewiesene SQL-Konsistenz, vollständige Disk-/Parentbindung, Restore in ein unabhängiges Ziel und Lease-/Referenzschutz vor Entfernung. Erster vollständiger Slice bleibt ein eigener Hyper-V-SQL-2025-Run; keine pauschale Container-/Checkpoint-Parität und kein Evaluation-Refresh durch Rücksetzen. Erstellung und Restore sind weiterhin nicht implementiert. |
| Air-Gap-Pakete | `planned` | Lizenz-/Hash-gebundenes Medienpaket, Offline-Auflösung, Aktualisierung und Exit anhand des Plattformbacklogs bewerten. |
| PolyBase/S3 | `planned` | Konkreten SQL-Nutzen, verfügbare Integrationsverträge und minimalen Object-Store-Slice im [S3-Backlog](POLYBASE_S3_OBJECT_STORAGE_BACKLOG.md) beurteilen. |
| SSIS | `validated` (Bewertung) | [Bewertung](BI_CAPABILITIES_ASSESSMENT_2026-09-10.md): Windows-/SSISDB-Projektreferenz mit synthetischem Full-/Delta-Load, Commit-gebundenem Fortschritt, Secret-/Rechtebindung und Fehler-/Restart-/Cleanup-Abnahme festgelegt. Aufwand L; Umsetzung nach den offenen Plattform- und Szenariogates. Keine neue Runtimefähigkeit. |
| SSAS | `validated` (Bewertung) | [Bewertung](BI_CAPABILITIES_ASSESSMENT_2026-09-10.md): Tabular Import mit festem Modell, DAX-Assertions, nicht administrativer RLS-Prüfung, Processing-Resume und unabhängigem Restore festgelegt. Aufwand L; DirectQuery, Multidimensional und verteilte Identitäten bleiben getrennt. |
| BI-Pipeline | `validated` (Bewertung) | [Bewertung](BI_CAPABILITIES_ASSESSMENT_2026-09-10.md): gemeinsame Quell-/Warehouse-/Modellrevision und Fehler vor/nach Fakt-Commit bis zum Processing prüfen. Aufwand L zusätzlich zu den Einzelabnahmen; ein erster eigener Windows-Run folgt erst nach SSIS und SSAS. Keine Ende-zu-Ende-Evidence behauptet. |
| Remote Hyper-V | `validated` (Bewertung) | [Bewertung](HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md): zuerst read-only Hostregistrierung; später genau ein gebundener SQL-Run mit hostseitiger Identität, State, Autorisierung, Transfer- und Recoveryvertrag. Aufwand L; kein entfernter Host für diese Welle freigegeben. |
| Mehrbenutzerbetrieb | `validated` (Bewertung) | [Bewertung](HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md): Einzeloperator bleibt Standard; erster späterer Slice ist disjunkte read-only Inventur zweier synthetischer Identitäten. Mutation verlangt eigene Rechte-, Revisions-, Audit- und Konfliktabnahme, Aufwand L. |
| Cluster/HA/DR | `validated` (Bewertung) | [Bewertung](HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md): SQL-AG zuerst bei konkretem Szenario; FCI, SSISDB-HA, Worker, SSAS-WSFC und Queryknoten erhalten getrennte Abnahmen und Aufwand L. Gastfailover auf einem Host belegt keine physische HA; keine Clusterlaufzeit implementiert. |
| Automation-API/IaC | `validated` (Bewertung) | [Bewertung](HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md): vorhandene PowerShell-API bleibt Standard; lokaler versionierter read-only Plan-/Result-Vertrag als nächster Schritt, Aufwand M. Kein neuer Netzwerkdienst; genau ein späterer IaC-Pilot erst bei konkretem Konsumenten. |
| KI-TLS-Gateway | `planned` | SQL-seitiges External Model, Endpointvertrauen, Zertifikate, Credential-Lifecycle und getrennte Native-Evidence bewerten. |
| ONNX | `planned` | Unterstützte Windows-/SQL-Kombination, reproduzierbares Modellartefakt und Native-Testkosten beurteilen. |
| ANN | `planned` | Nutzen gegenüber exakter Suche, Qualitäts-/Performance-Metriken und versionsabhängige Freigabe beurteilen. |
| Zusätzliche Cloudanbieter | `planned` | Bedarf, expliziten Egress, synthetische Daten, Credential-/Kostenlimit und austauschbaren Adapter entscheiden. Ohne freigegebenen Bedarf keine bezahlten API-Läufe. |

## Tests, Veröffentlichung und Arbeitsjournal

Die [lokale Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md) und
die [Kostenrichtlinie](../Quality/COST_EFFICIENT_DEVELOPMENT.md) bleiben
verbindlich: kleinste Reproduktion, fokussierte Suite, Auswahl über
`Invoke-ImpactedChecks.ps1`, betroffene native Provider und genau ein
erforderlicher Abschluss-Gate pro stabilem Stand. Unveränderte grüne Tests
werden nicht ohne neue Abhängigkeit wiederholt.

Reale Host-, SQL-, Backup-, Modell-, Secret- und Diagnosedaten bleiben lokal.
Versioniert werden nur sanitisierte Ergebnisse mit Test, Revision, Provider,
Datum, Ergebnis und Cleanupstatus. Native Tests verwenden isolierte eigene
Ressourcen und serialisieren konkurrierende Runtimearbeit über die vorhandenen
Projektverträge. Geschützte gemeinsame Testgruppen bleiben geschützt.

Der Gesamtabschluss verlangt:

- jede Implementierungszeile mit Code-/Vertrags-/Benutzerpfad und passender
  statischer sowie nativer Evidence;
- jede Bewertungszeile mit begründetem dokumentiertem Ergebnis;
- nachvollziehbare API-/Schema-/State-Kompatibilität und passende Beispiele;
- grüne erforderliche Windows-/Linux-Regression und getrennte Docker-, Podman-,
  Mixed-, Adapter- und Hyper-V-Nachweise auf dem integrierten Stand;
- verifizierte Paketabnahme, Privacy- und vollständige Diff-Prüfung;
- keine offenen testbedingten Residuen, unbekannten Blocker oder verdeckten
  Recoverybedarfe.

| Zeitpunkt | Fortschritt | Evidence / nächster Schritt |
|---|---|---|
| 2026-09-10 | Plan gegen `ca9f09e` und integrierte PRs abgeglichen; Implementierung dieser Welle noch nicht begonnen | Planungs-PR lokal prüfen, nach `origin/main` integrieren, anschließend Testregressionen reproduzieren und beheben. |
| 2026-09-10 | Plan über [PR #404](https://github.com/gecompat/SQL_Server_Lab/pull/404) nach grünen Windows-/Linux-Prüfungen integriert (`bce673a`) | Erste Implementierung: Beide Testfehler auf dieser Basis reproduziert. Netzwerk danach 36 PASS / 0 FAIL, Sample-Baseline 19 PASS / 0 FAIL; Job- und synthetischer Session-Cleanup erfolgreich. Kein neuer nativer Providernachweis. |
| 2026-09-10 | Testregressionen über [PR #405](https://github.com/gecompat/SQL_Server_Lab/pull/405) nach grünen Windows-/Linux-Prüfungen integriert (`40d2d32`); Testauswahl auf dieser Basis repariert | CI-Strategie 64 PASS / 0 FAIL, betroffene statische Regression einschließlich 18 Pester-Tests bestanden. Docker und Podman je 34/34, Mixed-Smoke, Adapter 10/10 sowie Hyper-V-Lifecycle-Smoke bestanden; erforderlicher Cleanup erfolgreich. Hyper-V-Smoke verwendet synthetische Datenträger ohne OS-/SQL-Installation und ersetzt keine fachliche Gastabnahme. Nächster Slice: Release-Sicherheit und Paketabnahme. |
| 2026-09-10 | Testauswahl über [PR #406](https://github.com/gecompat/SQL_Server_Lab/pull/406) nach allen grünen CI-Gates integriert (`ec63009`); Release-Sicherheit und Paketabnahme auf dieser Basis umgesetzt | Neue Release-Fixtures reproduzierten zunächst sechs Fehler; anschließend 20 PASS. CI-Strategie 66 PASS, betroffene Regression und alle 97 Suiten von `Invoke-AllChecks.ps1` auf Windows bestanden, Fixture-Cleanup erfolgreich. Der unveränderte Privacy-Scanner bestand nach Korrektur einer synthetischen Git-Identität. Produkt-/Providerquellen sind gegenüber `ec63009` unverändert; erfolgreiche lokale Provider-Evidence des vorherigen Slices wird für diesen unveränderten Scope wiederverwendet. Nächster Schritt: Release-PR mit Windows-/Linux- und ausgewählten Runtime-Gates integrieren, danach Statuswahrheit abgleichen. |
| 2026-09-10 | [Release-PR #407](https://github.com/gecompat/SQL_Server_Lab/pull/407): Windows-CI bestand auf `72222c5`, Linux scheiterte an der Größenprüfung einer versteckten Paketdatei im neuen Test | Das Paket enthielt `.gitignore` korrekt; `Get-Item` im Test benötigte `-Force`. Die Windows-Fixture reproduziert nun dieselbe Hidden-Eigenschaft. Der Fehler wurde vor dem Fix erneut reproduziert, danach bestand die fokussierte Suite mit 20 PASS und vollständigem Fixture-Cleanup. Der Produktcode blieb unverändert; die korrigierte Linux-CI bleibt bis zur Ausführung offen. |
| 2026-09-10 | Statusangaben mit `REPOSITORY_AGENT_SKILLS_BACKLOG.md`, `PSR-007`, den öffentlichen Workflow-Aktionen, dem Windows-Template-Tool und den nativen Referenzgrenzen in `KNOWN_LIMITATIONS.md` abgeglichen | Skills und öffentliche Daten-VHDX-Bedienung sind vorhanden. Der interaktive OS-Menüpfad bleibt manuell, das separate Template-Tool automatisiert den dokumentierten Scope. Prepared-Manifest und SQL-2025-CLI sind nativ referenziert, aber keine allgemeine Provider-/Versionsfreigabe. Änderungen betreffen Dokumentation, zwei deklarative Einschränkungsnamen und einen Testhilfetext; kein Runtimepfad geändert. |
| 2026-09-10 | Nachweisindex an die vorhandene Capability-Inventur angebunden; erste Einträge erhalten erfolgreiche Offline-Prüfungen und den historischen Linux-Fehler getrennt | `RECORDED_HISTORY_ONLY` bleibt von `CurrentExecutionStatus=NOT_EXECUTED` getrennt. Die Inventur validiert Schema, Kalenderdatum, Größe und Pfadgrenze, lädt aber weder externe Quellen noch Rohlogs. Native SQL-Nachweise benötigen ausdrücklich Provider, SQL-Version und Integrationstest; keine neue Task-/Runtime-Registry und kein neuer Providernachweis. |
| 2026-09-10 | [Release-PR #407](https://github.com/gecompat/SQL_Server_Lab/pull/407) auf Revision `ac414ab` vollständig grün und nach `origin/main` integriert (`be0a165`) | Korrigierte Windows-/Linux-CI, Docker, Podman, Mixed, Adapter, Hyper-V und PR-Gate bestanden. Der frühere Linux-Fehler bleibt historische Evidence. Statuskorrektur folgt separat; die übrigen Funktions- und Gastabnahmen bleiben offen. |
