# Persistentes Retrieval unter SQL Server 2025

Stand: 2026-09-22. Status: `VALIDATED_REFERENCE`. Der erste Slice
speichert einen festen synthetischen Dokumentbestand und seine Vektoren in
einer eigenen Datenbank eines laufenden Docker-/Podman-Runs. Er verwendet
standardmäßig das bereits vorhandene lokale `embeddinggemma:latest` mit 768
Dimensionen. `-EmbeddingModelKey ollama-bge-m3-latest` wählt für Apply, Query
und Sync das vorhandene lokale `bge-m3:latest` mit 1024 Dimensionen. Es gibt
keinen Modell-Download, Host-Neustart, Cloudaufruf oder Generierungsschritt.

## Öffentlicher Ablauf

Für eine neue eigene Podman-Umgebung bündelt der
[KI-Erstellungsdialog](AI_PODMAN_SETUP.md) New, Initial-Apply und die feste
Backup-Abfrage. Er behält erfolgreiche Umgebungen mit auffindbarer Collection-ID;
sein eigener nativer Podman-Gesamtnachweis bestand am 2026-09-21 einschließlich
Query nach SQLrestart und unabhängig bestätigtem vollständigem Cleanup.

Der Run benötigt ein verwaltetes SA-Secret, SQL Server 2025 unter Linux und
einen live bestätigten Loopback-SQL-Endpunkt. Die API akzeptiert entweder die
feste Fixture oder 1 bis 16 Caller-Dokumente für eine verwaltete Collection. Sie
akzeptiert keine SQL-Texte, Datenbanknamen oder Verbindungszeichenfolgen.

```powershell
$collectionId = [guid]::NewGuid().ToString('D')
$scope = @{ RunId=$runId; CollectionId=$collectionId; StateRoot=$stateRoot }
# Optional vor Apply setzen und bei jeder folgenden modellnutzenden Aktion beibehalten:
# $scope.EmbeddingModelKey = 'ollama-bge-m3-latest'
Invoke-SqlServerLabAiPersistentRetrieval @scope -WhatIf
Invoke-SqlServerLabAiPersistentRetrieval @scope -FixtureRevision Initial
Invoke-SqlServerLabAiPersistentRetrieval @scope -Action Query -QueryId backup
Invoke-SqlServerLabAiPersistentRetrieval @scope -Action Query -QueryId backup -SearchMode Hybrid
Invoke-SqlServerLabAiPersistentRetrieval @scope -FixtureRevision Delta
# Nur nach unterbrochenem Apply mit exakt derselben Revision:
Invoke-SqlServerLabAiPersistentRetrieval @scope -FixtureRevision Delta -Resume
$scope.Remove('EmbeddingModelKey') # Remove und Prune sind modellfrei.
Invoke-SqlServerLabAiPersistentRetrieval @scope -Action Remove

$documents = @(
    [pscustomobject]@{ Id='restore-guide'; Content='Synthetische Restore-Tests prüfen CHECKDB.' }
    [pscustomobject]@{ Id='index-guide'; Content='Synthetische Index-Tests vergleichen Abfragepläne.' }
)
Invoke-SqlServerLabAiPersistentRetrieval @scope -Documents $documents
Invoke-SqlServerLabAiPersistentRetrieval @scope -Action Query -Documents $documents `
    -Question 'Was prüfen synthetische Restore-Tests?' -SearchMode Hybrid
$updatedDocuments = @(
    [pscustomobject]@{ Id='restore-guide'; Content='Synthetische Restore-Tests prüfen CHECKDB und Datenstatus.' }
    $documents[1]
    [pscustomobject]@{ Id='cleanup-guide'; Content='Synthetische Testressourcen werden nach der Abnahme entfernt.' }
)
Invoke-SqlServerLabAiPersistentRetrieval @scope -Action Sync `
    -ExpectedDocuments $documents -Documents $updatedDocuments
# Nach mindestens einem erfolgreichen Caller-Sync die zwei jüngsten Generationen behalten:
Invoke-SqlServerLabAiPersistentRetrieval @scope -Action Prune -KeepGenerations 2
```

