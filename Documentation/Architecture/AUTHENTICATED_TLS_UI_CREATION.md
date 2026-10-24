# Authentifizierte Container-Erstellung im Browser

Die dedizierte Erstellung ergänzt den [operativen TLS-Lab-Vertrag](AUTHENTICATED_TLS_OPERATIONAL_LAB.md).
Sie verwendet dessen kanonischen Creator und verändert den einfachen Standard
`Encrypt=True;TrustServerCertificate=True` nicht. Bedienung und Voraussetzungen
stehen unter [Workflow-Oberfläche](../HowTo/WORKFLOW_UI.md#authentifiziertes-container-lab-erstellen).
Die [native Abnahme vom 2026-10-24](../Quality/TLS_UI_AUTHENTICATED_CREATION_ACCEPTANCE_2026-10-24.md)
bestand separat mit Docker und Podman für das kompakte SQL-2025-CU9-Lab.
Die zusätzliche [Profilabnahme](../Quality/TLS_UI_AUTHENTICATED_PROFILES_ACCEPTANCE_2026-10-24.md)
bestand separat für kompakte SQL-2019-CU32- und SQL-2022-CU27-Labs mit beiden
Providern. Weitere Ressourcen-, Patch-, Client- und Plattformkombinationen
sind dadurch nicht abgenommen.

## Geschlossener Umfang

Der Dialog unterstützt Windows mit PowerShell 7.5+, ausdrücklich Docker oder
Podman sowie die geschlossenen Profile SQL 2019 CU32, SQL 2022 CU27 und
SQL 2025 CU9. Die bestehende registrierte CA, der Signierkontext,
der aktuelle Clientkontext und CurrentUser-Trust müssen bereits passen.
Der Server verwendet seinen konfigurierten Data Root. Der Browser übermittelt
nur Kandidat-, Controller- und Location-Referenzen, Provider, das ausgewählte
SQL-Profil, Ressourcenprofil, Labnamen, Passwort und eine Request-ID.
Andere Felder, doppelte JSON-Schlüssel, falsche skalare Typen und andere
SQL-/Providerprofile werden abgewiesen. Es gibt keinen automatischen Fallback.

Die neue Instanz heißt `primary`, Autostart bleibt aus. Persistente Stores,
Hostmounts, zusätzliche SQL-Features und vorhandene Labs gehören nicht zu
diesem Dialog. Die öffentliche API unterstützt ihre getrennt dokumentierten
weiteren Profile weiterhin.

## Allokation und Sitzungsbindung

Jeder UI-Start besitzt einen neuen privaten Ticketstore. Die vorhandene
Operator-Capability und HTTP-Umschlagprüfung gelten vor jeder neuen Route.
POST verlangt zusätzlich dieselbe Origin. Requestbodys sind auf 4096 Bytes
begrenzt und verwenden den gemeinsamen zeitbegrenzten UTF-8-Reader.

Der kanonische Creator bestimmt selbst Audit-ID und StateRoot. Ein ausschließlich
privater Callback bindet genau diese neue Allokation vor der Policy-/Runanlage
an das servereigene Ticket. Der unveränderliche private Beleg entsteht unter
`DataRoot/State/authenticated-tls-ui-tickets/<TicketId>.json`. Er enthält
Sitzung, Operator-SID, Request-ID, Audit-ID und StateRoot, kein Passwort.
Ein fehlgeschlagener Callback verhindert die nachfolgende Runanlage.

Erst die tatsächliche erfolgreiche Rückgabe und erneute OwnBinding-Prüfung
geben ein Ziel für die Oberfläche frei. Der Browser erhält eine undurchsichtige
Referenz und eine geschlossene Projektion mit Provider, Profil, Run-ID,
gespeichertem Zustand, lokalem Port und beiden TLS-Booleans. StateRoot,
DataRoot, Registry-/Schlüsselpfade, Credentials und rohe Receipts werden nicht
projiziert. Das serverprivate Ticket erhält das ausgewählte SQL-Profil;
Erstellungsabschluss und jede Zielaktion vergleichen es mit dem frisch
gelesenen kanonischen Record. Die Liveanzeige verlangt genau dessen SQL-Jahr,
Patch und Build. Ein Versionswechsel während des Pollings wird abgewiesen.
Die allgemeine Workflowinventur wird weder umgeschaltet noch
um fremde Auditroots erweitert.

Gleiche Request-ID und gleiche Bytes liefern nur die bereits angenommene
Referenz. Geänderte Bytes mit derselben ID werden abgewiesen. Nach verlorenem
Ergebnis startet der Browser keine weitere Erstellung. Annahme, vollständiger
Erfolg und unbestätigter Ausgang bleiben getrennt. Der private Allokationsbeleg
ermöglicht die gezielte lokale Untersuchung des einen neuen Roots; er ist
keine automatische Recovery- oder Wiederholungsfreigabe.
Ein unbestätigtes Creationticket sperrt weitere Erstellungen serverseitig,
auch mit neuer Request-ID. Beim Laden fragt der Browser zuerst ausschließlich
den eigenen Sitzungszustand ab und hält den Dialog bis zur bestätigten Antwort
gesperrt. Ein Reload hebt die serverseitige Sperre nicht auf. Die Oberfläche
besitzt noch keinen Recovery-Apply oder automatischen Freigabepfad für solche
Tickets; untersuchen und bereinigen Sie ausschließlich das zugeordnete Lab
über den dokumentierten lokalen API-Pfad. Ein neuer Serverstart löst keinen
unklaren Ausgang des früheren Starts auf.

## Zielaktionen und Lebenszyklus

Die Sitzungsansicht bietet ausdrückliche Liveprüfung, Stop, Start, Wiederbindung
und Remove. Jede Aktion verwendet nur die serverprivate Referenz und liest die
kanonischen Run-/Policy-/Runtimebindungen frisch. Der Browser kann keine
anderen Run- oder Rootwerte einschleusen. Die öffentlichen Lifecyclefunktionen
behalten ihre Ownership-, Runtime- und Cleanupprüfungen.

Liveprüfung verwendet beide strikten Clients über die öffentliche API und
projiziert ausschließlich deren validiertes aktuelles Ergebnis. Die Anzeige
verfällt bei Fristablauf, neuer Aktion, expliziter Aktualisierung, ausgeblendetem
Browsertab (`document.hidden`) oder Entladen der Seite (`pagehide`). Ein bloßer
Workspacewechsel innerhalb der Seite ist kein solches Ereignis.
Start/Stop sind keine TLS-Qualifikation; nach einem Neustart ist
die ausdrückliche [Wiederbindung](AUTHENTICATED_TLS_CONTAINER_REBIND.md) erforderlich.
Remove bestätigt nur den tatsächlich erfolgreichen eigenen Cleanup. CA, Trust
und ursprüngliche Schlüssel bleiben erhalten.

Tickets und Jobs sind begrenzt: 64 Sitzungsziele, 256 Requestreceipts und die
gemeinsame Grenze von 256 flüchtigen/persistenten Jobs. Aktionen laufen seriell.
Statusreads starten keine Provider- oder SQL-Arbeit. Browserpolling ist auf
30 Minuten mit einzelnen HTTP-Fristen begrenzt; ein abgebrochener Read erteilt
keine neue Mutationsfreigabe. Schließen des Servers entfernt keine Labs.
Die gespeicherte Sitzungsansicht ist kein Discovery- oder Wiederanlaufvertrag
für einen neuen UI-Start.
