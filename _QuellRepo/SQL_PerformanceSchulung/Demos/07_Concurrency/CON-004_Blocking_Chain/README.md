# CON-004 – Blocking Chain, Head Blocker und Wartezeit

| Merkmal | Wert |
|---|---|
| Status | `VALIDATED` |
| Sicherheitsstufe | `YELLOW` |
| Primäre Zielversion | SQL Server 2025 |
| Unterstützte Versionen | SQL Server 2019, 2022 und 2025 |
| Compatibility Level | 150, 160 und 170 |
| Edition / Plattform | Database Engine; Windows oder Linux |
| Sessions | 4 im Problemzustand, 2 im Vergleich |
| Laufzeitklasse | M |
| Testprofil | `TP-CON` |

## 1. Lernziel

Nach Abschluss kann die lernende Person eine Blocking Chain vom unmittelbar blockierenden Request bis zum Head Blocker verfolgen und aktuelle Lock-Waits von einem Deadlock-Zyklus unterscheiden.

## 2. Fachliche Kernaussage

**Evidenzklasse:** `DOKUMENTIERT`, `EMPIRISCH` und `METHODE`

`blocking_session_id` beschreibt den unmittelbaren Blocker eines aktuell wartenden Requests. Der Head Blocker entsteht durch rekursives Verfolgen dieser Beziehung. Die Demo erzeugt deterministisch die Kette Head → Middle → Leaf, misst zwei `LCK_M_%`-Wartezustände und löst sie anschließend durch Commit in definierter Reihenfolge auf.

## 3. Nichtziel

Die Demo erzeugt keinen Deadlock und leitet keine allgemeine Empfehlung zum Beenden von Sessions ab. Sie verwendet weder `NOLOCK` noch instanzweite Locking-Konfigurationsänderungen.

## 4. Voraussetzungen

SQL Server 2019 bis 2025, vier gleichzeitig ausführbare Sessions sowie `CREATE DATABASE` und die versionsgerechte Server-State-Berechtigung. Mindestanforderungen sind 2 logische CPU-Kerne, 2 GB RAM und 100 MB freier Datenträgerspeicher. Zusätzliche Hosts sind nicht erforderlich.

## 5. Sicherheits- und Abbruchrahmen

Die Demo ist gelb, weil mehrere Sessions absichtlich Lock-Waits erzeugen. `FWK-010` verlangt `--confirm-isolated-lab`; das globale Zeitbudget beträgt 120 Sekunden. Jede Signalsperre besitzt ein eigenes Zeitlimit von höchstens 15 Sekunden. Bei Timeout beendet der Orchestrator verbleibende Prozesse; Cleanup setzt die Testdatenbank mit `ROLLBACK IMMEDIATE` zurück und entfernt sie nach Markerprüfung.

## 6. Synthetisches Datenmodell

`lab.BlockingDemo` enthält zwei Zeilen. Die Head-Session hält eine X-Sperre auf Zeile 1. Die Middle-Session hält eine X-Sperre auf Zeile 2 und wartet anschließend auf Zeile 1. Die Leaf-Session wartet auf Zeile 2. `fwk.SessionSignal` koordiniert ausschließlich die fachliche Reihenfolge; Launch Delays ersetzen keine Datenbanksignale.

## 7. Ablauf

| Phase | Datei | Zweck |
|---|---|---|
| Preflight | `00_Preflight.sql` | Version, Rechte und gelbe Sicherheitsbestätigung prüfen |
| Setup | `10_Setup.sql` | Datenbank, Signale, Tabellen und Evidenzobjekte anlegen |
| Baseline | `20_Baseline.sql` | blockierungsfreien Ausgangszustand prüfen |
| Demonstration | `Sessions/problem.json` | vier Sessions erzeugen und beobachten die Kette |
| Observation | `40_Observation.sql` | gespeicherte Head-/Middle-/Leaf-Evidenz und Endzustand prüfen |
| Mitigation | `50_Mitigation.sql` | Signale und Daten zurücksetzen; kurze Transaktionen festlegen |
| Comparison | `Sessions/comparison.json` | Commit vor Übergabe an die Folgesession |
| Verification | `70_Comparison.sql` | blockierungsfreien Vergleichszustand prüfen |
| Cleanup | `90_Cleanup.sql` | markierte Testdatenbank entfernen |

## 8. Erwartete Beobachtung

Während des Problemzustands wartet Middle mit einem `LCK_M_%`-Wait auf Head. Leaf wartet gleichzeitig mit einem `LCK_M_%`-Wait auf Middle. Die Beobachtersession speichert die drei Session-IDs, beide unmittelbaren Blockerbeziehungen und positive Wait-Zeiten. Nach dem Signal `OBSERVED` committen Head und Middle; alle Sessions enden ohne KILL.

Im Vergleich committen die schreibenden Sessions, bevor sie die nächste Session freigeben. Der fachliche Endwert bleibt identisch, es entsteht aber keine wartende Blocking Chain.

## 9. Interpretation

Eine blockierte Leaf-Session zeigt zunächst nur ihren unmittelbaren Blocker. Die Diagnose muss die Kette rekursiv bis zu einer Session verfolgen, die selbst nicht blockiert ist. Eine schlafende Session mit offener Transaktion kann dabei Head Blocker sein, obwohl sie keinen aktiven Request besitzt. Diese Demo hält Head während einer aktiven Signalwartephase sichtbar; produktive Diagnose muss zusätzlich Session- und Transaktionszustand berücksichtigen.

## 10. Cleanup und Wiederherstellung

Der Orchestrator besitzt Fail-fast und Timeout. Danach entfernt `90_Cleanup.sql` ausschließlich die vollständig markierte Datenbank. Offene Transaktionen werden nur innerhalb dieser Datenbank durch `SINGLE_USER WITH ROLLBACK IMMEDIATE` beendet.

## 11. Tests

Die Runtime-Matrix führte Problem- und Vergleichsszenario im Lauf `30108023315` je Version zweimal aus. Sie prüfte Chain Depth 2, exakte unmittelbare Blockerbeziehungen, `LCK_M_%`-Waits, positive Wartezeit, identische Endwerte, erfolgreichen Prozessabschluss und vollständiges Cleanup.

## 12. Bekannte Grenzen

Die konkrete Lock-Ressourcenbeschreibung und Wait-Dauer sind build- und schedulingabhängig. Daher werden keine festen Millisekundenschwellen verlangt; die Wartezeit muss lediglich positiv sein und die Blockerbeziehung exakt stimmen.

## 13. Quellen

| Quellen-ID | Aussagebezug | Gültigkeitsbereich | Abrufdatum |
|---|---|---|---|
| `SRC-036` | aktuelle Requests, Waits und Blocking Chain | SQL Server 2019–2025 | 2026-07-24 |
| Microsoft Learn: Understand and resolve blocking problems | Head Blocker und `blocking_session_id` | unterstützte SQL-Server-Versionen | 2026-07-24 |

## 14. Traceability

| Element | Zuordnung |
|---|---|
| Lernziel | `LO-M05-02` |
| Folie / Claim | `CLM-066`, Folie 66 |
| Demo-ID | `CON-004` |
| Testprofil | `TP-CON` |
