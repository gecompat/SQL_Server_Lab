# Persistentes synthetisches Retrieval unter SQL Server 2025

Stand: 2026-09-21. Status: `VALIDATED_REFERENCE`. Der erste Slice
speichert einen festen synthetischen Dokumentbestand und seine Vektoren in
einer eigenen Datenbank eines laufenden Docker-/Podman-Runs. Er verwendet das
bereits vorhandene lokale `embeddinggemma:latest` mit 768 Dimensionen. Es gibt
keinen Modell-Download, Host-Neustart, Cloudaufruf oder Generierungsschritt.

## Öffentlicher Ablauf

Für eine neue eigene Podman-Umgebung bündelt der
[KI-Erstellungsdialog](AI_PODMAN_SETUP.md) New, Initial-Apply und die feste
Backup-Abfrage. Er behält erfolgreiche Umgebungen mit auffindbarer Collection-ID;
sein eigener nativer Podman-Gesamtnachweis bestand am 2026-09-21 einschließlich
Query nach SQLrestart und unabhängig bestätigtem vollständigem Cleanup.

Der Run benötigt ein verwaltetes SA-Secret, SQL Server 2025 unter Linux und
einen live bestätigten Loopback-SQL-Endpunkt. Die API akzeptiert keine eigenen
Dokumente, SQL-Texte, Datenbanknamen oder Verbindungszeichenfolgen.

```powershell
$collectionId = [guid]::NewGuid().ToString('D')
$scope = @{ RunId=$runId; CollectionId=$collectionId; StateRoot=$stateRoot }
Invoke-SqlServerLabAiPersistentRetrieval @scope -WhatIf
Invoke-SqlServerLabAiPersistentRetrieval @scope -FixtureRevision Initial
Invoke-SqlServerLabAiPersistentRetrieval @scope -Action Query -QueryId backup
Invoke-SqlServerLabAiPersistentRetrieval @scope -FixtureRevision Delta
# Nur nach unterbrochenem Apply mit exakt derselben Revision:
Invoke-SqlServerLabAiPersistentRetrieval @scope -FixtureRevision Delta -Resume
Invoke-SqlServerLabAiPersistentRetrieval @scope -Action Remove
```

`WhatIf` liest nur versionierte lokale Verträge und berührt weder Run-State,
Credentials, SQL noch Ollama. `CollectionId` ist für Resume und Remove
beizubehalten. Eine bereits entfernte Collection wird nicht neu verwendet.
`QueryId` benennt ausschließlich die festen Fragen `backup` und `cleanup`.
Das Ergebnis enthält die aktive Generation, feste Dokument-IDs, Inhaltshashes,
Cosinedistanzen und die Anzahl der Embeddingrequests; keine Credentials,
Hostadressen oder Besitzmarker.

