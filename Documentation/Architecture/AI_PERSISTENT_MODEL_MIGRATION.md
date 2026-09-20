# Begrenzter Modellwechsel im persistenten SQL-Retrieval

Stand: 2026-09-21. Status: `VALIDATED_REFERENCE`. Dieser Folgeslice
erweitert [persistentes Retrieval](AI_PERSISTENT_RETRIEVAL.md) um genau einen
ausdrücklichen Modellwechsel: bestätigtes Delta, Generation 2 mit vorhandenem
`embeddinggemma:latest`, nach Generation 3 mit vorhandenem
`nomic-embed-text-v2-moe:latest`. SQL Server 2025 unter Docker und Podman bleiben
die einzigen Zielprovider. Der Controller kontaktiert ausschließlich Loopback;
kein Download, Cloudaufruf, Generierungsschritt oder Host-Lifecycleeingriff.

## Aufruf und Profile

```powershell
$scope = @{RunId=$runId; CollectionId=$collectionId; StateRoot=$stateRoot}
$migration = @{Action='Migrate'; FixtureRevision='Delta';
    TargetModelKey='ollama-nomic-embed-text-v2-moe'; TimeoutSeconds=600}
Invoke-SqlServerLabAiPersistentRetrieval @scope @migration -WhatIf
Invoke-SqlServerLabAiPersistentRetrieval @scope @migration
# Ausschließlich nach unterbrochenem Migrate mit identischem Ziel:
Invoke-SqlServerLabAiPersistentRetrieval @scope @migration -Resume
Invoke-SqlServerLabAiPersistentRetrieval @scope -Action Query -QueryId cleanup
Invoke-SqlServerLabAiPersistentRetrieval @scope -Action Remove
```

Die Quelle muss vollständig COMMITTED sein. Die API akzeptiert genau diesen
Zielschlüssel und benötigt ausdrücklich `FixtureRevision Delta`. WhatIf liest
nur lokale versionierte Verträge; es prüft keine Runtime und schreibt keinen
State. Die Vorschau nennt bei Query
`ModelSelection=ACTIVE_SQL_GENERATION` und lässt `ModelKey` und `Revision` leer,
weil deren tatsächliche Werte erst aus der aktiven SQL-Generation folgen.
Bei Remove gilt `ModelSelection=NOT_REQUIRED`; Apply und Migrate nennen das
feste Modell. Die eigentliche Ausführung der alten Apply-/Query-/Remove-Aufrufe
für Journal 1.0 bleibt erhalten.
Nach dem Upgrade ist Apply gesperrt; die Migration kann wiederholt bestätigt,
aber weder rückwärts noch zu einem weiteren Modell ausgeführt werden.

