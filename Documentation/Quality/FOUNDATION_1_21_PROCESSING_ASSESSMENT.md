# Foundation 1.21: Verarbeitung und Prüfwege

Dieser begrenzte Auftrag aktualisiert Foundation 1.19.0 auf 1.21.0, Source
`d720db4f2f0d043756a958d5195d0e62090b1c8f`. Der Copilotadapter und
`rule-context-cache` bleiben ausgewählt. Andere optionale Runtimes, Router,
Planner, Kennungsmigrationen und Repository-Bypässe werden nicht ausgewählt.
Das vollständige Delta umfasst 22 einzeln klassifizierte Features in
[der Upgradebewertung](../../.ai/foundation-upgrade-assessments/1.19.0-to-1.21.0.json).
Rootlizenz, vollständiger Foundationhinweis und historische Kennungen bleiben erhalten.

## Tatsächliche Ausführungswege

| Bereich | Vorher | Korrektur und Aussagegrenze |
|---|---|---|
| A: Provider und Fähigkeit | Docker-Lifecycle führte zwölf, Podman dreizehn Harnessaufrufe nacheinander aus. | Provider behalten den einzelnen SQL-2025-Lifecycle mit Autostart. Zusätzliche feste Capability-IDs werden additiv nach Feature und Voraussetzungen ausgewählt; Workflows bestätigen ihr erfolgreich abgeschlossenes Inventar. Der PR-Gate vergleicht angefordertes und abgeschlossenes Inventar. Nightly und direkte Aufrufe ohne Scope behalten das vollständige Paket. Hyper-V/Mixed/Adapter behalten ihren einzelnen bestehenden Baselineharness; spezielle manuell geschützte Hyper-V-Modi werden nicht aktiviert. |
| B: Wirkung von Infrastruktur | Selektor und dessen statische Assertions verlangten pauschal fünf Runtimejobs. | Reine Selektor-/Zuordnungsverträge erhalten deterministische Selbsttests. Gemeinsame ausführbare Orchestrierung, Ownership, Cleanup, Modulloader, Common, StateMachine und ManifestParser behalten fünf Runtimejobs. Unbekannte Produktreichweite behält konservativ alle fünf Provider und alle Containerfähigkeiten; bekannte Featuretreffer können ihn nicht verkleinern. |
| C: Dokumentationsauslöser | `STOP_HOST_MEMORY.md` wählte Docker/Podman trotz DocumentationOnly. | Dokumentationspfade können statische Verträge auswählen, lösen über Dateinamen keine Runtime aus. Runtimebehauptungen benötigen zusätzlich einen ausdrücklich gewählten Fachnachweis; Prosa allein attestiert keinen Providerlauf. |
| D: Suiteinterner Scope | Pester und Analyzer liefen auch lokal projektweit. | `-Development` übergibt geänderte Pfade. Analyzer prüft vorhandene betroffene PowerShell-Dateien; Pester berücksichtigt Modulimport/Exports, Lifecycle, Scanner und eigene Tests. Gemeinsame Modul-/Test-/Analyzerkonfiguration oder unbekannte Zuordnung verlangt globalen Scope. Ohne Development bleiben Integration, Qualifikation und Release global. Projektweite Analyzer-Baselinecounts dürfen neue Fehler im kleinen Scope nicht freigeben. |
| E: lokale Wiederverwendung | Jede ausgewählte Suite lief erneut. | Nur explizite lokale Development-Aufrufe können ausgeführte Documentation-/CiStrategy-Ergebnisse vier Stunden wiederverwenden. Bindung: gesamter Git-Quellbestand einschließlich unversionierter aktiver Dateien, Index, ChangedPaths, konkrete Child-Executable und deren vollständiger Runtime-Dateibaum, Gitbytes, PowerShell/.NET und Prozessumgebung. Loghash, Zeit, Status, Exitcode und Endbindung werden geprüft. Andere Suites und Runtimeprüfungen bleiben uncachebar. CI verwendet keine Wiederverwendung. FAIL/RUNNING/UNKNOWN, fehlende oder geänderte Evidence und verlorene Bindungen verlangen Ausführung. Eine belegte Writer-Sperre liefert NOT_EXECUTED ohne Kindprozess. |
| F: Validierungsphasen | Beispiele und Regeln vermischten Diagnose mit breiten Abnahmen. | Entwicklung, PR-Integration, volle Qualifikation und Release besitzen getrennte Aussagen. Sechs Foundationstufen sind sechs Aussagen, keine sechs obligatorischen einzelnen Läufe. Ein aktuelles Pflichtgate bleibt vor Merge erforderlich. |
| G: Textbindung | Aktive Foundationversion/Quellcommit und allgemeiner Status waren an historische Literale gebunden. | Aktive Versions-/Provenienzverträge werden aus strukturierten Receipts, Katalog und Upgradebewertung geprüft. Allgemeine Standfelder und historische Abnahmedaten verlangen Datumsstruktur statt einen alten Stichtag. Runtime-Status und N5-Gerätevertrag werden über strukturierte Mapfelder abgesichert; Projekt-IDs und falsche Altbehauptungen bleiben geprüft. Historische Quell-/Run-IDs, Lizenztext, öffentliche Befehle, Menü-IDs und fachliche Negativkontrollen bleiben dort exakt, wo die Identität selbst Vertragsinhalt ist. |

