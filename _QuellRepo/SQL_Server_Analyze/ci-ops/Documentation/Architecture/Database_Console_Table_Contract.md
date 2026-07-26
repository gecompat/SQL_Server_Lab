# Frameworkvertrag für Datenbankauswahl, CONSOLE und TABLE

**Vertragsversion:** 2.0<br>
**Stand:** 21. Juli 2026<br>
**Status:** verbindlich

Dieser Vertrag definiert die gemeinsamen Auswahl-, Schutz- und Ausgabegrenzen
der öffentlichen Analyse-Procedures. Procedure-spezifische Parameter,
Resultsetnamen und Aussagegrenzen ergänzen ihn, dürfen seinen Grundregeln aber
nicht widersprechen.

## 1. Geltungsbereich

Der Vertrag umfasst:

- Datenbankauswahl und Sichtbarkeitsgrenzen;
- Zeilen- und Payloadbegrenzung;
- Trennung leichter und bestätigungspflichtiger Analysepfade;
- `CONSOLE`, `RAW`, `TABLE` und `NONE`;
- JSON-Ausgabe aus derselben Materialisierung;
- benannte Mehrfach-Resultset-Exporte;
- Status-, Leer- und Partialitätssemantik;
- Child-Aufrufe durch Orchestratoren.

Die konkrete Signatur steht in der
[Procedure-Referenz](../Reference/Procedure_Reference.md), die stabilen
Resultsetnamen und nativen Spalten in
[`Metadata/Inventory/ResultSets.csv`](../../Metadata/Inventory/ResultSets.csv).

## 2. Datenbankauswahl

### 2.1 Standardmenge

Ohne expliziten Filter werden alle für den aktuellen Login sichtbaren,
zugreifbaren und online befindlichen Benutzerdatenbanken berücksichtigt. Die
Installationsdatenbank besitzt keine Sonderstellung.

Der gemeinsame Parametervertrag lautet, soweit die jeweilige Procedure einen
Mehrdatenbankpfad besitzt:

```sql
@DatabaseNames                nvarchar(max)  = NULL,
@DatabaseNamePattern          nvarchar(4000) = NULL,
@SystemdatenbankenEinbeziehen bit            = 0
```

Für `@DatabaseNames` bedeuten `NULL`, eine leere Zeichenfolge und nur
Leerzeichen: keine explizite Einschränkung. Eine nicht leere Liste ist eine
exakte, bracket-aware Pipe-Liste. Ein Pattern ist eine alternative
Einschränkung. Exakte Liste und Pattern sind gegenseitig exklusiv.

Systemdatenbanken bleiben ohne ausdrückliches Opt-in ausgeschlossen, auch wenn
ihr Name in einer exakten Liste steht. Es gibt keinen impliziten
`CURRENT`-Scope und kein Datenbankanzahllimit, das die Kandidatenmenge vor einer
globalen Bewertung willkürlich abschneidet.

### 2.2 Sichtbarkeit und nicht verfügbare Ziele

Eine syntaktisch gültige, explizit angeforderte Datenbank, die nicht verwendet
werden kann, erzeugt einen benannten Warning-Datensatz. Typische Statuscodes
sind `DATABASE_UNAVAILABLE` und `SYSTEM_DATABASE_EXCLUDED`. Die Warnung darf
keine Information offenlegen, die dem aktuellen Login nicht bereits sichtbar
ist.

Eine leere automatische Kandidatenmenge erzeugt in `RAW` und `TABLE` keine
künstliche fachliche Zeile. `CONSOLE` darf genau eine verständliche Leerzeile
anzeigen.

### 2.3 Filtersemantik

- Exakte Mehrfachfilter verwenden bracket-aware Pipe-Listen.
- `|` trennt nur außerhalb eines geklammerten SQL-Identifiers.
- Exakte Listen und Pattern sind getrennte Parameter.
- Pattern unterstützen `like:` sowie versionsabhängig `regex:` und `regexi:`.
- Leere exakte Filter bedeuten keine Einschränkung, nicht die aktuelle
  Datenbank.
- Ein expliziter Objekt-, Query-, Session-, Zeit- oder Plangrenzwert wird vor
  einem breiten Zugriff angewandt, sofern die zugrunde liegende SQL-Server-
  Quelle dies ermöglicht.