Beide Modelle liefern 768 Dimensionen. Das unveränderte Quellprofil `raw`
übergibt den Fixturetext direkt. Das feste Zielprofil `nomic-search` setzt
Dokumenten exakt `search_document: ` und Fragen exakt `search_query: ` voran.
Die [Ollama-Modellseite](https://ollama.com/library/nomic-embed-text-v2-moe)
beschreibt diese Präfixe, 768 Dimensionen und das Limit von 512 Tokens. Die
feste kurze Fixture bleibt innerhalb dieser Grenze; freie Dokumente und
automatische Trunkierung gehören nicht zum Vertrag. Die
[Nomic-Modellkarte](https://huggingface.co/nomic-ai/nomic-embed-text-v2-moe)
weist Apache-2.0 aus. `minimumOllamaVersion=0.34.2` ist der konservative
Projekt-Floor dieses neuen Katalogeintrags, keine behauptete Herstellermindestversion.
Seine native Eignung für diese SQL-Migration ist noch nachzuweisen.

Der Livevertrag prüft Tag, Manifestdigest, Ollama-Version, Embeddingfähigkeit,
Dimension und fehlende Remoteidentität. Diese Bindung wird vor und nach den
Payloads revalidiert. Die angeforderte Modellidentität ist keine unabhängige
Attestierung des tatsächlich ausgeführten Modells. Ein Modelldigest wird nicht
als allgemeine Konstante versioniert.

## Identität und Upgrade

Der bestehende reine Re-Embedding-Planer bindet Delta-Dataset, Chunking,
Dokumenthashes, tatsächliche SQL-Quellvektorhashes und beide Modellidentitäten.
Ein äußerer PlanKey ergänzt Run-/Scope-/Instanz-/Collection-/DB-Identität,
Operation, Request, Quellreceipt, vollständige Hostbindings und beide Profile.
Der historische ModelHash bleibt der Hash des Hostbindings. Profilhashes und
äußerer PlanKey ergänzen ihn; alte Hashes werden nicht umgedeutet.

Erst nach vollständiger Ownership-/Quellprüfung wird das lokale Journal atomar
als **2.0 / UPGRADE_PENDING** mit unveränderlichem Migrationsintent ersetzt.
Danach legt eine SQL-Transaktion das versionierte `LabMigrationReceipt` an.
Es bindet Upgrade-ID, PlanKey und den vollständigen Intent einschließlich
Zielprofil und Quellvektorhashes. Die drei bestehenden Tabellen werden nicht
umgebaut. Fremde oder widersprüchliche Receipts werden nicht adoptiert.

| Abbruchfenster | Verhalten |
|---|---|
| Vor dauerhaftem v2-Intent | Keine SQL-Upgrademutation; alte Journalbytes bleiben erhalten. |
| Intent vorhanden, SQL-Upgrade fehlt | Query liest Generation 2; explizites Resume darf das exakt gebundene Upgrade ausführen. |
| SQL-Upgrade bestätigt, Antwort verloren | Resume erkennt das Receipt und wiederholt kein DDL. |
| Ein Teil der Zielchunks bestätigt | Generation 2 bleibt aktiv; Resume validiert SQL und ergänzt nur fehlende Zielchunks. |
| SQL-Cutover bestätigt, Journal noch STAGING | Query verwendet sofort Generation 3 und das Zielprofil. Resume finalisiert ohne neue Embeddings oder zweiten Cutover. |

Das Upgrade ist ausdrücklich vorwärts gerichtet. Alte Clients lehnen das neue
Journal ab. Ein unbekanntes Vertragsformat, ein fehlendes erwartetes Receipt
oder ein anderer Upgradeintent bleibt Recoverybedarf. Ein expliziter
Dateilock und derselbe SQL-Session-AppLock wie bisher umfassen die Operation;
konkurrierende Aufrufe warten nicht. Die alte Query ist **nach unterbrochenem
Staging** verfügbar, nicht parallel zu einem laufenden exklusiven Migrate-Aufruf.

## Staging, Cutover und Cleanup

Alle drei Zielvektoren werden neu erzeugt, auch beim unveränderten Cleanuptext.
Es gibt keinen Copy-Pfad über Modellgrenzen. Die Quellgenerationen bleiben
unverändert. SQL validiert das Zielmanifest einschließlich vollständiger
Inhalte, Modell-/Plan-/Operationsbindung, gespeicherter Vektorhashes sowie das
Migrationsreceipt und die gebundenen Quellvektoren in der Cutovertransaktion.
Erst dann werden COMMITTED und der aktive Zeiger gemeinsam gesetzt.

Bei Journal 2.0 liest Query zunächst Ownership und aktive SQL-Generation,
prüft deren Plan, Operation, Dataset und Receipt und ermittelt erst danach das
zugehörige Live-Modell. Während Staging zählt das Quellmodell; nach Cutover
zählt ausschließlich das Zielmodell. Ein fehlendes Quellmodell verhindert
dann weder Zielquery noch die Bestätigung einer bereits abgeschlossenen Migration.
Digest-/Versions-/Profildrift blockiert unvollständiges Resume. Remove bleibt
modellunabhängig und prüft weiterhin ausschließlich exakt eigenen DB-Besitz
und tatsächliche Abwesenheit; fehlerhafte Ownership wird nicht übergangen.

## Grenzen und Nachweise

Höchstens drei Generationen mit je drei festen Dokumenten; Datenfile maximal
64 MiB und Log maximal 32 MiB wie bisher. Migration benötigt drei Embeddings,
Resume nur die fehlenden, Query eines. Keine automatischen Retries. Modellprobes
und Payloads benötigen weiterhin 45 beziehungsweise 60 Sekunden Restbudget;
600 Sekunden Operationsbudget werden für den Modellwechsel empfohlen.
Die bestehende begrenzte Wallclock-Garantie wird dadurch nicht erweitert.

Die Offline-Suite prüft die Upgrade-/Staging-/Commitfenster, alte und neue
Query, Profile, Drift, Sperren, Journalfehler und besitzgebundenes Remove.
Der getrennt nativ geprüfte Einstieg lautet:

```powershell
.\Tests\Integration\Invoke-AiPersistentRetrievalMigrationAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-AiPersistentRetrievalMigrationAcceptance.ps1 -Provider podman
```

Er verwendet je einen eigenen SQLrun, zählt die tatsächlich erreichten
Faultpoints, prüft beide festen Top-IDs vor/nach Cutover und SQLrestart sowie
unveränderte Quellgenerationen und Hosttags. PASS folgt erst nach eigenem
DB-/Run-/Volume-Cleanup. Die getrennten Docker- und Podman-Läufe bestanden am
2026-09-21 jeweils 20 Assertions und vollständiges Cleanup (zwei Schritte,
keine Fehler). Sie belegen den Modellwechsel einschließlich SQLrestart,
Upgrade-/Staging-/Commit-Antwortverlust und beider festen Suchfragen.
Ein früherer Docker-Versuch erreichte wegen der belegten Testsperre keine
Runtime; der anschließende Lauf mit vorgeschalteter Sperrübernahme bestand.
Beliebige Dokumente, weitere Modell-/Dimensionsmigrationen, alte Generationen
selektiv entfernen, Hyper-V, ANN und Golden-v1-Modelländerungen bleiben offen.
