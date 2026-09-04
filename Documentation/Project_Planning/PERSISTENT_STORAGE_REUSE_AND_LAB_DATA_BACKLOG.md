# Persistente SQL-Speicher, Wiederverwendung und `Lab_Data` – Backlog

## Status und Priorität

`ACTIVE / 8_TOP_LEVEL_PACKAGES_REMAIN / PSR_001_002_005_007_008_014_COMPLETE / PSR_003_004_011_PARTIAL / PSR_006_READ_ONLY / PSR_009_010_012_IMPLEMENTED_CORE / PSR_013_PLANNED` – die vorhandenen
Persistenzmechanismen schützen bereits Teile des SQL-Zustands, bilden aber noch
keinen vollständigen, providerübergreifenden Wiederverwendungs- und
Löschvertrag. Planung ist kein Implementierungs- oder Runtime-Nachweis.

Von den 14 kanonischen PSR-Arbeitspaketen sind `PSR-001`, `PSR-002`, `PSR-005`,
`PSR-007`, `PSR-008` und `PSR-014` abgeschlossen. Damit verbleiben acht Top-Level-Pakete; ein Paket
mit implementiertem Core oder read-only Slice zählt bis zum vollständigen
eigenen Abnahmekriterium weiterhin als offen.

Der P0-Bugfix zur verbindlichen Ablage aller neuen Hyper-V-Ressourcen unter
registrierten `Lab_Data`-Roots ist seit 2026-08-31 abgeschlossen. Die
verbleibenden PSR-Arbeitspakete konsumieren dessen geklärte Root-, Ownership-,
Recovery- und Cleanup-Grenzen; sie erhalten dadurch keine zusätzliche
Mutationsautorität.

`PSR-001` ist als read-only Inventur abgeschlossen. Der Cleanup-Audit liefert
den getrennten Vertrag `SqlServerLab.StorageResidencyInventory/1.0` mit stabilen
Objektidentitäten, Provider-Coverage, logischem Eigentum, physischer
Pfadklassifikation, Lebensdauer, Retention, Cleanup-Policy und Auditstatus.
`Lab_Data`, native Docker-/Podman-Runtime-Namensräume, externe Hostpfade,
Hyper-V-Run-/Shared-Ressourcen und Legacy-/Repository-Residuen werden nicht
gleichgesetzt. Ein Providerpfad innerhalb einer Runtime-VM gilt ausdrücklich
nicht als hostseitige `Lab_Data`-Ablage. Unterstützte lokale Docker-Desktop- und
Podman-WSL-Installationen werden zusätzlich über ihre tatsächlichen VHDX- und
Konfigurationsdateien hostseitig aufgelöst. Images, Container, Volumes und Build-
Cache werden als normalisierte Runtime-Klassen erfasst; verwaltete Images
erhalten stabile Objektidentitäten. Nur der Cleanup-Audit enthält die ermittelten
Hostpfade, während der Runtime-Scope ausschließlich den sanitisierten Status und
die Anzahl der Backing-Stores ausgibt. Die reale read-only Abnahme am 2026-09-02
bestätigte Docker und Podman samt unveränderten Runtime-Ressourcen. Sämtliche
globalen Runtime-/Machine-Backings bleiben `SHARED_EXTERNAL`/`REPORT_ONLY`; bei
fehlendem Provider, Remote-Endpunkt oder unbekanntem Layout darf ein einzelner
Audit weiterhin korrekt `PARTIAL` beziehungsweise `UNVERIFIABLE` sein.

`PSR-002` ist durch den bindenden Entscheid
[`SqlServerLab.LabDataResidencyDecision/1.0`](../Architecture/LAB_DATA_AND_NATIVE_RUNTIME_STORAGE_DECISION.md)
abgeschlossen. `Lab_Data` ist der hostseitige Katalog-, Austausch-, Sicherungs-
und Recovery-Einstieg, kein falsches Vollresidenzversprechen für gemeinsam
genutzte Container-Runtimes. Katalogisierte native Instanzstores bleiben
zulässig; globale Docker-/Podman-Ablagen, labfremde Ressourcen und externe
Pfade bleiben ohne eigenen Ownership- und Migrationsvertrag außerhalb des
Mutationsscopes. Neue Hyper-V-Hostdateien bleiben an registrierte `Lab_Data`-
Bindings gebunden.

Der erste mutierende Slice `PSR-003` ist implementiert. Der strenge Vertrag
`SqlServerLab.PersistentStorageCatalog/1.0` führt eine eigenständige
`PersistentStorageId`, die Klassen `INSTANCE_STORE`, `DATABASE_PACKAGE`,
`BACKUP_SET` und `EXCHANGE_WORKSPACE`, den vollständigen Zustandsraum,
Referenzen und genau eine exklusive Lease. Der Parser führt identische,
controllergebundene Katalogspiegel zusammen und blockiert ungültige oder
divergierende Spiegel. `SqlServerLab.PersistentStoragePlan/1.0` bindet diese
Einträge read-only an das Residency-Inventar und meldet retained Objekte ohne
erfundene ID als Registrierungskandidaten. Neue verifizierte Backup-Sets und
Datenbankpakete werden unter einem controllerweiten Lock mit eigenständiger
`PersistentStorageId`, aktiver `ARTIFACT`-Referenz und rollbackfähigen
identischen Spiegeln registriert. Ein gemeinsamer Mutationskern stellt
Preview, Compare-and-Swap über die erwartete Revision, eine unveränderliche
Controller-/Vertragsgrenze, genau einen Revisionsschritt und den rollbackfähigen
Spiegelcommit bereit. Der erste darauf umgestellte Writer registriert
vorhandene `EXCHANGE_WORKSPACE`-Verzeichnisse ausschließlich als verifizierte
relative Bindung in einem registrierten `Lab_Data`-Root. Der öffentliche
Einzelobjekt-Sync übernimmt vorhandene `BackupSetId`-, `DatabasePackageId`- oder
`ExchangeWorkspaceId`-Einträge, plant mit `-WhatIf` ohne Katalogmutation und
bleibt bei Wiederholung idempotent. Alle drei Pfade binden Apply per erwarteter
Revision an genau den zuvor gelesenen Preview-Stand. Backup und Paket werden
dabei vollständig als Artefakt revalidiert; beim Workspace werden Root-Grenze
und Verzeichnis unmittelbar vor dem CAS-Commit erneut geprüft. Der interne
Reconcile-Core gleicht bereits katalogisierte Library-Einträge ohne erneutes
Voll-Hashing ab; das
Residency-Inventar bindet sie an dieselbe Objekt-ID. Ein fehlgeschlagener
Paket-Katalogcommit quarantänisiert Library-Eintrag und Recovery-Journal.
Regulär mit `New-SqlServerLab -PersistentData` erzeugte Docker-/Podman-
Instanzstores erhalten ihre stabile ID vor der Volume-Erzeugung, werden für den
Run exklusiv geleast und beim Cleanup erst nach der Containerentfernung als
`DETACHED` freigegeben. Nach erfolgreicher Provisionierung bindet der Katalog
jede deklarierte und verifizierte Benutzerdatenbank über eine stabile
`DATABASE`-Referenz an denselben Store. Cleanup löst Run- und
Datenbankreferenzen atomar mit der Lease; eine erneute Lease ist bei verbliebenen
aktiven Datenbankreferenzen fail-closed. Fehlende oder abweichend gelabelte
Volumes bleiben mit Lease als `RECOVERY_REQUIRED` sichtbar. Reguläre Hyper-V-
Reservierung, Abschluss und Recovery-Markierung verwenden den gemeinsamen
Mutationskern mit Preview und erwarteter Revision. Der Abschluss nach
DiskIdentifier- und Attachment-Postcondition ist an exakt die Revision der
vorherigen Reservierung gebunden. Hyper-V-Clone und Reattach erwerben vor der
Hostmutation eine operationsgebundene Quell-Lease;
Clone registriert das unabhängige Ziel und gibt die Quelle atomar frei,
Reattach committed `IN_USE`, und Release löst Run-/Datenbankreferenzen mit der
Lease. Teilfehler bleiben katalogisiert `RECOVERY_REQUIRED`, alle drei Commits
sind journalisiert und idempotent. Die Umstellung der übrigen Instanzstore-
Writer, Bestandsmigration weiterer Storage-Klassen,
providerübergreifende Wiederverwendung und Löschung bleiben getrennte
Folgearbeit.

