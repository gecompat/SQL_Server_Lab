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
