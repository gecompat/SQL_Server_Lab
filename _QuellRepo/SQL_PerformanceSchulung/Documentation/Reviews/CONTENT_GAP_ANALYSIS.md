# Priorisierte Inhalts- und Evidenzlücken

| Merkmal | Wert |
|---|---|
| Arbeitspaket | `W0-005` |
| Status | `VALIDATED` |
| Stand | 2026-07-24 |
| Bewertungsbasis | 84 aktive Folien, 84 Claims, 43 Lernziele, 36 folienbezogene Demo-Bündel und 68 geplante fachliche Demo-Bündel |
| Primäre Folgearbeit | Welle 1, `W2-007` sowie die fachlichen Wellen 3 bis 9 |

## 1. Zweck und Methode

Die Analyse bewertet nicht nur fehlende Überschriften. Eine fachliche Lücke liegt vor, wenn eine für das Lernziel erforderliche Ursache-Wirkungs-Beziehung, Versionsgrenze, Diagnoseevidenz oder sichere Reproduktion noch nicht ausreichend abgedeckt ist. Grundlage sind der aktive Foliensatz, das Aussagenregister, die kritische Aussagenprüfung, die Curriculumarchitektur, die Traceability-Matrix und der im Masterplan vorgesehene Demo-Bestand.

Die Priorität ergibt sich aus fünf Kriterien:

1. **Lernwert:** Bedeutung für den gemeinsamen Diagnosepfad und die Fähigkeit, Fehlentscheidungen zu vermeiden.
2. **Demo-Eignung:** Möglichkeit, die Aussage mit synthetischen Daten und reproduzierbarer Evidenz zu prüfen.
3. **Umsetzungsaufwand:** erwartete Größe unter Berücksichtigung von Versionen, Multi-Session-Steuerung und Cleanup.
4. **Risiko:** Belastung oder Veränderung der Testinstanz sowie Gefahr einer fachlich irreführenden Verkürzung.
5. **Versionsbezug:** Abhängigkeit von Engine-Version, Compatibility Level, Datenbankkonfiguration, Edition oder Betriebssystem.

Die Bewertung unterscheidet Inhaltslücken von Implementierungslücken. Eine vorhandene korrekte Folie ist noch keine validierte Demo; eine geplante Demo ersetzt umgekehrt keine verständliche fachliche Erklärung.

## 2. Ergebnis der curricularen Prüfung

Es ist kein zusätzliches Hauptmodul erforderlich. Die acht bestehenden Module decken den notwendigen Lernpfad vollständig ab. Die offenen Punkte sind Vertiefungen, kontrollierte Präzisierungen oder noch fehlende Runtime-Evidenz innerhalb der bestehenden Struktur.

Die 36 bereits folienbezogenen Demo-Bündel bilden den verpflichtenden Kern der späteren Runtime-Abdeckung. Weitere im Masterplan vorgesehene Bündel erweitern diesen Kern, dürfen jedoch nur aufgenommen werden, wenn sie ein Lernziel, eine relevante Fehlannahme oder eine Diagnoseentscheidung sichtbar verbessern. Infrastruktur ist daraus nicht automatisch abzuleiten.

## 3. Priorisierte Gap-Liste