`WhatIf` liest nur versionierte lokale Verträge und berührt weder Run-State,
Credentials, SQL noch Ollama. `CollectionId` ist für Resume, Prune und Remove
beizubehalten. Eine bereits entfernte Collection wird nicht neu verwendet.
`QueryId` benennt ausschließlich die festen Fragen `backup` und `cleanup`.
`Documents` bindet eine Collection an sortierte IDs und Inhaltshashes;
Query verlangt dieselbe vollständige aktive Dokumentmenge und zusätzlich `Question`.
`Sync` verlangt in `ExpectedDocuments` den vollständigen erwarteten aktiven
Bestand und in `Documents` den vollständigen Zielbestand. Erst nach Prüfung des
Ausgangsbestands entsteht eine neue Generation: unveränderte IDs und Inhalte
übernehmen den vorhandenen Vektor, neue oder geänderte Inhalte werden neu
eingebettet und ausgelassene IDs sind nach dem atomaren Cutover gelöscht.
`Prune` ist ein expliziter, modellfreier Retention-Schritt für eine
callerverwaltete v1-Collection nach mindestens einem erfolgreichen `Sync`.
`KeepGenerations` liegt zwischen 1 und 31 und ist standardmäßig 2. Eine einzige
SQL-Transaktion sperrt den exakten Besitzer und aktiven Zeiger, verlangt
ausschließlich `COMMITTED`-Generationen, behält die jüngsten Generationen
einschließlich der aktiven und entfernt nur ältere Chunk- und Generationszeilen.
Replay ist idempotent. Fixture-Collections, unvollständiges Staging und
v2-Modellmigrationsjournale werden vor der Löschung abgewiesen.
Die Frage wird weder im Plan noch im Journal gespeichert. Dokumentinhalte liegen
nur in der eigenen SQL-Datenbank und in den lokalen Ollama-Requests. Abweichende
IDs oder Inhalte scheitern vor dem Query-Embedding.
Das Ergebnis enthält die aktive Generation, feste Dokument-IDs, Inhaltshashes,
Cosinedistanzen und die Anzahl der Embeddingrequests; keine Credentials,
Hostadressen oder Besitzmarker.

Die versionierte Fixture `Scenarios/Ai/persistent-retrieval/1.0/fixture.json`
enthält zwei Generationen mit jeweils drei Dokumenten: Initial enthält Backup,
Cleanup und Netzwerk. Delta aktualisiert Backup, entfernt Netzwerk, erhält
Cleanup und ergänzt Retention. Alte Generationen bleiben unverändert erhalten.
Die Suche verwendet ausschließlich die aktive Generation. Der Standardmodus
`Vector` ordnet per exakter Cosine-Distanz. `Hybrid` kombiniert 70 Prozent
Vektorscore mit 30 Prozent SQL-seitig berechneter lexikalischer Termabdeckung
und löst Gleichstände deterministisch per Distanz und Chunk-ID auf. Wörter mit
weniger als vier Zeichen und definierte Satzzeichen gehen nicht in den
lexikalischen Score ein. Die Berechnung verwendet nur parametrisierte feste SQL
und ausschließlich die aktive Generation. Sie ist für die
EmbeddingGemma- und BGE-M3-v1-Generationen freigegeben. Der separate Nomic-
Modellmigrationspfad bleibt reine Vektorsuche. SQL Server Full-Text Search mit
sprachspezifischem Word Breaker und Ranking bleibt ein eigener offener Slice,
weil das offizielle Standard-Containerimage das optionale
`mssql-server-fts`-Paket nicht enthält.
`VECTOR_DISTANCE`-Cosinesuche, keinen ANN-Index. SQL speichert abhängig von
der gebundenen Collection `VECTOR(768)` oder `VECTOR(1024)` mit float32; die JSON-Konvertierung ist ein dokumentierter
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
Generation mit derselben Modellidentität kopiert werden. Digest-/Versions-/
Dimensionsdrift blockiert Apply und Query, aber nicht das exakt besitzgebundene
Remove oder Prune.
Query prüft außerdem den Plan-Schlüssel der aktiven SQL-Generation gegen die
rekonstruierte Fixture- beziehungsweise erneut übergebene Caller-Dokument- und
Endpointbindung, bevor es ein Embedding erzeugt. Bei `Sync` bindet ein eigener
erwarteter Plan-Schlüssel die aktive Quelle. Eine Abweichung blockiert vor
Staging und Embedding. Das Journal speichert für eine laufende Operation nur
Zielhash, Zielgeneration und bestätigte Chunk-IDs, keine Dokumentinhalte. Nach
verlorenem Cutover-Ergebnis ist das SQL-Receipt maßgeblich; `-Resume` finalisiert
das Journal ohne erneute Quellprüfung oder Embeddings.

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

