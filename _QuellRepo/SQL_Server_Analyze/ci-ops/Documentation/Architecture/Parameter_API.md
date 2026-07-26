# Verbindliche Parameter- und API-Konvention

Stand: 2026-07-20

## Grundsatz

Dieselbe Funktionalität verwendet in sämtlichen öffentlichen `monitor`-Objekten exakt denselben Parameternamen, Datentyp, Defaultvertrag und dieselbe Semantik. Objekt-, Parameter-, Spalten- und Aliasnamen sind wegen `SQL_Latin1_General_CP1_CS_AS` exakt case-sensitiv.

Textuelle **Steuerwerte** werden dagegen mit `UPPER(LTRIM(RTRIM(...)))` normalisiert. Daher sind beispielsweise `RAW`, `raw` und `Raw` gleichwertig. Fachliche Werte wie Datenbank-, Schema-, Objekt-, Login- oder Programmnamen werden nicht normalisiert und case-sensitiv verglichen.

## Kanonische Querschnittsparameter

- `@MaxZeilen int`: positive Werte begrenzen, `NULL`/`0` bedeutet unbegrenzt, negative Werte sind `INVALID_PARAMETER`.
- `@MaxAnalyseobjekte int`: getrenntes Budget für zu analysierende Pläne/Objekte.
- `@DatabaseNames nvarchar(max)`: bracket-aware Pipe-Liste; `NULL`/`N''` = keine Einschränkung, also alle sichtbaren Online-Benutzerdatenbanken.
- `@DatabaseNamePattern nvarchar(4000)`: ein einzelnes `like:`, `regex:` oder `regexi:` Pattern; exklusiv zu `@DatabaseNames`.
- `@SystemdatenbankenEinbeziehen bit=0`: Systemdatenbanken sind ausschließlich opt-in.
- `@HighImpactConfirmed bit=0`: bestätigt nur einen tatsächlich aktivierten ressourcenintensiven Pfad.
- `@SessionIds nvarchar(max)`: Liste numerischer Session-IDs; Pipe, Beistrich und Strichpunkt sind gleichwertige Trennzeichen und dürfen gemischt werden.
- `@ResultSetArt varchar(16)='CONSOLE'`, `@ResultTablesJson nvarchar(max)=NULL`, `@JsonErzeugen bit=0`, `@Json nvarchar(max)=NULL OUTPUT`.
- `@PrintMeldungen bit=1`, `@Hilfe bit=0`.

## Query Store

`@QueryStoreDatabaseNames` bezeichnet die Datenbanken, deren Query Store gelesen wird. `@ReferencedDatabaseNames` filtert dagegen auf Datenbanken, die in gespeicherten Plänen referenziert werden. Diese Funktionen sind bewusst getrennt.

## Extended Events

`@ExtendedEventSessionNames`/Pattern filtern Inventar- und Runtime-Listen. `@SourceExtendedEventSessionName` bezeichnet genau eine Forensikquelle für Event-, Deadlock- oder Blocked-Process-Auswertung.
