# Historie des Frameworkvertrags für Datenbankauswahl, CONSOLE und TABLE

**Vertragsversion:** 2.0<br>
**Stand:** 21. Juli 2026
**Status:** VERBINDLICH

## 1. Ausgangslage und Migrationsumfang

Die Bestandsaufnahme des `main`-Stands `973d5cab5eab7ebad067376e9b6751068638232b`
ergab vor Beginn der Migration:

- 66 SQL-Dateien mit `@MaxDatenbanken`;
- 86 SQL-Dateien mit `@ResultTable`;
- keine öffentliche Procedure mit `@HighImpactConfirmed`;
- eine Datenbankauswahl, die `N''` als aktuelle Datenbank interpretiert;
- eine TABLE-Inventur, die nur ein Primärergebnis je Procedure beschreibt;
- Orchestratoren, die Child-Status teilweise aus dem Ausbleiben eines Fehlers
  ableiten und CONSOLE an Children weiterreichen.

Diese Zählwerte dokumentieren den Ausgangspunkt. Die Abschlussgates müssen für
`@MaxDatenbanken` und `@ResultTable` jeweils null produktive Treffer ergeben.

## 2. Datenbankauswahl

### 2.1 Standard

Ohne expliziten Filter werden alle für den aktuellen Login sichtbaren,
zugreifbaren und online befindlichen Benutzerdatenbanken berücksichtigt.
Die Installationsdatenbank erhält keine Sonderstellung.

```sql
@DatabaseNames                nvarchar(max)  = NULL,
@DatabaseNamePattern          nvarchar(4000) = NULL,
@SystemdatenbankenEinbeziehen bit            = 0
```

`NULL`, eine leere Zeichenfolge oder nur Leerzeichen bedeuten bei
`@DatabaseNames` **keine Einschränkung**. Eine nicht leere Liste ist eine
explizite exakte Einschränkung. `@DatabaseNamePattern` ist eine alternative
explizite Einschränkung. Liste und Pattern sind gegenseitig exklusiv.

Es gibt weder `CURRENT`-Scope noch `@DatabaseScope`. `@MaxDatenbanken` ist kein
Bestandteil der öffentlichen oder internen API. Die Kandidatenmenge darf vor
einer globalen Bewertung, Sortierung oder Ergebnisbegrenzung nicht willkürlich
gekürzt werden.

Systemdatenbanken bleiben auch bei expliziter Namensnennung ausgeschlossen,
solange `@SystemdatenbankenEinbeziehen <> 1` ist.

### 2.2 Explizit nicht verfügbare Datenbanken

Eine syntaktisch gültige, explizit angeforderte Datenbank, die nicht in die
Kandidatenmenge aufgenommen werden kann, erzeugt einen benannten Warning-Datensatz.
Der Status lautet `DATABASE_UNAVAILABLE`; für eine ohne Opt-in angeforderte
Systemdatenbank ist `SYSTEM_DATABASE_EXCLUDED` zulässig. Die Warnung darf keine
Information offenlegen, die der aktuelle Login nicht bereits sehen darf.

Eine leere automatische Kandidatenmenge ist kein künstlicher fachlicher Datensatz.
RAW und TABLE bleiben leer; CONSOLE darf eine verständliche Leerzeile ausgeben.

### 2.3 High-Impact-Gate

Cross-Database allein ist kein High-Impact-Merkmal. Die Bestätigung hängt vom
tatsächlich aktivierten Analysepfad ab.

```sql
@HighImpactConfirmed bit = 0
```

Ein Pfad ist bestätigungspflichtig, wenn er eine Analyseklasse mit
`RequiresGroupGate = 1` aktiviert oder ein Modul einen gleichwertigen breiten
Katalog-, Plan-Cache-, Query-Store-, Showplan-, Physical-Stats-, Extended-Events-
oder Forensikpfad ausdrücklich als High Impact einstuft. Gruppenfreigabe und
High-Impact-Bestätigung sind unabhängige Gates; beide müssen erfüllt sein.

Vor dem ersten teuren Systemzugriff gilt:

1. Das Verfahren validiert Steuerparameter und TABLE-Zuordnung.
2. Es bestimmt die tatsächlich aktivierten Analysepfade.
3. Bei erforderlicher und fehlender Bestätigung beendet es den Aufruf kontrolliert mit
   `HIGH_IMPACT_CONFIRMATION_REQUIRED`.
4. Erst danach liest es teure DMVs, Kataloge, Plan Cache, Query Store oder Eventdaten.

Leichte Pfade verwenden keine Bestätigung. `USP_CurrentIO` gehört zur Klasse
`STANDARD_CURRENT` und liest `sys.dm_io_virtual_file_stats(NULL, NULL)` je
Messzeitpunkt genau einmal serverweit. Die Kandidatenmenge wird anschließend
relational angewendet.

## 3. Ausgabemodi

### 3.1 Gemeinsame Parameter

```sql
@ResultSetArt      varchar(16)   = 'CONSOLE',
@ResultTablesJson nvarchar(max) = NULL,
@JsonErzeugen      bit           = 0,
@Json              nvarchar(max) = NULL OUTPUT
```

