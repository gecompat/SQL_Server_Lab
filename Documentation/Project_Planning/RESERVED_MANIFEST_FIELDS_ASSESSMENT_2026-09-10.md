# Bewertung reservierter Manifestfelder

| Merkmal | Wert |
|---|---|
| Status | `validated` (Bewertung, keine neue Runtimefreigabe) |
| Stand | 2026-09-10 |
| Quellstand | `be0a16532a76d7e8b255224e3d474e55ce16fecc` |
| Auftrag | Bewertungsanteil „Reservierte Manifestfelder“ des [autonomen Arbeitsplans](AUTONOMOUS_DEVELOPMENT_WAVE_2026-09-10.md) |

## Entscheidung

Die derzeit reservierten Manifestfelder bleiben reserviert. Für die ersten
Versionen der geplanten Upgrade-/Regressions- und Point-in-Time-Recovery-
Szenarien sind direkte, begrenzte SQL-Schritte ausreichend; ein zusätzlicher
SQL-Agent-, CLR- oder Authentifizierungsvertrag ist dafür keine Voraussetzung.
Die späteren fachlichen Anwendungsfälle rechtfertigen eine erneute Bewertung
der jeweils benötigten Fähigkeit, aber kein pauschales Freischalten aller
vorbereiteten Schalter. Bestehende ausführbare Collation-, Storage- und
External-Runtime-Verträge werden zuerst wiederverwendet.

Dies ist eine Projektentscheidung über den nächsten Umsetzungsscope.
`validated` bestätigt hier den dokumentierten Abgleich von Bedarf, Code,
Abhängigkeiten und Abnahmekriterien. Es bestätigt keine neue SQL- oder
Providerfunktion. Die verbleibenden Implementierungsaufgaben im Arbeitsplan
bleiben unverändert offen.

## Ermittelte Vertragsgrenze

Das [Lab-Schema](../../Schemas/lab-manifest.schema.json) kennzeichnet neun
direkte `serverConfig`-Felder und `externalScripts.customImage` als reserviert;
zusätzlich sind die Werte `custom-image` und `pre-built` von
`externalScripts.installMethod` reserviert. Der schemaabgeleitete
[Manifestvertrag](../../Private/ManifestBuilder.ps1) lehnt explizite Nutzung
vor Auflösung und Mutation ab. Dies gilt auch für einen ausdrücklich gesetzten
booleschen Wert `false`; das Feld wird weggelassen. Schema-Defaults sind keine
Erlaubnis, reservierte Felder in ausführbare Manifeste aufzunehmen.

Reserviert ist die benannte Manifestoberfläche. Der vorhandene generische
`spConfigure`-Pfad in [ServerConfig.ps1](../../Private/ServerConfig.ps1)
verarbeitet weiterhin ausdrücklich angegebene SQL-Konfigurationswerte. Ein
solcher Einzelaufruf belegt noch keinen vollständigen Dienst-, Assembly-,
Authentifizierungs- oder Providervertrag für den entsprechenden Fachschalter.

## Einzelentscheidungen

Die Aufwandsklassen sind relative technische Einschätzungen: **S** bezeichnet
eine begrenzte Eingabe-/Aliasentscheidung, **M** eine neue Konfiguration mit
SQL- und Providerabnahme, **L** zusätzliche Host-, Identitäts-, Daten- oder
Recovery-Verträge. Sie sind keine Termin- oder Kostenfreigabe.

