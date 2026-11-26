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

`Get-SqlServerLabEvaluationRefreshPlan` implementiert einen engen Entscheid für
genau eine moderne registrierte Hyper-V-SQL-Instanz unter explizitem `DataRoot`.
`FREE_SLOT_REPLACEMENT`, `RECONSTRUCT_LAB` und `STATEFUL_MIGRATION` bleiben
getrennte `BLOCKED`-Modi mit festen Blockern und nächsten Schritten, ohne
Aktionen, Persistenz oder Transferautorität. Windows-Aktivierung bleibt
historische Metadaten; SQL-Fristen stammen aus dem bestehenden gebundenen
Gast-Receipt. Ein ungebundenes DependencyInventory wird nicht angenommen.
Vollständiger Refresh, Zielauswahl, Export, Keytransfer, Cutover, Rückfall und
Gleichwertigkeit bleiben Backlog; der Datenbankplan bleibt `DATABASE_FILES_ONLY`.

Die CLI bietet **Wartung, Aufräumen und Recovery → SQL-Evaluation: Ersatz-
und Migrationsentscheid** als geführte reine Vorschau. Derselbe Dialog ist
auch unter **Alle öffentlichen Befehle → SQL-Evaluation: Ersatzentscheid**
erreichbar. Unter einem ausdrücklich eingegebenen registrierten
Root sind höchstens 64 Run-Verzeichnisse und nur eine vollständig gebundene
moderne Hyper-V-SQL-Instanz auswählbar. Der gemeinsame Plankern prüft den
Digest der Auswahl unmittelbar vor einem Gastzugriff. Abbruch verwirft
die Auswahl.
Windows-/SQL-Quelle und Aktualität werden getrennt angezeigt. Ein geführter
Browserdialog ist ebenfalls als reine RAM-Vorschau im Bereich **Wartung,
Aufräumen und Recovery** implementiert: eigener begrenzter HTTP-Metadaten-/
Previewpfad, dieselbe registrierte D-Readerautorität und öffentlicher Core,
Auswahlrevalidierung, getrennte Windows-/SQL-Evidence und Abbruch ohne Jobs.
Die geführte CLI bietet bei **Instanzzustand migrieren** zusätzlich
**SQL-Quellzähler im laufenden Gast lesen**. Der Schalter `-ObserveSqlSource`
liest denselben begrenzten Start der Inventur auf einer gebundenen
SQL-2025-Prepared-Instanz. Er zählt Benutzer-Datenbanken mit Teilmengen für
Zustand und Verschlüsselung, Snapshots, FILESTREAM-Dateityp, den
SSISDB-Katalogkandidaten, Serverprinzipale, Credentials, Linked Server,
Agent-Jobs und Proxies. Werte erscheinen nur aggregiert,
ohne SQL-Objektnamen oder Zugangsdaten. Bei fehlendem Live-Nachweis bleiben
die Werte unbeobachtet. Im Browser löst dieselbe getrennte Aktion einen
flüchtigen Leseauftrag mit gebundener Auswahl aus. Positive Zähler erzeugen
feste Prüfhinweise für Datenbankzustand, TDE-Schlüssel, Snapshots, FILESTREAM-
Dateityp, mögliche SSISDB, Zugangsdaten, Linked Server, SQL-Agent-Jobs und
-Proxies. Die SSISDB-Namensübereinstimmung erfordert eine Katalogprüfung.
Ein Nullwert beschreibt
die beobachtete Kategorie zum Prüfzeitpunkt. Die SQL-Quellabfrage zeigt auch die aggregierten, im SQL-Katalog
zugewiesenen Seiten der regulären Benutzer-Daten- und Logdateien in Bytes.
Systemdatenbanken, Snapshots und FILESTREAM-Dateien sind aus dieser Summe
ausgeschlossen. Fehlende oder ungültige Größenwerte bleiben unbeobachtet.
Die Summen liefern weder die belegte Kapazität im Dateisystem noch die
Backupgröße oder den vollständigen Platzbedarf am Ziel. Vollständige Inventur
und sämtliche Transferaktionen bleiben offen.
Die [Key18-Abnahme der Dateigrößen](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45573172192)
auf `9eea8419` bestätigte in einem eigenen SQL-2025-Developer-Gast den exakten
Zuwachs der Daten- und Logdateiseiten nach Anlage einer eigenen Testdatenbank.
Sie verglich die Quellsummen vor und nach der Anlage mit den Dateiseiten der
Testdatenbank. Run- und Verbindungsmetadaten sowie das Prepared-Artifact
blieben unverändert. Eigene VM und Datenträger wurden vollständig entfernt.
Die [Key18-Abnahme](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45343380820)
belegt die ursprünglichen neun Zähler der Gastprobe für SQL Server 2025 Developer, Build
`17.0.1000.7`. Der eigene Run wurde bereinigt und die Vorlage blieb
unverändert. Die [erweiterte Key18-Abnahme](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45418884558)
auf e4cdc1ac bestätigte elf typisierte Zähler einschließlich FILESTREAM-Dateityp
und SSISDB-Namenskandidat auf demselben Prepared-Artifact. Run- und
Verbindungsmetadaten sowie Vorlage blieben unverändert. Eigener Run, VM und
Disks wurden vollständig bereinigt. Die Zielvorschau bleibt eine Metadatenprüfung.

