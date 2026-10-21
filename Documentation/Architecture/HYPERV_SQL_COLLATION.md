# Collation im Windows-Prepared-Pfad

## Auswahl und Defaults

`instance.collation` im Manifest und ein ausdrueckliches `New-SqlServerLab
-Collation` waehlen eine kataloggebundene Instanzcollation. SQL 2019/2022/2025
werden nach Major-Version gebunden, einschliesslich CU-Versionen. Der Katalog
enthaelt auch `SQL_Latin1_General_CP1_CS_AS`. Andere vorhandene Katalogwerte
verwenden dieselbe Kette; freie Advanced-Namen bleiben ausgeschlossen.

Der editierbare Frameworkstandard fuer neue interaktive SQL-Zielintents steht
in `Catalogs/sql-intent-defaults.json`, Feld `collation`, initial
`SQL_Latin1_General_CP1_CS_AS`. Schnellkonfiguration zeigt ihn an;
benutzerdefinierte Konfiguration erlaubt eine andere Katalogauswahl. Schema,
Katalog und ausgewaehlte SQL-Version werden vor Erstellung geprueft. Eine
unbekannte Vorgabe bricht ab und faellt nicht auf einen anderen Namen zurueck.
Diese Datei ist Frameworkkonfiguration, keine automatisch geschriebene lokale
Preference. Aenderungen betreffen zukuenftige Zielintents, keine gespeicherten
Runs oder bereits ausgewaehlten Werte. Legacy-Testumgebungsauftraege behalten
ihre eigenen ausdruecklichen Vorgaben.

Windows ohne ausgewaehlten SQL-Intent beziehungsweise ohne ausdrueckliches
Manifestfeld/Ad-hoc-Argument behaelt das bisherige CompleteImage-Verhalten:
kein `/SQLCOLLATION`, keine Collationabfrage und kein erzeugter Sollwertnachweis.
`collationExplicit` bewahrt intern die Auswahl vor der Defaultnormalisierung;
es ist kein neues Manifestfeld. Der bisherige normalisierte CI-Wert bleibt
Datenbankdefault und Containerdefault. Ein ausdruecklich gewaehlter CI-Wert
wird dagegen genauso ausgefuehrt und geprueft wie ein CS-Wert. Datenbank-
Overrides bleiben erhalten. Es gibt keinen Umbau bestehender Systemdatenbanken.

## Weitergabe und Postcondition

Vor dem ersten Provisionierungseffekt wird die Auswahl gegen Version und
`SQL_PREPARED_SEALED`-Zustand des ausgewaehlten Artifacts geprueft. Ein OS-only-
Artifact lehnt einen SQL-Collationauftrag ab. Die Unattended-Provisionierung
speichert den kanonischen Namen als `sqlCollationIntent` in der run-eigenen
Connectiondatei vor der OOBE-Injektion und reicht ihn an CompleteImage weiter.
Auch die oeffentliche Aktion `CompleteHyperVLabSql` verwendet den gespeicherten
Intent. Ein abweichender Folgeparameter wird abgewiesen; ein fehlender Parameter
loescht keinen gespeicherten Auftrag. Alte Runs ohne Feld erhalten keinen
nachtraeglichen Intent.

CompleteImage bindet erneut gegen die Artifactversion und uebergibt genau ein
`/SQLCOLLATION=<kanonischer Name>` an Setup. Ohne Auswahl entfällt das Argument.
Die bestehenden Run-/Scope-/Root-/VM-Bindungen und der einmalige mutierende
Gastaufruf mit `NoRetry` bleiben erhalten.

Bei ausgewaehlter Collation ist der Zwischenzustand nach Setup
`COLLATION_PENDING`. Nach dem Setupneustart, statischer Portkonfiguration und
SQL-Readiness liest eine parametrisierte, rein lesende SqlClient-Abfrage im
gebundenen Gast ueber `localhost,<Port>` mit Windows-Authentifizierung:

