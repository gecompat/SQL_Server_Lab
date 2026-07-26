# Resultset- und Statuskonventionen

Diese Konventionen erleichtern die manuelle Auswertung und eine spätere gezielte Webfrontend-Anbindung. Sie bilden kein separates Vertragsframework.

## Statusinformationen

Wo vorhanden, enthält das erste Resultset insbesondere:

- `StatusCode`
- `IsPartial`
- `ErrorNumber`
- `ErrorMessage`
- `Detail`

`StatusCode` wird über `monitor.VW_ModuleStatusCatalog` erläutert.

## Analysis Navigator

`monitor.USP_AnalysisNavigator` besitzt genau ein benanntes Fachresultset `navigation`. `RAW` liefert davor den Modulstatus; `CONSOLE` rendert nur die priorisierte Fachansicht; `TABLE` exportiert ausschließlich `navigation`; JSON verwendet `meta` und `navigation`. Das Resultset enthält Katalogempfehlungen, keine ausgeführten Diagnosebefunde. Der vollständige Spalten- und Rankingvertrag steht in der [Navigator-Referenz](Analysis_Navigator.md).

## Stabilisierte Einzelmodule

Die stabilisierten Einzelmodule liefern den Status als erstes Resultset. Für den Orchestrator stehen zusätzlich OUTPUT-Parameter zur Verfügung, damit intern abgefangene Child-Fehler nicht als Erfolg erscheinen.

## Historisch abweichende Module

Einige ältere Module besitzen historisch unterschiedliche Resultsets. Für die Ad-hoc-Nutzung ist diese Abweichung dokumentiert. Ein technischer Verbraucher bindet nur die tatsächlich benötigten Orchestrator-Procedures fest an und verwendet deren dokumentierte Resultset-Reihenfolge.

<!-- BEGIN AUSGABE_VERTRAG -->
## Frameworkweiter Ausgabevertrag

`CONSOLE` ist der Default, weil die Procedures primär für Ad-hoc-Analysen verwendet werden. Die erste Spalte jedes fachlichen Konsolen-Resultsets bezeichnet redundant dessen Inhalt. Formatierungen und gezielt an fachlichen Blockgrenzen wiederholte Schlüssel sind ausschließlich Darstellungshilfen.

`RAW` ist der stabile, nicht formatierte Vertrag für technische Weiterverarbeitung und muss ausdrücklich angefordert werden. `NONE` unterdrückt fachliche Resultsets, insbesondere für JSON-only-Aufrufe.

Textuelle Steuerwerte wie `console`, `RAW` oder `None` werden getrimmt und case-insensitiv normalisiert. SQL-Identifier und fachliche Namen bleiben unter `SQL_Latin1_General_CP1_CS_AS` exakt case-sensitiv.
<!-- END AUSGABE_VERTRAG -->

<!-- BEGIN STATEMENT_RESULTSETS -->
## SQL-Text- und Statementkontext

Für laufende Requests wird zwischen folgenden Informationen unterschieden:

- aktuelles Statement: exakt aus `statement_start_offset` und `statement_end_offset` extrahiert;
- Batch-/Modultext: vollständiger Text des SQL Handles, optional;
- Modulkontext: Datenbank, Schema, Objekt, Typ und vollständig qualifizierter Name;
- Input Buffer: ursprünglich übergebener Batch-, RPC- oder EXEC-Aufruf, optional;
- technische Position: Byte-/Zeichenoffsets und Start-/Endzeile;
- Identität: Query Hash, Query Plan Hash, SQL Handle und Plan Handle.

JSON verwendet die benannten Arrays `requests`, `statements`, `batches`, `inputBuffers` und `warnings`.
<!-- END STATEMENT_RESULTSETS -->
