# Remote Windows Hyper-V Host – Backlog

## Status

Nicht implementiert. Die erste Workflow-Oberfläche steuert ausschließlich den
lokalen Windows-Hyper-V-Host. Unter Linux bleiben Hyper-V-Aktionen sichtbar,
aber deaktiviert.

## Ziel

Eine spätere Version soll einen ausdrücklich konfigurierten Windows-Hyper-V-Host
von einer lokalen SQL_Server_Lab-Installation aus verwalten können. Der
Container- und der Steuerungs-Host dürfen dabei Linux sein; die Hyper-V-Ressourcen
bleiben jedoch Eigentum des entfernten Windows-Hosts.

## Vorbedingungen

1. explizite Host-Registrierung mit FQDN und vertrauenswürdigem
   Authentifizierungsmodell;
2. getrennte State-, Scope- und Cleanup-Pfade pro Teilhost;
3. WinRM-/PowerShell-Remoting-Härtung und nachvollziehbare Berechtigungen;
4. keine Passwortpersistenz in UI, State oder Logs;
5. read-only Capability- und Erreichbarkeitsprüfung vor jeder Mutation;
6. keine automatische Ersatzplatzierung auf einen anderen Host.

## Nicht Teil der ersten Ausbaustufe

- automatische Remoting-Konfiguration;
- Übernahme lokaler VHDX ohne ausdrücklichen Transfervertrag;
- verteiltes L2-Netz oder Internet-Egress zwischen Hosts;
- implizites Credential Delegation beziehungsweise CredSSP.