## 3. Kosten- und High-Impact-Vertrag

Cross-Database allein ist kein High-Impact-Merkmal. Entscheidend ist der
tatsächlich aktivierte Pfad.

```sql
@HighImpactConfirmed bit = 0
```

Ein Pfad ist bestätigungspflichtig, wenn seine Analyseklasse
`RequiresGroupGate = 1` verlangt oder die Procedure einen gleichwertigen
breiten Katalog-, Plan-Cache-, Query-Store-, Showplan-, Physical-Stats-,
Extended-Events- oder Forensikpfad ausdrücklich als High Impact klassifiziert.
Gruppenfreigabe und `@HighImpactConfirmed` sind unabhängige Gates.

Vor dem ersten teuren Zugriff gilt:

1. Steuerparameter und TABLE-Zuordnung validieren;
2. tatsächlich aktivierte Analysepfade bestimmen;
3. Analyseklasse und Gruppenfreigabe prüfen;
4. bei fehlender Bestätigung kontrolliert mit
   `HIGH_IMPACT_CONFIRMATION_REQUIRED` beenden;
5. Lesen Sie erst danach die teure Systemquelle.

Leichte Pfade verlangen keine vorsorgliche Bestätigung. Die konkrete
Kostenspannweite und ein sicherer Einstieg stehen im
[Analysis-Navigator-Katalog](../Reference/Analysis_Navigator.md) und auf der
jeweiligen tiefen Procedure-Seite.

## 4. Zeilenbegrenzung

Für `@MaxZeilen` gilt frameworkweit:

- ein positiver Wert begrenzt die Ergebnismenge;
- `0` oder `NULL` bedeutet keine Ergebnisbegrenzung;
- ein negativer Wert ist `INVALID_PARAMETER`;
- eine Procedure darf für positive Werte eine dokumentierte Obergrenze setzen;
- ein Zeilenlimit ist nur dann ein Quellbudget, wenn die Procedure es vor oder
  innerhalb der teuren Quelloperation anwenden kann.

Bei mehreren Datenbanken oder benannten Resultsets kann ein Limit je Datenbank
oder je Resultset gelten. Die tiefe Procedure-Seite muss ausweisen, ob das
Limit Kandidaten, materialisierte Daten oder nur die Ausgabe begrenzt.

## 5. Gemeinsame Ausgabemodi

### 5.1 Steuerparameter

```sql
@ResultSetArt      varchar(16)   = 'CONSOLE',
@ResultTablesJson  nvarchar(max) = NULL,
@JsonErzeugen      bit           = 0,
@Json              nvarchar(max) = NULL OUTPUT
```

`@ResultSetArt` akzeptiert getrimmt und case-insensitiv `CONSOLE`, `RAW`,
`TABLE` und `NONE`. `@ResultTablesJson` ist nur mit `TABLE` zulässig. JSON wird
optional und unabhängig vom gewählten Resultsetmodus aus derselben
Materialisierung erzeugt.

### 5.2 CONSOLE

`CONSOLE` ist menschenorientiert und kein Importvertrag.

- Im Normalfall erscheint genau ein fachliches, verständlich beschriftetes
  Resultset.
- Technische Meta-Resultsets erscheinen nicht als separate Grids.
- Leere Warning- und Detailmengen werden unterdrückt.
- Bei leerem fachlichem Ergebnis erscheint genau eine verständliche
  Console-Zeile.
- Hinweise dürfen per `RAISERROR` mit Severity 10 und `WITH NOWAIT` erscheinen.

Spaltenauswahl, Formatierung und Leerzeilen dürfen sich für die Lesbarkeit
weiterentwickeln. Automatisierte Verbraucher verwenden `RAW`, `TABLE` oder
JSON.

### 5.3 RAW

`RAW` liefert nativ typisierte fachliche Resultsets in der dokumentierten
Reihenfolge. Technischer Modulstatus erscheint dort, wo er Bestandteil des
Procedurevertrags ist. Eine leere fachliche Menge bleibt leer; es werden keine
Darstellungszeilen eingeschoben.

Die Kombination aus Resultsetname, Reihenfolge und nativem Schema ist im
Resultsetinventar dokumentiert. Zusätzliche Spalten oder Ergebnisse erfordern
eine entsprechende Vertragsänderung.

### 5.4 NONE