| ID | Priorität | Lücke | Lernwert | Demo-Eignung | Aufwand | Risiko | Version / Voraussetzung | Entscheidung und Folgearbeit |
|---|---:|---|---|---|---:|---|---|---|
| `GAP-001` | P0 | Vier aktive Aussagen benötigen eine sichtbare Präzisierung: Plan-Cache-Kontext, Memory-Grant-Feedback-Persistenz, Eignungsheuristik für Table Variables und Interleaved Execution bei MSTVFs. | Hoch | Hoch | M | Fachlich hoch, technisch grün | SQL Server 2019–2025; CL 140/150; Query Store `READ_WRITE` je Funktion | In `W2-007` vor Präsentationsfreigabe korrigieren; zugehörige Demos `OPT-007`, `OPT-014`, `QRY-008` und `QRY-009` validieren. |
| `GAP-002` | P0 | Gemeinsamer Preflight-, Mess-, Sicherheits-, Fehler- und Cleanup-Vertrag ist noch nicht ausführbar. | Sehr hoch | Voraussetzung aller Demos | L | Ohne Framework hohes Fehlbedienungs- und Vergleichsrisiko | 2019, 2022 und 2025; Rechte und Konfiguration je Demo | `FWK-001` bis `FWK-012` bilden den unmittelbaren nächsten Workstream. |
| `GAP-003` | P0 | Für die 36 folienbezogenen Demo-Bündel fehlt Runtime-Evidenz einschließlich wiederholbarer Baseline, Gegenmaßnahme und Vergleich. | Sehr hoch | Hoch | XL, modular | je Bündel Grün bis Rot | zutreffende Versionsmatrix | Nach Gate B schrittweise umsetzen; keine Folienzuordnung als Runtime-Nachweis behandeln. |
| `GAP-004` | P0 | Query Store und Extended Events sind fachlich eingeordnet, aber Aktivierung, Scope, Retention, Overhead, Export und Cleanup sind noch nicht als sichere Schulungspfade beschrieben. | Hoch | Hoch | L | Gelb bei unkontrollierter Erfassung | Query Store-Konfiguration; XE-Ereignis- und Targetwahl | `FWK-007`, `DGN-003` und `DGN-005` gemeinsam entwerfen; Livezustand, Historie und Ereignisevidenz getrennt halten. |
| `GAP-005` | P0 | Blocking Chain, Head Blocker und Deadlock-Zyklus besitzen noch keine deterministische Multi-Session-Evidenz mit Abbruch und Recovery. | Hoch | Sehr hoch | L | Gelb | alle Zielversionen; mindestens zwei Sessions | `FWK-006`, `CON-004` und `CON-006`; Pilotkandidat für Gate B. |
| `GAP-006` | P0 | Synthetische Testdatenbanken besitzen noch kein verbindliches Namens-, Eigentums-, Schutz- und Lifecycle-Schema. | Hoch | Frameworkvoraussetzung | M | Hohes Cleanup-Risiko ohne Schutzvertrag | instanzweit | Vor Implementierung fachlicher Demos in `FWK-002` entscheiden und statisch prüfbar machen. |
| `GAP-007` | P1 | Statistik-Sampling, Skew, Histogrammgrenzen, Ascending Key sowie synchrone und asynchrone Statistikpflege sind im aktiven Deck nur verdichtet. | Hoch | Sehr hoch | M | Grün | versions- und CL-abhängige CE-/IQP-Effekte | Über `OPT-003` und `OPT-005` vertiefen; keine universellen Aktualisierungsschwellen lehren. |
| `GAP-008` | P1 | VLF-Struktur, ungeplantes Logwachstum, Commit-Batching und `WRITELOG` benötigen getrennte Evidenzketten. | Hoch | Hoch | L | Gelb bis Rot | Dateisystem und Recovery Model beachten | `STL-008` und `STL-009`; Rotanteile nur in isolierter Testinstanz. |
| `GAP-009` | P1 | TempDB-Kosten werden als Klassen benannt, aber temporäre Objekte, Worktables/Spills, Version Store, Allocation und Metadaten-Contention sind noch nicht diagnostisch getrennt demonstriert. | Hoch | Hoch | L | Gelb | Feature- und Plattformgrenzen dokumentieren | `CON-009` in Teilbeobachtungen gliedern; Ursache nicht aus TempDB-Größe allein ableiten. |
| `GAP-010` | P1 | Waits benötigen einen reproduzierbaren Scope-Vertrag: aktueller Task-Wait, Request-Wait, instanzweites Delta und bestätigende Gegenprobe. | Hoch | Hoch | M | Gelb bei Lastdemos | alle Zielversionen | `RES-007` und Messrahmen `FWK-004`; Wait Type nur als Hypothesenstart verwenden. |
| `GAP-011` | P1 | Index Maintenance benötigt messbare Verbindung zwischen Page Split, logischer Fragmentierung, Page Density, Scananteil und tatsächlicher Workloadwirkung. | Hoch | Hoch | M | Gelb | 2019–2025 | `IDX-006`; feste Prozentgrenzen ausdrücklich vermeiden. |
| `GAP-012` | P1 | Planwarnungen für Sort-, Hash- und Exchange-Spills sowie Required/Desired/Requested/Granted/Used Memory sind noch nicht in einer gemeinsamen Plan- und DMV-Evidenz dargestellt. | Hoch | Hoch | L | Gelb | versionsabhängige Planattribute und Feedbackfunktionen | `FWK-005`, `OPT-013` und `OPT-014` gemeinsam konzipieren. |
| `GAP-013` | P2 | Remote Pushdown und Linked-Server-Verhalten sind provider-, Collation-, Verschlüsselungs- und topologieabhängig. | Mittel | Mittel | L | Rot beziehungsweise externe Abhängigkeit | insbesondere SQL Server 2025 und OLE DB Driver 19 | `QRY-012` zunächst als optionales Sonderlab behandeln; nicht Bestandteil von Gate B. |
| `GAP-014` | P2 | Columnstore-Maintenance, Rowgroup-Qualität und Segment Elimination benötigen größere Datenmengen und hardwareabhängige Laufzeiten. | Mittel bis hoch | Hoch | L | Gelb | Edition, Version, Datenmenge | `IDX-009` und `IDX-010`; relationale Erwartungen statt fixer Laufzeiten verwenden. |
| `GAP-015` | P2 | OS-, Storage-, Netzwerk- oder Mehrinstanz-Szenarien sind noch nicht begründet einzelnen Lernzielen zugeordnet. | Situativ | Niedrig bis mittel | XL | Rot | Plattformabhängig | Bis zum Nachweis einer nicht mit T-SQL erzeugbaren Kernaussage `DEFERRED`; kein vorsorglicher Infrastrukturaufbau. |

