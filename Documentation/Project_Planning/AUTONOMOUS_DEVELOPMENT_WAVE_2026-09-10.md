# Autonome Entwicklungswelle nach der Repository-Durchsicht

| Merkmal | Wert |
|---|---|
| Status | `IN_PROGRESS` – nach ausdrücklichem Wiederaufnahmeauftrag vom 2026-09-30 |
| Stand | 2026-09-30 |
| Auftrag | Aktuelle Entwicklungswelle aus Orchestrator Chat 2 mit denselben Regeln fortsetzen; C# bleibt USER_DEFERRED |
| Ausgangspunkt | Durchsicht von `9cfd144`, vor Veröffentlichung gegen `ca9f09e` abgeglichen |
| Ziel | vollständige Abarbeitung der Implementierungs-, Abnahme- und Bewertungsaufgaben bei konsistentem Gesamtsystem |
| Reihenfolge | Konkretisierung des nachgelagerten Horizonts aus Abschnitt 12 des [Ausführungsplans](DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md) |

## Wiederaufnahmeauftrag vom 2026-09-30

Der neue ausdrückliche Auftrag setzt die aktuelle Entwicklungswelle mit den
bisherigen Regeln fort. Der neue Orchestrator-Heartbeat ist bestätigt ACTIVE;
der alte Zeitplan bleibt PAUSED. Der historische Benutzerstopp unten bleibt
erhalten. Es gibt genau einen aktiven Implementierer und keine zweite
Backlogwahrheit. Geschützte Shared-Umgebungen bleiben unangetastet.

Der enge erste Slice I ergänzt Auswahl, Vorschau, Cancel und bewussten Stop
einer bereits in derselben Modulsitzung gehaltenen llama.cpp-Session in CLI/GUI.
Die serverseitige Auswahl erhält den bestehenden Worker-/Cleanupvertrag und
zeigt Verbrauchercoverage UNKNOWN. Fremdprozesse, Start/Restart und
Modellaktionen bleiben offen. Synthetische Core-/HTTP-/CLI-/Browserprüfungen
sind fokussiert bestanden. Der breite Lauf endete mit 33/34 PASS und einem
AnalyzerFAIL durch gemischte Zeilenenden; nach kontrollierter eigener
Analyzer-Recovery und Korrektur bestand der notwendige abschließende Analyzer.
Der unabhängige Lifecycle-/Cleanup-Nachreview ist geschlossen. Der opt-in
Windows-GuidedStop-Nachweis vom 2026-09-30 bestand mit Exitcode 0: eigene
synthetische Worker-/Kindprozesse und Keydatei abwesend, Nachbarkind beim Stop
aktiv und danach separat own-cleaned, Testroot-Cleanup bestätigt. Das ist
native Prozessführung im engen Scope, keine SQL-/Modell-/Compute-/Provider-
oder manuelle UI-Abnahme. Der abschließende Dokudelta-Review bleibt separat.

Der anschließende Windows-PR-Gate auf `c12defe2` wurde bei weiterlaufender
Analyzerarbeit durch sein 10-Minuten-Jobbudget beendet. Dieser unvollständige
CI-Nachweis bleibt separat vom lokalen Analyzerfehler dokumentiert. Das
begrenzte Budget des bestehenden statischen Matrixjobs ist auf 20 Minuten
erhöht; Testauswahl und andere Jobbudgets bleiben unverändert. Der neue
Windows-Gate ist bis zum tatsächlichen Abschluss weiter offen; laufende
Providerprüfungen werden durch diese Korrektur nicht abgebrochen.

## Abschlusscheckpoint vom 2026-09-29

Der Benutzer hat die autonome Entwicklung nach einem konsistenten Abschluss
ausdrücklich gestoppt. Der Orchestrator-Heartbeat ist pausiert. Die nachstehenden
historischen Aufträge und offenen Aufgaben bleiben dokumentiert, erteilen aber
keine Freigabe für weitere automatische Bearbeitung.

