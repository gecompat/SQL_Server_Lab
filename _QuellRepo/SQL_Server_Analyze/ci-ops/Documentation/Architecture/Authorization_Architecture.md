# Architektur der internen Ressourcenschutz- und Berechtigungsschiene

**Stand:** 18. Juli 2026  
**Geltungsbereich:** SQL Server Analyze ab SQL Server 2019  
**Kanonische Objekte:** `[monitor].[VW_AnalyseClassCatalog]`, `[monitor].[VW_AnalyseAccessPolicy]`, `[monitor].[VW_AnalyseAccessCurrent]`, `[monitor].[VW_FrameworkFeatureCatalog]`, `[monitor].[USP_CheckAnalyseAccess]`, `[monitor].[USP_CheckFrameworkCapabilities]`

## 1. Primärer Zweck

Die interne Berechtigungsschiene ist in erster Linie ein **Ressourcenschutz-Gate**.

Sie soll festlegen, welche Benutzergruppen ressourcenintensive Analysemodi ausführen dürfen. Dazu gehören insbesondere breite oder unbegrenzte Scans von Plan Cache, Systemkatalogen, Query Store, physischen Indexstrukturen, Extended-Events-Daten und mehreren Datenbanken.

Das Modell ist keine allgemeine Benutzer- oder Objektberechtigungsverwaltung und ersetzt keine SQL-Server-Rechte.

Die zentrale Frage lautet:

> Darf der aktuelle Login diesen kostenintensiven Analysepfad starten?

Erst danach wird getrennt geprüft:

> Besitzt der Login die technischen SQL-Server-Berechtigungen, um die benötigten Quellen zu lesen?

## 2. Aktuelles Einschluss- und Ausschlussmodell

Die Policy arbeitet als Whitelist für geschützte Analyseklassen:

- Ohne aktive Policy sind geschützte Klassen offen.
- Sobald mindestens eine aktive Policyzeile existiert, sind geschützte Klassen nur für passende Windows-Gruppen oder sysadmin freigegeben.
- Benutzer außerhalb dieser Gruppen sind für den jeweiligen ressourcenintensiven Pfad ausgeschlossen.
- Es existieren derzeit keine expliziten Benutzer-Deny-Zeilen und keine Deny-Priorität.
- Der Ausschluss entsteht durch den fehlenden Gruppenmatch (`NO_MATCH`).

Damit können Benutzer von ressourcenintensiven Abfragen ein- beziehungsweise ausgeschlossen werden, ohne dass das Framework SQL-Server-Berechtigungen verändert.

## 3. Vier getrennte Ebenen

1. **Kostenklasse:** Ist der gewählte Modus leicht, erweitert, tief oder forensisch?
2. **Ressourcenpolicy:** Ist die Analyseklasse für den aktuellen Login freigegeben?
3. **Technische Capability:** Unterstützen Version, Plattform, Datenbankzustand und Feature die Quelle?
4. **SQL-Berechtigung:** Darf der Login die konkrete DMV oder den Systemkatalog lesen?

Die Ebenen dürfen nicht vermischt werden:

- `DENIED_GROUP` bedeutet: interner Ressourcenschutz verweigert den Pfad.
- `DENIED_PERMISSION` bedeutet: SQL Server verweigert die technische Quelle.

## 4. Gesamtfluss

```text
Aufruf einer Analyse-Procedure
        |
        v
Parameter und Analysemodus normalisieren
        |
        v
Ist der angeforderte Pfad ressourcenintensiv?
        |
        +-- nein -------------------------> begrenzten Standardpfad ausführen
        |
        v
Analyseklasse aus VW_AnalyseClassCatalog
        |
        v
Ressourcenpolicy aus VW_AnalyseAccessCurrent
        |
        +-- nicht freigegeben ------------> DENIED_GROUP
        |
        v
Version, Feature, Plattform und Objekt prüfen
        |
        +-- nicht verfügbar --------------> UNAVAILABLE_*
        |
        v
SQL-Berechtigung oder sichere Probe prüfen
        |
        +-- Recht fehlt ------------------> DENIED_PERMISSION
        +-- Sicht eingeschränkt ----------> AVAILABLE_LIMITED
        |
        v
Begrenzte Deep-Abfrage ausführen
        |
        v
AVAILABLE / AVAILABLE_LIMITED / strukturierter Fehlerstatus
```

