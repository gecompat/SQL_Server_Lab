# Eigener CI-Scope auf einem gemeinsam genutzten Windows-Host

## Auswahl und Vertrauensgrenze

Die Container-CI legt über `Tests/Common/OwnedHostTestScope.ps1` einen frischen,
expliziten StateRoot unter `RUNNER_TEMP` an. Der interne Initializer schreibt
`owned-host-required` und die typisierte `owned-host-policy.json`. Root und
Policydatei erhalten den aktuellen Token-SID als Owner sowie geschützte ACLs
mit ausschließlich dessen FullControl. Ein vorhandener Root wird nicht
übernommen. Ein verlorener oder veränderter Policyrecord führt nicht zum
Standardpfad zurück. Ohne Profil bleiben die bisherigen Standardverträge
wirksam. Ein Pfad oder eine Umgebungsvariable allein erteilt keine Autorität.

`PolicyId` und `RootScopeId` bezeichnen den Root. `ParentOperationId` beschreibt
die Initialisierung; sie ist weder Präfix noch Gleichheitsbedingung für
Workflowoperationen. Jeder tatsächliche `New-LabRunState` persistiert seine
RunId, ScopeId, WorkflowOperationId und den Policyhash. Batchgeschwister sowie
SQL-Upgrade-Quell-/Zielruns behalten ihre unterschiedlichen Operationen. Fehlt
der Workflowcontext, allokiert der bestehende GUID-Generator eine eigene
Operation. Das Schema beschreibt Policy und Runreferenz; Laufzeitprüfungen
prüfen zusätzlich Dateirechte, Pfade, Hashes und tatsächliche Ressourcen.

## Explizite Providerroute

Docker verwendet ausschließlich den gespeicherten lokalen Named-Pipe-Host mit
`--host`. Podman verwendet `--remote --url --identity` für die ausgewählte
bereits erreichbare lokale Maschinenverbindung mit Loopback-SSH und
hashgebundener Identitydatei. Weder Context noch Defaultconnection werden bei
späteren Aufrufen erneut gewählt. Routingvariablen werden nur für den
Kindprozess entfernt. Alle Beobachtungen, Effekte und Kompensationen verwenden
denselben Pin. Der Transport begrenzt beide Ausgabepipes gemeinsam auf 1 MiB
und besitzt einen endlichen Timeout. Remotehosts und unbekannte Routen bleiben
vor Arrange gesperrt; das Profil startet keine Podmanmaschine.
Podman-Create prüft Clientoptionen bis zur validierten unveränderlichen
Image-Referenz über den bestehenden Create-Parser. Ein vorheriges `-c` bleibt
gesperrt; danach darf es als Shellargument des eigenen Containers passieren.
Lange Routingoverrides bleiben gesperrt. Intent-, Mount- und Imagebindungen
werden vor dem tatsächlichen Create weiterhin vollständig geprüft.

Die RuntimeScope-Projektion verwendet `EXPLICIT_POLICY_PIN`. Ihr DisplayName
ist eine Policyanzeige; die bestehende Formel `DisplayName|Endpoint|BackendKind`
bleibt erhalten. `REPORT_ONLY` und `PRESERVE_RUNTIME` gelten weiter. Daraus
folgt weder eine Enginegeneration noch Kompatibilität mit anderen Roots oder
mit Standard-Scopeidentitäten. Die Projektion ersetzt keine Löschautorität.

## Ressourcen und Cleanup

Alle vorbestehenden Container, Volumes, Netzwerke, Images, Tags, Tasks,
Desktop-/HKCU-Einstellungen und Hostdienste bleiben erhalten. Eigene
Container benötigen einen exklusiven Write-ahead-Intent, die tatsächliche
Creation-Receipt, vollständige 64-stellige CID und frische eigene Labels am
selben Pin. Namen, UUIDs oder Labels allein erlauben keine Adoption. Diese
Prüfung gilt auch für Sidecars, Probecontainer und Fehlerkompensation.

Eigene Volumes besitzen separate Creation-Receipts, Namensabwesenheit vor
Create und frische Inspect-/Labelbindung. Diese Records bleiben nach
Containerentfernung für Retained-Store-Beobachtung und Transfer erreichbar.
Entfernung prüft zusätzlich die bestehenden Store-/Attachmentverträge.
Ein gültig gebundener Run darf ein am selben Pin nachweislich abwesendes
Volume ohne Delete als bereits bereinigt behandeln, auch wenn Arrange vor
der Creation-Receipt abbrach. Fehler bei der Inventarbeobachtung bleiben
gesperrt; ein vorhandenes Volume benötigt weiterhin sämtliche Besitznachweise.
Podmans Besitzanpassung mit `U`, `U,ro` oder `U,rw` ist ausschließlich
für Named Volumes mit vollständiger Creation-Receipt und frischer Labelbindung
zulässig. Host-Bind-Mounts erhalten diese rekursive Besitzänderung nicht;
unbekannte oder doppelte Optionen und Docker-`U` bleiben gesperrt.
Vorhandene Netzwerke werden nur gelesen. Hostschreibpfade bleiben im eigenen
Root; gemeinsame Netzwerk-, CNI- und Cacheänderungen werden gesperrt.

