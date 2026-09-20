# Interner Container-Memory-Puls

`Private/ContainerMemoryFault.ps1` ergänzt FLT-811/FLT-812 um das feste private
Profil `container.memory-limit`: Ein frischer operationseigener Linux-SQL-2025-
Testcontainer wechselt von 3072 MiB auf 2560 MiB und anschließend zurück.
Öffentliche API, freie Commands, SCN und Reconcile gehören nicht zum Slice.
Die unveränderten Transport-, Pfad-, Hash- und HMAC-Helfer aus
`ContainerCpuFault.ps1` werden wiederverwendet; Snapshot, Journal, SQL-Probe
und Memory-Rücknahme sind eigenständige Verträge.

Vollständige Container-ID, Run-, Scope-, Instanz-, Provider- und vor Erstellung
erzeugte Testoperationslabels sowie `lifecycle=test` müssen live übereinstimmen.
Schutz-, Reservierungs-, Testumgebungs-, Umgebungsgruppen- und Supporting-
Labels blockieren das Ziel. Erstellung nach dem gebundenen Zeitpunkt und ein
30-Minuten-Fenster begrenzen den frischen Aufruf; Resume bleibt später möglich.
Es gibt keine globale Run-Inventur. Lokaler Docker-Endpunkt beziehungsweise
lokale Podman-Connection sind gepinnt, Runtimeidentität wird vor Apply und
Restore geprüft. Inspect liest kein `Config.Env`.