Pro Fixture-Collection höchstens zwei Generationen mit je drei Dokumenten. Eine
Caller-Collection besitzt eine initiale und bis zu 31 weitere atomare Sync-
oder eine abschließende Modellmigrationsgeneration mit jeweils 1 bis 16
Dokumenten. Explizites `Prune` begrenzt abgeschlossene v1-Caller-Generationen,
setzt die monotone Generationsnummer jedoch nicht zurück. Nach Generation 32
blockiert daher weiterhin `AI_PERSISTENT_GENERATION_LIMIT_REACHED`;
automatische Retention ist nicht implementiert. Die Nomic-v2-Migration bleibt
an ihre validierte EmbeddingGemma-768-Quelle gebunden; eine BGE-M3-Collection
kann abgefragt, synchronisiert, begrenzt und entfernt, derzeit aber nicht zu
Nomic migriert werden. Datenfile maximal
64 MiB, Log maximal 32 MiB. Fixture-Initial erzeugt drei Embeddings, Delta zwei
und kopiert einen unveränderten Vektor. Caller-Initial erzeugt ein Embedding je
Dokument. Query erzeugt ein Embedding. Retry ist
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
Die getrennten nativen Docker- und Podman-Läufe vom 2026-09-22 belegen mit
jeweils 30 Assertions Vektor- und Hybridranking vor und nach SQLrestart sowie
nach Delta-Cutover, gezielte Staging-/Commitfehler und vollständiges
DB-/Run-Cleanup. Beide Läufe belegen außerdem eine eigene Collection mit drei
Caller-Dokumenten, freier hybrider Frage, Hashdrift-Abweisung, atomarem
Update/Insert/Delete bei Übernahme eines unveränderten Vektors sowie
idempotentem Prune mit unabhängig abgefragtem SQL-Tabellenbestand.
Das vorhandene Hostmodellinventar bleibt unverändert.

Die ergänzende Referenz `Invoke-AiPodmanSamplesReferenceAcceptance.ps1` bleibt
auf Podman begrenzt. Sie kombiniert einen frischen eigenen SQL-2025-Run, die
kataloggebundenen Samples Northwind und Chinook, die feste `backup`-Query und
einen öffentlichen SQLrestart. Sie verlangt exakt 830 Northwind-Orders und 275
Chinook-Artists vor und nach dem Restart und entfernt anschließend den gesamten eigenen Run
einschließlich der Collection und seiner Volume. Sie benötigt ein bereits vorhandenes lokales
`embeddinggemma:latest`; Python/R, Docker, Hyper-V, Cloud und beliebige
Dokumente gehören nicht zu diesem Referenzscope. Eine nicht verfügbare Runtime,
ein fehlendes Modell oder ein Katalog-/Integritätsfehler ist kein PASS.

Der Test-Parent persistiert die Operation und die aktuell verifizierte Runtime-ID
vor dem Workerstart in einem privaten temporären Root (Windows-ACL beziehungsweise
Unix-Modus 700). Acceptance und Cleanup laufen in getrennten Prozessen mit
unabhängigen Grenzen von standardmäßig 900 und 240 Sekunden. Bei Timeout folgt
die begrenzte Prozessbeendigung; unbestätigte Beendigung blockiert Cleanup.
Private Streams, Operation und beide Ergebnisse bleiben für lokale Recovery erhalten.
Es gibt keinen `KeepOnFailure`-Pfad. Cleanup benötigt auch nach partiellem New
keinen laufenden SQL-Endpunkt: Es prüft exakte Operationszuordnung, Cleanup-Plan,
frische Runtime-ID, Ressourcenlabels und fremde Volume-Attachments vor Remove.
Anschließend müssen sowohl die dokumentierten Ressourcen als auch alle Run-Labels
aus dem Runtime-Inventar verschwunden sein. Ein terminaler Run-State allein reicht
nicht. Fehlende oder mehrdeutige Ownership bleibt Recoverybedarf. Die fokussierte
Suite prüft diese Fehlerpfade synthetisch sowie echte Child-Prozessgrenzen mit
persistiertem Arrange-Marker und `NewStarted=true` vor dem künstlichen Hang.
Der Cleanup-Child verlangt das Ende des vorherigen Prozesses und quittiert die
synthetische Zustandsbereinigung; ein Cleanup-Timeout erhält den offenen Marker.
Der kombinierte native Podman-Nachweis für diesen Runner bleibt offen.

Sync ist ein inkrementeller Generationsrebuild mit unveränderter Modellidentität.
Der bestehende reine `New-LabAiReembeddingPlan` für einen echten Modellwechsel
bleibt unverändert und wird vom neuen
[begrenzten Modellwechsel](AI_PERSISTENT_MODEL_MIGRATION.md) für die feste
Delta- sowie für callerverwaltete Collections nach Nomic v2 MoE wiederverwendet.
Die erweiterten Docker- und Podman-Nachweise bestanden am 2026-09-22 getrennt
mit je 25 Assertions, Caller-Collection, SQLrestart und vollständigem Cleanup.
Weitere Zielmodelle und Dimensionswechsel, Sync oder Prune nach Modellmigration, automatische Retention, Cloud,
Generierung, Hyper-V und ANN sind offen.
Golden v1 sowie SQL-seitiges EXTERNAL MODEL/TLS-Gateway bleiben unverändert.
