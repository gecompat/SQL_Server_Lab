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
| Privacy-Scanner und parallele Runtime | `validated` | Die Korrektur trennt flüchtigen State vom Quellscan und prüft dennoch erzwungen versionierte Runtime-Dateien sowie versteckte aktive Env-Dateien. Lokale Evidence auf `3bbe4157`: fünf isolierte Pester-Positiv-/Negativfälle (Runtimewurzeln, aktive Secretdatei, indexierte Runtime-Secretdatei, versteckte `.env`, ähnlich benannter Pfad) sowie drei Scanner-Contracts bestanden. Windows-/Linux-Gates folgen dem dokumentationsbetroffenen PR-Scope. |
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
| Hyper-V-Reconcile | `in_progress` | Isolierte native Runner für SQL-Konfiguration, SQL-Port, Testdatenbanken und External Runtimes ausführen; Ressourcen-, Netzwerk- und Storage-Reparatur separat mit No-op, Mutation, Resume, Persistenz und Cleanup nachweisen. Der erhöhte SQL-2025-Prepared-Referenzlauf auf `386d9159` bestand vollständig: Fresh-VM/OOBE, `PrepareImage`, Generalize, immutable Publish, differenzierender Manifestklon, EvaluationOnline über eine temporäre und wieder entfernte eigene NIC, `SQL_READY_RUN` (Major 17, vier Systemdatenbanken), Parent-Hash/Schreibschutz und Cleanup von VM, Child-VHDX, IPAM-Lease, Builder-Root sowie State-Root. SQL-Konfiguration, SQL-Port, Testdatenbanken und External Runtimes brauchen weiterhin ihre getrennten Reconcile-Nachweise. |
| Hyper-V-Sample-Parität | `planned` | `LAB_GENERATED`-Export und automatische Sample-Manifestausführung nativ mit Hash-/Identitätsbindung, Wiederverwendung und Cleanup prüfen. |
| Recovery-Härtung | `in_progress` | Netzwerk-Cleanup prüft Run-/Scope-Labels. Die native Docker-/Podman-Abnahme erstellt je ein eigenes und ein fremdes Netzwerk, blockiert die fremde Löschung, entfernt ausschließlich das eigene über den Produkt-Cleanup und bereinigt das fremde Testnetz danach explizit (je 3 PASS). Isolierte native Docker- und Podman-Batchabbrüche nach sichtbarer Providerressource bestanden: persistierte Worker-Recovery, eindeutige Run-Übernahme, idempotentes Resume und scopegebundener Cleanup (je 13 PASS). Auch der zweite öffentliche Cleanup-Aufruf beider isolierten SQL-2025-Runs ist ohne Fehler konvergent (`REMOVED`/`ALREADY_REMOVED`); Container und Volumes wurden vollständig entfernt. Der neue native Volume-Nachweis blockiert für Docker und Podman ein fremdes Run-Label vor dem Remove-Aufruf, entfernt ausschließlich das eigene Volume und bereinigt das geschützte Testvolume anschließend explizit (je 3 PASS). Ein dynamischer Offline-Contract erzeugt eine Junction beziehungsweise einen Symlink aus dem Run-Ressourcenpfad nach außen, verweigert ihn vor dem Hyper-V-Cleanup und bewahrt ein externes Sentinel (1 Contract). Gemischte Provider-Teilfehler bleiben abzuarbeiten; fremde Objekte erhalten und idempotente Wiederaufnahme belegen. |
| Evaluation-Watch | `implemented_partial` | Der vorhandene read-only Watch projiziert Windows-/SQL-Fristen registrierter Imageartefakte über stabile IDs, klassifiziert Ablaufzustände, erzeugt nur mit explizitem `RecordEvents` deduplizierte lokale Ereignisse und führt keinen Refresh aus (5 Contracts bestanden). Registrierte laufende Instanzen und deren getrennte Fristen sowie ein begrenzter lokaler Zeittrigger fehlen weiterhin. |
| State-Upgrades | `implemented_partial` | Der read-only Plan bindet jetzt den Quellhash. `Invoke-SqlServerLabRunStateUpgrade` migriert ausschließlich ausdrücklich mit `metadata.syntheticStateFixture=true` markierte unversionierte synthetische Legacy-States, sichert die Ausgangsrevision, schreibt atomar und journalisiert Commit oder Rollback (8 Contracts). Unbekannte, nicht markierte und produktive historische States blockieren weiterhin; breite Kompatibilitätsmatrix, persistentes Resume über harte Prozessabbrüche und jede Framework-/Repositoryaktualisierung bleiben offen. |
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
| Collation-Auswahl | `implemented_partial` | `COL-001` besitzt einen schema-validierten Katalog für SQL 2019/2022/2025 und die öffentliche tokenbasierte Suche `Find-SqlServerLabCollation` (4 Contracts). Die Suche verändert keinen State und ersetzt keine Live-Prüfung. Katalogbindung im Konsolen-/Manifestpfad und die SQL-seitige Postcondition über `sys.fn_helpcollations()` sowie `SERVERPROPERTY('collation')` vor beziehungsweise nach einer neuen Instanz bleiben offen. |
| Direkter SQL-Prepared-Locale-Pfad | `planned` | Bestehenden portablen Locale-Intent separat im direkten Manifestpfad nach Kaltstart und mit Cleanup abnehmen. |
| Legacy-WMI-Fortschritt | `implemented` (Offline-Abnahme; neue Gastabnahme offen) | Vorhandene WMI-, Aktivierungs-, Sysprep- und Shutdown-Reporter inventarisiert. Luecken im SQL-Receipt-Polling, Legacy-OOBE und direkten SQL-Setup-Abfragen verwenden nun denselben durchgehenden Reporter. Synthetischer Transport reproduzierte die fehlende Anzeige; Heartbeat, Ausgabe, Fehler vor/nach Transportbeginn und eigener/geliehener Reporter-Cleanup bestehen nach dem Fix. Der bestehende echte Pipeline-Abbruchtest bleibt Bestandteil der fokussierten Suite. Keine Aenderung am WMI-/SMB-Transport oder an dessen Abbruchlatenz; neuer isolierter Legacy-Gastlauf bleibt offen. |
| Reservierte Manifestfelder | `validated` (Bewertung) | [Einzelbewertung](RESERVED_MANIFEST_FIELDS_ASSESSMENT_2026-09-10.md) für alle neun direkten reservierten `serverConfig`-Felder, `customImage`, zwei `installMethod`-Werte und die gesonderten Adapterfelder abgeschlossen. Bestehende Collation-/Storage-/Derived-Image-Verträge haben Vorrang; direkte erste PITR-/Upgrade-Szenarien benötigen keine zusätzlichen Agent-/CLR-/Authentifizierungsschalter. Jeder spätere Bedarf besitzt Nutzen, Abhängigkeit, Risiko, relativen Aufwand und konkreten Folgeschritt. Felder bleiben reserviert; keine neue Runtimefreigabe. |
| Podman Golden RAG | `planned` | Bisher vor RAG am Modell-Pull beendeten Nachweis unter geändertem, nachvollziehbarem Input erfolgreich einschließlich Restart und Cleanup ausführen. |
| Hyper-V RAG/Agent | `planned` | Isoliertes SQL-Ziel verwenden und bisher fehlenden VM-Neustart samt Login-/Modell-/Lab-Cleanup nachweisen; Schutz gemeinsamer Testgruppen nicht umgehen. |
| Modellcache | `validated` (Bewertung; Nichtübernahme) | [Bewertung](SQL_AI_CAPABILITIES_ASSESSMENT_2026-09-10.md): vorerst kein gemeinsamer persistenter Cache. Ein Pull-Timeout belegt keinen Cachegewinn; ein sicherer Blob-/Lease-/Publish-Vertrag fehlt. Erst erfolgreichen geänderten Podman-Lauf messen, bei bestätigtem Engpass separate Umsetzung mit Digest-, Abbruch-, Konkurrenz- und Cleanup-Abnahme; Aufwand L. |
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
| Air-Gap-Pakete | `validated` (Bewertung) | [Bewertung](DISTRIBUTION_AND_OBJECT_STORAGE_ASSESSMENT_2026-09-10.md): erster späterer Slice bindet eine vollständige freigegebene SQL-2025-/Provider-/Szenariomenge, vertrauenswürdige Digests, sicheres Staging und echten Offline-Aufbau ohne Nachladen. Delta benötigt exakte Basis und Referenzschutz; Aufwand L nach Transfer-/State-/Recovery-Gates. Kein Medienpaket erstellt. |
| PolyBase/S3 | `validated` (Bewertung) | [Bewertung](DISTRIBUTION_AND_OBJECT_STORAGE_ASSESSMENT_2026-09-10.md): Docker-SQL-2025 plus eigener Single-Node-Store, HTTPS/Least Privilege, SQL-Assertions, unabhängiger Schreibnachweis, Restart/Resume/Cleanup; Aufwand L, weitere Provider separat. Positive MinIO-Vorauswahl wegen archiviertem, nicht gepflegtem Community-Repository zurückgenommen. Zuerst aktuelle Produkt-/Artefaktmatrix; kein Store installiert. |
| SSIS | `validated` (Bewertung) | [Bewertung](BI_CAPABILITIES_ASSESSMENT_2026-09-10.md): Windows-/SSISDB-Projektreferenz mit synthetischem Full-/Delta-Load, Commit-gebundenem Fortschritt, Secret-/Rechtebindung und Fehler-/Restart-/Cleanup-Abnahme festgelegt. Aufwand L; Umsetzung nach den offenen Plattform- und Szenariogates. Keine neue Runtimefähigkeit. |
| SSAS | `validated` (Bewertung) | [Bewertung](BI_CAPABILITIES_ASSESSMENT_2026-09-10.md): Tabular Import mit festem Modell, DAX-Assertions, nicht administrativer RLS-Prüfung, Processing-Resume und unabhängigem Restore festgelegt. Aufwand L; DirectQuery, Multidimensional und verteilte Identitäten bleiben getrennt. |
| BI-Pipeline | `validated` (Bewertung) | [Bewertung](BI_CAPABILITIES_ASSESSMENT_2026-09-10.md): gemeinsame Quell-/Warehouse-/Modellrevision und Fehler vor/nach Fakt-Commit bis zum Processing prüfen. Aufwand L zusätzlich zu den Einzelabnahmen; ein erster eigener Windows-Run folgt erst nach SSIS und SSAS. Keine Ende-zu-Ende-Evidence behauptet. |
| Remote Hyper-V | `validated` (Bewertung) | [Bewertung](HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md): zuerst read-only Hostregistrierung; später genau ein gebundener SQL-Run mit hostseitiger Identität, State, Autorisierung, Transfer- und Recoveryvertrag. Aufwand L; kein entfernter Host für diese Welle freigegeben. |
| Mehrbenutzerbetrieb | `validated` (Bewertung) | [Bewertung](HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md): Einzeloperator bleibt Standard; erster späterer Slice ist disjunkte read-only Inventur zweier synthetischer Identitäten. Mutation verlangt eigene Rechte-, Revisions-, Audit- und Konfliktabnahme, Aufwand L. |
| Cluster/HA/DR | `validated` (Bewertung) | [Bewertung](HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md): SQL-AG zuerst bei konkretem Szenario; FCI, SSISDB-HA, Worker, SSAS-WSFC und Queryknoten erhalten getrennte Abnahmen und Aufwand L. Gastfailover auf einem Host belegt keine physische HA; keine Clusterlaufzeit implementiert. |
| Automation-API/IaC | `validated` (Bewertung) | [Bewertung](HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md): vorhandene PowerShell-API bleibt Standard; lokaler versionierter read-only Plan-/Result-Vertrag als nächster Schritt, Aufwand M. Kein neuer Netzwerkdienst; genau ein späterer IaC-Pilot erst bei konkretem Konsumenten. |
| KI-TLS-Gateway | `validated` (Bewertung) | [Bewertung](SQL_AI_CAPABILITIES_ASSESSMENT_2026-09-10.md): späterer SQL-seitiger Docker-Referenzlauf mit eigenem Gateway, begrenztem Trust und echtem Embed-/Negativ-/Restart-/Cleanup-Nachweis; Podman/Hyper-V separat. Aufwand L; vorhandener Controller und HTTPS-Stub ersetzen diese Abnahme nicht. |
| ONNX | `validated` (Bewertung) | [Bewertung](SQL_AI_CAPABILITIES_ASSESSMENT_2026-09-10.md): isolierter SQL-2025-Windows-Child-Slot nach External-Runtime-Abnahme, gebundene Modell-/Tokenizer-/Runtimeartefakte und eigene SQL-/Restart-/Cleanup-Prüfung. Aufwand L; kein Modell oder DLL ungeprüft installiert. |
| ANN | `validated` (begrenzte native Abnahme) | Auf Benutzerauftrag vom 2026-09-10 Preview konkret unter SQL Server 2025 getestet: Abnahmeversion 1.0 auf Revision `6fc518847eaefb021c31666ca8386da5b53e1908`, Docker und Podman getrennt `PASS`, SQL-Build `17.0.4075.5`, tatsächlich unversionierte Indexmetadaten. 4.096 Vektoren, vier Suchfälle mit Recall@10 jeweils 1,0 vor/nach Stop/Start, Distanzen, Filter und Cleanup bestanden. Kleine Testlaufzeiten ergeben keine allgemeine Performancezusage. Spätere Inkompatibilität verlangt angepasste oder eigene Funktionsversion; Hyper-V, Backup/Restore und produktiver Szenarioexecutor bleiben separate Erweiterungen. |
| Zusätzliche Cloudanbieter | `validated` (Bewertung) | [Bewertung](SQL_AI_CAPABILITIES_ASSESSMENT_2026-09-10.md): ohne konkreten Bedarf und gebundene Kosten-/Egressgrenze keine Aktivierung. Später genau ein Provider mit aktuellem Fähigkeitsnachweis, SecretRef und begrenztem synthetischem Smoke; Aufwand M je Adapter, keine bezahlten API-Läufe ausgeführt. |

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
| 2026-09-10 | Privacy-Scanner gegen den integrierten Stand `3bbe4157` erneut verifiziert | Fünf isolierte Pester-Positiv-/Negativfälle und drei Scanner-Contracts bestanden. Der Status ist auf `validated` berichtigt; der nachfolgende dokumentationsbetroffene PR liefert die Windows-/Linux-Regression. |
| 2026-09-11 | Native Netzwerk-Cleanup-Abnahme für Docker und Podman ausgeführt | Je Provider: fremdes Netzwerk bleibt nach abgelehntem Produkt-Cleanup erhalten, eigenes Netzwerk wird ausschließlich mit passendem Run-/Scope-Label entfernt, geschütztes Testnetz wird anschließend explizit bereinigt (je 3 PASS). Weiterer Recovery-Scope bleibt offen. |
| 2026-09-11 | Native Docker-/Podman-Batchabbrüche und wiederholten Cleanup ausgeführt | Je Provider wurde der separate Scheduler erst nach sichtbarer eigener SQL-2025-Ressource hart beendet. Persistierte Worker wurden deterministisch übernommen, Resume erzeugte keine doppelten Runs und der Batch-Cleanup entfernte beide Container und Volumes (je 13 PASS). Zwei weitere isolierte SQL-2025-Runs pro Provider bestätigten den zweiten öffentlichen Cleanup-Aufruf als fehlerfreie Konvergenz (`REMOVED`/`ALREADY_REMOVED`). Ownership-/Junction-Manipulation und gemischte Teilfehler bleiben offen. |
| 2026-09-11 | Native Volume-Ownership-Abnahme für Docker und Podman hinzugefügt | Je Provider: ein fremdes Run-Label blockiert den Produkt-Remove vor der Mutation, das eigene Volume wird entfernt und das geschützte Testvolume anschließend explizit bereinigt (je 3 PASS). Junctions und gemischte Provider-Teilfehler bleiben offen. |
| 2026-09-11 | Junction-/Symlink-Grenze des Hyper-V-Cleanup dynamisch geprüft | Ein isolierter Offline-Run bindet eine Junction beziehungsweise einen Symlink aus resources/hyperv auf ein externes Ziel. Der Cleanup-Pfad lehnt den Ausbruch vor einer Mutation ab und das externe Sentinel bleibt erhalten (1 Contract, Suite 64 PASS). Gemischte Provider-Teilfehler bleiben offen. |
| 2026-09-11 | Evaluation-Watch gegen den integrierten Stand geprüft | Fünf Contracts belegen stabile Artefakt-IDs, Fristenklassifikation, read-only Standardpfad, deduplizierte lokale Ereignisse und sanitisierte Ausgabe. Laufende Instanzen und Zeittrigger bleiben als Restscope offen. |