Bei **Instanzzustand migrieren** kann ein separates registriertes
SQL-2025-Hyper-V-Lab als Ziel gewählt werden. Die Metadatenvorschau bindet
Quelle und Ziel unter demselben `Lab_Data` an getrennte Run-, Scope- und
VM-Identitäten. Sie verwirft geänderte Bindungen und benennt die noch
ausstehenden Zielprüfungen für Windows-Lizenz, SQL-Bereitschaft, Speicher
und Transfer. Die gesonderte Live-Abfrage der Windows-Ziellizenz setzt eine
laufende Ziel-VM voraus. Sie bindet beide Snapshots und verwirft das Ergebnis
bei Änderungen. Eine separate Aktion prüft über den vorhandenen SQL-Gastreader
die Bereitschaft der erwarteten Instanz im laufenden SQL-2025-Prepared-Ziel.
Dieselbe Gastabfrage klassifiziert eine unterstützte SQL-Edition und zeigt
offen an, wenn eine Evaluationsfrist unbeobachtet bleibt. Die
Lizenzgültigkeit wird separat bewertet. Die [native Key18-Abnahme](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45584818347)
auf `93678dfe` bestätigte die Developer-Klassifikation am gebundenen Ziel.
Die Quelle war vor dem Zielstart gestoppt. Die Vorlage und Metadaten blieben
unverändert. Beide eigenen Runs, VMs und Datenträger wurden bereinigt.
Der freie Platz für die SQL-Standardpfade Daten, Log und Backup lässt sich
getrennt in der Ziel-VM lesen. Gemeinsam genutzte Volumes erscheinen einmal.
Die Speicherbeobachtung dient der Vorbereitung. Quellbedarf, Hostkapazität,
SQL-Lizenz, Gleichwertigkeit und Transfer müssen separat geprüft werden.
Die [native Key18-Abnahme](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45513939058)
beobachtete alle drei Speicherrollen am separaten SQL-2025-Developer-Ziellab
und bestätigte unveränderte Metadaten und vollständigen Cleanup.
Der Gesamtplan bleibt `BLOCKED`.

