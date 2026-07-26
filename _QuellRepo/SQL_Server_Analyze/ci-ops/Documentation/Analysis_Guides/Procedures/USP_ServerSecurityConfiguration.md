# [monitor].[USP_ServerSecurityConfiguration]

**Bereich:** Server Health<br>
**Zweck:** Erzeugt Sicherheits-Reviewbefunde zu relevanten Serveroptionen.<br>
**Beobachtungsart:** Katalogsnapshot<br>
**Kostenklasse:** LOW

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche sicherheitsrelevanten Servereinstellungen und Prinzipal-/Endpointmuster verdienen ein Securityreview?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ServerSecurityConfiguration]
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `configuration`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Zeile entspricht einer Sicherheitskonfiguration oder einem normalisierten Reviewfinding.

## So lesen

Berücksichtigen Sie Scope, aktuellen Wert, Exposition, Severity, Evidence und `EvidenceLimit` gemeinsam.

## Warum kann das problematisch sein?

Unsichere Optionen können Angriffsfläche oder unerwünschte Rechtepfade eröffnen.

## Wann ist es kein Problem?

Ein Feature kann betrieblich erforderlich und durch Berechtigungen, Audit oder andere Kontrollen abgesichert sein.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** `xp_cmdshell` aktiviert ist ein Reviewbefund, aber die reale Gefährdung hängt von Berechtigungen, Nutzung und Kompensationskontrollen ab. Prüfen Sie Sicherheitskonzept und Audit.

**Ähnlich aussehender Gegenfall:** Ein Feature kann betrieblich erforderlich und durch Berechtigungen, Audit oder andere Kontrollen abgesichert sein. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_ServerSecurityConfiguration` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW |
| Standardpfad | Liest sieben fest benannte sicherheitsrelevante Serveroptionen, SQL-Dienste sowie vier `SERVERPROPERTY`-/Rollenwerte. Jede Teilquelle schreibt eigenen Status. |
| Teuerster Pfad | Es gibt keinen erweiterten Modus; RAW/JSON zeigen nur mehr Projektionen derselben kleinen Quellen. Die Procedure enumeriert keine Logins, Berechtigungen, Credentials, Endpoints oder Datenbankbenutzer. |
| Haupttreiber | Feste Konfigurationsliste und Zahl der SQL-Dienste. Resultgröße ist unabhängig von Datenbanken und Loginanzahl. |
| Skalierung | Praktisch konstant. Finding-CASE-Auswertung und Sortierung sind gering; Sourcefehler werden isoliert statt durch teure Fallbacks kompensiert. |
| Ressourcen | Ein kleiner `sys.configurations`-Filter, `sys.dm_server_services`, `SERVERPROPERTY`/`IS_SRVROLEMEMBER` und Temp-Tabellen. Kein Registry-, Netzwerk- oder Dateisystemscan. |
| Begrenzungswirkung | Kein `@MaxZeilen`, weil jede Konfigurations-/Dienstzeile Teil des Security-Snapshots ist. `NONE` spart Ausgabe, nicht die Quellprüfung. |
| Locking und Nebenwirkungen | Read-only. Es werden keine Features, Logins oder Dienste geändert; konfigurierte und aktive Werte beziehungsweise Dienststatus können sich zwischen den drei Teilabfragen ändern. |
| Schutzmechanismus | Kein Gate und kein Teil-Scope. Der Sicherheitsvertrag ist fest auf sieben benannte Konfigurationen, SQL-Dienste und vier Server-/Rollenwerte begrenzt; Login-, Benutzer- und Berechtigungsinventare werden nicht geöffnet. |
| Sicherer Einsatz | CONSOLE direkt nutzen; Server-/Maschinenname und Dienstkonten aus RAW/JSON/TABLE als sensible Betriebsmetadaten behandeln. |
| Aussagegrenze | Die Auswertung ist ein enger Konfigurationscheck, kein Berechtigungs- oder Angriffsflächen-Audit. `OK_OR_CONTEXT_DEPENDENT` bestätigt weder Least Privilege noch sichere Proxy-/Credential-/Endpointkonfiguration. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche sicherheitsrelevanten Servereinstellungen und Prinzipal-/Endpointmuster verdienen ein Securityreview?

### Technischer Hintergrund

Server Principals, Roles und Permissions, Authentication, Endpoints, Service Accounts und Konfigurationsoptionen bilden mehrere Sicherheitsebenen. Metadata Visibility begrenzt die Sicht. Frameworkbefunde sollen die Konfiguration inventarisieren und keine Credentials oder Secrets ausgeben.

### Datenkette

`sys.configurations`, `sys.dm_server_services`.

### Source Select

Der Konfigurationszweig liest ausschließlich die sicherheitsrelevanten Optionsnamen:

```sql
SELECT
      [c].[name]
    , [c].[value]
    , [c].[value_in_use]
    , [c].[is_dynamic]
FROM [sys].[configurations] AS [c] WITH (NOLOCK)
WHERE [c].[name] IN
      (N'show advanced options',
       N'xp_cmdshell',
       N'Ole Automation Procedures',
       N'Ad Hoc Distributed Queries',
       N'clr enabled',
       N'clr strict security',
       N'external scripts enabled',
       N'remote admin connections',
       N'contained database authentication');
```

**Wichtig für die Eigenlast:** Die Quellen sind klein. Dienststatus und Instant File Initialization kommen separat aus `sys.dm_server_services`; die Procedure ändert keine Konfiguration und keine Dienstkonten.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Metadaten-/Konfigurationsstand.

### Bewertung und Gegenprobe

Verbinden Sie Finding, Scope, Severity und Confidence, die betroffene Option oder Rolle sowie die dokumentierte Policy. Prüfen Sie insbesondere `sysadmin`, `CONTROL SERVER`, unsichere Optionen und exponierte Endpoints zusammen mit dem zuständigen Owner und der fachlichen Notwendigkeit.

### Typische Fehlinterpretation

Technischer Befund ist kein vollständiges Berechtigungsaudit und keine Aussage über organisatorische Genehmigung. Fehlende Sicht darf nicht als fehlende Berechtigung interpretiert werden.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Formales Security-/Identityreview, Audit und Change Governance.

## Primärquellen

- [SQL Server security best practices](https://learn.microsoft.com/en-us/sql/relational-databases/security/sql-server-security-best-practices?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#9-monitorusp_serversecurityconfiguration)
