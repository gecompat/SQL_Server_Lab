# FWK-011 – Ergebnisnormalisierungs- und Erwartungsvertrag

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED` |
| Vertragsversion | 1.0 |
| Geltungsbereich | maschinenunabhängige Bewertung synthetischer Demoergebnisse |

## 1. Zweck

Der Vertrag ersetzt fragile absolute Laufzeitwerte durch fachliche Invarianten, Richtungen, Verhältnisse und begründete Bandbreiten. Eine Demo gilt nicht deshalb als erfolgreich, weil sie auf einer einzelnen Maschine einen festen Millisekundenwert unterschreitet.

## 2. Evidenzdatei

Die Eingabe enthält ausschließlich synthetische oder aggregierte Messwerte:

```json
{
  "contract_version": "1.0",
  "demo_id": "QRY-001",
  "profile": "SMALL",
  "baseline": {"logical_reads": 1000, "row_count": 100},
  "comparison": {"logical_reads": 100, "row_count": 100}
}
```

Zusätzliche Umgebungsdetails sind nicht Teil des maschinenlesbaren Vertrages. Engine-Version, Compatibility Level und Ressourcenprofil werden separat im Testbericht dokumentiert.

## 3. Assertions

Unterstützte Assertion-Arten:

| Art | Verwendung |
|---|---|
| `EXACT` | fachliche Invariante wie identische Ergebnismenge |
| `RANGE` | dokumentierter zulässiger Wertebereich |
| `RATIO_MAX` | Vergleichswert darf höchstens einen Anteil der Baseline erreichen |
| `RATIO_MIN` | Vergleichswert muss mindestens einen Anteil der Baseline erreichen |
| `DIRECTION` | `LESS`, `LESS_OR_EQUAL`, `GREATER`, `GREATER_OR_EQUAL` oder `UNCHANGED` |

Absolute Duration-Grenzen sind nur zulässig, wenn das Ressourcenprofil technisch kontrolliert und im Vertrag begründet ist. Für normale Schulungsdemos werden Duration und CPU bevorzugt als Richtung, Verhältnis oder empirische Warnung bewertet.

## 4. Schwere und fehlende Evidenz

Jede Assertion besitzt:

- `severity`: `FAIL` oder `WARN`,
- `on_missing`: `FAIL` oder `SKIP`.

Ein verletzter `WARN`-Grenzwert ergibt `WARN_EMPIRICAL_VARIANCE`. Eine verletzte `FAIL`-Assertion ergibt `FAIL_RESULT_CONTRACT`. Fehlende optional erklärte Evidenz ergibt `SKIP_EVIDENCE_MISSING`; fehlende verpflichtende Evidenz ist `FAIL_RESULT_CONTRACT`.

Division durch Null, nicht endliche Werte und widersprüchliche Grenzen sind Vertragsfehler.

## 5. Gesamtergebnis

Priorität:

```text
FAIL > SKIP > WARN > PASS
```

Der Evaluator gibt je Assertion und als letzte Zeile `SUMMARY` aus. Die Ausgabe enthält keine Pfade oder eingelesenen Rohdateien, sondern nur Demo-ID, Profil, Assertion-ID, Ergebnis, Code und numerische Vergleichswerte.

## 6. Datenschutz

Der Evaluator verarbeitet keine Querytexte, Pläne oder Identitätsdaten. Repository-Beispiele enthalten ausschließlich synthetische Werte. Werden lokal andere Eingaben verwendet, dürfen deren Inhalte nicht ungeprüft als CI-Artefakt gespeichert werden.

## 7. Abnahme

`FWK-011` ist implementiert, wenn:

- JSON-Vertrag und Evidenz ohne Drittanbieterbibliothek validiert werden,
- alle fünf Assertion-Arten geprüft werden,
- NaN, Infinity, Null-Division und inkonsistente Metadaten abgewiesen werden,
- `PASS`, `WARN`, `SKIP` und `FAIL` technisch unterscheidbar sind,
- ein positiver und ein negativer Selbsttest in CI ausgeführt werden.
