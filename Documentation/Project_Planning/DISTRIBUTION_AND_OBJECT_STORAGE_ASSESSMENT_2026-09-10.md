# Bewertung von Air-Gap-Paketen und SQL-Object-Storage

| Merkmal | Wert |
|---|---|
| Status | `validated` (Bewertung; keine neue Paket-/S3-Ausführung) |
| Stand | 2026-09-10 |
| Quellstand | `0ce3e3c1` |
| Auftrag | Zwei Bewertungszeilen des [Arbeitsplans](AUTONOMOUS_DEVELOPMENT_WAVE_2026-09-10.md) |

## Air-Gap-Distributionspaket

Der Bedarf aus dem [Plattformbacklog](CROSS_CUTTING_PLATFORM_CAPABILITIES_BACKLOG.md)
wird bestätigt: Ein SQL-Lab soll mit einer explizit ausgewählten, vollständig
verfügbaren Menge freigegebener Inhalte ohne Nachladen reproduzierbar sein.
Der vorhandene [Release-Packer](../../Tools/Prepare-LocalRelease.ps1) verteilt
einen geprüften Repository-Snapshot. Er beweist weder Vollständigkeit externer
Medien noch deren Distributionsrechte oder einen Offline-Labaufbau.

Der erste spätere Slice umfasst genau eine SQL-2025-/Provider-/Szenariobindung.
Ein Auswahlplan erfasst transitive Medien-, Image-, Tool-, Katalog- und
Sampleabhängigkeiten. Nur explizit freigegebene Inhalte dürfen ins Paket;
öffentliche Downloadbarkeit ist keine pauschale Weitergabefreigabe. Fehlende
oder nicht freigegebene Inhalte blockieren ein als vollständig bezeichnetes
Paket. Secrets, Host-/Run-State, unbekannte Caches und reale Backups bleiben
ausgeschlossen. Relativer Aufwand L wegen Resolver-, Lizenz-, Import- und
Offline-Lifecycle-Verträgen.

| Grenze / Nutzen | Risiko und nächster abnehmbarer Schritt |
|---|---|
| Herkunft und Integrität | Inhalt, Herkunft und zulässige Verwendung getrennt binden. Erwartete Digests aus vertrauenswürdiger Quelle und verfügbare Signaturen prüfen. Ein gemeinsam mit manipulierten Dateien ersetztes Hashmanifest ist kein Herkunftsnachweis. |
| Sichere Materialisierung | In eigenes Staging importieren; Pfadflucht, absolute Pfade, Linkziele, doppelte Einträge und unvertretbare Entpackgrößen abweisen. Bestehende Root-/Artifact-/Atomic-Write-Verträge wiederverwenden. Erst vollständig geprüfte Inhalte veröffentlichen. |
| Tatsächlicher Offline-Nutzen | Isoliertes Testziel ohne ausgehenden Zugriff mit der gebundenen Paketmenge aufbauen; SQL-Bereitschaft und synthetische fachliche Assertion ausführen. Ein absichtlich fehlendes Artefakt muss vor Mutation scheitern, ohne stillen Netzwerkversuch. Keine globale Netzwerkabschaltung des Arbeitsrechners. |
| Update und Exit | Delta an die exakte Ausgangsrevision binden. Abbruch vor/nach Veröffentlichung und Hashabweichung prüfen; alte referenzierte Artefakte erhalten. Ausstieg bleibt Nutzung der gleichen lokalen Resolver/Provider ohne dauerhaften Paketdienst. |

Nächster Schritt nach den offenen Transfer-/State-/Recovery-Gates ist eine
geschlossene, lizenzgeprüfte Referenzmenge und deren Offline-Roundtrip auf einem
eigenen Ziel. Inhalt, Integrität, funktionaler SQL-Aufbau und Cleanup werden
getrennt belegt. Diese Bewertung erstellt kein Medienarchiv.

## PolyBase und S3-kompatibler Object Store

Der [S3-Backlog](POLYBASE_S3_OBJECT_STORAGE_BACKLOG.md) bleibt sinnvoll für
SQL-Abfragen auf synthetischen CSV-/Parquet-Daten. Der erste Referenzpfad bleibt
ein kleiner Docker-SQL-2025-Run mit eigenem Single-Node-Store, Bucket, Volume,
Netzwerk und Least-Privilege-Identität. Podman und ein späterer Hyper-V-Linux-Pfad
benötigen getrennte Abnahmen. Relativer Aufwand L für Provider-, TLS-,
Credential-, SQL- und Recoveryintegration.

Die frühere positive Vorauswahl von MinIO wird zurückgenommen: Das öffentliche
[Community-Repository](https://github.com/minio/minio) ist seit 2026-04-25
archiviert und bezeichnet sich als nicht mehr gepflegt. Diese am 2026-09-10
festgestellte Wartungsgrenze verhindert eine ungeprüfte neue Standardabhängigkeit.
Ein altes Image mit bekanntem Hash genügt nicht als Wartungsentscheidung.
Ein alternatives Produkt oder kommerzieller Nachfolger wird nicht automatisch
ausgewählt. Die bereits genannten Kandidaten brauchen eine aktuelle Matrix zu
Wartung, Bezugsweg, Lizenz, reproduzierbarem Build, SQL-Kompatibilität und Exit.

| Grenze / Nutzen | Entscheidung und konkrete Abnahme |
|---|---|
| SQL-Funktion statt bloßer S3-Erreichbarkeit | Vor Installation SQL-Build, Dateiformat und gewünschte Lese-/Schreiboperation binden. Danach Daten über SQL External Objects lesen und erwartete Zeilen, Typen und Summen prüfen. Ein HTTP-Healthcheck genügt nicht. |
| Trust und minimale Rechte | HTTPS mit korrekter Identität und Trust im eigenen SQL-Ziel; kein Root-Key in SQL. Falsche CA, Hostname, Schlüssel und fehlende Bucketberechtigung müssen sichtbar scheitern. Secretwerte bleiben ausschließlich lokal. |
| Schreibfähigkeit | Nur ausdrücklich gebundene SQL-Schreiboperation ausführen. Resultierendes Objekt unabhängig über die S3-API auf Inhalt prüfen; Lesen und Schreiben erhalten getrennte Ergebnisse. |
| Persistenz und Wiederaufnahme | Stop/Start von SQL und Store, Prozessabbruch nach Bucketanlage und erneute Provisionierung prüfen. Keine doppelten Buckets, Credentials oder SQL-Objekte; eigener Datenstand bleibt nach Restart erhalten. |
| Eigentum und Cleanup | SQL-Objekte, Trust, Benutzer, Bucket, Volume und Netzwerk vor Mutation identifizieren. Externe/fremde Ressourcen bei Negativtests erhalten. Teilweise fehlgeschlagener Cleanup bleibt Recoverybedarf; kein Wildcard- oder Store-Prune. |

Der nächste Umsetzungsschritt ist zunächst die konkrete Produkt-/Artefaktmatrix,
anschließend ein solcher isolierter Ende-zu-Ende-Lauf. Die
[Microsoft-Dokumentation zum S3-Zugriff](https://learn.microsoft.com/en-us/sql/relational-databases/polybase/polybase-configure-s3-compatible?view=sql-server-ver17)
wurde am 2026-09-10 als Primärquelle gelesen; die konkrete Auswahl und
Abnahmereihenfolge sind Projektentscheidungen. Es wurde kein Store installiert,
kein Bucket angelegt und keine S3-/SQL-Runtimefähigkeit freigegeben.
