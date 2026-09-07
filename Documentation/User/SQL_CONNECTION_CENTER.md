# SQL-Verbindungszentrale

Die SQL-Verbindungszentrale ist über den Direktaufruf
`.\Invoke-SqlServerLab.ps1 -Action ConnectionCenter` erreichbar. Der
gleichwertige Hauptmenüpfad lautet `Datenbanken und Verbindungen` →
`Verbindungszentrale und SSMS-Endpunkte`. Sie ist der zentrale,
providerübergreifende Katalog aller bekannten SQL-Endpunkte aus Docker, Podman
und Hyper-V. Einträge werden bei den üblichen Konsolen-Lifecycle-Aktionen
automatisch aktualisiert und können jederzeit mit `[6] Jetzt synchronisieren`
neu erzeugt werden.

Der vollständige Aufbau der sechs Windows-/Linux-Testziele und des getrennten
CMS steht im [End-to-End-Runbook](../HowTo/END_TO_END_TEST_ENVIRONMENT.md).

Der Katalog liegt im State Root unter `catalog/sql-connection-center.json`. Er enthält
Endpunkt, Anzeigename, Provider und aktuellen Runtime-Status, aber ausdrücklich keine
Kennwörter oder Connection Strings mit Kennwort.

Der Katalog ist interne Zustandsverwaltung. Sichtbare Exporte werden davon getrennt
unter `Lab_Data/Exports` abgelegt. Das interaktive Menü zeigt den vollständigen
Zielpfad vor dem Schreiben an und erlaubt eine Änderung. Ist kein `Lab_Data`
konfiguriert, wird kein benutzerspezifischer State-Root-Pfad vorgeschlagen; stattdessen
muss ein Zielpfad ausdrücklich eingegeben oder der Export abgebrochen werden.

## SSMS

`[3]` schlägt `Lab_Data/Exports/sql-server-lab.regsrvr` vor und erzeugt dort oder
am ausdrücklich eingegebenen Ziel einen kennwortfreien, SSMS-kompatiblen
`.regsrvr`-Export für den SSMS-Import. SSMS verlangt
das SQL-Login-Passwort beim ersten Verbinden. Das entspricht dem Standardverhalten von
SSMS-Exporten ohne gespeicherte Kennwörter.

`[2]` erklärt bewusst den sicheren Importweg. SQL Server Lab verändert lokale,
versionsabhängige `RegSrvr.xml`-Dateien nicht direkt, weil diese bei unterschiedlichen
SSMS-Versionen nicht stabil genug serialisiert werden können. Der Export aus `[3]` wird
in SSMS unter **Ansicht -> Registrierte Server -> Aufgaben -> Importieren** importiert;
vorhandene Servergruppen bleiben dabei unverändert.

## CMS

`[4]` verwaltet einen optionalen CMS. Ohne vorhandenen CMS kann dort nach ausdrücklicher
Bestätigung eine kompakte, persistente SQL-2025-Instanz mit Docker oder Podman angelegt
werden. Das SA-Passwort wird einmalig angezeigt und anschließend nur run-lokal DPAPI-
geschützt gespeichert. Jede Lifecycle-Aktion der Konsole synchronisiert diesen CMS
best-effort mit dem aktuellen Katalog.

Empfohlener Ablauf:

1. `Datenbanken und Verbindungen` → `Verbindungszentrale und SSMS-Endpunkte`
   → `CMS verwalten und synchronisieren` öffnen.
2. `Kompakten persistenten CMS automatisch erstellen` wählen. Docker wird
   bevorzugt, Podman ist der Fallback.
3. Das einmalig angezeigte CMS-SA-Passwort sicher ablegen.
4. `CMS jetzt synchronisieren` ausführen.
5. `CMS-Zugang anzeigen` öffnen und Serverziel sowie Zugang kontrollieren.

Die geschützten Mitglieder der automatisierten Testgruppe sind keine
zulässigen CMS-Kandidaten. Alternativ darf nur ein anderer geeigneter
bestehender Run über `Bestehende SQL-Umgebung als CMS verwenden` übernommen
werden.