## Begrenzte konservative Ausnahmen

- Gemeinsame ausführbare CI-/Ownership-/Cleanupänderungen behalten die Matrix:
  sie steuern Arrange und Recovery auf persistenten Runnern. Selektorselbsttests
  allein können diese Effekte nicht empirisch nachweisen.
- Der lokale Ergebniscache bindet zunächst den gesamten aktiven Quellbestand.
  Kleine Änderungen können daher unnötig invalidieren. Ein schmalerer Cache
  benötigt einen vollständigen geprüften transitiven Abhängigkeitskatalog je
  Suite; ein Namensfilter genügt nicht. Diese konservative Überbindung schützt
  gegen ein wiederverwendetes PASS nach einer unerkannten gemeinsamen Änderung.
- Modul-Pester und globale Analyzerkonfiguration bleiben breiter: alle
  Private-/Public-Dateien werden vom Modul geladen; unbekannte Test-/Schema-/Katalogabhängigkeiten verlangen globalen Scope; globale Errorbaselinecounts
  besitzen bisher keine sichere Freigabe je Datei. Ein Teilcount ist daher kein
  Ersatz für den globalen Integrationsvergleich.
- Zwei bereits integrierte private SMTP-Offlinehelfer erhalten ihre MIME-/
  synthetische HTTP-Suite. Sie arrangieren weder Provider noch SQL; ihr
  früherer Docker-Fallback war kein geeigneter fachlicher Nachweis. Eine
  gekoppelte echte Providerdatei behält unabhängig ihren Runtimegate.
- Self-hosted Runtime-Cancellation bleibt ausgeschaltet. Eine kleinere
  Abbruchalternative ist ohne belegten Cleanup-/Recoveryvertrag unzureichend.
  Keine neuen Bypassrechte, Shared-Consent-Flags oder manuell geschützten Modi.

## Instruktionen, Reviews, Logs und Fortsetzung

Native AGENTS-Discovery bleibt pro Einstieg erforderlich. Zusätzliche Regeln
werden nach betroffenem Scope gelesen; Discoverability ist keine Bulk-Leseliste.
Tatsächlich verfügbare Sessionanalyse darf nur bei aktueller unveränderter
Autoritäts-/Inhalts-/Scope-/Abhängigkeitsbindung wiederverwendet werden.
Fehlende Analyse bleibt fehlend; Regelcache ist kein Testergebniscache.

Ein Writer bearbeitet diesen kohärenten Scope. Die getrennte read-only Analyse
beantwortet die konkrete Capability-/Consumerfrage; eine unabhängige Prüfung
des fertigen Cache-/Gatevertrags bewertet Fehl-PASS-Risiken. Hashes, Counts und
grüne Logs werden deterministisch geprüft, ohne Review-von-Review-Kette.
Rohlogs und Cache bleiben unter ignorierten lokalen Artefaktwurzeln. Ein Modell
erhält deduplizierte neue Findings, keine vollständigen grünen Logs.

Die frühere autonome Entwicklungswelle wurde auf Benutzerauftrag beendet und
ihr Heartbeat gelöscht. Dieser Auftrag eröffnet nur das Foundation-/Prüfscope.
Ein Timer oder unveränderter Zustand erzeugt keine neue Arbeit. Tatsächliche
Modell-/Tierausführung, Tokenverbrauch und Einsparungen sind nicht attestiert.

## Nachweise

Lokal ausgeführt: Foundationintegrität 78 Informationen, keine Warnung oder
Fehler; Dokumentationsvertrag 1872/0; CI-Strategie nach Korrektur 566/0;
abschließende Scope-/Cachefixture 65/0 mit echten Parentaufrufen und nachweislich
nur einem Kind bei zwei unveränderten Developmentaufrufen. Globale Pester-
Abnahme 23/0 ohne übersprungene Fälle; korrigierte Runnerfixture 14/0.
Development-Pester prüfte sieben Fälle; Development-Analyzer genau eine Datei.
Der globale Analyzer hielt die unveränderten 24 genehmigten Baselinefehler
ein und meldete 5652 Warnungen; keine neuen blockierenden Fehler.

Der erweiterte erste lokale Lauf scheiterte an alten Selektorannahmen und
zwei Aufruferrandfällen. Originalfehlversuche bleiben private Evidence;
unverändert erfolgreiche Suites wurden nicht nochmals gestartet. Die spätere
Korrekturprüfung und zusätzliche fokussierte Fixture sind getrennte Nachweise,
keine Umdeutung des fehlgeschlagenen Sammellaufs.

Der erforderliche CI-Gate am veröffentlichten finalen Head ist zusätzlich
verpflichtend. Foundationintegrität ersetzt keine Projektsuite und keine
native Providerabnahme. Das Upgrade attestiert keine höhere minimale Runtime,
keine vollständige SQL-/Providerqualifikation und keine gemessene Ersparnis.
