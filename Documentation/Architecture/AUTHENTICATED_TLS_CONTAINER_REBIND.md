# Explizite TLS-Wiederbindung nach Containerneustart

`Update-SqlServerLabTlsBinding` bindet einen ausdrücklich ausgewählten eigenen
Windows-/Docker-/Podman-Run nach einem Containerneustart erneut. Er verlangt
PowerShell 7.5+, `RunId`, `InstanceId` und den zurückgegebenen privaten
`StateRoot`. Nur die policygebundenen operativen Recordformen `0.2`/`0.3`
mit den geschlossenen SQL-/CU-Profilen des
[operativen TLS-Vertrags](AUTHENTICATED_TLS_OPERATIONAL_LAB.md) sind zulässig.
Historische `0.1`-Records werden nicht übernommen.

## Ziel und Nachweis

Der Befehl prüft Eigentum, ursprüngliche Runtime-Inkarnation, Container,
Image-Digest, Port und die gespeicherte Authority-/Client-/Registrybindung.
Ein Kandidat darf ausschließlich `StartedAt` auf die frisch beobachtete,
spätere UTC-Start-Epoche ändern. Zertifikat-DER, Keyrechte, SQL-Konfiguration
und Lademeldung müssen weiterhin exakt passen. Beide echten strikten Clients
prüfen den erwarteten SQL-Build und `encrypt_option=TRUE`; danach werden
dieselben Bindungen erneut gelesen.
Die geschlossene RFC3339-Form erlaubt `Z` oder einen expliziten numerischen
Offset sowie bis zu neun Nachkommastellen. Zeitliche Ordnung und Zukunftsgrenze
werden über UTC-Instants verglichen; gleiche Instants mit anderer Darstellung
werden abgewiesen. Gespeichert bleibt der exakte frisch beobachtete Native-Text,
damit die bestehende Stringbindung an den Provider erhalten bleibt.

Zertifikat, Key, Trust, CA, Provider, Port und SQL-Konfiguration werden nicht
geändert. Es gibt keinen Dienst- oder Containerneustart, keine Erneuerung,
Zielübernahme oder automatische Reparatur. Ein unveränderter Start liefert
`UNCHANGED_ALREADY_BOUND`, `BindingUpdated=false` und
`QualificationStatus=NOT_EXECUTED`. Dieser No-op ist kein neuer Clientnachweis.
`WhatIf` beendet den öffentlichen Einstieg vor Authority-, Runtime- und
Dateizugriffen.

## Geschützte Transaktion

Ein eigener fester Unterordner `authenticated-tls-rebind` im exakt gebundenen
TLS-StateRoot verwendet den bestehenden nicht wartenden Global-/Filelock-Kern.
Ein geschützter Owner bindet alle unveränderlichen Recordfelder. Vor dem
Dateiersatz bestehen unveränderliche Original-, Kandidaten- und Intentdateien.
`File.Replace` erhält die tatsächlich ersetzte Quelle als eigene Sicherung.
Quell-/Kandidatenhash, ACL, Authority und echte Native-Epoche werden vor und
nach dem Ersatz geprüft; erst danach entsteht der Commit.

Die Folge ist auf 64 explizite erfolgreiche Wiederbindungen pro Lab begrenzt.
Der Reader prüft geschlossene Dateiformen, vollständige Snapshots, eindeutige
fortlaufende Sequenzen und die exakte Vorgängerhashkette bis zum aktuellen
Record. Unvollständige, fremde, umgebundene oder widersprüchliche Inhalte
ergeben Recoverybedarf, auch bei inzwischen unveränderter Epoche. Ein
verlorener Reply beziehungsweise unklarer Schreibausgang erlaubt weder
automatischen Retry noch Rollback. Es gibt keinen Recovery-Apply-Befehl.
Die Serialisierung ist kooperativ und keine Zusage gegen einen feindlichen
Hostadministrator oder denselben Benutzer mit beliebiger Codeausführung.
Normale Qualifizierung, Export und Exportreadback prüfen vorhandene History
unter demselben Writer-Lock vor weiteren Clientprüfungen und erneut vor ihrer
Erfolgsrückgabe. Ein installierter Kandidat ohne vollständigen Commit bleibt
gesperrt. Nur der interne Kandidatenpfad mit seinem tatsächlich offenen,
passenden Writer-Lock darf während der eigenen Transaktion qualifizieren.

## Export und Betrieb

Nach Erfolg lautet der Status `QUALIFIED_METADATA_COMMITTED`. Die Rückgabe
enthält Provider, SQL-/CU-/Build, Flags und den frischen Nachweiszeitraum;
keine Credentials, internen Authorityreferenzen oder privaten Hostpfade.
Der Wire-Zertifikatsfingerprint bleibt `NOT_OBSERVED`.

Frühere V2-Exporte bleiben durch ihre alte Start-Epoche ungültig. Ein neuer
Export wird ausdrücklich in ein neues Verzeichnis erzeugt und führt seine
beiden realen Verbindungen erneut aus. V1 und True/True-Default bleiben erhalten.
Der normale eigene Run-Cleanup entfernt Runtime-Ressourcen; geschützte
Transaktionsnachweise bleiben lokal. Die Acceptance-Lane bereinigt nach
terminalem eigenem Run ausschließlich die beiden festen Exportverzeichnisse.

Die [statische Suite](../../Tests/Static/Invoke-AuthenticatedTlsRestartRebindChecks.ps1)
verwendet eigene echte Tempdateien, ACLs, Locks und Dateiersatz mit injizierten
Authority-/Provider-/Clientgrenzen. Sie ist keine SQL-Verbindungsabnahme.
Die [native Lane](../../Tests/Integration/Invoke-AuthenticatedTlsLabAcceptance.ps1)
besitzt den ausdrücklichen Schalter `-ExerciseRestartRebind`; ihre ausgeführten
Ergebnisse stehen in der [Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md).
Die getrennte Windows-/SQL-2022-CU27-Abnahme bestand mit Docker und Podman
je zwölf Fälle und zwölf bezeichnete strikte Clientergebnisse auf Build
`16.0.4295.3`. Die tatsächlichen Records verwenden `0.3` mit
`SqlProfileId=2022-CU27`. Eigener Cleanup und Bestandsvergleich bestanden.
Produkt und öffentlicher Harness sind dafür unverändert; die bezeichneten
Clientergebnisse ergeben sich aus sechs positiven Zweiergruppen, keiner
instrumentierten Gesamtzahl von Netzwerkverbindungen.
Die zusätzliche Windows-/SQL-2025-CU9-Abnahme bestand getrennt mit Docker und
Podman auf Build `17.0.5005.3`: je zwölf Fälle und zwölf strikte Clientergebnisse,
Recordform `0.2` ohne `SqlProfileId`, vollständiger eigener Cleanup und
Bestandsvergleich. Ein unabhängiges Oracle prüft
die tatsächliche Property-Abwesenheit; vorhandenes `null` oder leer wird abgewiesen.
Die SQL-2025-Ergebnisse bleiben ein eigener Versionsnachweis.
Getrennte native Windows-/SQL-2019-CU32-Abnahmen bestanden für Docker und Podman
je zwölf Fälle und zwölf strikte Clientergebnisse mit eigenem Cleanup. Docker
belegt den Stand vor der fokussiert geprüften Offsetkorrektur, Podman den
korrigierten Stand; der ursprüngliche Podman-FAIL bleibt erhalten. Finale
PR-Pflichtgates bleiben Integrationsbedingung. Linuxclients, Hyper-V-False-/Exportpfade, Renewal,
Consumer-Cutover und gerenderter Browser bleiben getrennte offene Grenzen.