Der verwaltete CMS wird stets mit `autostart=on` erstellt. Bei Docker/Podman
greifen Restart-Policy und Hostkoordinator; unter Windows ist er nach der ersten
Anmeldung des einrichtenden Benutzers verfügbar. So bleibt die zentrale Instanz
nicht versehentlich wegen einer ausgeschalteten Podman Machine oder eines nicht
gestarteten Docker Desktop stehen.

Die Ausgabeaktionen der Verbindungszentrale – Status, SSMS-Importhinweis,
Export, Gruppenkonfiguration, Synchronisation und Vorschau – bleiben sichtbar,
bis sie mit **Enter** oder **Escape** geschlossen werden.

Sobald ein CMS eingerichtet ist, führt jede erfolgreiche Konsolen-Lifecycle-Aktion die
CMS-Synchronisation automatisch aus, einschließlich des Hyper-V-Unterworkflows. `[6]`
dient nur zum manuellen Nachholen oder zur Diagnose. Schlägt die automatische
Synchronisation fehl, zeigt die Konsole eine sichtbare Warnung mit dem Wiederholungsweg an.
Wer Lifecycle-Cmdlets außerhalb der Konsole direkt aufruft oder State aus einem älteren
Lauf übernimmt, führt anschließend `Sync-SqlServerLabCms` aus. Die CMS-Anzahl ist der
Stand des letzten erfolgreichen Abgleichs und kein Live-Zähler des Lab-Menüs.

### Welche Umgebungen in den CMS gehören

Das Lab-Menü zählt verwaltete Runs und Workflows. Der CMS zählt dagegen nutzbare
SQL-Endpunkte. Registriert werden aktive, nicht entfernte Runs, für die eine lesbare
`connection-info.json` und ein vollständiges Serverziel vorhanden sind. Dabei gilt:

- Ein laufender Endpunkt erscheint unter `Running`.
- Ein gestoppter Endpunkt mit weiterhin gültigem Serverziel erscheint unter `Stopped`.
- Provisionierungs- und Slot-Platzhalter ohne fertigen SQL-Endpunkt erscheinen nicht.
- Entfernte oder bereinigte Runs, unlesbare Verbindungsdaten und Einträge ohne Hostziel
  erscheinen nicht.
- Der CMS selbst erscheint nie als Mitglied seines eigenen Unterbaums.
- Die geschützte automatisierte Testgruppe wird nur vollständig veröffentlicht: Solange
  nicht alle registrierten Ziele `READY` sind, erscheint keines ihrer Mitglieder als
  vermeintlich vollständige Testgruppe.

Darum kann ein Lab-Menü beispielsweise 27 verwaltete Umgebungen kennen, während der CMS
nur die tatsächlich verbindbaren SQL-Endpunkte zeigt. Ein nachträglich fertiggestellter
Endpunkt wird beim nächsten erfolgreichen Abgleich ergänzt; reine Hyper-V-Slots oder
Legacy-Provisionierungsläufe ohne Verbindung bleiben absichtlich ausgeschlossen.

