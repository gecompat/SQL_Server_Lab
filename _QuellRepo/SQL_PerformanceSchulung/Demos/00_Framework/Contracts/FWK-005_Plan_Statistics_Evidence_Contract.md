# FWK-005 – Vertrag für Plan- und Statistikevidenz

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Vertragsversion | 1.0 |
| Geltungsbereich | Estimated/Actual Execution Plans, Statistikmetadaten und Histogramme in synthetischen Testdatenbanken |

## 1. Zweck

Der Vertrag legt fest, welche Evidenz für Aussagen über Kardinalität, Planwahl, Warnungen, Memory Grants und Statistiken erforderlich ist. Ein Execution Plan ist eine Evidenzquelle, aber kein alleiniger Ursachenbeweis.

## 2. Planarten

| Evidenz | Bedeutung | Grenze |
|---|---|---|
| `Estimated Execution Plan` | kompilierter Plan ohne Laufzeitinformationen | belegt keine tatsächlichen Zeilen, Spills oder Laufzeit |
| `Actual Execution Plan` | Plan mit Laufzeitinformationen der ausgeführten Statements | enthält nur die betrachtete Ausführung und kann Messaufwand verursachen |
| Cache-Plan | aktuell im Plan Cache auffindbarer kompilierter Plan | kann fehlen, verdrängt oder nicht dem gewünschten Parameterwert zugeordnet sein |
| Query-Store-Plan | persistierte Planhistorie | Konfiguration, Capture Mode und Zeitraum beachten |

Die Referenzvorlage verwendet `SET STATISTICS XML ON/OFF`, wodurch pro ausgeführtem Statement XML-Showplan mit Laufzeitinformationen zurückgegeben wird. Dafür ist `SHOWPLAN` auf allen referenzierten Datenbanken erforderlich.

## 3. Statistik-Evidenz

Für eine Statistik werden mindestens erfasst:

- Objekt-, Schema- und Statistikname,
- `stats_id`,
- automatische oder benutzerdefinierte Herkunft,
- Filterdefinition,
- `last_updated`,
- Zeilen, Stichprobenzeilen, Schritte und Änderungszähler,
- Histogrammgrenzen und Häufigkeitswerte.

`sys.dm_db_stats_properties` kann bei ungültigen IDs oder fehlender Sichtbarkeit ein leeres Ergebnis liefern. Ein leeres Ergebnis darf nicht als Statistik mit Nullzeilen interpretiert werden.

## 4. Histogramm und Density

Das Histogramm beschreibt nur die führende Statistikspalte. Density-Informationen und Histogramm dürfen nicht als gleichwertige Verteilungsmodelle bezeichnet werden. Mehrspaltenkorrelation oder Prädikatsabhängigkeit ist durch geeignete Datenprofile und Estimated-/Actual-Vergleich zu prüfen.

## 5. Scope und Datenschutz

Die Vorlage arbeitet ausschließlich in der aktuellen markierten Testdatenbank. Sie speichert keine Pläne. Interaktive XML-Ausgabe darf nur synthetische Objekt- und Literalwerte enthalten. Ein Export wird als eigenes Artefakt geprüft; reale Querytexte, Objektbezeichner oder Parameterwerte dürfen nicht versioniert werden.

## 6. Abnahme

`FWK-005` ist implementiert, wenn die Vorlage:

- Marker und Zielobjekt prüft,
- Statistikproperties und Histogramm über dokumentierte Systemobjekte abfragt,
- Actual-Plan-XML für eine synthetische Referenzabfrage ausgibt,
- fehlende Statistik- oder SHOWPLAN-Voraussetzungen eindeutig meldet,
- Estimated, Actual, Cache und Query Store begrifflich trennt,
- keine Plan- oder Statistikdatei automatisch persistiert.
