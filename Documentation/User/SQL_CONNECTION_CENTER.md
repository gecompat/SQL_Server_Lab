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

Sobald ein CMS eingerichtet ist, führt jede erfolgreiche Konsolen-Lifecycle-Aktion die
CMS-Synchronisation automatisch aus, einschließlich des Hyper-V-Unterworkflows. `[6]`
dient nur zum manuellen Nachholen oder zur Diagnose. Schlägt die automatische
Synchronisation fehl, zeigt die Konsole eine sichtbare Warnung mit dem Wiederholungsweg an.

Der CMS wird immer mit einem automatisch erzeugten SA-Passwort erstellt. Daher zeigt die
Konsolenübersicht dessen Connection String einschließlich Passwort erneut im Klartext an,
solange der lokale DPAPI-Schlüssel den Run entschlüsseln kann. Manuell eingegebene oder
manifestbasierte Kennwörter bleiben immer maskiert.

Alternativ schreibt `[4]` unter `Lab_Data/Exports` ein idempotentes
`sql-server-lab-cms-sync.sql`. Das Skript nutzt
die dokumentierten `msdb.dbo.sp_sysmanagement_*`-Prozeduren, legt Gruppen an und ergänzt
fehlende Registered Servers in einem vorhandenen Central Management Server. Es löscht keine
CMS-Einträge und enthält keine Kennwörter.

## Gruppen

`[5]` ändert den Namen der verwalteten Wurzelgruppe. Für maximale Kompatibilität mit dem
SSMS-Import liegen die Server direkt darunter; der Provider steht im Anzeigenamen, etwa
`[DOCKER] mein-lab (primary)`.