`NONE` unterdrückt alle Resultsets. Der Modus wird für JSON-only-Aufrufe und
Orchestrierung verwendet. Er verhindert nicht automatisch die fachliche
Erhebung; die Procedure führt die aktivierten Pfade aus, sofern kein separater
Schalter sie deaktiviert.

## 6. TABLE mit benannter Mehrfachzuordnung

`TABLE` exportiert benannte Resultsets in lokale Temp-Tabellen des Aufrufers.
Das JSON-Objekt verwendet den stabilen Resultsetnamen als Property und den
lokalen Tabellennamen als Wert.

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

### 6.1 Preflight

Vor dem ersten fachlichen Systemzugriff werden atomar abgelehnt:

- ungültiges JSON oder ein anderer Top-Level-Typ als Objekt;
- unbekannte oder nicht exportierbare Resultsetnamen;
- doppelte JSON-Properties;
- dasselbe Ziel für mehrere Resultsetnamen;
- permanente Tabellen, globale Temp-Tabellen oder reservierte interne Namen;
- nicht vorhandene Zieltabellen;
- gefüllte oder nicht sicher adaptierbare Seed-Tabellen;
- eine bereits strukturierte Zieltabelle mit abweichendem nativen Schema.

### 6.2 Strukturadaption und Anhängen

Ein neues Ziel ist eine vorhandene, leere lokale `#Temp`-Tabelle mit genau
einer beliebigen Seed-Spalte. Der gemeinsame Writer ersetzt diese Struktur
durch das native Quellschema. Eine bereits exakt passende Zielstruktur darf
zum Anhängen verwendet werden.

Verglichen werden Spaltenreihenfolge, Name, Systemtyp, Länge, Precision, Scale,
Collation und Nullable-Eigenschaft. Identity-, berechnete, benutzerdefinierte,
Assembly-, typisierte XML- und `rowversion`-Strukturen sind für automatische
Adaption ausgeschlossen.

Alle angeforderten Ziele werden aus bereits im selben Aufruf materialisierten
Quellen geschrieben. Ein TABLE-Export darf keinen erneuten DMV-, Plan-Cache-,
Query-Store-, Extended-Events- oder Katalogzugriff auslösen.

## 7. JSON-Vertrag

Wenn `@JsonErzeugen = 1` ist, setzt die Procedure `@Json` auf ein gültiges
JSON-Objekt. Es enthält mindestens technische Metadaten und die benannten
fachlichen Arrays der Procedure. Leere Resultsets erscheinen als `[]`, nicht
als fehlende oder `null`-Arrays, sofern die Procedure-Seite nichts
Spezifischeres dokumentiert.

JSON wird aus derselben Materialisierung wie RAW und TABLE erzeugt. Der
JSON-Pfad darf keine zweite fachliche Erhebung starten. Native Zahlen und Bits
bleiben JSON-Zahlen beziehungsweise Booleans; Zeit-, Binär-, XML- und
Spezialtypen folgen der procedure-spezifisch dokumentierten Serialisierung.

## 8. Begrenzung großer Text- und XML-Payloads

Eine ausdrücklich angeforderte Begrenzung kürzt nur die Ausgabeprojektion und
darf Vollständigkeit niemals vortäuschen. Native Quell- und
Materialisierungstypen bleiben `nvarchar(max)` beziehungsweise `xml`.

Für zeichenbasierte Grenzen wie `@MaxTargetDataZeichen` gilt:

- ein eigener `@Mit...`-Schalter entscheidet, ob Inhalt erhoben oder ausgegeben
  wird;
- ein positiver Wert begrenzt die Projektion;
- `0` bedeutet vollständige, nicht durch das Framework gekürzte Ausgabe;
- negative Werte sind ungültig;
- kein gültiges Unicode-Zeichen und kein UTF-16-Surrogate-Paar darf geteilt
  werden;
- Zeichen-, Byte- und Kürzungsmetriken bleiben maschinenlesbar.

Ein kürzbares Ergebnis weist mindestens ursprüngliche Zeichenlänge,
Bytegröße und ein `IsTruncated`-Kennzeichen aus. Sobald Werte gekürzt wurden,
erscheint höchstens eine technische Warning pro Procedure-Aufruf mit dem Code
`OUTPUT_VALUE_TRUNCATED`, der Anzahl betroffener Werte, dem aktiven Grenzwert
und dem für diesen Aufruf ausreichenden Wert. `@PrintMeldungen` darf die
menschliche Meldung unterdrücken, nicht die maschinenlesbare Kennzeichnung.