Die CMS-Einträge erscheinen in SSMS nicht im normalen **Objekt-Explorer** und auch
nicht unter **Lokale Servergruppen**. Der verwaltete CMS muss einmal unter
**Ansicht -> Registrierte Server -> Datenbankmodul -> Zentrale Verwaltungsserver**
mit dem im CMS-Menü angezeigten Serverziel registriert werden. Danach den Knoten
aktualisieren und beispielsweise **SQL Server Lab (8) -> Running (3)** aufklappen;
darunter folgen optional die nichtleeren Providergruppen wie `DOCKER (1)` und
`HYPERV (2)`. Root-, Status- und Providergruppen zeigen bei jedem Abgleich die
Anzahl aller jeweils darunterliegenden Umgebungen. Das CMS-Menü zeigt dafür den
konkreten Servernamen. CMS-Mitglieder speichern selbst keine Anmeldung: Microsoft
beschränkt deren [zentrale Registrierung](https://learn.microsoft.com/en-us/ssms/register-servers/create-a-new-registered-server-sql-server-management-studio)
auf Servername, sichtbaren Namen und Beschreibung. Nur die einmalige lokale
Verbindung von SSMS zum CMS kann ein von SSMS verschlüsselt gespeichertes Kennwort
verwenden.

Das Serverziel eines Mitglieds wird immer aus Sicht des SSMS-Clients gespeichert.
Läuft SSMS auf demselben Windows-Host wie Docker oder Podman, bleibt ein veröffentlichter
Loopback-Endpunkt daher beispielsweise `127.0.0.1,15433`. Der Provider des CMS ändert
dieses Ziel nicht in `host.docker.internal` oder `host.containers.internal`: Diese Namen
sind für Zugriffe *aus* einem Container gedacht, während SSMS die Mitgliedsverbindung
selbst auf dem Host öffnet.

Das CMS-Menü bietet zusätzlich **Generiertes Passwort im CMS-Namen anzeigen**.
Der sichere Standard ist **Aus**. Nach ausdrücklicher Klartextwarnung kann die
Option aktiviert werden; dann erhält jede Umgebung einen eigenen Unterordner.
Der darin liegende Serverknoten heißt ausschließlich wie das generierte Kennwort:

```text
DOCKER (1)
└─ Demo (primary)
   └─ GeneriertesPasswort
```

SSMS kopiert mit **Strg+C** stets den vollständigen Namen eines Baumknotens und
ignoriert eine optisch markierte Teilzeichenfolge. Weil der Serverknoten nur aus
dem Kennwort besteht, ist sein vollständig kopierter Wert unmittelbar im
Verbindungsdialog einsetzbar.
Ausschließlich Kennwörter, deren Herkunft
das Framework als selbst erzeugt nachweist, werden ergänzt. Manuell eingegebene,
manifestbasierte und über Lizenzprofile bereitgestellte Geheimnisse erscheinen
niemals im Namen. Für diese Einträge heißt der Serverknoten stattdessen
`MANUELLES PASSWORT EINGEBEN`; das selbst vergebene Kennwort muss der Benutzer
kennen und manuell eingeben. Die Option erleichtert den bewussten Zugriff auf kurzlebige
Testumgebungen, macht das jeweilige Kennwort aber auch in SSMS, CMS-Backups,
Screenshots und für alle CMS-Leser sichtbar.

Bei automatisch erzeugten Containerumgebungen wird dieser Herkunftsnachweis als
getrennter, DPAPI-geschützter run-lokaler Secret-Alias gespeichert. Die
automatisierte Testgruppe und der interaktive Containerdialog verwenden diesen
Pfad. Wird im Containerdialog **Manuell eingeben** gewählt oder ein Kennwort über
ein Manifest beziehungsweise `-SaPassword` geliefert, entsteht dieser Nachweis
nicht und das Kennwort bleibt unabhängig von der Klartextoption aus dem CMS-Namen
ausgeschlossen.

Bei der einmaligen CMS-Registrierung in SSMS ist SQL-Authentifizierung mit
Login `sa` und dem gesicherten CMS-Passwort zulässig. Microsoft dokumentiert
diesen Weg unter
[Create a central management server and server group](https://learn.microsoft.com/en-us/ssms/register-servers/create-a-central-management-server-and-server-group).
Für SSMS 22 wird der lokale Eintrag wie folgt gespeichert:

1. Das im CMS-Menü angezeigte **CMS-Serverziel** eintragen.
2. **SQL Server Authentication**, Login `sa` und das dort angezeigte
   **CMS-SA-Passwort** verwenden.
3. **Encrypt = Mandatory** und **Trust Server Certificate** aktivieren.
4. **Remember password** aktivieren, **Test Connection** ausführen und den Eintrag
   anschließend mit **Save** beziehungsweise **OK** speichern.

Das CMS-SA-Passwort öffnet nur den Knoten `CMS-Docker` oder `CMS-Podman`. Für ein
Mitglied wird dessen eigenes, beim jeweiligen Neuaufbau neu erzeugtes SA-Passwort
benötigt. Ist die Klartextoption aktiviert, den Serverknoten unter dem betreffenden
Umgebungsordner markieren, mit **Strg+C** vollständig kopieren und den Wert in den
von SSMS geöffneten Verbindungsdialog übernehmen.

Ein Doppelklick auf ein CMS-Mitglied öffnet den SSMS-Verbindungsdialog zunächst mit
**Windows Authentication**, weil die zentrale Mitgliedsregistrierung weder
Authentifizierungsart noch SQL-Anmeldedaten speichert. Bei einem Linux-Container
führt der unmittelbare Verbindungsversuch deshalb typischerweise zu SQL-Fehler 18452.
Danach **SQL Server Authentication** und Login `sa` wählen. Als Passwort darf nur der
vollständige Name des untergeordneten Kennwort-Serverknotens eingefügt werden. Nicht
den übergeordneten Umgebungsordner kopieren. Bei einem Eintrag namens
`MANUELLES PASSWORT EINGEBEN` muss das selbst vergebene Kennwort verwendet werden.

Erscheint direkt nach einem SSMS-Neustart beim Öffnen des CMS-Knotens
`Object reference not set to an instance of an object
(Microsoft.SqlServer.Management.UnifiedConnectionDialog)`, ist der lokale SSMS-Eintrag
unvollständig oder widersprüchlich gespeichert. Ein erfolgreicher **Test Connection**
kann die Verbindung nur für die laufende Sitzung zwischenspeichern. Deshalb die
Eigenschaften erneut öffnen und die vier obigen Schritte einschließlich **Remember
password** und abschließendem Speichern ausführen. Bleibt der Fehler bestehen, nur den
lokalen CMS-Eintrag löschen und mit denselben Werten neu anlegen; der CMS-Server und
seine Gruppen werden dadurch nicht gelöscht.

Der CMS selbst wird nicht als verwaltetes Ziel in seinen eigenen Unterbaum
eingetragen. Bei sechs fertigen Testumgebungen meldet der CMS-Abgleich daher sechs
Endpunkte, auch wenn die lokale Verbindungszentrale zusätzlich den CMS-Run anzeigt.

Der CMS wird immer mit einem automatisch erzeugten SA-Passwort erstellt. Er ist bewusst
nicht in **Umgebungen verwalten -> Status** gelistet, weil er als geschützter Systemdienst
behandelt wird. Den Zugang zeigt die CLI unter **Datenbanken und Verbindungen ->
SQL-Verbindungszentrale -> CMS verwalten und synchronisieren -> CMS-Zugang anzeigen**.
Dort erscheinen Connection String und Passwort nur in dieser ausdrücklich geöffneten
Ansicht und bleiben bis **Enter** oder **Escape** lesbar. Voraussetzung ist, dass der lokale
DPAPI-Schlüssel den Run entschlüsseln kann. Manuell eingegebene oder manifestbasierte
Kennwörter bleiben immer maskiert.

Alternativ schreibt die Exportaktion unter `Lab_Data/Exports` ein idempotentes
`sql-server-lab-cms-sync.sql`. Das Skript nutzt die dokumentierten
`msdb.dbo.sp_sysmanagement_*`-Prozeduren und gleicht den vollständig durch SQL Server Lab
verwalteten CMS-Unterbaum mit dem Framework-State ab. Es legt Einträge an, verschiebt sie
zwischen `Running` und `Stopped` und entfernt veraltete Einträge nur, wenn der zugehörige
Provider lokal sicher geprüft werden kann. Das exportierte Skript enthält auch
bei aktivierter Namensanzeige keine Kennwörter und verwendet deshalb normale
Anzeigenamen. Der direkte CMS-Abgleich erzeugt den kennworthaltigen Plan
ausschließlich im Arbeitsspeicher, führt ihn unmittelbar aus und verwirft den
Klartext danach; es entsteht keine kennworthaltige Sync-Datei.

## Gruppen

`[5]` ändert den Namen der verwalteten SSMS-/CMS-Wurzelgruppe. In der CMS-Verwaltung kann
die sichtbare Hierarchie zusätzlich unabhängig konfiguriert werden: eigener Root-Ordner
ein oder aus sowie Provider-Ordner unter `Running` und `Stopped` ein oder aus. Damit sind
vier Layouts möglich, einschließlich der flachsten Variante mit Umgebungen direkt unter
`Running` und `Stopped`. Sichtbare Gruppennamen erhalten automatisch einen aktuellen
Anzahlzusatz; der gespeicherte logische Root-Name bleibt davon unberührt. Leere
Providergruppen werden nicht angezeigt. Bei aktivierter Klartextoption kommt unabhängig
vom gewählten Layout je Ziel genau ein Umgebungsordner hinzu, unter dem der direkt
kopierbare Kennwort- beziehungsweise manuelle Eingabe-Serverknoten liegt. Der Name des
CMS-Knotens selbst bleibt eine lokale SSMS-Eigenschaft.
