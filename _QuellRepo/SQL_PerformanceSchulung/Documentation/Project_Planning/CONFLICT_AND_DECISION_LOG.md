# Konflikt- und Entscheidungslog

| Merkmal | Wert |
|---|---|
| Arbeitspaket | `W0-008` |
| Status | `ACTIVE` |
| Initiale Abnahme | `VALIDATED` |
| Stand | 2026-07-24 |
| Verbindliche Entscheidungen | [`.ai/DECISIONS.md`](../../.ai/DECISIONS.md) |

## 1. Zweck

Dieses Log hält fachliche, didaktische und technische Widersprüche fest, die mehrere Artefakte oder Arbeitspakete betreffen. Ein Konflikt darf nicht durch stillschweigende Änderung einer Folie, Demo oder Quelle aufgelöst werden. Die Auflösung muss nachvollziehbar auf eine Entscheidung, eine Primärquelle, eine empirische Prüfung oder eine ausdrücklich dokumentierte Zurückstellung verweisen.

Das Log ersetzt nicht die fachliche Detailprüfung einzelner Claims. Claim-spezifische Korrekturen verbleiben im Aussagenregister und in der kritischen Aussagenprüfung. Dieses Dokument erfasst die übergreifende Konsequenz und den Bearbeitungsstatus.

## 2. Statusmodell

| Status | Bedeutung |
|---|---|
| `OPEN` | Konflikt ist bestätigt; Entscheidung oder Evidenz fehlt noch. |
| `RESOLVED` | Auflösung ist entschieden und in den betroffenen Artefakten umgesetzt oder verbindlich eingeplant. |
| `DEFERRED` | Entscheidung wird bewusst bis zu einem benannten Design- oder Runtime-Schritt zurückgestellt. |
| `SUPERSEDED` | Ein früherer Konflikt wurde durch eine neuere, dokumentierte Entscheidung ersetzt. |

Ein `OPEN`-Eintrag muss einen Owner in Form eines Arbeitspakets, ein Abnahmekriterium und eine Blockerwirkung besitzen. `DEFERRED` ist nur zulässig, wenn der späteste Entscheidungszeitpunkt benannt ist.

## 3. Aktive und aufgelöste Konflikte

