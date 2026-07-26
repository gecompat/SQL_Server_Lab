# Quellenbasis der SQL-Server-Runtime-Matrix

| Merkmal | Wert |
|---|---|
| Status | `VALIDATED` |
| Stand | 2026-07-24 |
| Geltungsbereich | SQL Server 2019, 2022 und 2025 in offiziellen Linux-Containern |

## Primärquellen

| ID | Quelle | Aussagebezug |
|---|---|---|
| `MATRIXSRC-001` | [Quickstart: Run SQL Server Linux container images with Docker](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/quickstart-install-docker?view=sql-server-ver17) | offizielle Tags `2019-latest`, `2022-latest`, `2025-latest`; `MSSQL_SA_PASSWORD`; Developer Edition; Mindestbedarf von 2 GB RAM und 2 GB Datenträgerspeicher; Bereitschaftsmeldung |
| `MATRIXSRC-002` | [Deploy and connect to SQL Server Linux containers](https://learn.microsoft.com/en-us/sql/linux/containers/deploy?view=sql-server-ver17) | unterstützte Linux-x64-Containerplattform, Verbindungswege und ephemere Containerverwendung |
| `MATRIXSRC-003` | [Configure and customize SQL Server Docker containers](https://learn.microsoft.com/en-us/sql/linux/containers/configure?view=sql-server-ver17) | Verhalten von Daten-, Log- und Persistenzpfaden; Begründung für den volumenlosen Wegwerfcontainer der Matrix |
| `MATRIXSRC-004` | [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) | jeder Standardjob läuft auf einer neuen VM; Ressourcen- und Architekturgrenzen des Hosted Runners |
| `MATRIXSRC-005` | [GitHub Actions runner images](https://github.com/actions/runner-images) | `ubuntu-latest` als x64-Ubuntu-Image und Docker als vorinstalliertes Werkzeug |

## Technische Entscheidungen

Die Matrix verwendet je Job genau einen SQL-Server-Container. Dadurch konkurrieren die drei Versionen nicht innerhalb desselben Arbeitsspeichers. Es wird weder ein Host-Port veröffentlicht noch ein Volume eingebunden. Der Zugriff erfolgt ausschließlich über `docker exec` und das im Container enthaltene `sqlcmd`.

Die Tags `*-latest` prüfen fortlaufend den aktuellen von Microsoft ausgelieferten Containerstand. Dies ist für Kompatibilitäts- und Regressionsprüfung geeignet, ersetzt jedoch keine Release-Evidenz mit festem Image-Digest oder dokumentiertem CU-Stand.

Das ephemere SA-Kennwort wird pro Workflowlauf erzeugt, durch GitHub Actions maskiert und ausschließlich über Umgebungsvariablen übergeben. Es wird nicht als Repositoryinhalt, Workflow-Artefakt oder Kommandozeilenparameter gespeichert.

## Gültigkeitsgrenze

Die Matrix prüft SQL Server auf Linux und x86-64. Windows-spezifische Funktionen, Editionseffekte außerhalb Developer Edition und OS-nahe Diagnosepfade benötigen separate Testprofile. Ein erfolgreicher Matrixlauf bestätigt die getesteten Framework-Verträge und nicht die allgemeine Performancegleichheit unterschiedlicher SQL-Server-Versionen.
