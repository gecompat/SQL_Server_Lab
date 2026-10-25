# Development/ – Entwicklungsdokumentation

| Dokument | Inhalt |
|---|---|
| [DEVELOPMENT_AND_TEST_SETUP_WINDOWS.md](DEVELOPMENT_AND_TEST_SETUP_WINDOWS.md) | Schrittweise Einrichtung für Codeentwicklung, statische Tests, Provider-Smoke-Tests und Self-hosted Runner unter Windows |
| [DEVELOPMENT_AND_TEST_SETUP_LINUX.md](DEVELOPMENT_AND_TEST_SETUP_LINUX.md) | Linux-Entwicklung, Provider-Smoke-Tests und Self-hosted Runner unter Ubuntu |
| [Testressourcen und Cleanup](../Architecture/OWNED_HOST_CI_ISOLATION.md#ressourcen-und-cleanup) | Eigene CI-Ressourcen, lokale Dateifixtures, Cleanupfehler und Wiederanlauf nach einem abgebrochenen Runner |

Der statische Transfer-Executorvertrag prüft auch sein verschachteltes
Planjournal. Dafür werden ausschließlich die beiden bekannten lokalen
Repositoryschemas im Speicher zusammengesetzt; `Test-Json` erhält ein
geschlossenes Schema ohne externes Nachladen. Damit bleibt die Prüfung auch
mit der [expliziten Fetch-Sperre neuer PowerShell-Versionen](https://github.com/PowerShell/PowerShell/pull/28205)
ausführbar. URI-Referenzen, Ressourcen-IDs, dynamische Referenzen und fremde
Dialekte werden vor der Validierung abgewiesen. Der zusätzliche Nachlauf
betrifft diesen neu erkannten Integrationsfehler, nicht eine erneute Abnahme
unveränderter Cleanupgrenzen.
Die vier exakten Pfade des weiterhin blockierten Legacy-Planvertrags wählen
seine statische Suite, Pester und Analyzer. Die ausführende Runtime, native
Acceptance und unbekannte Produktpfade behalten ihre bisherigen Gates.
Damit startet die lokale Schemakomposition keine zusätzliche Hyper-V- oder
Adapterprovisionierung; die Docker-/Podman-/Mixed-Gates dieses Cleanup-Diffs
bleiben erforderlich. Die zusätzliche Auswahlprüfung kontrolliert alle vier
Einzelpfade; vorhandene Vereinigungs- und Fallbackprüfungen bleiben erhalten.
