# FWK-008 – Sicherheits- und Abbruchvertrag

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Vertragsversion | 1.0 |
| Geltungsbereich | alle ausführbaren Demos |
| Technische Einbindung | `../Templates/00_Preflight.sql` |

## 1. Grundsatz

Die Sicherheitsstufe beschreibt die mögliche Wirkung der Demo, nicht ihre fachliche Schwierigkeit. Eine Umgebung wird nicht automatisch als Test-, Entwicklungs- oder Produktionsumgebung klassifiziert. Für gelbe und rote Demos sind deshalb ausdrückliche Bestätigungen erforderlich.

Eine Warnmeldung ohne technische Sperre erfüllt diesen Vertrag nicht.

## 2. Sicherheitsstufen

| Stufe | Zulässiger Rahmen | Erforderliche Bestätigung |
|---|---|---|
| `GREEN` | lokal auf die eigene synthetische Testdatenbank begrenzt; keine relevante Instanzwirkung | keine zusätzliche Hochlastbestätigung |
| `YELLOW` | kontrollierte CPU-, Memory-, TempDB-, I/O-, Log- oder Concurrency-Last | `@ConfirmIsolatedLab = 1`, `@HighImpactConfirmed = 1`, positive Laufzeitgrenze |
| `RED` | Instanz-, Cache-, Dienst-, Betriebssystem- oder Infrastrukturänderung | alle gelben Bestätigungen sowie `@DisposableEnvironmentConfirmed = 1` und `@RecoveryPlanConfirmed = 1` |

Rote Demos dürfen nicht in unbeaufsichtigten Standard-CI-Läufen ausgeführt werden.

## 3. Pflichtgrenzen

Jede gelbe oder rote Demo dokumentiert mindestens:

- maximale geplante Laufzeit,
- erwartete Datenbank- beziehungsweise TempDB-Größenordnung,
- maximale Sessionzahl,
- Abbruchsignal oder Kill-Switch,
- Cleanup- und Recovery-Pfad,
- Messwert, der eine vorzeitige Beendigung auslöst,
- bekannte Restwirkung nach einem erzwungenen Abbruch.

Grenzen sind als Schutzwerte zu verstehen. Sie sind keine universellen Performance-Schwellen.

## 4. Abbruchverhalten

Ein Abbruchpfad muss:

1. wiederholbar aufrufbar sein,
2. ausschließlich demo-eigene Sessions, Objekte oder markierte Testdatenbanken adressieren,
3. bei unbekanntem Eigentum abbrechen statt aggressiv zu bereinigen,
4. offene Transaktionen und Datenbankoptionen in definierter Reihenfolge behandeln,
5. einen erneuten Preflight vor einer Wiederholung verlangen.

`KILL`, `SINGLE_USER WITH ROLLBACK IMMEDIATE`, globale Cacheeingriffe oder Dienstoperationen sind nur zulässig, wenn ihre Zielmenge technisch eindeutig begrenzt ist und die Sicherheitsstufe dies erlaubt.

## 5. Verbotene Annahmen

Unzulässig sind insbesondere:

- Produktionssicherheit aus Datenbanknamen, Hostnamen oder Edition abzuleiten,
- eine gelbe oder rote Demo allein aufgrund eines kleinen Testdatensatzes als grün einzustufen,
- Timeout als vollständigen Cleanup zu behandeln,
- fremde Sessions nach Application Name oder Loginname ohne zusätzliches Eigentumsmerkmal zu beenden,
- einen Recovery-Pfad nur in Freitext zu beschreiben, ohne die ausführbaren Schritte zu benennen.

## 6. Statusintegration

Fehlende Sicherheitsbestätigungen sind `FAIL_SAFETY`. Eine nicht verfügbare, aber fachlich optionale Ressourcenkonstellation ist `SKIP_RESOURCE_PROFILE`. Ein unerwarteter Abbruch während der Demo ist `FAIL_EXECUTION`; unvollständiger Cleanup ist `FAIL_CLEANUP`.

## 7. Abnahmekriterien

`FWK-008` ist implementiert, wenn der Preflight die Bestätigungen stufenabhängig erzwingt, gelbe und rote Vorlagen positive Laufzeitgrenzen verlangen und der Lifecycle nur markergeprüfte Datenbanken entfernen kann.
