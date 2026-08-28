# External-Runtime-Refresh-Validierungsbericht 2026-08-28

| Merkmal | Wert |
|---|---|
| Status | `NATIVE_EXTERNAL_RUNTIME_REFRESH_PASS` |
| Branch-Stand | `agent/external-language-wave8b`, nativer Stand `48bff05` |
| Plattform | isolierter Ubuntu-22.04-Hyper-V-Gast, cgroup v1 |
| Provider | Docker und Podman |
| SQL-Referenz | SQL Server 2022 External Runtimes |
| Image-Rezept | Version 5 |
| Vorheriger Gesamtbefund | [CLI- und Provider-Validierung 2026-08-27](VALIDATION_RESULT_2026-08-27.md) |

## Ergebnis

Der additive External-Runtime-Refresh bestand den echten Produktpfad getrennt
für Docker und Podman. Jeder positive Lauf provisionierte zunächst eine
Python-only-Instanz, änderte anschließend das Zielmanifest auf Python, R und
Java und führte den öffentlichen Reconcile-Plan samt Apply aus.

Dieser fokussierte Nachweis erweitert den vollständigen CLI-/Providerbefund vom
2026-08-27. Der dortige Hyper-V-/Windows-Befund wurde nicht erneut ausgeführt
und wird in der Repository-Map ausdrücklich als übernommener Befund bezeichnet.

Beide Provider bestätigten:

- resolvergebundene Klassifizierung `recreate` mit genau einer Aktion;
- Build des neuen content-addressierten Derived Image vor der Mutation;
- journalgebundenes Umbenennen des alten und Erstellen des neuen Containers;
- SQL-Readiness und echte Python-, R- und Java-Postconditions;
- atomaren Connection-/Desired-State-Commit und Journalstatus `COMPLETED`;
- drei persistierte Receipts mit Status `EXTENSIONS_READY_RUN`;
- erfolgreichen providergebundenen Restart mit erneuten Sprachprobes;
- scopegebundenes Run-Cleanup bei zunächst erhaltenem alten und neuen Image;
- explizites Entfernen beider test-eigenen Images und des Podman-Testnetzes.

## Charakterisierung und Korrekturen

Die erste native Python-only-Charakterisierung deckte auf, dass
`revoscalepy` die Laufzeit `libgomp.so.1` benötigt. Zuvor war diese nur
indirekt in kombinierten R-Images vorhanden. Rezept 5 bindet das offizielle
Ubuntu-22.04-Paket `libgomp1` deshalb separat per Version und SHA-256, extrahiert
es ohne Compiler in einen eigenen OCI-Stage und kopiert dieselben Runtimebytes
in Python- und R-Zielstages.

Der erste Build dieser Korrektur zeigte außerdem, dass `dpkg-deb -x` den
angegebenen Zielwurzelordner nicht selbst erzeugt. Der Containervertrag erstellt
den eng begrenzten Extraktionspfad nun ausdrücklich; der fokussierte statische
Image-Vertrag deckt diese Voraussetzung ab.

Ein erster Podman-Probeversuch traf vor dem Refresh einmalig SQL-Fehler
`Msg 39011` bei der LaunchPad-Kommunikation. Cleanup des fehlgeschlagenen Runs
war vollständig. Die unveränderte, gezielte Wiederholung im erhaltenen Gast
bestand anschließend Provisionierung, Refresh, Restart, alle drei Sprachprobes
und Cleanup. Dies wird als transiente Provider-/LaunchPad-Charakterisierung und
nicht als reproduzierter Produktfehler dokumentiert.

## Evidence und Cleanup

Die sanitisierten Evidence-Dokumente meldeten für beide Provider `PASS`,
Refresh `SUCCEEDED`, Journal `COMPLETED`, cgroup-Version `1` und drei bereite
Sprachreceipts. Host-, Runtime- und Diagnosedaten bleiben gemäß Repositoryregel
außerhalb der Versionsverwaltung. Die isolierte Diagnose-VM und ihr run-eigenes
Verzeichnis wurden nach Sicherung und Prüfung der Evidence vollständig entfernt.

## Verbleibende Grenze

Dieser Nachweis gilt für additive Runtime-Anforderungen in bereits laufenden,
verifizierten SQL-Server-2022-Docker-/Podman-Runs. Runtime-Entfernung, freie
Packagewechsel, der allgemeine Hyper-V-Softwarepfad sowie Hyper-V-Artifact-
Refresh und automatische Gastumschaltung bleiben außerhalb dieses Slices.
