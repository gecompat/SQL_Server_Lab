# Adapters/ – Project Adapter

Project Adapter koppeln konsumierende Repositories an den Lab-Core, ohne dass
diese Provider-, Lifecycle- oder State-Logik implementieren.

| Bereich | Inhalt |
|---|---|
| `Examples/synthetic-demo/` | synthetischer Beispieladapter für Vertrags- und Regressionstests |

## Vertrag

- Struktur: [`Schemas/project-adapter.schema.json`](../Schemas/project-adapter.schema.json), Version `0.1-draft`
- Prüfung ohne Mutation: `Test-SqlServerLabAdapter -Path <adapterverzeichnis>`
- Anwendung auf einen laufenden Run: `Install-SqlServerLabAdapter -Path <adapterverzeichnis> -RunId <id> -SaPassword <securestring>`

Version 0.1 führt ausschließlich relative T-SQL-Entrypoints (`.sql`) innerhalb
des Adapter-Roots aus. Pfad-Traversierung, absolute Pfade und unbekannte
Major-Vertragsversionen werden abgelehnt. `ApplyAdapter` hat keinen
Lifecycle-Seiteneffekt: Es werden keine Container, Volumes oder Runs erzeugt,
verändert oder entfernt.

Die Felder `sqlPackageCatalogs` und `defaultPackageRefs` sind für die
Package-Architektur des
[Projektintegrationsvertrags](../Documentation/Architecture/PROJECT_INTEGRATION_CONTRACT.md)
reserviert und werden noch nicht ausgewertet.

Die Priorisierung und die nächsten Arbeitspakete stehen in der
[Project-Adapter-Priorisierung](../Documentation/Project_Planning/PROJECT_ADAPTER_PRIORITIZATION.md).