Die Baseline enthält sieben exakte Rohfelder: `Memory`, `MemorySwap`,
`MemoryReservation`, `MemorySwappiness`, `KernelMemory`, `KernelMemoryTCP` und
`OomKillDisable`. Akzeptiert werden ausschließlich 3221225472 Bytes Memory,
6442450944 Bytes MemorySwap, Reservation 0 und OomKillDisable false.
Bei zusätzlich live bestätigtem cgroup v2 darf OomKillDisable null bleiben:
[Docker dokumentiert](https://docs.docker.com/engine/containers/runmetrics/),
dass OOM-disable dort verworfen wird. Die cgroup-Version wird mitjournalisiert
und bei Apply/Restore erneut verglichen; unbekannte Versionen sowie null bei
cgroup v1 bleiben ausgeschlossen. Null wird nicht zu false normalisiert.
Kernel-Felder dürfen null oder 0, Swappiness null, -1 oder 0 sein. Null wird
nicht als numerischer Default umgedeutet. Andere, unbegrenzte oder fehlende
Pflichtwerte blockieren die Mutation. Apply und Restore setzen Memory mit
explizit unverändertem MemorySwap. Alle sieben Felder, Image-ID und
Erstellungszeitpunkt werden exakt verglichen; unbekannte Drift wird nicht
überschrieben. Dies ist eine enge Untermenge der
[Docker-Update-Optionen](https://docs.docker.com/reference/cli/docker/container/update/)
und [Podman-Update-Optionen](https://docs.podman.io/en/latest/markdown/podman-update.1.html).

Vor Apply wird die Baseline mit Restore-Intent unter exklusivem Lock atomar
gespeichert (temporäre eigene Datei, Flush, Rename). HMAC-SHA-256 authentifiziert
das Journal mit einem separat vom Aufrufer erhaltenen 32-Byte-Schlüssel.
Schema, Zielhash, Baseline und Ownership werden bei Resume erneut geprüft.
Schlüssel, Journal und Runtimewerte bleiben lokal außerhalb von Git.
Gleichberechtigter lokaler Zugriff mit Schlüssel und Replay älterer
authentifizierter Journale liegen außerhalb dieser Vertrauensgrenze.

`AppliedVerified` wird nach exakter Postcondition vor SQL-Beobachtung und
Cleanup dauerhaft gespeichert. Resume aktiviert niemals erneut; der Primärlauf
bleibt nach Abbruch `INTERRUPTED`. Höchstens drei Cleanupversuche werden vorab
dauerhaft gezählt. Primär-/Cleanupstatus sowie `LimitRestoredVerified` und
`SqlRestoredVerified` bleiben getrennt. Ein identischer eigener gestoppter
Container wird ohne automatischen Start zur Limit-Rücknahme zugelassen.
Die Limit-Postcondition wird vor der SQL-Prüfung separat persistiert. Gestopptes
oder unbestätigtes SQL bleibt `RECOVERY_REQUIRED` auch bei exakten Limits.
Ein externer autorisierter Start kann einen weiteren SQL-Verifikationsversuch
ermöglichen. Abgeschlossene Journale bleiben bei Resume bytegleich.

Docker bestätigt die exakte Limit-Rücknahme auch am gestoppten Container.
Podman 6.0.2 lieferte dort nach Update weiterhin die Applied-Werte in Inspect;
`LimitRestoredVerified` und `SqlRestoredVerified` bleiben deshalb false und
der Vorgang bleibt `RECOVERY_REQUIRED`. Ein erfolgreicher CLI-Exit genügt
nicht als Nachweis. Der [Podman-Quellcode dieser Version](https://github.com/containers/podman/blob/v6.0.2/libpod/container_internal.go)
schreibt die Konfiguration in die Datenbank, aktualisiert die OCI-Spec aber
nur für Created/Running/Paused. Das erklärt möglicherweise die Projektion;
eine intern erfolgte Rücknahme wird daraus nicht als validiert abgeleitet.
Der Slice startet, ersetzt oder bereinigt den Container nicht als Ausweichweg.
Weitere Versuche bleiben auf insgesamt drei begrenzt. Eine Garantie der
gestoppten Podman-Rücknahme besteht nicht.

Apply, Applied-Inspect und SQL-Beobachtung haben je eine Sekunde native
Wartezeit; die Arbeitsdeadline beträgt fünf Sekunden ohne Haltephase.
Cleanup hat eigene begrenzte Aufrufe. Host-/Engineausfall, harter Abbruch und
blockierende Dateisysteme erlauben keine garantierte Rücknahmefrist.
Nur eine private Fixture pausiert nach Applied-Checkpoint höchstens 30 Sekunden.
Die feste Tools18-SQL-Probe prüft Major 17, Engine Edition und `master` ONLINE;
das SA-Secret steht weder in CLI-Argumenten noch im Journal.

Die Offline-Suite prüft Rohwerte, Schutz-/Fremdziele, Drift, Cancellation,
Apply-/Restore-/SQL-Fehler, gestoppte Ziele, HMAC, Lock, drei Versuche und echte
harte Kindprozessabbrüche. Der native Runner erstellt genau einen eigenen
SQL-2025-Run im temporären State-Root und entfernt dessen Container und Volume.
Normaler Puls und `-HardInterrupt` sind je Provider getrennte Nachweise.
`-HardInterrupt -StopAfterInterrupt` stoppt ausschließlich den frisch erzeugten
eigenen Container nach bestätigtem Kindprozessende. Bei Docker erwartet der
Runner exakte Limit-Rücknahme, bei Podman die unverifizierte Rücknahmegrenze.
Beide bleiben gestoppt, führen keine SQL-Probe aus und bleiben nach drei
Versuchen `RECOVERY_REQUIRED`. Anschließend entfernt nur der eigene Run-Cleanup
die disposable Ressourcen. Ein bestandener Test belegt diese Klassifizierung,
nicht erfolgreiche SQL-Wiederherstellung.
Am 2026-09-19 bestanden Docker und Podman getrennt den normalen SQL-2025-Puls
und den Hard-Interrupt mit laufendem Restoreziel: exakter Rohrestore, SQL-
Readiness, `INTERRUPTED` nach Abbruch, keine Reaktivierung und bytegleiches
terminales Journal. Beide gestoppten Fälle bestanden die oben getrennten
Erwartungen einschließlich drei begrenzter Versuche, ohne Start oder SQL-Probe.
Jeder Lauf entfernte ausschließlich seinen eigenen Container und sein Volume
in zwei Cleanup-Schritten ohne Fehler oder verbleibende Ressourcen.

Die erste Docker-Vorprüfung blockierte vor Memory-Mutation wegen des null-
OOM-Felds; dessen cgroup-v2-Bindung wurde anschließend offline und nativ belegt.
Die ersten gestoppten Podman-Läufe erfüllten die ursprünglich erwartete exakte
Rücknahme nicht und wurden vollständig bereinigt. Die Diagnose führte zur
expliziten unverifizierten Recoverygrenze, nicht zur Umdeutung in erfolgreichen
Restore. Die angepasste native Abnahme bestätigt genau diese Grenze.
Hyper-V, weitere Versionen, OOM-Erzeugung, Performancewirkung und allgemeine
Memory-Faults sind nicht Bestandteil dieses Slice.
