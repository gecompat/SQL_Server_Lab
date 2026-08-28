# Validierungsbericht: geschützter Testgruppen-Lifecycle 2026-08-28

| Merkmal | Wert |
|---|---|
| Status | `NATIVE_HYPERV_TEST_GROUP_LIFECYCLE_PASS` |
| Host | Key 18 |
| Testgruppe | 6 registrierte Mitglieder, davon 3 Linux und 3 Windows |
| Scope | öffentlicher nicht-destruktiver Windows-Gruppen-Lifecycle |

## Geprüfte Aufrufe

Die realen Aufrufe verwendeten keine Kennwörter oder Connection Strings als
Parameter und beschränkten die sichtbare Evidence auf aggregierte Statuswerte:

```powershell
Start-SqlServerLabAutomatedTestEnvironment -Force -WhatIf
Stop-SqlServerLabAutomatedTestEnvironment -Force -WhatIf

.\Tests\Integration\Invoke-TestEnvironmentGroupLifecycle.ps1 `
    -TimeoutSeconds 300
```

Der Integrationsrunner ruft intern exakt den öffentlichen Ablauf auf:

```powershell
Start-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false
Stop-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false
```

## Ergebnis

- Ausgangszustand: 3 Linux-Mitglieder `READY`, 3 Windows-Mitglieder `STOPPED`,
  Gesamtstatus `INCOMPLETE`.
- Beide `-WhatIf`-Aufrufe lieferten `CANCELLED` ohne Einzelaktion oder Export.
- Der reale Start brachte 3 von 3 Windows-Mitgliedern einschließlich ihrer
  vorhandenen SQL-Engine-Dienste in SQL-Readiness.
- Der unmittelbar danach live erzeugte Export meldete `groupStatus = READY`.
- Der garantierte Cleanup stoppte 3 von 3 Windows-Mitgliedern.
- Der anschließend live erzeugte Export meldete `groupStatus = INCOMPLETE`;
  alle 3 Windows-Einträge meldeten `runtimeStatus = STOPPED` und kein Eintrag
  wurde als `READY` freigegeben.
- Registrierungsbindungen und die Livezustände aller Linux-Mitglieder waren vor
  und nach dem Ablauf identisch.

## Restzustand

Die sechs Registrierungen, Runs, Secrets und VHDX-Dateien blieben erhalten.
Alle drei Linux-Mitglieder waren weiterhin `READY`; alle drei Windows-VMs waren
ausgeschaltet. Es wurden keine Runs, Datenbanken oder Providerressourcen
entfernt. Credentials, vollständige Connection Strings, Hostnamen, IP-Adressen,
VM-Namen und lokale State-Pfade wurden weder in die Evidence aufgenommen noch
als Repository-Artefakte gespeichert.
