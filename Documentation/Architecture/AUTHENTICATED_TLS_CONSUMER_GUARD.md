# Private TLS-SQL-Verbraucher: lesender Rootanker und Recoverystatus

## Grenze

`Private/AuthenticatedTlsRootAnchor.ps1` hält native Windows-Handles für die
ausgewählte lokale NTFS-Verzeichniskette und nachfolgend gelesene Dateien.
`Private/AuthenticatedTlsConsumerJournal.ps1` liest einen festen privaten
SQL-CompleteImage-Journalpfad und prüft dessen geschlossene Zustandsfolge.
Beides ist eine interne Voraussetzung für einen späteren festen Setupworker.
Die vorhandenen öffentlichen CompleteImage-/HostSQL-Aufrufe werden dadurch
nicht verändert oder automatisch mit einem Journal ausgestattet.

## Gehaltene Lesebindung

`Open-LabTlsRootAnchor` akzeptiert einen ausdrücklichen vorhandenen lokalen
NTFS-Unterordner mit Laufwerksbuchstaben. UNC, Gerätepfade, Laufwerksroot,
Traversal, leere Komponenten, ADS, Wildcards und DOS-Gerätenamen werden
abgelehnt. Die native Interop wird erst beim ausdrücklichen Aufruf geladen;
ein bereits fremd vorgeladener gleichnamiger Typ wird nicht übernommen.

Die Kette beginnt am geöffneten Volume. Jeder weitere Ordner wird über dessen
Volume-GUID-Pfad geöffnet, mit `OPEN_REPARSE_POINT` geprüft und bis zum eigenen
`Dispose` gehalten. Pfadcache und sämtliche Namespacevergleiche sind ordinal exakt. Eine nur
anders geschriebene Komponente wird nicht auf einen vorhandenen Cacheeintrag
abgebildet; auch auf case-insensitiven Ordnern muss ihre Schreibweise zum
nativen Endpfad passen. Reparsepoints, andere Endpfade und nicht passende
Objektarten blockieren. Native Volume-/Datei-IDs, Endpfade, Prozess und
Windows-Aktor werden beim Lesen erneut geprüft. Das ursprüngliche
Laufwerksalias muss weiterhin auf den gebundenen Root zeigen.

`Read-LabTlsAnchoredFile` akzeptiert ausschließlich relative Unterpfade und
liest durch den gehaltenen Dateihandle, nicht durch einen anschließend neu
aufgelösten PowerShell-Dateipfad. Dateien mit mehreren Hardlinks werden
abgelehnt. Offene Writer oder Schreibmappings blockieren die neue Lesebindung.
Eigene Handles geben weder Schreiben noch Löschen/Rename frei. Die Grenze ist
64 Handles, 32 Pfadkomponenten und höchstens 4 MiB je Datei. Das Journal ist
zusätzlich auf 64 KiB begrenzt. Nur eigene Handles werden freigegeben.

Das ist eine Lesebindung für die tatsächlich geöffneten Objekte. Sie ersetzt
weder die semantische Registrierung von DataRoot/Controller/Location noch
frische CA-/Actor-/VM-Autorität. Nicht geöffnete Geschwisterdateien und spätere
pfadbasierte Writer sind nicht atomar geschützt. Keine ACL wird gesetzt,
keine VM reserviert und kein Handle eines fremden Prozesses geschlossen.
ReFS und Linux sind in dieser Lane nicht unterstützt. Ein CLR-Objekt oder
ein Hash alleine wird dadurch nicht zur Mutationsfreigabe.

Die native Grundlage sind Microsofts Verträge für
[CreateFileW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew),
[Handleinformationen](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfileinformationbyhandle)
und [Handle-Endpfade](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew).

## Geschlossenes Journal-Lesemodell

`Get-LabTlsSqlConsumerRecoveryStatus` liest ausschließlich
`State/authenticated-tls/sql-completion/<OperationId>.json` unter einem
ausdrücklich übergebenen Rootanker. Abwesenheit, Zugriffsfehler, Verzeichnis,
Reparsepoint, ungültige Bytes oder falsche Bindung ergeben einen ungültigen
Status; Abwesenheit wird nicht als nachgewiesene Wirkungslosigkeit behandelt.