Der Plan- und erste Executor-Slice `PSR-004` ist implementiert. Ein strikter
`SqlServerLab.PersistentStorageRemovalIntent/1.0` bindet die sechs
Retention-/Removal-Policies an Run- und Storage-ID sowie aktive
Datenbankreferenzen. `SqlServerLab.PersistentStorageRemovalPlan/1.0` ordnet
Scope-, Referenz- und Lease-Prüfung vor jede Folge, verlangt für Backups
`CHECKSUM` und `RESTORE VERIFYONLY`, für Pakete Offline-/Detach-Evidence,
vollständiges Dateiinventar, SHA-256 und Postcondition und setzt Fehler ab der
ersten Mutation auf `RECOVERY_REQUIRED`. Fremde Referenzen, Recovery-Zustände
und nicht katalogisierte retained Objekte blockieren. Der öffentliche Executor
führt für Docker-/Podman-Instanzstores `RETAIN_INSTANCE_STORE`,
`BACKUP_ON_REMOVE`, MDF/NDF/LDF-`PACKAGE_ON_REMOVE` und `BACKUP_AND_PACKAGE`
aus. Die Kombinationspolicy verifiziert das Backup vor dem Offline-Commit für
das Paket. Er schreibt vor
der ersten Artefaktmutation ein geheimnisfreies Journal, veröffentlicht Backups
erst nach `CHECKSUM` und `RESTORE VERIFYONLY` und Pakete erst nach exklusivem
Offline-Commit, vollständiger SQL-Dateiinventur und automatischem Objekt- und
Manifest-SHA-256. Er revalidiert den Plan vor Cleanup und setzt einen begonnenen
Cleanup idempotent fort. Der Run wird entfernt, der Store bleibt detached
katalogisiert. `EXTERNAL_UNMANAGED` löst revisionsgeschützt ausschließlich
die eigene Katalogbindung, journalisiert `SourceMutated=false` und verändert
weder externe Quelle noch Inhalt. `DELETE_WITH_RUN` ist nun eng auf einen
öffentlich aus persistierter Run-, Scope-, Container- und Runtime-Label-Evidence
registrierten Docker-/Podman-`INSTANCE_STORE` begrenzt: Der journalisierte
Executor löst zuerst die exklusive Lease in `DELETE_PENDING`, entfernt erst
dann den Run und finalisiert nach frischem Nachweis eines fehlenden Volumes zu
`DETACHED`. FILESTREAM, TDE und jede andere endgültige Persistent-Storage-
Löschung bleiben vor jeder Mutation blockierte, getrennte Folgearbeit. Der
reguläre Run-Cleanup ist davon getrennt:
Er entfernt ein rungebundenes Docker-/Podman-Volume nur, wenn dessen frische
Runtime-Labels RunId und ScopeId exakt mit dem Cleanup-Plan übereinstimmen;
bei fehlender oder abweichender Ownership-Evidence erfolgt kein `volume rm` und
der Run bleibt recoverbar. Neue rungebundene Systemvolume-Gruppen erhalten
zuvor eine UUID, die im Desired State des Runs persistiert und auf alle
zugehörigen Runtime-Volumes gelabelt wird. Dieser Nachweis ist die notwendige
Identitätsbrücke für einen selektierbaren Katalogstore; er registriert weiterhin
keine Altbestände. Der interne Katalogkern
akzeptiert eine folgende Registrierung ausschließlich mit derselben Label-ID,
dem einzigen erwarteten Container und vollständiger Run-/Scope-/SQL-/Persistenz-
Evidence; er erstellt dabei eine exklusive `RUN_SCOPED`/`RUN_CLEANUP`-Lease.
Der öffentliche, `WhatIf`-fähige Einstieg und die zweiphasige
Cleanup-Finalisierung verwenden diese Lease revisionsgebunden. Der Plan weist
unabhängig von seiner
fachlichen Gültigkeit mit `Execution.Status` aus, ob die verlangte Policy
heute ausführbar ist (`EXECUTABLE`), nur vollständig geplant ist
(`PLANNED_NOT_EXECUTABLE`) oder fachlich blockiert bleibt (`BLOCKED`).

Der Core-Slice `PSR-005` ist implementiert und für Docker und Podman getrennt
real belegt. `SqlServerLab.ContainerInstanceStoreIntent/1.0` wählt eine bereits
katalogisierte Quelle ausschließlich über ihre stabile `PersistentStorageId`;
Planner und Runtime-Revalidierung verlangen ein passendes unveränderliches
Volume-Label, dieselbe SQL-Major-Version, `AVAILABLE` oder `DETACHED`, keine
Lease, keine aktive Referenz und keinen angehängten Container. `CONTINUE`
liefert die revalidierte `/var/opt/mssql`-Bindung. `CLONE` erstellt ein neues,
operationsgebundenes Ziel, mountet die Quelle nur read-only, vergleicht
Dateizahl, Bytes und SHA-256-Inhaltsdigest und bleibt bei Fehlern über ein
`RECOVERY_REQUIRED`-Journal fortsetzbar. Die realen Docker- und Podman-Läufe
bestätigen nach Recreate und im Clone jeweils ein Serverobjekt sowie eine
Benutzerdatenbank. Erst nach der Digest-Postcondition wird das Clone-Ziel mit
seiner vorab vergebenen stabilen ID rollbackfähig auf alle controllergebundenen
Katalogspiegel committed. Vor der ersten Kopie reserviert eine exklusive,
operationsgebundene Quell-Lease den Store; nur dieselbe Recovery-Operation darf
sie fortsetzen. Zielregistrierung und Quellfreigabe werden atomar in derselben
Katalogrevision committed. Ein Katalogfehler verhindert `COMPLETED`, behält die
Lease und bleibt über dasselbe Journal fortsetzbar; der Commit ist idempotent.
`New-SqlServerLab` und die Browseroberfläche wählen einen detached Store für
`CONTINUE` oder `CLONE` ausschließlich per stabiler ID, prüfen Provider und
SQL-Major-Version frisch und leasen das gewählte Ziel für den echten neuen Run.
Der Mehr-Volume-Vertrag nimmt optional die beiden External-Runtime-Sidecars
`EXTERNAL_LANGUAGES` und `EXTERNAL_LIBRARIES` mit. Beide tragen dieselbe stabile
Storage-ID, eine eindeutige Rollenmarkierung und die SQL-Major-Version;
Continue revalidiert und bindet alle drei Volumes, Clone kopiert und verifiziert
sie getrennt im selben Recovery-Journal. Die nativen Docker- und Podman-Läufe
vom 2026-09-02 bestätigten beide Sidecar-Marker und den Live-SQL-Zustand.
Unvollständige oder ungelabelte Legacy-Sidecargruppen bleiben fail-closed.