Der geführte Vergleich `-CompareFileAllocation` liest beide gebundenen
Gastbefunde, sofern die SQL-2025-Prepared-Labs bereits laufen. Er vergleicht
die zugewiesenen Daten- und Logdateigrößen mit dem freien Platz der jeweiligen
SQL-Standardvolumes. Bei einem gemeinsamen Volume wird der Platz einmal
angesetzt. Eigener Backupplatz, Wachstum, Hostkapazität und
Wiederherstellbarkeit müssen separat ermittelt werden. Ohne beide Befunde
bleibt der Vergleich `NOT_OBSERVED`. Der Status des Gesamtplans und seine
Ausführungsgrenzen bleiben `BLOCKED` und `TransferAuthority=NONE`.
Der vorbereitete manuelle Hyper-V-Modus
`evaluation-target-file-allocation-acceptance` verwendet die beiden
eigenen Test-VMs der Zielabnahme. Er startet die bereits gebundene Quelle
nach den Zielprüfungen wieder und legt nur dort eine synthetische
Datenbank an. Er benötigt die Kapazität für zwei laufende Test-VMs.
Im [ersten kombinierten Key18-Lauf](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45705241664)
auf `8c485eed` scheiterte die Windows-Aktivierung bei der Anlage des
Ziellabs. Der Speichervergleich wurde nicht erreicht. Die gespeicherten
Zustände beider eigenen Runs waren danach `REMOVED`. Der erweiterte
Runner gibt bei künftigen Fehlern freigegebene Aktivierungscodes und die
Bereinigung je Run aus. Im [zweiten kombinierten Key18-Lauf](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45719561652)
auf `41a9889d` waren Lizenzen, SQL-Bereitschaft, Zielspeicher und simultaner
Betrieb beider VMs bestätigt. Das Journal der Testdatenbank meldete
`FAILED_UNCONFIRMED`. Der Runner wertete diese Rückgabe nicht aus und
scheiterte bei der anschließenden Größenprüfung. Beide eigenen Runs, VMs
und Disks wurden bereinigt.

Der korrigierte Runner verwendet die SQL-Anmeldung über PowerShell Direct
aus der Einzelgast-Abnahme. Er bindet die Anlage an die eigene Quell-VM,
prüft das Ergebnis und erwartet für Daten und Log genau den gemessenen
Zuwachs gegenüber der Ausgangsgröße. Im [dritten kombinierten Key18-Lauf](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45731436183)
auf `c02adb5f` erreichte der Runner die Ausgangsgrößenprüfung der neu
gestarteten Quelle, aber noch keine Anlage der Testdatenbank. Beide eigenen
VMs liefen gleichzeitig und wurden anschließend samt Disks bereinigt.
Der VM-Laufstatus bestätigt nur den Start der VM. Der Runner prüft deshalb
vor der Ausgangsgrößenmessung die SQL-Identität der gebundenen Quell-VM
schreibgeschützt mit einer begrenzten Wartezeit.

Der [native Key18-Lauf 45742408943](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45742408943)
auf `6979d649` bestand den kombinierten Vergleich. SQL war nach dem
erneuten Start der Quelle erreichbar. Beide eigenen VMs liefen
gleichzeitig. Das Fixture legte ausschließlich auf der Quelle eine
synthetische Datenbank an. Die Quellsummen stiegen exakt um deren Daten-
und Logdateigrößen. Der Vergleich übernahm je Zielvolume die gebundenen
freien Bytes und zählte gemeinsam genutzte Volumes einmal. Vorlage,
fertige Run- und Verbindungsmetadaten blieben unverändert. Beide eigenen
Runs, VMs und Datenträger wurden entfernt.

Die Abnahme belegt den Speichervergleich mit einer SQL-2025-Developer-Vorlage.
Der gesamte Refreshplan bleibt `BLOCKED` mit `TransferAuthority=NONE`.
Backup- und Wachstumskapazität, der Datentransfer, die Gleichwertigkeit und
der Rückfall brauchen eigene Nachweise.

Key18 bestätigte die Windows-Lizenz der separaten Ziel-VM mit zwei eigenen
SQL-2025-Developer-Runs. Die Quelle wurde vor dem Zielstart gestoppt.
Quell- und Zielmetadaten sowie die Vorlage blieben unverändert. Beide
eigenen Runs einschließlich VMs und Disks wurden bereinigt.
[Nativer Nachweis](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45463261705)

