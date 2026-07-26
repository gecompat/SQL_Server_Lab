# Repository- und ZIP-Datenschutzgate

**Stand:** 18. Juli 2026  
**Backlog:** SC-001 / RQ-001  
**Status:** IMPLEMENTED_AUTOMATED_GATE  
**Prüfskript:** `Code/Tests/Static/910_Validate_Repository_Privacy.py`  
**Workflow:** `.github/workflows/repository-privacy-validation.yml`

## Zweck und Grenze

Das Gate prüft ausschließlich versionierte Repositorydateien und ein daraus erzeugtes Liefer-ZIP. Es verändert keine Resultsets, OUTPUT-Parameter sowie RAW-, CONSOLE- oder JSON-Ausgaben der Diagnose-Procedures.

Die automatische Prüfung ist ein unterstützender Blockierfilter. Sie kann reale Identitäten, Firmenbezüge oder proprietäre Strukturen nicht vollständig erkennen und ersetzt deshalb niemals die vorgeschriebene kontextbezogene Review. Ein uneindeutiger Treffer stoppt die Datei- oder Git-Operation und erfordert eine nicht sensitive Alternative.

## Ausführung

Repository und Selbsttests:

```text
python3 Code/Tests/Static/910_Validate_Repository_Privacy.py --repository-root . --self-test
python3 Code/Tests/Static/910_Validate_Repository_Privacy.py --repository-root .
```

Repository und vorhandenes Liefer-ZIP:

```text
python3 Code/Tests/Static/910_Validate_Repository_Privacy.py --repository-root . --archive-path <ZIP>
```

Das ZIP muss ausschließlich den Root `SQL_Server_Analyze/` enthalten. Git-Metadaten, weitere Root-Verzeichnisse, Pfadtraversierung, generierte Installer, Logs, Sicherungen, SQL-Pläne, Extended-Events-Dateien und verschachtelte ZIP-Dateien werden blockiert.

## Geprüfte Musterklassen

- expliziter, ausschließlich im Selbsttest erzeugter Blockier-Sentinel;
- E-Mail-Adressen;
- IPv4-Adressen;
- GUID-Werte;
- UNC- und Benutzerprofilpfade;
- private Home-Pfade;
- Private-Key-Marker;
- verdächtige Secret-Zuweisungen;
- nicht generische statische `USE`-Datenbankkontexte;
- binäre oder nicht UTF-8-dekodierbare versionierte Inhalte.

Die Datei `Metadata/Quality/Repository_Privacy_Allowlist.csv` darf nur technisch notwendige, geprüfte öffentliche oder synthetische Ausnahmen anhand eines pfadgebundenen SHA-256-Matchwerts enthalten. Blockier-Sentinels und ZIP-Strukturfehler sind niemals erlaubnisfähig. Ein neuer Allowlist-Eintrag benötigt weiterhin eine manuelle fachliche und datenschutzbezogene Review.

## Datenschutzkonforme Ausgabe

Ein Fehler nennt ausschließlich Scope, stabilen Regelcode, Repository- beziehungsweise ZIP-Pfad und Trefferanzahl. Der gefundene Inhalt, ein Secret, eine Identität oder ein sonstiger Matchwert wird weder ausgegeben noch als Artefakt hochgeladen.

Der Workflow erzeugt das ZIP nur im temporären Runnerverzeichnis, lädt weder ZIP noch Scanprotokoll hoch und verwirft beides mit dem Runner.

## Selbsttests

`Repository_Privacy_Fixtures.json` beschreibt fünf generische Verträge:

1. generischer Repositoryinhalt wird akzeptiert;
2. der zur Laufzeit zusammengesetzte Sentinel blockiert ein Repository;
3. ein ZIP mit exakt einem zulässigen Root wird akzeptiert;
4. der Sentinel blockiert auch ein ZIP;
5. ein abweichender ZIP-Root wird blockiert.

Die Blockier-Fixtures entstehen ausschließlich in einem temporären Verzeichnis. Das Repository enthält keine realistisch nachgebildeten Personen-, Firmen-, Kunden- oder Umgebungsdaten.