## 4. Abgrenzung zwischen Pflichtkern und Erweiterung

Für Gate B werden vier Pilotdemos benötigt. Die fachlich geeigneten Kandidaten sind:

| Gate-B-Rolle | Kandidat | Begründung |
|---|---|---|
| Grüne Single-Session-Demo | `QRY-001` SARGability | geringe Betriebsgefahr, klare Plan- und Read-Evidenz, direkter Entwicklerbezug |
| Grüne Plan-/Statistik-Demo | `OPT-002` beziehungsweise `OPT-003` | verbindet Verteilung, Schätzung und Planwahl ohne globale Instanzänderung |
| Gelbe Multi-Session-Demo | `CON-004` Blocking Chain | prüft Orchestrierung, Timeout, Recovery und Head-Blocker-Evidenz |
| Gelbe Ressourcen-Demo | `OPT-013` Spill oder `OPT-014` Memory Grant | prüft Abbruchkriterien, Planwarnungen und hardwareabhängige Bandbreiten |

Die endgültige Auswahl erfolgt im Framework-Design. Sie darf nur geändert werden, wenn alle vier Rollen weiterhin abgedeckt sind.

## 5. Gate-A-Bewertung

Die fehlenden Themen sind priorisiert, vorhandenen Modulen und Arbeitspaketen zugeordnet und nach Lernwert, Demo-Eignung, Aufwand, Risiko und Versionsbezug bewertet. Offene fachliche Punkte sind als kontrollierte Folgearbeit dokumentiert. Damit erfüllt `W0-005` sein Abnahmekriterium.

Die Gap-Liste ist bei Änderungen an Curriculum, aktivem Foliensatz, Demo-Katalog oder Zielversionen erneut zu prüfen. Ein neuer Themenvorschlag darf nicht allein aufgrund technischer Attraktivität aufgenommen werden; erforderlich ist ein nachweisbarer Beitrag zu Lernziel, Diagnoseentscheidung oder Fehlannahme.