| Feld oder Wert | Bedarf und Nutzen | Entscheidung und Abhängigkeit | Risiko / Aufwand | Konkreter nächster Schritt bei erneutem Bedarf |
|---|---|---|---|---|
| `serverConfig.collation` | Collation-Auswahl ist für Sprach- und Vergleichsszenarien sinnvoll. | Reserviert lassen; der ausführbare Einstieg ist `instances[].collation`. `COL-001` ergänzt diesen bestehenden Vertrag um Katalog und Suche. | Zwei konkurrierende Sollwerte; S für Aliasbewertung, Collation-Abnahme separat. | Erst einen eindeutigen Vorrang-/Konfliktvertrag entscheiden, falls ein Alias wirklich benötigt wird. Keine zweite Runtimeimplementierung. |
| `defaultPaths` | SQL-Dateiplatzierung ist ein Kernbedarf. | Reserviert lassen; gebundene Storage-Lanes, Rollen und dateigenauer Plan sind bereits die passende Grundlage. | Freie Pfade umgehen Bindung und Recovery; M. | Einen konkreten fehlenden SQL-Dateifall am Storage-Vertrag reproduzieren und dort ergänzen; keinen unabhängigen Pfadschalter einführen. |
| `sqlAgent` | Geplante CDC-, Betriebsautomatisierungs- und vollständige Refresh-Fälle können Jobs und Schedules benötigen. | Für den ersten direkten PITR-/Upgrade-Executor nicht erforderlich; bis zu einem konkreten Agent-Szenario reserviert. | Dienst-/Providerkonfiguration, Restart und Job-Ownership; M. | Kleinen SQL-2025-T-SQL-Job als Ziel definieren; Aktivierung, Ausführung, Restart, No-op und Entfernung nur eigener Jobs getrennt für Docker/Podman und später Hyper-V prüfen. |
| `clrEnabled` | Ein künftiges Assembly-/Kompatibilitätsszenario könnte CLR benötigen; kein aktueller Kernfall verlangt eine Assembly. | Reserviert lassen; ein Boolean ersetzt weder signiertes Assembly-Artefakt noch Trust- und Berechtigungskonzept. | Ausführung verwalteten Codes und Assembly-Vertrauen; L. | Synthetische signierte Assembly, benötigte Rechte, Negativtest für unbekannten Hash und vollständigen Assembly-/Permission-Cleanup festlegen; `clr strict security` erhalten. |
| `filestream` | Windows-Datei-/Datenbankpakete und Persistenzprüfungen besitzen einen fachlichen FILESTREAM-Bezug. | Reserviert lassen; vorhandene Paket-/Backupfähigkeit ist von automatischer FILESTREAM-Aktivierung getrennt. Die eigenen Persistenz-Freigabegates bleiben maßgeblich. | Host-/Dienstkonfiguration, Dateizugriff und vollständige Datenübernahme; L. | Einen isolierten kompatiblen Windows-/SQL-Referenzfall mit Aktivierungs-, Inhalts-, Restart-, Backup-/Restore- und Cleanup-Nachweis definieren. Erst danach den Manifestvertrag ergänzen. |
| `containedDatabases` | Portable Datenbankidentitäten sind ein möglicher späterer Migrationsfall. | Reserviert lassen; aktueller Datei-/Backuptransfer bestätigt keine Übernahme oder Freigabe von Datenbankbenutzern. | Verlagerung von Zugangsverwaltung und Authentifizierungsgrenzen; L. | Synthetische Contained-Datenbank mit erlaubten Benutzertypen und positiven/negativen Loginproben planen; Restore- und Benutzer-Cleanup einschließen. |
| `authMode` | Ein künftiges Identity-/Windows-Authentication-Lab benötigt gezielte Authentifizierung. | Reserviert lassen; kein impliziter Wechsel bestehender Run-Zugänge. | Verlust des Verwaltungszugangs, Credential-/Domain-Bindung; L. | Vor dem Moduswechsel einen verifizierten alternativen Verwaltungszugang, Wiederaufnahme und Rückkehr zum Ausgangszustand nachweisen. |
| `errorLogRetention` | Begrenzte Diagnosedaten sind sinnvoll. | Für die geplante SQL-Observability zuerst Größe und Aufbewahrung der eigenen sanitisierten Evidence umsetzen; SQL-Engine-Error-Logs sind ein eigener Vertrag. | Verlust von Diagnoseevidence und unbeabsichtigte Rohdatenübernahme; M. | Einen konkreten lokalen Logrotationsfall mit Größen-/Anzahlgrenze, Providerbindung und Nachweis erhaltener Fehlerursachen definieren. |
| `instantFileInit` | Kontrollierte Dateiwachstums-/Performanceversuche können IFI untersuchen. | Reserviert lassen; ein Manifestdefault darf keine Hostrechte still vergeben. | Dienstkonto-/Hostberechtigung und Datenrestzugriff; L. | Bestehenden wirksamen Zustand zuerst read-only erfassen; einen isolierten synthetischen Vergleich mit explizitem Berechtigungs- und Recovery-Vertrag abnehmen. |
| `externalScripts.customImage` | Wiederverwendbare External-Runtime-Images können Buildzeit sparen. | Reserviert lassen; katalogisierte und digestgebundene Derived Images haben Vorrang vor freien Image-Namen. | Unbekannte Herkunft, Versionen, Lizenz und Launch-Capabilities; L. | Bedarf mit der separaten Modell-/Imagecache-Bewertung abgleichen; nur einen inhaltlich gebundenen Import mit Herkunfts-, Capability- und SQL-Roundtrip-Nachweis vorschlagen. |
| `externalScripts.installMethod = custom-image / pre-built` | Eine explizite Wiederverwendungsart kann später Bedienung vereinfachen. | Beide Werte reserviert lassen, bis ein vollständiger gemeinsamer Image-/Providervertrag existiert; keine bloße Weiterleitung eines frei angegebenen Tags. | Umgehung bestehender Digest-, Runtime- und Recovery-Bindungen; L. | Zunächst eine einzige katalogisierte Wiederverwendungsvariante mit Drift-/Restart-/Cleanup-Test definieren; danach Schema, Parser, Resolver, Runtime, Beispiel und Hilfe gemeinsam ergänzen. |

