# FWK-012 – Status-, Fehler- und Skip-Vertrag

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Vertragsversion | 1.2 |
| Geltungsbereich | Preflight, Setup, Demo, Beobachtung, Orchestrierung, Telemetrie, Gegenmaßnahme, Vergleich, Ergebnisabnahme und Cleanup |

## 1. Zweck

Der Vertrag trennt erwartete Nichtanwendbarkeit von technischen Fehlern. Eine ältere Version, fehlende optionale Funktion, ein nicht installiertes externes Werkzeug oder nicht erteilte Diagnoseberechtigung darf nicht als gescheiterte Produkteigenschaft protokolliert werden. Umgekehrt darf ein Sicherheits-, Timeout-, Ergebnisvertrags- oder Cleanup-Fehler nicht als `SKIP` kaschiert werden.

## 2. Outcomes

| Outcome | Bedeutung | Batch- oder Prozessverhalten |
|---|---|---|
| `PASS` | Prüfung oder Phase erfolgreich | Fortsetzung |
| `WARN` | ausführbar, aber Interpretation, optionale Evidenz oder Messqualität eingeschränkt | Fortsetzung mit sichtbarer Meldung |
| `SKIP` | erwartete Voraussetzung, externes Werkzeug oder ausdrücklich optionale Evidenz nicht verfügbar | keine zustandsverändernde Folgephase beziehungsweise Assertion nicht bewertbar |
| `FAIL` | Vertrags-, Sicherheits-, Zustands-, Timeout-, Ausführungs-, Ergebnis- oder Cleanup-Fehler | vollständige Evidenzausgabe, danach Fehlerstatus |

## 3. Verbindliche Codes

### 3.1 Erfolg und Warnung

- `OK`
- `WARN_ENVIRONMENT_DETAIL_SUPPRESSED`
- `WARN_RESOURCE_PROBE_APPROXIMATE`
- `WARN_EMPIRICAL_VARIANCE`
- `WARN_OPTIONAL_EVIDENCE_SKIPPED`

### 3.2 Kontrollierte Skips

- `SKIP_VERSION`
- `SKIP_COMPATIBILITY_LEVEL`
- `SKIP_EDITION`
- `SKIP_PLATFORM`
- `SKIP_PERMISSION`
- `SKIP_CONFIGURATION`
- `SKIP_RESOURCE_PROFILE`
- `SKIP_MANUAL_APPROVAL`
- `SKIP_EVIDENCE_MISSING`
- `SKIP_TOOL_MISSING`

### 3.3 Fehler

- `FAIL_CONTRACT`
- `FAIL_SAFETY`
- `FAIL_STATE`
- `FAIL_TIMEOUT`
- `FAIL_EXECUTION`
- `FAIL_CLEANUP`
- `FAIL_RESULT_CONTRACT`

Neue Codes benötigen eine Änderung dieses Vertrags. Freitext darf einen Code erläutern, aber nicht ersetzen.

## 4. Resultsetschema

Framework- und Demo-Prüfungen verwenden mindestens:

```text
Sequence        int
Phase           varchar(20)
CheckId         varchar(64)
Outcome         varchar(8)
Code            varchar(64)
ObservedValue   nvarchar(4000) NULL
RequiredValue   nvarchar(4000) NULL
Message         nvarchar(4000)
```

Die letzte Zeile eines Preflights, Test-Harness-Laufs oder Ergebnisvertrags ist `CheckId = SUMMARY`. Sie enthält genau ein Gesamtergebnis. Alternativ dürfen Prozesswerkzeuge den Marker `SQLPERF_SUMMARY|OUTCOME|CODE` ausgeben. Priorität: `FAIL` vor `SKIP` vor `WARN` vor `PASS`.

## 5. Fehlernummern und Prozess-Exitcodes

Die T-SQL-Referenzskripte verwenden den reservierten Projektbereich:

| Fehlernummer | Kategorie |
|---:|---|
| 51000 | `FAIL_CONTRACT` |
| 51001 | `FAIL_SAFETY` |
| 51002 | `FAIL_STATE` |
| 51003 | `FAIL_EXECUTION` |
| 51004 | `FAIL_CLEANUP` |
| 51005 | `FAIL_TIMEOUT` |

`FAIL_RESULT_CONTRACT` wird vom plattformneutralen Ergebnis-Evaluator als Prozess-Exitcode und strukturierter Code ausgegeben. Python-Harnesses verwenden Exitcode 0 für `PASS`, `WARN` und kontrollierten `SKIP`; Vertrags-, Ausführungs-, Timeout- und Cleanup-Fehler erhalten unterschiedliche von null verschiedene Exitcodes.

Ein kontrollierter `SKIP` löst standardmäßig keinen SQL-Fehler aus. Der Test-Harness wertet Summary-Datensatz oder Summary-Marker aus. Dadurch bleibt ein erwarteter Feature-, Tool- oder Evidenz-Skip von einem fehlgeschlagenen Job unterscheidbar.

## 6. Catch-, Timeout- und Cleanup-Regel

Ein `CATCH`-Block darf ursprüngliche Fehlernummer und -meldung nicht durch eine allgemeine Erfolgsmeldung ersetzen. Prozess-Timeouts müssen verbleibende Kindprozesse beenden. Cleanup wird nach gestarteter Setup-Phase unabhängig vom vorherigen Ergebnis versucht. Cleanup-Fehler werden separat erfasst. Wenn Ausführung und Cleanup fehlschlagen, ist der Gesamtausgang `FAIL_CLEANUP`, während die ursprüngliche Ausführungsmeldung als Kontext erhalten bleibt.

## 7. Datenschutz

`ObservedValue` darf interaktiv notwendige Diagnosewerte enthalten. Testreports und Repository-Artefakte speichern nur synthetische Werte oder aggregierte Statusinformationen. Schutzwürdige Fundwerte werden nicht in Fehlertexte kopiert. Prozesswerkzeuge schreiben Rohoutput standardmäßig nicht in Dateien.

## 8. Abnahmekriterien

`FWK-012` ist implementiert, wenn Preflight, Lifecycle, Messung, Orchestrierung, Runtime-Harness, Telemetrie und Ergebnisnormalisierung ausschließlich diese Outcomes und Codes verwenden, eine Summary erzeugen und `FAIL` von `SKIP` technisch unterscheidbar bleibt.
