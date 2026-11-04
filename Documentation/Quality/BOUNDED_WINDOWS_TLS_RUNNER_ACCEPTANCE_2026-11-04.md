# Befristeter Windows-TLS-Runner: native Abnahme

## Ergebnis und Bindung

Der korrigierte native Consumer-Gesamtfall ist PASS. Nach einmaliger erhöhter
Installation startete der gewöhnliche Controller Vorprüfung und vollständigen
Lauf ohne weitere Hostinteraktion. Einer von höchstens zwei neuen Versuchen wurde genutzt.

Der [Runnervertrag](../Architecture/BOUNDED_WINDOWS_TLS_RUNNER.md) bindet eine
unveränderliche Quellkopie und dieselbe registrierte Lab-Identität samt Paket-/
Authoritykontext. Produktgrundlage ist
[ec51ffb1](https://github.com/gecompat/SQL_Server_Lab/tree/ec51ffb1356bb3546feb8c397b56c2cfd42a5f8f)
mit dem hier ergänzten, privat hashgebundenen Runner und korrigierten Adapter.
Private Originale und Quellkopie bleiben außerhalb der Versionskontrolle.

## Reale Nachweise

Vierzehn native Sicherheitsprüfungen bestanden: gewöhnlicher Controller,
Schreibverweigerung an Manifest, Zähler, Quelle und privatem Probeobjekt;
administrativer Taskbesitzer, Lese-/Ausführungsrechte der gewöhnlichen Identität,
Highest/InteractiveToken, keine harte Terminierung oder parallele Instanz,
gebundener Trigger, unbeaufsichtigter Start, tatsächlich erhöhter registrierter
Kontext sowie echte Duplicate-/Replay-Abweisung ohne VM-Anlage. Das Probeobjekt
des privaten Writers erhielt kein separates Dateilabel; geprüft wurde die Vererbung.

Der reguläre Koordinator bestätigt alle sieben Abschnitte:

| Abschnitt | Ergebnis |
|---|---|
| Ununterbrochener öffentlicher Windows-/Hyper-V-/SQL-2025-RTM-Neuaufbau mit beiden strikten TLS-Stacks | PASS |
| Neuer signierter V2-Export mit frischer Qualifikation über beide Stacks | PASS |
| Öffentlicher Reader über Datei und dieselben Exportbytes | PASS |
| Tatsächliche zusätzliche SQL-Consumer-Anmeldung mit erwarteter Build-/Verschlüsselungsantwort | PASS |
| Öffentlicher eigener Remove und Entfernung des temporären Exports | PASS |
| Separater frischer Koordinatoraudit: eigene VM abwesend, Run REMOVED | PASS |
| Fremde VM-/Switch-/Trust-/Verbraucherdatei-Baseline unverändert | PASS |

Der Worker bestätigt PASS_PENDING_AUDIT nach Cleanup; der reguläre Supervisor
danach PASS und REMOVED_AND_INDEPENDENTLY_AUDITED. Der Runner bestätigt PASS
und PASS_CLEANED. Die eigene erhöhte Aufgabe ist entfernt; eine frische
Controllerbeobachtung bestätigt deren Abwesenheit.

## Korrekturen und Grenzen

Der [frühere Teilnachweis](TLS_WINDOWS_PUBLIC_CREATE_ACCEPTANCE_2026-11-04.md)
bleibt mit Adapterfehler und FAIL-Koordinator unverändert erhalten. Der neue
Lauf mit dem korrigierten Indexer Connect Timeout belegt nun die dort fehlende
Anmeldung und den regulären Gesamtabschluss.

Der unabhängige Review schloss Manifest-Hash/Read-TOCTOU, unbekanntes Vorgängerende,
Request-unabhängigen Leaseabschluss, historische Replayabwehr und die explizite
Hard-Terminate-Einstellung. 67 fokussierte Offlineprüfungen und die gekoppelten
PowerShell-, Privacy-, Dokumentations-, Selektor- und Cleanupgates bestanden.

Die reale Schedulerdefinition zeigte Sekundenpräzision gegenüber einer
Bruchsekunden-Lease. Die Installation bindet beide Werte deshalb nun an denselben
UTC-Sekundenzeitpunkt. Diese kleine Präzisionskorrektur ist separat statisch und
unabhängig geprüft. Ein realer Ablauf nach zwei Stunden wurde nicht abgewartet:
die Aufgabe wurde zuvor regulär nach PASS entfernt. Es gab keine zweite
Installation oder Wiederholung des grünen Fachlaufs.

Geschlossen ist der gebundene Windows-TLS-Neuaufbau samt zusätzlichem Consumer
und regulärem Gesamtkoordinator für SQL 2025 RTM. Andere Identitäten, Dateisichten,
SQL-Versionen, Zertifikatserneuerung, Neustartwiederbindung, OS-/VM-Verlust des
Koordinators und die gesamte TLS-001-Matrix bleiben getrennt.
CA, Hosttrust, Konten, Gruppen und fremde Ressourcen wurden nicht verändert.
Kein Release und kein Tag wurden erzeugt.