| ID | Konflikt | Status | Auflösung / Arbeitsauftrag | Evidenz oder Entscheidung | Blockerwirkung |
|---|---|---|---|---|---|
| `CFL-001` | Die Bestandspräsentation enthält fachlich verkürzte Aussagen und nicht freigegebene Branding- beziehungsweise Metadatenrisiken, soll aber als inhaltliche Ausgangsbasis dienen. | RESOLVED | Keine unveränderte Veröffentlichung. Der aktive Foliensatz wurde neutral und fachlich neu aufgebaut; Altmaterial bleibt Referenzquelle und wird später beispielbezogen klassifiziert. | `DEC-011`, `DEC-013` bis `DEC-016`; Baseline-Review; Quellenmanifest | Kein Blocker für Gate A; Altbeispiele bleiben bis `W2-001` inaktiv. |
| `CFL-002` | Reproduzierbarkeit könnte zu einem vorsorglichen Container-, Hyper-V- oder Mehrinstanz-Lab führen, obwohl die Schulungsziele überwiegend mit T-SQL erreichbar sind. | RESOLVED | T-SQL in einer isolierten synthetischen Testdatenbank ist der Standardpfad. Infrastruktur benötigt pro Demo eine fachliche Notwendigkeitsbegründung. | `DEC-002`, `DEC-009`, `DEC-010`; Masterplan Abschnitt 3.1 | Kein Blocker; Sonderinfrastruktur bleibt bis zum Nachweis des Bedarfs `DEFERRED`. |
| `CFL-003` | SQL Server 2025 ist Primärplattform, während die Schulung zugleich SQL Server 2019 und 2022 unterstützen soll. | RESOLVED | Engine-Version, Compatibility Level und Konfiguration werden getrennt dokumentiert. Neue Funktionen erhalten Feature-Skips oder Alternativpfade; ältere Versionen werden nicht durch pauschale 2025-Aussagen beschrieben. | `DEC-003`; Curriculum `LO-M00-04`; Terminologiestandard | Kein Blocker; wird im Test-Harness und je Demo erneut geprüft. |
| `CFL-004` | Vorläufige `DEM-*`-Kennungen und die fachlichen Präfixe des Masterplans erzeugen zwei konkurrierende ID-Systeme. | RESOLVED | Ausschließlich `FWK`, `STL`, `OPT`, `QRY`, `IDX`, `CON`, `RES`, `DGN` und `INF` sind kanonisch. Vorläufige `DEM-*`-IDs werden nicht veröffentlicht. | `DEC-018`; Traceability-Matrix Abschnitt 4 | Kein Blocker. |
| `CFL-005` | Query Patterns stehen im aktiven Foliensatz vor der physischen Indexvertiefung. Dadurch könnte ein Zugriffspfad vorausgesetzt werden, bevor B+-Tree-Internals erklärt sind. | RESOLVED | M03 behandelt den Zugriffspfad zunächst als beobachtbares Planmerkmal. M04 erklärt anschließend Struktur und Design-Trade-offs. | `DEC-019`; Curriculumarchitektur Abschnitt 4 | Kein Blocker; die Modulfolge bleibt bestehen. |
| `CFL-006` | Vier aktive Folien sind im Kern korrekt, besitzen aber noch unzureichende Versions- oder Gültigkeitsgrenzen. | OPEN | Folien 32, 34, 42 und 43 einschließlich Notes, Quellenbezug und Demo-Evidenz in `W2-007` präzisieren. | `CR-002`, `CR-004`, `CR-005`, `CR-022`; `GAP-001` | Kein Blocker für Gate A; Blocker für Präsentationsfreigabe und Gate D. |
| `CFL-007` | Für synthetische Testdatenbanken existiert noch kein Namens- und Schutzschema. Ein zu allgemeiner Name könnte versehentlich eine fremde Datenbank treffen oder unvollständiges Cleanup erlauben. | RESOLVED | `FWK-002` leitet `SQLPERF_LAB_<DEMO>_<RUN>` deterministisch ab und verlangt vor `DROP` vollständige Marker für Projekt, Vertragsversion, Demo-ID und Run-Token sowie zwei Bestätigungen. | `DEC-025`; `FWK-002_TestDatabase_Lifecycle_Contract.md`; `FWK_TestDatabaseLifecycle.sql` | Der frühere Blocker ist aufgehoben. Runtime-Validierung der Referenzimplementierung bleibt offen. |
| `CFL-008` | Herstellerdokumentation kann nachträglich geändert, umgeleitet oder versionsübergreifend dargestellt werden. Dadurch kann ein stabiler Quellenlink eine veränderte Aussage transportieren. | RESOLVED | Das projektweite Quellenregister führt Aktualisierungs- und Abrufdatum, Gültigkeitsbereich, Status und Review-Trigger. Änderungen führen zunächst zu `REVIEW_REQUIRED`. | `SOURCE_REGISTER.md`; Terminologiestandard Abschnitt 3 | Kein aktueller Blocker; erneute Prüfung bei Trigger. |
| `CFL-009` | Der Masterplan enthält mehr geplante Demo-Bündel als der aktive Foliensatz unmittelbar referenziert. Eine vollständige Umsetzung aller Kandidaten könnte den Kurs unnötig vergrößern. | RESOLVED | Die 36 folienbezogenen Bündel bilden den verpflichtenden Runtime-Kern. Weitere Bündel werden nur bei nachweisbarem Lernwert, relevanter Fehlannahme oder notwendiger Diagnoseentscheidung umgesetzt. | `CONTENT_GAP_ANALYSIS.md`; Traceability-Matrix | Kein Blocker; Umfang wird vor Design je Bündel bestätigt. |
| `CFL-010` | Linked Server, Remote Pushdown, Storage-Drosselung und OS-nahe Szenarien können zusätzliche Topologie verlangen. | DEFERRED | Erst im jeweiligen Demo-Design wird geprüft, ob die Kernaussage ohne Sonderinfrastruktur nicht glaubwürdig reproduzierbar ist. `QRY-012` und entsprechende `INF-*`-Bündel bleiben bis dahin optional. | `DEC-009`; `GAP-013`, `GAP-015` | Kein Blocker für Gate B oder den T-SQL-Kern. Spätester Entscheidungszeitpunkt: Design des betroffenen Bündels. |
| `CFL-011` | Fachbegriffe werden in älteren Materialien teilweise übersetzt, verkürzt oder synonym verwendet, obwohl sie unterschiedliche Engine-Konzepte bezeichnen. | RESOLVED | Der Terminologie- und Schreibstandard ist für alle neuen und geänderten Artefakte verbindlich. | `TERMINOLOGY_AND_STYLE_STANDARD.md` | Kein Blocker; Verstöße sind Review-Findings. |

## 4. Bearbeitungsregel

Ein neuer Konflikt wird vor der Umsetzung einer möglicherweise einseitigen Lösung eingetragen. Der Eintrag enthält mindestens:

- betroffene Artefakte oder Arbeitspakete,
- technisch widersprüchliche Annahmen,
- bekannte Quellen- oder Runtime-Evidenz,
- Entscheidungseigentümer in Form eines Arbeitspakets,
- spätesten Entscheidungszeitpunkt,
- Abnahmekriterium und Blockerwirkung.

Bei einer Auflösung werden die betroffenen Artefakte gemeinsam aktualisiert. Eine Entscheidung in `.ai/DECISIONS.md` wird ergänzt, wenn die Auflösung projektweit verbindlich ist. Frühere Entscheidungen werden nicht gelöscht, sondern durch eine explizite Nachfolgeentscheidung überholt.

## 5. Abnahme von W0-008

Die bekannten übergreifenden Konflikte sind erfasst. Offene Punkte besitzen einen Arbeitsauftrag, einen Entscheidungszeitpunkt und eine dokumentierte Blockerwirkung. Damit ist das initiale Konflikt- und Entscheidungslog für `W0-008` validiert. Das Dokument bleibt bis zum Projektabschluss aktiv.
