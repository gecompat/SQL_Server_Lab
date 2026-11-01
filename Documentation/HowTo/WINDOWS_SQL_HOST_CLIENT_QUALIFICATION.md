# Nativer Windows-SQL-Qualifikationsclient auf dem Host

`Invoke-SqlServerLabScript -WindowsAuthentication` führt SQL im gebundenen
Windows-Gast aus. Ein vollständiger Installer oder SSMS auf dem Host benötigt
einen eigenen Clientprozess. Der native Testhelper
[`Start-WindowsSqlHostClient.ps1`](../../Tests/Integration/Start-WindowsSqlHostClient.ps1)
startet dafür einen explizit quellgebundenen PowerShell-Client mit der vorhandenen
geschützten Windows-Anmeldung des ausgewählten SQL-Runs.

Dies ist ein Qualifikationswerkzeug, keine zusätzliche öffentliche Lab-API
und keine allgemeine Nicht-SQL-Ausführungsplattform. Es verändert weder
Labressourcen noch Rechte, Zertifikate, Truststores oder Konfiguration.

## Voraussetzungen und Ablauf

- Laufender gebundener Windows-SQL-Hyper-V-Run und vorhandener geschützter
  Gastadministratorzugang; die bestehende SSIS-Prerequisite-Bindung prüft die VM.
- Vorhandene Microsoft-signierte lokale `pwsh.exe`, im Helper mit kanonischen
  UTF8/LF-Textbytes gepinnter
  Worker und ausdrücklich freigegebener
  vertrauenswürdiger SQL-Testcode. `ExpectedScriptSha256` bindet dessen Datei.
- Ein neuer eigener privater `OutputDirectory`; bestehende Verzeichnisse sperren
  einen Replay. Argumente enthalten keine Kennwörter oder anderen Secrets.

Der Helper prüft Quellen und `ShouldProcess`, liest den tatsächlichen Computernamen
über die vorhandene gebundene PowerShell-Direct-Verbindung ohne Retry und prüft
die Bindung erneut. Erst danach erzeugt Windows eine flüchtige reine
Netzwerkanmeldesitzung für den eigenen Hostclient. Das Kennwort wird weder
zurückgegeben noch in Argumente oder Dateien geschrieben; der kurzlebige
unmanaged Puffer wird in `finally` freigegeben. Es wird kein `/savecred` verwendet.

```powershell
./Tests/Integration/Start-WindowsSqlHostClient.ps1 `
    -LabModuleFile $cleanLabModuleFile -ExpectedLabCommit $approvedLabCommit -RunId $ownWindowsSqlRun `
    -ScriptPath $approvedSqlClientScript -ExpectedScriptSha256 $approvedScriptHash `
    -ScriptArguments $credentialFreeArguments -OutputDirectory $ownPrivateDirectory
```

`STARTED_AUTHENTICATION_UNCONFIRMED` belegt nur den Prozessstart. Die
Qualifikation muss tatsächliche SQL-Windows-Authentifizierung, Zielidentität,
Ergebnis und eigenen Cleanup getrennt nachweisen. `process.private.json` enthält
den Exitcode des separaten Clients, keine pauschale Funktionsabnahme. Private
Clientausgaben bleiben im eigenen Verzeichnis und werden nicht hochgeladen.
Nach unbekanntem Ausgang oder Drift wird kein Client automatisch erneut gestartet.

## Grenzen und Prüfung

Es werden keine interaktiven Anmeldedialoge bedient. Für sichtbare SSMS-Proben
öffnet der vertrauenswürdige Client eine eigene Instanz; der verantwortliche
Test führt GUI-Beobachtung, Timeout und Cleanup. Bestehende Benutzerfenster
gehören nicht zum eigenen Scope. Der Helper ist kein Sandboxersatz für fremden Code.

[`Invoke-WindowsSqlHostClientChecks.ps1`](../../Tests/Static/Invoke-WindowsSqlHostClientChecks.ps1)
prüft den Secret-/Binding-/Replayvertrag sowie echte separate Worker mit
synthetischen Unicodeargumenten und geänderter Eingabedatei ohne VM-/Credentialzugriff.
Der native SSIS-Consumerlauf ergänzt seine tatsächlichen Ergebnisse separat;
ein statischer Erfolg behauptet keine Windows-Anmeldung.

## Native Consumerbeobachtung vom 2026-11-01

Der Helper startete einen tatsächlichen Toolbelt-SQL-Hostclient unter
der gebundenen vorhandenen Windows-Gastidentität. Dieser bestätigte NTLM und
bereits vorhandene sysadmin-Rechte und führte die erste öffentliche
Toolbelt-Installation erfolgreich aus. Der Consumerkoordinator scheiterte
anschließend vor seinem GUI-Start an einer datetime-Konvertierung in seiner
Trust-Zuordnung. Dieser Fehler ist keine fehlgeschlagene Windows-Anmeldung.

Ein separat quellgebundener Sicherheitslauf unter derselben Windowsidentität
bestätigte die eigene Ownership anhand Actor, typisiertem datetime2-Zeitfenster,
vorher fehlenden Hashes und fehlenden verbleibenden Verbrauchern. Genau die drei
eigenen Trusteinträge wurden entfernt. Ein weiterer frischer Windows-Prozess
bestätigte Datenbankabwesenheit sowie exakte Konfigurations-, Trust- und
Verbraucherbaselines. Das Consumerergebnis bleibt `FAILED_CLEANED` mit
Abschlussaudit PASS; ein vollständiger SSMS-/Installer-Gesamtpass wird daraus
nicht abgeleitet. Bestehende Labressourcen und Hosteinstellungen blieben erhalten.

Der danach ergänzte exakte Workerhash-Guard ist separat offline geprüft. Er
akzeptiert ausschließlich die erklärte CRLF→LF-/UTF8-Textdarstellung für
Git-Checkouts; jede andere Änderung der Quelle bleibt gesperrt. Er
ändert weder die tatsächlich verwendeten Workerbytes noch den Anmeldeweg;
ein weiterer nativer Gesamtlauf wird für diese zusätzliche Vorprüfung nicht
behauptet.
