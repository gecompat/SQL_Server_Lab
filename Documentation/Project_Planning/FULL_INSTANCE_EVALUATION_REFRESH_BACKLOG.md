# Vollständiger Instanz-Refresh vor Evaluation-Ablauf – Backlog

| Merkmal | Wert |
|---|---|
| Status | `BACKLOG` |
| Entscheidung | fachlich akzeptiert |
| Stand | 2026-09-06 |
| Primärpfad | Hyper-V/Windows mit getrenntem Windows- und SQL-Evaluationsstatus |
| Ziel | nachgewiesen gleichwertige neue Umgebung ohne Verlängerung oder Reset der alten Evaluation |

## Problem und Entscheidung

Eine ablaufende Windows- oder SQL-Server-Evaluation darf nicht durch einen
In-place-Reset, eine undokumentierte Editionsänderung oder das Weiterbooten
eines abgelaufenen Images behandelt werden. Das Lab baut stattdessen eine neue
Zielumgebung aus verifizierten Medien parallel auf und migriert den vollständig
klassifizierten fachlichen Zustand.

„1:1“ bedeutet in diesem Vertrag **funktionale Gleichwertigkeit**. Quelle und
Ziel müssen nach dem Cutover dieselben freigegebenen Datenbanken,
Serverobjekte, Konfigurationen, SQL-bezogenen Dienste und überprüfbaren
Anwendungsresultate bereitstellen. Eine bitidentische Kopie der Quell-VM gilt
nicht als Evaluation-Refresh, weil sie den bestehenden Maschinen-, Lizenz- und
Evaluationszustand übernimmt.

Der Refresh darf nur `FULLY_EQUIVALENT` melden, wenn jeder inventarisierte
Bestandteil übertragen, gleichwertig rekonstruiert, ausdrücklich ausgeschlossen
oder als Blocker behandelt wurde. Unbekannte beziehungsweise nicht
beobachtbare Bestandteile verhindern diesen Status.

## Aktueller Stand

Bereits vorhanden sind:

- getrennte Windows- und SQL-Evaluationsmetadaten sowie Ausschluss abgelaufener
  Baselines;
- hashgebundene Windows- und SQL-Medien, Image-Builder, parallele Hyper-V-Slots
  und SQL-Readiness;
- verifizierte Full-Backups, Backup-Bibliothek und Datenbankpakete;
- read-only Inventur von Login-Mappings, SQL-Agent-Jobs, Proxies,
  Linked-Server-Kandidaten und TDE-Protektoren;
- persistente Storage-IDs, Retention-Pläne, Hyper-V-Daten-VHDX sowie
  Docker-/Podman-Continue und -Clone;
- ein strikt nicht ausführbarer Datenbank-Migrationsplan für Review und
  Blocker.

Noch nicht vorhanden sind ein vollständiges Quellinventar, Export-/Import-
Executor für Instanzobjekte, sicherer Keymaterialtransfer, externe
Serviceprüfung, transaktionaler Cutover und ein maschineller
Gleichwertigkeitsnachweis. Bestehende Backup- und Paket-Receipts bleiben daher
`DATABASE_FILES_ONLY` mit `FullInstanceMigration=false`.

## Geltungsbereich

Der vollständige Refresh klassifiziert mindestens folgende Ebenen:

| Ebene | Verpflichtender Inhalt |
|---|---|
| Betriebssystem und VM | Windows-Version, Edition, Patchstand, Computeridentität, Zeitzone/Locale, CPU/RAM, Laufwerke, Netzwerk, Firewall und erforderliche Windows-Features |
| SQL-Installation | SQL-Version, Edition, CU, Instanzname, Features, Dienstkontenklasse, Startparameter, Ports und Autostart |
| SQL-Konfiguration | `sp_configure`, Trace Flags, Collation, Defaultpfade, TempDB, Resource Governor und weitere freigegebene Instanzoptionen |
| Datenbanken | Benutzer- und erforderliche Systemdatenbankinhalte, Owners/SIDs, Compatibility Level, Dateitopologie, Backups, Recovery Model, Verschlüsselung und Onlinezustand |
| Serverobjekte | Logins/SIDs, Serverrollen und Berechtigungen, Credentials, Proxies, SQL-Agent-Jobs, Schedules, Operators, Alerts, Linked Servers, Endpoints und Database Mail |
| Schlüssel und Zertifikate | Service Master Key-/Database Master Key-Abhängigkeiten, Zertifikate, TDE-Protektoren und verschlüsselte Backups mit getrenntem Recovery-Nachweis |
| Zusatzfunktionen | External Languages, CLR, FILESTREAM, PolyBase sowie katalogisierte Zusatzsoftware |
| SQL-nahe Dienste | SSISDB, SSIS, SSAS und weitere ausdrücklich gebundene Supporting Components |
| Externe Abhängigkeiten | DNS, SPN, Shares, erlaubte Endpoints, Dienstkonten und Anwendungen, jeweils ohne Secretwerte im portablen Plan |

