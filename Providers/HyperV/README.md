# Providers/HyperV/ – Hyper-V-Provider (geplant)

Status: **Noch nicht implementiert.**

Geplant fuer Szenarien die einen Windows-Gast erfordern:
- Windows Authentication (Domain Controller)
- SQL Server Agent (nativer Windows-Dienst)
- WSFC / Failover Cluster Instances
- Availability Groups

### Voraussetzungen

- Windows 10/11 Pro oder Windows Server
- Hyper-V Feature aktiviert (`Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V`)
- Admin-Rechte

### Interface (geplant)

- `Test-HyperVAvailable` → Get-VM verfuegbar?
- `New-HyperVInstance` → VM + SQL Server installieren
- `Get-HyperVInstanceStatus` → VM + SQL Ready?
- `Start/Stop/Remove-HyperVInstance`

### Aufsetzpunkte und Testdatenbanken

Hyper-V verwendet den providerübergreifenden Artifact-, Trust-, Verification-
und Baseline-Vertrag aus
[`SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md`](../../Documentation/Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md).
Die dort beschriebenen Funktionen sind noch nicht implementiert.

Geplante wiederverwendbare Aufsetzpunkte:

1. generalisierte OS-Evaluation als Parent-VHDX;
2. konfiguriertes Gastbetriebssystem mit Integration und Baseline-Patches;
3. SQL Server in definierter Version, Edition und Featuremenge;
4. verifizierte SQL-Konfiguration als Lab-Basis;
5. Szenariozustand nur bei klarem Wiederherstellungsnutzen und eindeutiger
   Invalidierungsregel.

Testdatenbanken und zusätzliche Software werden nach Möglichkeit als getrennte
Deployment- beziehungsweise Database-Artifacts angewendet. Testdatenbanken
werden standardmäßig nicht dauerhaft in ein allgemeines OS-Parent-Image
eingebettet. Das Manifest beziehungsweise der Bound Plan wählt deterministisch
die beste kompatible, verifizierte Ausgangsbasis; fehlt sie, beginnt der Ablauf
beim nächsttieferen gültigen Aufsetzpunkt.

