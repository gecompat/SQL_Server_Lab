# SQL Server CU Watch (SQL_Server_Lab)

## Ziel
Der Agent soll dem Projekt Bescheid geben, sobald die aktuelle
Versionskatalogdatei `Catalogs/sql-server-versions.json` gegenüber den
Microsoft-CU-Quellen hinterherhinkt.

Er ist kein autonomer Installations-Agent; die Bereitstellung von
Windows-ISO/EXE liegt weiterhin beim Betreiber.

## Scope
- Geltung nur für dieses Repo (`SQL_Server_Lab`) und dessen Katalogdatei.
- Der Standardlauf prüft ausschließlich Katalogeinträge mit Status `SUPPORTED`.
  Veraltete oder anderweitig nicht aktive Versionen werden nur bei expliziter
  Angabe über `-Version` ausgewertet.
- Keine Risiko-Matrix nach Prod/Test/Dev oder Sicherheitskategorien.
- Keine hypothetische Statusauswertung: nur belastbare Delta-Erkennung.

## Autoritative Inputs
1. `Catalogs/sql-server-versions.json`
2. [Microsoft: Download and install the latest SQL Server updates](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates)
3. `Tools/Get-SqlServerCuStatus.ps1`
4. `Public/Get-SqlServerLabWorkflow.ps1` (für Slot-Zustand)

## Ausführung
- Standard:
```powershell
.\Tools\Get-SqlServerCuStatus.ps1
```
- Optional als JSON:
```powershell
.\Tools\Get-SqlServerCuStatus.ps1 -AsJson
```

## Was als "neu" gilt
- Neue CU/Builds, die in den Microsoft-Quellen vorhanden sind, aber nicht im
  aktuellen Katalogeintrag stehen.
- `CU_MONITORING_BACKLOG.md` ist der Implementierungsstatus für das gesamte
  CU-Monitoring: aktuell auf `DEFERRED`.

## Erwartetes Resultat des Agents
1. `NEU`: es gibt Kataloglücken, welche Versionen betroffen sind.
2. `NO CHANGE`: Katalog ist aktuell.
3. `UNCLEAR`: Quellverfügbarkeit oder Prüfung war nicht eindeutig.

## Zusätzliche Framework-Hinweise
- Wenn `TemplatePool.AvailableTemplates` im Workflow-Status auf `0`
  oder sehr niedrig ist, soll der Agent auf fehlende Slot-Kapazität hinweisen.
- Die konkrete Slot-Generierung bleibt operativ und manuell/CLI-basiert.

## Ausgabeformat (Pflicht)
- **A Status** (`NEW` / `NO CHANGE` / `UNCLEAR`)
- **B** fehlende CU-Einträge je SQL-Version (Version, erwarteter CU, KB, Datum/Quelle)
- **C** Framework-Hinweis (`TemplatePool`/Slots)
- **D** Nächster manueller Schritt

## Prüfkriterium bei Unsicherheit
- Bei fehlender Quelle, nicht lesbarem Katalog oder zweifelhafter Zuordnung:
  `UNCLEAR` + genaue Lücke benennen.
