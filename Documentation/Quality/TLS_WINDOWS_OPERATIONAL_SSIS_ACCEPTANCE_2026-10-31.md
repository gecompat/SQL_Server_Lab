# Eigener Windows-TLS-Run für die SSIS-Abnahme

Datum: 2026-10-31. Scope: Windows/Hyper-V, SQL Server 2025 RTM
(`17.0.1000.7`), eigener vorbereiteter Run, registrierter Windows-Client.
Der Benutzer gab die Windows-TLS-Erweiterung und die anschließende
Toolbelt-Qualifikation ausdrücklich frei. Keine Veröffentlichung.

## Ausgeführt und Ergebnis

Der [Windowsvertrag](../Architecture/AUTHENTICATED_TLS_WINDOWS_OPERATIONAL_LAB.md)
wurde als komponierter nativer Pfad ausgeführt. Zwei eigene VMs entstanden:
Der erste Aufbau scheiterte am nicht erhöhten Offline-VHDX-Mount und wurde
gebunden entfernt und frisch auditiert. Der zweite Aufbau erreichte OOBE,
scheiterte aber am unpassenden Aktivierungsintent `ExistingOnly`.
Der Fehler bleibt erhalten. Derselbe eigene Run wurde über die vorhandenen
Funktionen für Windows-Aktivierung und SQL-CompleteImage fortgesetzt.

`EvaluationOnline`/`AllowTemporary` verwendete einen vorhandenen External-Switch
und eine ausschließlich eigene temporäre NIC. Aktivierung wurde live bestätigt,
das Netzwerkjournal endete `CLEANED`. Ein zusätzlicher UAC-Start kam nicht
zustande; die verbleibenden Schritte liefen nach einer erfolgreichen lesenden
PowerShell-Direct-Probe mit den vorhandenen Hyper-V-Rechten. Der Offline-Mount
war zu diesem Zeitpunkt bereits abgeschlossen. SQL-CompleteImage verwendete
`RequireExistingNetwork`; gemeinsame Hostnetze wurden nicht eingerichtet.

Der gemeinsame Windows-TLS-Abschluss erzeugte einen eigenen nicht exportierbaren
RSA3072-CSP-Schlüssel im Gast, signierte dessen CSR mit der bestehenden CA,
band das Leaf an den eigenen SQL-Dienst und prüfte VM, Boot, SQL-Prozess,
Zertifikat, Keyrechte und geladenes Zertifikat frisch. Acht echte strikte
Clientresultate entstanden in vier Paaren aus SqlClient und ODBC-sqlcmd:
Initialqualifikation, erster V2-Export, öffentliche Livequalifikation und
abschließender frischer V2-Export. Encrypt=True und TrustServerCertificate=False
blieben zwingend; kein Hosttrust wurde importiert.

Der öffentliche Reader prüfte Exportpfad und erneut dieselben Bytes. Toolbelt
prüfte den aktuellen SSIS-Build in local/central mit CL170 und 412 Assertions.
Jede der drei Zielverbindungen und die unabhängige Auditverbindung verwendeten
denselben frisch geprüften signierten Snapshot, ohne Pooling oder Retry.
Ein erster Consumer bestand bereits seine 412 Assertions, scheiterte aber am
Konfigurations-Restore des Toolbelt-Testadapters. Dessen eigene gebundene Recovery
und ein erneuter unabhängiger Audit bestanden; der korrigierte Consumer endete
anschließend vollständig `PASS_CLEANED`. Ursprüngliche Fehler bleiben erhalten.

Nach nachgewiesenem SQL-Consumerende entfernte `Remove-SqlServerLab` genau den
eigenen Run. Frisch geprüft: eigene VM abwesend, zuvor vorhandene VMs unverändert,
CurrentUser/Root-Trust unverändert. Beide tatsächlich erzeugten eigenen VMs
sind entfernt. Private IDs, Endpoints, Secrets, Zertifikate und Rohlogs bleiben
außerhalb von Git. Die aggregierte
[Toolbelt-Evidence](https://github.com/gecompat/SQL_Server_Toolbelt/blob/main/Modules/toolbelt.tsql.ssis-debug/Tests/Qualification/Current.AuthenticatedTls.Windows.20261031.json)
enthält ausschließlich statische Quellpins und bereinigte Ergebnisse.
Labpins beziehen sich auf die tatsächlich ausgeführten Windows-Arbeitsbaumbytes
mit CRLF, nicht auf normalisierte Git-Blobs.

## Statische und vertragliche Prüfung

- `Invoke-AuthenticatedTlsWindowsChecks.ps1`: 46 PASS, echte eigene
  RSA-/Signatur-/Export-/Readerfixtures und synthetische native Grenzen.
- `Invoke-ImpactedChecks.ps1 -Development` für den vollständigen Änderungsumfang:
  32 Suites PASS, einschließlich ScriptAnalyzer, Export-/Reader-/Live- und
  bestehender Containerregressionen. Statische Tests ersetzen keinen SQL-Nachweis.
- Die Manipulationsfälle prüfen geschlossene Windowsformen, VM-/Boot-/Prozess-,
  Profil-, Frist-, Trust- und Eintragsbindung sowie unbekanntes Gastende und
  Erstellungsablehnung vor Effekten bei fehlender Erhöhung.

## Grenzen und Aufwand

Ein ununterbrochener öffentlicher `New-SqlServerLab`-Neuaufbau mit dem korrigierten
Aktivierungsintent wurde nicht erneut ausgeführt. Die Manifestwahl ist offline
geprüft; der native Nachweis verwendet die gebundene Fortsetzung desselben Runs
und den gemeinsamen TLS-Abschluss. Weitere Windows-/SQL-Versionen, native
Zertifikat-Negativmatrix, Renewal/Rebind, Browsererstellung und der gesamte
TLS-001-Abschluss sind damit nicht qualifiziert. Ein Wire-Fingerprint ist
`NOT_OBSERVED`.

Ein Implementierungsverantwortlicher, keine zusätzlichen Agents, zwei gekoppelte
PRs. Der neue statische Test läuft im vorhandenen Selektor; keine neuen CI-Jobs.
Die Änderung am gemeinsamen Erstellungs-/Selektorpfad fordert dessen bestehende
Provider-Smokes an. Unveränderte erfolgreiche Suites werden nur bei aktueller
Quellbindung wiederverwendet. Native Logs werden lokal dedupliziert; kein
zusätzlicher Bericht-Review-Zyklus und keine pauschale neue Versionsmatrix.