Bibliotheksbackups binden zusätzlich den eigenen Run und den `DataRoot` im
Policyroot vor SQL- oder Dateieffekten. Ihre temporäre Exportdatei liegt in
einem frischen Verzeichnis unter diesem Root statt im globalen Tempverzeichnis.
Auch das temporäre Cleanup prüft die Root- und Pfadbindung. Ohne eigenes Profil
bleibt der bisherige temporäre Backupvertrag wirksam.
Die CI-Rootnamen behalten die vollständige GUID bei kurzem Präfix. Transfer-
Acceptance und Medien-Preflight allokieren ihre Daten direkt unter diesem Root
in frischen kurzen Verzeichnissen, damit die Evidence-Verzeichnisstruktur den
nativen Backup-Bind-Mount nicht unnötig verlängert. Das Daten-Cleanup verlangt
die unveränderte Policy und den prozesslokalen Allocationrecord mit Dateimarker;
vorhandene Verzeichnisse werden nicht adoptiert, Reparsepfade bleiben gesperrt.
Der Preflight entfernt seinen eigenen persistenten Ziel-Store nach Run-Cleanup
über den öffentlichen Retained-Store-Plan und dessen gebundenen Apply-Vertrag.
Bei fehlgeschlagener Bereinigung bleiben Daten und Custody für Recovery erhalten.
Wirft die Preflight-Erstellung vor Rückgabe einer Run-ID, bleibt auch ihr
möglicher partieller State erhalten; der Harness adoptiert keinen unbekannten Run.
Ein gleichzeitiger primärer Fehler und Cleanupveto behält die ursprüngliche
Exception; deren lokale `SqlServerLab.BackupCleanupStatus`-/
`SqlServerLab.BackupCleanupReason`-Metadaten zeigen den getrennten Recoverybedarf.

Der Package-Export-Recoverytest injiziert seinen kontrollierten Kopierfehler im
eigenen Profil erst am vorbereiteten nativen Prozessstart hinter den tatsächlichen
Route-, Custody- und Pfadprüfungen. Nur die exakte Runtime-Route und Container-ID
des Test-Runs treffen diese Fault-Injection; andere Aufrufe laufen unverändert weiter.

SqlPackage-ToolImages behalten ihre logischen Katalogschlüssel. Validierte
vorhandene Images dürfen über ihre unveränderliche Image-ID gelesen werden.
Podmans vollständige 64-stellige Hex-ID wird dabei zur gemeinsamen
`sha256:`-Referenz normalisiert. Verkürzte IDs bleiben für beide Provider gesperrt;
Docker benötigt weiterhin die vollständige präfixierte ID.
Ein notwendiger Build verwendet einen intern generierten Policy-/ImageKey-Tag,
exklusiven Intent, bestätigte Tagabwesenheit und `--pull=false`. Base und
Extractor müssen bereits unter dem katalogisierten Digest erreichbar sein;
fehlende Images lösen keinen Pull aus. Probecontainer gehören zum eigenen
Run. Imagecleanup entfernt ausschließlich den eigenen Tag ohne Prune oder
Force und erst nach terminalen referenzierenden Runs und ohne verbleibende
Containerreferenzen. Geteilte Tags oder Images werden nicht entfernt.

Autostart verwendet ausschließlich einen eindeutig eigenen Task und ein
hashgebundenes Koordinatorskript, Write-ahead-Receipt und exakte
Task-Revalidierung. Kein Force, keine Desktop-/HKCU-Änderung. Eine native
Task kann Principal und Logontrigger als Kontonamen statt SID zurückliefern.
Beide werden vor Create-Bestätigung oder Cleanup aufgelöst und mit dem exakten
Owner-SID verglichen; fremde, leere oder nicht auflösbare Identitäten bleiben
gesperrt. Die übrigen Action-, Trigger-, Principal- und Hashbindungen gelten weiter.
Eine registrierte
Task ist kein Nachweis tatsächlichen Logondispatchs. Öffentlicher Stop im
Profil überspringt gemeinsame Hostspeicherwartung auch aus verschachtelten
Lifecycle-/Gruppenpfaden. Der Standardvertrag für Hostspeicher bleibt bestehen.
Cleanupfehler behalten Ursache und Recoverybedarf; der Root wird nicht
pauschal rekursiv entfernt und seine lokalen Custodyrecords bleiben erhalten.

