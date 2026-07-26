# Schnittstellenvertrag für eine spätere Fleet-Korrelation

Stand: 2026-07-18  
Backlog: SC-024  
Status: `DESIGN_READY_EXTERNAL_COMPONENT_REQUIRED`

## Zweck

Eine externe Komponente könnte freigegebene, abstrahierte Diagnosemetriken mehrerer SQL-Server-Instanzen vergleichen. Sie gehört nicht in den zustandslosen T-SQL-Kern und wird durch dieses Dokument nicht implementiert.

## Verbindliche Isolationsregeln

- Jede Quelle erhält eine synthetische, nicht rückrechenbare `SourceKey`; reale Server-, Instanz-, Firmen-, Kunden-, Benutzer-, Datenbank- oder Umgebungsnamen werden nicht transportiert oder gespeichert.
- Mandant beziehungsweise Sicherheitsdomäne wird vor Annahme eines Datensatzes authentisiert und technisch isoliert.
- Erlaubt sind nur versionierte Statuscodes und numerische Metriken aus einer Positivliste.
- SQL-/Plantexte, freie Meldungen, Pfade, Objekt- und Schemanamen, Identitäten, Host-/Clientdaten sowie vollständige Resultsets sind verboten.
- Transport, zentraler Speicher, Schlüsselverwaltung, Retention, Löschung, Region und Betreiber werden außerhalb dieses Repositorys ausdrücklich entschieden.
- Fehlende, verspätete oder verweigerte Quellen bleiben Datenlücken und werden nie als gesunder Zustand imputiert.

## Minimaler Nachrichtenvertrag

| Feld | Typ | Regel |
|---|---|---|
| `ContractVersion` | stabiler Code | Pflicht; unbekannte Version ablehnen |
| `SourceKey` | synthetischer Token | keine direkte Umgebungsaussage |
| `CollectedAtUtc` | UTC-Zeitpunkt | Pflicht |
| `MetricCode` | Positivlisten-Code | Pflicht |
| `MetricValue` | Zahl oder stabiler Status | kein Freitext |
| `ResetEpoch` | synthetischer Token | Pflicht für Deltaquellen |
| `SourceStatus` | stabiler Code | partielle Evidenz erhalten |

## Noch erforderliche externe Entscheidungen

Authentisierung, Transportprotokoll, Endpunkt, Mandantenmodell, Speichertechnologie, Region, Retention, Löschverantwortung, Schlüsselrotation, Größenbudget, Betriebs-SLO und Incident-Verfahren. In diesem Repository werden dafür keine realen Endpunkte, Konten oder Topologien hinterlegt.

## Abnahme

Mindestens zwei synthetische Quellen werden getrennt verarbeitet. Cross-Tenant-Zugriff, Replay, unbekannte Version, verbotenes Zusatzfeld, Retention, Löschung, Teilausfall und Resetwechsel müssen kontrolliert getestet werden. Erst danach kann SC-024 von einem externen Komponentenprojekt übernommen werden.
