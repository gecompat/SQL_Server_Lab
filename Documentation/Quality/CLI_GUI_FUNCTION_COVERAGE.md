# CLI- und GUI-Funktionsabdeckung

| Merkmal | Wert |
|---|---|
| Status | `INCOMPLETE` |
| Bestandsaufnahme | 2026-11-20 |
| Autoritative Exportquelle | `SqlServerLab.psd1` |
| Zielvertrag | [Cross-Cutting Backlog](../Project_Planning/CROSS_CUTTING_PLATFORM_CAPABILITIES_BACKLOG.md#vollständige-cli-abdeckung-aller-lab-funktionen) |

## Zweck und Bewertungsregeln

Diese Datei beginnt die geforderte Zuordnung von Produktoperationen zu
geführter CLI-Navigation, Browser-GUI, öffentlicher PowerShell-API und
Nachweisen. Sie ist ausdrücklich noch keine vollständige Operationsmatrix und
keine Releasefreigabe.

Das Manifest exportiert 166 Funktionen aus 137 Skriptdateien. Der erzeugte
Expertenkatalog macht die 165 Befehle neben dem zentralen CLI-Einstieg und im
Browser auffindbar. Das beweist weder einen verständlichen geführten Fachweg
noch die Laufzeitfähigkeit jeder Operation. Die vorhandene
[Cmdlet-Funktionsübersicht](../User/FUNCTIONS_CLI_GUI.md) enthält bereits
Zuordnungen für ausgewählte Befehle; sie ist nicht vollständig für alle
Exporte und bildet nicht für jeden Eintrag Prüf- und Providergrenzen ab.

Die Statuswerte bewerten geführte Bedienbarkeit, nicht das bloße Vorhandensein
eines Cmdlets:

| Status | Bedeutung |
|---|---|
| `GUIDED_BOTH` | Geführte Fachaktion in CLI und GUI nachgewiesen; keine Aussage über andere Providerzellen. |
| `GUIDED_CLI_ONLY` / `GUIDED_GUI_ONLY` | Geführte Fachaktion nur in der genannten Oberfläche nachgewiesen. |
| `EXPERT_CATALOG_ONLY` | Befehl ist im Expertenkatalog verfügbar, aber keine geführte Fachaktion belegt. |
| `PUBLIC_API_ONLY` | Öffentliche API ist bekannt; Katalog- und geführte Oberflächenzuordnung ist nicht belegt. |
| `KNOWN_GAP` | Eine konkrete fehlende oder unvollständige Fachführung ist dokumentiert. |
| `NOT_ASSESSED` | Zuordnung und Bedienpfad wurden noch nicht einzeln geprüft. |
| `NOT_APPLICABLE` / `UNSUPPORTED` | Nur mit begründeter, quellengestützter Produktgrenze verwenden. |

## Exportreferenz-Audit

Ein mechanischer Abgleich des Manifests mit
`Documentation/User/FUNCTIONS_CLI_GUI.md` findet 161 der 166 Exportnamen und
5 dort nicht referenzierte Exporte. Das ist ein Referenzabgleich, keine
vollständige Prüfung, ob die 161 Treffer tatsächlich korrekt geführt,
ausführbar oder providerabgenommen sind. Die folgende Inventarliste hält die
5 nicht referenzierten Namen einzeln fest. Die sieben Environment-Group-
Operationen aus dem vorherigen Abgleich sind jetzt in der Funktionsübersicht
enthalten und unten separat quellengestützt als `GUIDED_BOTH` bewertet. Von
den 5 Einträgen sind vier TLS-001-Exporte `DEFERRED` und einer
`EXPERT_CATALOG_ONLY`. Die drei External-Model- und
OVMS-Gateway-Operationen sind in der eigenen Tabelle unten bewertet.
Die Bewertung folgt aus Menüdispatch, GUI-Aktion, öffentlichen Parametern
und den vorhandenen Nachweisen. Der Expertenkatalog allein erfüllt die
geführte Abdeckung nicht.

| Funktionsfamilie | Nicht einzeln in der Funktionsübersicht referenzierte Exporte | Status |
|---|---|---|
| Security-Tool-Katalog | `Get-SqlServerLabSecurityToolPlan` | `EXPERT_CATALOG_ONLY`. Die produktive Allowlist ist leer, der lokale Resolver blockiert alle Anfragen. [Katalogvertrag und Freigabestand](../Project_Planning/SECURITY_TOOL_ACQUISITION_BACKLOG.md). |
| TLS-001, zurückgestellt | `Update-SqlServerLabTlsBinding`; `Get-SqlServerLabTlsBindingRecovery`; `Resolve-SqlServerLabTlsBindingRecovery`; `Read-SqlServerLabQualifiedTestEnvironment` | `DEFERRED`; bestehender Zustand bleibt erhalten, keine neue Abdeckungs- oder Runtimearbeit ohne dokumentierten Anwendungsfall |

Die 5 Namen ohne Referenz und die einzeln geprüften Exporte unten
wurden unmittelbar gegen `FunctionsToExport` im Manifest
abgeglichen; die Familiengruppierung ist nur eine Lesbarkeitshilfe. Sie ist
keine Behauptung, dass eine Familie einen gemeinsamen Aufrufer oder denselben
Nachweis besitzt.

## Geprüfte Operation: Lab-Katalog schreiben

| Operations-ID und Aufgabe | Geführte CLI | Browser-GUI | Öffentlicher Vertrag und Nachweis |
| --- | --- | --- | --- |
| `workflow-catalog-export` · Workflow-Inventar lokal als JSON schreiben | Lab-Umgebungen → Datenbanken, Samples und Skripte → Lab-Katalog prüfen → Zielpfad | Lab-Umgebungen → Lab-Katalog schreiben → Bestätigen | `GUIDED_BOTH` über `Get-SqlServerLabCatalog`. Der Browser bindet den konfigurierten State Root und den festen Dateinamen. Er zeigt ausschließlich eine Bestätigung und aggregierte Zähler. Der atomare Schreibvorgang aktualisiert dieselbe lokale Datei. |

`Invoke-ConsoleUiChecks.ps1` prüft die Bindung der Katalogleser an den
gewählten State Root. `Invoke-PublicCommandConsoleChecks.ps1` und
`Invoke-WorkflowUiChecks.ps1` prüfen Browser-Bestätigung, abgewiesene
Pfadparameter und die begrenzte Ergebnisansicht. Diese Prüfungen sind
synthetisch. Der Export startet keine SQL-Instanz und bescheinigt keine
Provider-Bereitschaft.

Die gerenderte Prüfung auf `78d6a3b2bcb7238b70684119fccf64d4c7db194b`
lud alle 54 UI-Dateien. Abbrechen sendete keinen Schreibauftrag.
Die Bestätigung löste genau eine Berechtigungsanfrage und genau einen
synthetischen Katalogauftrag aus. Der Testbrowser meldete keine Fehler.
Eine separate Prüfung mit synthetischem Workflow und echtem Datei-Writer
schrieb und ersetzte die feste JSON-Datei im isolierten Zustandspfad.
Die Rückgabe enthielt nur den festen Dateinamen und die erwarteten Zähler.

## Geprüfte Operationen: OVMS und externe Modellendpunkte

| Aufgabe | Geführte Bedienung | Öffentlicher Vertrag und Nachweis |
| --- | --- | --- |
| Bereits laufenden lokalen OVMS-Upstream prüfen | `GUIDED_BOTH` unter **Host-Dienste und Modelle → Lokalen OVMS-Embedding-Dienst prüfen** | `Test-SqlServerLabOvmsUpstreamEndpoint` sendet nach Bestätigung einen synthetischen HTTP-Request über numerisches Loopback und prüft Modell und Dimension. |
| Lokale External-Model-Konfiguration erstellen | `GUIDED_BOTH` unter **Host-Dienste und Modelle → Lokalen HTTPS-Modellendpunkt planen** | `Get-SqlServerLabAiExternalModelPlan` bindet Modell, Runtime, Zertifikat und optional ein OVMS-Gateway. Die Tests prüfen exakte Planbindung, geschlossene Eingaben, feste Blockercodes und die getrennte Übernahme zur Probe. Reine Konfiguration. |
| Geplanten HTTPS-Modellendpunkt verifizieren | `GUIDED_BOTH` unter **Host-Dienste und Modelle → Geplanten HTTPS-Modellendpunkt prüfen** | `Test-SqlServerLabAiExternalModelEndpoint` erhält den gebundenen Plan nach Bestätigung. Die Guidance-Fixtures prüfen das lokale Eingabefeld, optionales öffentliches CA-PEM, Credential-Grenzen und die Quittung mit synthetischem Transport. Die native Framework-/Plattformabnahme bleibt separat. |
| SQL-Objekte für den bestätigten Modellendpunkt planen | `GUIDED_BOTH` unter **Host-Dienste und Modelle → SQL-Plan für bestätigten Modellendpunkt erstellen** oder direkt nach der Probe | `Get-SqlServerLabAiExternalModelSqlPlan` revalidiert Plan, Quittung und Höchstalter. Die Tests prüfen den unveränderten Zeitstempel, exakte Quittungsbindung und die reine Vorschau. SQL-Preflight und Apply bleiben getrennte Schritte. |
| Eigenen OVMS-HTTPS-Gateway starten | `GUIDED_BOTH` unter **Host-Dienste und Modelle** auf Windows | CLI und Browser bestätigen die befristete Loopback-Sitzung und geben die geprüfte Gateway-Bindung aus. |
| Eigenen OVMS-HTTPS-Gateway stoppen | `GUIDED_BOTH` unter **Host-Dienste und Modelle** auf Windows | Die Auswahl bindet den Stop an eine eigene Sitzung im aktuellen CLI-Modul oder UI-Server. |

Der [separate Windows-Harness](LOCAL_VALIDATION_STRATEGY.md) prüft Gateway-Start,
HTTPS-Probe und Owner-Stop mit einem synthetischen Upstream. Das belegt keine
geführte Gateway-Bedienung, Acceleratorkonfiguration oder SQL-Ausführung.
Die geführten OVMS-Aktionen sind mit synthetischem Vault und eigenen
Sitzungsobjekten im Modul sowie mit dem tatsächlichen Dialogskript in
einer synthetischen Browserumgebung geprüft.

Am 25.11.2026 bestätigte ein Windows-Loopback-Test die Modulschritte für
OVMS-Start, HTTPS-Prüfung und SQL-Plan aus der serialisierten Quittung.
Er verwendete die Aufrufe der Bedienpfade auf Quellbaum
`0fb1400d96f28d89612e7d25df85c740fcd7ddba` mit einem echten Gateway-Prozess,
synthetischem Upstream und einer temporären CA. Stop und Abwesenheit von
Listener und temporärer Schlüsseldatei wurden bestätigt. Rendern im
Browser, SQL-Ausführung, Beschleuniger und weitere Plattformen sind
getrennte Nachweise.

## Geprüfte Operationen: Ressourcenstand und lokaler Bedarf

| Operations-ID und Aufgabe | Geführte CLI | Browser-GUI | Öffentlicher Vertrag und Nachweis |
| --- | --- | --- | --- |
| `resources-watch-read` · Katalogstand und letzten Sitzungsbefund lesen | Ressourcen und Downloads → Ressourcenstand: CUs und SqlPackage → Gespeicherten Sitzungsbefund ansehen | Ressourcen und Downloads → Ressourcenstand: CUs und SqlPackage → Sitzungsbefund lesen | `GUIDED_BOTH` über `Invoke-SqlServerLabWorkflowAction -Action GetResourceWatchState` und Browser-GET. Kein Netzabruf, keine Speicherung. Fehlender oder abgelaufener Befund bleibt sichtbar. |
| `resources-watch-refresh` · Hersteller-Metadaten vergleichen | Ressourcen und Downloads → Ressourcenstand: CUs und SqlPackage → Jetzt bei Microsoft prüfen | Ressourcen und Downloads → Ressourcenstand: CUs und SqlPackage → Jetzt bei Microsoft prüfen | `GUIDED_BOTH` über `Invoke-SqlServerLabWorkflowAction -Action RefreshResourceWatch` und gleichoriginigen Browser-POST. Expliziter Abruf der fest zugelassenen Quellen. Aktualisiert den Sitzungscache, ohne Pakete zu laden oder Kataloge zu verändern. Quellenfehler erhalten keinen ungeprüften Freigabestatus. |
| `resources-cu-check` · SQL-CUs ohne SqlPackage vergleichen | Ressourcen und Downloads → Aktuelle SQL-Server-CUs bei Microsoft prüfen | Gemeinsamer CU-Abgleich in der Ressourcenstand-Aktion oben | Der Browser zeigt den CU-Befund aus dem gemeinsamen Vergleichskern. `Get-SqlServerLabCuStatus -Version … -MaxMissingEntries … -SourceUrl …` bleibt für die gezielte Auswahl ein PowerShell-Befehl. `SourceUrl` ist auf zugelassene Microsoft-Learn-HTTPS-Quellen begrenzt. |
| `resources-local-plan` · Lokale Voraussetzungen und Beschaffungsbedarf prüfen | Ressourcen und Downloads → Lokalen Ressourcenbedarf prüfen → Auswahl | Ressourcen und Downloads → Lokalen Ressourcenbedarf prüfen → Auswahl → Prüfung starten | `GUIDED_BOTH` über `Get-SqlServerLabResourcePlan -ResourceKind All\|Sample\|Software -SummaryOnly`. Beide Fachwege zeigen Status und Anzahlen ohne lokale Pfade oder Hashes. Ausführung liest die konfigurierten Speicherorte und ändert weder Dateien noch Vertrauensstatus. Einzel-IDs und alternative Roots gehören zum direkten Cmdlet. |

Die Ressourcenstandprüfung ist hostbezogen und benötigt keinen laufenden
SQL Server und keinen Provider. `Invoke-VersionCatalogChecks.ps1` prüft den
Vergleichskern, die CLI und den HTTP-Handler. `Invoke-WorkflowUiChecks.ps1`
prüft den Browserdispatch einschließlich verspäteter oder fehlgeschlagener
Antworten. Die [Validierungsstrategie](LOCAL_VALIDATION_STRATEGY.md#resource-watch-fokussierte-validierung)
dokumentiert den getrennten Live-Metadatencheck. `Invoke-ResourceSetChecks.ps1`
prüft die lokale Ressourcenplanung im eigenen Fixture. Ein Ressourcenplan
bestätigt weder eine Installation noch die Ausführbarkeit eines Providers.

## Geprüfte Operationen: SQL-Betriebsmetriken

| Operation | Geführter CLI-Pfad | Geführter GUI-Pfad | Vertrag und Nachweis |
|---|---|---|---|
| Aggregierte SQL-Betriebsmetriken lesen (`Get-SqlServerLabSqlObservabilityEvidence`) | Lab-Umgebungen → Datenbanken, Samples und Skripte → SQL-Betriebsmetriken lesen | Lab-Umgebungen → laufende Docker-/Podman-Instanz → SQL-Betriebsmetriken lesen | `GUIDED_BOTH` für laufende Containerinstanzen. Fokustests prüfen die Auswahl, Abbruch, geschütztes SA-Passwort und geschlossene Ausgabe. Die Bedienwege sind synthetisch geprüft. Der öffentliche SQL-Lesekern ist getrennt für Docker und Podman nativ belegt. |

## Geprüfte Operationen: Verifizierte Datenbank-Backups

| Operation | Geführter CLI-Pfad | Geführter GUI-Pfad | Nachweis und Grenze |
|---|---|---|---|
| Backup in der `Lab_Data`-Bibliothek erstellen | Lab-Umgebungen → Datenbanken, Samples und Skripte → Datenbank sichern | Lab-Umgebungen → laufende Docker-/Podman-Instanz → Verifiziertes Backup erstellen | `GUIDED_BOTH` für Container. Fokustests prüfen die Instanzbindung, Bestätigung, Abbruch und sanitisierte Backupquittung. Die Browser-Aktion wurde synthetisch geprüft. Der bestehende Backup-Core hat einen separaten nativen Docker→Podman-Restore-Nachweis. |

Der gerenderte Browser auf `7c50f5df4620f0a17cfeb4e759c5468bdf4aa08b`
lud alle 56 UI-Dateien. Die beiden Aktionen erschienen für das laufende
synthetische SQL-Ziel. Der abgebrochene Backup-Dialog sandte keinen Auftrag.
Jede bestätigte Aktion nutzte genau eine Berechtigungsanfrage und einen an
Run und Instanz gebundenen Auftrag. Die Bestätigung hielt die synthetische
Passworteingabe verborgen. Der Browser-Test und der Loopback-Listener
endeten ohne Fehler oder unerwartete Anfragen.

## Geprüfte Operationen: Environment Groups

Der Abgleich von CLI-Router, Konsolenmenü, Browserdialog, typed HTTP route und
den fokussierten Vertragsprüfungen bestätigt für die sieben öffentlichen
Gruppenoperationen geführte Aktionen in beiden Oberflächen. Das schließt nur
diese Operationsgruppe ein; es behauptet keine vollständige Gesamtmatrix.

| Operation | Geführter CLI-Pfad | Geführter GUI-Pfad | Vertrag und Nachweis | Provider-/Versions-Evidence |
|---|---|---|---|---|
| Gruppen lesen und Bindungsstatus anzeigen | Lab-Umgebungen → Umgebung auswählen und verwalten → Lab-Umgebungsgruppen verwalten → Runtime-Zustand eines Mitglieds lesen | Lab-Umgebungen → Lab-Umgebungsgruppen ansehen → Gruppen erneut lesen; optional Runtimestatus live lesen | `Get-SqlServerLabEnvironmentGroup`; `Invoke-EnvironmentGroupLifecycleChecks.ps1`; `EnvironmentGroupsBrowserHttpChecks.ps1`; `EnvironmentGroupsBrowserUiChecks.cjs` | Containerbeobachtung und Gruppenstatus getrennt; kein SQL-Readiness-Nachweis |
| Leere Gruppe anlegen | gleicher CLI-Pfad → Lab-Umgebungsgruppen verwalten → Gruppe erstellen | gleicher GUI-Pfad → Leere Gruppe erstellen | `New-SqlServerLabEnvironmentGroup`; Lifecycle-/Browser-HTTP-/Browser-UI-Fokustests; UI bestätigt vor dem Auftrag | kein Provideraufruf |
| Vorhandenen Run zuordnen | gleicher CLI-Pfad → Gruppe wählen → Run-ID hinzufügen | gleicher GUI-Pfad → gestoppte Gruppe → Run zuordnen | `Add-SqlServerLabEnvironmentGroupMember`; Lifecycle-/Browser-HTTP-/Browser-UI-Fokustests; synthetischer Mehrgruppenfall | Docker und Podman Mehrgruppen-Lifecycle separat am 2026-11-08 nativ abgenommen |
| Einzelne Zuordnung lösen | gleicher CLI-Pfad → Gruppe wählen → Zuordnung lösen | gleicher GUI-Pfad → gestoppte Gruppe → Zuordnung lösen | `Remove-SqlServerLabEnvironmentGroupMember`; Lifecycle-/Browser-HTTP-/Browser-UI-Fokustests; andere Gruppen und Run bleiben gebunden | kein eigener UI-Runtime-Smoke; Cleanup der eigenen Container-Runs ist im verknüpften Szenario belegt |
| Gruppe samt Zuordnungen entfernen | gleicher CLI-Pfad → gestoppte Gruppe → Gruppe entfernen | gleicher GUI-Pfad → gestoppte Gruppe → Gruppe entfernen | `Remove-SqlServerLabEnvironmentGroup`; Lifecycle-/Browser-HTTP-/Browser-UI-Fokustests; Entfernen stoppt/entfernt keine Runs | kein eigener Provider-Lifecycle; siehe Cleanup-Grenze im Testvertrag |
| Gruppe starten | gleicher CLI-Pfad → Gruppe wählen → Gruppe starten | gleicher GUI-Pfad → Gruppe starten | `Start-SqlServerLabEnvironmentGroup`; Lifecycle-/Browser-HTTP-/Browser-UI-Fokustests; neue Starts werden SQL-bereitschaftsgeprüft | Docker und Podman, SQL 2025 CU9: je `OPENQUERY`, Gruppenstart und Cleanup bestanden |
| Gruppe stoppen | gleicher CLI-Pfad → Gruppe wählen → Gruppe stoppen | gleicher GUI-Pfad → Gruppe stoppen / Wiederherstellen und stoppen | `Stop-SqlServerLabEnvironmentGroup`; Lifecycle-/Browser-HTTP-/Browser-UI-Fokustests; bei weiterem Gruppenanspruch bleibt der Run aktiv | Docker und Podman, SQL 2025 CU9: geteilter Ziel-Run blieb nach Stop der ersten Gruppe aktiv und stoppte nach Freigabe des letzten Anspruchs |

Die CLI- und GUI-Prüfungen verwenden synthetische Registry-/DOM-/HTTP-
Fixtures; sie beweisen keine native Ausführung der jeweiligen Oberfläche mit
echten Laufzeitressourcen. Die native Linked-Server-Gruppenabnahme belegt das
Produktverhalten für die gebundenen Docker-/Podman-Zellen, aber keine
GUI-Automation, TLS-Identitätsprüfung, Kerberos-, MSDTC- oder gruppeneigene
Netzwerkkonfiguration. Details stehen in der [datierten Abnahme](LINKED_SERVER_ENVIRONMENT_GROUP_ACCEPTANCE_2026-11-08.md)
und dem [Gruppenvertrag](../Architecture/LAB_ENVIRONMENT_GROUPS.md).

## Geprüfte Operation: llama.cpp-Paketübersicht

| Operation | Geführter CLI-Pfad | Geführter GUI-Pfad | Vertrag und Nachweis | Provider-/Versions-Evidence |
|---|---|---|---|---|
| Vorhandene Runtime-Paketdateien suchen (`Get-SqlServerLabLlamaCppRuntime`) | Host-Dienste und Modelle → Vorhandene llama.cpp-Pakete prüfen | Derselbe Bereich und dieselbe Aktion | `GUIDED_BOTH`. Lesen aus den konfigurierten Suchwurzeln und Anzeige von Backend, Build und unvollständiger Suche. `Invoke-LlamaCppRuntimeChecks.ps1` und einmaliger HTTP-Aufruf im Browserfixture. Freie Suchwurzeln bleiben ein PowerShell-Parameter. | Synthetische Paketdateien. Kein Modell-, Geräte-, SQL- oder Providerlauf für diese reine Dateisuche erforderlich. |
| GGUF-Katalog lesen und Modell beschaffen (`Get-SqlServerLabLlamaCppModel`, `Save-SqlServerLabLlamaCppModel`) | Host-Dienste und Modelle → llama.cpp-Modellkatalog und Dateien | Host-Dienste und Modelle → llama.cpp-Modelle anzeigen und herunterladen | `GUIDED_BOTH`. Der Download bindet Revision und Hash aus der bestätigten Auswahl. Katalog-, Download- und Browser-Fixtures prüfen Status, Bindung und Fehlerfälle. | Synthetische Datei- und Downloadprüfungen. Vollständige Katalogdownloads bleiben als nicht ausgeführt dokumentiert. |
| Ollama-Generationsmodell aufrufen (`Invoke-SqlServerLabAiModel`) | Host-Dienste und Modelle → Vorhandenes Ollama-Modell aufrufen | Host-Dienste und Modelle → Lokales Ollama-Modell aufrufen oder Ollama-Cloud-Modell aufrufen | `GUIDED_BOTH`. Die lokale Variante verwendet den ausgewählten Loopback-Port. Die Cloud-Variante führt über Datenklassenwahl und Bestätigung für Ollama. Die Browser-Fixture prüft Ziel, Eingaben und Auftragsparameter mit synthetischen Daten. |
| Eigene llama.cpp-Sitzung starten (`Start-SqlServerLabLlamaCppRuntime`) | Host-Dienste und Modelle → Eigene llama.cpp-Sitzung geführt starten | Host-Dienste und Modelle → llama.cpp: eigene Sitzung starten | `GUIDED_BOTH`. Eingabe und Bestätigung führen zum bestehenden öffentlichen Start. CLI- und Browser-Vertragssuiten. | Synthetische Fälle. Native Abnahme des geführten Starts `NOT_EXECUTED`. |
| Eigene llama.cpp-Sitzung stoppen (`Stop-SqlServerLabLlamaCppRuntime`) | Host-Dienste und Modelle → Eigene llama.cpp-Sitzung auswählen und stoppen | Host-Dienste und Modelle → Eigene llama.cpp-Sitzung stoppen | `GUIDED_BOTH`. Beide Dialoge bestätigen eine gebundene Stop-Vorschau und nutzen denselben Core wie das Cmdlet. Geschützte Verbraucher sperren den geführten Stopp. `Invoke-LlamaCppSessionGuidanceChecks.ps1`. | Nativer Prozess- und Cleanup-Nachweis am 30.09.2026 im dokumentierten Scope. SQL- und Modellbetrieb sind separat. |

## Geprüfte Operationen: Volltext und FILESTREAM

| Operation | Geführter CLI-Pfad | Geführter GUI-Pfad | Vertrag und Nachweis | Provider-/Versions-Evidence |
|---|---|---|---|---|
| Volltext nachinstallieren oder deaktivieren (`Set-SqlServerLabFeature`) | Lab-Umgebungen → bestehende Umgebung auswählen → Volltextsuche ändern | Lab verwalten → Volltextsuche ändern an der laufenden SQL-Instanz, unter Hyper-V Volltextsuche / FILESTREAM | `GUIDED_BOTH`. CLI-Fixture und Browser-Fixture prüfen Auswahl, Zielbindung und die Übergabe von Ein/Aus. | Der bestehende Core wurde nativ unter Docker, Podman und Hyper-V geprüft. Die neuen Bedienpfade sind synthetisch abgenommen. [Provider- und Versionsgrenzen](KNOWN_LIMITATIONS.md#optionale-volltextsuche-und-filestream). |
| FILESTREAM ändern (`Set-SqlServerLabFeature`) | Lab-Umgebungen → Datenbanken, Samples und Skripte → Volltext und FILESTREAM ändern | Lab verwalten → Volltextsuche / FILESTREAM an der laufenden Hyper-V-Instanz | `GUIDED_BOTH` für bestätigte Änderungen über Hyper-V. | Native Abnahme für den bestehenden Core auf SQL Server 2025 RTM. |

## Geprüfte Operationen: Container-Autostart

| Operation | Geführter CLI-Pfad | Geführter GUI-Pfad | Vertrag und Nachweis | Provider-/Versions-Evidence |
|---|---|---|---|---|
| Hyper-V-Autostart (`Get-SqlServerLabHyperVAutoStartPlan`, `Set-SqlServerLabHyperVAutoStart`) | Lab-Umgebungen → Hyper-V-Autostart ändern | Lab verwalten → Reguläre Hyper-V-Umgebungen → Hyper-V-Autostart ändern | `GUIDED_BOTH`. Gebundene Vorschau, Bestätigung und einmalige Browserfreigabe sind synthetisch geprüft. Native Abnahme der neuen Absicherung `NOT_EXECUTED`. |
| Hyper-V-Autostart-Recovery (`Resume-SqlServerLabHyperVAutoStart`) | Lab-Umgebungen → Hyper-V-Autostart-Recovery fortsetzen | Lab verwalten → Reguläre Hyper-V-Umgebungen → Hyper-V-Autostart ändern → Autostart-Recovery fortsetzen | `GUIDED_BOTH`. Synthetische Fälle prüfen die Journalbindung und Statepersistenz. Native Abnahme des neuen Bedienpfads `NOT_EXECUTED`. |
| Startpolicy lesen und ändern (`Get-SqlServerLabContainerAutoStartPlan`, `Set-SqlServerLabContainerAutoStart`) | Lab-Umgebungen → Docker-/Podman-Autostart ändern | Lab verwalten → Container-Autostart ändern | `GUIDED_BOTH`. Der Plan bindet die Zielpolicy. Der Browser bestätigt nur die zuletzt geprüfte Änderung über eine einmalige Auswahl. `Invoke-ContainerAutoStartChecks.ps1` und Browserfixtures. | Synthetische Vertragsfälle. Native CLI- und GUI-Abnahme `NOT_EXECUTED`. |
| Journaloperation fortsetzen (`Resume-SqlServerLabContainerAutoStart`) | Lab-Umgebungen → Docker-/Podman-Autostart-Recovery fortsetzen | Lab verwalten → Container-Autostart-Recovery fortsetzen | `GUIDED_BOTH`. Die Journaloperation wird unter der Sperre erneut geprüft. Die Browserauswahl ist einmalig und läuft nach fünf Minuten ab. `Invoke-ContainerAutoStartChecks.ps1` und Browserfixtures. | Synthetische Vertragsfälle. Native CLI- und GUI-Abnahme `NOT_EXECUTED`. |

## Geprüfte Operationen: Hostfähigkeiten und Run-Artefakte

| Operation | Geführter CLI-Pfad | Geführter GUI-Pfad | Vertrag und Nachweis |
|---|---|---|---|
| Provider- und Sprachübersicht (`Get-SqlServerLabHostCapabilityMatrix`) | Hauptmenü → Hostfähigkeiten vor der Funktionsauswahl | Lab erstellen → Hostfähigkeiten vor der Funktionsauswahl | `GUIDED_BOTH` für Katalog und explizite Lesebeobachtung. Hostmatrix-Vertrags- und Browser-Suites. |
| Sprachvariante prüfen (`Get-SqlServerLabExternalRuntimeCapability`) | Hostfähigkeiten → Konkrete Container-Variante näher prüfen | Lab erstellen → Python / R / Java: Katalog und Hostvoraussetzungen | `GUIDED_BOTH` für die geführte katalogisierte Docker-/Podman-Linux-Auswahl. Hostmatrix-Launchdetails und External-Runtime-Browser-Suites. SQL-Sprachausführung bleibt getrennt. |
| Historische Nachweise zur Sprachvariante lesen (`Get-SqlServerLabExternalRuntimeCapability -IncludeRecordedEvidence`) | Konkrete Container-Variante näher prüfen → Historische Nachweise für diese Variante lesen | Python / R / Java → Historische Nachweise lesen | `GUIDED_BOTH`. Die statischen Hostmatrix- und Browser-Suites prüfen den gebundenen Indexzugriff, die begrenzte Ausgabe sowie die Trennung von aktueller Readiness und SQL-Sprachausführung. |
| `host.external-runtime.profile-prerequisites` · Controller, Profilkapazität und Providerangaben lesen | Konkrete Container-Variante näher prüfen → Voraussetzungen für ein Ressourcenprofil lesend prüfen | Python / R / Java → Ressourcenprofil wählen → Controller und Profilkapazität lesend prüfen | `GUIDED_BOTH` für `Get-SqlServerLabExternalRuntimeCapability -IncludeProviderFacts -CheckProviderReadiness -ResourceProfile`. Die Prüfungen binden die konkrete Variante und unterscheiden beobachtete OS-, cgroup- und Rootless-Werte von fehlenden Angaben anhand synthetischer Antworten. Native Abnahme dieses Bedienpfads `NOT_EXECUTED`. |
| llama.cpp-Eignung prüfen (`Get-SqlServerLabAiRuntimeCapability`) | Host-Dienste und Modelle → llama.cpp-Eignung prüfen | Derselbe Bereich und dieselbe Aktion | `GUIDED_BOTH` für die Prüfung vorhandener Paketdateien gegen die Geräteinventur. Runtime-Ausführung und Leistungsnachweise erfolgen separat. |
| SSIS-Ausführungsmetadaten (`Get-SqlServerLabSsisExecutionDiagnostic`) | Lab-Umgebungen → SSIS-Diagnose eines bestehenden Windows-Labs | Lab verwalten → Reguläre Hyper-V-Umgebungen → SSISDB-Ausführung beobachten | `GUIDED_BOTH`. Menü, Belegbindung und Browserdarstellung sind synthetisch geprüft. Native Abnahme der neuen Bedienpfade `NOT_EXECUTED`. |
| SSIS-Paketladediagnose (`Get-SqlServerLabSsisPackageDiagnostic`) | Lab-Umgebungen → SSIS-Diagnose eines bestehenden Windows-Labs | Lab verwalten → Reguläre Hyper-V-Umgebungen → SSIS-Paketladediagnose | `GUIDED_BOTH`. Auswahl, Belegbindung und Vertrauensbestätigung sind synthetisch geprüft. Native Abnahme der neuen Bedienpfade `NOT_EXECUTED`. |
| Erlaubte Gerätekombinationen anzeigen (`Get-SqlServerLabAiComputeCandidate`) | Host-Dienste und Modelle → llama.cpp-Eignung prüfen | Derselbe Bereich und dieselbe Aktion | `GUIDED_BOTH` für die aggregierte Anzahl je Backend und Geräteklasse aus der gebundenen Prüfung. |
| Gerätekombinationen messen (`Measure-SqlServerLabAiComputeCandidate`, `Measure-SqlServerLabAiComputeCandidateSet`) | Host-Dienste und Modelle → llama.cpp-Gerätekombinationen messen | Derselbe Bereich und dieselbe Aktion | `GUIDED_BOTH` für ein lokal gebundenes GGUF und installierte llama-bench-Kandidaten. Geführte Einzel- und Serienauswahl synthetisch geprüft. Neue Hardwaremessung `NOT_EXECUTED`. |
| Portables Lab-Paket prüfen (`Get-SqlServerLabPortableLabImportPlan`) | Datenbanken, Samples und Skripte → Portables Lab-Paket prüfen | Lab-Umgebungen → Datenbankpakete → Portables Lab-Paket prüfen | `GUIDED_BOTH` für die JSON-Prüfung gegen einen registrierten Docker-/Podman-Run. Katalog, Schema und Zielbindung synthetisch geprüft. |
| Automatisierungsvertrag lesen (`Get-SqlServerLabAutomationPlan`) | Wartung, Aufräumen und Recovery → Automatisierungsschnittstelle ansehen | Wartung → Automatisierungsschnittstelle ansehen | `GUIDED_BOTH` für sechs Fachverträge und deren Pflichtparameter. Die Ansicht führt keinen Fachvorgang aus. |
| SQL-Editionsbeleg aktualisieren (`Update-SqlServerLabSqlGuestEvaluationEvidence`) | Wartung, Aufräumen und Recovery → SQL-Editionsbeleg im Gast aktualisieren | Wartung → SQL-Editionsbeleg im Gast aktualisieren | `GUIDED_BOTH` für geeignete eigene laufende Hyper-V-Labs mit SQL Server 2025. Auswahl und Bestätigung sind synthetisch geprüft. Native Abnahme der neuen Bedienpfade `NOT_EXECUTED`. |
| CPU, GPU und NPU erfassen (`Get-SqlServerLabAiComputeInventory`) | Host-Dienste und Modelle → CPU, GPU und NPU erfassen | Derselbe Bereich und dieselbe Aktion | `GUIDED_BOTH` für die Übersicht. Synthetische vollständige und partielle Gerätebefunde in Inventar- und Browserfixtures. Keine Geräte- oder Runtimequalifikation. |
| Gemeinsamen Embedding-Gateway planen (`Get-SqlServerLabAiSharedGatewayPlan`) | Host-Dienste und Modelle → Gemeinsamen Embedding-Gateway planen | Derselbe Bereich und dieselbe Aktion | `GUIDED_BOTH` für den Konfigurationsplan. `Invoke-AiSharedGatewayPlanChecks.ps1` belegt Menü, HTTP-Handler, Browser-Formular und Übergabe des Plans. Runtime, Registrierung und SQL-Verbraucherprüfung sind getrennte Fachaktionen. |
| Lokale Gateway-Dateien prüfen (`Test-SqlServerLabAiSharedGatewayPreflight`) | Gemeinsamen Embedding-Gateway planen → Lokale Gateway-Dateien für diesen Plan prüfen → Dateien jetzt prüfen | Gleicher Bedienweg und Ergebnis im Auftragsprotokoll | `GUIDED_BOTH`. Die Plan-Suite prüft Navigation, Abbruch und Planbindung. Die Preflight-Suite liest synthetische Artefakte nach Bestätigung und prüft Pfadablehnung und den Schutz des Schlüsselpfads. |
| Gateway-Dateien geschützt registrieren (`Register-SqlServerLabAiSharedGatewayStorage`) | Gemeinsamen Embedding-Gateway planen → Gateway-Dateien für diesen Plan geschützt registrieren → Dateien geschützt registrieren | Gleicher Bedienweg mit ausdrücklicher Bestätigung der Kopie | `GUIDED_BOTH`. Die Plan-Suite prüft Planbindung, Bestätigung und Browser-Auftrag. Die Storage-Suite prüft Abbruch, echte Kopie synthetischer Dateien im isolierten konfigurierten State Root und die idempotente Wiederholung. |
| Status für diesen Gateway-Plan lesen (`Get-SqlServerLabAiSharedGatewayStatus`) | Gemeinsamen Embedding-Gateway planen → Status für diesen Gateway-Plan lesen | Gleicher Bedienweg. Status im Auftragsprotokoll. | `GUIDED_BOTH` für den auf Auswahl gelesenen Status. `Invoke-AiSharedGatewayPlanChecks.ps1` prüft Menü, Planbindung, Browser-Dispatch und den öffentlichen Auftragsvertrag. `Invoke-AiSharedGatewaySessionChecks.ps1` prüft einen eigenen Loopback-Listener und getrennte Registrierungen mit synthetischen Daten. Besitz gilt nur in der startenden Modulsitzung. SQL-Anbindung ist eine getrennte Prüfung. |
| Registrierten Loopback-Upstream prüfen (`Test-SqlServerLabAiSharedGatewayUpstream`) | Gemeinsamen Embedding-Gateway planen → Registrierten Loopback-Upstream mit Testanfrage prüfen | Gleicher Bedienweg, Ausgabe im Auftragsprotokoll | `GUIDED_BOTH` für den gebundenen Plan ohne API-Schlüssel. Menü und Browserdispatch sind synthetisch belegt. Die getrennte Core-Suite prüft Registrierung und Antwortvertrag mit injiziertem Testtransport. Ein echtes Modell bleibt außerhalb dieses Nachweises. |
| Host-Autostart vorbereiten (`Get-SqlServerLabAiSharedGatewayServicePlan`) | Gemeinsamen Embedding-Gateway planen → Host-Autostart für diesen Gateway-Plan vorbereiten → Modus wählen | Gleicher Bedienweg mit Modusauswahl und Dienstplan im Auftragsprotokoll | `GUIDED_BOTH`. Plan- und ServicePlan-Suites prüfen Planbindung, Auswahl, Hostbefund und Abbruch mit synthetischen Voraussetzungen. Installation und Dienstbetrieb sind eigene Schritte. |
| Dienst-Secrets prüfen (`Test-SqlServerLabAiSharedGatewayServiceSecret`) | Bereiter Dienstplan → Dienst-Secrets für diesen Plan prüfen | Bereiter Dienstplanauftrag → In Dienst-Secret-Prüfung übernehmen → Dienst-Secrets prüfen | `GUIDED_BOTH`. Die Browser-Fixture prüft Auftrags-ID, exakte Plan- und Modusbindung sowie den Ausschluss laufender oder blockierter Ergebnisse. Die ServiceSecret-Suite belegt explizite Auswahl, gebundene Referenzen und begrenzte Ausgabe. Nichtinteraktiver Zugriff des tatsächlichen Diensts bleibt offen. |
| Eigene Gateway-Sitzung starten (`Start-SqlServerLabAiSharedGatewaySession`) | Registrierter Gateway-Plan → Eigene Gateway-Sitzung für diesen Plan starten | Gleicher Einstieg. Bestätigter Start mit lokalem Vault. | `GUIDED_BOTH`. Die Session-Suite prüft maskierte CLI-Eingabe, Auflösung gebundener Browser-Referenzen und den Loopback-Worker mit synthetischem Upstream. Die SQL-Bindung bleibt separat. |
| Eigene Gateway-Sitzung stoppen (`Stop-SqlServerLabAiSharedGatewaySession`) | Host-Dienste und Modelle → Eigene Gateway-Sitzung auswählen und stoppen | Eigene Gateway-Sitzungen verwalten → auswählen und Stop bestätigen | `GUIDED_BOTH`. Die Session-Suite prüft Besitzgrenze, Ablehnung, bestätigtes Ende und Cleanup im synthetischen Loopback-Fall. |
| Metadaten eines entfernten Runs prüfen und entfernen (`Get-SqlServerLabRunArtifactRemovalPlan`, `Invoke-SqlServerLabRunArtifactRemoval`) | Wartung, Aufräumen und Recovery → Artefakte eines entfernten Runs | Wartung und Recovery → Run-Artefakte prüfen | `GUIDED_BOTH`. Dieselben Cmdlets für gebundene Vorschau, bestätigte Entfernung und Fortsetzung. Workflow-UI und CLI-Vertragsfälle mit synthetischem State. |
| Evaluationsersatz oder Migration vorprüfen (`Get-SqlServerLabEvaluationRefreshPlan`) | Wartung, Aufräumen und Recovery → SQL-Evaluation: Ersatz- und Migrationsentscheid | Wartung und Recovery → SQL-Evaluation: Ersatzentscheid | `GUIDED_BOTH` für die lesende Vorschau. Synthetische CLI-, HTTP- und Browserfälle. Die Vorschau führt keine Übernahme aus. |
| Registriertes Ziellab vorprüfen (`Get-SqlServerLabEvaluationRefreshPlan -TargetRunId -TargetInstanceId`) | Ersatz- und Migrationsentscheid → Instanzzustand migrieren → Registriertes Ziellab vorprüfen | Ersatzentscheid → Instanzzustand migrieren → Registriertes Ziellab → Vorschau lesen | `GUIDED_BOTH` für zwei getrennte registrierte SQL-2025-Hyper-V-Bindungen. Die Evaluationsplan-, CLI-, HTTP- und Browserfixtures prüfen Änderungen beider Auswahlen, Abbruch und Schreibfreiheit. Die Zielprüfung umfasst gespeicherte Metadaten. |
| Windows-Lizenz des Ziellabs beobachten (`Get-SqlServerLabEvaluationRefreshPlan -ObserveTargetWindowsLicense`) | Ersatz- und Migrationsentscheid → Instanzzustand migrieren → Windows-Lizenz im laufenden Ziellab lesen | Ersatzentscheid → Instanzzustand migrieren → registriertes laufendes Ziellab wählen → Windows-Lizenz im Ziellab lesen | `GUIDED_BOTH` für die gezielte Windows-Leseabfrage. CLI, Browser und Auftragsgrenze sind synthetisch geprüft. Der gemeinsame Workflow las die Lizenz eines separaten laufenden Hyper-V-Ziellabs auf Key18. Quelle und Ziel waren eigene SQL-2025-Developer-Runs. [Nativer Nachweis](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45463261705) |
| SQL-Bereitschaft und Edition des Ziellabs prüfen (`Get-SqlServerLabEvaluationRefreshPlan -ObserveTargetSqlReadiness`) | Ersatz- und Migrationsentscheid → Instanzzustand migrieren → SQL-Bereitschaft und Edition im laufenden Ziellab prüfen | Ersatzentscheid → Instanzzustand migrieren → registriertes laufendes Ziellab wählen → SQL-Bereitschaft und Edition im Ziellab prüfen | `GUIDED_BOTH` für eine lesende SQL-Gastabfrage auf dem gebundenen SQL-2025-Prepared-Ziel. Ergebnis `OBSERVED` oder `NOT_OBSERVED`. Die Edition erhält einen separaten Befund. Die Evaluationsfrist bleibt unbeobachtet oder nicht anwendbar. Die Developer-Klassifikation ist in einem eigenen SQL-2025-Developer-Ziel [nativ belegt](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45584818347). Die Zielprüfung erteilt keine Transferfreigabe. |
| Freien Gastspeicher des Ziellabs lesen (`Get-SqlServerLabEvaluationRefreshPlan -ObserveTargetStorage`) | Ersatz- und Migrationsentscheid → Instanzzustand migrieren → Freien Speicher im laufenden Ziellab prüfen | Ersatzentscheid → registriertes laufendes Ziellab wählen → Freien Speicher im Ziellab prüfen | `GUIDED_BOTH` für gebundene SQL-2025-Ziel-VMs. Synthetisch und im gerenderten Browser geprüft. Zeigt freien Platz je lokalem Volume, ohne Pfade, Ressourcenänderung oder Transferfreigabe. [Native Hyper-V-Abnahme](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45513939058). |
| SQL-Dateizuweisung und freien Zielspeicher vergleichen (`Get-SqlServerLabEvaluationRefreshPlan -CompareFileAllocation`) | Ersatz- und Migrationsentscheid → Instanzzustand migrieren → SQL-Quelldateigrößen mit freiem Zielspeicher vergleichen | Ersatzentscheid → laufende Quelle und laufendes Ziel wählen → SQL-Quelldateigrößen mit freiem Zielspeicher vergleichen | `GUIDED_BOTH` für getrennte gebundene SQL-2025-Prepared-Labs. Synthetische Core-, Konsolen-, HTTP- und Browser-Fixtures prüfen gemeinsame Volumes, fehlende Messung und beide Auswahlbindungen. Nativer kombinierter Nachweis `NOT_EXECUTED`. |
| SQL-Quellzähler, Dateigrößen und Prüfhinweise beobachten (`Get-SqlServerLabEvaluationRefreshPlan -ObserveSqlSource`) | Ersatz- und Migrationsentscheid → Instanzzustand migrieren → SQL-Quellzähler im laufenden Gast lesen | Ersatzentscheid → Instanzzustand migrieren → SQL-Quellzähler im Gast lesen | `GUIDED_BOTH` für die lesende Auswahl und die abgeleiteten Prüfhinweise. Die ursprünglichen neun Zähler der Gastprobe sind für eine laufende SQL-2025-Developer-Prepared-Instanz unter Hyper-V [nativ belegt](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45343380820). Prüfhinweise und Bedienwege sind synthetisch geprüft. Der erweiterte Gastbefund mit elf Zählern ist im selben SQL-2025-Developer-Scope [nativ belegt](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45418884558). Die zugewiesenen Daten- und Logdateiseiten sind mit einem exakten positiven Zuwachs an einer eigenen Benutzerdatenbank [nativ belegt](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45573172192). |
| Windows-Lizenz im Gast beobachten (`Get-SqlServerLabEvaluationRefreshPlan -ObserveWindowsLicense`) | Ersatz- und Migrationsentscheid → Windows-Lizenz im laufenden Gast lesen | Ersatzentscheid → Windows-Lizenz im Gast lesen | `GUIDED_BOTH` mit synthetischem Menü- und Browserdispatch. Die flüchtige Gastabfrage wurde in einer eigenen SQL-2025-Developer-Prepared-VM einschließlich unveränderter Metadaten und Cleanup [nativ belegt](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45381383611). |
| Vorhandene Hyper-V-Checkpoints lesen (`Get-SqlServerLabHyperVRecoveryPointPlan`) | Wartung, Aufräumen und Recovery → Hyper-V-Wiederherstellungspunkte lesen | Wartung → Hyper-V-Wiederherstellungspunkte lesen | `GUIDED_BOTH` für das Checkpoint-Inventar. Synthetische Menü- und HTTP-Bindung geprüft. Native Oberflächenabnahme `NOT_EXECUTED`. |
| Gespeicherten Diagnosebefund lesen (`Get-SqlServerLabDiagnosticBundle -SkipReadiness`) | Wartung, Aufräumen und Recovery → Gespeicherten Diagnosebefund lesen | Wartung → Gespeicherten Diagnosebefund lesen | `GUIDED_BOTH` für gebundene Metadaten im Standard-Lab_Data. Native Provider- und SQL-Readiness sind hier `NOT_EXECUTED`. |
| Vector-Core-Szenarioplan lesen (`Get-SqlServerLabAiScenario`) | Lab-Umgebungen → Datenbanken, Samples und Skripte → SQL Server 2025 KI → Szenarioplan | Host-Dienste und Modelle → Vector-Core-Szenarioplan lesen | `GUIDED_BOTH` für `vector-core-ci/1.0`, entweder aus dem Katalog oder gegen den gespeicherten KI-Intent einer laufend registrierten Docker-/Podman-Instanz. Das Szenario wird nicht ausgeführt. |
| Run-State-Format prüfen (`Get-SqlServerLabRunStateUpgradePlan`) | Wartung, Aufräumen und Recovery → Format eines Run-States prüfen | Wartung → Format eines Run-States prüfen | `GUIDED_BOTH` für die lesende Vorschau eines registrierten Runs. Der getrennte Upgrade-Befehl bleibt auf synthetische Legacy-States begrenzt. |
| Registrierte Hyper-V-Zielpfade und Kapazität lesen (`Get-SqlServerLabHyperVResourcePreview`) | Hyper-V: Vorlagen und Slots → Hyper-V-Zielpfade und freien Speicher anzeigen | Derselbe Bereich und dieselbe Aktion | `GUIDED_BOTH` für das registrierte Standardziel. Der Browser prüft keine frei eingegebenen Pfade. Vertrags- und Browserprüfungen verwenden einen isolierten lokalen Speicherkatalog. |
| Windows-Slot-Pool vorbereiten (`New-SqlServerLabWindowsSlotPool`) | Hyper-V: Vorlagen und Slots → Windows-OS-Slot-Pool automatisch erstellen | Hyper-V: Vorlagen und Slots → Windows-OS-Slot-Pool vorbereiten | `GUIDED_BOTH` für automatisch erzeugte, geschützte Passwörter. Browser-Fixtures prüfen Baseline-Auswahl, Ressourcenwerte und Bestätigung. Der Browser-Pfad legt im Test keine nativen VMs an. |
| Wartungsplan lesen (`Get-SqlServerLabMaintenancePlan`) | Wartung, Aufräumen und Recovery → Schnellen oder vollständigen Wartungsplan lesen | Derselbe Bereich und dieselben Aktionen | `GUIDED_BOTH` für Providerstatus und Zähler. Der vollständige Plan ergänzt Zähler aus dem lesenden Speicher- und Cleanup-Audit. Beide Ansichten lassen Objekt- und Pfaddaten aus. Apply ist eine separate PowerShell-Operation. |

Am 21.11.2026 bestand der Menüpfad in einer nummerierten PowerShell-Konsole
mit einem eigenen lokalen Speicherfixture. Der Katalog blieb unverändert.
Ein Headless-Edge-Test mit vollständiger Produktseite und synthetischem
Endpunkt bestätigte Navigation, Klassenausgabe, Fehleranzeige und Schließen.
Die Vorschau erfordert für diese Prüfung keinen Start einer Hyper-V-VM.

## Geprüfte Operationen: Manifest, Registrierungen und Containerwerkzeuge

| Operation | Geführter CLI-Pfad | Geführter GUI-Pfad | Vertrag und Nachweis |
|---|---|---|---|
| Vorhandenes Manifest prüfen (`Test-SqlServerLabManifest`) | Lab-Umgebungen → Datenbanken, Samples und Skripte → Vorhandenes Lab-Manifest prüfen | Lab erstellen → Container-Manifest prüfen oder ausführen → Manifest prüfen | `GUIDED_BOTH` für eine ausgewählte lokale Manifestdatei. Schema und Fachregeln greifen vor der Provisionierung. Manifest-Builder-, HTTP- und Browserprüfungen decken Erfolg, ungültige Eingaben und die Secret-Grenze ab. |
| SSMS-Registrierungen exportieren (`Export-SqlServerLabSsmsRegistration`) | Verbindungszentrale → SSMS-Export | Verbindungen und CMS → SSMS-Registrierungen herunterladen | `GUIDED_BOTH` für gespeicherte reguläre Endpunkte. Der Browser liefert bis zu 500 Einträge als kennwortfreie `.regsrvr` ohne Providerabfrage. CMS-Vertrags- und Browserprüfungen decken Auswahl und Download ab. |
| Gespeicherte SQL-Endpunkte ansehen (`Get-SqlServerLabConnectionCenter -StoredOnly`) | Verbindungen und CMS → Gespeicherte SQL-Endpunkte anzeigen | Verbindungen und CMS → Gespeicherte SQL-Endpunkte anzeigen | `GUIDED_BOTH`. Die Oberflächen zeigen reguläre gespeicherte Endpunkte ohne Providerabgleich. Core-, Konsolen- und Browser-Fixtures prüfen die begrenzte Projektion und den Verzicht auf Verbindungsstrings. |
| Registrierten CMS abgleichen (`Sync-SqlServerLabCms`) | Verbindungszentrale → CMS verwalten und synchronisieren → CMS jetzt synchronisieren | Verbindungen und CMS → Registrierten CMS lesend prüfen → CMS synchronisieren | `GUIDED_BOTH` für vorhandene Docker-/Podman-CMS ohne Kennwortalias. Der Browser bestätigt die zuletzt gelesene Registrierung. Der Core prüft Run und Container, führt den verwalteten SQL-Abgleich aus und lässt unverwaltete Registrierungen bestehen. Synthetische Prüfungen decken auch veraltete Auswahlen ab. |
| SqlPackage-Version abfragen (`Test-SqlServerLabContainerTool`) | Lab-Umgebungen → Datenbanken, Samples und Skripte → SqlPackage-Version im Container prüfen | Lab erstellen → SqlPackage-Version im Container prüfen | `GUIDED_BOTH` für kataloggebundenes SqlPackage in einer ausgewählten Docker-/Podman-Instanz. Die Versionsabfrage bindet die geprüfte Container-ID. Softwarekatalog- und Browserprüfungen decken Fehlerpfade und die read-only Weiterleitung ab. |
| Wartende Vorgänge priorisieren und umreihen (`Set-SqlServerLabOperationPriority`, `Move-SqlServerLabOperation`) | Vorgänge, Queue und Benutzeraktionen → Priorität ändern oder Vorgang umreihen | Vorgänge, Warteschlange und Wiederaufnahme → Priorität, Nach oben oder Nach unten am Vorgang | `GUIDED_BOTH` für wartende Vorgänge. Die Browserprüfung deckt angezeigte Optionen, gebundene Vorgangs-ID, laufende Vorgänge und parallele Bedienung desselben Vorgangs ab. |

Am 21.11.2026 bestand `Invoke-ConnectionCenterCmsInspectionAcceptance.ps1
-IncludeBoundSync -Version 2025` auf Quellrevision `f4b81ac1` separat
mit Docker und Podman. Die Abnahme bestätigte den SQL-Abgleich,
die Abweisung einer veralteten Auswahl, den Erhalt unverwalteter
Registrierungen und das Aufräumen der beiden eigenen Test-Labs. Die
Browserbestätigung ist synthetisch geprüft. SSMS und Verbindungen zu
Mitgliedsservern waren außerhalb dieser Abnahme.

Auf Quellrevision `3c60cef0` wurden in Edge Manifestprüfung und
SSMS-Download anhand synthetischer HTTP-Antworten geprüft. Der Test
beobachtete zudem die zielgebundenen Bestätigungen für den CMS-Abgleich
und für SqlPackage und brach beide vor dem Versand ab.


## Geprüfte Teilmenge: Warteschlange und Batchsteuerung

`Invoke-BatchWorkflowChecks.ps1` prüft den persistenten Fachkern in einem
isolierten State-Verzeichnis. Die Browserprüfung
`OperationOrderingUiChecks.cjs` belegt den Dispatch für Priorität und
Umreihen. Beide Prüfungen laufen ohne neue Provider-Labs.

| Operation | CLI-Menü | Browser-GUI | Vertrag und Stand |
| --- | --- | --- | --- |
| `batch.compose` · `New-SqlServerLabBatch` | SQL- oder Windows-Umgebung zusammenstellen → mehrere Positionen | Vorgänge → Batch mit mehreren Umgebungen planen → Entwurf validieren und speichern | Beide Oberflächen planen mehrere Positionen. Der Browser unterstützt SQL unter Linux und Windows sowie reine Windows-Umgebungen. Testmatrix und gemeinsame Änderungen bleiben im Konsolenmenü. |
| `batch.submit` · persistierten Entwurf einreihen | Vorgänge, Queue und Benutzeraktionen → Gespeicherten Batch prüfen und einreihen | Vorgänge → Fortschritt gespeicherter Batches → Entwurf prüfen und einreihen | `GUIDED_BOTH` für validierte Umgebungsentwürfe. Der Browser bestätigt den Batch mit Providerzahlen und gemeinsamen Abhängigkeiten. Ein veränderter Entwurf erfordert eine erneute Prüfung. |
| `batch.list` · `Get-SqlServerLabBatch` | Vorgänge → Batch für den Stopp auswählen | Vorgänge → Fortschritt gespeicherter Batches | Der Browser zeigt bis zu 50 Batchstände mit Zählern. Das Menü liest Batches für die Auswahl. Es bietet keine getrennte Detailübersicht pro Batch. |
| `queue.read` · `Get-SqlServerLabQueue`, `Get-SqlServerLabOperation` | Vorgänge → Queue-Übersicht und Details oder Letzte abgeschlossene Vorgänge | Vorgänge → offene Vorgangskarte oder Letzte abgeschlossene Vorgänge | Beide Historien zeigen bis zu 50 gebundene terminale Ergebnisse. Die Inventar- und Browserfixtures prüfen Status, Begrenzung und die ausgeblendeten internen Felder. |
| `queue.gate.confirm` · `Confirm-SqlServerLabOperationUserAction` | Vorgänge → Benutzeraktionen öffnen → Erledigt, prüfen und fortsetzen | Vorgänge → Erledigt, prüfen und fortsetzen | Der Core setzt einen Vorgang erst nach erfolgreicher technischer Prüfung fort. Bei Windows-Setup dient das Gastkonto nur der Prüfung. Die Auswahl mehrerer Kandidaten bleibt ein CLI-Menüpfad. |
| `queue.suspend`, `queue.resume` · `Suspend-SqlServerLabOperation`, `Resume-SqlServerLabOperation` | Vorgänge → Vorgang pausieren oder freigeben | Vorgänge → Pausieren oder Freigeben | Der Core persistiert die Entscheidung. Pausieren ist für wartende und blockierte Einträge verfügbar, Freigeben für pausierte. |
| `queue.stop` · `Stop-SqlServerLabOperation` | Vorgänge → Vorgang endgültig stoppen und aufräumen | Vorgänge → Stoppen + Cleanup | Beide Bedienpfade verlangen Bestätigung. Der Worker übernimmt eine gespeicherte Stoppanforderung an der nächsten sicheren Schrittgrenze. Er reiht die Bereinigung nur mit der gewählten Cleanup-Option ein. |
| `batch.stop` · `Stop-SqlServerLabBatch` | Vorgänge → Batch stoppen oder vollständig zurückbauen | Vorgänge → Fortschritt gespeicherter Batches → Unfertige Positionen stoppen oder Gesamten Batch zurückbauen | `GUIDED_BOTH`. Der Standardstopp schützt fertige Positionen. Die separate Rückbauvorschau bindet den Zustand der betroffenen Positionen einschließlich fertiger Positionen. Beide Browseraktionen erfordern eine Bestätigung. |
| `queue.run` · `Invoke-SqlServerLabScheduler` | Vorgänge → Scheduler jetzt ausführen | Vorgänge → Hintergrundscheduler anfordern → bestätigen | `GUIDED_BOTH` für den ausdrücklichen Start. Die CLI führt synchron aus. Der Browser fordert den Hintergrundhost für die aktuelle Warteschlange an. Die Annahme belegt keinen laufenden Worker. |

## Geprüfte Operationen der Grundkonfiguration

In der CLI führt **SQL-Lab-Grundkonfiguration → Grundkonfiguration und
Provider prüfen** zu den folgenden Aktionen. Im Browser öffnet
**SQL-Lab-Grundkonfiguration → Grundkonfiguration und Provider öffnen**
denselben Fachablauf. Beide nutzen `Invoke-SqlServerLabWorkflowAction`.
Der Browser sendet die typisierten Anfragen an `/api/initial-setup`.

| Operation | CLI im Dialog | Browser im Dialog | Vertrag und Nachweis |
|---|---|---|---|
| `setup.roots.read` · `GetInitialSetupState` | Registrierung und Rootdetails ansehen, mit F5 aktualisieren | Roots erneut lesen | `GUIDED_BOTH`. Liest Herkunft, registrierte Roots und Standard. Schreibbarkeit und Kapazität bleiben bis zur jeweiligen Einzelprüfung ungeprüft. |
| `setup.roots.configure` · `PlanInitialSetup` / `ApplyInitialSetup` | Fehlende Roots ergänzen / globalen Standard wählen, Vorschau bestätigen | Vorschau erstellen → Angezeigten Plan revalidieren und anwenden | `GUIDED_BOTH`. Apply verlangt Plan und Bestätigung. Ein gültiger Media-Root bleibt erhalten. Der neue Standard gilt für künftige Vorgänge. Geänderte Bindungen sperren die Ausführung. |
| `setup.provider.readiness` · `RefreshSetupProvider` | Einen Provider ausdrücklich erneut prüfen | Provider wählen → Gewählten Provider prüfen | `GUIDED_BOTH` für Installation und Erreichbarkeit des gewählten Providers. Der Befund gilt für Docker, Podman oder Hyper-V einzeln. Providerstart und SQL-Bereitschaft sind separate Vorgänge. |
| `setup.location.capacity` · `RefreshSetupCapacity` | Freien Speicher einer registrierten Lab_Data-Location lesen | Registrierte Lab_Data-Location → Freien Speicher lesen | `GUIDED_BOTH`. Gibt eine datierte Hostdatenträger-Momentaufnahme für genau eine Location zurück. Unbekannt, unlesbar und nicht unterstützt liefern keinen Bytewert. |
| `setup.location.writeability` · `PlanSetupWriteability` / `ProbeSetupWriteability` | Eine registrierte Lab_Data-Location auf Schreibbarkeit prüfen → Vorschau bestätigen | Schreibprobe vorschauen → Bestätigte Schreibprobe ausführen | `GUIDED_BOTH` auf einem lokalen festen Windows-NTFS-/ReFS-Volume. Der befristete Plan bindet die Location. Der Worker schreibt ein Byte in eine eigene temporäre Datei und meldet Schreibbefund und Cleanup getrennt. |

`Invoke-InitialSetupChecks.ps1` prüft Plan, Apply, Abbruch, Status und
Providerdispatch. Die eingebundenen Schreibbarkeits- und Kapazitätsfixtures
prüfen Auswahl, Identität, Zeitgrenzen und Fehlerfälle. Die tatsächlichen
Browsercontroller in `WorkflowSqlTargetChecks.cjs` laufen mit synthetischem
DOM und HTTP-Transport. Diese Nachweise betreffen Host-Grundkonfiguration
und Bedienpfade. Installationen zusätzlicher Provider und SQL-Readiness
haben separate Abnahmen.

## Bereichsinventar

**Grundkonfiguration → Lokale Lizenzprofile prüfen** bietet auf Windows
in CLI und Browser die Profilübersicht und die lokale Formatprüfung.
Ausgaben enthalten Produkt, Version, Edition und Kanal sowie einen
strukturellen Befund. Onlineaktivierung und Änderungen an Profilen sind
eigene Operationen.

In **Lab-Umgebungen → SMTP-Testdienst prüfen** zeigen CLI und Browser
registrierte SMTP-Labs an und prüfen den ausgewählten Mailpit-Receiver.
Die Prüfung verifiziert die Runtime-Bindung und den Containerzustand.
Bei einem bestätigten laufenden Receiver öffnen beide Oberflächen den
lokalen WebMail-Zugang ausdrücklich für 15 Minuten. Das Protokoll zeigt
keinen Startlink. Die Mailzustellung bleibt eine getrennte Prüfung.

CLI und Browser bieten die lesende `-WhatIf`-Vorschau mit optionalem
IPv4-Zielsubnetz. Die automatische Vorschau lässt die Netzkonfiguration im
Prozess unverändert. Die getrennte Bestätigung übergibt den gebundenen
Plan an den öffentlichen Befehl. Dieser prüft den `ExpectedPlanKey`
vor jeder Mutation. Der Plan bindet Provider, Netz-ID, Subnetze und
registrierte Container sowie eine verifizierte lokale Runtime. Fremde, geschützte und nicht eindeutig zugeordnete
Ressourcen sowie eine offene Recovery sperren die Ausführung. Der
synthetisch geprüfte Executor verwendet unveränderliche IDs an einem gebundenen Provider-Endpunkt und
kontrolliert Power und Aliasse nach der Mutation.

Am 22.11.2026 wurde die Migration auf Stand `27a67f4f` mit je einer
eigenen SQL-2025-CU9-Instanz (`17.0.5005.3`) unter Docker und Podman
ausgeführt. Die synthetischen SQL-Daten blieben nach beiden Netzwechseln
lesbar. Podman bestand auch den automatischen Cleanup und den gesamten
Vorher-/Nachher-Inventarvergleich. Beim Docker-Lauf brach der ursprüngliche
Cleanup an der Konsolenbestätigung ab. Die anschließende gezielte
Bereinigung entfernte denselben Run und sein Netz. Der vor dieser
Bereinigung erfasste Fremdbestand blieb erhalten. CLI- und Browser-Dispatch
sind separat mit synthetischen Antworten geprüft. Bei einer unterbrochenen
Migration zeigt dieselbe Vorschau den gespeicherten Recovery-Befund mit
letzter protokollierter Phase und bekanntem Fehlercode. Synthetische
Vertragsfälle prüfen das unveränderte Journal und den gesperrten
Ausführungspfad. Eine geführte Ausführung der Recovery bleibt offen.

Beim persistenten KI-Retrieval führen beide Oberflächen die synthetische
Demo sowie `Prune` und `Remove`. Die Löschaktionen binden die ausgewählte
SQL-2025-Containerinstanz und eine vorhandene Collection-ID. Der Core
prüft den Besitz der Datenbank. Die CLI- und Browser-Fixtures prüfen die
Parameterübergabe und die Bestätigungsgrenze. Für eigene Dokumente führen
beide Oberflächen Anlage, freie Abfrage, Synchronisation und Migration
aus lokaler JSON-Eingabe. Der bestätigte Sync bindet den erwarteten und
den neuen Dokumentbestand an dieselbe Collection. CLI- und Browser-Fixtures
prüfen die Grenze der JSON-Eingabe, ihre Bindung und den Bestätigungsschritt.

Die native Abnahme `Invoke-AiPersistentRetrievalAcceptance.ps1` führte
am 21.11.2026 auf Docker und Podman je 30 Prüfungen mit SQL Server 2025
und dem vorhandenen lokalen Embeddingmodell aus. Sie prüfte unter anderem
Synchronisation, Wiederanlauf, Retention und die Bereinigung von
Test-Datenbanken und Test-Runs. CLI- und Browser-Dispatch haben eigene
synthetische Prüfungen.

Die Bereiche und dokumentierten Grenzen entsprechen der neun Bereiche
umfassenden Navigation in der [Workflow-Oberfläche](../HowTo/WORKFLOW_UI.md).
`TEILWEISE` bedeutet, dass die Oberfläche passende Einstiege enthält, aber
nicht alle Operationen des Bereichs einzeln auf einen CLI-Menüpfad, GUI-Aktion,
öffentlichen Vertrag, Voraussetzungen und Testbelege abgebildet wurden.

| Fachbereich | Geführter CLI-Einstieg | GUI-Bereich | Vorhandene Grundlage | Bewertung |
|---|---|---|---|---|
| Lab-Umgebungen, Run-Lifecycle, Datenbanken, Samples und Skripte | Lab-Umgebungen | Lab-Umgebungen | Workflow-Einstieg; ausgewählte öffentliche Cmdlet-Zuordnungen; Container-/Hyper-V-Abnahmen in der [CLI-Akzeptanzmatrix](CLI_ACCEPTANCE_MATRIX.md) | `TEILWEISE`; vollständige Operations- und Änderungsmatrix offen |
| Geschützte Testsystem-Matrix | Testsystem-Matrix | Geschützte Testsystem-Matrix | Registrierte SQL-Ziele, Vormerkungen und Powerzustand anzeigen. Gruppen-Power, Linux-Anlage, vorbereitete Windows-Anlage, Export, Reparatur und Entfernen. | `TEILWEISE`; Linux-Anlage mit aktuellem oder gezielt gewähltem katalogisiertem Patch. Im Browser führt die Matrix auch zur Vorbereitung einer Windows-/SQL-Vorlage aus ISOs. Der direkte manuelle Medienpfad bleibt im Konsolenmenü. |
| Hyper-V-Vorlagen, Windows-Images und operative Slots | Hyper-V: Vorlagen und Slots | Hyper-V: Vorlagen und Slots, danach Lab verwalten → Reguläre Hyper-V-Umgebungen | Image-/Poolinventar, gebundene Mitgliedaktionen, konfigurierbarer SQL-Ausbauplan sowie Start und Fortsetzen für einen übernommenen normalen Windows-Slot | `TEILWEISE`. Die Browser-Fachaktion zur Erstinstallation von SQL Server 2025 in einem übernommenen Windows-2025-Desktop-Slot ist mit Gastbereitschaft und Cleanup nativ belegt. Dialog und Bestätigung sind separat synthetisch geprüft. Weitere Slot-Workflows und ein nativer Installations-Resume bleiben offen. [Nativlauf](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45360347068) |
| Ressourcen, Medien, Downloads und Speicher | Ressourcen und Downloads | Ressourcen und Downloads | Kataloge, ausgewählte Plan-/Apply-Dialoge und geführte Bedarfsprüfung aus den konfigurierten Ordnern. `Invoke-ResourceSetChecks.ps1` und `WorkflowSqlTargetChecks.cjs` prüfen die Filterung und Übergabe ohne Download. | `TEILWEISE`; vollständige Operationszuordnung und Providerbelege offen |
| Host-Dienste und Modelle | Host-Dienste und Modelle | Host-Dienste und Modelle | Einzelne Modell-/Hostservice-Dialoge und öffentliche Befehle | `KNOWN_GAP` für Fremdstart und weiteren Hostdienst-/Modell-Lifecycle |
| Verbindungen, Registrierungen und CMS | Verbindungen und CMS | Verbindungen und CMS | Gespeicherter SSMS-Export, lesende CMS-Inspection, gebundener CMS-Abgleich und geführtes CMS-Bereitstellen im Browser. Der Core-Abgleich ist mit Docker und Podman abgenommen. | `TEILWEISE`; native Browser-Abnahme und vollständige Operationszuordnung offen |
| SQL-Lab-Grundkonfiguration | Grundkonfiguration | SQL-Lab-Grundkonfiguration | Roots lesen und konfigurieren, Provider prüfen, Kapazitäts- und Schreibprobe | `TEILWEISE`. Die [geprüften Operationen](#geprüfte-operationen-der-grundkonfiguration) sind einzeln zugeordnet. Der Assistent zum Einrichten zusätzlicher Provider bleibt offen. |
| Wartung, Aufräumen und Recovery | Wartung, Aufräumen und Recovery | Wartung/Recovery | Read-only-Pläne, bestätigte Aktionen und Recovery-Verträge je Slice | `TEILWEISE`; komplette Funktions- und Fehlerpfadzuordnung offen |
| Vorgänge, Queue und Scheduler | Vorgänge, Queue und Benutzeraktionen | Vorgänge | Batch-/Queue-Einstiege und Workflow-Aktionen | `TEILWEISE`; jede Operation und ihre Abbruch-/Recoverypfade noch einzeln abzugleichen |
| Expertenbefehle und Meldungen | Alle öffentlichen Befehle / Meldungen | Alle Funktionen / Meldungen | Generierter Export-/Parametersatzkatalog; Konsolen- und Workflow-UI-Prüfungen | `EXPERT_CATALOG_ONLY` als Fachführung; Katalogvollständigkeit ist separat statisch prüfbar |

### Geprüfte Teilmenge: Linux-Testumgebung anlegen

**Geschützte Testsystem-Matrix → Linux-Testumgebung hinzufügen** führt im
Browser eine einzelne SQL-Version mit dem aktuellen Patch oder einem gewählten
katalogisierten CU über die vorhandene Gruppenanlage aus. Vorschau, Eingabeänderung, Abbruch,
Bestätigung und gesperrte Wiederholung sind synthetisch geprüft. Der
Workflow liefert nur den registrierten Schlüssel und die Gruppenbereitschaft.

Am 22.11.2026 registrierte der Workflow-Adapter auf `b3a3c850` ein
eigenes Docker-Lab und in einem getrennten Lauf ein eigenes Podman-Lab
mit SQL Server 2025. Beide Gruppenexporte meldeten Bereitschaft.
Die jeweiligen Bereinigungen entfernten die eigenen Ressourcen und
bestätigten den unveränderten Bestand. Beim früheren kombinierten Lauf
erreichte Podman die SQL-Bereitschaft innerhalb des Zeitlimits nicht.
Die native Abnahme belegt die getrennte Anlage je Provider. Der
Browserversand ist separat synthetisch geprüft.

### Native Abnahme der Windows-Testgruppe

| Operation | CLI-Menü und GUI | Ausführung und Prüfung |
|---|---|---|
| `test-group.windows.create-prepared` | CLI **Geschützte Testsystem-Matrix → Geschützte Testgruppe erstellen oder konfigurieren → Windows aus SQL-Prepared-Vorlage anlegen**. GUI **Testgruppe verwalten → Windows anlegen**. | Beide verwenden denselben Pfad wie `CreateWindowsTestGroupMember`. Er bindet Artefakt-ID, Version und Build per Vorschau an die Registrierung und prüft die Artefaktintegrität vor dem Klonen. Registrierung und Bereitschaft der Gesamtgruppe werden separat gemeldet. Die unten verlinkte native Abnahme deckt den Prepared-Pfad ab. Der separate CLI-Menüpunkt **Windows hinzufügen** mit SQL-/Medienwahl benötigt einen eigenen Nachweis in dieser Matrix. |
| `test-group.repair` | CLI **Geschützte Testsystem-Matrix → Geschützte Testgruppe reparieren**. GUI **Testgruppe verwalten → Gruppe reparieren**. | Beide bestätigen eine gebundene Vorschau vor `Repair-SqlServerLabAutomatedTestEnvironment`. Die Reparatur kann Container ersetzen und Windows-VMs neu starten. Unbestätigte Ergebnisse erfordern die Prüfung des aktuellen Gruppenstatus. |
| `test-group.remove` | CLI **Geschützte Testsystem-Matrix → Geschützte Testgruppe entfernen** oder Composer **Alle Testumgebungen löschen**. GUI **Testgruppe verwalten → Gruppe entfernen**. | Beide binden Mitglieder und Cleanup-Pläne vor `Clear-SqlServerLabAutomatedTestEnvironment`. Ein fehlender oder nach der Vorschau geänderter Plan verhindert die Ausführung. Das öffentliche Cmdlet unterstützt `-WhatIf`. Die bestätigte Gruppenaktion entfernt zugeordnete Ressourcen und lokale Gruppenexporte. Nach einem unbestätigten Ergebnis zuerst den Gruppenstatus prüfen. |

`Invoke-TestGroupGuidanceChecks.ps1` prüft die Menü- und Workflow-Ausführung
mit isolierten Fixtures. `WorkflowSqlTargetChecks.cjs` prüft den Browserversand.
Der native Nachweis unten gilt für eine SQL-2025-Prepared-VM auf Hyper-V. Die
Testmatrix erhält dadurch keinen neuen Nachweis für Docker oder Podman.

Der manuelle Hyper-V-Workflow mit Modus `windows-test-group-acceptance`
prüft auf Key18 eine lokale SQL-Server-2025-Prepared-Vorlage mit Build
`17.0.1000.7`. Bei mehreren geeigneten Vorlagen nutzt er den jüngsten
registrierten Eintrag. Die Artefakt-ID bleibt im lokalen Prüfprotokoll.
Ein eigener State Root und ein eigenes Exportverzeichnis trennen den Test von
der regulären Testsystem-Matrix. Der Test legt ein Mitglied an, stoppt es,
prüft den Wiederanlauf über die Reparatur und entfernt es über die
Gruppenaktion. Er prüft anschließend den Bestand der Hyper-V-VM-IDs und die
Abwesenheit der eigenen Child-Datenträger. Der Browser- und Menüversand wird
weiterhin separat geprüft.

Am 22.11.2026 bestand dieser Ablauf auf Key18 für SQL Server 2025
(`17.0.1000.7`) auf Commit `9d21a819`. Nach Anlage und Reparatur
war SQL jeweils bereit. Der Lauf endete im Zustand `REMOVED`, der
Child-Datenträger fehlte und der Bestand fremder Hyper-V-VMs blieb gleich.
[Key18-Abnahmeprotokoll](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45024970153/job/137215913050)

### Geprüfte Teilmenge: CMS-Management

Der geführte Browserdialog **Verbindungen und CMS → CMS bereitstellen**
deckt das Erstellen und Übernehmen ab. Synthetische UI- und
Adapterprüfungen prüfen Auswahl, Bestätigung und Änderungsschutz.

Am 21.11.2026 bestanden Neuanlage und Übernahme über den gemeinsamen
Workflow-Adapter jeweils mit einem eigenen SQL-Server-2025-Run unter
Docker und Podman. Ohne Bestätigung blieb die Registrierung unverändert.
Bei der Übernahme wurde eine veraltete Vorschau abgewiesen. Die
Auftragsquittungen enthielten keine Zugangsdaten. Die Abnahme entfernte
ihre Container und bei der Neuanlage auch den eigenen persistenten Speicher.
Der Browserversand wurde separat mit synthetischen Antworten geprüft.

| Aktion | CLI-Menü | Browser-GUI | Öffentlicher Vertrag / Nachweis | Grenze |
|---|---|---|---|---|
| Verwalteten CMS erstellen | Verbindungszentrale → CMS verwalten und synchronisieren → CMS automatisch erstellen | Verbindungen und CMS → CMS bereitstellen → Neuen CMS-Run erstellen | `Initialize-SqlServerLabCms`, `Invoke-ConnectionCenterCmsChecks.ps1`, `WorkflowSqlTargetChecks.cjs` | SQL Server 2025 über Docker/Podman. Der Browser erhält keine Zugangsdaten. |
| Bestehenden Run übernehmen | gleicher CMS-Menüpfad → bestehenden Run übernehmen | gleicher Dialog → Vorhandenen SQL-Run übernehmen | interne Fachaktion `Register-SqlServerLabCmsEnvironment`, CMS-State-/Payload-Prüfungen und Workflow-UI-Suite | Geeigneter laufender Docker-/Podman-Run, eine SQL-Instanz und gespeichertes SA-Kennwort. Die Übernahme prüft die aktuelle Containerbindung. |

Die Bezeichnungen stammen aus dem bestehenden Navigationsvertrag. Ein
vorhandener Fachdialog oder Runtime-Smoke darf nur für genau die darin
ausgeführte Operation und gebundene Provider-/Versionszelle als Evidence
verwendet werden.

## Noch ausstehende Operationsmatrix

Diese Matrix muss noch für **jeden** Manifestexport und jede weitere
benutzerseitige Produktoperation eine einzeln prüfbare Zeile mit mindestens
folgenden Feldern erhalten:

1. stabiler Operations-ID und fachlicher Aufgabe, einschließlich Operationen
   an bereits bestehenden Labs;
2. CLI-Menüpfad und getesteter Dispatch, GUI-Bereich und getesteter Aktionspfad;
3. öffentlichem parametriertem Cmdlet, Parametern, WhatIf/Vorschau und
   Bestätigung;
4. Voraussetzungen, Secret-Grenze, Idempotenz, Seiteneffekten sowie
   Fehler-, Cleanup- und Recoveryvertrag;
5. unterstützten Providern und Versionen, mit `NOT_EXECUTED` je nicht
   tatsächlich belegter Runtimezelle;
6. präzisem statischem und Runtime-Testselektor samt Evidence-Revision.

Ein Export, ein Menüeintrag, ein HTTP-Handler oder ein bestandener globaler
Static-Check füllt diese Zeile nicht automatisch aus. Insbesondere erzeugt
eine GUI- oder CLI-Lücke keine neue Providerfähigkeit. Docker, Podman und
Hyper-V bleiben getrennte Nachweisgrenzen; es wird keine Vollmatrix aller
SQL-CUs abgeleitet.

## Umsetzungsreihenfolge und Release-Gate

1. Manifestexporte und die vorhandenen Cmdlet-Referenzen inventarisieren;
   gleiche Fachoperationen über Parameter-/Aliasvarianten deduplizieren.
2. Jede Operation mit tatsächlichem CLI-Menüdispatch, GUI-Aktion und Core
   verbinden und die Statuswerte dieser Datei durch konkrete Quell- und
   Teststellen belegen.
3. Lücken in kohärenten vertikalen Slices ergänzen. Gemeinsame Fachlogik
   bleibt im geprüften Core; Oberflächen stellen sichere Vorschau,
   Eingabevalidierung, nötige Bestätigung und verständliche Recovery bereit.
4. Geänderte statische Verträge zuerst, dann ausgewählte Provider-Smokes
   ausschließlich für unterstützte und betroffene Funktionen prüfen.
5. Erst nach vollständiger vereinbarter Matrix, erfolgreicher betroffener
   Funktionssuite, erforderlichen getrennten Runtime-Nachweisen und grüner
   Pflicht-CI kann ein Release gebaut werden.

Beim historischen Podman-Gate von PR #864 scheiterte der KI-Samples-Test.
Sein eigener Cleanup war erfolgreich. Am 21.11.2026 bestand der übernommene
CMS-Fix zur Wiederverwendung persistenter Labnamen auf dem aktuellen
Entwicklungsstand je acht gezielte native Prüfungen mit Docker und Podman.
Beide Abnahmen bestätigen das abschließende Inventar. Die Freigabe des
integrierten Stands benötigt dessen eigene grüne Pflicht-CI.

TLS-001 bleibt nach Projektentscheidung zurückgestellt.
