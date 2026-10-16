# Private TLS-Kontextanfrage und Windows-Vorschau

Der getrennte [CA-Kandidat](AUTHENTICATED_TLS_CA_CANDIDATE.md) verwendet den
internen nativen Prozessreader frisch für seine CurrentUser-DPAPI-/Trust-
Bindung. Er übernimmt keine Caller-Preview als Autorität. Die Kontextvorschau
selbst bleibt lesend, unregistriert und ohne Key-/Trustmutation; beobachtete
Clientbinaries sind weiterhin kein geladener Treiber- oder SQL-Nachweis.

| Merkmal | Wert |
|---|---|
| Status | `PRIVATE_METADATA_PREVIEW`; keine Registrierung oder Qualifikation |
| Stand | 2026-10-16 |
| Implementierung | [`AuthenticatedTlsContext.ps1`](../../Private/AuthenticatedTlsContext.ps1) |
| Prüfung | [`Invoke-AuthenticatedTlsContextChecks.ps1`](../../Tests/Static/Invoke-AuthenticatedTlsContextChecks.ps1) |
| Weiterer Entwurf | [Kontextregistrierung](../Project_Planning/TLS_001_CONTEXT_REGISTRATION_DESIGN.md) |

## Geschlossene Anfrage

Der private Validator `Test-LabAuthenticatedTlsContextRequest` akzeptiert nur
ein natives `PSCustomObject` mit exakten NoteProperties. Er verwendet die
[bestehenden Formhelper](AUTHENTICATED_TLS_REQUEST.md), ohne fremde Getter,
Stringcasts oder ETS-Dekorationen als Eingabedaten auszuführen. Pflichtfelder
werden auch unter StrictMode explizit geprüft. Enums werden ordinal und
groß-/kleinschreibungssensitiv verglichen; zusätzliche Felder werden abgelehnt.

Gemeinsam sind `ContractVersion=SqlServerLab.AuthenticatedTlsContextRequest/0.1`,
`RequestId` als nicht leere kleine D-UUID, `Kind` und ausschließlich
`Context=CURRENT_WINDOWS_PROCESS`. Dazu kommen genau diese rollenspezifischen
Felder:

| Kind | Zusätzliche Felder |
|---|---|
| `CLIENT_CONTEXT` | `ClientRef` als kleine D-UUID, `Store=CURRENT_USER_ROOT`, `ClientStacks` als natives Array mit genau einmal `SYSTEM_DATA_SQLCLIENT` und `ODBC_SQLCMD` |
| `SIGNER_CONTEXT` | `SignerContextRef` als kleine D-UUID, `Backend=DOTNET_X509` |

Das Ergebnis enthält genau `Success`, `Value`, `ErrorCode`. Erfolg liefert eine
frische Form mit separatem, fest geordnetem Stackarray. Ablehnung liefert
`Success=false`, `Value=null`, `TLS_CONTEXT_REQUEST_INVALID`. Der Validator
liest keinen Host. Caller-SIDs, Pfade, Binaries, Freigaben oder Generationen
sind keine Anfragefelder. `AuthorityRef` wird nicht als Signierer-ID akzeptiert.
Die vorgeschlagenen Referenzen werden weder aufgelöst noch reserviert.

## Lesende Prozessvorschau

`Get-LabAuthenticatedTlsContextPreview` prüft die Form vor jeder Hostlesung.
Anschließend beobachtet sie ausschließlich den aktuellen Windows-Prozess.
Andere Hosts, Benutzer, Services, Runner und Remoteprozesse sind nicht wählbar.
Nicht-Windows wird vor Identitäts- und Registryzugriff gesperrt. Die separate
[API-Metadatenprüfung](AUTHENTICATED_TLS_BACKEND_METADATA.md) bleibt plattformübergreifend.

Der native Reader verlangt einen nicht impersonierenden Windows-Token ohne
Anonymous-, Guest- oder Systemidentität und eine reguläre lokale/Domain- oder
AAD-Benutzer-SID. Diese SID-Form beweist weder interaktive Anmeldung noch eine
bestimmte Benutzerrolle. Er liest mit `OpenSubKey(..., false)` den lokalen
`MachineGuid`-Marker, den SID-bezogenen ProfileList-Pfad, den vorhandenen HKU-
Profilhive und den HKCU-Volatile-Environment-Profilpfad. Beide absoluten,
vorhandenen Profilpfade müssen übereinstimmen und auf einem festen lokalen
Laufwerk liegen. Nicht expandierte `%`-Werte bleiben gesperrt; es gibt keinen
Environmentfallback. Pfade verwenden den bestehenden Diagnostic-Pfadguard
gegen UNC, Traversal, ADS und Reparse Points. Zusätzlich werden PID,
Prozessstartzeit und tatsächlicher Prozesspfad beobachtet. Handles werden
auch bei Abbruch freigegeben.