## 5. Analyseklassen als Kostenklassen

`[monitor].[VW_AnalyseClassCatalog]` beschreibt nicht primär fachliche Rollen, sondern Kosten- und Risikoprofile.

| Spalte | Bedeutung |
|---|---|
| `AnalysisClass` | Stabiler, case-sensitiver Klassencode |
| `AnalysisLevel` | `STANDARD`, `ERWEITERT`, `DEEP` oder `FORENSIK` |
| `RequiresGroupGate` | `1`: ressourcenintensiver Pfad benötigt Gruppenfreigabe |
| `DefaultMaxRows` | Empfohlene Standardbegrenzung |
| `DefaultTimeoutSeconds` | Empfohlenes Laufzeitbudget |
| `Description` | Kosten, Umfang und Aussagegrenze |

Geschützte Beispiele:

- `LOCKS_DEEP`
- `LOG_VLF_DEEP`
- `PLAN_CACHE_DEEP`
- `SHOWPLAN_XML_DEEP`
- `CATALOG_DEEP`
- `PHYSICAL_STATS_DEEP`
- `INDEX_OPERATIONAL_DEEP`
- `QUERY_STORE_DEEP`
- `CROSS_DATABASE_DEEP`
- `COLUMNSTORE_DEEP`
- `EXTENDED_EVENTS_FORENSICS_DEEP`
- `ENTERPRISE_TOPOLOGY_DEEP`

Eine Procedure kann einen begrenzten Standardpfad ohne Gate anbieten und nur beim Wechsel auf einen teuren Modus die Deep-Klasse prüfen.

Beispiel: `[monitor].[USP_QueryStats]` verwendet `PLAN_CACHE_DEEP` erst für `VOLL`, mehr als 1.000 Zeilen oder unbegrenzte Ausgabe.

## 6. Policyquelle

`[monitor].[VW_AnalyseAccessPolicy]` enthält die Gruppen-Whitelist für ressourcenintensive Klassen.

Das Framework führt keine `GRANT`, `DENY`, `REVOKE`, Rollenänderung oder AD-Gruppenpflege aus.

| Spalte | Bedeutung |
|---|---|
| `AnalysisClass` | Exakte geschützte Klasse oder `*` für alle geschützten Klassen |
| `ADGroupName` | Windows-Gruppe, deren Mitglieder den Pfad ausführen dürfen |
| `IsEnabled` | Nur `1` ist aktiv |
| `ValidFromUtc` | Optionaler Beginn, inklusive |
| `ValidToUtc` | Optionales Ende, exklusiv |
| `Priority` | Dokumentations- und Sortierwert; keine Allow-/Deny-Priorität |
| `Comment` | Zweck und lokale Betriebsentscheidung |

### 6.1 Aktivierungssemantik

- Keine aktive Zeile → `OPEN_POLICY`; geschützte Pfade sind offen.
- Mindestens eine aktive Zeile → Whitelist ist aktiv.
- Passender Klassen- oder `*`-Gruppenmatch → Pfad erlaubt.
- Kein Match → Pfad gesperrt (`NO_MATCH` / `DENIED_GROUP`).
- Ungeschützte Klassen → `NOT_REQUIRED`.
- sysadmin → `SYSADMIN`-Bypass.

Eine einzelne aktive Regel aktiviert die Whitelist global für alle geschützten Klassen. Deshalb müssen vor Aktivierung alle gewünschten Deep-Klassen oder ein bewusstes `*`-Fallback betrachtet werden.

## 7. Effektive Gruppenprüfung

`[monitor].[VW_AnalyseAccessCurrent]` berechnet eine Zeile je Analyseklasse.

Prüfreihenfolge:

1. `RequiresGroupGate = 0` → `NOT_REQUIRED`
2. sysadmin → `SYSADMIN`
3. keine aktive Policy → `OPEN_POLICY`
4. Windows-Gruppe in `[sys].[login_token]` → `LOGIN_TOKEN`
5. positiver `IS_MEMBER`-Fallback → `IS_MEMBER`
6. kein Match → `NO_MATCH`