Die versionierte Fixture `Scenarios/Ai/persistent-retrieval/1.0/fixture.json`
enthält zwei Generationen mit jeweils drei Dokumenten: Initial enthält Backup,
Cleanup und Netzwerk. Delta aktualisiert Backup, entfernt Netzwerk, erhält
Cleanup und ergänzt Retention. Alte Generationen bleiben unverändert erhalten.
Die Suche verwendet ausschließlich die aktive Generation und exakte
`VECTOR_DISTANCE`-Cosinesuche, keinen ANN-Index. SQL speichert `VECTOR(768)`
mit float32; die JSON-Konvertierung ist ein dokumentierter
[SQL-Vektorvertrag](https://learn.microsoft.com/en-us/sql/t-sql/data-types/vector-data-type?view=sql-server-ver17).

## Besitz, Nebenläufigkeit und Recovery

Vor CREATE persistiert ein atomar geschriebenes Journal den zufälligen
Datenbanknamen und einen zufälligen Besitzmarker. Dieser ist kein SQL-Secret;
reale Journale bleiben dennoch ausschließlich im lokalen Run-State. Das
SQL-Receipt bindet Run, Scope, Instanz, Collection, Marker und `database_guid`.
Die von SQL gelieferte GUID-Schreibweise bleibt in Receipt und Journal
unverändert erhalten; das Schema erlaubt dafür hexadezimale Großbuchstaben
bei weiterhin strikt geprüfter GUID-Struktur und exakt gebundenem Vergleich.
Die live geprüfte Container-/Runtime-/Endpointidentität ist zusätzlich im
Journal gebunden. Ein Datenbankname allein berechtigt nie zu Adoption oder
DROP. Vorhandene Namen ohne passendes Receipt blockieren.

Der runlokale `FileShare.None`-Lock umfasst Lesen, Probe, SQL und Journalcommit;
vorhandene Pfadkomponenten einschließlich StateRoot/Vorfahren dürfen keine
Reparse-Points sein. Zusätzlich hält dieselbe ungepoolte SQL-Verbindung in
`master` einen exklusiven Session-`sp_getapplock` bis zum Dispose. Die
[SQL-Lockidentität](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-getapplock-transact-sql?view=sql-server-ver17)
ist datenbankgebunden. Beide Sperren warten nicht; konkurrierende Aufrufe
liefern `AI_PERSISTENT_LOCKED` oder `AI_PERSISTENT_SQL_LOCKED`.

Jeder Staging-Chunk besitzt feste ID, Inhaltshash und einen Hash der tatsächlich
gespeicherten SQL-Vektorrepräsentation. Resume liest diese Receipts aus SQL,
prüft sie und ergänzt ausschließlich nachweislich fehlende Chunks. Das lokale
Journal ist kein Beweis dafür, dass ein SQL-Schritt abgeschlossen wurde.
Unveränderte Vektoren dürfen nur aus der vollständig validierten aktiven
Generation mit derselben Modellidentität kopiert werden. Digest-/Versionsdrift
blockiert Apply und Query, aber nicht das exakt besitzgebundene Remove.
Query prüft außerdem den Plan-Schlüssel der aktiven SQL-Generation gegen die
rekonstruierte Fixture- und Endpointbindung, bevor es ein Embedding erzeugt.

Der Cutover prüft Soll-IDs, vollständige Inhalte einschließlich Byte-Längen,
Hashes, Modell-/Dataset-/Operationsbindung und vollständige Chunkmenge innerhalb
einer SQL-Transaktion. Erst dann werden Commitreceipt und aktiver Zeiger gemeinsam
aktualisiert. Bei verlorener Commitantwort finalisiert Resume anhand des
SQL-Receipts ohne zweite Umschaltung. Ein gescheitertes Delta lässt die alte
Generation lesbar. Fehlgeschlagene Journalschreibvorgänge bewahren die zuletzt
atomar gespeicherten Bytes; Fehlertexte bleiben feste sanitisierte Codes.

`CREATE DATABASE` muss laut [Microsoft](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-database-transact-sql?view=sql-server-ver17)
außerhalb einer expliziten Transaktion laufen. Deshalb besteht bewusst eine
CREATE→Receipt-Lücke: Ist die DB angelegt, das Besitzreceipt jedoch nicht
bestätigbar, bleibt `AI_PERSISTENT_OWNERSHIP_UNPROVEN`/Recovery. Weder Resume
noch Remove adoptiert oder löscht diese DB. Manuelle Recovery beziehungsweise
das separat autorisierte Cleanup des gesamten eigenen Test-Runs bleibt nötig.
Ist die DB unter gehaltenem SQL-Lock nachweislich noch nicht vorhanden, kann
explizites Resume den persistierten Createintent ausführen. Query erstellt nie
eine fehlende Datenbank. DROP prüft Token und `database_guid` erneut im selben
SQL-Batch und bestätigt danach die Abwesenheit; keine erzwungene Trennung
fremder SQL-Sessions. Ein unbestätigtes DROP bleibt `REMOVING` und kann anhand
der tatsächlichen Abwesenheit finalisiert werden.

## Grenzen und Nachweise

Pro Collection höchstens zwei Generationen mit drei Dokumenten; Datenfile
maximal 64 MiB, Log maximal 32 MiB. Initial erzeugt drei Embeddings, Delta zwei
und kopiert einen unveränderten Vektor. Query erzeugt ein Embedding. Retry ist
jeweils null; Embedding- und SQL-Aufrufe dauern höchstens 60 Sekunden,
Metadatenrequests jeweils 15 Sekunden. `TimeoutSeconds` ist ein zwischen den
Schritten geprüftes Budget (60–600, Standard 300). Modellprobes und Embeddings
werden nur mit 45 beziehungsweise 60 Sekunden Restbudget begonnen. Eine bereits
laufende begrenzte native Bindungsprobe ist nicht global abbrechbar; deshalb
ist dies keine exakte Wallclock-Abbruchgarantie.

Die fokussierte Offline-Suite prüft unter anderem Chunk-/Commit-Antwortverlust,
alte aktive Generation, Resume, GUID-/Markerdrift, Kollisionen, Dateisperre,
Reparse-StateRoot, Modell-/Vektordrift und Journalschreibfehler. Der vorbereitete
`Invoke-AiPersistentRetrievalAcceptance.ps1 -Provider docker|podman` erstellt je
einen eigenen SQL-Run, prüft echte Dateisperre und SQL-AppLock, Restart, Delta-
Teilfehler und Commitantwortverlust und entfernt erst die eigene DB, dann den
eigenen Run mit Container-/Volume-Residueprüfung. PASS erfolgt erst nach Cleanup.
Die getrennten nativen Docker- und Podman-Läufe bestanden am 2026-09-21 jeweils alle 16 Assertions, SQLrestart, gezielte Staging-/Commitfehler und vollständiges DB-/Run-Cleanup. Das vorhandene Hostmodellinventar blieb unverändert.

Dies ist ein inkrementeller Generationsrebuild mit unveränderter Modellidentität.
Der bestehende reine `New-LabAiReembeddingPlan` für einen echten Modellwechsel
bleibt unverändert und wird vom neuen
[begrenzten Modellwechsel](AI_PERSISTENT_MODEL_MIGRATION.md) für genau Delta/gen2
nach Nomic v2 MoE/gen3 wiederverwendet. Docker und Podman bestanden getrennt jeweils 20 Assertions, SQLrestart und Cleanup.
Weitere Digest-/Dimensionswechsel, beliebige Dokumente,
Retention alter Generationen, Cloud, Generierung, Hyper-V und ANN sind offen.
Golden v1 sowie SQL-seitiges EXTERNAL MODEL/TLS-Gateway bleiben unverändert.
