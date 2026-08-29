# Mehrversions-External-Runtime-Validierungsbericht 2026-08-29

| Merkmal | Wert |
|---|---|
| Status | `NATIVE_EXTERNAL_RUNTIME_MULTI_VERSION_PASS` |
| Branch-Stand | `codex/fix-test-environment-availability`, nativer Abschlussstand `3ba7590` |
| Plattform | isolierte Linux-Hyper-V-Gäste, cgroup v1 |
| Provider | Docker und Podman, jeweils getrennte Evidence |
| SQL Server 2019 | Java |
| SQL Server 2025 | Python, R und Java |
| Vorheriger SQL-2022-Befund | [External-Runtime-Refresh-/Removal-Validierung 2026-08-28](VALIDATION_RESULT_2026-08-28.md) |

## Ergebnis

Der versionsbewusste External-Runtime-Pfad bestand die echten Produktpfade
für SQL Server 2019 und 2025 getrennt unter Docker und Podman. Zusammen mit dem
positiven SQL-2022-Befund ist damit jede katalogisierte Linux-Variante auf jeder
freigegebenen SQL-Hauptversion nativ belegt.

SQL Server 2019 bestand mit Java den Datenroundtrip, die Worker-Identitätsprobe,
den providergebundenen Neustart und den registrierten Cleanup. Der getrennte
2019-Pfad verwendet ausschließlich das passende Ubuntu-20.04-/SQL-2019-
Extensibilitypaket und baut keine inkompatiblen Python-/R-Stages.

SQL Server 2025 bestand mit Python, R und Java zusätzlich den atomaren Wechsel
von Python-only auf die Dreiersprachkombination, die eigentumsgebundene
Entfernung von Java sowie einen anschließenden Restart mit erneuten Python-/R-
Probes. SQL-Daten, Runtime-Receipts und Journalzustand blieben konsistent. Der
alte Container diente bis zum erfolgreichen State-Commit als Rollback-Ziel;
der Cleanup entfernte danach Container, Volumes, Testimages und Podman-Testnetz.

## Evidence

Die sanitisierten Evidence-Dateien liegen außerhalb des Repositorys unter
`D:\Lab_Base\Linux\ExternalRuntimeAcceptance\evidence`:

| SQL | Provider | Evidence-Datei | SHA-256 |
|---|---|---|---|
| 2019 | Docker | `external-runtime-2019-docker-c99ea030f88b45a9ba0e2c86e928ba96.json` | `04515595F172BE7367584528CF2238A7C6E1CFB0C09CE3E5272CBBB7216E990A` |
| 2019 | Podman | `external-runtime-2019-podman-c99ea030f88b45a9ba0e2c86e928ba96.json` | `E7D6E9AB24D456EB8A8603A093E844AA2FB259F335CCF5F098D529D61059D1B5` |
| 2025 | Docker | `external-runtime-2025-docker-c6b94b53590142e681d2db35680ebe3b.json` | `1768A86393BBF59E8B5B1C9CEF8B44AC2B45B0F62A7EEC3EDEC30840227FE856` |
| 2025 | Podman | `external-runtime-2025-podman-c6b94b53590142e681d2db35680ebe3b.json` | `5B60CD6BA2F0D58F1DAA8DF8A92748B0BA0C8A6EEDEC3266678CA15B8B5C13ED` |

Die isolierten Acceptance-VMs und alle test-eigenen Laufzeitressourcen wurden
über die registrierten Cleanup-Pfade entfernt. Die Evidence blieb erhalten.

## C#-Grenze

C# ist als sichtbarer `sql-csharp`-Intent für SQL Server 2019, 2022 und 2025
auf Hyper-V/Windows katalogisiert. Die Variante bleibt `PREVIEW` und vor jeder
Mutation gesperrt: Microsoft unterstützt die C# Language Extension nur unter
Windows, der einzige veröffentlichte Binärrelease zielt auf .NET 5, während der
aktuelle Quellstand .NET 8 verwendet. Ein aktueller hashgebundener Binärbuild
und eine native SQL-`dotnet`-Acceptance fehlen noch.
