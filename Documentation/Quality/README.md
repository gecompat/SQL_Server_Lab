# Quality-Dokumentation

| Dokument | Zweck |
|---|---|
| [COST_EFFICIENT_DEVELOPMENT.md](COST_EFFICIENT_DEVELOPMENT.md) | verbindliche Local-first-, Log-, Teststufen- und Kontextkostenstrategie |
| [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) | verbindliche Grenzen des aktuellen Runtimepfads |
| [LOCAL_VALIDATION_STRATEGY.md](LOCAL_VALIDATION_STRATEGY.md) | tatsächlich verfügbare lokale Prüfpfade und verbleibende Testlücken |
| [TLS_UI_AUTHENTICATED_CREATION_ACCEPTANCE_2026-10-24.md](TLS_UI_AUTHENTICATED_CREATION_ACCEPTANCE_2026-10-24.md) | kompakte Windows-/Docker-/Podman-SQL-2025-CU9-Erstellung im Browser mit strikter Liveprüfung, Wiederbindung und eigenem UI-Remove; ursprüngliche FAILs erhalten |
| [TLS_UI_AUTHENTICATED_PROFILES_ACCEPTANCE_2026-10-24.md](TLS_UI_AUTHENTICATED_PROFILES_ACCEPTANCE_2026-10-24.md) | zusätzliche kompakte authentifizierte Browser-Erstellung für SQL 2019 CU32 und 2022 CU27, jeweils Docker und Podman, strikte Clients und eigener Cleanup |
| [TLS_UI_RESOURCE_PROFILES_ACCEPTANCE_2026-10-24.md](TLS_UI_RESOURCE_PROFILES_ACCEPTANCE_2026-10-24.md) | Standard-/Performanceprofile beider Erstellungsmodi für Windows, Docker/Podman und SQL 2019/2022/2025; 24 Laufzeitbelege, ursprünglicher Controller-FAIL mit getrenntem passivem Abschluss erhalten |
| [TLS_UI_LIVE_RESOURCE_PROFILES_ACCEPTANCE_2026-10-25.md](TLS_UI_LIVE_RESOURCE_PROFILES_ACCEPTANCE_2026-10-25.md) | separate Liveaktion bestehender Labkarten mit Standard/Performance, Docker/Podman und SQL 2019/2022/2025; zwölf positive Zellen und drei unveränderte FAILs, alle 15 Labs entfernt |
| [TLS_HYPERV_NATIVE_ACCEPTANCE_2026-10-20.md](TLS_HYPERV_NATIVE_ACCEPTANCE_2026-10-20.md) | bestandene native Windows-/Hyper-V-SQL-2025-RTM-Referenz mit Ablauf, Erneuerung, neuem Boot und eigenem TLS-Cleanup |
| [CLI_ACCEPTANCE_MATRIX.md](CLI_ACCEPTANCE_MATRIX.md) | providergetrennte reale CLI-, Sample-, Storage- und Ressourcenabnahme |
| [LOCAL_READINESS_CHECKLIST.md](LOCAL_READINESS_CHECKLIST.md) | präzise Vor-Push- und Vor-Release-Validierungsreihenfolge |
| [REPOSITORY_CONTINUITY_RUNBOOK.md](REPOSITORY_CONTINUITY_RUNBOOK.md) | verbindlicher GitHub-Actions-Ausfall-, Break-Glass- und Nachholvalidierungsablauf |
| [PRIVACY_AND_ARTIFACT_SECURITY.md](PRIVACY_AND_ARTIFACT_SECURITY.md) | Privacy-, Daten- und Artefaktsicherheitsvertrag |
| [VALIDATION_RESULT_2026-09-02.md](VALIDATION_RESULT_2026-09-02.md) | native Docker-/Podman-Abnahme des PSR-005-Mehr-Volume-Pfads, zentrale Host-Tool-Auflösung und revisionsgeschützte Hyper-V-Instanzstore-Writer |
| [VALIDATION_RESULT_2026-08-28.md](VALIDATION_RESULT_2026-08-28.md) | native Docker-/Podman-Abnahme von External-Runtime-Refresh, Java-Removal, Persistenz und Cleanup |
| [VALIDATION_RESULT_2026-08-27.md](VALIDATION_RESULT_2026-08-27.md) | aktueller lokaler und CI-gestützter vollständiger CLI- und Provider-Validierungsbefund |
| [VALIDATION_RESULT_2026-08-20.md](VALIDATION_RESULT_2026-08-20.md) | historischer Validierungsbefund der providerneutralen Batch-Abnahme |
| [VALIDATION_RESULT_2026-08-12.md](VALIDATION_RESULT_2026-08-12.md) | historischer Validierungsbefund vor der providerneutralen Batch-Abnahme |
| [DOCUMENTATION_CONSISTENCY_REPAIR_2026-07-27.md](DOCUMENTATION_CONSISTENCY_REPAIR_2026-07-27.md) | Umfang und Validierungsstatus der Dokumentations- und Vertragsbereinigung |

Die Root-README ist der operative Einstieg. Diese Quality-Dokumente beschreiben Grenzen, Prüfung und Sicherheitsregeln vertiefend.