Der letzte Produktslice H (`AIX-001`/`AIX-008`) wurde mit
[PR #662](https://github.com/gecompat/SQL_Server_Lab/pull/662) als
`01124cefe2abd74855a8ff52b7ec966960b4cd89` integriert. Der Merge-Tree entspricht
dem geprüften Head `7f93b8073af11f1d6fa65fa990c8ad80934048fd`.
Die [Pflicht-CI](https://github.com/gecompat/SQL_Server_Lab/actions/runs/36553670109)
bestätigt Windows-/Linux-Static, Docker, Podman, Mixed, Hyper-V-Lifecycle,
Adapter und PR-Gate am selben Head. Nach einem fehlgeschlagenen Podman-Job
bestand dessen einzeln autorisierter Wiederholungslauf; die ursprüngliche
Fehlerursache bleibt `UNKNOWN`. Erfolgreiche Provider wurden dabei nicht erneut
ausgeführt. Geschützte Shared-Umgebungen waren nicht Teil dieses CI-Pfads.

Lokal bestanden 99 synthetische Installerprüfungen und die acht betroffenen
Suites des abschließenden Plattform-Testdeltas; die unabhängigen Reviews sind
ohne offene Findings abgeschlossen. Der eigene native Windows-x64-CPU-Nachweis
bestand neun Prüfungen einschließlich Cleanup. `BINARY_PROBE_PASSED` belegt
ausschließlich den gepinnten Paketpfad mit modellfreier Versionsprobe.
Die beiden vorherigen fehlgeschlagenen Nativeversuche bleiben historische
Fehlernachweise; der erste Grund bleibt unbekannt, der zweite führte zur
geprüften Korrektur der Logreader-Reihenfolge.

H bleibt `IMPLEMENTED_PARTIAL`: Compute, SQL und Modelle sind `NOT_CHECKED`,
weitere Plattformen und Backends offen, Empfehlung `UNASSESSED` und allgemeine
Mindest-VC-/OS-/CPU-Kompatibilität `UNKNOWN`. Maßgeblich bleiben der
[Installationsvertrag](../Architecture/LLAMA_CPP_INSTALLER.md), die
[bekannten Grenzen](../Quality/KNOWN_LIMITATIONS.md), die unten zugeordneten
Folgearbeiten und deren bestehende Fachbacklogs. C# bleibt `USER_DEFERRED`.
Dieser Abschluss eröffnet keinen zweiten Backlog und behauptet keine
vollständige Abarbeitung der Entwicklungswelle. Rohdiagnosen und bewahrte
Fehlerartefakte bleiben ausschließlich lokal und unversioniert.

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

## Ergänzungsauftrag vom 2026-09-27: Capability-Matrix und autonome Fortsetzung

**Priorität:** Autonome Implementierung und zugehörige Tests haben Vorrang.
Der Abgleich der Provider-/SQL-/OS-/Capability-Matrix wird ab sofort begleitend
bearbeitet; seine vollständige Erstellung ist keine neue Sperre vor weiterer
Featureentwicklung. Unabhängige Inventur oder Evidence-Prüfung darf ein
separater Agent übernehmen. Pro atomarer Implementierung bleibt es bei genau
einem Verantwortlichen; mutierende Providerprüfungen werden weiterhin über
den vorhandenen Runtime-Lock serialisiert.

Dieser Ergänzungsauftrag erweitert vorhandene Aufgaben, eröffnet aber keinen
zweiten Backlog und keine unabhängige Capability-Registry:

| Bestehender Bezug | Ergänzung und offener Umfang |
|---|---|
| `BASE-001` bis `BASE-005` im [Ausführungsplan](DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md) | Quellinventur und vorhandenen Evidence-Index zu einer maschinenlesbaren, für Menschen lesbaren, mehrdimensionalen Statussicht zusammenführen; vorhandene Abnahmen übernehmen, Widersprüche im betroffenen Scope berichtigen und Drift testseitig absichern. Der bisherige Inventur-Slice bleibt abgeschlossen, die vollständige Kombinationenmatrix ist offen. |
| `CORE-102` und [Issue #619](https://github.com/gecompat/SQL_Server_Lab/issues/619) | Gemeinsamen Capability-Entscheid um aktuelle, read-only Host-/Backend-Readiness und passende historische Evidence ergänzen. API, Konsole/Fallback und Browser verwenden denselben Vertrag; External Languages sind der erste vertikale Anwendungsfall. Issue #619 bleibt offen. |
| `SFT-711`, `SFT-712` im [External-Languages-Plan](EXTERNAL_LANGUAGES_IMPLEMENTATION_PLAN.md) | Python, R, Java und C# getrennt nach tatsächlichem Provider-/OS-/SQL-/Buildpfad behandeln. SQL-2022-Hyper-V und SQL-2025-cgroup-v2-Nachweise wiederverwenden. C#-Build ist belegt; SQL-Registrierung, Launchpad-Roundtrip, Workeridentität und Neustart sind noch offen. |
| `PSR-011` im [Persistenzbacklog](PERSISTENT_STORAGE_REUSE_AND_LAB_DATA_BACKLOG.md) | Vorhandenen Retained-Store-Removal-Vertrag und dessen noch fehlende native Abnahme prüfen, keine parallele Löschimplementierung eröffnen. |
| Weitere IDs aus den verlinkten Fachbacklogs | Jede gefundene Implementierungs- oder Abnahmelücke dem bestehenden Eigentümer zuordnen; vor einer neuen ID die kanonische Registration Authority und Duplikate prüfen. |

### Konsolidierter Bedien- und Ressourcenauftrag vom 2026-09-27

Der ergänzende Auftrag erweitert die folgenden bestehenden Verantwortungen;
Abschnittsnummern sind Anforderungsreferenzen, keine neuen Task-IDs. Die
Reihenfolge bleibt im [Ausführungsplan](DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md).
Zuerst werden Anforderungen vollständig zugeordnet, danach unmittelbar kleine
Implementierungs- und Abnahmeslices bearbeitet. Eine vollständige empirische
Matrix ist keine Vorbedingung für unabhängige nutzbare Verbesserungen.

**Produktentscheidung:** Ein generischer Parametersatz unter „Alle öffentlichen
Befehle“ erfüllt keine geführte Fachbedienung. Unterstützte Operationen brauchen
einen verständlichen fachlichen Einstieg in CLI und GUI sowie dokumentierte
nichtinteraktive PowerShell-Aufrufe. Alle verwenden dieselben Planner,
Executor-, State-, Reconcile- und Recovery-Verträge. Fehlt der sichere Core,
bleibt eine Implementierungsaufgabe offen; ein deaktivierter Eintrag genügt nicht.

| Anforderung | Bestehende Aufgaben und Verträge | Ausgangspunkt und offene Abnahme |
|---|---|---|
| 0–1: Autorität, Datenschutz, aktueller Stand | `BASE-001` bis `BASE-005`, Arbeitsregeln, Issue #619 | Code, Exporte, Schemas, Kataloge, Menüs, `Ui/`, Tests und Evidence gemeinsam prüfen. Frühere Chatstände sind Suchhinweise. Lokale Diagnostik und veröffentlichbare Evidence bleiben getrennt; keine konkurrierenden Backlogs oder Implementierer. |
| 2–3: verständliche Fachbereiche | `UX-201` bis `UX-206`, `UX-621/622`, `CUI-001` bis `CUI-011`, Console-UI- und Querschnittsbacklog | Vorhandene Menü-/Browseradapter wiederverwenden. Zielbereiche: Lab-Umgebungen, geschützte Testsystem-Matrix, Hyper-V-Vorlagen/Slots, Ressourcen/Downloads, Host-Dienste/Modelle, Verbindungen/CMS, SQL-Lab-Grundkonfiguration, Wartung/Recovery und Vorgänge. Globale und kontextuelle Zugänge binden dieselbe Aktion. Keine ungeklärten internen Begriffe oder ständig aufgeklappten technischen Großmenüs. Vollständige Fachdialogparität ist offen. |
| 4: Grundkonfiguration und späterer Provider | `UX-202/204`, `CORE-102/108/111`, Storage- und Batchvertrag | `Private/InitialSetup.ps1` und bestehende Providererkennung weiterverwenden. Lab_Base/Lab_Data mit Zweck, effektivem Ort, Erreichbarkeit, Schreibbarkeit und freiem Speicher anzeigen; native Containerspeicher nicht fälschlich unter Lab_Data verorten. Bereite Container nicht an Hyper-V-Voraussetzungen binden. Provider später erneut erkennen/einrichten, vorhandene Konfiguration und Komponentenbindung erhalten; nicht installiert/erreichbar/konfiguriert/unterstützt unterscheiden. |
| 5–6: Slots und Reserve | `HV-401` bis `HV-508`, `CORE-107/111`, Batch-/Queue-/Resume-Vertrag | Zielbestellung und bewusste Einzel-/Batch-Vorbereitung über denselben Planner. Medium, OS-/SQL-Prepared-Vorlage, Windows-/SQL-Slot sowie frei/reserviert/belegt/ablaufend/abgelaufen/fehlerhaft unterscheiden. Eignung, Restlaufzeit, Kosten und erforderliche Änderungen begründen; Alternativen zulassen, gemeinsame Voraussetzungen deduplizieren, konkurrierende Reservierung und Cold Path prüfen. Reservepolicy zentral in Grundkonfiguration: Profilbestand einschließlich null, Mindestrestlaufzeit, separate Warnfrist, Budget, Parallelität und Erneuerung. Default ist Auffüllempfehlung; automatische Auffüllung nur explizit aktiviert. Unbekannte oder ablaufende Slots nicht still voll zählen. |
| 7: Evaluation, Ersatz und Migration | `CORE-107`, Evaluation-Watchdog, FULL_INSTANCE_EVALUATION_REFRESH_BACKLOG, WINDOWS_SLOT_ACTIVATION_BACKLOG, SQL_GUEST_EVALUATION_EVIDENCE_BACKLOG | Windows-/SQL-Fristen getrennt und mit Quelle/Aktualität führen. Freien Slot ersetzen, rekonstruierbares Lab neu aufbauen und zustandsbehaftete Migration getrennt behandeln. Inventar umfasst je Scope Datenbanken, Logins/SIDs, Rechte, Jobs, Konfiguration, Schlüssel, External Languages, CLR, FILESTREAM und Dienste. Gleichwertigkeit, Cutover, Rückfall nach Zielschreibzugriffen und Cleanup explizit planen; Unübertragbares blockieren oder konkret ausschließen lassen. Clone ist kein Evaluationsreset. Lokale Prüfung, Scheduler und Benachrichtigung separat abnehmen. |
| 8: providerübergreifendes Lab | MULTI_INSTANCE_MULTI_VERSION_ENVIRONMENTS_BACKLOG, Batch-, Topologie-, Manifest- und ProviderSubRun-Verträge | Gemeinsame Labidentität mit Komponenten, Abhängigkeiten, Verbraucherbeziehungen und Gesamtstatus erweitern, kein zweites Modell. Provider/Ausführungsort je Komponente einschließlich Host-/Shared-Diensten; Start/Stop/Änderung/Migration/Cleanup mit Teilfehlern und Resume. DNS, Ports, TLS und Identitäten gesondert prüfen; gemeinsame Dienste beim Lab-Removal erhalten. Das Beispiel SSIS auf Podman erteilt keine technische SSIS-Freigabe. |
| 9: nachträgliche Änderungen | `CORE-101` bis `CORE-106`, `CNT-211` bis `CNT-214`, `HV-601` bis `HV-607`, `UX-202/622` | Erstellbarkeit beweist keine Änderbarkeit. Pro Eigenschaft aktueller/gewünschter Wert, Default/Overrideherkunft, gültige Werte, Voraussetzungen, Reset/Removal und konkreter Weg: live, Dienst-/VM-/Containerrestart, Neuerstellung, Neuinstallation, Migration, manuell, nicht implementiert oder technisch unmöglich. Umfasst Version/CU/Edition, CPU/RAM, Ports/Netz, Storage, SQL/TempDB/Collation, Autostart, Datenbanken, Software/Sprachen, KI/Modelle und Komponenten. Vorbefüllte Fachdialoge mit Alt-/Neu-Plan statt JSON-/State-Bearbeitung. |
| 10: bewusste Hostdienststeuerung | `AIX-001/003/007/008`, `AI-20`, AI_EXTERNAL_MODEL_ACCELERATION_BACKLOG | Inventur von Hardware, Runtimeinstallation, Prozess/Dienst, gespeicherten und geladenen Modellen trennen; llama.cpp, Ollama, OVMS und HTTPS-Gateways berücksichtigen. Bewusst ausgewählten, eindeutig gebundenen Dienst darf ein berechtigter Hostbenutzer auch ohne Lab-Ownership starten/stoppen/neustarten/konfigurieren. Rechte, bekannte Verbraucher und Unsicherheit anzeigen; keine Namens-Kills oder Rechteumgehung. Automatischer Cleanup bleibt ownershipgebunden. Einzel-/Mehr-GPU, CPU/NPU, Backendkombinationen, Ports, Modellpfade, Budget, Sitzungslaufzeit und Autostart nur im konkret unterstützten Scope anbieten; RBAC ist keine Vorbedingung der Einzelplatzlösung. Manueller Fremdstart-Lifecycle ist noch offen. |
| 11: Modelle | `AI-20A/B`, `AI-30`, `AIX-008`, SQL2025_AI_PLATFORM_BACKLOG und VECTOR_EMBEDDING_BACKLOG | Kataloganzeige und Modelldownload vorhanden; vollständiger Import-/Load-/Warmup-/Unload-/Wechsel-/Datei-Removal-Workflow offen. Diese Aktionen getrennt halten. Revision, Format, Sprache, Lizenz, Runtime, RAM/VRAM, Kontext und Backend prüfen; Herstellerangabe, statische Eignung und Benchmark kennzeichnen. Expliziter experimenteller Pfad braucht nicht die gesamte Benchmarkmatrix. Embedding/Generation unterscheiden; Dimensions-/Revisions-/Inputprofilwechsel mit Re-Embedding und SQL-Bindungen sichtbar machen. Router-/Mehrmodellfähigkeit nur nach Runtime- und Adapternachweis. |
| 12: vollständige Beschaffung | `SFT-711/712`, `AIX-001/008`, vorhandene Medien-/Sample-/ResourceSet-Verträge | Funktion → Abhängigkeiten → Quelle → Download/Import → Installation → Konfiguration → Funktionsprobe → Betrieb. OS, SQL/SP/CU, Images, Samples, Sprachpakete, KI-Runtimes/Modelle, Tools und transitive DLLs/Treiber/SDKs einbeziehen. Katalogisiert/verfügbar/herunterladbar/lokal/geprüft/installiert/konfiguriert/funktionsfähig/nativ getrennt. Manuelle Beschaffung mit genauem Paket, Link, Auswahlkriterien, Zielordner und Resume. Ordner erst im bestätigten Vorgang anlegen. Keine stillen globalen PATH-/Treiber-/Dienständerungen; Bootstrapper nicht als Vollmedium ausgeben. llama.cpp-Runtimeinstaller von Backend-/Releasewahl bis versioniertem Funktionstest fehlt; Modelldownload ersetzt ihn nicht. Installiert/upstream/katalogisiert/empfohlen unterscheiden, neueste Version experimentell ohne stilles Upgrade zulassen. |
| 13: Quellen und Integrität | `BASE-001/004`, `CORE-102/104`, Medien-/Trust-/Cache-Verträge und CU-Lane | Lokale persistente Overrides samt effektiver Herkunft und Reset sowie CLI-/GUI-Editor fehlen als allgemeiner Pfad. Default und einmalige Auswahl trennen; Ressourcenidentität, Quelle und Byte-Revision unterscheiden. URL, API, Registry, Resolver, Parser/Allowlist, Variante, Architektur, Sprache/Edition, Ziel und Integrität gemeinsam behandeln. Redirects/Produkt/Hash/Signatur revalidieren, Sollhash niemals bei Drift überschreiben. Fehlenden Sidecar nur im freigegebenen Vorgang als lokale SHA256-Baseline erstellen; keine Herkunftsbehauptung. Zielorte anzeigen, kein Vollhashing bei Cursorbewegung. |
| 14: lokale Aktualität und Resource Watch | bestehende CU-Lane / CU_MONITORING_BACKLOG, `BASE-004` | Deterministische explizite Prüfung mit Cache statt Netz bei Menüwechsel. Erreichbarkeit, Redirect, Versions-/Assetdrift, Katalogalter; Offline/Timeout/Rate-Limit/Parserfehler von keine Änderung trennen. Quellen/Intervalle/Timeouts/Benachrichtigung konfigurierbar machen. Monatlichen CU-Watch auf Windows/SQL, Runtime-/Modellrevisionen, Samples und Tools erweitern; Quelle, Zeitpunkt, Alt/Neu, betroffene Fähigkeit und nächste Aktion in deduplizierten Issues. Ein Prüfausfall darf nicht aktuell bedeuten. Zeitplan und echte erfolgreiche Läufe getrennt. KI-Recherche/PR optional, Issue allein startet keinen Agenten. Kein Download/Install/Support allein wegen neuer Releases. |
| 15: Samples, Testmatrix und CMS | `HV-505`, `UX-202/204`, TestEnvironment-, Sample- und Connection-Center-Verträge | AdventureWorks/LT/DW, WideWorldImporters/DW, Contoso-Größen, Northwind, Chinook, Stack-Overflow-Varianten vollständig katalogbezogen prüfen. Vorabdownload/Import/Erstellung/nachträgliche Änderung providerneutral; Format BAK/SQL/Bundle/BACPAC/Attach, Größen, Version/Edition, DB-Namen/Konflikte und Handlerstatus trennen, LAB_GENERATED wiederverwenden. Beschreibend ist nicht bestellbar. Testmatrix als geschützte Gruppe mit Gesamtstatus/Start/Stop/Prüfung/Reparatur/Neuaufbau/Removal; Einzelaktionen umgehen Schutz nicht. CMS optional, mit eigenem Einrichtungs-/Prüf-/Syncpfad und Endpointabhängigkeiten. |
| 16: Wartung und Testreste | `CORE-105/106/109`, `PSR-011`, Maintenance-/Cleanup-Audit-/Storage-/Runtime-Sync-Verträge | Runs, VMs/Container, Slots, Disks/Volumes, Netze, Images/Vorlagen, Caches, Downloads, Diagnostik und abgebrochene Vorgänge einbeziehen. Fehlende Registrierung heißt nicht fremd. Verwaltet/geteilt/behalten/verwaist mit Nachweis/möglicher Testrest/ungeklärt/nachweislich extern von Nutzung und Löschbarkeit trennen. Marker/Journale/Labels/Receipts/Referenzen korrelieren; Namen/Pfade sind keine Autorität. Details → Zuordnung/Reparatur → konkreter bestätigter Entfernungsplan → Abwesenheitsprüfung/Resume. Kein nachträglicher Übernahmeschalter erfindet Evidence. Operationsabsicht vor Mutation, Ressourcen-ID danach; Platzgewinn belegt oder geschätzt kennzeichnen. |
| 17: Matrix | `BASE-001` bis `BASE-005`, `CORE-102`, Issue #619 | Bestehende Statusdimensionen um Beschaffungs-/Installationsvollständigkeit und geführte CLI-/GUI-Abdeckung ergänzen. Alle katalogisierten SQL-Versionen 2000–2025 und spätere, historische Server/Core/Desktop/Architektur/Sprache/Patches sowie Linux/Clientpfade erfassen. Unbekannt, Legacy, nicht getestet und technisch ausgeschlossen unterscheiden; ungültige Kombinationen nicht zwangsläufig installieren. Historische Native Evidence erhalten, Regression risikobasiert an geänderten Scope binden. |
| 18: Funktionsfamilien | bestehende Fachbacklogs in Project_Planning/README, `BASE-001/003` | OS/SQL/Locale/Aktivierung; Lifecycle/Ressourcen/Netz; CU/Upgrade; Backup/Restore/PITR/Import/Export; Persistenz/Retention/Attach/FILESTREAM; Mehrinstanz/-version/Mixed; Sprachen/Software; Vector/Embedding/RAG/Metriken/Agent/Re-Embedding; External Models/TLS/ONNX/Cloud; Geräte/Benchmark; Evaluation/Recovery/Portabilität; Observability/UX/Queue/Scheduler; Szenarien/Faults; PolyBase/S3; SSIS/SSAS/BI; AG/FCI/HA/DR/Scale-out; Remote-Hyper-V/Air Gap/API; Treiber/Security/CDC/Event/JSON/REST/Hybrid Search/Collation/Linked Server/MSDTC bleiben getrennt zugeordnet. Keine sofortige Implementierung aller Zukunftsfunktionen und keine Wiedereröffnung erledigter Slices. |
| 19–21: Benutzerreisen, Integration und Bericht | `BASE-004/005`, `UX-204/206`, bestehende Abnahmematrizen und autonomer Zyklus | Je Slice Startzustand → Menüweg → Eingaben → Vorschau → Ausführung → fachliches Ergebnis → Wiederholung → Fehler/Resume → Cleanup. Labels/Ziel/Defaults editierbar, Zurück ohne Eingabeverlust, Abbruch ohne Mutation, Auswirkungen/Downtime/Daten-/Verbraucherwirkung, echter Fortschritt, Fehler mit nächstem Schritt, keine Secrets im generischen Formularstate/Log. Contract- und Native-Tests getrennt. Dokumentation allein beendet den Auftrag nicht. |

**Nachverfolgung pro Slice:** Anforderung → obiger bestehender Task/Vertrag →
konkreter Code → CLI-/GUI-Einstieg → Test → scopegebundene Evidence → Restarbeit.
Die Ausgangsklassifikation lautet je Einzelfall: vollständig vorhanden und
abgenommen; Core vorhanden, Bedienung fehlt; teilweise implementiert; geplant
ohne Executor; bisher nicht erfasst; technisch/lizenzbedingt eingeschränkt;
mangels Evidence ungeklärt. Die Zuordnung oben ist kein pauschaler PASS.

Die vierzehn verpflichtenden Benutzerreisen sind: Grundkonfiguration mit direktem
Container-Lab; späterer Provider ohne Konfigurationsverlust; Einzel-/Batch-Slots
mit Reserve; Ablaufwarnung/Ersatz/abgegrenzte Migration; Mixed-Lab; geführte
Änderung bestehender Umgebung; bewusst manuelle Hostdienststeuerung; getrennte
Modellaktionen; llama.cpp-Runtimebeschaffung bis Funktionsprobe; Quellenoverride
und Reset; Online/Offline/Redirect/Hashfehler/Update; geschützte Testmatrix/CMS;
eigene/unklare/geteilte Cleanupfälle; Resource Watch einschließlich Prüfausfall.
Jede bleibt offen, soweit kein passender konkreter Nachweis vorliegt.

External Languages bleiben unabhängig von Engine-cgroup-Support und SQL CLR:
Launchpad/Sprache, rootful/rootless, v1/v2, WSL/native Host und tatsächliche
Podman-Engine binden. Podman-6/v1-Ausschluss gegen aktuelle Herstellerquelle
prüfen; daraus keinen v2-Ausschluss folgern. SQL2025 shared-user-v2 nur im
belegten Scope mit geänderter Isolation; SQL2022/v2 bleibt eigene Forschung.
Preflight-Abweisung ist kein Sprach-Roundtrip. C#-Runnerimplementierung ist
keine native C#-SQL-Abnahme.

**Erster integrierter Slice:** Die CU-Watch-Reportprojektion ist an `Sources`
und `LatestCatalog` gebunden und synthetisch geprüft. Der folgende Prüfadapter
behandelt harte Check-/Reportfehler und reguläres `UNCLEAR` mit bereinigtem
Hinweisversuch vor dem roten Workflowabschluss. Infrastrukturfehler außerhalb
des Adapters und echte End-to-End-Benachrichtigungsabnahme bleiben separat.
Der geplante monatliche Workflow besitzt einen erfolgreichen Schedule-Lauf
`33500598035` vom 2026-09-01; das beweist weder heutige Quellenaktualität noch
eine allgemeine Resource-Watch-Abnahme. Fehlender allgemeiner Quelleneditor,
llama.cpp-Runtimeinstaller und manuelle Hostdienststeuerung bleiben separat.

### Nächste abnehmbare Schritte des Bedienauftrags

Stand 2026-09-28: Die Zielnavigation ist in
[Abschnitt 4.1 des Ausführungsplans](DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md#41-kanonischer-bedienpfad)
konsolidiert. Dies ist ein Planungsabschluss, keine implementierte
Bereichsmigration. Die nachfolgenden Schritte konkretisieren die vorhandenen
Tasks; sie erzeugen weder neue IDs noch einen zweiten Backlog. Die vollständige
Anforderungszuordnung oben bleibt gültig. `NEXT` bezeichnet einen ausführbaren
Schritt, `FOLLOW_UP` dessen nächste Erweiterung, nicht den Status der gesamten
Aufgabe. C# bleibt `USER_DEFERRED`.

**IMPLEMENTED – `UX-202/204`, `CORE-107`: Evaluationsfristen verständlich prüfen.**
Benutzeraufgabe: vorhandene Windows-/SQL-Fristen lesen, einen Artefakt- oder
Instanzeintrag auswählen und die nächste erforderliche Handlung verstehen.
`Get-SqlServerLabEvaluationWatch` liefert `Items` und `InstanceItems`
ohne Runtimezugriff; der Fachdialog ist in CLI und GUI implementiert. Zuständig
sind der Evaluation-Watchdog im
[Querschnittsbacklog](CROSS_CUTTING_PLATFORM_CAPABILITIES_BACKLOG.md#evaluation-watchdog-und-benachrichtigung)
und die bestehenden SQL-Gast-Evidence-Verträge. Der Konsoleneinstieg unter
Wartung und ein eigener Browserdialog verwenden denselben öffentlichen Core
ohne `RecordEvents`, Trigger oder Gastprobes. Keine manuelle ID-Eingabe und
kein Umweg über den generischen Befehlskatalog.

Abnahme: Windows/SQL sowie Artefakt/Instanz bleiben getrennt; Quelle,
Evidence-Aktualität, Restlaufzeit und nächster Schritt sind sichtbar. Leere
Liste, fehlende oder veraltete Evidence ergeben keinen pauschalen Gültigkeits-
oder Betriebsbereitschaftsnachweis. Lesen erfolgt ausdrücklich, Zurück und
Abbruch verändern nichts; erneutes Lesen ist möglich. Tatsächlich importierte
Menühandler und Browseraktionen prüfen Auswahl, Fehler, leeres Ergebnis,
`UNKNOWN` und unterlassene Mutation. Bestehende EvaluationWatch-, ConsoleUI-
und WorkflowUI-Suites sowie die betroffene Regression sind erforderlich.
Native Tests sind für die reine Bindung dieses unveränderten read-only Cores
nicht erforderlich. Abschluss bedeutet ausschließlich geführte Fristenanzeige;
Ersatz, Migration, Scheduler und Benachrichtigung bleiben offen.

Der gemeinsame Adapter `Private/EvaluationWatchView.ps1` bindet den
Wartungseinstieg und den eigenen Browserdialog. 17 EvaluationWatch-Prüfungen,
zwölf importierte Projektions-/CLI-/GET-Prüfungen, 18 tatsächliche
JavaScript-Fälle und die zehn betroffenen statischen Suites bestanden.
Der wegen gemeinsamer Konsolenpfade ausgewählte lokale Docker-SQL-2025-Smoke
bestand 34/34 Prüfungen einschließlich Entfernung und Containerabwesenheit.
Er ist ein Core-Regressionstest, keine neue native Evaluations- oder
Lizenzabnahme. Das unabhängige Quellreview ist abgeschlossen; die gefundene
Dialoglayoutlücke ist korrigiert. Eine visuelle Browserabnahme wurde nicht
ausgeführt. Nächster Schritt ist die folgende Bereichsmigration.

**IMPLEMENTED – `UX-201/203/204/205/206`: Bereichsmigration lokal geprüft.**
CLI und Browser verwenden die neun Fachbereiche aus Abschnitt 4.1 mit
bestehenden Handlern und getrennten Experten-/Meldungseinstiegen. Erstellen
und Verwalten liegen unter Lab-Umgebungen; geschützte Gruppenaktionen im
eigenen Testmatrixbereich. Vorlagen/Slots, Beschaffung, Grundkonfiguration und
Host-Dienste/Modelle sind getrennt. Browserinventare werden kontextuell
angezeigt; fehlende Fachdialoge bleiben ausdrücklich offen.


Die frühere Achtgruppenassertion ist durch Tests tatsächlicher
Menüdestinationen, Dispatch, Zurück, Abbruch, Refresh und fehlender
Verfügbarkeit ersetzt. Direkte `-Action`-Aufrufe bleiben erhalten. Reale
JavaScript-Handler prüfen Bereichswechsel und unveränderte Eingaben; vorhandene
Fachdialoge werden wiederverwendet. Alle 14 betroffenen statischen Suites bestanden; nach zwei behobenen Reviewbefunden bestanden erneut die fünf betroffenen Suites einschließlich 26 tatsächlicher JavaScript-Fälle. Der unabhängige Nachreview ist abgeschlossen. Der ausgewählte eigene Docker-SQL-2025-Smoke bestand 34/34 Prüfungen einschließlich Entfernung und bestätigter Containerabwesenheit. Er belegt Core-Regression, keine vollständige native Fachdialogparität. Die Integration setzt den grünen finalen PR-Gate auf dem exakten Head voraus.
Keine neue Runtimefunktion und keine pauschale Fachdialogparität werden
behauptet. Historische `CUI-026`-Evidence bleibt erhalten. Nächste Erweiterung:
Grundkonfiguration und gezielte Änderung einer vorhandenen Umgebung.

**IMPLEMENTED (erster Dialogslice) – `UX-202/204/622`, `CORE-102/108/111`: Grundkonfiguration und
späteren Provider prüfen.** Benutzeraufgabe: wirksame Lab_Base-/Lab_Data-Werte
und fehlende Voraussetzungen sehen, gezielt konfigurieren und später einen
Provider prüfen. `Private/InitialSetup.ps1` besitzt
`Get-LabInitialSetupState`, `New-LabInitialSetupPlan` und
`Invoke-LabInitialSetupPlan`; CLI und Browser binden über die vorhandene
WorkflowAction-API denselben Status-/Plan-/Apply-Pfad. Lab_Base-Herkunft und
ungültige registrierte Roots bleiben sichtbar. Complete beendet den Dialog
nicht; registrierte Defaultwechsel werden angewendet und danach idempotent.
Providerrefresh prüft ausdrücklich genau einen Provider strukturiert über den
bestehenden Readinessvertrag. Erkennung überschreibt keine Providerbindung.
Ein enger zusätzlicher Slice bietet eine explizite Schreibprobe über
`Private/InitialSetupWriteability.ps1` und den isolierten
`Tools/Invoke-InitialSetupWriteProbe.ps1`: genau eine vorhandene registrierte
Location, serverseitige Vorschau, Abbruch ohne Probe, bewusste Bestätigung,
frische Ownership-/Volume-/Ancestorbindung und eigenes Byte/Flush mit
begrenzter unabhängiger Abwesenheitsprüfung. Windows Fixed NTFS/ReFS ist die
ausdrückliche Grenze; Lesen behauptet weiterhin keine Schreibbarkeit. CLI und
Browser binden denselben Workflow-Core. Eine getrennte ausdrückliche
Kapazitätsabfrage liest genau eine vorhandene registrierte Location über
frische Controller-/Volume-/Marker-/Ancestorbindung und gehaltene Readhandles.
CLI und Browser zeigen Zeitpunkt, Datenträgerfrei und nullable unbekannte,
unlesbare oder nicht unterstützte Ergebnisse. Dies reserviert keinen Speicher
und prüft weder Schreibbarkeit noch native Container-Volumes. Installation
und Service-Start bleiben Folgearbeit innerhalb derselben IDs. Isolierte Prüfungen
sind keine SQL- oder Providerabnahme; ausgewählte Runtime-Gates bleiben offen
bis zu ihrer tatsächlichen Ausführung.

Abnahme: Container-only ohne Hyper-V-Zwang, Vorschau/Abbruch ohne neue Ordner,
wiederholtes Apply als No-op, bestehende Roots und Bindungen nach
Providerergänzung unverändert. Unbekannt, nicht erreichbar und nicht
schreibbar bleiben unterscheidbar. `Invoke-InitialSetupChecks.ps1`, passende
Storage-/Readiness-Verträge und WorkflowUI-/ConsoleUI-Verhalten prüfen; eine
geänderte Provisionierung benötigt zusätzlich den betroffenen Providernachweis.
Der erste Abschluss umfasst Rootstatus, geführte Ergänzung/Defaultwahl und
explizites read-only Providerrefresh. Die übrige Providerergänzung sowie
zentrale Slotreserve folgen separat. Reale Providerabnahmen sind keine
Folgerung aus den isolierten CLI-/Browser-Handlerregressionen.

#### Konkrete Folgearbeit innerhalb der übrigen bestehenden Aufgaben

Die Reihenfolge bleibt abhängig von den oben genannten Benutzerprioritäten
und belegten Voraussetzungen. Jeder folgende Schritt übernimmt denselben
Abnahmevertrag: Auswahl ohne interne Befehlskenntnis, Ist-/Zielwerte und
Auswirkungen, Vorschau, Abbruch, Ergebnis sowie Wiederholung/Resume/Cleanup
soweit anwendbar. Die Tabelle ersetzt keine umfangreicheren Fachverträge.

| Restanforderung / bestehende Verantwortung | Ist-Stand, nächster vollständiger Schritt und CLI-/GUI-Zugang | Akzeptanz, Prüfungen und Abschlussgrenze |
|---|---|---|
| A: bestehende Umgebung ändern – `UX-202/622`, `CNT-211` bis `CNT-214`, `HV-601` bis `HV-607` | `Set-LabResourcesInteractive` und Browser-`openResourceDialog` verwenden einen gemeinsamen instanz-/providergebundenen CPU/RAM-Plan mit gemessenen Limits und Alt/Neu-Vorschau. Container-Apply ist eng live/no-op begrenzt und serialisiert; Hyper-V bleibt read-only, bis dauerhafte Sollzustandsautorität und journalisierte Teilfehler-/Recovery geklärt sind. Container-CPU/RAM ist implementiert und unabhängig nachgeprüft; Docker und Podman bestanden am 2026-09-28 getrennt je neun native Prüfungen des neuen Plan-/Workflow-Apply-/No-op-/Driftpfads mit SQL-Probe und bestätigtem Own-Cleanup. Dies schließt weder Hyper-V-Apply noch weitere Eigenschaften unter den bestehenden IDs ab. | Cancel/No-op ändern nichts; geschützte Gruppen bleiben geschützt; exakte Instanz-/Providerbindung und verständliches Ergebnis. ConsoleUI/WorkflowUI, Ressourcen-/Reconcile-Verträge und bei Executoränderung getrennte Provider-Smokes. Abschluss nur CPU/RAM, weitere Eigenschaften mit Reset/Removal separat. |
| C: Slotreserve – `HV-401` bis `HV-508`, `CORE-107/111` | `New-SqlServerLabWindowsSlotPool` und Batchplanung existieren. Zentrale Advisory-Reservepolicy und registrierte Kandidatensicht sind an dieselbe Preferences-Authority in CLI/GUI gebunden. Ohne dauerhafte Poolmitgliedschaft und Claims bleiben verfügbare Reserve, Defizit und exakte Auffüllzahl unbekannt. Nächster Schritt: belastbare Pool-/Claimbindung, danach explizite Einzel-/Batchvorbereitung aus vorhandenem Bestand; feinere Profile, Budget, Parallelität und Erneuerung bleiben offen. | Nullreserve gültig, Warnfrist getrennt von Mindestrestlaufzeit, unbekannte/ablaufende/reservierte Slots nicht voll zählen; Default nur Auffüllempfehlung. WindowsSlotPool-/Batchchecks, Race-/Resume-Fälle; mutierende Erweiterung braucht eigene Hyper-V-Abnahme. Automatische Auffüllung separat opt-in. |
| D: Ersatz und Migration – `CORE-107`, bestehende Evaluation-Refresh-Backlogs | Nach der Fristenanzeige freien Slotersatz, rekonstruierbares Lab und zustandsbehaftete Instanzmigration getrennt planen. Bestehenden Watch, SQL-Gast-Evidence und Datenbank-Abhängigkeitsinventur verwenden; CLI/GUI zeigen fehlende Gleichwertigkeit statt ausführbare Migration vorzutäuschen. | Serverobjekte, Schlüssel, externe Verbraucher, Cutover und Rückfall nach Zielschreibzugriffen vollständig erfassen oder konkret blockieren. EvaluationWatch-/GuestEvidence-/Dependencychecks; erst nach geschlossenem Plan eigene Migration/Recovery nativ prüfen. Clone setzt keine Evaluation zurück. |
| E: providerübergreifendes Lab – Multi-Instance-/Multi-Version-Backlog, Batch-/ProviderSubRun-Verträge | `Private/BatchWorkflow.ps1` und gemischter Container-Lifecycle existieren. Als nächsten Core-Schritt Komponentenabhängigkeit und Shared-Verbraucherbindung an bestehender Labidentität für eine begrenzte Topologie ergänzen; CLI/GUI zeigen Gesamt- und Teilstatus. | Startreihenfolge, Teilfehler, Resume und Erhalt gemeinsamer Dienste prüfen. MixedProviderLifecycle-Checks plus eigenes Mixed-Smoke. Hyper-V-SubRun, providerübergreifendes DNS/TLS/Netz und SSIS auf Podman bleiben ohne eigenen Vertrag blockiert. |
| F: Quellenoverrides – `BASE-001/004`, `CORE-102/104` | Genau die drei SQL-2025-Bootstrapper (Enterprise Developer, Standard Developer, Express) besitzen einen gemeinsamen CLI-/GUI-Dialog für lokale alternative Bezugsadressen derselben Bytes. Vorhandene Preferences-Authority, gebundene Vorschau/Apply, effektive Herkunft und gezielter Reset werden wiederverwendet; Reset lädt nichts. URL-/Varianten- und unveränderliche Integritätsbindung gelten auch beim bestehenden Save-Aufruf. Weitere Medienfamilien und freie Mirrors bleiben offen. | Reset ohne Download, URL/Resolver/Parser/Allowlist/Redirect und Variante gemeinsam prüfen; Hashdrift nicht durch neuen Sollhash kaschieren. Medien-/Trust-/ResourceSetchecks mit synthetischen Quellen. Abschluss nur gewählte Familie, weitere Quellen separat. |
| G: Beschaffung – `SFT-711/712`, `AIX-001/008` | `Private/ResourceSet.ps1`, `Get-SqlServerLabResourcePlan` und `Save-SqlServerLabResourceSet` decken Samples und externe Sprachmedien ab. OFFEN: Die vollständige SSIS-Beschaffung mit Paket, Link, Zielort, Prüfung und Resume ist noch nicht umgesetzt. [Beschaffungscheckpoint](SSIS_ETL_DATA_WAREHOUSE_BACKLOG.md#beschaffungscheckpoint-g-weiterhin-offen): Herstellerweg SSMS Component.IS/Offline-Layout dokumentiert; eigener WinPS-Host als Engineering-/Validierungsgrenze, Standalone-Redistribution/Notices und exakte Integrität getrennt ungeklärt. Keine Bootstrapper-Ersatzimplementierung. Wiederaufnahme erst mit begrenztem Layout-/Hostvertrag; autonome Produktumsetzung von G endet an dieser Grenze, andere Slices bleiben möglich. | Registriert, herunterladbar, installiert, konfiguriert und funktional getrennt. ResourceSet-/SSIS-Contractchecks und eigene native IS-Abnahme; SSISDB/ETL bleiben bis vollständiger Offlineclosure offen. C#-Beschaffung und Abnahme nicht wieder aufnehmen. |
| H: llama.cpp-Runtimeinstaller – `AIX-001/008` | `IMPLEMENTED_PARTIAL`: Gemeinsamer CLI/GUI-Ressourceninstaller für genau b11247/Windows/x64/CPU experimentell umgesetzt und unabhängig geprüft. Repositorykuratierter Asset-/Größen-/SHA256-/Dateimengenpin, vorhandener Lab_Base, Vorschau/Bestätigung, versionierte atomare Veröffentlichung und feste modellfreie `--version`-Probe. [Enger Vertrag](../Architecture/LLAMA_CPP_INSTALLER.md). | Eigener Windows-x64-CPU-Nachweis9/9 PASS mit bestätigtem Cleanup: `BINARY_PROBE_PASSED`; Empfehlung `UNASSESSED`, Mindest-VC/OS/CPU-Kompatibilität `UNKNOWN`. Offizieller API-Hash ist keine unabhängige Signatur. Upstream, katalogisiert, installiert und Ausführungsnachweis getrennt; keine PATH-/Treiber-/Dienst-/Modelländerung. Weitere Releases/OS/Backends und Compute/SQL-Abnahmen bleiben offen; vorhandene Discovery `FILES_ONLY` bleibt unverändert. |
| I: Hostdienste und Modelle – `AIX-001/003/007/008`, `AI-20/20A/20B/30` | `IMPLEMENTED_PARTIAL`: Gemeinsame CLI/GUI-Auswahl, Vorschau, Cancel und bestätigter Stop genau einer vorhandenen eigenen llama.cpp-Modulsitzung. Exakter UI-Modulsitzungserhalt; serverseitige Objekt-/Port-/Schutzbindung, Verbrauchercoverage UNKNOWN. Fremdstart benötigt weiter den sicheren Identitäts-/Rechtevertrag, kein pauschales Ownershipverbot. | Synthetische Core-/HTTP-/CLI-/Browserchecks bestanden; unabhängiger Lifecycle-/Cleanup-Nachreview geschlossen. Separater Windows-GuidedStop am 2026-09-30 PASS mit bestätigtem Worker-/Kind-/Key-/Nachbar-Cleanup; ausschließlich synthetische native Prozesse, keine SQL-/Modell-/Compute-/Providerabnahme. Eigener Cleanupvertrag unverändert. Fremdprozesse, Start/Restart/Konfiguration sowie Import/Pull, Load/Warmup, Unload, Wechsel und Dateientfernung bleiben offen. |
| J: Resource Watch – CU-Lane, `BASE-004` | Interaktiver Slice: `Private/ResourceWatch.ps1` verwendet den CU-Core plus genau katalogisiertes SqlPackage, gemeinsame WorkflowActions und explizite CLI-/GUI-Prüfung. Katalog, aktueller Quellenbefund und letzter Erfolg getrennt; Prozesscache ohne Netz bei Menüwechsel. Monatlicher CU-Watch unverändert; dauerhafter Scheduler/Benachrichtigung bleibt Folgearbeit. | Offline/Timeout/Rate-Limit/Parserfehler sind nicht unverändert/aktuell; Cache und Deduplikation synthetisch prüfen. Bestehende CU-Watchchecks erweitern, Scheduler/Benachrichtigung separat mit echter Ausführung abnehmen. Issue erzeugt keinen Agentstart. |
| K: unklare Testreste – `CORE-105/106/109`, `PSR-011` | IMPLEMENTED: gemeinsamer CLI-/GUI-Wartungsdialog mit CleanupAudit-NoWrite-Befunden, Herkunft/Nutzung/Details und separat bestätigter fehlender moderner Container-Store-Katalogzuordnung. Bestehender Repair-Core mit frischer Source-/Runtime-/Volumeidentität, Registry-/Kataloglocks und CAS; kein allgemeines Maintenance-Apply. | Unabhängiger Nachreview geschlossen; Core/HTTP/CLI 34, JS 85 und Audit 38 synthetische Prüfungen bestanden, betroffene Gates grün. Docker und Podman getrennt je 38 native Assertions am neuen Guidancepfad bestanden, eigene Ressourcen entfernt und Abwesenheit bestätigt. UNKNOWN, Konflikt, Schutz und unvollständige Referenzevidence blockieren Repair. Die Zuordnungsreparatur ist keine SQL-Funktionsabnahme. Der separate Retained-Removal-Nachweis bestand am 2026-10-01 auf `b2a1f456` für Docker und Podman je sechs Assertions an einem frischen eigenen SQL-2025-Store mit unabhängigem Cleanup; eigene Container, Volumes und Testnetze abwesend, Shared-Umgebungen und Defaults unverändert. Kein zweiter Löschpfad. |
| L: Samples, Testmatrix und CMS – `HV-505`, `UX-202/204`, bestehende Fachverträge | `Public/TestEnvironment.ps1`/`TestEnvironmentLifecycle.ps1`, Sample-/ResourceSet- und CMS-Core existieren. Geführter CLI-/GUI-Powerdialog implementiert: kanonische Registrygruppe auswählen, gemessenen Powerstatus je Mitglied lesen, Start/Stop nur nach gebundener Vorschau und Bestätigung. SQL-Bereitschaft bleibt nicht geprüft; keine CMS-/Lizenz-/SQLdienst-/Exportmutation. Offlineprüfung und unabhängiger Nachreview geschlossen; getrennte eigene Docker-/Podman-/Hyper-V-Powerfixtures bestanden je zehn Prüfungen einschließlich Own-Abwesenheit. Keine SQL-/Gastbereitschaftsabnahme. PR #656 ist nach integrierter CI-Privacybasis und vollständig grünen Pflichtgates einschließlich aller fünf Providergates integriert. Der PR-Hyper-V-Aufruf verwendet ausschließlich lifecycle; die geschützte gemeinsame Gruppe wurde nicht ausgeführt. | Einzelaktionen umgehen Gruppenschutz nicht, Teilfehler bleiben pro Mitglied sichtbar, Wiederholung/Resume dupliziert nichts. TestEnvironmentChecks, Pester-Lifecycle, WorkflowUI und isolierte GroupLifecycle-Abnahme; reservierte Gruppe bleibt unangetastet. Danach Samplevarianten/Handlerkonflikte und optionales CMS-Setup/Prüfung/Sync separat. |

Nach jedem Slice werden Implementierung, geführte CLI-/GUI-Abdeckung und
Abnahme getrennt hier sowie in Funktionsübersicht und Known Limitations
aktualisiert. Ein Teilabschluss schließt keine Sammelaufgabe. Fehlt eine
konkrete Voraussetzung, wird beim bestehenden Task die Wiederaufnahmebedingung
festgehalten und der nächste unabhängige Bedien-/Implementierungsschritt
fortgesetzt; eine neue Vollinventur ist dafür nicht erforderlich.

### Statusdimensionen und Quellen

Die Erweiterung baut auf `Tools/Get-SqlServerLabCapabilityInventory.ps1`,
`Schemas/capability-evidence-index.schema.json`,
`Documentation/Quality/capability-evidence-index.json`, dem privaten
[Instanz-Capability-Vertrag](../Architecture/INSTANCE_CAPABILITY_ASSESSMENT.md),
Katalogen, Code und den referenzierten Qualitätsberichten auf. Der bestehende
Evidence-Index enthält nur einen Ausschnitt der dokumentierten Historie;
fehlende Indexeinträge bedeuten nicht, dass keine Abnahme existiert.

Mindestens getrennt zu führen sind `implementationStatus`,
`installabilityStatus`, `projectSupportStatus`, `manufacturerSupportStatus`,
`nativeAcceptanceStatus` und `currentReadinessStatus`. Die noch zu
implementierende Native-Acceptance-Sicht unterscheidet `NATIVE_ACCEPTED`,
`NATIVE_FAILED`, `NOT_EXECUTED`, `NOT_APPLICABLE`, `EVIDENCE_STALE` und `UNKNOWN`.
Diese Zielwerte ersetzen nicht stillschweigend vorhandene Schemaverträge.
Jede Aussage benötigt ihren konkreten Scope, Quelle, Zeitpunkt und relevante
Versionsbindung. Historischer PASS ist keine aktuelle Readiness; Static/Mock
ist keine Native Acceptance. Nicht getestet bedeutet nicht unsupported,
Legacy bedeutet nicht uninstallierbar. Hersteller- und Projektfreigabe bleiben
unabhängig; unbelegte Aussagen bleiben unbekannt.

### Vollständiger Such- und Abgleichscope

Zu erfassen sind SQL 2000, 2005, 2008, 2008 R2, 2012, 2014, 2016, 2017, 2019,
2022 und 2025 für Hyper-V, Docker und Podman. Windows-Baselines umfassen Server
2003 SP2, 2008 R2 SP1, 2012 R2, 2016, 2019, 2022, 2025 und weitere tatsächlich
katalogisierte Varianten. Containerzellen binden die tatsächlichen Linux-/
Imagevarianten und, soweit relevant, rootful/rootless sowie cgroup v1/v2.
Nicht jede Kombination ist installierbar; Ausschluss und fehlender Nachweis
werden getrennt ermittelt, nicht aus dem kartesischen Produkt behauptet.

Der Funktionsscope umfasst Provisionierung/Installation, Lifecycle,
SQL-Readiness, Konfiguration/Reconcile, CU-/Buildwahl, Backup/Restore/PITR,
persistenten und retained Storage, Testdatenbank-Bestellung und sämtliche
Samples, BAK, SQL-Script/Bundle, BACPAC, MDF/NDF/LDF-Attach, FILESTREAM,
Multi-Instance/-Version, Mixed Provider, CMS, Python/R/Java/C#, cgroup-Pfade,
Vector, Embeddings, Ollama, RAG, External Model, ONNX, CPU/GPU/NPU,
Observability, Evaluation Watch/Refresh, Recovery, Export/Import/Portabilität,
Remote Hyper-V, PolyBase/S3, SSIS, SSAS, End-to-End BI, AG/FCI/Cluster/HA,
Scenario Engine/Fault Injection sowie weitere kanonisch geplante Fähigkeiten.

Vor neuen Tests sind insbesondere die [Windows-Template-Evidence](../Quality/WINDOWS_SERVER_TEMPLATE_VALIDATION_MATRIX.md),
Legacy-SQL-2005/2008/2008-R2/2012/2014-Nachweise in den
[Known Limitations](../Quality/KNOWN_LIMITATIONS.md), die bestehende
SQL-2019/2022/2025-Testgruppe, getrennte Docker-/Podman-Abnahmen,
SQL-2022-Hyper-V-Sprachabnahmen, SQL-2025-cgroup-v2, Vector/RAG/AI und
Chinook/Northwind-Hyper-V-Samples auszuwerten. OS-Boot, SQL-Engine und einzelne
Zusatzfähigkeiten sind getrennte Nachweise. Suchhinweise sind keine neuen
offenen Aufgaben und überschreiben aktuellere Evidence nicht.

Erst danach werden Lücken für implementierte/installierbare Kombinationen
abgeleitet: insbesondere SQL 2000/2016/2017 Hyper-V, SQL 2017 Container,
Legacy-Slot-Integration, weitere Windows-Sprachkombinationen, C#, vollständige
Samples, Multi-Instance/-Version, retained Removal und AI-/External-Model-Pfade.
SQL-2022-cgroup-v2 bleibt ein experimenteller Spike ohne Supportannahme.
Vor jeder Ausführung wird erneut geprüft, ob inzwischen passende Evidence
vorliegt. Jede abgeschlossene Implementierung/Abnahme aktualisiert die
betroffenen kanonischen Status-, Evidence- und Limitationsquellen; der Auftrag
endet nicht mit einer Matrixdatei.

### Erhöhte Ausführung und sichtbare Wiederaufnahme

Für notwendige Administratoroperationen wird bevorzugt ein vorhandener
GitHub-Actions-Workflow auf dem passenden autorisierten Self-hosted Runner
verwendet. Das ist kein allgemeiner Remote-Shell-Auftrag: vertrauenswürdiger
Checkout, Capability-Labels, expliziter Modus, Ownership, Ressourcenprüfung,
Timeout, Runtime-Lock und Cleanup-/Recovery-Vertrag bleiben Voraussetzung.
Reservierte Umgebungen werden weder gestartet noch als Testfixture verwendet.
Eine neue Runnerfunktion wird regulär implementiert und geprüft; lokale
ungeprüfte Skripte werden nicht über einen generischen Dispatch ausgeführt.

Fehlt ein geeigneter Runnerpfad oder wird notwendige UAC nicht angenommen,
bleibt die betreffende Abnahme `NOT_EXECUTED` mit konkretem Blocker und
Wiederaufnahmebedingung beim bestehenden Arbeitspaket. Unabhängige
Implementierung und Tests ohne UAC gehen weiter. Eine unveränderte Ablehnung
wird nicht wiederholt; eine neue verfügbare Runnerfunktion, geänderte
Voraussetzungen oder erneuerte Benutzerfreigabe erlaubt die Wiederaufnahme.
Reale Hostwerte, Pfade, Identitäten und Rohlogs bleiben außerhalb Git.

### C# zurückgestellt und geänderte Priorität am 2026-09-28

C# bleibt unter den bestehenden Arbeitspaketen `SFT-711`/`SFT-712` erhalten,
ist aber auf ausdrücklichen Benutzerwunsch `USER_DEFERRED` und kein aktiver
Arbeitsstrang. Offline-Build, Paketprüfung und eigener begrenzter GitHub-
Runner für Windows/SQL 2025 sind implementiert. Die letzte native Abnahme
`36405567818` auf `88c0445f` ist `FAILED`: SQL 39048/39004 und ein leerer
Hostfxr-Trace (`EMPTY`). Eigenes Cleanup und Evidenceaufbewahrung waren
erfolgreich; der Katalog bleibt `PREVIEW`. Vertrag und Grenzen stehen in der
[CSharp-Nativabnahme](../Architecture/CSHARP_NATIVE_ACCEPTANCE.md);
reale Diagnosen verbleiben ausschließlich privat und lokal.

Die API-3-Kompatibilität ist ein `UNPROVEN`-Verdacht, keine festgestellte
Fehlerursache. Wiederaufnahme erfolgt erst nach bewusster späterer
Priorisierung und einer gezielten Vorprüfung von DLL-Ladbarkeit,
Hostfxr-Voraussetzungen und Schnittstellenvertrag. Keine weitere unveränderte
VM-Abnahme und keine fortgesetzte Instrumentierung während der Zurückstellung.

Vorrang haben jetzt CLI-/GUI-Menüstruktur und verständliche Bedienführung;
danach folgen die bestehenden SQL-bezogenen SSIS- und Failover-Arbeitspakete
entsprechend ihren belegten Voraussetzungen. Maßgeblich bleibt der
[konsolidierte Ausführungsplan](DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md),
ohne zweiten Backlog oder neue Freigabebehauptungen.

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

**Prioritätsänderung 2026-09-20:** Der Benutzer zieht die KI-Punkte vor:
Podman-RAG/Golden, anschließend isoliertes Hyper-V-RAG/Agent, danach persistentes
Retrieval/Re-Embedding. Bereits laufendes Host-Ollama soll bei erfülltem
Modellvertrag genutzt werden; Cloudgeneration bleibt ausdrücklich opt-in.
Der [ausführbare Host-RAG-Slice](../Architecture/AI_RAG_EXISTING_OLLAMA.md) ist
implementiert und am 2026-09-20 unter Podman und Docker getrennt einschließlich
SQLrestart und Cleanup nativ belegt; Hyper-V bleibt offen. Golden v1 bleibt
unverändert. Sein fester Fall `backup-frequency` bestand am 2026-09-21 separat
unter Docker und Podman mit der ursprünglichen Modellpaarung, Golden-Metriken,
SQL-/Ollama-Restart und Cleanup. Nicht abgeschlossene andere Punkte einschließlich SQL-Gast-
Evaluation-Capture bleiben erhalten und werden dadurch nicht abgeschlossen.

Der nächste Slice ist die [isolierte Hyper-V-Abnahme](../Architecture/AI_HYPERV_OWN_RUN_ACCEPTANCE.md)
mit explizitem Prepared-Artefakt, eigener VM und lokaler Qwen-Generierung für
RAG/Agent. Der erhöhte native Lauf 35542940923 bestand am 2026-09-21 mit
14 Assertions, VM-Neustart, SQL-Bereitschaft und vollständigem Cleanup.
Persistentes Retrieval und Re-Embedding besitzen getrennte Nachweise. Für Golden v1
ist der feste Containerfall `backup-frequency` belegt; weitere Fälle bleiben offen.

Abgesehen von der obigen ausdrücklichen KI-Priorität sind Reihenfolge und
Abnahme innerhalb dieser Tabelle von oben nach unten vorgegeben.
Unabhängige Offlinearbeit darf bei einem konkret dokumentierten
Runtimeblocker weitergehen, ohne den blockierten Punkt abzuschließen.

| Arbeit | Status | Abschlusskriterium |
|---|---|---|
| Hyper-V-Reconcile | `in_progress` | SQL-Konfiguration ist nativ belegt: Der erfolgreiche erhöhte GitHub-Actions-Lauf `34754976310` vom 2026-09-13 bestätigte verifiziertes SQL-2025-Prepared-Artifact, gültiges Manifest, isolierten Run und Host-SQL-Zugriff, initiale dynamische und restartpflichtige Zielkonfiguration, unverändertes `WhatIf`, Live- und Owned-Trace-Flag-Add/Remove bei erhaltenem fremdem Flag, Live-No-op, ausschließlichen `MSSQLSERVER`-Restart ohne VM-Neustart, Desired-State-Konvergenz sowie VM/VHDX/IPAM-Cleanup. Der SQL-2025-Prepared-Referenzlauf bestätigte außerdem Fresh-VM/OOBE, `PrepareImage`, Generalize, immutable Publish, differenzierenden Manifestklon, EvaluationOnline über eine temporäre und wieder entfernte eigene NIC, `SQL_READY_RUN` (Major 17, vier Systemdatenbanken), Parent-Hash/Schreibschutz und Cleanup. Der erhöhte Testdatenbank-Wiederholungslauf vom 2026-09-12 bestätigte Aktivierung, Add/Remove, Journal, LAB_GENERATED-Wiederverwendung, VM-Neustart, stabile Host-SQL-Readiness nach 94,2 Sekunden und vollständigen Cleanup. SQL-Port ist nativ belegt: Der erfolgreiche erhöhte GitHub-Actions-Lauf `34761955648` vom 2026-09-13 bestätigte Prepared-Artifact, gültiges Manifest, isolierten Run, initialen Port/Connection-State, erreichbare Alternativport-Drift, TCP-/Firewall-Plan, unverändertes `WhatIf`, Wiederherstellung mit ausschließlich `MSSQLSERVER` ohne VM-Neustart, No-op und VM/VHDX/IPAM-Cleanup. Die native Ressourcen-Acceptance vom 2026-09-14 belegte den Windows-2025-/SQL-2025-Enterprise-Clone-Scope mit VerifyOnly, SQL-Readiness, Shutdown-Integration, dynamischem Live-/Restart- und statischem Restart-Pfad sowie vollständigem Cleanup. Der manuelle Ressourcenlauf `35564131935` vom 2026-09-21 auf `a4510f5c` ergänzte zwei eigene Windows-2025-/SQL-2025-Developer-Runs, einen VM-ID-gebundenen injizierten Pre-Start-Fehler, Wiederaufnahme mit persistentem SQL-Marker sowie Cleanup beider Runs mit jeweils drei Schritten und null Fehlern; reale Hyper-V-Plattformfehler sind damit nicht belegt. Der frühe External-Runtime-Lauf `34772015168` stoppte sicher in `SQL_MEDIA_PREFLIGHT`; nach Bereitstellung der SQL-2022-Evaluation-ISO bestand der fachliche Lauf `34776120704`, dessen Cleanup allein am JSON-Leselimit des SafetyRoot-Readers scheiterte und durch `34780328388` scopegebunden wiederhergestellt wurde. Der vollständige manuelle main-Lauf `34780626984` vom 2026-09-13 ist positive Evidence für den isolierten SQL-2022-Evaluation-/Windows-Server-2025-Pfad: öffentlicher Plan, `WhatIf`, Apply, No-op und Removal-Blockade, Python/R/Java- und Resource-Governor-Intent sowie Gast-/SQL- und Runtime-Probes nach VM-Kaltstart; VM, VHDX und IPAM-Lease endeten mit `CLEANUP_SUCCEEDED (3 Steps, 0 Fehler)`. Die datierten Nachweise erteilen keine breite Versions-/Providerfreigabe. Weitere native Fault/Resume-Nachweise, weitere Ressourcenklassen, Hyper-V-Removal, Varianten-/Packagewechsel, allgemeine Zusatzsoftware sowie weitergehende Netzwerkreparatur außerhalb des belegten eingeschränkten Reconnect-Slices bleiben separat. |
| Hyper-V-Sample-Parität | `validated_reference` | Der manuelle Main-Lauf `34790092466` auf Commit `95c5a79c` führte zwei frische SQL-2025-Prepared-Manifest-Runs auf einem isolierten Testdatenroot erfolgreich aus: Chinook (`sql-server`) und Northwind (`script`), katalog-/hashgebundene Quellen, identische `LAB_GENERATED`-Baseline-ID/Key/Hash- und `manifest.lock.json`-Bindungen im zweiten Run sowie scopegebundenes Cleanup. Weitere Hyper-V-Sample-Varianten bleiben separat offen. |
| Recovery-Härtung | `validated` | Netzwerk-Cleanup prüft Run-/Scope-Labels. Die native Docker-/Podman-Abnahme erstellt je ein eigenes und ein fremdes Netzwerk, blockiert die fremde Löschung, entfernt ausschließlich das eigene über den Produkt-Cleanup und bereinigt das fremde Testnetz danach explizit (je 3 PASS). Isolierte native Docker- und Podman-Batchabbrüche nach sichtbarer Providerressource bestanden: persistierte Worker-Recovery, eindeutige Run-Übernahme, idempotentes Resume und scopegebundener Cleanup (je 13 PASS). Auch der zweite öffentliche Cleanup-Aufruf beider isolierten SQL-2025-Runs ist ohne Fehler konvergent (`REMOVED`/`ALREADY_REMOVED`); Container und Volumes wurden vollständig entfernt. Der native Volume-Nachweis blockiert für Docker und Podman ein fremdes Run-Label vor dem Remove-Aufruf, entfernt ausschließlich das eigene Volume und bereinigt das geschützte Testvolume anschließend explizit (je 3 PASS). Ein dynamischer Offline-Contract erzeugt eine Junction beziehungsweise einen Symlink aus dem Run-Ressourcenpfad nach außen, verweigert ihn vor dem Hyper-V-Cleanup und bewahrt ein externes Sentinel (1 Contract). Ein gemischter synthetischer Docker-/Podman-Teilfehler bewahrt den erfolgreich bereinigten Docker-Subrun, markiert nur Podman für Recovery und führt beim Retry ausschließlich dessen Schritt erneut aus (4 Contracts). Der Status gilt für diese nachgewiesenen Cleanup-Grenzen, nicht für beliebige Providerfehler. |
| Evaluation-Watch | `implemented_partial` | Der read-only Watch projiziert Windows-/SQL-Fristen registrierter Imageartefakte über stabile IDs sowie die eigene persistierte Windows-Frist jeder als `RUNNING` registrierten Hyper-V-Instanz. Für registrierte `RUNNING`-/`STOPPED`-Hyper-V-SQL-Runs projektiert er zusätzlich ausschließlich einen schema- und bindungsvalidierten, frischen SQL-Gast-Evidence-Receipt; fehlende, unzulässige oder veraltete Evidence bleibt fail-closed `UNKNOWN`. Er klassifiziert Ablaufzustände, erzeugt nur mit explizitem `RecordEvents` deduplizierte lokale Ereignisse und führt keinen Refresh oder Live-/Gastabfrage aus. `Invoke-SqlServerLabEvaluationWatchTrigger` ergänzt einen explizit begrenzten foreground-Zeittrigger ohne Windows-Aufgabe, Runtime- oder Netzwerkmutation. Der separate SQL-2025-Hyper-V-Capture implementiert jetzt atomare NO_DEADLINE-Evidence aus der live gebundenen Edition. Native Developer-Capture bestand am 2026-09-21 in Lauf 35563036235 mit elf Assertions, Receiptkette, bytegleichem State und vollständigem Cleanup; positive Evaluation-/Deadline-Evidence bleibt offen. |
| State-Upgrades | `implemented_partial` | Der read-only Plan bindet jetzt den Quellhash. `Invoke-SqlServerLabRunStateUpgrade` migriert ausschließlich ausdrücklich mit `metadata.syntheticStateFixture=true` markierte unversionierte synthetische Legacy-States, sichert die Ausgangsrevision, schreibt atomar und journalisiert Commit oder Rollback. `-Resume` finalisiert nur ein exakt gebundenes `PENDING`-Journal nach bereits vollständig atomarem Zielcommit; geänderte Source-Revisionen und unvollständige Zielstates blockieren (10 Contracts). Unbekannte, nicht markierte und produktive historische States, ein Resume vor beobachteter Mutation, breite Kompatibilitätsmatrix und jede Framework-/Repositoryaktualisierung bleiben offen. |
| Persistenzlücken | `implemented_partial` | Die enge Katalog-Recovery eigener bereits UUID-gelabelter detached retained Docker-/Podman-Stores ist implementiert: unveränderte Original-Run-Evidence, frische Runtime-Bindung, CAS und Spiegelrollback; Continue-/Clone-/Lease-Consumer revalidieren diese Bindung. Die getrennten nativen SQL-2025-Abnahmen vom 2026-09-21 bestanden je acht Assertions einschließlich SQL-Marker und Serverobjekt nach Continue, unveränderter Labels und vollständigem Cleanup. Der öffentliche ID-/Preview-/Resume-Delete einzelner moderner eigener detached Docker-/Podman-Stores ist implementiert und am 2026-10-01 auf `b2a1f456` für SQL Server 2025 getrennt je sechs Assertions mit separatem Cleanup nativ abgenommen. Weitere Bestandsklassen, kompatible Paketprovider und breitere endgültige Löschungen bleiben offen. TDE/FILESTREAM besitzen eigene Freigabegates. |
| Portabler Lab-Transfer | `validated` (enger Ein-Datenbank-Slice); Gesamt-Lab weiter `planned` | `Invoke-SqlServerLabPortableContainerTransfer` restauriert ein registriertes read-only SQL-2025-Linux-Backup in einen neuen operationseigenen Run desselben Providers, bestätigt READ_ONLY/MATCH und behält das erfolgreiche Ziel. 32 Offline-Assertions; Docker- und Podman-Referenzabnahmen am 2026-09-20 getrennt mit jeweils zwölf Assertions einschließlich unveränderter Quelle, Replay, Inhaltsabweichung und vollständigem Cleanup bestanden. Bestehende Ziele, Mehrdatenbank- und Gesamt-Lab-Roundtrip bleiben offen. [Vertrag und Grenzen](../Architecture/PORTABLE_CONTAINER_TRANSFER.md). |
| SQL-Observability | `validated_reference` | Die getrennten nativen Docker- und Podman-Referenzläufe vom 2026-09-20 bestanden jeweils auf einem eigenen SQL-2025-Linux-Run mit 35 Assertions: öffentliche rungebundene Capture, exakte Query-Store-/Online-Datenbankdelta, Restart und Datenmarker, Privacy sowie vollständiger scopegebundener Cleanup. Extended Events, SQL-Agent-/Backupzustände, Retention, Evidenzpakete, externe Provider und Hyper-V bleiben offen. |
| Breitere Hyper-V-Provisionierung | `planned` | OS-Baseline→SQL-Pfad, Post-Provisioning und Softwarebindung unter dem vorhandenen Cold-Path-/Prepared-Vertrag vervollständigen. SQL 2025 bleibt Core-Referenz; breite Versionsmatrizen gehören weiterhin zu den Partnerprojekten. |

Fachliche Quellen bleiben der
[Persistenzbacklog](PERSISTENT_STORAGE_REUSE_AND_LAB_DATA_BACKLOG.md),
der [Plattformbacklog](CROSS_CUTTING_PLATFORM_CAPABILITIES_BACKLOG.md),
der [Hyper-V-Vertrag](../Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md)
und die [Known Limitations](../Quality/KNOWN_LIMITATIONS.md).

## Szenarien, Bedienung und KI

Der priorisierte [Podman-KI-Erstellungsdialog](../Architecture/AI_PODMAN_SETUP.md)
ergänzt die bisher getrennten Schritte um neue eigene SQL-2025-Umgebung,
vorhandenes Host-Embeddingmodell, Initial-Collection und bestätigte feste
Backup-Abfrage. Erfolgreiche Umgebungen bleiben mit auffindbaren IDs erhalten;
Fehler bereinigen nur die eigene Operation. Status `validated_reference`:
Die native Podman-Referenz auf `9d8d313a` bestand am 2026-09-21 mit sechs
Assertions, persistierter Query nach SQLrestart, unverändertem Modellinventar
und unabhängig bestätigtem vollständigem Own-Cleanup. Dies ändert
keine Golden-Referenz und behauptet keinen Podman-SQL-HTTPS-Nachweis.

| Arbeit | Status | Abschlusskriterium |
|---|---|---|
| Allgemeiner Szenariokern | `implemented_partial` | [SCN-802](SCENARIO_CONTRACT_BACKLOG.md) ergänzt einen internen providerlosen synthetischen Executor: fünf feste Phasen, authentifiziertes atomisches Journal, Ownership, begrenzte Timeouts/Cancellation und Cleanup-Resume. Offline-Verträge einschließlich eigener harter Kindprozessunterbrechung sind vorhanden. SCN-801 bleibt unverändert; öffentliche API, fachliche Szenarien, SQL-/Providerbindung und native Evidence bleiben offen. |
| Upgrade-/Regressionsszenario | `validated_reference` | [Feste SQL-2022-/SQL-2025-Referenz](../Quality/SQL_VERSION_UPGRADE_REFERENCE.md): zwei neue eigene Docker-/Podman-Runs, öffentlich registriertes verifiziertes Full-Backup und Restore per BackupSetId, erhaltene Kompatibilität 160 vor separatem Wechsel auf 170, exakte Daten/Aggregate, Transaktions-/Constraint-/CHECKDB-Prüfungen, unveränderte Quelle und beobachtete Dauern. Native Docker und Podman bestanden am 2026-09-21 auf `46340200`; der unabhängige Nachlauf bestätigte je Provider zwei entfernte Own-Runs und keine Runtime-Residuen. Die Restore-Dauern sind Beobachtungen, kein Benchmark. Allgemeiner Szenariokern, weitere Versionen und fachliche Partnerzuständigkeit bleiben unverändert. |
| Point-in-Time-Recovery-Szenario | `validated_reference` (enger synthetischer Slice) | `Invoke-PointInTimeRecoveryAcceptance.ps1` bindet je Docker-/Podman-Lauf einen neuen eigenen SQL-2025-Run, containerlokale Full-/Log-Backups, einen SQL-seitigen Serverzeit-`STOPAT` zwischen gutem Marker und Fehlmutation sowie Restore in ein neues Ziel. Offline-Vertraege und getrennte native Docker-/Podman-Läufe auf `f51595ea` bestanden am 2026-09-21: SQL-Major 17, guter Commit wiederhergestellt, Fehlmutation ausgeschlossen, Quelle unverändert, `DBCC CHECKDB` und unabhängige Prüfung von Own-Run-Removal sowie fehlenden Runtime-Resten. Beobachtete Restoreintervalle: Docker 2873,8858 ms, Podman 6600,8529 ms; kein Performance-Benchmark. Der Nachweis erweitert weder den allgemeinen Scenario-Executor noch den öffentlichen PITR-Restorevertrag; Hyper-V bleibt offen. |
| Collation-Auswahl | `implemented_partial` | `COL-001` besitzt einen schema-validierten Katalog für SQL 2019/2022/2025, die öffentliche tokenbasierte Suche `Find-SqlServerLabCollation` und eine Konsolenauswahl mit Metadaten. Manifestprüfung, Wizard-Speicherung, Manifestauflösung und Ad-hoc-Erstellung binden die Instanzcollation vor Provisionierung an einen vollständigen versionsgebundenen Namen. Die Offline-Suite prüft auch ungültige Kataloge, null Treffer und Abbruch. Docker/Podman pruefen nach SQL-Readiness vor Konfiguration, Datenbanken und Samples per einer parametrisierten SqlClient-Abfrage `sys.fn_helpcollations()` und `SERVERPROPERTY('Collation')`. Die native Acceptance bestand am 2026-09-13 im PR-Gate-Lauf `34783317945` fuer beide Containerprovider mit SQL Server 2025 und `Latin1_General_100_CS_AS`, Katalogverfuegbarkeit, Server-Postcondition, run-gebundener sanitisierter Evidence und vollstaendigem Cleanup. Freie Advanced-Eingabe und ein getrennter Hyper-V-/Windows-Nachweis bleiben offen. |
| Direkter SQL-Prepared-Locale-Pfad | `validated_reference` | [Run 35574934252](https://github.com/gecompat/SQL_Server_Lab/actions/runs/35574934252) bestand am 2026-09-21 auf `bf72dc32`: explizites hashverifiziertes englisches SQL-2025-Prepared-Artifact, frischer eigener US-Manifest-Child, alle fünf Locale-Werte nach Kaltstart, VM-ID-gebundener SQL-SELECT mit Major 17, Aktivierung, Receipt und unveränderter Parent. Überwachter Cleanup `COMPLETED`, eigener Run-State separat `REMOVED` bestätigt. Weitere Image-Sprachen und SQL-Versionen bleiben offen. |
| Legacy-WMI-Fortschritt | `implemented` (Offline-Abnahme; neue Gastabnahme offen) | Vorhandene WMI-, Aktivierungs-, Sysprep- und Shutdown-Reporter inventarisiert. Luecken im SQL-Receipt-Polling, Legacy-OOBE und direkten SQL-Setup-Abfragen verwenden nun denselben durchgehenden Reporter. Synthetischer Transport reproduzierte die fehlende Anzeige; Heartbeat, Ausgabe, Fehler vor/nach Transportbeginn und eigener/geliehener Reporter-Cleanup bestehen nach dem Fix. Der bestehende echte Pipeline-Abbruchtest bleibt Bestandteil der fokussierten Suite. Keine Aenderung am WMI-/SMB-Transport oder an dessen Abbruchlatenz; neuer isolierter Legacy-Gastlauf bleibt offen. |
| Reservierte Manifestfelder | `validated` (Bewertung) | [Einzelbewertung](RESERVED_MANIFEST_FIELDS_ASSESSMENT_2026-09-10.md) für alle neun direkten reservierten `serverConfig`-Felder, `customImage`, zwei `installMethod`-Werte und die gesonderten Adapterfelder abgeschlossen. Bestehende Collation-/Storage-/Derived-Image-Verträge haben Vorrang; direkte erste PITR-/Upgrade-Szenarien benötigen keine zusätzlichen Agent-/CLR-/Authentifizierungsschalter. Jeder spätere Bedarf besitzt Nutzen, Abhängigkeit, Risiko, relativen Aufwand und konkreten Folgeschritt. Felder bleiben reserviert; keine neue Runtimefreigabe. |
| Podman Golden RAG | `validated_reference` | Der feste Golden-v1-Fall `backup-frequency` bestand am 2026-09-21 getrennt unter Docker und Podman mit `embeddinggemma:300m-qat-q4_0` und `gemma3:1b`, exaktem SQL-Retrieval, Golden-Metriken, SQL-/Ollama-Restart und vollständigem eigenem Cleanup. Podman verwendete 1800 Sekunden Downloadbudget je Modell; die Inferenzlimits blieben unverändert. Weitere Golden-Fälle sind nicht durch diese Referenz abgedeckt. |
| Hyper-V RAG/Agent | `validated_reference` | Eigener SQL-2025-Prepared-Run mit Host-Embeddinggemma und lokalem Qwen: Lauf 35542940923 bestand am 2026-09-21 mit 14 Assertions, tatsächlichem VM-Neustart, SQL-Bereitschaft, Login-Cleanup und vollständigem VM-/Child-VHDX-/IPAM-Cleanup. Parent und Hostmodellinventar unverändert; reservierte Gruppen unberührt. Golden v1 bleibt separat. |
| Modellcache | `validated` (Bewertung; Nichtübernahme) | [Bewertung](SQL_AI_CAPABILITIES_ASSESSMENT_2026-09-10.md): vorerst kein gemeinsamer persistenter Cache. Ein Pull-Timeout belegt keinen Cachegewinn; ein sicherer Blob-/Lease-/Publish-Vertrag fehlt. Erst erfolgreichen geänderten Podman-Lauf messen, bei bestätigtem Engpass separate Umsetzung mit Digest-, Abbruch-, Konkurrenz- und Cleanup-Abnahme; Aufwand L. |
| Persistentes Retrieval/Re-Embedding | `validated_reference` (begrenzter Container-Slice) | [Eigene SQL-2025-Containergenerationen](../Architecture/AI_PERSISTENT_RETRIEVAL.md) mit festen Initial-/Delta- oder 1–16 Caller-Dokumenten, lokalem Host-Embedding, atomarem Cutover, SQL-quittiertem Resume, explizitem Prune alter v1-Caller-Generationen und besitzgebundenem Remove. Sync und Prune sind unter Docker und Podman nativ mit je 30 Assertions belegt. Der Modellwechsel Embeddinggemma→Nomic unterstützt feste und Caller-Bestände; Docker und Podman bestanden jeweils 25 native Prüfungen einschließlich SQL-Neustart und vollständigem Cleanup. Weitere Zielmodelle, Dimensionswechsel und Hyper-V bleiben offen. |

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
| Remote Hyper-V | `validated` (Bewertung), nachgelagert `P3` | [Bewertung](HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md): zuerst read-only Hostregistrierung; später genau ein gebundener SQL-Run mit hostseitiger Identität, State, Autorisierung, Transfer- und Recoveryvertrag. Aufwand L; kein entfernter Host für diese Welle freigegeben und keine Abhängigkeit für lokale funktionale Gastcluster. |
| Mehrbenutzerbetrieb | `validated` (Bewertung) | [Bewertung](HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md): Einzeloperator bleibt Standard; erster späterer Slice ist disjunkte read-only Inventur zweier synthetischer Identitäten. Mutation verlangt eigene Rechte-, Revisions-, Audit- und Konfliktabnahme, Aufwand L. |
| Cluster/HA/DR | `validated` (Bewertung), lokaler erster Slice `P2` | [Bewertung](HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md): SQL-AG zuerst bei konkretem Szenario; FCI, SSISDB-HA, Worker, SSAS-WSFC und Queryknoten erhalten getrennte Abnahmen und Aufwand L. Mehrere isolierte VMs auf einem lokalen Host belegen `FUNCTIONAL_GUEST_CLUSTER`, aber keine physische HA; Multi-Host-Evidence bleibt als getrennte `P3`-Erweiterung offen. |
| Automation-API/IaC | `validated` (Bewertung) | [Bewertung](HOST_AND_AUTOMATION_ASSESSMENT_2026-09-10.md): vorhandene PowerShell-API bleibt Standard; lokaler versionierter read-only Plan-/Result-Vertrag als nächster Schritt, Aufwand M. Kein neuer Netzwerkdienst; genau ein späterer IaC-Pilot erst bei konkretem Konsumenten. |
| KI-TLS-Gateway | `validated` (Bewertung) | [Bewertung](SQL_AI_CAPABILITIES_ASSESSMENT_2026-09-10.md): späterer SQL-seitiger Docker-Referenzlauf mit eigenem Gateway, begrenztem Trust und echtem Embed-/Negativ-/Restart-/Cleanup-Nachweis; Podman/Hyper-V separat. Aufwand L; vorhandener Controller und HTTPS-Stub ersetzen diese Abnahme nicht. |
| ONNX | `validated` (Bewertung) | [Bewertung](SQL_AI_CAPABILITIES_ASSESSMENT_2026-09-10.md): isolierter SQL-2025-Windows-Child-Slot nach External-Runtime-Abnahme, gebundene Modell-/Tokenizer-/Runtimeartefakte und eigene SQL-/Restart-/Cleanup-Prüfung. Aufwand L; kein Modell oder DLL ungeprüft installiert. |
| ANN | `validated` (begrenzte native Abnahme) | Auf Benutzerauftrag vom 2026-09-10 Preview konkret unter SQL Server 2025 getestet: Abnahmeversion 1.0 auf Revision `6fc518847eaefb021c31666ca8386da5b53e1908`, Docker und Podman getrennt `PASS`, SQL-Build `17.0.4075.5`, Compatibility Level `170`, `Preview=true`, tatsächlich unversionierte Indexmetadaten. 4.096 Vektoren, je 32 Dimensionen, vier Suchfälle mit `MinimumRecallAt10=1,0` vor/nach Neustart-Prüfung, Distanz-/Filterprüfung und Cleanup `CLEANUP_SUCCEEDED`. Kleine Testlaufzeiten ergeben keine allgemeine Performancezusage. Spätere Inkompatibilität verlangt angepasste oder eigene Funktionsversion; Hyper-V, Backup/Restore und produktiver Szenarioexecutor bleiben separate Erweiterungen. |
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
| 2026-09-11 | Gemischten Container-Cleanup-Teilfehler behoben und geprüft | Kontrollierter Podman-Fehler nach erfolgreichem Docker-Cleanup lässt Docker terminal bereinigt, markiert nur Podman als RECOVERY_REQUIRED und führt beim Retry ausschließlich Podman erneut aus (4 Contracts). |
| 2026-09-11 | Evaluation-Watch gegen den integrierten Stand geprüft | Fünf Contracts belegen stabile Artefakt-IDs, Fristenklassifikation, read-only Standardpfad, deduplizierte lokale Ereignisse und sanitisierte Ausgabe. Laufende Instanzen und Zeittrigger bleiben als Restscope offen. |
| 2026-09-11 | Registrierte RUNNING-Hyper-V-Instanzen im Evaluation-Watch ergänzt | Die zusätzliche Instanzprojektion liest nur die gespeicherte Windows-Aktivierungsevidenz, bindet Run-, Instanz- und Artefakt-ID ohne VM-Namen oder Pfade und dedupliziert Ereignisse getrennt. Sechs Contracts belegen die Projektion, die getrennte Frist, den read-only Pfad und die Sanitierung. Persistierte SQL-Gastfristen und der Zeittrigger bleiben offen. |
| 2026-09-11 | Begrenzten lokalen Evaluation-Watch-Zeittrigger ergänzt | Der foreground-Trigger führt den vorhandenen Watch sofort und höchstens für die explizit angegebene Anzahl Prüfungen aus. Er registriert keine Windows-Aufgabe, startet keine Runtime und nutzt nur bei `-RecordEvents` die vorhandene lokale Ereignisdeduplizierung. Persistierte SQL-Gastfristen und Benachrichtigungskanäle bleiben offen. |

## Persistentes Retrieval: begrenzter Folgeslice 2026-09-21

Nach der ausdrücklich priorisierten KI-Reihenfolge ist der
[synthetische Persistenz-Slice](../Architecture/AI_PERSISTENT_RETRIEVAL.md)
implementiert: eigener SQL-2025-Containerscope, Initial/Delta, Resume und
atomarer aktiver Zeiger. Offline-Verträge und die getrennten nativen Docker-/Podman-Abnahmen sind geprüft, einschließlich SQLrestart und vollständigem Cleanup.
Der nachfolgende [begrenzte Modellwechsel](../Architecture/AI_PERSISTENT_MODEL_MIGRATION.md)
ergänzt explizit Delta/gen2 nach Nomic v2 MoE/gen3 mit v2-Upgrade und festen
Präfixprofilen. Am 2026-09-22 wurde derselbe atomare Vertrag auf vollständig
gebundene Caller-Bestände und dynamische Quell-/Zielgenerationen erweitert. Die
fokussierte Suite besteht; Docker und Podman bestanden jeweils 25 native
Prüfungen einschließlich SQL-Neustart und vollständigem Cleanup. Weitere
Zielmodelle und Dimensionswechsel bleiben offen; Golden v1 wird nicht umgebunden.

## Entwicklungsreihenfolge nach Fortsetzung vom 2026-09-21

Die vom Benutzer bereitgestellten Übergaben
`sql-server-lab-development-handoff.prompt.md` und
`sql-server-lab-diagnostic-bundle-development.prompt.md` bleiben historische
Quellen; Betriebsbefunde eines anderen Hosts sind kein Nachweis für den
aktuellen Zielhost. Die autonome Entwicklung ist fortgesetzt. Bei der
Wiederaufnahme waren die kompakte CMS-Anzeige, Point-in-Time-Recovery,
die SQL-Versionsupgrade-Referenz und die enge retained-store-Arbeit noch nicht
vollständig integriert. Diese begonnenen Slices werden zuerst abgeschlossen;
die separat unter Docker und Podman validierte Upgrade-Referenz folgt nach der
PITR-Integration. [PR #540](https://github.com/gecompat/SQL_Server_Lab/pull/540)
für die CMS-Anzeige und [PR #537](https://github.com/gecompat/SQL_Server_Lab/pull/537)
für PITR wurden inzwischen nach grüner CI integriert. Die
KI-Statuskorrektur in den Benutzerdokumenten ist in diesem Dokumentationsslice
enthalten. Einzelne historische Prüferfolge ersetzen keine abschließende
Prüfung und Integration des jeweiligen aktuellen Branchstands.

Die aktuelle read-only Zielhostprüfung klassifiziert Docker und Podman für den
Container-Python/R-Pfad wegen erforderlichem cgroup v1 bei beobachtetem cgroup
v2 als `INFRASTRUCTURE_UNAVAILABLE`. Das ist kein Embedding-Blocker, keine
Abnahme von Python/R und keine Grundlage für einen Host- oder cgroup-Umbau.
Nach Abschluss der vorhandenen Slices ist daher zuerst die unabhängige
kombinierte synthetische SQLKI-/Northwind-/Chinook-Abnahme möglich; danach
folgen der begrenzte Diagnose-API-Vertrag und erst anschließend der Operator-
Handoff. Ältere breitere Arbeiten und Assessments bleiben von ihren bestehenden
Abhängigkeiten bestimmt. Die Zeilen sind beschreibende Arbeitspakete, keine
neuen sequenziellen Task-IDs.

### CMS, SQLKI und External Languages

Ziel bleibt eine unabhängige SQL-2022-, SQL-2025- und SQLKI-Testumgebung mit
persistentem CMS. SQLKI soll persistente KI-Testdaten, generierte Zugangsdaten,
Python/R und katalogisierte Testdatenbanken kombinieren. Bestehende Teilpfade
sind wiederzuverwenden; die kombinierte Zielhost-Abnahme bleibt offen.

| Reihenfolge / Arbeit | Stand und Abhängigkeiten | Akzeptanz und nächste Prüfung |
|---|---|---|
| Zielhost-Bestandsaufnahme | `partially_validated`; Docker-/Podman-Readiness und cgroup-Kompatibilität aktuell geprüft; weitere Zielbindungen bleiben vor ihrer Mutation zu prüfen | Öffentliche Connection-Center-Projektion und aktuelle Endpunkte für den jeweiligen Ziel-Run prüfen. Installiertes Tool, unerreichbare Runtime, fehlende Berechtigung und fehlendes Secret getrennt klassifizieren; Provider getrennt bewerten. Keine historischen Ports übernehmen. |
| CMS-Registrierung und Secret-Herkunft | `partially_implemented`; `f67c71f2` enthält benannten CMS und explizites Ersetzen ausschließlich terminaler `REMOVED`-Registrierungen | Öffentliche API und passwortfreie Projektion prüfen. Laufende, gestoppte und unklare Registrierungen bleiben gesperrt. Nur nachgewiesen generierte Passwörter dürfen in der ausdrücklich aktivierten CMS-Anzeige erscheinen. Einen fehlenden Herkunftsnachweis nicht allein aus einem vorhandenen Secret ableiten oder manuelle Kennwörter umklassifizieren; zulässigen Reparaturvertrag vor einer möglichen Mutation klären. |
| Persistentes SQLKI-Setup | `planned` für den kombinierten Anwendungsfall; vorhandene [Podman-KI-Erstellung](../Architecture/AI_PODMAN_SETUP.md) und [persistentes Retrieval](../Architecture/AI_PERSISTENT_RETRIEVAL.md) berücksichtigen | Entscheidung für ein bewusst persistentes Setup dokumentieren; erwartete Datenbank und Dokumente nach Setup sowie SQL-Neustart über SQL prüfen. Das Cleanup von `vector-core-ci/1.0` bleibt unverändert. Bestehende feste Fixture nicht als beliebigen Dokumentimport ausgeben. |
| Container-Reconcile-Regressionsnachweis | `partially_implemented`; `f67c71f2` enthält Drive-Abgrenzung und Erstinstallation bei leerem Software-Envelope | Framework-eigene Volume-Metadaten dürfen keinen falschen Manifestdrift erzeugen. Tatsächlich deklarierte Drive-Änderungen und nichtleere persistierte Software bleiben verbindlich. Leer → erste Installation → persistierter Zielzustand gezielt prüfen. Keine automatische Übertragung dieser Containerregel auf Hyper-V. |
| Python/R und SQL Launchpad | `INFRASTRUCTURE_UNAVAILABLE` für den aktuellen SQL-2025-Containervertrag; aktuelle read-only Prüfung bestätigt cgroup v2 unter Docker und Podman bei erforderlichem v1 | Ein künftig kompatibler Docker-/Podman-Pfad benötigt getrennte echte SQL-External-Script-Postconditions, Restart und Cleanup/Recovery. Keine native Python-/R-Abnahme und kein stiller Host-/cgroup-Umbau. Hyper-V nur als ausdrücklich passender eigener Scope mit getrenntem Vertrag und Nachweis. |
| Northwind und Chinook | `planned`; im berichteten kombinierten Ablauf wegen Runtime-Blocker nicht ausgeführt | Nach erfüllten Voraussetzungen über katalogisierte öffentliche Installationspfade einbringen, Datenbankzustand und erwartete Inhalte prüfen. Vorhandene allgemeine Sample-Nachweise ersetzen nicht diese kombinierte Abnahme. |
| Abschluss der Übergabe | `planned`; nach den betroffenen Arbeitspaketen | Analyzer-Verfügbarkeit tatsächlich prüfen; Infrastrukturfehler nicht als Code-Erfolg behandeln. Reproduktion → fokussierte Tests → betroffene Suiten → tatsächlich betroffene Provider. Ergebnis, nicht ausgeführte Nachweise und Cleanup getrennt dokumentieren; konsistente Änderungen nur über geprüfte PRs integrieren. |

### Sanitisiertes Diagnosebundle und Operator-Handoff

Status: `partially_implemented`. `Get-SqlServerLabDiagnosticBundle` ist als
gebundene, geschlossene read-only API implementiert. Der ausdrücklich angeforderte
lokale Operator-Handoff verwendet das [kanonische Rezept](../HowTo/OPERATOR_DIAGNOSTIC_HANDOFF.md);
Export, Upload, freie Diagnosebefehle und selbständige Entwicklung bleiben ausgeschlossen.
Provider-/SQL- und Skillloader-Nachweise sind getrennt auszuweisen.

| Reihenfolge / Arbeit | Abhängigkeiten und Akzeptanz |
|---|---|
| Ergebnisvertrag und Privacy-Grenze festlegen | Contract-/Ergebnisversion, kanonische Operationskategorien, Provider-/SQL-/OS-Klassen, gebundener Run-/Instanzstatus, feste Reason Codes, Fehlerphase und Recovery/Cleanup. Reproduktionsbindungen nur als zulässige Katalog-/Manifest-/Planhashes, keine Inhalte oder Pfade. Abschnitte tragen `OBSERVED`, `NOT_EXECUTED`, `UNAVAILABLE`, `UNSUPPORTED` oder `BLOCKED`; ausgeschlossene Datengruppen werden maschinenlesbar aufgeführt. |
| Begrenzte read-only Reader und API implementieren | Nur sanitierte, ownership-gebundene Projektionen oder eng begrenzte interne Reader. Readiness einschließlich Toolverfügbarkeit ohne Installationspfade aufnehmen. Feste Allowlist für notwendige OS-/Architektur-, Versions-, Berechtigungs- und gegebenenfalls cgroup-Kategorien; keine frei formulierbaren Diagnosebefehle. Anzahl, Größe und Tiefe begrenzen. Fehlendes Tool und unerreichbarer Provider müssen unterscheidbar bleiben. |
| Negativ- und Vertragsprüfungen | Keine Passwörter, Tokens, SecureStrings, Secret-Aliasse, Connection Strings mit Kennwort, SQL-Texte, Datenbankinhalte, Rohlogs, Hostnamen, IPs, Ports, lokale Pfade oder Container-/VM-/Runtime-IDs. Keine direkten öffentlichen Zugriffe auf Secretstores, State-/Connection-Dateien oder Provider-Inspect. Fremde, unbekannte und ungebundene Ziele werden gesperrt. Keine Netzwerk-, Provider-, SQL-, Datei-, Git-, Konfigurations- oder Hostmutation und kein Runtime-Start/-Stop. |
| Öffentliche Dokumentation und Exportvertrag | Erst implementierte Funktion exportieren; Help, Benutzerreferenz, Repo-Map, DTO/Schema und Tests gemeinsam pflegen. Mit synthetischen Fixtures Reproduzierbarkeit, Datenschutz und getrennte Fehlerklassen prüfen; erforderliche Provider-Nachweise nach tatsächlichem Scope auswählen. |
| Operator erst nach bestandener API-Abnahme anbinden | Der `SQL Server Lab Operator` nutzt ausschließlich diese API und vorhandene öffentliche Cmdlets für die benutzergebundene Operation. Handoff auf entscheidungsrelevante sanitierte Felder reduzieren; Produktfehler, Infrastruktur, Berechtigung, Secret und fehlende Evidence trennen. Keine eigenständige Entwicklung oder erweiterte Shell-Freigabe. |

Ein automatischer Bundle-Dateiexport oder Upload ist ausdrücklich nicht Teil
dieses Vorhabens. Ein späterer Support-Export benötigt einen getrennten
Privacy-, Retention-, Speicherort- und Freigabevertrag. Die Originaluploads und
das CMS-Bild werden nicht ins Repository übernommen; insbesondere werden keine
abgebildeten Kennwörter oder privaten Hostdaten versioniert.

### Welle L: schmaler registrierter CMS-Lesepfad

CLI und Browser besitzen einen gemeinsamen expliziten Lesepfad für genau den bereits registrierten verwalteten CMS. Native eigene Container-/Scope-/Portautorität muss vor dem Secretlesen feststehen; öffentliche Befunde sind nullable, zeitgebunden und ohne Namen/Secrets/Endpunkte. Hyper-V, CMS-Einrichtung/Adoption/Sync im Browser sowie SSMS und Mitgliedsverbindungen bleiben offen. Implementierung ist kein Runtime-Nachweis; tatsächliche ausgewählte Gates und reale CMS-Abnahme sind separat auszuweisen. [Kanonischer Vertrag](../Architecture/CMS_READONLY_INSPECTION.md).