Nicht vorhandene Capabilities dürfen nicht still übersprungen werden. Der Plan
ordnet jedes Element genau einer der folgenden Klassen zu:

- `EXACT_TRANSFER`: Identität und fachlicher Inhalt werden unverändert
  übertragen;
- `RECONSTRUCT_EQUIVALENT`: der Zustand wird aus deklarativen Quellen
  gleichwertig neu aufgebaut;
- `MANUAL_REQUIRED`: ein dokumentierter Operatorschritt mit nachfolgender
  maschineller Postcondition ist erforderlich;
- `EXCLUDED_EXPLICITLY`: bewusst nicht Teil dieses Refreshs und vor Cutover
  bestätigt;
- `BLOCKED`: sichere Gleichwertigkeit oder Wiederherstellbarkeit ist nicht
  belegt.

## Zielablauf

### Vorwarnung und Preflight

- Windows- und SQL-Evaluationsstatus getrennt live prüfen.
- Standardmäßig mindestens 30 Tage vor dem frühesten relevanten Ablaufdatum
  planen.
- Zielversion, Edition, Provider, Host-Capabilities, Medien, Speicher und
  notwendige Downtime vor der ersten Mutation fest binden.
- TDE, FILESTREAM, SSISDB, SSAS, unbekannte Serverobjekte und externe Dienste
  vorab als Capability oder Blocker klassifizieren.

### Quellinventar und Wiederherstellbarkeit

- Das Quellinventar vor jedem Export versionsgebunden und read-only erzeugen.
- Datenbank-, Instanz-, OS-/VM- und externe Abhängigkeiten getrennt erfassen.
- Secrets nur als lokale `SecretRef` oder erforderliche Operatoraktion führen;
  Secretwerte gelangen weder in Plan, Journal, Log noch Evidence.
- Für jede Datenbank mindestens `CHECKSUM`, `RESTORE VERIFYONLY WITH CHECKSUM`,
  Objekt-SHA-256 und ein getestetes Zielverfahren verlangen.
- TDE-Keymaterial ausschließlich verschlüsselt, getrennt autorisiert und mit
  einem tatsächlichen Restore-Nachweis zulassen.

### Paralleler Neuaufbau

- Ziel-OS und Ziel-SQL aus erneut verifizierten Originalmedien beziehungsweise
  immutable Images erzeugen.
- Eine neue Maschinenidentität verwenden und DNS-/SPN-/Netzwerkumschaltung
  erst im Cutover ausführen.
- Zielkonfiguration und Zusatzsoftware aus katalogisierten oder explizit
  gebundenen Quellen rekonstruieren.
- Die Quelle bleibt während Aufbau und Seed unverändert weiter nutzbar.

### Übertragung und Cutover

- Full-Backup als Seed verwenden; für geringe Downtime Differential-/Log-
  beziehungsweise Tail-Log-Schritte als eigenen Backupkettenvertrag ergänzen.
- Instanzobjekte in deterministischer Reihenfolge importieren und jede
  Postcondition einzeln bestätigen.
- Vor dem finalen Delta einen Cutover-State mit Quelle, Ziel, erlaubtem
  Schreibstatus, Rollbackpunkt und Compensation persistieren.
- Quellschreibzugriffe erst sperren, wenn Ziel und letzter Delta-Schritt bereit
  sind.
- Connection Center, CMS, DNS oder andere Endpunkte erst nach erfolgreicher
  Ziel-Readiness umschalten.

### Gleichwertigkeitsprüfung und Rückfall

Mindestens zu vergleichen sind:

- Anzahl, Identität und Status aller freigegebenen Datenbanken;
- Datenbankinhalt über katalogisierte Assertions, Counts oder Digests;
- Logins/SIDs, Rollen und Berechtigungen;
- Agent-Jobs, Schedules, Proxies, Linked Servers und weitere Serverobjekte;
- wirksame SQL-Konfiguration, Ports, Storagepfade und SQL-Dienste;
- TDE-/Zertifikat- und Backup-Restore-Fähigkeit;
- SSIS-/SSAS-/External-Runtime-Postconditions, sofern im Scope;
- echte Anwendungs- und Verbindungsprobes.

