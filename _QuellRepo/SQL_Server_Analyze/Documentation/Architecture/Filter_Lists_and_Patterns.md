# Filter-, Listen- und Pattern-Konvention

Stand: 2026-07-15

## Exakte Listen

Mehrfachwerte werden mit `|` getrennt. Das Pipe-Zeichen trennt nur außerhalb von `[...]`; innerhalb bracket-quotierter Werte ist es Bestandteil des Namens. `]]` repräsentiert eine schließende Klammer.

Die folgenden Beispiele verwenden ausschließlich synthetische Bezeichner:

```sql
@SchemaNames = N'ExampleSchemaA|ExampleSchemaB'
@ColumnNames = N'[ExampleColumn]|[Example Column With Spaces]|[Example|Column]'
@ObjectNames = N'[Example|ObjectA]|[ExampleObjectB]'
@FullObjectNames = N'[ExampleDatabase].[ExampleSchema].[ExampleObjectA]|[ExampleSchema].[ExampleObjectB]'
```

Punkte trennen bei `@FullObjectNames` nur außerhalb von Brackets. Unterstützt werden ein-, zwei- und dreiteilige Namen; Linked-Server-Namen sind ausgeschlossen. Validierte Namen werden für dynamisches SQL erneut mit `QUOTENAME()` aufgebaut.

## Patterns

Patternparameter sind keine Pipe-Listen. Das Framework unterstützt folgende Modi:

- ohne Präfix oder `like:`: SQL `LIKE` unter `SQL_Latin1_General_CP1_CS_AS`
- `regex:`: case-sensitive Regex
- `regexi:`: case-insensitive Regex

Regex wird ausschließlich versionsadaptiv und dynamisch auf SQL Server 2025 mit Compatibility Level 170 ausgeführt. Auf älteren Versionen wird `UNAVAILABLE_FEATURE` geliefert; es erfolgt keine unvollständige LIKE-Übersetzung.

`REGEXP_LIKE(...)` ist dabei ein Prädikat. Positive Filter verwenden es direkt, negative Filter verwenden `NOT REGEXP_LIKE(...)`; ein Vergleich mit `= 1` oder `= 0` ist nicht zulässig. Der statische Dokumentationscheck verhindert die erneute Aufnahme dieser inkompatiblen Form.

Eine exakte Liste und ein Pattern für dieselbe Eigenschaft sind gegenseitig exklusiv.