`[sys].[login_token]` ist der bevorzugte Nachweis. Gruppenänderungen werden erst mit einer neuen Anmeldung zuverlässig wirksam.

Bei SQL-Logins liefert `IS_MEMBER` typischerweise `NULL`; daraus entsteht keine Freigabe für geschützte Pfade.

## 8. Technische Capability und SQL-Rechte

Diese Ebene ist nachgelagert und unabhängig vom Ressourcenschutz.

`[monitor].[VW_FrameworkFeatureCatalog]` beschreibt Version, Scope, technische Probe und erforderliche SQL-Berechtigung.

Typische Rechte:

| Version | Serverquellen | Datenbankquellen |
|---|---|---|
| SQL Server 2019 | `VIEW SERVER STATE` | `VIEW DATABASE STATE` |
| SQL Server 2022/2025 | `VIEW SERVER PERFORMANCE STATE` | `VIEW DATABASE PERFORMANCE STATE` |

Prüfarten:

- `HAS_PERMS_BY_NAME`: deklarative Prüfung möglich;
- `PROBE_ONLY`: begrenzte read-only Probe notwendig.

Eine Gruppenfreigabe vergibt diese Rechte nicht. Umgekehrt erlaubt ein vorhandenes DMV-Recht keinen durch die interne Policy gesperrten Deep-Pfad.

## 9. Zusammenspiel

| Ressourcenpolicy | Technische Quelle | Ergebnis |
|---|---|---|
| freigegeben | vollständig nutzbar | `AVAILABLE` |
| freigegeben | eingeschränkte Sicht | `AVAILABLE_LIMITED` |
| freigegeben | Probe erfolgreich, Vollständigkeit unklar | `AVAILABLE_UNVERIFIED` |
| freigegeben | SQL-Recht fehlt | `DENIED_PERMISSION` |
| nicht freigegeben | technisch verfügbar oder unbekannt | `DENIED_GROUP` |
| freigegeben | Version/Feature/Objekt fehlt | entsprechender `UNAVAILABLE_*`-Status |

## 10. Öffentliche Diagnoseobjekte

### Ressourcenschutz prüfen

```sql
EXEC [monitor].[USP_CheckAnalyseAccess]
      @ResultSetArt = 'CONSOLE';
```

```sql
EXEC [monitor].[USP_CheckAnalyseAccess]
      @AnalyseKlasse = 'PLAN_CACHE_DEEP'
    , @ResultSetArt  = 'RAW';
```

```sql
EXEC [monitor].[USP_CheckAnalyseAccess]
      @NurGesperrte = 1;
```

### Policy und technische Voraussetzungen gemeinsam prüfen

```sql
EXEC [monitor].[USP_CheckFrameworkCapabilities]
      @DatabaseNames      = N''
    , @AnalyseKlasse      = 'PLAN_CACHE_DEEP'
    , @MitGruppenpruefung = 1
    , @ResultSetArt       = 'CONSOLE';
```

`@MitGruppenpruefung = 0` dient nur zur technischen Capabilitydiagnose. Der Parameter ist kein Bypass für Deep-Pfade in den eigentlichen Analyse-Procedures.

## 11. Designprinzipien

- Prüfen Sie den Ressourcenschutz vor einer teuren Materialisierung.
- Leichte Standardpfade möglichst nutzbar lassen.
- Deep-Pfade explizit, begrenzt und opt-in gestalten.
- Gruppenfreigabe und SQL-Rechte getrennt melden.
- Keine automatische Rechte- oder Gruppenvergabe.
- Keine Persistenz von Gruppenmitgliedschaften.
- Keine Abfrage beliebiger Verzeichnisdienste.
- Verwenden Sie Beispiele und freigegebene Auszüge ausschließlich mit synthetischen Domain-, Gruppen-, Login- und Umgebungswerten.

## 12. Weiterführende Dokumente

- [Administration](../Operations/Authorization_Administration.md)
- [Fehlersuche](../Operations/Authorization_Troubleshooting.md)
- [Policy-Beispiele](../Reference/Authorization_Policy_Examples.md)
- [Status- und AccessReason-Referenz](../Reference/Authorization_Status_and_Access_Reasons.md)
- [Beispielaufrufe](../../Code/Examples/050_Authorization_Examples.sql)
