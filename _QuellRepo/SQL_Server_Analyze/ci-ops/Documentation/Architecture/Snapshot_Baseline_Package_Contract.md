# Optionales Snapshot-/Baseline-Paket – Architekturvertrag

**Produktstatus des ausgelieferten Performance-Counter-Slice:** `IMPLEMENTED_ACTIONS_GATE`  
**Weitere Collector, Rollups und Scheduler-/Exportpakete:** `OPTIONAL_FUTURE`

## Zweck und Abgrenzung

Der Frameworkkern ist zustandslos. Das optionale Snapshot-/Baseline-Paket ergänzt eine ausdrücklich installierte lokale Persistenz für begrenzte Zeitreihen und technische Modulstatus. Es wird nicht durch `Install_All.sql` installiert und richtet keinen Scheduler ein.

Pro SQL-Server-Instanz wird eine eigene Snapshotdatenbank empfohlen. Die Frameworkdatenbank hält nur die Zielbindung; Evidenz wird in der separat installierten Zieldatenbank gespeichert.

## Öffentliche Procedures

| Procedure | Aufgabe |
|---|---|
| `[monitor].[USP_ConfigureSnapshotTarget]` | bindet Ziel, Collector-, Retention-, Budget- und Payloadpolicy |
| `[monitor].[USP_RunSnapshotCollectionCycle]` | führt genau einen begrenzten Collection Cycle aus |
| `[monitor].[USP_PurgeSnapshotData]` | entfernt abgelaufene Daten child-first in begrenzten Batches |

Alle drei Procedures stehen im vollständigen Analysis Catalog mit `PackageCode = SNAPSHOT_OPTIONAL`. `IsInstalled` zeigt, ob sie lokal vorhanden sind.

## Installation

Zwei gleichwertige Installationswege stehen zur Verfügung:

- SQLCMD: die beiden kanonischen `Install_SnapshotBaseline_*.sql`-Masterinstaller
  aus einer vollständigen Repositorykopie ausführen;
- Standalone: `Code/Install/Build-SnapshotBaselineInstallers.ps1` ausführen und
  danach die beiden eingebetteten Artefakte unter `Code/Install/generated/`
  ohne SQLCMD-Modus verwenden.

In beiden Fällen bleibt die Reihenfolge verbindlich:

1. separate Snapshotdatenbank anlegen;
2. Target-Installer in der ausdrücklich ausgewählten Snapshotdatenbank ausführen;
3. Framework-Installer nach Anpassung von `[DeineDatenbank]` in der Frameworkdatenbank ausführen;
4. Ziel und Policies mit `USP_ConfigureSnapshotTarget` setzen;
5. einen kontrollierten manuellen Collection Cycle prüfen;
6. erst danach einen externen Scheduler konfigurieren.

Das Paket erstellt keine Datenbank, Benutzer, Login, Berechtigung oder Scheduleraufgabe.

## Zielbindung

`monitor.SnapshotTargetConfiguration` enthält die aktive Datenbankbindung und typisierte Steuerwerte. Das Ziel muss lokal erreichbar, als Snapshotpaket erkennbar und versionskompatibel sein.

Eine Zielkonfiguration umfasst mindestens:

- Zieldatenbank und Aktivstatus;
- Collectoraktivierung und Intervall;
- Rohdaten-, Payload- und Rollupretention;
- Softbudget und Budgetreaktion;
- Purgeintervall und Batchgröße;
- Payloadfreigabe;
- Schedulerherkunft.

Unbekannte Zielobjekte oder inkompatible Paketversionen führen zu einem kontrollierten Status. Es wird keine fremde Tabelle als Snapshotziel verwendet.

## Zielschema

| Tabelle | Granularität und Rolle |
|---|---|
| `[snapshot].[PackageVersion]` | installierte Paket- und Schemaversion |
| `[snapshot].[RetentionPolicy]` | typisierte Retention je Datenklasse |
| `[snapshot].[CollectorPolicy]` | Aktivierung, Intervall, Limits und Payloadmodus je Collector |
| `[snapshot].[CaptureRun]` | ein Collection Cycle mit Zeit-, Reset- und Gesamtstatus |
| `[snapshot].[ModuleStatus]` | Status, Partialität und Evidenzgrenze je Laufmodul |
| `[snapshot].[Scope]` | technische Scopeidentität und Parentbezug |
| `[snapshot].[MetricDefinition]` | versionierter Metrikcode, Typ, Einheit und Bedeutung |
| `[snapshot].[MetricSample]` | genau ein typisierter Wert je Lauf, Scope und Metrik |
| `[snapshot].[PayloadSnapshot]` | optionaler komprimierter, hashgebundener Rohpayload |
| `[snapshot].[PurgeRun]` | technische Summen eines Retentionlaufs |

Die vollständigen Spalten und Stabilitätsgrenzen stehen in der [Objektreferenz](../Reference/Object_Reference.md).

## Collection-Vertrag

Pro Instanz darf höchstens ein Collection Cycle gleichzeitig laufen. Eine benannte Anwendungssperre wird ohne Wartezeit angefordert; Parallelaufrufe werden kontrolliert übersprungen.

Ein Lauf:

1. prüft Zielbindung, Paketversion und Policy;
2. prüft Fälligkeit oder ausdrückliches `RunEvenIfNotDue`;
3. legt `CaptureRun` mit Scheduler-, UTC- und Resetkontext an;
4. ruft nur aktivierte Collectorpfade auf;
5. schreibt Modulstatus auch bei partieller oder nicht verfügbarer Quelle;
6. schreibt nur typisierte, definierte Metriken;
7. schreibt Payload nur bei expliziter Aktivierung;
8. finalisiert Laufstatus und Summen.