Eine bewusst konfigurierte Ausgabekürzung macht die fachliche Erhebung nicht
automatisch partiell. Unabhängig davon bleibt sichtbar, dass die gelieferte
Projektion gekürzt wurde.

## 9. Status, Partialität und leere Ergebnisse

Statuscodes benennen den Zustand einer Quelle oder eines Moduls, nicht bloß
den SQL-Ausführungserfolg. Typische Gruppen sind:

| Gruppe | Bedeutung |
|---|---|
| `AVAILABLE` | Quelle wurde innerhalb des dokumentierten Scopes ausgewertet |
| `NO_DATA` / `NO_MATCH` | gültiger Aufruf, aber keine passende fachliche Zeile |
| `NOT_SUPPORTED` / `FEATURE_DISABLED` | Plattform oder Feature stellt die Quelle nicht bereit |
| `PERMISSION_DENIED` / `NOT_AUTHORIZED` | Sichtbarkeit, SQL-Recht oder Frameworkpolicy fehlt |
| `INVALID_PARAMETER` | Steuer- oder Scopeparameter verletzt den Vertrag |
| `HIGH_IMPACT_CONFIRMATION_REQUIRED` | aktivierter Pfad benötigt ausdrückliche Bestätigung |
| `LOCK_TIMEOUT` / `ERROR_HANDLED` | Quelle konnte kontrolliert nicht vollständig ausgewertet werden |

`IsPartial = 1` bedeutet, dass die fachliche Gesamtaussage unvollständig ist.
Eine leere Ergebnismenge allein ist nicht automatisch partiell. Umgekehrt darf
das Ausbleiben eines SQL-Fehlers nie als `AVAILABLE` interpretiert werden, wenn
der explizite Child- oder Quellenstatus fehlt.

## 10. Orchestratoren

Ein Orchestrator ruft jedes aktivierte Child höchstens einmal je eigener
Ausführung auf. Children laufen nicht im Modus `CONSOLE`. Je nach
Übergabevertrag verwenden sie `NONE` oder benannte interne TABLE-Ziele.

Childstatus, Partialität und Zeilenanzahl stammen aus dem expliziten Status-
oder JSON-Vertrag desselben Childaufrufs. Ein fehlender valider Status wird als
`STATUS_UNAVAILABLE` oder gleichwertig partiell behandelt, niemals automatisch
als verfügbar.

`USP_CurrentOverview` verwendet den zusätzlichen Console-Vertrag:

```sql
@Detailgrad varchar(16) = 'SUMMARY'
```

- `SUMMARY`: genau ein konsolidiertes Modul-Summary;
- `RELEVANT`: Summary plus nicht leere relevante Childdetails;
- `ALL`: Summary plus alle nicht leeren aktivierten Childdetails.

Leere Children bleiben mit Status und Zeilenanzahl im Summary sichtbar, ohne
ein leeres Grid zu erzeugen. TABLE und JSON bleiben unabhängig vom
Console-Detailgrad über ihre benannten Resultsetnamen steuerbar.

## 11. Leserichtung für Verbraucher

1. Wählen Sie Procedure und Scope im [Analysis Navigator](../Reference/Analysis_Navigator.md)
   aus.
2. Verwenden Sie `@Hilfe = 1` und lesen Sie die ausführliche Procedure-Seite.
3. Prüfen Sie zuerst Status, Partialität, Zeitbezug und Scope.
4. Interpretieren Sie danach fachliche Zeilen und Einheiten.
5. Unterscheiden Sie leere, gekürzte, optionale und nicht verfügbare Quellen.
6. Verwenden Sie für die Automatisierung benannte RAW-, TABLE- oder JSON-Verträge.
7. Bestätigen Sie einen Befund durch den dokumentierten Folge- oder Gegenpfad.

Die allgemeinen Aufruf- und Ausgabegrundlagen stehen zusätzlich in den
[gemeinsamen Verträgen](../Analysis_Guides/Common_Contracts.md) und den
[Resultset-Konventionen](../Reference/Resultset_Conventions.md).