Der read-only Slice `PSR-006` ist implementiert und gegen die reale Docker-
Desktop- sowie Podman-WSL-Runtime belegt. Der sanitisierte Vertrag
`SqlServerLab.ContainerRuntimeScope/1.0` bindet den aktiven Docker-Context oder
die aktive Podman-Connection samt Machine an eine stabile, endpunktgebundene
Runtime-ID, ohne Rohendpunkt, Identity-Pfad oder Runtime-Storage-Pfad
auszugeben. Bestehende Engines und Machines bleiben `SHARED_EXTERNAL`, ihre
Hostdefaults und ihr physisches Backing `REPORT_ONLY`; Relocation, Removal,
Default-Connection-/Modusänderung und Adoption labfremder Ressourcen sind
explizit blockiert. Eine künftig dedizierte Runtime benötigt weiterhin einen
eigenen Ownership-, Location-, Capacity-, Recovery- und Cleanup-Vertrag.

`PSR-008` ist für die aktuelle Provider-Matrix abgeschlossen.
`SqlServerLab.BackupLibrary/1.0` veröffentlicht Backups erst nach SQL-
`CHECKSUM`, `RESTORE VERIFYONLY WITH CHECKSUM`, Host-SHA-256 und sanitiertem
Receipt. Der reale Docker-zu-Podman-Lauf bestätigt Auswahl per stabiler
`BackupSetId`, erneute Verifikation, Restore, identischen Inhaltsdigest und
vollständigen Cleanup. Microsoft führt FileTable und FILESTREAM bei SQL Server
2025 auf Linux ausdrücklich als nicht unterstützt; Docker und Podman bilden
daher kein FILESTREAM-fähiges Quell-/Zielpaar. Der Cross-Provider-
FILESTREAM-Nachweis ist in der aktuellen Capability-Matrix `NOT_APPLICABLE`
statt offen. Der Core verlangt für jedes Backup, das FILESTREAM-Metadaten
trägt, weiterhin echte FILESTREAM-Inhaltsevidence. Kommt ein zweiter
FILESTREAM-fähiger Provider hinzu, wird der native Cross-Provider-Nachweis vor
dessen Freigabe verpflichtend. Quelle:
[Microsoft – Editions and supported features of SQL Server 2025 on Linux](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-editions-and-components-2025?view=sql-server-ver17#unsupported-features-and-services).

Der read-only Core-Slice `PSR-012` ist implementiert. Der öffentliche
Cleanup-Audit projiziert die Residency-Matrix zusätzlich als strikten Vertrag
`SqlServerLab.CleanupFindings/1.0`: bewusst retained und geteilte Objekte,
unerwartete Residuen einschließlich Orphan-Containern und -Volumes,
recoverypflichtige Katalog-/Hyper-V-Zustände sowie unverifizierbare Evidence
stehen in getrennten Listen. Jeder Befund bindet eine stabile Subjektidentität,
Provider, Reason-Code und einen sanitisierten Handlungshinweis; der Audit
erteilt ausdrücklich keine automatische Mutationsautorität.

Der read-only Core-Slice `PSR-010` ist implementiert. Der Vertrag
`SqlServerLab.DatabaseMigrationDependencyInventory/1.0` zählt SQL-seitig
beobachtbare Server-Login-Mappings, datenbankgebundene SQL-Agent-Jobs,
zugehörige Proxies, instanzweite Linked-Server-Kandidaten und TDE-Protectoren.
Serverkonfiguration, SSISDB und SSAS bleiben ausdrücklich
`NOT_OBSERVABLE` und verlangen externes Review. Neue Backup- und
Datenbankpaket-Receipts weisen ihren Scope als `DATABASE_FILES_ONLY` aus und
setzen `FullInstanceMigration`, Serverobjekt-, TDE-Key-, Secret- und externe
Service-Mitnahme ausnahmslos auf `false`. TDE ohne verifizierte Recovery-
Evidence bleibt blockiert. Objekt-, Host-, Credential- und Schlüsselnamen
werden nicht im sanitierten Receipt gespeichert. Persistierte Kategorien und
Warnungen werden über die stabile `DatabasePackageId` ohne erneute SQL-Abfrage
pfad- und geheimnisfrei in CLI und Browser angezeigt. Die öffentliche read-only
Live-Inventur bindet eine direkte Quelle oder eine stabile Run-/Instanz-ID an
denselben Vertrag. Export-/Import-Executor bleiben Folgearbeit.

Der nächste öffentliche Slice `PSR-011` inventarisiert Datenbankpakete in CLI
und Browser über dieselbe stabile `DatabasePackageId`. Die Auswahlansicht ist
geheimnis- und pfadfrei, meldet fehlende Objekte ohne Voll-Hashing und hasht
große Paketobjekte nur auf ausdrückliches `-VerifyIntegrity` oder unmittelbar
vor einer Verwendung. Der Hyper-V-Attach wählt zusätzlich einen laufenden
SQL-Run per stabiler Run-/Instanz-ID; das Framework leitet das Ziel live aus
SQLs Default-Data-Verzeichnis ab, sodass kein freier Host- oder Gastpfad
eingegeben werden kann. Nicht kompatible Ziele und TDE ohne Ziel-Key-Vertrag
bleiben sichtbar fail-closed. Weitere Providerbindungen bleiben gesperrt,
solange ihre jeweilige Zielpfadabbildung nicht sicher gebunden ist.

## Ausgangslage

Die Bezeichnung *persistenter Speicher* fasst derzeit technisch und fachlich
unterschiedliche Dinge zusammen:

- Docker und Podman binden für einen persistenten SQL-Systemzustand ein stabil
  benanntes, von der Runtime verwaltetes Volume auf `/var/opt/mssql` ein. Es
  enthält unter anderem Systemdatenbanken, Datenbankregistrierungen und die dort
  abgelegten Benutzerdatenbanken, liegt physisch aber nicht als direkt
  sichtbarer Verzeichnisbaum unter `Lab_Data`.
- Der Backup-Arbeitsbereich eines Containers ist ein separater Host-Bind-Mount
  unter `Lab_Data`.
- Optionale External-Language- und External-Library-Inhalte liegen in eigenen
  Runtime-Volumes; kurzlebige Sandboxes bleiben containerlokal.
- Ohne ausdrückliche Persistenzpolicy sind die SQL-System- und Zusatzvolumes nur
  rungebunden und werden beim regulären Cleanup entfernt.
- Hyper-V kann eine langlebige `sql-data.vhdx` unter `Lab_Data` anhängen. Bei
  einer frischen SQL-Installation kann sie Benutzer-Data, -Log, TempDB und
  Backups aufnehmen. Bei einem bereits vorbereiteten SQL-Image wird sie aktuell
  nur initialisiert; ohne weiteren Storage-Plan werden bestehende SQL-Pfade
  nicht automatisch dorthin verschoben.
- Die Hyper-V-System-/Child-VHDX trägt weiterhin Windows, Registry,
  SQL-Installation, Systemdatenbanken und Serverobjekte. Sie ist rungebunden
  und wird beim Cleanup entfernt.
- Vorhandene persistente Runtime-Volumes oder Hyper-V-Daten-VHDX können weder
  in CLI noch GUI als eigenständige Speicherressource katalogisiert, ausgewählt,
  geklont, sicher freigegeben oder gezielt gelöscht werden.

Damit erfüllt der aktuelle Containerpfad primär **Instanzpersistenz** für
Restart und Recreate. Er erfüllt noch nicht den Benutzerzweck eines sichtbaren,
zwischen Umgebungen kontrolliert wiederverwendbaren Datenbestands. Der
Hyper-V-Pfad ist ohne Attach-/Restore-Workflow noch stärker eingeschränkt.

## Zielbild

`SQL_Server_Lab` soll einen gemeinsamen, in CLI und GUI bedienbaren
Storage-Lifecycle anbieten, der vier Speicherklassen ausdrücklich trennt:

| Speicherklasse | Zweck | Portabilität |
|---|---|---|
| `INSTANCE_STORE` | Exakt denselben SQL-Instanzzustand nach Stop, Restart oder kompatiblem Recreate fortsetzen | provider- und versionsgebunden |
| `DATABASE_PACKAGE` | Vollständige MDF/NDF/LDF-/FILESTREAM-Dateimenge kontrolliert offline übergeben | Attach an genau eine kompatible Zielinstanz |
| `BACKUP_SET` | Geprüfte SQL-Backups als kanonische Übergabe zwischen Umgebungen und Providern | gleiche oder unterstützte neuere SQL-Version |
| `EXCHANGE_WORKSPACE` | Hostsichtbare Import-, Export-, Skript- und Transferdateien | providerneutral, keine aktiven SQL-Dateien |

Ein persistenter Speicher erhält eine stabile, vom Anzeigenamen unabhängige
`PersistentStorageId`. Er bleibt auch ohne aktiven Run katalogisiert und darf
nicht allein aus Labname, Instanz-ID oder einem erneut berechneten Runtime-Namen
identifiziert werden.

## Gewünschter `Lab_Data`-Einstiegspunkt

Der Benutzer soll einen klaren Verzeichniseinstiegspunkt besitzen, unter dem
jedes System seine fachlich zugeordneten Ressourcen ablegt. Das folgende Layout
ist ein zu prüfender Zielentwurf und noch kein festgelegter physischer Vertrag:

```text
Lab_Data
└── PersistentStores
    └── <PersistentStorageId>
        ├── store.json
        ├── Backups
        ├── DatabasePackages
        │   └── <DatabaseId>
        │       ├── data
        │       ├── log
        │       ├── filestream
        │       └── database.json
        ├── Exchange
        └── ProviderData
            ├── docker
            ├── podman
            └── hyperv
```

Direkte Sichtbarkeit bedeutet nicht, dass aktive Datenbankdateien gleichzeitig
vom Host und vom SQL-Dienst geöffnet oder von mehreren SQL-Instanzen schreibend
verwendet werden dürfen. Wo ein providergeeigneter nativer Datenträger
erforderlich ist, stellt das Produkt sichere Export-, Materialize-, Clone- und
Import-Aktionen bereit, anstatt eine gefährliche Dateifreigabe vorzutäuschen.

## Katalog- und Metadatenvertrag

Jeder Speicher muss mindestens folgende geheimnisfreie Metadaten besitzen:

- stabile Storage-, Datenbank- und Revision-Identitäten;
- Speicherklasse, Providerbackend und physische beziehungsweise logische
  Location-Bindung;
- erzeugende Umgebung, SQL-Version, Edition, Plattform und Build;
- Datenbanken, logische Dateinamen, Dateitypen, relative Pfade, Größen und
  SHA-256-Werte;
- vollständige FILESTREAM-Container und deren Zuordnung;
- Backup-Typ, LSN-/Zeitbezug, `CHECKSUM`-/Verifikationsstatus und Restore-
  Evidence;
- Verschlüsselungsstatus und benötigte, **nicht im Katalog gespeicherte**
  TDE-/Zertifikats- oder Credential-Abhängigkeiten;
- letzte saubere SQL-Offlining-/Detach-, Backup- oder Shutdown-Evidence;
- Zustand `AVAILABLE`, `IN_USE`, `DETACHED`, `INCOMPLETE`, `RECOVERY_REQUIRED`
  oder `DELETE_PENDING`;
- exklusive Lease beziehungsweise aktuell gebundene Umgebung;
- Retention-, Cleanup-, Clone- und Löschpolicy.

Der Katalog darf weder Passwörter noch private Schlüssel, konkrete
Credential-Werte oder ungeschützte TDE-Key-Backups enthalten.

## Datenbank-, FILESTREAM- und Backup-Lifecycle

### Kanonischer Portabilitätspfad

Ein vollständiges SQL-Backup ist der Standard für den Wechsel zwischen
Umgebungen und Providern. FILESTREAM-Daten müssen im vollständigen Backup
enthalten und beim Restore tatsächlich verifiziert werden. Ein Backup wird erst
als wiederverwendbar veröffentlicht, wenn mindestens SQL `CHECKSUM`,
`RESTORE VERIFYONLY`, Hash und Metadatenreceipt erfolgreich vorliegen. Für
höhere Schutzklassen ist ein realer testweiser Restore der stärkere Nachweis.

### Kontrollierter Attach-Pfad

Ein `DATABASE_PACKAGE` ist ein ausdrücklicher Expertenpfad. Vor der
Veröffentlichung muss das Produkt:

1. die Datenbankzugriffe sperren und einen sauberen Offline-/Detach-Zustand
   nachweisen;
2. alle MDF-, NDF- und LDF-Dateien sowie den vollständigen FILESTREAM-
   Container inventarisieren;
3. die zusammengehörige Dateimenge atomar kopieren oder snapshotten und hashen;
4. SQL-Major-Version, Datenbankstatus, Verschlüsselung und externe
   Serverabhängigkeiten aufzeichnen;
5. die Quelle erst freigeben, wenn keine Instanz sie mehr schreibend verwendet.

Beim Import werden Abwärtskompatibilität, Vollständigkeit, Hashes,
FILESTREAM-Capability, TDE-Schlüssel und exklusive Nutzung fail-closed geprüft.
Dieselben physischen Dateien dürfen nie gleichzeitig an zwei schreibende
SQL-Instanzen gebunden werden. Eine zweite Umgebung erhält einen Clone oder
einen Restore, keine gemeinsame Read/Write-Bindung.

### Nicht datenbankgebundener Instanzzustand

Benutzerdatenbanken enthalten nicht alle Serverobjekte. Für einen vollständigen
Umzug müssen mindestens Logins und SIDs, SQL-Agent-Jobs, Credentials, Linked
Servers, Serverkonfiguration, Zertifikate und gegebenenfalls SSISDB-/SSAS-
Abhängigkeiten separat klassifiziert, exportiert oder bewusst ausgeschlossen
werden. Ein reines Attach darf nicht als vollständige Instanzwiederherstellung
ausgegeben werden.

## Retention und Entfernen einer Umgebung

Vor dem Entfernen zeigt CLI und GUI für jede Datenressource die tatsächliche
Folge an. Mindestens folgende Policies sind zu planen:

- `DELETE_WITH_RUN`: rungebundene Ressource wird nach Scope-Prüfung entfernt;
- `RETAIN_INSTANCE_STORE`: Instanzspeicher bleibt katalogisiert erhalten;
- `BACKUP_ON_REMOVE`: alle ausgewählten Benutzerdatenbanken werden vor dem
  Cleanup gesichert und geprüft;
- `PACKAGE_ON_REMOVE`: Datenbanken werden sauber offline als Paket
  materialisiert;
- `BACKUP_AND_PACKAGE`: beide unabhängigen Wiederherstellungswege werden
  erzeugt;
- `EXTERNAL_UNMANAGED`: Produkt entfernt weder Quelle noch Inhalt und löst nur
  seine eigene Bindung.

Scheitert eine verlangte Sicherung, ein Hash, ein Detach oder eine
Postcondition, darf der Datenträger nicht still freigegeben oder gelöscht
werden. Der Run endet mit einem sichtbaren Recovery-Pfad. Ein späteres
erzwungenes Entfernen ist eine getrennte Expertenaktion mit genauer
Auswirkungsanzeige.

Persistente Speicher werden niemals als Nebeneffekt von `Remove-SqlServerLab`
gelöscht. Ihre endgültige Löschung ist eine eigene Aktion mit Storage-ID,
Inhaltsinventar, Referenzprüfung, Preview und Bestätigung.

## Providervertrag

### Docker

- `/var/opt/mssql` darf weiterhin in einem nativen Named Volume liegen, wenn
  Windows-/Linux-Dateisystemsemantik, SQL-Version oder Performance gegen einen
  direkten Host-Bind-Mount sprechen.
- Das Produkt muss Volume-Name, Runtime, Engine-/Context-Identität,
  Mountpoints, Datenumfang und Retention katalogisieren.
- Ein direkter Host-Mount aktiver SQL-Dateien ist nur nach eigener Capability-
  und Performanceprüfung sowie ausdrücklichem Experten-Opt-in zulässig.
- Eine etwaige Verlagerung des Docker-Desktop-Datenträgers darf nicht still
  alle labfremden Images, Volumes und Container betreffen.

### Podman

- Podman-Volumes und Images können innerhalb einer Podman Machine liegen und
  sind nicht allein durch einen Windows-Hostpfad unter `Lab_Data` beschrieben.
- Zu analysieren ist ein eigener, von SQL Server Lab verwalteter Machine-
  Vertrag mit expliziter Disk-Location, Kapazität, Rootless-/Rootful-Modus,
  Start, Stop, Update, Recovery und Entfernung.
- CLI und GUI müssen Anlegen, Auswählen und Verwalten einer solchen Machine
  unterstützen, falls sie Teil des Produktvertrags wird.
- Eine bestehende allgemeine Podman Machine und ihre labfremden Container
  dürfen weder umgebogen noch beim Lab-Cleanup entfernt werden.

### Hyper-V

- Eine vorhandene persistente Daten-VHDX muss per Storage-ID ausgewählt,
  revalidiert und an eine ausgeschaltete Ziel-VM angehängt werden können.
- Vor Read/Write-Attach sind DiskIdentifier, Hostpfadbindung, vorhandene
  Attachments, Checkpoints, Dirty-/Detach-Zustand, SQL-Version und freier
  Gastpfad zu prüfen.
- Der Vertrag unterscheidet die Fortsetzung der vollständigen ursprünglichen
  VM von Recovery beziehungsweise Migration einer bloßen Daten-VHDX.
- Systemdatenbanken und Serverobjekte auf der gelöschten Child-VHDX werden nicht
  als durch die Daten-VHDX erhalten ausgegeben.
- Normale Zusatz-VHDX für Data, Log, TempDB und Backup benötigen dieselbe
  sichtbare Retention- und Exportklassifikation; ihre bisherige Runbindung darf
  keine Datenbankdateien unbemerkt vernichten.

## Erforderliche `Lab_Data`-Bestandsanalyse

Vor einer Festlegung, dass *alle Daten unter `Lab_Data` liegen*, ist pro
Provider und Hostmodus eine physische Inventur erforderlich. Sie erfasst
mindestens:

- Run-State, Journale, Secrets, Logs, Exporte, Caches und temporäre Dateien;
- Docker- und Podman-Container, Images, Named Volumes, Netzwerke, Build-Cache
  und deren tatsächliche Backing-Disks;
- Podman Machines samt Machine-Disk, Konfiguration und Connections;
- Docker-Desktop-/WSL-/VM-Datenträger und die Reichweite einer möglichen
  Verlagerung;
- Hyper-V-VM-Konfiguration, OS-/Child-/Zusatz-/Daten-VHDX, Images, Builder,
  Staging, Checkpoints, Smart Paging und Saved State;
- Daten, die nach erfolgreichem Remove, Clear, fehlgeschlagenem Provisioning,
  Prozessabbruch und Hostneustart tatsächlich verbleiben;
- fremde beziehungsweise labfremde Ressourcen, die nie in den Ownership- oder
  Cleanup-Scope geraten dürfen.

Für jede Objektklasse sind logischer Eigentümer, physischer Pfad, Lebensdauer,
Größe, Referenzen, Cleanup-Schritt, Recovery-Möglichkeit und Auditstatus zu
dokumentieren. Ein Runtime-Volume darf nicht allein deshalb als unter
`Lab_Data` liegend gelten, weil sein Name im Run-State gespeichert ist.

Die Analyse muss folgende Produktentscheidung vorbereiten:

1. Bedeutet `Lab_Data`, dass wirklich jedes physische Byte dort liegt, oder ist
   es der verwaltete Katalog- und Austauschroot mit ausdrücklich ausgewiesenen
   nativen Runtime-Ausnahmen?
2. Kann eine dedizierte Docker-/Podman-Engine beziehungsweise Machine
   Labressourcen isolieren, ohne labfremde Objekte oder Hostdefaults zu
   verändern?
3. Welche Daten müssen direkt hostsichtbar sein und welche werden nur über
   sichere Materialize-/Exportaktionen sichtbar?
4. Wie werden bestehende Daten mit Kapazitätsprüfung, Journal, Rollback und
   Wiederaufnahme migriert?
5. Welche Residuen meldet der Cleanup-Audit, welche kann er sicher entfernen
   und welche benötigen eine eigene Benutzerentscheidung?

## CLI- und GUI-Vertrag

CLI und GUI sind Ansichten auf denselben Planner-, Katalog-, Lease-, Journal-
und Providerkern. Beide müssen mindestens anbieten:

- persistente Speicher auflisten, filtern und mit Inhalt, Größe, Provider,
  SQL-Version, Bindung und Zustand anzeigen;
- neuen Speicher erstellen oder vorhandenen Speicher auswählen;
- **Fortsetzen**, **Restore**, **Attach**, **Klonen**, **Exportieren** und
  **Freigeben** als unterschiedliche Aktionen darstellen;
- Backup-/Package-on-Remove-Policy bereits bei der Erstellung sowie vor dem
  Entfernen prüfen;
- einen read-only Plan mit physischen und logischen Zielpfaden, Downtime,
  Kapazität, Versionswechsel und Datenverlustrisiko anzeigen;
- Podman Machine beziehungsweise Docker-Kontext nur im zuvor definierten
  Ownership-Scope anlegen oder auswählen;
- unvollständige Operationen fortsetzen, zurückrollen oder als
  `RECOVERY_REQUIRED` untersuchen;
- persistente Speicher ausschließlich über eine getrennte, referenzgeprüfte
  Löschaktion entfernen.

Ein Manifest benötigt langfristig eine stabile Storage-Referenz und eine
Retention-Policy; ein frei eingebbarer Hostpfad oder ein abgeleiteter
Volumename ersetzt diese Identität nicht.

## Arbeitspakete

| ID | Priorität | Arbeitspaket | Ergebnis |
|---|---:|---|---|
| `PSR-001` | P0-Analyse | Ist-Inventar aller persistenten, rungebundenen und verbleibenden Objekte für Docker, Podman und Hyper-V | `COMPLETE`: versionierte read-only Matrix mit stabilen Objekt-IDs, Residency, Lifecycle, Cleanup-Policy und Provider-Coverage; lokales Docker-Desktop-/Podman-WSL-Backing samt Konfiguration sowie normalisierte Image-, Container-, Volume- und Build-Cache-Nutzung real belegt |
| `PSR-002` | P0-Analyse | `Lab_Data`-Versprechen, native Runtime-Ausnahmen und Hosteingriffsgrenzen entscheiden | `COMPLETE`: bindender `SqlServerLab.LabDataResidencyDecision/1.0`-Entscheid |
| `PSR-003` | P1 | Storage-Katalog mit stabiler ID, Klassen, Zuständen, Referenzen und Leases entwerfen | `IMPLEMENTED_PARTIAL`: Schema, Parser, Planner, Inventarbindung, generischer CAS-/Preview-Mutationskern mit genau einem rollbackfähigen Revisionscommit, darauf vereinheitlichte `BACKUP_SET`-/`DATABASE_PACKAGE`-Writer, Clone-`INSTANCE_STORE`-Registrierung, exklusive Lease/Freigabe regulärer `-PersistentData`-Containerstores einschließlich stabiler Datenbankreferenzen sowie revisionsgeschützte Preview-/Apply-Writer für Reservierung, Abschluss und Recovery regulärer Hyper-V-Instanzstores auf allen controllergebundenen Spiegeln; vorhandene Backup-Sets, Datenbankpakete und sichere `EXCHANGE_WORKSPACE`-Verzeichnisse lassen sich öffentlich einzeln, revisionsgeschützt, previewfähig und idempotent synchronisieren; Umstellung der übrigen Instanzstore-Writer, breite Bestandsmigration, providerübergreifende Wiederverwendung und Löschung bleiben offen |
| `PSR-004` | P1 | Retention-, Backup-on-Remove-, Package- und expliziten Löschvertrag entwerfen | `IMPLEMENTED_PARTIAL`: verlustsicherer Plan mit explizitem `Execution.Status` plus journalisierter Docker-/Podman-Executor für Retain, verifiziertes Backup-on-Remove, MDF/NDF/LDF-`PACKAGE_ON_REMOVE` und `BACKUP_AND_PACKAGE` mit Backup-vor-Offline-Reihenfolge sowie `EXTERNAL_UNMANAGED` als revisionsgeschützte, quellunverändernde Katalogfreigabe; FILESTREAM, TDE und getrennte endgültige Storage-Löschung bleiben fail-closed offen |
| `PSR-005` | P1 | Docker-/Podman-Instanzstore auswählbar, fortsetzbar und klonbar machen | `IMPLEMENTED`: öffentliche CLI-/Browser-Auswahl per stabiler ID, detached Continue/Clone, operationsgebundene Quell-Lease, Digest/Resume, atomarer Zielcommit plus Quellfreigabe und rollenfester External-Runtime-Mehr-Volume-Vertrag; Docker und Podman getrennt real belegt, unvollständige Legacy-Sidecargruppen fail-closed |
| `PSR-006` | P1 | Podman-Machine- und Docker-Engine-/Context-Reichweite bewerten und gegebenenfalls dediziert verwalten | `IMPLEMENTED_READ_ONLY`: stabile sanitisierte Runtime-ID, Context-/Connection-/Machine-Bindung und REPORT_ONLY-Hostgrenze real belegt; dedizierter Ownership-/Lifecycle-Vertrag bleibt offen |
| `PSR-007` | P1 | Hyper-V-Daten-VHDX sicher auswählen, reattachen, freigeben und klonen | `COMPLETE`: reguläre Erzeugung reserviert Storage-ID und Run-Lease vor der VHDX-Mutation; der öffentliche pfadfreie CLI-/Browser-Flow prüft alle SQL-Dateibindungen im Gast, blockiert aktive Datenbankdateien, fährt sauber herunter und persistiert einen an Storage-ID, DiskIdentifier, Dateigröße und Änderungszeit gebundenen Detach-Receipt; Reattach/Release/Clone revalidieren VM, Checkpoints, Gastpfad und SQL-Version, sind operationsgeleast, journalisiert, atomar katalogisiert, idempotent und nativ belegt; vorhandene Datenbankdateien bleiben bis zur expliziten Restore-/Attach-Aktion offline |
| `PSR-008` | P1 | Providerneutrale Backup-Bibliothek mit automatischem Backup und Restore-Verifikation liefern | `COMPLETE`: inhaltsadressierte `Lab_Data`-Bibliothek, `CHECKSUM`, `RESTORE VERIFYONLY`, Hash, Metadatenreceipt, öffentliche BackupSetId-Auswahl und realer Docker→Podman-Inhaltsnachweis; Cross-Provider-FILESTREAM ist in der aktuellen Matrix mangels zweitem FILESTREAM-fähigem Provider `NOT_APPLICABLE`, bleibt bei künftiger Capability-Erweiterung aber zwingendes Freigabegate |
| `PSR-009` | P2 | Datenbankpakete inklusive FILESTREAM, Attach und Clone implementieren | `IMPLEMENTED_CORE`: vollständiger Offline-Dateivertrag, rekursive Hashes, unabhängiger Clone und journalisiertes Copy-then-Attach; öffentlicher pfadfreier Hyper-V-Attach per stabiler Paket-/Run-ID und live gebundenem SQL-Default-Data-Ziel ist implementiert und nativ belegt, öffentliche Paketpublikation und weitere Providerbindungen bleiben offen |
| `PSR-010` | P2 | Serverobjekt- und TDE-Abhängigkeiten inventarisieren und Migrationsgrenzen anzeigen | `IMPLEMENTED_CORE`: öffentliche read-only Live-Inventur per direktem Ziel oder stabiler Run-/Instanzbindung, TDE-Recovery-Gate, externe Review-Grenzen und sanitisierte `DATABASE_FILES_ONLY`-Receipts; persistierte Kategorien und Warnungen sind paketgebunden in CLI/Browser sichtbar, Export/Import bleibt offen |
| `PSR-011` | P1 | identische CLI- und GUI-Flows für Auswahl, Retention, Restore, Attach, Clone und Delete liefern | `IMPLEMENTED_PARTIAL`: Backup-Inventur/Restore, Container-Continue/Clone, Retention-Vorschau, Retain/Backup-on-Remove sowie pfadfreie Datenbankpaket- und Hyper-V-Daten-VHDX-Auswahl verwenden in CLI und Browser dieselben stabilen IDs und Fachkerne; Hyper-V-Release/Reattach/Clone und Datenbankpaket-Attach laufen über dieselben öffentlichen ID-/Run-gebundenen Actions; weitere Paketprovider und endgültiges Delete bleiben offen |
| `PSR-012` | P1 | Cleanup-Audit um persistente Stores, Runtime-Backing, Orphans und Referenzschutz erweitern | `IMPLEMENTED_CORE`: strikte getrennte Findings für Retention, unerwartete Residuen, Recovery und unverifizierbare Evidence; automatische Mutation bleibt ausgeschlossen |
| `PSR-013` | P2 | journalisierte Migration vorhandener Volumes/VHDX und Metadaten bereitstellen | Resume, Rollback, Hash- und Kapazitätsnachweis |
| `PSR-014` | P1 (hoch) | Interaktiven Ersteinrichtungsassistenten für `Lab_Base` und mehrere `Lab_Data`-Locations bereitstellen | `COMPLETE`: `Invoke-SqlServerLab -Action Setup` und das Storage-Menü verwenden denselben read-only Plan und Apply-Core, fragen nur fehlende oder ungültige Werte über den gemeinsamen abbrechbaren Eingabeadapter ab, leiten `Lab_Base` und je Parent `Lab_Data` ab, registrieren mehrere unterschiedliche Volumes und verlangen die ausdrückliche globale Default-Auswahl; gültige Konfigurationen sind No-op, vorhandene Dateien bleiben unverändert und fremde nichtleere Datenroots werden vor jeder Mutation fail-closed abgelehnt |

`P0-Analyse` bedeutet hier, dass die Entscheidung vor jeder breiten
Implementierung benötigt wird. Sie ersetzt oder relativiert nicht den bereits
priorisierten P0-Hyper-V-Ressourcenroot-Bugfix.

## Abnahmekriterien

- Ein Benutzer kann einen vorhandenen Speicher in CLI und GUI anhand seiner
  stabilen ID auswählen; ein Anzeigename oder neu berechneter Volumename reicht
  nicht als Identität.
- Docker und Podman setzen denselben freigegebenen Instanzstore nach einem
  kontrollierten Container-Recreate fort und bestätigen System- sowie
  Benutzerdatenbanken live.
- Eine Hyper-V-Daten-VHDX kann nach sauberem Detach an eine neue kompatible VM
  gebunden werden; Datenbanken werden anschließend ausdrücklich restored oder
  attached und nicht nur wegen vorhandener Dateien als online gemeldet.

Stand 2026-09-02: `SqlServerLab.HyperVPersistentDataIntent/1.0`, Plan und
Recovery-Journal wählen die Quelle ausschließlich per stabiler Storage-ID aus
dem Katalog. Vor jeder Mutation werden registriertes `Lab_Data`, VHDX-Pfad und
DiskIdentifier, exklusiver Attachmentzustand, Checkpoints, ausgeschaltete und
scopegebundene Ziel-VM, Clean-Detach-Evidenz, SQL-Major-Version, freier
Gastpfad sowie Lease und Referenzen fail-closed geprüft. Der Clone verwendet
eine unveränderte Quelle, erzeugt eine eigenständige VHDX und setzt deren
DiskIdentifier explizit neu. Clone und Reattach leasen die Quelle vor der
Hostmutation operationsgebunden; Clone-Zielregistrierung und Quellfreigabe,
Reattach-Commit sowie Release werden erst nach ihrer jeweiligen physischen
Postcondition atomar katalogisiert. Katalogfehler verhindern `COMPLETED` und
bleiben mit demselben Journal fortsetzbar. Ein realer isolierter Hyper-V-Lauf
hat `RELEASE -> CLONE -> REATTACH -> RELEASE` gegen den tatsächlichen
controllergebundenen Katalog samt Cleanup bestätigt. Das Ergebnis bleibt
`DatabaseFilesOnline=false` und verlangt anschließend ausdrücklich Restore
oder Attach; diese Datenbankaktion und CLI-/GUI-Flows gehören weiterhin zu
`PSR-009` beziehungsweise `PSR-011`.

Stand 2026-09-02: `Get-SqlServerLabWorkflow`,
`Invoke-SqlServerLabWorkflowAction` und die Browser-Oberfläche
inventarisieren dieselben katalogisierten Hyper-V-Daten-VHDX pfadfrei anhand
der stabilen `PersistentStorageId`. Katalogzustand, physisches Attachment,
VHDX-Identität und Checkpointreferenzen werden bei verfügbarem erhöhtem
Hyper-V-Host read-only frisch abgeglichen. Release fragt Gast- und bei Bedarf
abweichendes SA-Passwort nur flüchtig ab, prüft jede registrierte SQL-Instanz
gegen `sys.master_files`, blockiert aktive Dateien unter der Daten-VHDX und
fordert unmittelbar danach den sauberen Gast-Shutdown an. Der versionierte
Detach-Receipt bleibt nur gültig, solange Storage-ID, DiskIdentifier,
Dateigröße und Änderungszeit der VHDX unverändert sind. Reattach und Clone
erzeugen ihre Ziel-Evidenz aus der frisch scopegebundenen ausgeschalteten VM;
der eigenständige Clone schreibt seinen Receipt vor dem Katalogcommit. CLI und
Browser rufen denselben Planner/Executor auf und melden Datenbankdateien nie
allein wegen ihrer Existenz als online.

Stand 2026-09-02: Der reguläre `-PersistentData`-Erstellungsflow reserviert die
Hyper-V-Daten-VHDX vor `New-VHD` controllerweit als `INCOMPLETE` mit stabiler
`PersistentStorageId`, portabler `Lab_Data`-Bindung, aktiver Run-Referenz und
exklusiver Lease. Erst die verifizierte DiskIdentifier- und VM-Attachment-
Postcondition committed `IN_USE`; ein Teilfehler bleibt `RECOVERY_REQUIRED`
und verwendet beim Resume dieselbe Identität. VM-Notes, Connection-State,
Katalog und Residency-Audit tragen dieselbe Bindung. Die getrennten Reattach-,
Release- und Clone-Aktionen verwenden inzwischen denselben gespiegelten
Katalog-, Lease- und Recovery-Vertrag.
- Sobald Quelle und Ziel FILESTREAM als Capability unterstützen, wird ein
  vollständiges Backup einer FILESTREAM-Datenbank aus einem Provider
  exportiert, in dem zweiten Provider restauriert und inhaltlich verifiziert.
  In der aktuellen Matrix ist dieses Kriterium `NOT_APPLICABLE`, weil SQL
  Server auf Linux und damit die Docker-/Podman-Provider FILESTREAM nicht
  unterstützen; Hyper-V/Windows ist der einzige fähige Provider.

Stand 2026-09-01: `SqlServerLab.BackupLibrary/1.0` veröffentlicht ein Backup
erst nach `BACKUP ... CHECKSUM`, `RESTORE VERIFYONLY ... WITH CHECKSUM`,
Host-SHA-256 und sanitiertem SQL-Metadatenreceipt als `REUSABLE`. Ein realer,
isolierter Lauf hat Docker → Podman einschließlich Quell-Cleanup, erneutem
`VERIFYONLY`, Restore und identischem Inhaltsdigest bestätigt. TDE endet ohne
eigenen Zertifikat-/Recovery-Vertrag fail-closed. FILESTREAM wird im Receipt
erkannt und eine Restore-Evidence ohne ausdrücklich bestätigten FILESTREAM-
Inhaltsnachweis abgelehnt. Da Microsoft FILESTREAM unter SQL Server auf Linux
nicht unterstützt, existiert für Docker/Podman kein zulässiger positiver
FILESTREAM-Testfall. Der Cross-Provider-Pfad ist deshalb capability-basiert
`NOT_APPLICABLE`; er wird weder als ausgeführt noch als bestanden behauptet.
- Ein Datenbankpaket enthält nachweislich alle MDF/NDF/LDF- und FILESTREAM-
  Bestandteile; fehlende oder veränderte Inhalte sowie paralleles Read/Write-
  Attach werden blockiert.
- Neuer-zu-älter-SQL-Attach, fehlende FILESTREAM-Capability, fehlendes TDE-
  Zertifikat und inkonsistenter Detach-Zustand enden fail-closed mit
  verständlicher Recovery-Angabe.

Stand 2026-09-01: `SqlServerLab.DatabasePackageLibrary/1.0` veröffentlicht nur
eine nach dem exklusiven Lock erneut als sauber offline oder detached
beobachtete Dateimenge. MDF, NDF, LDF und verschachtelte FILESTREAM-Inhalte
werden vollständig kopiert und einzeln gehasht; ein kanonischer Manifesthash
bindet die Gesamtmenge. Clone und Attach materialisieren eine unabhängige
physische Kopie, das direkte Read/Write-Attach eines Bibliotheksobjekts ist
verboten. Der Attach-Plan blockiert ältere SQL-Ziele, fehlende FILESTREAM- oder
TDE-Evidence, vorhandene Zieldatenbanken und parallele Writer. Kopie, Attach,
Online-Postcondition und Recovery werden journalisiert. Die deterministische
Core-Suite ist grün. Erfolgreiche Publikation bindet das Paket atomar über eine
getrennte `PersistentStorageId` an alle controllergebundenen Katalogspiegel;
Katalogfehler setzen Bibliothek und Journal auf Quarantäne/Recovery. Das
Residency-Inventar verwendet dieselbe stabile Objekt-ID ohne erneutes
Inhalts-Hashing. Der öffentliche Hyper-V-Attach nimmt keinen freien Zielpfad
an, sondern bindet eine stabile Run-/Instanz-ID live an SQLs Default-Data-
Verzeichnis. Er revalidiert das vollständige Paket, kopiert es unabhängig über
PowerShell Direct, prüft jeden Hash im Gast und persistiert den Recovery-Zustand
vor der SQL-Mutation. `Invoke-HyperVDatabasePackageAttachAcceptance.ps1` hat
den echten Transport, Gast-Hashes, Attach, Inhalt, Journal und Cleanup am
2026-09-02 gegen einen laufenden scopegebundenen SQL-2025-Run grün belegt; der
native Windows-SQL-/FILESTREAM-Inhaltsnachweis bleibt davon getrennt.
- Serverobjekte, TDE-Keymaterial, Credentials und externe Services werden bei
  Backup oder Datenbankpaket nicht als implizit mitgenommen ausgegeben.

Stand 2026-09-02: `SqlServerLab.DatabaseMigrationDependencyInventory/1.0`
liefert ausschließlich sanitisierte Kategorien und Counts. SQL-seitig
beobachtbare Login-Mappings, Agent-Jobs, Proxies, Linked-Server-Kandidaten und
TDE-Protectoren werden getrennt ausgewiesen; Serverkonfiguration, SSISDB und
SSAS bleiben `NOT_OBSERVABLE`. Backup- und Package-Receipts zeigen
`DATABASE_FILES_ONLY` sowie `FullInstanceMigration=false`. Ohne verifizierte
TDE-Recovery-Evidence bleibt portable Migration `BLOCKED`. Die öffentliche
Live-Inventur verwendet direkte Ziele oder stabile Run-/Instanzbindungen. Ein
Export- oder Recreate-Executor, Keymaterialtransfer und schreibende GUI-Flows
sind nicht Teil dieses Slices.
- `BACKUP_ON_REMOVE` entfernt die Umgebung erst nach erfolgreicher
  Sicherungs- und Verifikationsevidence oder endet ohne Datenlöschung in
  `RECOVERY_REQUIRED`.
- Normales Cleanup entfernt rungebundene Volumes und VHDX, behält freigegebene
  persistente Stores und Testdatenbibliotheken und verändert keine labfremden
  Container, Volumes, Images, Machines oder Hostdefaults.
- Der Cleanup-Audit zeigt nach Erfolg alle bewusst retained Objekte mit Grund
  sowie unerwartete Residuen getrennt an.

Stand 2026-09-01: `SqlServerLab.CleanupFindings/1.0` trennt retained und
geteilte Ressourcen von Orphan-Containern/-Volumes, externen oder ungetrackten
Residuen, recoverypflichtigen Persistent-Storage-/Hyper-V-Zuständen und
unverifizierbarer Provider-Evidence. Stabile Subjektidentität, Provider,
Reason-Code und Handlungshinweis sind schemafest; jeder Befund setzt
`AutomaticMutationAllowed=false`.
- Die reale Storage-Matrix weist für jede Provider-/Hostkombination aus, welche
  Daten physisch unter `Lab_Data`, in einer Runtime-/Machine-Disk oder an einem
  externen Ort liegen. Keine indirekte Referenz wird als physische Ablage
  ausgegeben.
- Docker-, Podman- und Hyper-V-Nachweise bleiben getrennt; ein erfolgreicher
  Providerlauf beweist keine Parität der anderen Provider.

## Nicht Ziel des ersten Vertical Slice

- gleichzeitiger schreibender Zugriff mehrerer SQL-Instanzen auf dieselben
  MDF/LDF-/FILESTREAM-Dateien;
- unkontrolliertes Kopieren aktiver Datenbankdateien;
- allgemeine Verwaltung aller Docker-, Podman- oder Hyper-V-Ressourcen des
  Hosts;
- stilles Verschieben der globalen Docker-Desktop- oder Podman-Standardablage;
- produktiver SAN-, NAS-, SMB-, Cluster-Shared-Volume- oder Cloud-Storage;
- automatische TDE-Schlüsselablage ohne eigenen Secret- und Recovery-Vertrag;
- Behauptung vollständiger Instanzportabilität allein aufgrund vorhandener
  Benutzerdatenbankdateien.

## Verwandte Verträge und Backlogs

- [Storage Contract](STORAGE_CONTRACT_PLAN.md);
- [P0-Hyper-V-`Lab_Data`-Ressourcenroot-Bugfix](HYPERV_LAB_DATA_RESOURCE_ROOT_BUGFIX_BACKLOG.md);
- [Persistente Daten und Evaluation-Refresh](../HowTo/PERSISTENT_DATA_AND_EVALUATION_REFRESH.md);
- [Konsolen-, Lifecycle- und Storage-Konsolidierung](CONSOLE_LIFECYCLE_AND_STORAGE_CONSOLIDATION_PLAN_2026-08-12.md);
- [Providerneutraler Batch-, Queue- und Resume-Workflow](PROVIDER_NEUTRAL_BATCH_QUEUE_RESUME_WORKFLOW_2026-08-13.md);
- [SQL-, SSIS- und SSAS-Cluster](SQL_SSIS_SSAS_CLUSTER_BACKLOG.md).
