USE [DeineDatenbank];
GO

/*
===============================================================================
Objekt       : monitor.VW_ModuleStatusCatalog
Version      : 1.2.0
Stand        : 2026-07-20
Typ          : View
Zweck        : Stellt den zentralen Katalog aller maschinenlesbaren Framework-
               Statuscodes bereit.
Änderungen   : 1.2.0 - Datenbank-, High-Impact-, Childstatus- und TABLE-
                         Preflightstatus des Ausgabe-Vertrags 2.0 ergänzt.
               1.1.0 - Plattform-, Messkontext- und Resetstatus ergänzt.
===============================================================================
*/
CREATE OR ALTER VIEW [monitor].[VW_ModuleStatusCatalog]
AS
    SELECT [v].[StatusCode],[v].[SeverityLevel],[v].[IsSuccess],[v].[IsQueryable],[v].[IsTerminal],
           [v].[GermanDescription],[v].[TechnicalMeaning]
    FROM (VALUES
      (CAST('AVAILABLE' AS varchar(40)),CAST(0 AS tinyint),CAST(1 AS bit),CAST(1 AS bit),CAST(0 AS bit),CAST(N'Verfügbar' AS nvarchar(200)),CAST(N'Die Quelle wurde erfolgreich abgefragt.' AS nvarchar(1000))),
      ('AVAILABLE_LIMITED',1,1,1,0,N'Verfügbar, aber eingeschränkt',N'Die Quelle ist abfragbar, die Vollständigkeit kann wegen Rechten oder Featurezustand eingeschränkt sein.'),
      ('AVAILABLE_UNVERIFIED',1,1,1,0,N'Abfragbar, Vollständigkeit nicht verifiziert',N'Die technische Probe war erfolgreich; eine deklarative Vollständigkeitsprüfung war nicht möglich.'),
      ('AVAILABLE_DISABLED',1,0,1,0,N'Quelle verfügbar, Feature deaktiviert',N'Die Metadatenquelle ist erreichbar, das zugehörige Feature ist nicht aktiviert.'),
      ('PARTIAL',1,1,1,0,N'Teilergebnis',N'Mindestens ein Teil wurde erfolgreich erhoben, mindestens ein weiterer Teil wurde übersprungen oder mit Fehlerstatus beendet.'),
      ('CUMULATIVE_CONTEXT',0,1,1,0,N'Kumulativer Messkontext',N'Die Werte gelten seit SQL-Server-Start oder letztem Zählerreset und sind keine aktuelle Delta-Messung.'),
      ('MEASUREMENT_RESET',2,0,0,1,N'Messung durch Reset ungültig',N'Während des Messfensters wurde ein Serverneustart oder ein Zählerreset erkannt; Deltas und Prozentwerte sind nicht belastbar.'),
      ('SKIPPED',1,0,0,0,N'Übersprungen',N'Das Teilmodul wurde aufgrund der Aufrufparameter nicht ausgeführt.'),
      ('NOT_APPLICABLE',0,0,0,0,N'Nicht anwendbar',N'Die Funktion ist für Plattform, Datenbankrolle oder Konfiguration fachlich nicht anwendbar.'),
      ('UNAVAILABLE_VERSION',2,0,0,1,N'Von der Serverversion nicht unterstützt',N'Die notwendige DMV, Spalte, Eigenschaft oder Syntax ist in dieser Version nicht verfügbar.'),
      ('UNAVAILABLE_PLATFORM',2,0,0,1,N'Auf dieser Plattform nicht verfügbar',N'Die Information ist nur auf einer anderen Betriebssystemplattform verfügbar; ein allgemeiner Fallback kann weiterhin nutzbar sein.'),
      ('UNAVAILABLE_FEATURE',2,0,0,1,N'Feature nicht verfügbar',N'Das optionale Feature ist nicht installiert, nicht aktiviert oder für Edition beziehungsweise Rolle nicht nutzbar.'),
      ('UNAVAILABLE_OBJECT',2,0,0,1,N'Objekt nicht verfügbar',N'Das optionale System- oder Frameworkobjekt ist nicht vorhanden.'),
      ('DATABASE_UNAVAILABLE',2,0,0,1,N'Datenbank nicht verfügbar',N'Die Zieldatenbank ist nicht vorhanden, nicht online oder für den Login nicht zugänglich.'),
      ('SYSTEM_DATABASE_EXCLUDED',1,0,0,1,N'Systemdatenbank ausgeschlossen',N'Die explizit angeforderte Systemdatenbank ist ohne @SystemdatenbankenEinbeziehen=1 nicht Teil der Kandidatenmenge.'),
      ('HIGH_IMPACT_CONFIRMATION_REQUIRED',2,0,0,1,N'High-Impact-Bestätigung erforderlich',N'Der tatsächlich aktivierte ressourcenintensive Analysepfad wurde vor dem teuren Systemzugriff beendet, weil @HighImpactConfirmed nicht 1 ist.'),
      ('STATUS_UNAVAILABLE',2,0,0,1,N'Childstatus nicht verfügbar',N'Das Child lieferte keinen vollständigen validierbaren Statusvertrag; Erfolg wird nicht aus dem Ausbleiben eines Fehlers abgeleitet.'),
      ('DENIED_PERMISSION',2,0,0,1,N'Berechtigung fehlt',N'Die Quelle konnte wegen fehlender SQL-Server-Berechtigung nicht abgefragt werden.'),
      ('DENIED_GROUP',2,0,0,1,N'Analyseklasse gesperrt',N'Die Analyseklasse ist durch die konfigurierte Gruppenpolicy nicht freigegeben.'),
      ('TIMEOUT',2,0,0,1,N'Zeitlimit erreicht',N'Das Teilmodul wurde wegen Lock- oder Laufzeitlimit beendet.'),
      ('ERROR_HANDLED',2,0,0,1,N'Fehler abgefangen',N'Ein Teilfehler wurde isoliert und strukturiert zurückgegeben.'),
      ('INVALID_RESULT_TABLE_MAPPING',2,0,0,1,N'Ungültige TABLE-Zuordnung',N'Das JSON-Objekt enthält unbekannte oder doppelte Resultsetnamen, doppelte Ziele oder unzulässige Zielnamen.'),
      ('INVALID_RESULT_TABLE_TARGET',2,0,0,1,N'Ungültiges TABLE-Ziel',N'Mindestens eine lokale Ziel-Temp-Tabelle fehlt, enthält Daten oder besitzt keine sichere Seed-Struktur.'),
      ('INVALID_PARAMETER',2,0,0,1,N'Ungültiger Parameter',N'Der Aufruf enthält einen ungültigen oder widersprüchlichen Parameterwert.')
    ) v(StatusCode,SeverityLevel,IsSuccess,IsQueryable,IsTerminal,GermanDescription,TechnicalMeaning);
GO
