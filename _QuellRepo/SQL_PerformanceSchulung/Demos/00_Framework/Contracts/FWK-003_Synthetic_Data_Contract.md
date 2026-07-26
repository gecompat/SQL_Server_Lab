# FWK-003 – Vertrag für synthetische Testdaten

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Vertragsversion | 1.0 |
| Geltungsbereich | deterministischer Datenaufbau innerhalb einer durch `FWK-002` markierten Testdatenbank |

## 1. Zweck

Der Vertrag erzeugt reproduzierbare Datenprofile für Performance-Demos, ohne reale Daten, öffentliche Beispieldatenbanken oder nicht mitgelieferte Abhängigkeiten zu benötigen. Derselbe Parametersatz muss dieselbe relationale Datenverteilung erzeugen. Hardware, Parallelität und physische Seitengestaltung dürfen Laufzeit und Speicherlayout beeinflussen, nicht jedoch die fachliche Verteilung der generierten Werte.

## 2. Sicherheitsgrenze

Der Generator darf ausschließlich in einer Datenbank ausgeführt werden, deren Extended Properties vollständig zum `FWK-002`-Vertrag passen. Vor jeder Zustandsänderung werden mindestens geprüft:

- `SQLPERF.Project = SQL_PerformanceSchulung`,
- `SQLPERF.ContractVersion = 1.0`,
- `SQLPERF.DemoId` entspricht der angeforderten Demo-ID,
- `SQLPERF.RunToken` entspricht dem angeforderten Run-Token.

Systemdatenbanken, nicht markierte Datenbanken und Markerabweichungen führen zu `FAIL_SAFETY`. Der Generator löscht keine Datenbank und verändert keine Instanzoption.

## 3. Eingabeparameter

| Parameter | Bedeutung | Grenze |
|---|---|---|
| `@DemoId` | kanonische Demo-ID | `STL|OPT|QRY|IDX|CON|RES|DGN-nnn` |
| `@RunToken` | synthetische Laufkennung | 1 bis 20 Zeichen; nur `A-Z`, `0-9`, `_` |
| `@RowCount` | Anzahl Faktzeilen | 1 bis 10.000.000 |
| `@Seed` | deterministischer Seed | beliebiger `int` |
| `@DistinctKeys` | Kardinalität der Schlüsselverteilung | 2 bis `MIN(@RowCount, 1.000.000)` |
| `@SkewPercent` | Anteil der Zeilen im Hot-Set | 0 bis 100 |
| `@HotKeyPercent` | Anteil der Schlüssel im Hot-Set | 1 bis 100 |
| `@CorrelationPercent` | Anteil korrelierter Werte | 0 bis 100 |
| `@PayloadBytes` | tatsächliche Payload-Länge | 0 bis 4.000 Bytes |
| `@StartDate` | Beginn des synthetischen Zeitbereichs | nicht `NULL` |
| `@DateSpanDays` | Größe des Zeitbereichs | 1 bis 36.500 |
| `@ResetExistingData` | vorhandene Generatorzeilen ersetzen | `0` oder `1` |

## 4. Datenprofil

Die Referenzimplementierung erzeugt `lab.SyntheticFact` mit folgenden unabhängigen Diagnoseachsen:

- gleichverteiltem `UniformKey`,
- steuerbarer Hot-Set-Verteilung in `SkewKey`,
- teilweise an `UniformKey` gekoppeltem `CorrelationKey`,
- deterministisch verteiltem `EventDate`,
- numerischem `MeasureValue`,
- variabler `Payload` zur Steuerung der Zeilenbreite.

`SkewPercent = 0` erzeugt keine Hot-Set-Bevorzugung. Bei aktiviertem Skew werden `SkewPercent` Prozent der Zeilen auf `HotKeyPercent` Prozent der Schlüssel abgebildet. `CorrelationPercent = 100` setzt `CorrelationKey = UniformKey`; bei `0` wird eine unabhängige deterministische Abbildung verwendet.

## 5. Determinismus

Determinismus bezeichnet die fachlichen Werte je `SyntheticFactId`, nicht eine identische physische Page-Verteilung oder Ausführungszeit. Verboten sind nicht reproduzierbare Quellen wie `NEWID()`, ungesetztes `RAND()`, aktuelle Zeitwerte oder die Zeilenanzahl von Systemkatalogen.

Die Referenzimplementierung bildet Werte ausschließlich aus laufender Nummer, Seed und Parametern durch ganzzahlige Arithmetik. Das Ergebnis enthält eine nicht kryptografische Prüfsumme als schnellen Wiederholungshinweis. Diese Prüfsumme ist kein Integritätsbeweis und darf nicht zur Kollisionsfreiheit behauptet werden.

## 6. Idempotenz

Ein Lauf mit identischen Parametern und `@ResetExistingData = 1` ersetzt ausschließlich die Generatorobjekte innerhalb der markierten Testdatenbank. Ein Lauf mit `@ResetExistingData = 0` und vorhandenen Zeilen endet mit `FAIL_STATE`.

Die Parametermenge und das Ergebnis werden in `lab.SyntheticGeneratorManifest` protokolliert. Reale Umgebungswerte, Servernamen oder Dateipfade werden nicht gespeichert.

## 7. Ergebnis

Der Generator gibt genau einen Summary-Datensatz mit mindestens folgenden Feldern aus:

```text
Phase
CheckId
Outcome
Code
GeneratedRows
DistinctUniformKeys
DistinctSkewKeys
PayloadBytes
DataFingerprint
Message
```

Erfolgreiche Generierung ist `PASS/OK`. Vertrags- oder Markerfehler sind `FAIL_CONTRACT`, `FAIL_SAFETY` oder `FAIL_STATE`; Ausführungsfehler sind `FAIL_EXECUTION`.

## 8. Abnahme

`FWK-003` ist implementiert, wenn die Referenzimplementierung:

- ausschließlich markierte Testdatenbanken verändert,
- identische Parameter reproduzierbar abbildet,
- Uniform-, Skew-, Korrelations-, Zeit- und Breitenprofile unterstützt,
- maximal 10 Millionen Zeilen ohne Abhängigkeit von Benutzerdaten erzeugt,
- Parametermenge und aggregierte Ergebnisdaten dokumentiert,
- durch die statische Framework-Prüfung erfasst wird.