- Verfuegbarkeit des Namens in `sys.fn_helpcollations()`;
- `SERVERPROPERTY('Collation')`;
- `DATABASEPROPERTYEX('master','Collation')` und denselben Wert fuer `tempdb`;
- SQL-Major-Version und Defaultinstanzidentitaet.

Leere/mehrfache Receipts, fremde Run-/Scopebindung, falsche SQL-Identitaet,
fehlende Katalogverfuegbarkeit, NULL, Abfragefehler und abweichende Collations
brechen geschlossen ab. Es gibt weder automatische Reparatur noch erneutes
Setup. Der persistierte Zwischenzustand blockiert einen Setup-Replay. Recovery
und Cleanup bleiben gesonderte, scopegebundene Operationen.

Der Caller verwendet die vorhandene Transportsignatur ohne `StateRoot`.
Der ausgewählte Root bleibt an den Run-Readern gebunden; Run, Scope,
Credential, optionaler VM-ID-Direct-Selector und `NoRetry` werden erhalten.
Fehlende, NULL-, leere oder ungültig typisierte Collationwerte ergeben
`HYPERV_SQL_COLLATION_RECEIPT_INVALID`. Erst drei gültige Istwerte erlauben
den Vergleich; eine tatsächliche Abweichung ergibt
`HYPERV_SQL_COLLATION_POSTCONDITION_FAILED`. Ein Transportfehler bleibt
`HYPERV_SQL_COLLATION_QUERY_FAILED` und erzeugt keinen Collationnachweis.

Erst nach Erfolg speichert `sqlCompletion.collation` den Status `VERIFIED`,
Sollwert, drei Istwerte, Katalogverfuegbarkeit, SQL-Version, Beobachtungszeit
und Run-/Scope-/Instanzbindung. Es werden keine Gastnamen, Connection Strings
oder Credentials in diese Evidence uebernommen. Dann werden `COMPLETE` und die
bestehende SQL-Readiness persistiert. Nachgelagerte Konfiguration, Datenbanken,
Samples und optionale SQL-Funktionen laufen erst nach Rueckkehr weiter.

Eine eigene Consumerdatenbank und CL170 bleiben eigenstaendige Postconditions.
Eine leere Providerliste beweist keinen synthetischen OLE-DB-Providerfall.

## Beispiel und Nachweisgrenze

Der folgende Entwurf ist ohne Provisionierung pruefbar:

```powershell
Test-SqlServerLabManifest -InputObject @{
    name = 'windows-collation-demo'
    instances = @(@{
        id = 'primary'; version = '2025'; provider = 'hyperv'; os = 'windows'
        collation = 'SQL_Latin1_General_CP1_CS_AS'
    })
}
```

Die Offline-Suites fuehren Auswahl, Weitergabe, CompleteImage-Gastskript und
SQL-Gastskript mit synthetischen nativen Blaettern aus. Das ist kein nativer
Windows-/SQL-Collationnachweis. Eine spaetere isolierte Abnahme muss einen
eigenen Child aus einem vorhandenen Prepared-Artifact mit expliziter Collation
und einen Kontrollfall ohne Intent, drei echte Istwerte, Parentintegritaet und
vollstaendigen eigenen Cleanup pruefen. Ein neuer Imagebau ist dafuer nicht
erforderlich. Bestehende Docker-/Podman-Nachweise qualifizieren weder Windows
noch automatisch den neu katalogisierten SQL-CS-Wert.

Die ausgefuehrten Offlinechecks und offenen nativen Abnahmen stehen in der
[Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md).

Microsoft dokumentiert `/SQLCOLLATION` unter
[Complete image parameters](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt?view=sql-server-ver17#complete-image-parameters),
die Collationauswahl bei der
[SysPrep-Fertigstellung](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-using-sysprep?view=sql-server-ver17#complete-a-prepared-instance-of-sql-server)
und die [Abfrage der Istwerte](https://learn.microsoft.com/en-us/sql/relational-databases/collations/view-collation-information?view=sql-server-ver17).