Die Quellumgebung bleibt nach dem Cutover für eine ausdrücklich festgelegte
Rückfallfrist gestoppt oder read-only erhalten. Ein Fehler schaltet nicht
automatisch auf eine teilweise migrierte Zielumgebung um. Cleanup beginnt erst
nach bestätigtem `FULLY_EQUIVALENT`, abgelaufener Rückfallfrist und erneuter
Retention-Prüfung.

## Sicherheitsgrenzen

- Keine Verlängerung, Manipulation oder technische Rücksetzung einer
  abgelaufenen Evaluation.
- Kein VM-, VHDX- oder Runtime-Clone wird allein als erfolgreicher Refresh
  gewertet.
- Keine gemeinsame Read/Write-Nutzung derselben Datenbankdateien durch Quelle
  und Ziel.
- Kein TDE-Cutover ohne verifizierten Zertifikat-/Private-Key-Restore.
- Keine automatische Übernahme unbekannter Credentials, Produktivdaten,
  Hostwerte oder externer Services.
- Keine Quellentfernung ohne unabhängigen Restore-, Gleichwertigkeits- und
  Rollbacknachweis.
- Windows- und SQL-Lizenzstatus bleiben getrennte Gates; ein gültiger Status
  ersetzt den jeweils anderen nicht.

## Lieferpakete

Die Umsetzung erfolgt als getrennte, jeweils statisch und nativ abnehmbare
Pakete:

1. vollständiges, sanitiertes Quellinventar und Klassifikationsplan;
2. verifizierte Exportartefakte für Datenbanken und unterstützte
   Serverobjekte;
3. paralleler Hyper-V-Zielaufbau aus frischen Images;
4. idempotenter Import mit Journal, Resume und Compensation;
5. Backupketten-, Delta- und transaktionaler Cutover-Vertrag;
6. maschineller Gleichwertigkeitsbericht;
7. CLI-/Browser-Preview und ausdrücklich bestätigte Ausführung;
8. nativer End-to-End-Nachweis mit Rückfall und vollständigem Cleanup.

Der erste Vertical Slice verwendet ausschließlich synthetische Daten auf einem
lokalen Hyper-V-Windows-/SQL-Evaluationspaar. Er überträgt mindestens eine
Benutzerdatenbank, Login/SID, SQL-Agent-Job, eine freigegebene
Instanzkonfiguration und einen katalogisierten Anwendungstest. TDE, SSISDB,
SSAS oder nicht unterstützte externe Services müssen in diesem Slice vor der
ersten Migration als `BLOCKED` enden, nicht als stiller Teil-Erfolg.

## Definition of Done

Der Gesamtvertrag ist erst abgeschlossen, wenn:

- Windows- und SQL-Evaluation getrennt erkannt und im Refreshplan gebunden
  werden;
- kein inventarisiertes Element ohne Klassifikation bleibt;
- Export, Import, Cutover, Resume, Rollback und Cleanup journalisiert sind;
- ein Prozessabbruch nach jedem mutierenden Schritt deterministisch fortgesetzt
  oder kompensiert werden kann;
- Quelle und Ziel durch den versionierten Gleichwertigkeitsbericht verglichen
  werden;
- `FULLY_EQUIVALENT` bei fehlenden, unbekannten oder nur manuell behaupteten
  Postconditions technisch unmöglich ist;
- ein realer Hyper-V-Lauf den vollständigen Refresh einschließlich
  Anwendungsprobe, Rückfallübung und scopegebundenem Cleanup belegt;
- keine Secrets, realen Hostwerte oder nicht freigegebenen Daten in
  versionierter Evidence enthalten sind.

## Abhängigkeiten

- [Persistente Daten und Evaluation-Refresh](../HowTo/PERSISTENT_DATA_AND_EVALUATION_REFRESH.md)
- [Persistente Speicherwiederverwendung und Lab_Data](PERSISTENT_STORAGE_REUSE_AND_LAB_DATA_BACKLOG.md)
- [Automatische Windows-Slot-Aktivierung](WINDOWS_SLOT_ACTIVATION_BACKLOG.md)
- [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](../Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md)
- [Bekannte Grenzen](../Quality/KNOWN_LIMITATIONS.md)

Dieser Backlog autorisiert noch keine Export-, Import-, Cutover-, Lizenz- oder
Löschmutation. Bis zur implementierten und validierten Ausführung bleiben die
bestehenden Datenbank-Migrationspläne strikt read-only.
