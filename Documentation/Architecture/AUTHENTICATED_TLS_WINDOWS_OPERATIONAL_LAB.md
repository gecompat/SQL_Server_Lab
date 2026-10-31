# Authentifiziertes TLS für ein eigenes Windows-SQL-Lab

## Vertrag und Freigabe

Der Benutzer hat diesen zusätzlichen Labumfang am 2026-10-31 ausdrücklich
für die aktuelle SSIS-Qualifikation freigegeben. Der
[komponierte native Referenznachweis](../Quality/TLS_WINDOWS_OPERATIONAL_SSIS_ACCEPTANCE_2026-10-31.md)
bestand einschließlich Consumer und Cleanup. Ein ununterbrochener öffentlicher
Neuaufbau wurde nach der Aktivierungskorrektur nicht erneut ausgeführt.
Die bisherige private
[Hyper-V-Referenzabnahme](AUTHENTICATED_TLS_HYPERV_NATIVE_ACCEPTANCE.md)
bleibt an ihren ursprünglichen Run und ihre damaligen Bytes gebunden.

`New-SqlServerLab -Provider hyperv -Version 2025
-TrustServerCertificate:$false` erstellt ausschließlich einen neuen eigenen
Windows-/SQL-2025-RTM-Run aus einem regulär zulässigen vorbereiteten Image.
Die Erstellung verlangt einen bereits erhöhten Windows-Runner, da der
kanonische Offline-OOBE-Schritt die eigene Child-VHDX mountet. Fehlende
Erhöhung wird vor Registry-, Run- oder VM-Effekten abgelehnt; es gibt keinen
automatischen UAC-Start. Das intern erzeugte geheimnisfreie Manifest fixiert
die vorgeprüfte Image-ID und verwendet die regulären Windows-/Netzwerkdefaults.
Für die hostOnly-Testumgebung wird der vorhandene Aktivierungsvertrag
`EvaluationOnline`/`AllowTemporary` ausdrücklich ausgewählt. Die bestehende
Lab-Aktivierungsfunktion verwendet bei Bedarf einen bereits vorhandenen,
verbundenen External-Switch, bindet eine temporäre NIC ausschließlich an die
eigene VM und entfernt sie über ihren Run-/Scope-/VM-/Adapter-Journalvertrag.
Es wird kein neuer Hostswitch eingerichtet. `ExistingOnly` reicht für einen
hostOnly-Run ohne permanente Internetanbindung nicht aus.
Die vorhandenen CA-, Controller- und Locationreferenzen sind ausdrücklich
anzugeben. Ein bereits identisch vertrauter CA-DER in CurrentUser/Root ist
Voraussetzung; dieser Weg importiert keinen Hosttrust. Eine vorhandene VM
wird nicht übernommen und bestehende Testsysteme werden nicht umkonfiguriert.

Verwenden Sie die vorhandenen registrierten Referenzen in einer erhöhten
PowerShell 7.5. Die Funktion startet selbst keine UAC-Abfrage:

```powershell
$lab = New-SqlServerLab -Provider hyperv -Version 2025 `
    -TrustServerCertificate:$false -DataRoot $dataRoot `
    -TlsControllerId $controllerId -TlsLocationId $locationId `
    -TlsCandidateId $candidateId -TlsClientPlatform Windows -NonInteractive