## Tatsächliche Pflichtketten und Grenzen

Sample-Artefakte verwenden im eigenen Profil standardmäßig die Bibliothek
`testdata-library` unter dem gebundenen StateRoot. Cache, sichtbare Bibliothek
und `LAB_GENERATED`-Baselines bleiben dadurch im eigenen Scope. Ein expliziter
Testdaten-Root muss absolut und innerhalb dieses Roots liegen. Policyverlust,
fremde Pfade und Reparse Points in den abgeleiteten Artifact- und Baselinepfaden
werden vor deren Initialisierung abgelehnt.
Auch später abgeleitete Digest-, Kategorie-, Objekt- und Quarantänepfade
werden vor Lesen, Schreiben oder Verschieben auf diese Grenze geprüft.
Die globale Bibliotheksauswahl des Standardprofils bleibt erhalten;
die Container-Kopiergrenze gilt weiter.

Docker-, Podman- und Mixed-Workflows geben denselben expliziten Root an ihre
bestehenden Harnesses weiter: Lifecycle/Matrix, Restore, Collation, Batch,
ToolAcceptance, PackageExport, PortableTransfer/Preflight, PITR, SQL-Upgrade,
AI-Vector und ausgewählte Podman-Samples. Native Restartpolicy-, Label- und
öffentliche DTO-Assertions bleiben erhalten. Hyper-V-Smoke nutzt den
bestehenden isolierten Reconcile-Vertrag und prüft Adapterabwesenheit; die
Hyper-V-Runtimeimplementierung wird dadurch nicht erweitert. Adaptergate und
vollständige Pflichtgateauswahl bleiben eigenständige Nachweise.

Der optionale CLI-Reconcile-Modus, InstanceStore-CLONE, parallele
Matrix-Runspaces im eigenen Profil und externe Runtime-ToolImage-Builds sind
vor Arrange ausdrücklich gesperrt. Sie werden nicht als bestandene Fälle
umgedeutet. Die fünf Pflichtgates bleiben vollständig auszuwählen. Rohlogs,
Pins, Hostwerte und native Diagnosen bleiben lokal; Uploads dürfen nur bereits
bereinigte Zusammenfassungen enthalten.

## Validation

`Invoke-OwnedHostIntegrationChecks.ps1` verwendet synthetische Records,
Transport-Spies und eigene PowerShell-Kinder für Transportgrenzen. Es führt
keine Provider-, SQL-, Task-, WSL- oder Desktopoperation aus. Die Suite
prüft zusätzlich den tatsächlichen Initializer für Docker, Podman und Mixed
mit synthetischen Discoveryantworten: Die ausgewählten Providernamen bleiben
bis zur Readinessprüfung erhalten. Diese Prüfung erzeugt keine native Policy.
Ein stabiler Diff benötigt gekoppelte statische Suites, unabhängige Reviews und getrennte native
Docker-, Podman-, Mixed-, Hyper-V- und Adapterpflichtgates am exakten Head.
Der CI-Selektor wählt diese fünf Gates auch bei einer isolierten Änderung am
OwnedHost-Core, seinem Root-Koordinator oder seinem Schema. Reine Änderungen
an der statischen Fixture oder dieser Dokumentation starten keine Runtime.
Vor und nach nativem Arrange müssen sämtliche vorbestehenden Ressourcen frisch
erfasst und als geschützt revalidiert werden. Synthetische Checks, Readiness,
Taskregistrierung und historische Abnahmen ersetzen diese Nachweise nicht.

Die Consumer-Fixtures führen tatsächliche Provider-Inventar- und Create-Funktionen
mit null beziehungsweise mehreren Mounts, Transfer-Planung und die terminalen
PITR-, Upgrade- und Sample-Cleanupfunktionen mit gebundenen Transport-Spies aus.
Ein SQL-Wait mit realer Zeitmessung und synthetischem SQL-Probe bleibt auch nach
fünf Sekunden innerhalb seines konfigurierten Zeitfensters; ausgeschlossene
Hostwartung liefert keine erfundene Nichterreichbarkeitsdiagnose. Der öffentliche
New-Carrier wird gezielt durch Ausführung seiner tatsächlichen AST-Retryschleife
mit abweichender ambienter Runvariable geprüft. Diese begrenzte Prüfung deckt
weder die vollständige öffentliche Provisionierung noch native Wirkung ab.