Die verwendeten Microsoft-APIs sind
[WindowsIdentity.GetCurrent](https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.windowsidentity.getcurrent?view=net-10.0),
[ImpersonationLevel](https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.windowsidentity.impersonationlevel?view=net-10.0)
und [RegistryKey.OpenBaseKey](https://learn.microsoft.com/en-us/dotnet/api/microsoft.win32.registrykey.openbasekey?view=net-10.0).
Die explizite Registry64-Auswahl ist keine Behauptung über die Betriebssystem-
Architektur. Der Registrymarker ist kopierbare lokale Metadaten, keine
kryptographische Hostattestation. `OBSERVED_HIVE_AND_PATH` beweist weder einen
geöffneten effektiven Truststore noch den späteren Keyschutz.

Für Clients muss genau eine bereits geladene `System.Data.SqlClient`-Assembly
mit `SqlConnection` und Dateipfad vorhanden sein. Es gibt keinen impliziten
Assemblyload. `sqlcmd` wird wie in [`SqlReadiness.ps1`](../../Private/SqlReadiness.ps1)
als erste `Application` ausgewählt, ohne Alias-/Funktionsfallback oder Aufruf.
Beide lokalen Dateien müssen die erwarteten Namen haben. Der Reader öffnet
sie nur lesend mit `FileShare.Read` und akzeptiert 1 bis 64 MiB. SHA-256,
Byteanzahl und Pfad bezeichnen ausschließlich beobachtete Diskbytes. Die
Assemblyidentität und geladene Modul-MVID werden separat erfasst.
`LoadedImageDigestStatus=NOT_MEASURED`, `SqlcmdFlavorStatus=NOT_QUALIFIED` und
`LoadedOdbcDriverStatus=NOT_EXECUTED` verhindern eine Verwechslung mit geladenem
Code, ODBC-Eignung oder Treiberqualifikation. Fehlende Binaries sperren den
gesamten Befund. Kein PATH wird verändert und kein SQL-Befehl ausgeführt.

Für Signierkontexte werden zusätzlich nur die sechs CLR-API-Signaturen des
Backendreaders beobachtet. Auch `INCOMPLETE` bleibt ein gültiger Metadatenbefund.
Keys, Zertifikate und Stores werden weder geöffnet noch angelegt.

## Privates Ergebnis und Grenzen

Erfolg liefert `ContractVersion=SqlServerLab.AuthenticatedTlsContextPreview/0.1`,
Anfrage-ID, Kind, Kontext, `Status=PRIVATE_METADATA_PREVIEW`, den privaten
`Process`-Befund sowie die rollenspezifische Referenz und Metadaten.
`RegistrationStatus=NOT_REGISTERED`, `QualificationStatus=NOT_EXECUTED`,
`Ready=false` und `MutationAllowed=false` gelten immer. Client-Trust und
Signierer-Keyschutz bleiben jeweils `NOT_EVALUATED`. Native SIDs, Marker,
Profile, Prozess-/Binärpfade und Digests bleiben ausschließlich lokal und
ignoriert; diese Projektion ist keine öffentliche API oder Uploadfreigabe.

Bekannte Sperren liefern `TLS_CONTEXT_PLATFORM_UNSUPPORTED`,
`TLS_CONTEXT_IDENTITY_UNAVAILABLE`, `TLS_CONTEXT_HOST_UNAVAILABLE`,
`TLS_CONTEXT_PROFILE_UNAVAILABLE`, `TLS_CONTEXT_BINARY_UNAVAILABLE` oder
`TLS_CONTEXT_BACKEND_UNAVAILABLE`. Andere Fehler werden auf
`TLS_CONTEXT_PREVIEW_UNAVAILABLE` reduziert, immer ohne Teilbefund oder
Exceptiontext. Lokale I/O ist synchron und bytebegrenzt, ohne harte Zeitgarantie.
Pfadprüfung und Dateiöffnung sind keine atomare Reservierung. Der Snapshot
besitzt keine Frischegarantie oder Sicherheit gegen einen manipulierten
eigenen Prozess beziehungsweise lokale Administratoren.

Nur die exakte Produktdatei erhält eine Offline-Ausnahme im Selektor. Ihre
Form-, Backend-, Pfadguard- und Clientauswahlabhängigkeiten wählen die Suite
ebenfalls aus; bestehende Runtimeauswahl dieser Dateien bleibt erhalten.
Nightly registriert die Suite. Synthetische Form-/Fehler-/Dateigrenztests und
eine getrennte lokale Beobachtung genügen für diesen lesenden Scope;
unabhängiger Review und exakter CI-Pflichtgate bleiben erforderlich. Weitere
Providerstarts oder Modellrunden werden dadurch nicht ausgelöst.

Registrytransaktion, dauerhafte Identitätsbindung, CA-/Keyschutz, Trustimport
und echte Client-/SQL-/TLS-Abnahmen folgen separat. Ergebnisse und fehlende
Nachweise stehen in der [Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md)
und den [Known Limitations](../Quality/KNOWN_LIMITATIONS.md).
