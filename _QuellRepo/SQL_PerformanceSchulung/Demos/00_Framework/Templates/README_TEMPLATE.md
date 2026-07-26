# <DEMO-ID> – <Titel>

| Merkmal | Wert |
|---|---|
| Status | `DESIGNED` |
| Sicherheitsstufe | `<GREEN|YELLOW|RED>` |
| Primäre Zielversion | `<SQL Server 2025>` |
| Unterstützte Versionen | `<2019, 2022, 2025>` |
| Compatibility Level | `<Bereich oder konkreter Wert>` |
| Edition / Plattform | `<Voraussetzung oder versionsneutral>` |
| Sessions | `<Anzahl>` |
| Laufzeitklasse | `<S|M|L>` |
| Testprofil | `<TP-RUN|TP-PERF|TP-CON>` |

## 1. Lernziel

Nach Abschluss kann die lernende Person …

## 2. Fachliche Kernaussage

**Evidenzklasse:** `<DOKUMENTIERT|EMPIRISCH|METHODE|INFERENZ>`

Die Kernaussage wird als überprüfbare Ursache-Wirkungs-Beziehung formuliert. Voraussetzungen und Grenzen werden im selben Abschnitt genannt.

## 3. Nichtziel

Der Abschnitt grenzt naheliegende, aber nicht geprüfte Schlussfolgerungen ab.

## 4. Voraussetzungen

### 4.1 Version und Konfiguration

- Engine-Version:
- Compatibility Level:
- Datenbankoptionen:
- Edition / Betriebssystem:

### 4.2 Berechtigungen

Es werden nur die tatsächlich verwendeten Berechtigungen aufgeführt.

### 4.3 Mindestanforderungen an die Host-Hardware

- CPU:
- RAM:
- freier Datenträgerspeicher:
- zusätzliche Hosts oder Instanzen, sofern fachlich erforderlich:

Die Angaben sind Mindestanforderungen für die reproduzierbare Ausführung, keine Beschreibung einer konkreten Umgebung.

## 5. Sicherheits- und Abbruchrahmen

- Sicherheitsstufe und Begründung:
- maximale geplante Laufzeit:
- maximale Sessionzahl:
- erwartete Datenbank- oder TempDB-Größe:
- Abbruchsignal:
- Kill-Switch:
- Recovery-Pfad:

Gelbe und rote Demos verweisen ausdrücklich auf `FWK-008`.

## 6. Synthetisches Datenmodell

Tabellen, Verteilung, Korrelation, Datenbreite, Seed und Skalierungsparameter werden beschrieben. Reale Objekt- oder Umgebungsnamen sind ausgeschlossen.

## 7. Ablauf

| Phase | Datei | Zweck |
|---|---|---|
| Preflight | `00_Preflight.sql` | Voraussetzungen und Sicherheitsfreigabe |
| Setup | `10_Setup.sql` | idempotenter Aufbau |
| Baseline | `20_Baseline.sql` | Ausgangsmessung |
| Demonstration | `30_Demonstration.sql` | kontrollierte Ursache |
| Observation | `40_Observation.sql` | technische Evidenz |
| Mitigation | `50_Mitigation.sql` | genau eine begründete Änderung |
| Comparison | `60_Comparison.sql` | identische erneute Messung |
| Cleanup | `90_Cleanup.sql` | vollständige Bereinigung |

Fehlende Phasen werden begründet; sie werden nicht stillschweigend ausgelassen.

## 8. Erwartete Beobachtung

### 8.1 Baseline

Erwartete Richtung, Größenordnung und zulässige Abweichung.

### 8.2 Problemzustand

Messwert und Plan-/DMV-/XE-Evidenz, die die Hypothese stützt.

### 8.3 Nach Gegenmaßnahme

Erwartete relationale Veränderung gegenüber der Baseline. Fixe Laufzeiten oder universelle Schwellen sind unzulässig.

## 9. Interpretation

Der Abschnitt trennt Beobachtung, Mechanismus, alternative Hypothesen und Grenzen. Ein Planoperator oder Wait Type allein gilt nicht als Ursachenbeweis.

## 10. Cleanup und Wiederherstellung

- regulärer Cleanup:
- Cleanup nach Abbruch:
- wiederherzustellende Optionen:
- Nachweis des definierten Ausgangszustands:

Datenbankentfernung erfolgt ausschließlich über den markergeprüften Vertrag aus `FWK-002`.

## 11. Tests

- statische Vertragsprüfung:
- Syntax-/Deploy-Prüfung:
- zwei vollständige Wiederholungsläufe:
- zutreffende Versionsmatrix:
- kontrollierte Skip-Fälle:
- Cleanup-Nachweis:

## 12. Bekannte Grenzen

Hardware-, Cache-, Datenmengen-, Editions-, Plattform- und Versionsgrenzen werden benannt.

## 13. Quellen

| Quellen-ID | Aussagebezug | Gültigkeitsbereich | Abrufdatum |
|---|---|---|---|
| `<SRC-...>` |  |  | `<YYYY-MM-DD>` |

## 14. Traceability

| Element | Zuordnung |
|---|---|
| Lernziel | `<LO-...>` |
| Folie / Claim | `<CLM-...>` |
| Demo-ID | `<...>` |
| Testprofil | `<...>` |