## Gesonderte Adapterfelder

`sqlPackageCatalogs` und `defaultPackageRefs` gehören zum
[Projektadapter-Schema](../../Schemas/project-adapter.schema.json), nicht zu
`serverConfig`. [ProjectAdapter.ps1](../../Private/ProjectAdapter.ps1) warnt bei
nichtleeren Werten und wertet sie nicht aus. Sie erhalten deshalb keine
Ausführungsbehauptung aus dieser Manifestbewertung.

Beide bleiben reserviert. Ein neuer Package-basierter Partnerpilot muss zuerst
konkreten SQL-Nutzen, katalogisierte Quellen, Version-/Hashbindung, Ownership,
Fehlerwiederaufnahme und Cleanup definieren. Aufwand **M** für den ersten
begrenzten Pilot; die bestehende gemeinsame Package-Infrastruktur ist dessen
Aufsetzpunkt. Die aktuelle Warnungsgrenze darf nicht mit der strengeren
Ablehnung reservierter Lab-Manifestfelder verwechselt werden.

## Fachliche Quellen und Abnahme einer späteren Freischaltung

Der Bedarf stammt aus den bestehenden
[SQL-Anwendungsfällen](NEW_SQL_LAB_USE_CASES_BACKLOG.md), dem
[Persistenzbacklog](PERSISTENT_STORAGE_REUSE_AND_LAB_DATA_BACKLOG.md) und dem
[vollständigen Evaluation-Refresh](FULL_INSTANCE_EVALUATION_REFRESH_BACKLOG.md).
Ihre fachlichen Grenzen werden nicht durch Schemafelder erweitert.

Microsoft beschreibt SQL Agent unter Linux als eigene
[Dienst-/Konfigurationseinstellung](https://learn.microsoft.com/en-us/sql/linux/configure/mssql-conf?view=sql-server-ver17#enable-sql-server-agent).
Die dokumentierten Grenzen von
[CLR Strict Security](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/clr-strict-security?view=sql-server-ver17),
[Contained-Datenbanken](https://learn.microsoft.com/en-us/sql/relational-databases/databases/security-best-practices-with-contained-databases?view=sql-server-ver17)
und [Instant File Initialization](https://learn.microsoft.com/en-us/sql/relational-databases/databases/database-instant-file-initialization?view=sql-server-ver17)
begründen die getrennten Trust-, Zugangs- und Hostberechtigungsprüfungen.
Diese Quellen wurden am 2026-09-10 geprüft; sie ersetzen keine lokale Abnahme.

Eine spätere Freischaltung benötigt einen konkreten synthetischen SQL-Fall,
klaren Provider-/Versionsscope, Schema und Parser, Runtime mit Recovery,
ausführbares Beispiel, Benutzerhilfe, fokussierte Negativtests und getrennte
native Postconditions einschließlich Cleanup. Bis dahin sind die Felder weder
im Wizard noch im direkten Manifestpfad als ausführbar auszuweisen.
