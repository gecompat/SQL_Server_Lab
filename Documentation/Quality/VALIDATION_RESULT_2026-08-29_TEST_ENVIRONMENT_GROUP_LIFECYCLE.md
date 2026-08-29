# Validierungsbericht: providerübergreifender Testgruppen-Lifecycle 2026-08-29

| Merkmal | Wert |
|---|---|
| Status | `NATIVE_TEST_GROUP_LIFECYCLE_PASS` |
| Testgruppe | 6 registrierte Mitglieder: 3 Docker/Linux, 3 Hyper-V/Windows |
| SQL-Versionen | 2019, 2022 und 2025 je Plattform |
| Scope | öffentlicher nicht-destruktiver Gruppen-Lifecycle und CMS-Synchronisierung |

## Geprüfte Aufrufe

```powershell
.\Tests\Integration\Invoke-TestEnvironmentAcceptance.ps1
.\Tests\Integration\Invoke-TestEnvironmentGroupLifecycle.ps1 -TimeoutSeconds 300
```

Die Abnahme verwendete ausschließlich die öffentlichen Gruppenaufrufe. Der
Runner stoppte nach dem initialen `READY`-Nachweis alle registrierten Mitglieder
und stellte sie in einem garantierten `finally` wieder vollständig bereit.

## SQL-Versionen und Funktionsprüfung

| Schlüssel | Erwartete Major-Version | Tatsächliche Major-Version |
|---|---:|---:|
| `LINUX_2019_LATEST` | 15 | 15 |
| `LINUX_2022_LATEST` | 16 | 16 |
| `LINUX_2025_LATEST` | 17 | 17 |
| `WINDOWS_2019_BASE` | 15 | 15 |
| `WINDOWS_2022_BASE` | 16 | 16 |
| `WINDOWS_2025_BASE` | 17 | 17 |

Jedes Ziel bestand zusätzlich einen isolierten Create-/Drop-Schreibtest. Der
CMS-Abgleich enthielt danach alle sechs Testziele konsistent.

## Gruppen-Lifecycle

- Initialer Gruppenstart: 6 von 6 Mitgliedern `READY`.
- Gruppenstopp: 6 von 6 Mitgliedern `STOPPED`; der Export meldete bewusst
  `INCOMPLETE`, und der CMS hielt die Testziele fail-closed zurück.
- Garantierter Wiederanlauf: 6 von 6 Mitgliedern `READY`; erwartete Major-
  Versionen 15, 16 und 17 wurden erneut geprüft.
- Abschlussstatus: `READY`; Registry- und Providerbindungen blieben unverändert.

Runs, Registrierungen, Secrets, Volumes und VHDX-Dateien wurden nicht gelöscht.
Die Evidence enthält keine Kennwörter oder vollständigen Connection Strings.
