# Docker-/Podman-Quick-Testsystem – verbindliche Anforderungen

**Status:** `REQUIRED`  
**Stand:** 25. Juli 2026

**Zuordnung:** `LAB-001 – Reproducible Diagnostic Lab`

## 1. Ziel

Für `SQL_Server_Analyze` ist ein rein containerbasiertes, schnell aufsetzbares Testsystem bereitzustellen. Es muss ohne Hyper-V- oder sonstige VM-Abhängigkeit wahlweise mit Docker oder Podman betrieben werden können.

Der primäre Einsatzzweck ist die kurzfristige Bereitstellung synthetischer SQL-Server-Testinstanzen für Entwicklung, Funktionsprüfung und reproduzierbare Framework-Tests. Das System ersetzt keine vollständige Windows-, WSFC-, FCI- oder hardwarenahe Testumgebung.

## 2. Verbindlicher Bedienvertrag

Die Bereitstellung erfolgt über ein interaktives Installations- beziehungsweise Orchestrierungsskript. Als primäre plattformübergreifende Oberfläche ist PowerShell 7 vorzusehen.

Das Skript muss den Benutzer mindestens nach folgenden Angaben fragen:

1. Container-Runtime:
   - Docker
   - Podman
2. Bereitzustellende SQL-Server-Versionen als Mehrfachauswahl:
   - SQL Server 2019
   - SQL Server 2022
   - SQL Server 2025
3. SQL-Server-Zugangsdaten:
   - administrativer SQL-Loginname;
   - Passwort mit verdeckter Eingabe;
   - optional sichere lokale Passwortgenerierung.
4. Host-Port je Instanz.
5. Container- beziehungsweise Instanzname.
6. Ressourcenprofil:
   - CPU-Limit;
   - Arbeitsspeicherlimit;
   - optional vordefinierte Profile wie `SMALL`, `MEDIUM` und `LARGE`.
7. Lokale Pfade beziehungsweise Volumes für:
   - Daten;
   - Transaktionsprotokolle;
   - Backups;
   - temporäre lokale Laufzeitdaten.
8. Persistenzmodus:
   - persistent;
   - temporär und beim Reset vollständig löschbar.
9. Optionale automatische Installation beziehungsweise Aktualisierung des Frameworks nach erfolgreichem Start.

Die interaktive Abfrage muss durch vollständig dokumentierte Kommandozeilenparameter ergänzt werden, damit derselbe Ablauf unbeaufsichtigt und in CI ausgeführt werden kann.

## 3. Zugangsdaten und Secrets

Kennwörter, Tokens, Connection Strings und andere Secrets dürfen niemals im Repository, in Beispielkonfigurationen, generierten Compose-Dateien, Konsolenprotokollen oder Commit-Inhalten gespeichert werden.

Verbindliche Anforderungen:

- Passwörter werden interaktiv verdeckt abgefragt oder sicher lokal generiert.
- Passwortregeln des verwendeten SQL-Server-Images werden vor dem Start validiert.
- Secrets werden ausschließlich lokal in einem durch `.gitignore` ausgeschlossenen Bereich, über Runtime-Secrets oder über einen gleichwertigen lokalen Secret-Mechanismus gehalten.
- Eine optionale lokale `.env`-Datei muss vollständig ignoriert sein und darf nur synthetische Laufzeitwerte enthalten.
- Konsolenausgaben dürfen Passwörter und vollständige Connection Strings mit eingebettetem Passwort nicht anzeigen.
- Beispielwerte im Repository verwenden ausschließlich klar erkennbare generische Bezeichnungen wie `ExampleSqlAdmin` und niemals ein funktionsfähiges Standardpasswort.
- Ein vom Benutzer gewählter Loginname darf nicht implizit als personenbezogener Wert in versionierte Dateien übernommen werden.

## 4. Container- und Versionsmodell

Für jede ausgewählte SQL-Server-Version wird eine getrennte Instanz mit eigenem Port, Volume-Scope und Healthcheck bereitgestellt.

Die Implementierung muss:

- einen gemeinsamen portablen Compose-Core verwenden;
- Runtime-Abweichungen in getrennten Docker- und Podman-Overrides abbilden;
- Images über explizite Tags und, soweit praktikabel, Digests binden;
- nicht verfügbare oder geänderte Image-Tags mit verständlicher Fehlermeldung behandeln;
- SQL Server 2019, 2022 und 2025 unabhängig auswählbar machen;
- parallelen Betrieb mehrerer Versionen ermöglichen;
- Portkollisionen vor dem Start erkennen;
- Container-, Netzwerk- und Volume-Namen ausschließlich aus einem generischen Lab-Scope ableiten.

SQL-Server-Versionen sollen standardmäßig ressourcenschonend sequenziell gestartet werden können. Ein expliziter Parallelmodus ist zulässig, wenn der Preflight ausreichende Ressourcen bestätigt.

## 5. Geplante Repositorystruktur

