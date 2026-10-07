# Bytegrenzen für gemeinsame Downloads

`Save-LabProgressDownload` ist der interne gemeinsame Streamingtransport für
Artefakte, Medien, Windows-Pakete und llama.cpp-Modelle. `MaximumBytes` ist eine
positive 64-Bit-Byteobergrenze; ohne engere Vorgabe gilt 1 TiB (1.099.511.627.776
Bytes). Das ist ein Kompatibilitätsrahmen für große Backup-/Archivquellen ohne
Größenmetadaten, keine Empfehlung zum Reservieren dieser Datenmenge.

`Save-SqlServerLabMediaSource` übergibt für beide bestehenden Quellenwege die
kataloggebundenen `ExpectedBytes`. Der Standardtransport des llama.cpp-
Modellkatalogs erhält `sizeBytes`. Andere gemeinsame Aufrufer ohne Bytepin
verwenden zunächst den allgemeinen Rahmen. Die öffentlichen Parameter,
Ergebnisverträge, Quellenfreigaben und Integritätswerte bleiben erhalten.

Eine deklarierte `Content-Length` oberhalb der Grenze führt vor Öffnen oder
Kürzen der Zieldatei zu `LAB_DOWNLOAD_MAXIMUM_BYTES_EXCEEDED`. Antworten ohne
Länge und Chunked-Antworten werden ebenfalls gezählt. Der Reader verwendet
höchstens die verbleibende Bytezahl und am exakten Limit ein Sentinelbyte zur
Unterscheidung von EOF und Überlänge. Dieses Byte wird nicht geschrieben.
Subtraktion des Restbudgets vermeidet einen Additionsüberlauf bei großen Limits.

Ein Größenverstoß wird nicht wiederholt. Vorhandene begrenzte HTTP-/Timeout-
Retries bleiben erhalten. Erfolg verlangt weiterhin die vorhandene HTTP-
Längenkonsistenz; die Aufrufer prüfen danach Hash, genaue Kataloggröße,
GGUF-Magic bzw. Signatur und veröffentlichen erst nach diesen Prüfungen.

Der Transport verfügt über keine allgemeine Löschautorität für `OutFile`.
Ein während des Empfangs abgewiesener Teilstand kann bis zur Caller-Bereinigung
bestehen und bleibt höchstens so groß wie die Obergrenze. Medien und Modelle
entfernen ihre eigenen temporären Dateien im bestehenden `finally`; der
Artefaktresolver entfernt den eigenen fehlgeschlagenen Stagingvorgang.

Die [Loopback-Fixture](../../Tests/Static/Fixtures/ActionProgressDownloadLimitChecks.ps1)
ist in die direkte Fortschrittssuite eingebunden. Sie prüft tatsächlichen
HTTP-Empfang mit deklarierter und unbekannter Länge, Chunked, exaktem Limit,
leerem Body, Redirect, abgeschnittener Antwort und begrenztem Retry. Sie nutzt
eigene synthetische Dateien und einen kurzlebigen numerischen Loopback-Listener;
SQL und Provider sind daran nicht beteiligt.

Offen bleiben engere fachliche Grenzen für nicht größenkatalogisierte Quellen,
freie Speicherplatzprüfung, Reservierung und kumulative Quoten. Eine Bytegrenze
autorisiert kein Downloadziel und ist kein Redirect-/DNS-/TCP-Nachweis. Der
ältere Security-Cloud-Scan attestiert diesen Stand nicht; sein Fund wird durch
diesen Slice nicht extern geschlossen.