`@ResultSetArt` akzeptiert getrimmt und case-insensitiv `CONSOLE`, `RAW`,
`TABLE` und `NONE`. `@ResultTable` ist entfernt.

### 3.2 CONSOLE

CONSOLE ist menschenorientiert und kein Importvertrag.

- Im Normalfall liefert eine öffentliche Procedure genau ein fachliches
  Resultset.
- Technische Meta-Resultsets werden nicht separat ausgegeben.
- Leere Warning- und Detail-Resultsets werden unterdrückt.
- Bei leerem fachlichem Ergebnis wird genau eine verständliche Console-Zeile
  ausgegeben; RAW und TABLE erhalten keine künstliche Datenzeile.
- Technische Hinweise und Warnungen dürfen mit `RAISERROR` Severity 10 und
  `WITH NOWAIT` ausgegeben werden.

### 3.3 RAW und NONE

RAW liefert die dokumentierten, nativ typisierten fachlichen Resultsets ohne
Darstellungszeilen. Technischer Status wird nur ausgegeben, wenn er im
Resultsetinventar als fachlich nutzbarer benannter Vertrag definiert ist.
NONE unterdrückt Resultsets und wird insbesondere für Orchestrierung und
JSON-only-Aufrufe verwendet.

### 3.4 TABLE mit benannter Mehrfachzuordnung

TABLE verwendet ausschließlich ein JSON-Objekt, dessen Property-Namen stabile
semantische Resultsetnamen und dessen Werte lokale Ziel-Temp-Tabellen sind.

```sql
CREATE TABLE #OverviewStatus   ([Seed] bit NULL);
CREATE TABLE #OverviewSessions ([Seed] bit NULL);
CREATE TABLE #OverviewRequests ([Seed] bit NULL);
CREATE TABLE #OverviewIO       ([Seed] bit NULL);

EXEC [monitor].[USP_CurrentOverview]
      @ResultSetArt = 'TABLE'
    , @ResultTablesJson = N'{
        "moduleStatus":"#OverviewStatus",
        "sessions":"#OverviewSessions",
        "requests":"#OverviewRequests",
        "io":"#OverviewIO"
      }';
```

Vor dem ersten fachlichen Systemzugriff werden atomar abgelehnt:

- ungültiges JSON oder ein anderer JSON-Top-Level-Typ als Objekt;
- unbekannte oder für die Procedure nicht exportierbare Resultsetnamen;
- doppelte JSON-Properties;
- dasselbe Ziel für mehrere Resultsetnamen;
- permanente Tabellen, globale Temp-Tabellen oder reservierte interne Namen;
- nicht vorhandene Zieltabellen;
- gefüllte oder für die sichere Strukturadaption ungeeignete Seed-Tabellen.

Der Preflight akzeptiert als neu zu adaptierendes Ziel eine vorhandene, leere
lokale `#Temp`-Tabelle mit genau einer Seed-Spalte. Eine bereits exakt passende
Zielstruktur darf nur verwendet werden, wenn sie vor dem Systemzugriff anhand
des inventarisierten Schemas vollständig validiert werden kann.

Alle angeforderten Ziele werden aus bereits im selben Procedure-Aufruf
materialisierten Quellen geschrieben. Ein TABLE-Export darf keinen erneuten
DMV-, Plan-Cache-, Query-Store-, Extended-Events- oder Katalogzugriff auslösen.

### 3.5 Begrenzung großer Text- und XML-Payloads

Eine explizit angeforderte Begrenzung darf große Inhalte für die Ausgabe
kürzen, niemals jedoch stillschweigend Vollständigkeit vortäuschen. Native
Quell- und Materialisierungstypen bleiben `nvarchar(max)` beziehungsweise
`xml`; `nvarchar(4000)` ist keine allgemeine XML- oder Payloadgrenze.

`OUT-001` ist frameworkweit umgesetzt. Für zeichenbasierte Ausgabeparameter
wie `@MaxTargetDataZeichen` gilt:

- ein eigener `@Mit...`-Schalter entscheidet, ob der Inhalt überhaupt
  ausgegeben wird;
- ein positiver Grenzwert kürzt ausschließlich die Ausgabeprojektion;
- `0` bedeutet vollständige, nicht durch das Framework gekürzte Ausgabe;
- negative Werte sind `INVALID_PARAMETER`;
- eine zusätzliche künstliche Obergrenze wie `1000000` ist unzulässig; die
  technischen Grenzen des nativen MAX-/XML-Datentyps bleiben maßgeblich;
- die Implementierung darf beim Kürzen kein gültiges Unicode-Zeichen und
  insbesondere kein UTF-16-Surrogate-Paar teilen.

Jedes kürzbare benannte Ergebnis stellt die Vollständigkeit maschinenlesbar
bereit. Für `USP_ExtendedEventsTargetRuntime` und entsprechend benannte
Textfelder sind folgende Metriken implementiert:

```text
TargetDataCharacters   bigint
TargetDataBytes        bigint
TargetDataIsTruncated  bit
TargetData             nvarchar(max)
```