Die Umsetzung soll mindestens folgende Artefakte vorsehen:

```text
Lab/
├── README.md
├── .gitignore
├── Install-Lab.ps1
├── Uninstall-Lab.ps1
├── Config/
│   ├── lab.config.example.psd1
│   └── resource-profiles.json
├── Containers/
│   ├── compose.yaml
│   ├── compose.docker.yaml
│   ├── compose.podman.yaml
│   ├── Config/
│   └── Scripts/
├── Orchestration/
│   └── Invoke-DiagnosticLab.ps1
├── .secrets/
├── .state/
└── .artifacts/
```

Die Verzeichnisse `.secrets`, `.state` und `.artifacts` sind ausschließlich lokale Laufzeitbereiche und müssen durch `.gitignore` ausgeschlossen sein.

## 6. Preflight

Vor jeder Änderung muss ein read-only Preflight ausgeführt werden. Er prüft mindestens:

- Betriebssystem und CPU-Architektur;
- Vorhandensein und Erreichbarkeit der gewählten Runtime;
- Runtime-Version und Compose-Unterstützung;
- verfügbare CPU-, RAM- und Datenträgerressourcen;
- Erreichbarkeit der benötigten Container-Registry;
- Verfügbarkeit der angeforderten SQL-Server-Images;
- freie Host-Ports;
- Schreibrechte auf lokale Laufzeit- und Volume-Pfade;
- bereits vorhandene Lab-Ressourcen;
- Konflikte mit bestehenden Container-, Netzwerk- oder Volume-Namen.

Der Preflight verändert keine Container, Netzwerke, Volumes, Dateien außerhalb des Lab-Scopes oder Runtime-Konfigurationen.

## 7. Lebenszyklusbefehle

Die Oberfläche muss mindestens folgende Aktionen anbieten:

- `Preflight`: Voraussetzungen und Konflikte prüfen;
- `Install` beziehungsweise `Up`: Konfiguration erzeugen und ausgewählte Instanzen starten;
- `Status`: Containerstatus, Healthstatus, Ports und SQL-Erreichbarkeit anzeigen;
- `Stop`: Instanzen geordnet stoppen, Daten erhalten;
- `Start`: vorhandene Instanzen erneut starten;
- `Restart`: Instanzen kontrolliert neu starten;
- `Reset`: synthetische Testumgebung reproduzierbar zurücksetzen;
- `UpdateFramework`: Framework erneut installieren beziehungsweise aktualisieren;
- `Down`: Container und Netzwerke entfernen, persistente Daten standardmäßig erhalten;
- `Destroy`: nach expliziter Bestätigung alle Lab-Container, Lab-Netzwerke, Lab-Volumes und lokalen Lab-Laufzeitdaten entfernen.

Destruktive Aktionen müssen den betroffenen generischen Scope anzeigen und eine explizite Bestätigung verlangen. Ein `-Force`-Parameter darf nur für dokumentierte unbeaufsichtigte Abläufe vorgesehen werden.

## 8. Healthchecks und SQL-Bereitschaft

Ein gestarteter Container gilt erst dann als verwendbar, wenn:

1. der Runtime-Healthcheck erfolgreich ist;
2. eine SQL-Verbindung möglich ist;
3. eine einfache Abfrage erfolgreich ausgeführt wurde;
4. die erwartete Hauptversion bestätigt wurde;
5. bei aktivierter Framework-Installation deren Abschluss und Basiskonsistenz geprüft wurden.

Ein reiner Status `running` genügt nicht.

Timeouts, Wiederholungsintervalle und die letzte technische Fehlermeldung müssen diagnostisch ausgegeben werden. Secrets dürfen dabei nicht erscheinen.

## 9. Verbindungsinformationen

Nach erfolgreicher Bereitstellung zeigt das Skript pro Instanz mindestens:

- SQL-Server-Version;
- generischen Instanz-/Containernamen;
- Hostname beziehungsweise `localhost`;
- Port;
- administrativen Loginname;
- Datenbankname des Frameworks, sofern installiert;
- Beispielaufrufe für `sqlcmd` ohne eingebettetes Passwort;
- Verbindungsparameter für SSMS und Azure Data Studio;
- Connection-String-Vorlage ohne Passwort.

Passwörter werden niemals erneut im Klartext ausgegeben.

## 10. Dokumentationsumfang

`Lab/README.md` muss mindestens enthalten:

- Zweck und Grenzen des Quick-Testsystems;
- Voraussetzungen für Docker und Podman;
- unterstützte Betriebssysteme und CPU-Architekturen;
- Installation von PowerShell 7 und benötigten Hilfswerkzeugen;
- interaktiven Quick Start;
- unbeaufsichtigte Beispiele;
- Auswahl einzelner oder mehrerer SQL-Server-Versionen;
- Port-, CPU- und RAM-Konfiguration;
- Persistenz-, Backup- und Reset-Verhalten;
- Start-, Stop-, Status-, Update- und Cleanup-Anweisungen;
- Verbindungsbeispiele für SSMS, Azure Data Studio und `sqlcmd`;
- Secret-Handling und `.gitignore`-Regeln;
- Firewall- und Netzwerkhinweise;
- bekannte Docker-/Podman-Unterschiede;
- Troubleshooting für Image Pull, Portkonflikte, Healthcheck, Loginfehler, Ressourcenmangel und Volume-Rechte;
- vollständige Deinstallation.

