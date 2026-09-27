# CSharp-Nativabnahme auf Windows und SQL Server 2025

Status: interner opt-in Testpfad; native Ausführung noch `NOT_EXECUTED`.
Die Katalogvariante bleibt `PREVIEW`. Offline-Build, Paketintegrität und
synthetische Runnerprüfungen sind keine SQL-/Launchpad-Freigabe.

## Einstieg und Eingaben

Der manuelle Workflow `.github/workflows/csharp-native-acceptance.yml` läuft
nur auf `main` des Ursprungsrepositorys mit exakt dem ausgelösten Commit.
Ein bereits erhöhter self-hosted Windows-Runner mit `SQL_Lab` und `Hyper-V`
ist erforderlich. Der Einstieg fordert keine UAC an. Fehlen Rechte,
Clientvoraussetzungen, registrierte Medien oder Ressourcen, bleibt die native
Abnahme offen; die Ursache und ihre Wiederaufnahmebedingung sind festzuhalten.

Benötigt werden ein explizites geprüftes Windows-Server-2025-`OS_SEALED`-
Artifact, hashregistrierte SQL-2025-Installationsmedien und ein lokaler
Payloadroot mit `extension.zip`, `runtime.zip` und
`SqlServerLab.CSharpProbe.dll`. Extension und Probe benötigen unabhängig
geprüfte SHA256-Werte. `runtime.zip` ist das im
[Offline-Build](CSHARP_OFFLINE_BUILD.md) gesperrte Microsoft-.NET-8.0.31-x64-
Archiv. Der Caller verwendet die dort gebauten Artefakte. Der Runner lädt
nichts herunter und übernimmt keine vorhandene VM oder Clone-Quelle.
Die automatische Windows-Evaluationsaktivierung des eigenen Gastes verwendet
vorübergehend den bestehenden Aktivierungsnetzwerkpfad.

## Ablauf und Grenzen

Der Supervisor prüft den Checkout und die lokalen Eingaben, kopiert sie in
einen neuen eigenen Stagingroot und prüft die Kopien erneut. Der Kindprozess
hält den gemeinsamen Runtime-Mutex, prüft Artifact, SQL-Medien und die aktuelle
Ressourcenreserve und erstellt einen operationseigenen Gast mit 16 GiB festem
RAM. SQL 2025 wird mit `SQLENGINE`, `FULLTEXT`, `REPLICATION` und
`ADVANCEDANALYTICS` installiert. Bereits gestoppte Testumgebungen werden dafür
nicht gestartet oder verändert.

Die Dateiübertragung aktiviert ausschließlich auf der gebundenen VM den
Guest Service Interface. Im Gast werden Extension, Runtime, Probe und der
SQL-Prüftext vor Verwendung erneut gegen die erwarteten Hashes geprüft.
Die lokale Runtime und ihre AppContainer-Leserechte, `DOTNET_ROOT`, externe
Skripte und das SQL-Speicherlimit von 12 GiB werden nur im eigenen Gast gesetzt.
Ein Kaltstart übernimmt die Umgebung vor Registrierung der Sprache `dotnet`.

Die eigene Datenbank `CSharpAcceptance` muss neu sein. Die Probe verlangt die
exakten Wertepaare `-7/-14`, `0/0`, `21/42`, .NET 8, einen AppContainer-Worker
und eine positive Worker-Prozess-ID. Sie läuft vor und nach einem weiteren
VM-Neustart. Der zweite Nachweis verlangt dieselbe VM-ID, SQL-Major 17 und
eine gestiegene Bootzeit. Das sind Abnahmeanforderungen, bislang keine
beobachteten nativen Ergebnisse.

Der Kindprozess ist auf 120 Minuten begrenzt; danach beendet der Supervisor
den Prozessbaum und prüft die Terminierung. Er erwirbt erst anschließend den
Runtime-Mutex für Cleanup. Eine nicht bestätigte Terminierung sperrt Cleanup
und meldet `RECOVERY_REQUIRED`. Die äußere CI-Grenze beträgt 180 Minuten.
Der Supervisor findet auch nach einem verlorenen Erstellungsrückgabewert nur
den eigenen Run über seine Operation wieder. Er prüft Cleanupplan,
Run-/Scope-/VM-Bindung und entfernt ausschließlich diesen Run. Verbleibende
VMs, VHDX-Dateien, IPAM-Leases oder ein fehlgeschlagener Cleanup verhindern
`PASSED`. Ein sehr früher Fehler vor einem VM-Cleanupschritt bleibt ebenfalls
bereinigbar. Manueller Workflowabbruch oder Hostausfall bleiben Recoveryfälle.

Rohlogs, lokale Pfade, Gastwerte und Plan bleiben unter ignorierten lokalen
Testartefakten. GitHub erhält keine Uploads dieser Dateien. Das kleine Receipt
trennt Hauptfehler und Cleanupfehler. Es bestätigt nur diesen internen
Referenztest; allgemeine Installation, Reconcile, andere Windows-/SQL-Versionen,
Ressourcen-Governance und Katalogpromotion bleiben separate Aufgaben.

## Validierung

`Invoke-ExternalRuntimeWindowsChecks.ps1` führt die synthetischen Verträge aus:
Main-/Repository-/SHA-Guards, Hash- und Größenabwehr, echter Kindprozess mit
Exitcode/Logprüfung, echter Timeout, partielle Erstellung ohne Connection-Info,
fremde Ownership, frühes Cleanup ohne VM-Schritt, Cleanupfehler, mutable
Gastcredentials, fehlender/deaktivierter Dateikopierdienst und Gastkopie-Hashdrift.
Die CI-Auswahl bindet die neuen Dateien an diese Suite. Ein nativer Durchlauf
und seine bestätigte Ressourcenbereinigung stehen noch aus.