Der vorhandene Collector erfasst begrenzte Performance-Counter-Evidenz. Weitere Frameworkmodule werden durch die Paketinstallation nicht automatisch persistiert.

## Zeit- und Resetmodell

Jeder Lauf verwendet UTC-Zeitgrenzen. `SqlServerStartTimeUtc` und `ResetEpochId` verhindern, dass kumulative Zähler über einen SQL-Server-Neustart hinweg als durchgehendes Delta interpretiert werden.

Metriken tragen ihren Werttyp und ihre Einheit in `MetricDefinition`. `MetricSample` speichert numerische, ganzzahlige oder textuelle Werte in getrennten Spalten. Ein partieller Read erzeugt keinen erfundenen Nullwert.

Ein Baselinevergleich ist nur zulässig, wenn Metrikcode, Vertragsversion, Scope, Einheit, Resetepoche und Qualitätsstatus kompatibel sind.

## Payloadvertrag

`PayloadEnabled = 0` ist der sichere Ausgangspunkt. Bei Aktivierung kann der vollständige versionierte JSON-Vertrag eines unterstützten Collectors komprimiert gespeichert werden.

Payloads besitzen:

- Capture- und Modulbezug;
- Format- und Vertragsversion;
- Kompressionstyp;
- Hash über den gespeicherten Inhalt;
- ursprüngliche Zeichenzahl;
- eigene Retention.

Ein Payload ist keine anonymisierte Darstellung. Seine Speicherung benötigt einen ausdrücklichen Datenschutz-, Berechtigungs-, Backup- und Löschvertrag.

## Retention

Retention ist je Datenklasse typisiert. `USP_PurgeSnapshotData` löscht nur Daten, deren Ablaufgrenze erreicht ist, und verarbeitet Abhängigkeiten child-first:

1. Payloads und Metriksamples;
2. Modulstatus;
3. Capture Runs;
4. nicht mehr referenzierte Scopes;
5. technische Purgesumme.

Batch- und Laufgrenzen verhindern einen unbeschränkten Einzeldelete. `@Force` hebt ausschließlich die Fälligkeitsprüfung nach dokumentiertem Vertrag auf; es erweitert nicht Ziel oder Datenklassen.

## Budgetmodell

`SoftBudgetMB` ist eine Betriebsgrenze, keine harte Dateigrößenbeschränkung. Die konfigurierte `BudgetAction` bestimmt die Reaktion, beispielsweise zuerst abgelaufene Daten zu purgen und weitere Collection zu stoppen, wenn das Budget weiterhin überschritten ist.

Ein Softbudget kann kurzfristig überschritten werden. Dateigröße, tatsächlich belegter Speicher, Logwachstum und freier Volumespeicher bleiben getrennte Betriebsmetriken.

## Fehler- und Partialitätsmodell

- Eine nicht lesbare Collectorquelle markiert das Modul partiell oder nicht verfügbar.
- Ein Modulfehler darf bereits erfolgreiche Module nicht als vollständig darstellen.
- Ein nicht fälliger Lauf ist kontrolliert übersprungen, nicht fehlgeschlagen.
- Ein Parallelaufruf ist kontrolliert übersprungen.
- Ein Ziel- oder Schemavertragsfehler verhindert fachliche Writes.
- Ein Purgefehler behält Summen und Fehlergrenze des bereits verarbeiteten Umfangs.

## Locking und Transaktionen

Die Zieldatenbank enthält echte persistente Writes. Collection verwendet kurze, begrenzte Inserts; Purge begrenzte child-first Deletes. Fremdschlüssel und Indizes können Zeilen- und Schlüsselsperren erzeugen. Die Betriebsdatenbank sollte für den Paketvertrag passend dimensioniert, gesichert und überwacht werden.

Lange Transaktionen über Quelllesung und gesamten Collection Cycle werden vermieden. Modulstatus bewahrt Teilfortschritt und Aussagegrenze.

## Datenschutz und Sicherheit

Die Snapshotdatenbank kann reale Laufzeitwerte, Namen, technische Identitäten und bei freigegebenem Payload vollständige JSON-Evidenz enthalten. Das Framework erweitert den Quellsicherheitskontext nicht und sammelt keine Kennwörter oder Schlüsselmaterialien.

Erforderlich sind:

- minimal berechtigter Collector;
- getrennte Rechte auf Framework- und Snapshotdatenbank;
- definierte Retention und Löschung;
- passende Backup- und Verschlüsselungsvorgaben;
- keine Payloadaktivierung ohne fachlichen Bedarf;
- kontrollierte Exporte und Weiterverarbeitung.

Siehe [Datenschutz und Laufzeitausgaben](Runtime_Data_Privacy.md).

## Nichtziele

- kein zentraler Fleet- oder Cloudservice;
- kein automatischer Scheduler;
- keine automatische Anonymisierung;
- keine persistente Vollkopie aller Frameworkresultsets;
- keine autonome Schwellwertaktion oder Konfigurationsänderung;
- kein Ersatz für Query Store, Extended Events oder reguläre Monitoringplattformen.

## Weiterführende Dokumentation

- [Betriebsleitfaden](../Operations/Snapshot_Baseline_Operations.md)
- [Installation](../Reference/Installation.md)
- [Procedure-Seite `USP_ConfigureSnapshotTarget`](../Analysis_Guides/Procedures/USP_ConfigureSnapshotTarget.md)
- [Procedure-Seite `USP_RunSnapshotCollectionCycle`](../Analysis_Guides/Procedures/USP_RunSnapshotCollectionCycle.md)
- [Procedure-Seite `USP_PurgeSnapshotData`](../Analysis_Guides/Procedures/USP_PurgeSnapshotData.md)
