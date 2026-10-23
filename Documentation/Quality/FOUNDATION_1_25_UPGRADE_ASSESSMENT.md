# Foundation 1.25.0: semantische Integration und Dokumentationswege

Stand: 2026-10-23. Ausgang ist Foundation 1.24.0. Die Übernahme folgt auf den
abgeschlossenen Linux-TLS-Clientscope; sie erweitert keine TLS-, Provider-,
Trust-, Setup- oder Recoveryfreigabe.

## Quelle, Delta und Erhaltung

Quelle ist [AI Repository Foundation 1.25.0](https://github.com/gecompat/AI_Repository_Foundation/tree/a3567f8e5372e5f4db72dbd466323aa22c71b13a),
Commit `a3567f8e5372e5f4db72dbd466323aa22c71b13a`. Die
[maschinenlesbare Bewertung](../../.ai/foundation-upgrade-assessments/1.24.0-to-1.25.0.json)
erfasst den vollständigen Versionsdelta: genau ein neues Feature,
`human-documentation-paths`, mit `APPLY_DEFAULT`. Die neun Kandidaten des
historischen 1.21-/1.24-Upgrades und dessen Negativfälle bleiben eigenständig
erhalten; sie werden nicht zu einer neuen Bewertung umgedeutet.

Die Auswahl bleibt ein Adapter (`github-copilot`) und eine Capability
(`rule-context-cache`) mit 77 Manifestzielen. Zehn Quellziele ändern sich.
Der verwaltete Root-Bridgeblock wird semantisch übernommen; die übrigen
Projektregeln bleiben erhalten. Die erneuerte Provenienz bindet Quellpin,
Version, Auswahl und portable Zielhashes. Die Projektlizenz und der geschützte
README-Lizenzblock bleiben in Inhalt und logischer Leseposition erhalten.
Foundation-Projekt-README, Lizenz, Backlog, Status und Identitätsregistry werden
nicht als Projektinhalt kopiert. Keine weitere Capability wird aktiviert.

Die neue Dokumentationsregel ist `COMPLEMENTARY`. Strengere Privacy-,
Ownership-, Cleanup-, Provider- und aktuelle CI-Gates bleiben `PROJECT_STRONGER`;
Deutsch, Projektlizenz und KI-Commitpräfix bleiben `PROJECT_SELECTABLE_OVERRIDE`.
Die Regel erzeugt weder ein neues Dokumentationsregister noch Pflichtmetadaten,
einen weiteren Validator oder eine automatische Reviewkette.

## Geprüfter Lesepfad und Dokumentationswirkung

Der Einstieg beginnt in der [Root-README](../../README.md) mit Zweck, Zielgruppe,
verfügbarem Umfang und Grenzen. Der [Dokumentationsindex](../README.md) trennt
Bedienung, gemeinsame technische Quellen, Planung/Evidence und den benannten
KI-Einstieg. Der [Getting-Started-Pfad](../User/Getting_Started.md) führt zuerst
durch Voraussetzungen, Checkout, Import, Root-Einrichtung, Ressourcen,
Erstellung, Verbindung und eigenen Cleanup. Vorgezogene optionale Features,
Wartung, Medienvorbereitung und Windows-Spezialabläufe stehen anschließend als
Vertiefung. Bestehende Befehlsbeispiele und Anker bleiben erhalten.

Ein technischer Inspektionsweg führt von [AGENTS.md](../../AGENTS.md) über die
[Repository-Map](../../.ai/repo_map.yaml) zum
[Manifestvertrag](../Architecture/MANIFEST_AND_INTERFACE_ARCHITECTURE.md),
[Schema](../../Schemas/lab-manifest.schema.json),
[Parser](../../Private/ManifestParser.ps1) und den in der
[Validierungsstrategie](LOCAL_VALIDATION_STRATEGY.md) benannten Prüfungen.
Provenienz bestätigt importierte Regeln, nicht SQL-Verhalten oder Lesbarkeit.

Konkrete widersprüchliche Aussagen werden berichtigt: Der geführte
Browser-Komponentenplan besitzt seinen eigenen Dialog und HTTP-Pfad;
der generische Zugang ist zusätzlich verfügbar. Die Windows-Prepared-Collation
besitzt einen begrenzten nativen SQL-2025-Nachweis; andere Versionen und
Collations werden dadurch nicht qualifiziert. Einstiegstexte verweisen für
Teststände auf datierte Nachweise statt eine zweite Testchronologie zu führen.
Der TLS-Einstieg nennt die drei qualifizierten Windows-Containerprofile und
trennt die vorhandene Konfigurationsanzeige von der noch offenen aktuellen
Livequalifikation. Zwei bisher nur im Einleitungstext genannte öffentliche
Run-Artefaktbefehle sind im API-Index explizit auffindbar.

Die verbleibende Konsolidierung anderer gewachsener Dokumentationsbereiche ist
im [vorhandenen Masterplan](../Project_Planning/MASTER_IMPLEMENTATION_PLAN.md)
mit Scope, zuständiger Rolle und Wiederaufnahmeauslöser erfasst. Neue und
materiell geänderte Pfade folgen der Regel. Das ist keine Aussage über eine
vollständige Konformität des gesamten historischen Dokumentationsbestands.

## Erforderliche Bewertung des Verarbeitungsaufwands

| Tatsächlicher Weg oder Auslöser | Disposition und begrenzter Schutzgrund |
|---|---|
| Native AGENTS-Kette und betroffene Projektquellen | Aktuelle Discovery bleibt erforderlich. Bereits verfügbare Analyse wird nur nach Prüfung von Inhalt, Scope und Abhängigkeiten wiederverwendet. Die vorhandenen Regeln verlangen betroffene Abschnitte, keinen vollständigen Dokumentationsimport vor jedem Edit. |
| Foundation-Transfer und Provenienz | Bestehende Manifestselektion und offizielle Werkzeuge prüfen alle 77 ausgewählten Ziele. Es gibt keine neue Capability, Telemetrie, Registry oder Aktivierung eines Ausführungsadapters. |
| Dokumentationswirkung | Der vorhandene Diff, die Repository-Map und gezielte Quellensuchen wählen Leserpfade und notwendige Fortsetzungen aus. Änderungen an Verhalten, Konfiguration, Schema oder Ablage lösen dieselbe Prüfung aus, auch ohne bisherige Dokuänderung. Kein Corpus- oder Modellaufruf allein wegen eines neuen Commits. |
| Lokale Tests und Selektor | Das konkrete 22-Pfad-Paket wählt acht statische Suites. Der vorhandene Impact-Runner führt den Dokumentationsvertrag einschließlich historischer und aktueller Assessment-Oracles zusammen mit der betroffenen Regression aus; kein zusätzlicher direkter identischer Doku-Komplettlauf. Unveränderte grüne Produkt-/Native-Matrizen werden nicht wiederholt. Unsichere Abhängigkeiten behalten den konservativen größeren Fallback. |
| Aktuelle PR-Gates | Root-Bridge und gepinnter Workflow sind governancewirksame Eingaben. Der vorhandene Fallback wählt die fünf Runtimegates; beide statischen CI-Plattformen und das getrennte Foundation-Integrity-Gate bleiben erhalten. Lokale Development-Evidence ersetzt mangels geschütztem Remote-Producer/Verifier keine aktuelle CI; eine Verkleinerung dieser Grenze braucht einen eigenen nachgewiesenen Änderungsscope. |
| Doppelte Prüfungen | Dokumentationschecks prüfen Projektverweise, Katalogintervall und negative Assessment-Fälle. Der offizielle Foundationvalidator prüft Installationsintegrität. Das sind verschiedene Oracles; derselbe Validator wird lokal für dieselbe Bindung nicht zusätzlich direkt und über eine zweite Suite ausgeführt. Frische vorgeschriebene CI bleibt getrennt. |
| Logs und Erfolgsbewertung | Bestehende Runner und lokale deterministische Auswertung liefern Status und begrenzte Findings. Vollständige Rohlogs bleiben lokal außerhalb Git. Ein grüner Lauf benötigt keinen weiteren Modellaufruf nur zur Bestätigung. Belastbare Verbrauchsmessung fehlt; es werden keine Geld- oder Tokeneinsparungen behauptet. |
| Reviews und Modelle | Ein Implementierungsverantwortlicher, ein vorhandener unabhängiger Reviewer für den kohärenten Scope; keine zusätzlichen Agenten und keine Review-of-Review-Kette. Weitere Durchgänge brauchen ein konkretes Finding oder eine geänderte relevante Bindung. |
| Warten und Pausen | Ein Beobachter je laufendem Auftrag, begrenzte Abfragen mit Backoff und stiller unveränderter Wartezustand. Kein neuer Scheduler oder Heartbeat. Pause, echte Blocker und unveränderte Budgetgrenzen bleiben maßgeblich. |

## Validierung und Grenzen

Der Autor prüft die genannten Einstiegs-, Erstnutzungs- und technischen
Inspektionspfade im geänderten Kontext. Bestehende Link-, Schema-, Privacy-,
Dokumentations-, Analyzer- und CI-Verträge bleiben die Prüfwege. Die aktuelle
ausgeführte lokale und CI-Evidence wird in der zugehörigen PR-Beschreibung
gebunden; ein Integrity-PASS allein bestätigt keine Lesbarkeit.

Diese Übernahme verändert keine SQL- oder Providerimplementierung.
Zusätzliche native SQL-, CA-, Trust-, Key-, VM-, Setup- oder Recoveryabnahmen
werden dafür nicht ausgeführt. Die vorhandenen TLS-Nachweise behalten ihren
datierten Scope; die offenen TLS-001-Arbeiten werden anschließend getrennt
fortgesetzt.