Die Zeichenmetrik muss eindeutig und Unicode-sicher definiert sein; die
Bytegröße wird unabhängig davon mit `DATALENGTH` ermittelt. Der für eine
ungekürzte Ausgabe benötigte Grenzwert wird aus der ursprünglichen, bereits im
selben Aufruf materialisierten Länge bestimmt. Seine Ermittlung darf keinen
erneuten Systemzugriff auslösen.

Sobald mindestens ein Wert gekürzt wurde, wird genau eine technische Warning
pro Procedure-Aufruf ausgegeben, nicht eine Warning je Zeile. Sie verwendet
`RAISERROR` Severity 10 mit `WITH NOWAIT` und nennt mindestens:

- den stabilen Code `OUTPUT_VALUE_TRUNCATED`;
- Anzahl der gekürzten Werte;
- Namen und aktuellen Wert des begrenzenden Parameters;
- die größte für diesen Aufruf benötigte ungekürzte Länge;
- den konkreten ausreichenden Parameterwert sowie `0` als unbegrenzte Option.

Beispiel:

```text
OUTPUT_VALUE_TRUNCATED: 3 Targetwerte wurden durch
@MaxTargetDataZeichen=4000 gekürzt. Der größte Wert benötigt 28734 Zeichen.
Verwenden Sie @MaxTargetDataZeichen=28734 oder 0 für eine vollständige Ausgabe.
```

RAW und TABLE erhalten keine künstliche Warning-Datenzeile. Die
zeilenbezogenen Längen- und Kürzungsfelder bleiben dort sowie in JSON erhalten;
CONSOLE darf sie menschenlesbar projizieren. Eine bewusst konfigurierte
Ausgabekürzung macht die fachliche Quellenerhebung nicht automatisch
`PARTIAL`, muss aber immer über `TargetDataIsTruncated` und die einmalige
Warning sichtbar bleiben. `@PrintMeldungen` darf die menschliche Meldung
unterdrücken, nicht jedoch die maschinenlesbare Kennzeichnung.

## 4. Resultsetinventar

`Metadata/Inventory/ResultSets.csv` ist die kanonische maschinenlesbare
Zuordnung. Mindestens folgende Felder sind verbindlich:

| Feld | Bedeutung |
|---|---|
| `ProcedureName` | öffentlicher Prozedurname ohne Schema |
| `ResultName` | stabiler semantischer Name |
| `IsConsoleDefault` | Bestandteil des normalen Console-Resultsets |
| `IsRawExportable` | als RAW-Resultset dokumentiert |
| `IsTableExportable` | in `@ResultTablesJson` zulässig |
| `SourceSchema` | geordnete native Spaltendefinition |
| `EmptyConsoleMessage` | optionale menschenlesbare Leeranzeige |

`Metadata/Inventory/TableOutput.csv` wird durch dieses Inventar ersetzt. Eine
positionsabhängige Zuordnung über Pipe-, Komma- oder Semikolonlisten ist verboten.

## 5. Orchestratoren und `USP_CurrentOverview`

Orchestratoren rufen jedes Child höchstens einmal pro eigener Ausführung auf.
Children laufen niemals mit CONSOLE. Je nach benötigter Übergabe verwenden sie
`NONE` oder einen benannten internen TABLE-Export; Status, Partialität und
Zeilenanzahl werden aus dem im selben Childaufruf erzeugten JSON-Envelope
übernommen.

Das Ausbleiben eines SQL-Fehlers ist kein Verfügbarkeitsnachweis. Der Childstatus
wird aus dessen explizitem Statusvertrag gelesen. Fehlt ein valider Status, ist
`STATUS_UNAVAILABLE` beziehungsweise ein gleichwertiger partieller Status zu
verwenden, niemals automatisch `AVAILABLE`.

`USP_CurrentOverview` verwendet:

```sql
@Detailgrad varchar(16) = 'SUMMARY'
```

- `SUMMARY`: genau ein konsolidiertes Modul-Summary;
- `RELEVANT`: Summary plus nicht leere relevante Childdetails;
- `ALL`: Summary plus alle nicht leeren aktivierten Childdetails.

Leere Children erscheinen mit Status und Zeilenanzahl im Summary, erzeugen aber
kein leeres Grid. TABLE und JSON bleiben unabhängig vom Console-Detailgrad über
benannte Resultsetnamen steuerbar.

## 6. Reihenfolge der Einführung

1. gemeinsame Auswahl- und TABLE-Preflight-Helper;
2. Pilot `USP_CurrentIO`;
3. Pilot `USP_CurrentOverview` einschließlich Childstatus-Vertrag;
4. Pilotgates auf SQL Server 2019, 2022 und 2025;
5. frameworkweite API-Migration;
6. Installer, Beispiele, Dokumentation und Metadaten;
7. vollständige Release-, Dokumentations-, Datenschutz-, Nonblocking- und
   Vertragsprüfungen.

Ein Framework-Rollout vor grüner Pilotvalidierung ist nicht zulässig.
