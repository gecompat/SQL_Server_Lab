# Initialer Backlog

## Welle 0 - Fachliche Konsolidierung

- [x] `W0-001` Quellenmanifest für Folien, Dokumente und vorhandene Demo-Artefakte erstellen.
- [x] `W0-002` Privacy- und Metadaten-Prüfverfahren definieren.
- [x] `W0-003` Folien- und Aussagenregister erstellen.
- [x] `W0-004` Kritische Bestandsaussagen gegen aktuelle Primärquellen prüfen.
- [x] `W0-005` Fehlende Themen nach Lernwert, Demo-Eignung, Aufwand, Risiko und Versionsbezug priorisieren.
- [x] `W0-006` Projektweites Quellenregister mit Pflege- und Gültigkeitsfeldern strukturieren.
- [x] `W0-007` Verbindlichen Terminologie- und Schreibstandard festlegen.
- [x] `W0-008` Konflikt- und Entscheidungslog mit Blockerwirkung und Folgearbeit einführen.
- [x] Gate A fachlich abnehmen.

## P0 - Voraussetzung

- [x] Folien, Dokumente und vorhandene Demo-Artefakte vollständig inventarisieren.
- [x] Jede fachliche Aussage der Welle 0 gegen aktuelle Primärquellen prüfen.
- [x] Curriculum-Themen, Folien und geplante Demo-IDs eindeutig zuordnen.
- [x] Kanonisches Namensschema der Demo-IDs festlegen.
- [x] Namens-, Eigentums- und Schutzschema für synthetische Testdatenbanken festlegen.
- [x] Wiederverwendbares Preflight-, Mess-, Cleanup-, Orchestrierungs- und Runtime-Framework implementieren und auf SQL Server 2019, 2022 und 2025 validieren.
- [ ] Automatisierte Privacy-Prüfung für Text-, Office- und Bildmetadaten implementieren.
- [ ] Entscheidungspfad T-SQL/Testdatenbank vor zusätzlicher Infrastruktur im Demo-Katalog abbilden.
- [x] Baseline-Review der vorhandenen Präsentationen als Review-Artefakt pflegen.
- [x] Sanitizing-Regeln für Bestandsunterlagen anwenden; nur `Gerhard Pisch` bleibt als reale Namensangabe zulässig.
- [x] Sämtliche veralteten Verweise auf externe Vorlage-Repositories entfernen.
- [x] Das bezeichnete Firmenlogo und die dazugehörigen Firmen- und Markenkennzeichen aus den geprüften Schulungsartefakten entfernen.
- [x] Bildbasierte Branding-Prüfung zusätzlich zur Text- und Metadatensuche definieren.
- [x] Projektweites Quellenregister, Terminologiestandard und Konfliktlog bereitstellen.

## P1 - Erste Umsetzung

- [x] `FWK-001` Preflight-Vertrag und Vorlage implementieren.
- [x] `FWK-002` Namens-, Schutz- und Lifecycle-Vertrag implementieren.
- [x] `FWK-003` deterministischen synthetischen Datengenerator implementieren.
- [x] `FWK-004` sessionbezogenen Messrahmen implementieren.
- [x] `FWK-005` Plan- und Statistikevidenz implementieren.
- [x] `FWK-006` deterministische Multi-Session-Orchestrierung implementieren.
- [x] `FWK-007` Query-Store- und Extended-Events-Helfer implementieren.
- [x] `FWK-008` Sicherheits- und Abbruchvertrag implementieren.
- [x] `FWK-009` vollständige Demo-Dokumentvorlage implementieren.
- [x] `FWK-010` vollständigen Runtime-Harness implementieren.
- [x] `FWK-011` Ergebnisnormalisierung und maschinenunabhängige Erwartungsverträge implementieren.
- [x] `FWK-012` Status-, Fehler- und Skip-Vertrag implementieren.
- [x] Framework-SQL auf SQL Server 2019, 2022 und 2025 parsen, deployen und im Lifecycle testen.
- [x] Zwei grüne T-SQL-Pilotdemos nach vollständigem Demo-Vertrag umsetzen und auf SQL Server 2019, 2022 und 2025 validieren (`QRY-001`, `OPT-002`).
- [x] Eine Multi-Session-Pilotdemo mit kontrolliertem Blocking in einer Testdatenbank umsetzen und validieren (`CON-004`).
- [x] Eine gelbe Ressourcen-Pilotdemo mit definierten Abbruchkriterien umsetzen und validieren (`OPT-013`).
- [x] Gate B mit statischer Prüfung und 24 vollständigen Pilotläufen abnehmen.
- [ ] Query Store und Extended Events als zentrale Diagnosepfade in Pilotdemos validieren.
- [x] `W2-001` Bestandsbeispiele vollständig als `REUSE`, `REFACTOR`, `REBUILD`, `DIAGNOSTIC_ONLY` oder `REMOVE` klassifizieren und kanonischen Demo-IDs zuordnen.
- [ ] `W2-002` interne und externe Datenabhängigkeiten der priorisierten Migrationskandidaten entfernen.
- [x] Diagnoseleitfaden als roten Faden von Symptom über Messung und Hypothese bis zum Vorher-Nachher-Vergleich integrieren.
- [x] Rollenmodell für Projektionsfolie, Sprecherhinweis, Teilnehmerunterlage und Demo-Evidenz festlegen.
- [x] Die vier aktiven `REFINE`-Claims in `W2-007` fachlich korrigieren, mit Notes/Quellen synchronisieren und gegen den aktiven Foliensatz validieren.

## P2 - Reproduktion und Testmatrix

- [x] SQL-Server-2019/2022/2025-Testmatrix definieren und erfolgreich ausführen.
- [ ] How-to für vorhandene SQL-Server-Instanz plus isolierte synthetische Testdatenbank erstellen.
- [ ] Kompakten Docker-/Podman-Bereitstellungspfad für Personen ohne verfügbaren SQL Server planen.
- [ ] Docker-/Podman-Ressourcen- oder Netzwerkfunktionen nur für konkret abhängige Demos prüfen.
- [ ] Hyper-V nur für nachweislich Windows-, Storage- oder OS-nahe Demos planen.
- [x] Wiederholbare Concurrency-Prozesssteuerung ohne proprietäre Abhängigkeiten implementieren und mit realen parallelen SQL-Sessions validieren.
- [x] Hardwareabhängige Erwartungswerte als Invarianten, Richtungen, Verhältnisse oder begründete Bandbreiten statt Fixwerte definieren.
- [ ] Vorhandene Präsentationsmodule fachlich modernisieren und mit Demo-Katalog, Quellenregister und Lernzielen synchronisieren.
- [x] Branding-bereinigte Repository-Fassung der Schulungsunterlagen bereitstellen.

## Erledigungsregel

Ein Punkt gilt nur dann als erledigt, wenn Artefakt, Quellenprüfung und zutreffende Validierung im Repository nachvollziehbar vorhanden sind. `IMPLEMENTED` ersetzt keine Runtime-Validierung ausführbarer SQL-Artefakte.