Der lesende Plan unterstützt auch gespeicherte Hyper-V-SQL-Manifestläufe,
bei denen der Run-State das Feld `persistentData` auslässt. Voraussetzung
ist ein explizit nichtpersistenter Sollzustand ohne registrierten
Datenträgeranhang. Widersprüchliche Speicherangaben blockieren die Prüfung.

Die getrennte Auswahl **Windows-Lizenz im laufenden Gast lesen**
(`-ObserveWindowsLicense`) prüft die aktuelle Lizenz derselben gebundenen
laufenden Instanz in allen drei Planmodi. Die Ausgabe trennt den Live-Befund
von den gespeicherten Fristen. Sie enthält Lizenzstatus, Beobachtungszeitpunkt
und gegebenenfalls die Evaluation-Frist. Eine abgelaufene Evaluation ist ein
eigener Blocker. Der aktuelle Befund bleibt flüchtig. Die Key18-Abnahme auf
`8d932932` bestätigte die Gastabfrage für einen eigenen laufenden
SQL-2025-Developer-Prepared-Run mit bytegleichem Run-/Connection-State,
unveränderter Vorlage und eigenem Cleanup.
[Nativer Befund](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45381383611)

Die gemeinsame Watch-Fristklassifikation bleibt unverändert. Bei durch JSON
typisierten Zeitwerten bewahren beide Watch-Pfade jetzt UTC und Bruchteile der
Sekunde statt kulturabhängiger Stringkonvertierung. Für zuvor falsch
interpretierten Datumsinhalt kann dadurch ein anderer Ereignisfingerprint
entstehen; wiederholtes Lesen unveränderter kanonischer Werte bleibt stabil.
Das registriert ohne ausdrückliches `RecordEvents` keine Ereignisse.

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
- Für einen Hyper-V-SQL-Gast ist die SQL-Frist erst nach einer frischen,
  versionsgebundenen und an Run/Scope/Instanz/VM/Image gebundenen
  [SQL-Gast-Evidence](SQL_GUEST_EVALUATION_EVIDENCE_BACKLOG.md) verwendbar;
  fehlende, ungültige oder veraltete Evidence blockiert den Refresh-Preflight.
- Standardmäßig mindestens 30 Tage vor dem frühesten relevanten Ablaufdatum
  planen.
- Zielversion, Edition, Provider, Host-Capabilities, Medien, Speicher und
  notwendige Downtime vor der ersten Mutation fest binden.
- TDE, FILESTREAM, SSISDB, SSAS, unbekannte Serverobjekte und externe Dienste
  vorab als Capability oder Blocker klassifizieren.

### Quellinventar und Wiederherstellbarkeit

Der Ersatzentscheid kann nach ausdrücklicher Auswahl eine reguläre
Benutzerdatenbank der gebundenen laufenden SQL-2025-Quelle lesend prüfen.
CLI und Browser übernehmen denselben Datenbanknamen. Der Gast liefert
Kategorien und Zähler für Login-Mappings, Agent-Jobs, Proxies,
Linked Server und Verschlüsselungsabhängigkeiten. Externe Komponenten und
die vollständige Instanzinventur bleiben getrennte Aufgaben.

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
- für SQL-Gäste keine Image- oder Windows-Frist als Ersatz für die gebundene
  SQL-Gast-Evidence verwendet wird;
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
- [Persistierte SQL-Gast-Evaluations-Evidence](SQL_GUEST_EVALUATION_EVIDENCE_BACKLOG.md)
- [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](../Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md)
- [Bekannte Grenzen](../Quality/KNOWN_LIMITATIONS.md)

Dieser Backlog autorisiert noch keine Export-, Import-, Cutover-, Lizenz- oder
Löschmutation. Bis zur implementierten und validierten Ausführung bleiben die
bestehenden Datenbank-Migrationspläne strikt read-only.