## 11. Framework-Installation

Die optionale automatische Framework-Installation muss:

- ausschließlich Repository-Artefakte des Frameworks verwenden;
- die unterstützte SQL-Server-Hauptversion prüfen;
- Installationsfehler pro Instanz getrennt ausgeben;
- keine erfolgreiche Bereitstellung melden, wenn die Framework-Basisprüfung fehlschlägt;
- wiederholbar und möglichst idempotent sein;
- eine bereits vorhandene Installation erkennen;
- Update und Neuinstallation eindeutig unterscheiden;
- keine realen Datenbanken oder Backups verwenden.

## 12. Performance- und Lastgrenzen

Das Quick-Testsystem muss standardmäßig ein ressourcenschonendes Profil verwenden. Es darf den Host nicht ungeprüft mit allen ausgewählten SQL-Server-Versionen und unlimitierten Ressourcen belasten.

Verbindliche Regeln:

- CPU- und RAM-Limits je Container;
- sequenzieller Start als sicherer Standard;
- Warnung bei voraussichtlicher Überbelegung;
- keine automatische Erhöhung systemweiter Runtime-Limits;
- keine Veränderung fremder Container oder Volumes;
- Workloads nur innerhalb der ausgewählten synthetischen Testinstanzen;
- Lastszenarien müssen separat aktiviert werden.

## 13. Fehler- und Zustandsvertrag

Jede Aktion liefert einen eindeutigen Gesamtstatus und je Instanz einen Detailstatus. Mindestens folgende Zustände sind vorzusehen:

- `READY`
- `NOT_INSTALLED`
- `PREFLIGHT_FAILED`
- `RUNTIME_UNAVAILABLE`
- `IMAGE_UNAVAILABLE`
- `PORT_CONFLICT`
- `RESOURCE_LIMIT_EXCEEDED`
- `CONTAINER_START_FAILED`
- `SQL_NOT_READY`
- `AUTHENTICATION_FAILED`
- `FRAMEWORK_INSTALL_FAILED`
- `PARTIAL_SUCCESS`
- `DESTROY_CONFIRMATION_REQUIRED`

Fehler müssen konkrete nächste Prüfschritte nennen, dürfen aber keine Secrets oder umgebungsspezifischen Werte in versionierte Dateien schreiben.

## 14. Abnahmekriterien

Die Anforderung gilt erst als umgesetzt, wenn automatisiert oder dokumentiert nachgewiesen ist, dass:

1. Docker und Podman über dieselbe Bedienoberfläche auswählbar sind;
2. SQL Server 2019, 2022 und 2025 einzeln und gemeinsam gewählt werden können;
3. Loginname, Passwort, Ports und Ressourcen interaktiv abgefragt werden;
4. Passwortwerte weder im Repository noch in Konsolenprotokollen erscheinen;
5. Portkollisionen vor dem Start erkannt werden;
6. Healthchecks die tatsächliche SQL-Bereitschaft prüfen;
7. Start, Stop, Status, Reset, Down und Destroy funktionieren;
8. Verbindungsinformationen ohne Passwort ausgegeben werden;
9. die optionale Framework-Installation erfolgreich geprüft wird;
10. alle erzeugten Daten, Namen und Workloads eindeutig synthetisch sind;
11. Docker- und Podman-Abweichungen dokumentiert und getestet sind;
12. ein vollständiger Quick Start ohne Zugriff auf frühere Chats verständlich ausführbar ist.

## 15. Implementierungsstand und nächste Nachweise

Der verbindliche Quick-Test-Lifecycle ist als `IMPLEMENTED_ACTIONS_GATE`
umgesetzt. Er umfasst Preflight, Installation, Status, Stop, Restart, Reset,
Down, Start, Frameworkupdate und Destroy für die auswählbaren SQL-Server-Versionen
2019, 2022 und 2025. Compose-Core, Docker-/Podman-Overrides, SQL-Healthcheck,
synthetische Zugangsdaten, lokale Zustandsbindung und statische
Datenschutzprüfungen sind Bestandteil des Vertrags.

Der Runtimezustand bleibt `IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING`. Als nächste
Nachweise sind der vollständige Lifecycle auf nativem Docker und nativem Podman
sowie die versionsbezogene SQL-Bereitschaft und Frameworkprüfung auszuführen.
Diese Läufe dürfen ausschließlich zusammengefasste synthetische Evidenz ohne
Secrets, Hostidentitäten oder lokale Pfade veröffentlichen.