```

Die Rückgabe enthält private Verbindungsinformationen. Nicht in ein öffentliches
Protokoll ausgeben. `TlsQualification.Status=QUALIFIED` bestätigt die während
dieses Aufrufs entstandenen beiden strikten Clientprüfungen, nicht eine
unbegrenzte Gültigkeit.

Der Gast erzeugt genau einen neuen nicht exportierbaren Machine-CSP-Schlüssel
mit RSA3072, SChannel-Provider12 und KeySpec1. Nur CSR und öffentlicher Leaf
verlassen die jeweilige lokale Schlüsselgrenze. Das Leaf enthält den exakt
beobachteten eigenen IPv4-Endpunkt. Der SQL-Dienst erhält Leserecht auf genau
diese eigene Keydatei. Zertifikatbindung und Force Encryption werden nur im
neuen Run gesetzt; anschließend wird dessen SQL-Dienst einmal neu gestartet.

Vor und nach den beiden echten strikten Verbindungen werden Run-/Scope-/VM-ID,
laufende VM, Gastidentität, Boot, SQL-Prozessstart, Port, Registrybindung,
Zertifikatbytes, nicht exportierbarer Key und aktuelle SQL-Lademeldung geprüft.
`System.Data.SqlClient` verwendet Encrypt=True und TrustServerCertificate=False
ohne Pooling oder Retry. ODBC-sqlcmd verwendet `-N` ohne `-C`; der tatsächlich
geladene ODBC-Treiber wird gebunden. Ein Wire-Zertifikatdigest wird nicht
behauptet. Neustart oder Drift macht den bisherigen Nachweis ungültig; eine
automatische Wiederbindung gibt es für diesen neuen Windowsweg nicht.

## Export und Verbraucher

Die neue geschlossene Windows-Recordform und ihre eigene Qualifikationsform
tragen VM-/Dienst-/Bootbindungen. Sie verwenden keine erfundenen Container-
oder Imagefelder. Alte Containerrecordformen bleiben unverändert begrenzt.

`Export-SqlServerLabTestEnvironment -TrustServerCertificate:$false` erzeugt
für den ausdrücklich ausgewählten eigenen Windows-Run einen neuen signierten
V2-Export. Er bindet den vollständigen Eintrag, registrierte Authority und
Clientgeneration sowie die frische Windowsqualifikation. Die Frist beträgt
höchstens 15 Minuten und endet spätestens mit dem Leaf. Der öffentliche Reader
prüft dieselben Bytes vor weiterer Nutzung im tatsächlichen Clientkontext.
Ein normaler Functional-Export wird dadurch nicht zur TLS-Evidence.

```powershell
$export = Export-SqlServerLabTestEnvironment -RunId $lab.RunId `
    -InstanceId primary -StateRoot $lab.StateRoot `
    -TrustServerCertificate:$false -OutputDirectory $newPrivateExportDirectory
$snapshot = Read-SqlServerLabQualifiedTestEnvironment -Path $export.JsonPath `
    -RunId $lab.RunId -InstanceId primary -StateRoot $lab.StateRoot
```

Der Consumer verwendet genau `ExportBytes` aus diesem Ergebnis und prüft sie
vor jeder weiteren Anmeldung erneut. Die vollständige Verbrauchergrenze steht
im [V2-Readervertrag](AUTHENTICATED_TLS_V2_READER.md).

Das exportierte JSON und ENV enthalten Credentials und bleiben in einer neuen
privaten CurrentUser-/SYSTEM-Ablage. Bestehende V1-Exporte, Discoveryvariablen
und die spezielle Container-Erstellungsoberfläche bleiben erhalten. Der
vollständige öffentliche Befehlszugang verwendet denselben Cmdletvertrag.

## Eigentum, Ende und Abnahme

Vor Erstellung stehen eigener Intent, Budget und Cleanupzuständigkeit fest.
Eine unbestätigte Gastoperation wird nicht automatisch wiederholt und löst
keinen blinden VM-Cleanup aus. Unklares Verbraucherende bleibt Recoverybedarf.
Ein bestätigter Fehler nach Rückkehr des eigenen Runs verwendet ausschließlich
den bestehenden öffentlichen Remove-Weg mit exakter Run-/VM-Bindung.
Wird der kanonische Aufbau vor seiner Rückgabe unterbrochen, bleibt die eigene
Ressource zur gebundenen Recovery erhalten. Die vorhandene Windows-Aktivierungs-
Fortsetzung und SQL-CompleteImage-Funktion werden verwendet. Der interne
TLS-Abschluss prüft den ursprünglichen privaten Erstellungsintent, Run, Scope,
VM und vorbereitete Image-ID; er ist kein öffentlicher Takeover-Einstieg.
Ein erfolgreicher Run bleibt für den ausdrücklich beauftragten Consumer
verfügbar und wird nach dessen Ende mit demselben öffentlichen Weg entfernt.
CA, bestehender Hosttrust, vorbereitete Images und fremde Runs bleiben erhalten.

Nach dem nachweislichen Ende aller eigenen SQL-Consumer:

```powershell
Remove-SqlServerLab -RunId $lab.RunId -StateRoot $lab.StateRoot -Force -Confirm:$false
```

Abnahme: geschlossene Typ-/Profil-/Snapshot- und Manipulationsfälle offline;
ein repräsentativer frischer Windows-SQL-2025-RTM-Run mit beiden echten strikten
Clients, signiertem Export und Consumer; eigener Cleanup mit frischer Abwesenheit.
Die versionsunabhängige Befehlsfolge wird nicht als neue SQL-2019/2022-Matrix
ausgegeben. Neue Code-, Export- und native Consumerbelege sind eigene Gates.
