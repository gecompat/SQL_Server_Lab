# Verbindliche Projektregeln

## Repository-Grenze

- Schreibziel ist ausschließlich `gecompat/SQL_PerformanceSchulung`.
- Andere Repositories dürfen durch Arbeiten an diesem Projekt nicht verändert werden.
- Eine lesende Nutzung anderer Quellen ist nur zur fachlichen oder lizenzbezogenen Referenz zulässig.

## Datenschutz und Neutralisierung

- Repository-Inhalte verwenden ausschließlich synthetische Labordaten.
- Keine realen Personen-, Kunden-, Firmen-, Organisations-, Umgebungs- oder proprietären Informationen, sofern sie nicht ausdrücklich freigegeben sind.
- `Gerhard Pisch` ist als Namensangabe freigegeben.
- Das vom Auftraggeber bezeichnete Firmenlogo sowie die dazugehörigen Firmen- und Markenkennzeichen sind aus allen Repository-Artefakten zu entfernen.
- Weitere Firmeninformationen, Logos, Kontaktdaten oder interne Systembezeichnungen dürfen in Präsentationen und Begleitmaterialien nicht enthalten sein.
- Office-Metadaten, Bilder, Screenshots, Logs und Diagnoseausgaben sind vor jeder Übernahme ausdrücklich zu prüfen.
- Bildbasierte Logos und Markenkennzeichen sind zusätzlich visuell zu prüfen; eine reine Textsuche ist nicht ausreichend.
- Bei Unsicherheit ist die Dateierstellung oder Git-Operation anzuhalten und eine ausdrückliche Freigabe einzuholen.

## Fachliche Qualität

- Technische Aussagen gegen aktuelle Primärquellen prüfen.
- Version, Compatibility Level und Edition nicht vermischen.
- Dokumentierte Fakten, empirische Beobachtungen und Vermutungen klar unterscheiden.
- Keine pauschalen Tuning-Regeln ohne Voraussetzungen, Messmethode und Trade-offs.
- Veraltete Aussagen korrigieren, nicht aus Kompatibilitätsgründen konservieren.

## Umsetzung

- T-SQL bevorzugen.
- Infrastruktur nur verwenden, wenn der Effekt mit T-SQL allein nicht glaubwürdig demonstrierbar ist.
- Demos idempotent und wiederholbar aufbauen.
- Setup und Cleanup voneinander trennen.
- Globale Cache-, Konfigurations- und Neustart-Eingriffe ausschließlich in isolierten Laborinstanzen.
- Keine produktiven Zugangsdaten oder Secrets im Repository.

## Validierung

- Statische Sicherheits- und Datenschutzprüfung.
- Syntax- und Vertragsprüfung.
- Laufzeittest auf den unterstützten SQL-Server-Versionen, soweit die Demo dort verfügbar ist.
- Erwartete Resultate und tolerierte Abweichungen dokumentieren.