Das Format `SqlServerLab.TlsSqlConsumerJournal/0.1` verlangt exakte nicht leere
UUIDs für Operation, Run, Scope und VM sowie exakte SHA-256-Digests für Root,
Quellen und Worker. Der Caller muss diese erwarteten Werte unabhängig und
frisch binden. Der Reader kann ihre Herkunft oder menschliche Autorität
nicht aus der Datei ableiten. Unbekannte, doppelte und anders geschriebene
Felder, Arrays statt Objekten und mehr als 16 Ereignisse blockieren.

| Phase | Zulässiger Folgezustand |
|---|---|
| Anfang | `PREPARED` |
| `PREPARED` | `DISPATCHED`, `ABORTED_NO_EFFECT` |
| `DISPATCHED` | `REPLY_OBSERVED`, `RECOVERY_REQUIRED` |
| `REPLY_OBSERVED` | `RECOVERY_REQUIRED` |
| `ABORTED_NO_EFFECT`, `RECOVERY_REQUIRED` | keiner |

Sequenzen beginnen bei null. Jedes Ereignis verweist auf den SHA-256 der
exakten UTF-8-JSON-Repräsentation des vorherigen Ereignisses; das erste
verwendet 64 Nullen. Diese Verkettung prüft Konsistenz und ist keine Signatur
oder Authentifizierung eines Workers. `EffectEntered` darf nach Dispatch
nicht zurückgesetzt werden. Ein verlorener Reply erlaubt keinen neuen
Dispatch. `CLEANED`, `COMPLETED` oder ein behauptetes Kindprozessende werden
in dieser Form nicht als terminaler Nachweis akzeptiert.

Jeder Zustand nach Dispatch ergibt `RECOVERY_REQUIRED`, auch ein erfolgreicher
Reply. `ConsumerEnd` bleibt `NOT_PROVEN`; `Ready`, `MutationAllowed`,
`RetryAllowed`, `StopAllowed` und `CleanupAllowed` bleiben false. Ein gültiger
Readerbefund bestätigt ausschließlich die aufgezeichnete Form. Es gibt hier
keinen Journalwriter, Executor, automatischen Retry oder Recovery-Apply.

## Ausstehender Verbrauchernachweis

Der vorhandene CompleteImage-Gastblock wartet bis zu 90 Minuten auf seinen
Setup-Parent. Bei Timeout adressiert er nur diesen Prozess. Ein normaler
Parentexit oder lokales Remoting-Jobcleanup beweist kein Ende sämtlicher
Gastverbraucher. Ein eigener nativer Worker benötigt weiter ein festes
unabhängig geprüftes Worker-/Supervisor-/Intent-/Preview-Paket, eine echte
begründete Gast-/Kind-/Installergrenze, frische Root-/Actor-/CA-/VM-Bindung,
den verfügbaren nicht abandoned Runtime-Smoke-Mutex und ein endliches
Einversuchsbudget. Timeout oder unbekannte Wirkung bedeuten Erhalt der
VM/Disks/des vorhandenen Keys und CSR; sie erteilen keine Stop-/Cleanupautorität.

Die [Guard-Suite](../../Tests/Static/Invoke-AuthenticatedTlsConsumerGuardChecks.ps1)
trennt synthetische Journalgegenfälle von echten eigenen NTFS-Tempfixtures:
gehaltene Lesebytes, blockierter Austausch und Writer, Reparsepoints,
Hardlinks und eigene Handlefreigabe. Der Case-Gegenfall verwendet die
tatsächliche Klasse mit zwei synthetischen Namespace-Blättern auf echten
eigenen Dateien; kein Host-Caseflag wird verändert. Das qualifiziert keinen
nativ case-sensitiven Testordner. Das ist keine native VM-/Setup-/SQL-/TLS-
Qualifikation. Die [öffentliche VM-ID-Lane](HYPERV_SQL_COMPLETION_BOUNDARY.md)
bleibt unverändert. SC-2026-045 und die vollständige TLS-001-Abnahme bleiben offen.
