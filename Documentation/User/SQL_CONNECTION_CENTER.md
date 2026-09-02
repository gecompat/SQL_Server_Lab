# SQL-Verbindungszentrale

Die SQL-Verbindungszentrale ist über `Invoke-SqlServerLab.ps1` mit `[k]` erreichbar.
Sie ist der zentrale, providerübergreifende Katalog aller bekannten SQL-Endpunkte aus
Docker, Podman und Hyper-V. Einträge werden bei den üblichen Konsolen-Lifecycle-Aktionen
automatisch aktualisiert und können jederzeit mit `[6] Jetzt synchronisieren` neu erzeugt
werden.

Der Katalog liegt im State Root unter `catalog/sql-connection-center.json`. Er enthält
Endpunkt, Anzeigename, Provider und aktuellen Runtime-Status, aber ausdrücklich keine
Kennwörter oder Connection Strings mit Kennwort.

Der Katalog ist interne Zustandsverwaltung. Sichtbare Exporte werden davon getrennt
unter `Lab_Data/Exports` abgelegt. Ist kein Data Root konfiguriert, verwendet SQL Server
Lab als Rückfall den State Root unter `exports`.

## SSMS

`[3]` erzeugt unter `Lab_Data/Exports/sql-server-lab.regsrvr` einen kennwortfreien,
SSMS-kompatiblen `.regsrvr`-Export für den SSMS-Import. SSMS verlangt
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

Der verwaltete CMS wird stets mit `autostart=on` erstellt. Bei Docker/Podman
greifen Restart-Policy und Hostkoordinator; unter Windows ist er nach der ersten
Anmeldung des einrichtenden Benutzers verfügbar. So bleibt die zentrale Instanz
nicht versehentlich wegen einer ausgeschalteten Podman Machine oder eines nicht
gestarteten Docker Desktop stehen.

Sobald ein CMS eingerichtet ist, führt jede erfolgreiche Konsolen-Lifecycle-Aktion die
CMS-Synchronisation automatisch aus, einschließlich des Hyper-V-Unterworkflows. `[6]`
dient nur zum manuellen Nachholen oder zur Diagnose. Schlägt die automatische
Synchronisation fehl, zeigt die Konsole eine sichtbare Warnung mit dem Wiederholungsweg an.

Die CMS-Einträge erscheinen in SSMS nicht im normalen **Objekt-Explorer** und auch
nicht unter **Lokale Servergruppen**. Der verwaltete CMS muss einmal unter
**Ansicht -> Registrierte Server -> Datenbankmodul -> Zentrale Verwaltungsserver**
mit dem im CMS-Menü angezeigten Serverziel registriert werden. Danach den Knoten
aktualisieren und **SQL Server Lab -> Running** aufklappen; darunter folgen optional
die Providergruppen `DOCKER`, `PODMAN` und `HYPERV`. Das CMS-Menü zeigt dafür den
konkreten Servernamen. Zugangsdaten bleiben im geschützten Run-Secret und werden
nicht in den CMS-Registrierungen gespeichert.

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

Alternativ schreibt `[4]` unter `Lab_Data/Exports` ein idempotentes
`sql-server-lab-cms-sync.sql`. Das Skript nutzt die dokumentierten
`msdb.dbo.sp_sysmanagement_*`-Prozeduren und gleicht den vollständig durch SQL Server Lab
verwalteten CMS-Unterbaum mit dem Framework-State ab. Es legt Einträge an, verschiebt sie
zwischen `Running` und `Stopped` und entfernt veraltete Einträge nur, wenn der zugehörige
Provider lokal sicher geprüft werden kann. Das Skript enthält keine Kennwörter.

## Gruppen

`[5]` ändert den Namen der verwalteten SSMS-/CMS-Wurzelgruppe. In der CMS-Verwaltung kann
die sichtbare Hierarchie zusätzlich unabhängig konfiguriert werden: eigener Root-Ordner
ein oder aus sowie Provider-Ordner unter `Running` und `Stopped` ein oder aus. Damit sind
vier Layouts möglich, einschließlich der flachsten Variante mit Umgebungen direkt unter
`Running` und `Stopped`. Der Name des CMS-Knotens selbst bleibt eine lokale SSMS-Eigenschaft.
