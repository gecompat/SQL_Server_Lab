# Anzeige der SQL-Verbindungseinstellungen

Die CLI-Runstatusansicht und die GUI unter **Verbindungen und CMS** zeigen
je Ziel ausdrücklich `Encrypt` und `TrustServerCertificate`. Neue gemeinsame
Lab-Connection-Strings und SSMS-Registrierungsexporte behalten den Standard
`Encrypt=True;TrustServerCertificate=True`. Eine Anzeige von `False` ändert
keine Verbindung und richtet keine Zertifikate oder Client-Trust ein.

Der private [gemeinsame Reader](../../Private/SqlConnectionSettings.ps1)
verwendet `System.Data.SqlClient.SqlConnectionStringBuilder`. Er öffnet keine
Verbindung und wertet keine Kennwortteile als eigene Optionen aus. Quoting,
Semikolons, Escaping, Groß-/Kleinschreibung und doppelte Schlüssel folgen dem
tatsächlichen nativen Parser. `ShouldSerialize` unterscheidet ausdrücklich
angegebene TLS-Werte von dessen impliziten Defaults. Fehlende Optionen bleiben
`null`; es wird kein `True` oder `False` aus einem anderen Clientstack geraten.

Eingaben sind auf tatsächliche Strings mit höchstens 65536 Zeichen begrenzt.
Fremde Objekte und ETS-Getter werden nicht ausgeführt. Ungültige oder nicht
unterstützte Strings liefern `Status=UNREADABLE` und beide TLS-Werte `null`,
ohne Rohdiagnose, Endpoint, Benutzer oder Passwort. Leere Eingaben liefern
`NOT_SPECIFIED`; erfolgreich geparste Strings `CONFIGURED_CONNECTION_STRING`.
Die geschlossene Projektion enthält genau `Encrypt`, `TrustServerCertificate`
und `Status`. Ein bekannter Wert ist ein echter Boolean, kein Textboolean.

[Get-SqlServerLabWorkflow](../../Public/Get-SqlServerLabWorkflow.ps1) ergänzt
diese Projektion als `ConnectionSettings` je Containerinstanz, je expliziter
Hyper-V-SQL-Instanz und am bisherigen Hyper-V-Fallback. Die GUI formatiert
ausschließlich diese beiden Werte und feste Statuswörter. Fehlende Werte
erscheinen als `nicht angegeben`, unlesbare als `nicht lesbar`. Die Übersicht
zeigt keine Connection Strings oder Zugangsdaten. Explizites `False` darf
nicht durch einen JavaScript-Default zu `True` werden; bei fehlenden
Metadaten wird kein Defaultziel und kein anderer Instanzwert übernommen.

Die CLI-Statusansicht in [Invoke-SqlServerLab](../../Public/Invoke-SqlServerLab.ps1)
zeigt dieselbe Projektion als eigene `Connection Settings (Provider/Instanz)`-
Zeile neben dem bestehenden Connection String. Die bisherigen bewussten
Zugangs-/Secretanzeigen der Statusansicht erhalten keine neue Entschlüsselung.

Diese Werte beschreiben den gespeicherten Connection String. Sie sind weder
ein Live-Verbindungstest noch ein Ketten-, SAN-, Ablauf-, Trust- oder
Clientqualifikationsnachweis. Die additive öffentliche strikte Moduswahl und der qualifizierte V2-Export sind im [operativen TLS-Vertrag](AUTHENTICATED_TLS_OPERATIONAL_LAB.md) für eigene Windows-/Docker-/Podman-Labs mit SQL 2025 CU9, SQL 2022 CU27 oder SQL 2019 CU32 begrenzt.

## Getrennter Status ohne aktuelle Liveprüfung

Der Workflow ergänzt je SQL-Ziel den skalaren `TlsQualificationStatus`.
Die bestehende dreifeldrige `ConnectionSettings`-Projektion bleibt erhalten.
CLI, SQL-Zielkarte und Verbindungsübersicht zeigen den Status unmittelbar
am jeweiligen Ziel. Der gemeinsame Reader leitet ihn ausschließlich aus
den ausdrücklich gespeicherten Optionen ab; er liest keine Qualifikation,
Exporte, Zertifikate, Secrets oder Truststores und öffnet keine Verbindung.

