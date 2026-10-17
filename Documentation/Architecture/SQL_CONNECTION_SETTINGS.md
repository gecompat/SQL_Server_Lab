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
Clientqualifikationsnachweis. Die öffentliche strikte Moduswahl und der
qualifizierte Export bleiben Teil von [TLS-001](../Project_Planning/TLS_001_ISOLATED_CA_DESIGN.md).

Die [fokussierte Suite](../../Tests/Static/Invoke-SqlConnectionSettingsChecks.ps1)
prüft den tatsächlichen Default-Erzeuger, native Parsergegenfälle, fehlende
Werte, geschlossene Ablehnung und den tatsächlichen CLI-Renderer mit festen
Workflowantworten. Die [JavaScript-Fixture](../../Tests/Static/Fixtures/WorkflowSqlTargetChecks.cjs)
führt den tatsächlichen GUI-Renderer mit begrenzter DOM-Fixture aus und prüft
beide Werte, explizites `False`, fehlende Angaben und Geheimnisfreiheit.
Dies ist keine gerenderte Browser- oder neue SQL-Verbindungsabnahme.
Die getrennte gerenderte Komponentenabnahme und die tatsächliche lesende
Workflow-Projektion sind in der [Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md#angegebene-tls-werte-in-cli-und-gui-vom-2026-10-17)
beschrieben; die vollständige Produktseiten-/SQL-Komposition bleibt separat.
