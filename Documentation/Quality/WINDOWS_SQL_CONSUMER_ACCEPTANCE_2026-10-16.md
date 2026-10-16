# Native Windows-Abnahme des SQL-/SSIS-Consumerzugangs

| Merkmal | Ausgeführter Nachweis |
|---|---|
| Ergebnis | `PASSED`, lokal am bestehenden Run |
| Abschlusszeit der geheimnisfreien Receipt | 2026-10-16 18:50:12 UTC |
| Implementierung | [bbfce441](https://github.com/gecompat/SQL_Server_Lab/commit/bbfce441e1afbd7365a8eb275fe7675a05146bc8) |
| Integration | [PR #766](https://github.com/gecompat/SQL_Server_Lab/pull/766) |
| RunId / InstanceId | `53fbfd35-08bc-439a-baa1-680f13eb471e` / `primary` |
| SQL / Authentifizierung | Major 17, Windows, tatsächlich `NTLM` |
| Öffentlicher Einstieg für sämtliche SQL-Aufrufe | `Invoke-SqlServerLabScript -WindowsAuthentication` |
| Native Abnahme | `Tests/Integration/Invoke-WindowsSqlConsumerAcceptance.ps1` |
| Receiptvertrag | `SqlServerLab.WindowsSqlConsumerAcceptance/1.0` |
| SHA-256 der vollständigen geheimnisfreien lokalen Receipt | `02B6C5A8DEAA8D8B6B587F5B83A4C6B15167AF76481AB0E418402B5B834CBCC7` |

## Tatsächlich ausgeführte Operationen

Die Abnahme verwendete die vorhandene Gastanmeldung intern über denselben
PowerShell-Direct-Transport wie die bestehenden Lab-SSIS-Operationen. Ein neuer
SQL-Run, eine Installation, ein Dienst oder ein Kennwortexport waren dafür
nicht erforderlich. Der bestehende Skriptbefehl erhielt einen zusätzlichen
Parametersatz; die öffentliche Exportliste blieb unverändert.

| Prüfung | Beobachtet |
|---|---|
| Windows-Verbindung zur gebundenen Gastinstanz | `Authentication=Windows`, `AuthScheme=NTLM` |
| Eigene Ordneranlage mit `@folder_id OUTPUT` | FolderId `6` |
| Löschversuch mit absichtlich falscher FolderId | Fehlernummer `51000`; eigener Ordner blieb erhalten |
| Eigenes ISPAC über binären SQL-Parameter deployt | ProjectId `4`, ProjectVersion `4` |
| Eigenes Paket über Katalogprozeduren gestartet | ExecutionId `14`, terminaler Status `7` |
| Eigene Ergebnisse gelesen | `catalog.executions`, `catalog.event_messages` |
| Identitäts-/versionsgebundener eigener Cleanup | `OWN_PROJECT_AND_FOLDER_REMOVED`; aktive Abwesenheit bestätigt |
| Geschützte Ausführungen `10/11/12` und deren Ereignisse | Unveränderte Vorher-/Nachher-Hashes |
| Source-Receipt/-Operation, Run-State und Connection-Info | Unveränderte SHA-256-Werte |
| Bestehende aktive Ordner/Projekte/Umgebungen und Datenbankinventar | Vorher-/Nachher-Vergleich identisch |
| Globale Katalogeigenschaften | Vorher-/Nachher-Vergleich identisch |
| Erneuerung der Lab-Fixture / globale Konfigurationsmutationen | Jeweils `0` |

Das rein synthetische ISPAC verwendet den vorhandenen produktiven Writer.
Nur `Success.dtsx` wurde gestartet; die Abnahme entwickelt keine fachliche
Analyze-Legacyfixture. Für den Cleanup verwendet sie den vorhandenen
transaktionalen Folder-/Project-ID-/Versionsguard. Die Source-Fixture wurde
weder neu angelegt noch über ihre Cleanup-API entfernt.

Die zwölf öffentlichen SQL-Aufrufe besitzen eigene runlokale Operationsjournale.
SQL-Texte, ISPAC-Bytes, ausgewählte Daten, Endpunkte und Anmeldedaten wurden
nicht in diese Nachweisquelle übernommen. Der vollständige ursprüngliche
Receipt und die privaten Diagnosebelege verbleiben lokal außerhalb der
Versionskontrolle; der Hash oben bindet den geheimnisfreien Ergebnisrecord.

## Diagnose- und Aussagegrenzen

Die nativen Vorläufe deckten einen ungültigen Connection-Builder-Schlüssel und
die Deserialisierung binärer Parameter als `object[]` auf. Beide Fehler wurden
behoben und durch fokussierte Regressionen ergänzt. Die vorherigen eigenen
Ordner wurden jeweils entfernt; ihre Schutzvergleiche bestanden. Die ursprünglichen
Fehlerbelege bleiben lokal erhalten und werden nicht als erfolgreiche Läufe umgewertet.

35 fokussierte Offlineprüfungen bestanden. Die betroffenen statischen Suites
wurden ausgeführt; nach den nativen Korrekturen wurden die geänderten Einheiten
erneut geprüft. Die statische Analyse behielt ihre bestehende Fehlerbaseline.
Die Hostabweisung verwendet abschließend die bereits vorhandene
`Test-LabSsisWindowsHost`-Grenze, sodass die simulierte Windows-Komposition auch
unter Linux geprüft und ein Nicht-Windows-Host ausdrücklich abgewiesen wird.
Die echte Windows-Verbindung bestand danach erneut rein lesend mit NTLM.
Der Gast-SQL-Payload der vollständigen nativen Abnahme blieb dabei unverändert.

Diese Abnahme belegt den zusätzlichen Windows-Consumerweg am bezeichneten
Windows-/Hyper-V-/SQL-2025-Ziel. Andere SQL-/IS-Versionen, Least-Privilege-
Identitäten, große Produktivpakete, eine gerenderte Browserbedienung und
Hard-Crash-/Netzwerkfehler während des Deployments sind damit nicht abgenommen.
Der eigene Executionrecord und Projektversions-/Operationshistorie verbleiben
bis zur unveränderten Herstellerretention. Aktiver Projekt-/Ordnercleanup
behauptet keine sofortige Historienlöschung.

Der erste [manuell angeforderte GitHub-Lauf](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38947458220)
startete wegen des offline befindlichen registrierten Runners nicht und wurde
noch in der Warteschlange abgebrochen. Er bleibt **NOT_EXECUTED**. Die automatische
Freigabeprüfung blockierte den Start des vorhandenen Runners mit `blocked by policy`.
Nach dessen manuellem Start durch den Betreiber bestand die
[native GitHub-Abnahme](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38953413402)
am Stand `0dca94bf126c4d9680b13875409e6188b60dbd58` am 2026-10-16 um 19:28 UTC.
Sie führte denselben Harness einschließlich Deployment, Paketstart, eigenem
Cleanup und Schutzvergleichen am bestehenden Run aus.

Im [vorherigen PR-Gate](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38953095095)
bestanden Windows-Verträge und Hyper-V-Smoke. Die Linux-Vertragsprüfung fand
die fehlende Simulation der Windows-Hostgrenze; diese wurde wie oben beschrieben
behoben. Der Pflichtgate am jeweiligen aktuellen PR-Head ist eine getrennte
Integrationsaussage; sein laufender Status steht in [PR #766](https://github.com/gecompat/SQL_Server_Lab/pull/766).

## Consumeraufruf

Die [vollständige Anleitung für Analyze](../HowTo/SSIS_CONSUMER_WINDOWS_ACCESS.md)
enthält die lokalen Modul-/Runbindungen, SQL-Parameter, binäres Deployment,
Paketstart, Ergebnisabfrage, Ownership-Receipt und gezielten Cleanup ohne Secrets.