| Status | Bedeutung der Anzeige |
|---|---|
| `NOT_EVALUATED` | Encrypt=True und TrustServerCertificate=False sind angegeben; hier nicht aktuell geprüft. Eine frühere Prüfung andernorts ist damit weder bestätigt noch ausgeschlossen. |
| `CERTIFICATE_VALIDATION_DISABLED` | Zertifikatsprüfung laut gespeicherter Konfiguration abgeschaltet. |
| `ENCRYPTION_NOT_REQUESTED` | Encrypt=False ist angegeben. Die tatsächlich ausgehandelte Verschlüsselung ist damit nicht ermittelt; der Server kann sie erzwingen. |
| `INCOMPLETE_CONFIGURATION` | Mindestens eine ausdrückliche TLS-Option fehlt; keine aktuelle Prüfung. |
| `UNREADABLE_CONFIGURATION` | Die Konfiguration ist nicht lesbar; keine aktuelle Prüfung. |

Fehlende, unbekannte oder falsch typisierte Browsermetadaten ergeben nur
„Kein aktueller TLS-Prüfstatus gemeldet“. Es gibt keinen Status `QUALIFIED`
und keine Aufwertung durch Runtime-READY, gespeichertes False oder einen
früheren Export. Die UI startet beim Anzeigen keine zusätzliche Prüfung.
Die [ausdrückliche öffentliche Liveprüf-API](AUTHENTICATED_TLS_LIVE_QUALIFICATION.md)
prüft das eigene operative Container-Lab mit beiden echten Clients erneut.
Ihr Ergebnis beschreibt ausschließlich den Beobachtungszeitpunkt und wird
nicht in diesen Konfigurationsstatus übernommen. Die dedizierte Liveaktion
am SQL-Ziel ist im [Bedienungspfad](../HowTo/WORKFLOW_UI.md#tls-jetzt-prüfen)
beschrieben und für die drei operativen Windows-/Docker-/Podman-Profile
in getrennten [Browser-](../Quality/TLS_UI_LIVE_QUALIFICATION_ACCEPTANCE_2026-10-23.md)
und [Profilabnahmen](../Quality/TLS_UI_PROFILE_MATRIX_ACCEPTANCE_2026-10-23.md)
belegt. Diese Konfigurationsanzeige allein liefert diesen Nachweis nicht.
Die [getrennte native Anzeigeabnahme](../Quality/TLS_CONFIGURATION_STATUS_DISPLAY_2026-10-22.md)
prüfte `NOT_EVALUATED` mit echtem Produktserver und Browser an zwei eigenen
Windows-/Docker-/Podman-SQL-2025-CU9-Labs einschließlich Cleanup.

Die [fokussierte Suite](../../Tests/Static/Invoke-SqlConnectionSettingsChecks.ps1)
prüft den tatsächlichen Default-Erzeuger, native Parsergegenfälle, fehlende
Werte, geschlossene Ablehnung und den tatsächlichen CLI-Renderer mit festen
Workflowantworten. Die [JavaScript-Fixture](../../Tests/Static/Fixtures/WorkflowSqlTargetChecks.cjs)
führt den tatsächlichen GUI-Renderer mit begrenzter DOM-Fixture aus und prüft
beide Werte, explizites `False`, fehlende Angaben und Geheimnisfreiheit.
Dies ist keine gerenderte Browser- oder neue SQL-Verbindungsabnahme.
Die getrennte gerenderte Komponentenabnahme und die tatsächliche lesende
Workflow-Projektion sind in der [Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md#angegebene-tls-werte-in-cli-und-gui-vom-2026-10-17)
beschrieben. Die zusätzliche
[Windows-Produktseitenabnahme vom 2026-10-21](../Quality/TLS_WINDOWS_RENDERED_CONNECTION_SETTINGS_2026-10-21.md)
bestand an eigenen qualifizierten Docker-/Podman-SQL-2025-CU9-Labs mit echter
Workflowantwort, sichtbaren False-Werten und exakt angezeigtem Connection
String. Die Default-Browser-Erstellung ist separat für
[SQL 2025 CU9](../Quality/TLS_UI_DEFAULT_CREATION_ACCEPTANCE_2026-10-23.md)
und [SQL 2019 CU32 sowie 2022 CU27](../Quality/TLS_UI_DEFAULT_CREATION_PROFILES_ACCEPTANCE_2026-10-23.md)
belegt. Authentifizierte Browser-Erstellung, Clipboard, weitere
Erstellungsprofile, Modi und Plattformen bleiben getrennte offene Nachweise.
