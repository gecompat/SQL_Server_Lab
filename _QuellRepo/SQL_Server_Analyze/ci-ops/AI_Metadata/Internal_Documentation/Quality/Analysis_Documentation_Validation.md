# Analyse-Dokumentation validieren

## Ausführung

```powershell
pwsh ./Code/Tests/Static/900_Validate_Analysis_Documentation.ps1
```

Externe Links werden separat geprüft:

```bash
python3 ./Code/Tests/Static/980_Validate_External_Documentation_Links.py --repository-root . --self-test --check-network
```

Optional kann der Repositoryroot übergeben werden:

```powershell
pwsh ./Code/Tests/Static/900_Validate_Analysis_Documentation.ps1 -RepositoryRoot 'C:\Example\SQL_Server_Analyze'
```

Der Beispielpfad ist synthetisch.

## Automatische Ausführung

Der Workflow `.github/workflows/documentation-validation.yml` führt dieselbe Prüfung aus bei:

- relevanten Pull Requests,
- relevanten Änderungen an `main`,
- manueller Auslösung über `workflow_dispatch`.

Der Workflow benötigt nur lesenden Zugriff auf Repositoryinhalte.

## Geprüft wird

- Referenzmenge gegen Procedure-Seiten,
- die aus `Metadata/Inventory/Objects.csv` abgeleitete öffentliche Proceduremenge in Referenz, kanonischen SQL-Quellen, Einzelseiten und Aufrufkatalog,
- jede inventarisierte View, TVF, interne Procedure und Tabelle mit Abschnitt und kanonischem Quellpfad in `Reference/Object_Reference.md`,
- Existenz der in der Referenz genannten SQL-Quelldateien,
- Procedure-Name der Quelldatei,
- Parameterreihenfolge, Parameternamen, Datentypen, Defaults und `OUTPUT`-Kennzeichnung gegen die kanonische SQL-Signatur,
- Parameternamen in dokumentierten `EXEC`-Beispielen,
- Seitentitel,
- Pflichtüberschriften einschließlich der sieben technischen Vertiefungsfelder,
- Links auf das gemeinsame Zeit-/Evidenzmodell und die technischen Familienbeschreibungen,
- interne relative Markdownziele,
- interne Markdown-Anker,
- mindestens einen eingehenden Link für jede Markdown-Seite unter `Documentation/` aus einer anderen Dokumentationsseite oder dem Root-README,
- anklickbare Datei-Einstiege in `Documentation/README.md` anstelle nicht verlinkter Markdown-, CSV- oder JSON-Pfade,
- exakte Übereinstimmung des Review-Manifests mit den inventarisierten Referenz-Procedures,
- zulässige Status-/Versionskombinationen für `BASELINE` und `DEEP_REVIEWED`,
- für tief geprüfte Seiten die erweiterten Pflichtabschnitte, vollständigen Kostendimensionen, Primärquellen, synthetische Beispiele und substanzielle Mindesttiefe,
- syntaktisch gültige externe HTTP-/HTTPS-Links in der gesamten Dokumentation,
- dauerhaft nicht vorhandene externe Ziele mit HTTP `404` oder `410` in den Analysis Guides und der zentralen Quellenliste.

## Aussagegrenzen

Nicht automatisiert bewiesen werden:

- fachliche Richtigkeit jeder Aussage,
- fachliche Aktualität des Inhalts hinter einem erreichbaren externen Link,
- tatsächliche Runtime-Resultsets,
- korrekte Kostenklassifizierung im konkreten Produktionssystem,
- Datenschutz als beweisbarer Automatismus.

Vor Merge bleibt eine manuelle fachliche und datenschutzbezogene Diffprüfung erforderlich. Der statische Test ergänzt das SQL-Release-Gate, ersetzt es aber nicht.

Transiente DNS-, Timeout-, Rate-Limit- und HTTP-5xx-Zustände externer Anbieter werden gezählt, blockieren das Gate aber nicht. Damit bleibt ein dauerhafter Linkverlust sichtbar, ohne die Repositorylieferung an einen kurzfristigen Fremdsystemausfall zu koppeln.
