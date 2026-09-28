# CSharp-Nativabnahme auf Windows und SQL Server 2025

Status: interner opt-in Testpfad; letzte native Sprachabnahme `FAILED`.
Die Katalogvariante bleibt `PREVIEW`. Offline-Build, Paketintegrität und
synthetische Runnerprüfungen sind keine SQL-/Launchpad-Freigabe.

Seit 2026-09-28 ist die weitere C#-Arbeit auf Benutzerwunsch `USER_DEFERRED`.
Der Runner bleibt implementiert; die letzte native Abnahme `36405567818`
auf `88c0445f` scheiterte mit SQL 39048/39004 und Hostfxr-Trace `EMPTY`.
Eigenes Cleanup und Evidenceaufbewahrung waren erfolgreich. API-3-
Kompatibilität bleibt ein `UNPROVEN`-Verdacht. Reale Diagnosen bleiben
ausschließlich privat und lokal. Die
[kanonische Entwicklungswelle](../Project_Planning/AUTONOMOUS_DEVELOPMENT_WAVE_2026-09-10.md#c-zurückgestellt-und-geänderte-priorität-am-2026-09-28)
bestimmt Priorität und bewusste spätere Wiederaufnahme; es erfolgen aktuell
keine weiteren C#-Diagnosen, Implementierungen oder Runtimeversuche.

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

## Runnerlokales Profil

Der Workflow benötigt den festen Profilnamen `csharp-sql2025` und den SHA256
über die unveränderten Bytes eines ausdrücklich lokal gestagten Requests.
`Invoke-CSharpNativeRequestAcceptance.ps1` prüft zuerst Ursprungsrepository,
Main-Ref und exakten sauberen Checkout, bevor es lokale Requestdaten liest.
Es gibt keinen Fallback auf vorhandene Profile, keine Suche und keinen Download.

Der Request liegt ausschließlich lokal unter
`<Laufwerksroot>/SqlServerLab-CSharpRequest-<sha256>/request.json`. Der Root ist
exakt der durch `CommonApplicationData` bestimmte lokale Laufwerksroot und
muss den festen Datenträger-, Reparse-, Owner- und Vorfahrenguard bestehen.
Der Eingangsordner darf unprivilegiert gestagt sein: seine Daten sind nicht
vertrauenswürdig; die Freigabe bindet der explizit übergebene SHA256. Request
und Eingang werden niemals repariert, überschrieben oder entfernt. Ihre
Datenschutzrechte muss der lokale Bereitsteller vor dem Staging sicherstellen.
Reale Inhalte oder Pfade gehen nicht an GitHub.

Das UTF-8-JSON ohne BOM ist höchstens 32 KiB groß. Es enthält exakt
`SchemaVersion` (`1`), `Purpose` (`CSharpNativeAcceptance`), `ProfileName`
(`csharp-sql2025`), eine frisch zufällig erzeugte nichtleere `Nonce`-GUID in
kanonischer Kleinschreibung, `MainCommit` (exakter ausgelöster Commit),
`ExpiresUtc` (`yyyy-MM-ddTHH:mm:ssZ`) und das eingebettete Objekt `Profile`.
Außer `Profile` sind alle Werte Strings. Die UTC-Ablaufzeit muss beim Lesen in
der Zukunft und höchstens vier Stunden entfernt sein; vor dem Supervisor wird
sie erneut geprüft. `Profile` verwendet unverändert den unten beschriebenen
16-KiB-Profilvertrag. Doppelte oder unbekannte Felder werden abgewiesen.

Der Reader bindet begrenzte Daten und SHA256 an dasselbe Dateihandle, ohne
parallelen Schreib-/Löschzugriff; erst danach wird JSON interpretiert. Der
Wrapper erzeugt einen neuen eigenen GUID-Profilroot atomar mit Admin-Owner
und geschützter Admin-/SYSTEM-ACL, schreibt das Profil mit `CreateNew` und
prüft es mit dem bestehenden tatsächlichen Resolver. Er setzt
`SQL_SERVER_LAB_CSHARP_PROFILE_ROOT` ausschließlich in seinem Prozess und ruft
danach den unveränderten Supervisor auf. Dienste, persistente Umgebungswerte
und bestehende Zugriffsrechte bleiben unberührt.

Im `finally` wird die vorherige Prozessumgebung wiederhergestellt. Nach erneuter
Pfad-/Reparse-/ACL-Prüfung werden ausschließlich eigene Profildatei und leerer
Profilroot entfernt. Vorhandene Zielobjekte werden niemals übernommen. Fehler
vor vollständigem Schreiben bleiben bereinigbar. Hauptfehler, Run-Cleanupfehler
und `ProfileCleanupFailure` bleiben getrennt sichtbar; ein Cleanupfehler
verhindert PASS und meldet Recoverybedarf. Vor der ersten Profilmutation wird
unter `LocalApplicationData/SqlServerLab/CSharpRequestRecovery/<GUID>` ein
exklusives lokales `profile-recovery.jsonl` angelegt. Es liegt außerhalb von
Actions-Checkout und RUNNER_TEMP und bleibt auch nach erfolgreichem Cleanup
als Diagnose erhalten. Der begrenzte append-only Beleg enthält Operation,
Request-Nonce/-Hash, Commit, eigene Root-/Dateibindung und Status, keine
Profilinhalte. Jeder Eintrag wird vor dem nächsten Schritt auf den Datenträger
geflusht. PREPARED bestätigt keine Anlage; CREATED bestätigt die eigene
Verzeichnisanlage, FILE_CREATED die Profildatei. CLEANED, NOT_CREATED und
CLEANUP_FAILED unterscheiden den Abschluss. Recordfehler vor Mutation sperren
die Anlage; spätere Recordfehler bleiben zusätzlich sichtbar und verhindern
PASS. Weder Record noch seine realen Pfade werden nach GitHub übertragen.

Ein harter Kill zwischen Create und bestätigtem CREATED-Eintrag hinterlässt
UNKNOWN: PREPARED oder eine unvollständige letzte Journalzeile berechtigen
niemals zur automatischen Übernahme oder Löschung eines Objekts. Auch ein
CREATED-Beleg ersetzt keine aktuelle manuelle Ownership-/Pfadprüfung.
Automatische Recovery ist nicht implementiert. Harter Prozess-/Hostabbruch bleibt
ein Recoveryfall. Es gibt keinen automatischen Retry. Eine erneut ausdrücklich
ausgelöste identische Anfrage innerhalb ihrer Commit-/Zeitbindung ist möglich;
eine dauerhafte Einmalverwendungsdatenbank ist nicht implementiert.

Der direkte interne Einstieg `Invoke-CSharpHyperVAcceptance.ps1 -Profile`
bleibt für ein bereits administrativ konfiguriertes Profil unverändert
verfügbar. Nur dort setzt der Bereitsteller den runnerlokalen Profilroot selbst;
der Workflow ersetzt diesen Einstieg ausdrücklich durch den Requestwrapper.
Die native Ausführung `36367366887` endete mit `PROFILE_ROOT_REQUIRED` vor
Gast-/SQL-Arbeit und ohne Run-Recoverybedarf. Das ist kein nativer Sprachbeleg.

Für den direkten internen Profileinstieg erfolgt die Einrichtung separat
durch einen berechtigten Administrator; der
Test legt weder Profile an noch repariert er Zugriffsrechte. Profil und Root
müssen auf einem lokalen festen Windows-Laufwerk liegen, ohne Reparse Points
in der gesamten Vorfahrenkette. Owner und Schreibzugriffe auf Datei/Root sind
auf SYSTEM, integrierte Administratoren und TrustedInstaller begrenzt. Alle
Vorfahren werden zusätzlich gegen fremde Löschung, DeleteChild, Attribut-,
ACL- und Owneränderung geprüft. Fremde CreateFile/CreateDirectory-Rechte auf
höheren Vorfahren allein erlauben keine Ersetzung vorhandener geschützter
Objekte. InheritOnly-ACEs gelten nicht als Rechte auf dem aktuellen Objekt.
Null-DACL, unbekannte wirksame Schreiber und nicht auflösbare ACLs sperren den
Lauf. Der Runner benötigt zusätzlich die bereits bestehenden erhöhten Rechte.

Das UTF-8-JSON ist höchstens 16 KiB groß. Es enthält exakt diese Stringfelder:
`SchemaVersion` mit Wert `1`, `ArtifactId`, `PayloadRoot`, `PackageSha256`,
`ProbeSha256`, `SqlMediaPath`, `MediaEdition`, `StateRoot` und `MediaRoot`.
Alle Werte sind erforderlich; doppelte, zusätzliche und anders geschriebene
Felder werden abgewiesen. Roots sind absolute lokale Windows-Pfade,
`SqlMediaPath` ist ein relativer ISO-Pfad ohne Traversal; `MediaEdition` ist
`Enterprise`, `Standard` oder `Eval`. Es gibt keine Hash-, Medien-, Root- oder
Latest-Defaults. Paket und Probe behalten unabhängig geprüfte SHA256-Werte;
der Runtimehash bleibt fest im Supervisor gebunden. Profile sind reine Daten,
keine Skripte. Reale Profile und Payloads bleiben außerhalb der Versionierung.

Profilfehler gehen wie andere Runnerfehler nur als feste bereinigte Codes nach
GitHub. Die vorhandene lokale Streamumleitung umfasst auch die Profilauflösung.
Ein fehlendes oder nicht sicher gebundenes Profil bleibt ein offener lokaler
Einrichtungsschritt und ist kein nativer SQL-Nachweis.

## Ablauf und Grenzen

Die generische Readinessprüfung bleibt `hyperv`/`Create` einschließlich Storage.
Ihr Vertrag `SqlServerLab.ClientReadiness/1.0` meldet bei gesundem Bootstrap
absichtlich `READY_WITH_WARNINGS`: die einzige Warnung
`TARGET_AUTHORIZATION_REQUIRED` überlässt konkrete Autorisierung dem
Operationseinstieg. Der CSharp-Adapter akzeptiert ausschließlich diese exakt
gebundene Kombination mit acht bekannten erfolgreichen Voraussetzungchecks,
der passenden OperationRights-Warnung, leeren MissingPrerequisites und
`MutationAllowed=false`. Andere Warnungen, fehlende Checks, NOT_CHECKED,
BLOCKED oder inkonsistente Statusmeldungen bleiben gesperrt. Der Adapter
verändert weder das Readinessergebnis noch die vorhandenen Elevation-,
Ressourcen-, Medien-, Ownership- und Cleanupguards. Ein begrenztes Fehlerdetail
bleibt ausschließlich im lokalen Artefaktscope; GitHub erhält feste Fehlercodes.
Der native Lauf `36371565625` scheiterte an der bisherigen READY-only-Abfrage;
sein ephemeres Profil wurde vollständig bereinigt. Eine erfolgreiche native
Sprachprobe ist damit weiterhin nicht bestätigt.

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

Der Gast baut seine lokale SQL-Verbindung über kanonische Schlüssel des
`SqlConnectionStringBuilder` auf, insbesondere `Data Source` statt einer
PowerShell-Zuweisung an `DataSource`. PowerShell behandelt den Builder als
Dictionary; CLR-Eigenschaftsnamen ohne SQL-Schlüsselabstände können deshalb
bereits vor einer Verbindung scheitern. Die Offline-Regression führt den
tatsächlichen Gastbuilder unter PowerShell 7 und verfügbarem Windows PowerShell
5 aus und prüft Endpoint, Timeout, Verschlüsselung, deaktiviertes Pooling und
separate read-only `SqlCredential`, ohne eine SQL-Verbindung zu öffnen.
Der native Lauf `36372699217` erreichte Gast-/SQL-Provisionierung, scheiterte
aber am ungültigen Schlüssel vor der Sprachprobe; sein eigener Run wurde
bereinigt. Die korrigierte Verbindung ist noch kein nativer Sprachnachweis.

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
Die Profilprüfungen ergänzen echte JSON-Parserfälle, Hash-/Pfad-/Schemafehler,
ACL- und Vorfahrenfälle sowie die reine Profilübergabe im Workflow. Eine eigene
unprivilegierte Windows-Datei belegt die tatsächliche ACL-Abweisung; positive
ACL-Adapterfälle verwenden synthetische SecurityDescriptor-Objekte. Die echte
Einrichtung eines realen Runnerprofils bleibt separat. Ein zusätzlicher Test
prüft auf erhöhtem Windows den tatsächlichen Profilresolver mit ausschließlich
synthetischem JSON in einem eigenen GUID-Unterordner direkt am Laufwerksroot
des durch CommonApplicationData bestimmten lokalen Laufwerks. Er
prüft die vorhandenen Vorfahren nur lesend und erzeugt den neuen Ordner atomar
mit Admin-Owner und geschützter Admin-/SYSTEM-ACL. Ein vorhandener Name wird
niemals übernommen. Die Profildatei verwendet CreateNew mit initialer ACL.
ProgramData selbst ist keine geeignete feste Testbasis: bestehende effektive
Schreibrechte können dort den unveränderten strengen Vorfahrenguard verletzen.
Der Test verwendet genau den abgeleiteten Laufwerksroot; er sucht keine
alternativen Basen und verändert keine bestehenden ACLs. Auch dieser Root muss
die vollständige lokale Datenträger-, Reparse-, Owner- und Vorfahrenprüfung
bestehen. Feste Diagnosestufen unterscheiden Vorprüfung, sichere Anlage,
Rootprüfung, Profilauswertung und Cleanup. ACL-Diagnosen enthalten ausschließlich
BASE/ANCESTOR und OWNER/DACL/WRITER, niemals Pfade, SIDs oder rohe ACEs. Ein
ungeeigneter Laufwerksroot bleibt FAIL; es gibt keine Umdeutung zu PASS.
Nach erneuter Pfad-/Reparse-/ACL-Prüfung werden ausschließlich die eigene Datei
und der leere eigene Ordner entfernt; Cleanupfehler verhindern PASS.

Der eindeutige Check `CSharp profile ACL evidence: real protected profile and
exact cleanup` meldet nur nach tatsächlicher Resolverprüfung und Cleanup PASS.
Linux und nicht erhöhte Windows-Prozesse melden dafür ausdrücklich
`NOT_EXECUTED`, ohne UAC oder Änderung bestehender Zugriffsrechte. Synthetische
Fehlerfälle prüfen Kollision, Teilanlage, private Fehler, Reparse-Abbruch und
getrennte Cleanupfehler auch ohne erhöhte Rechte. Die vorhandene Windows-CI
kann den echten positiven Fall ausführen. Dies startet weder SQL noch VMs und
bestätigt keine Installation oder Katalogpromotion. Die CI-Auswahl bindet die
Dateien an diese Suite.
Ein nativer Durchlauf
und seine bestätigte Ressourcenbereinigung stehen noch aus.

Die Request-Fixture ergänzt tatsächliche bounded-Dateilesung und Hashbindung,
strikte Envelope-/Profil-Negativfälle, Kollision/Teilwrite, Umgebungserhaltung
und gleichzeitig fehlgeschlagenes Run- und Profil-Cleanup. Auf erhöhtem
Windows nutzt der positive synthetische Fall den produktiven ephemeren
Profilwrapper mit einer No-op- beziehungsweise werfenden Action; er ruft
keinen SQL-/VM-Supervisor auf. Nur sein expliziter PASS bestätigt Profilanlage
und eigenes Cleanup, nicht die native Sprachabnahme.

## Dauerhafte lokale Abnahmenachweise

Der Request-Wrapper erzeugt nach dem vertrauenswürdigen Main-/Repository- und
Elevationsguard genau einen atomar neu angelegten GUID-Ordner auf dem geprüften
lokalen Laufwerksroot. Seine initiale geschützte ACL erlaubt ausschließlich
Administratoren und SYSTEM Schreibzugriff; ausschließlich die tatsächliche
WindowsIdentity.User des Runnerprozesses erhält zusätzlich Lesezugriff. Vorhandene Ordner werden weder übernommen
noch durch ACL-Reparaturen verwendbar gemacht. Der ausschließlich interne
EvidenceRoot-Parameter ist kein Workflow-Input. Ein begrenzter geschlossener
Marker bindet Main-SHA, Workflow-Run und Native-Operation; ein exklusiver
Supervisor-Claim verhindert Wiederverwendung desselben Ordners.

Plan, Payloadkopien, Workflow-/Worker-Rohlogs, SQL-Versuchsmarker und Receipt
bleiben ausschließlich dort lokal. Checkout-Cleanup und Runner-Tempbereinigung
berühren diesen Ort nicht. Kindprozessausgaben fließen bereits während der
Ausführung in vor dem Prozessstart exklusiv erzeugte Dateien. Prozessende und
Ausgabedrain bleiben zeitlich begrenzt. `EvidenceFailure` wird getrennt von
Hauptfehler, Run-Cleanup und Profil-Cleanup transportiert; GitHub erhält nur
feste Fehlercodes, keine lokalen Pfade, Rohlogs oder hochgeladenen Artefakte.
VM- und Profilcleanup löschen keine Evidenz. Ein eigener späterer, exakt
gebundener Retentions-/Cleanupauftrag ist erforderlich; dieser Slice fügt
keine automatische Löschung hinzu. Ein harter Abbruch kann einen Marker oder
Teilstreams ohne abschließenden Receipt hinterlassen: das ist kein PASS.

Der Lauf `36375779272` verlor seine checkout-/tempgebundenen Rohdiagnosen beim
folgenden CI-Checkout. Sein konkreter Kindfehler und SQL-Versuchsstatus sind
`UNKNOWN`, nicht nachträglich als `NOT_EXECUTED` oder Sprachfehler zu deuten.
Der separat erhaltene Produkt-Run ist nachweislich `REMOVED`; dieser
Cleanupnachweis rekonstruiert den verlorenen SQL-Marker nicht. Ein erneuter
nativer Lauf erfolgt erst mit dem integrierten Retentionsfix. Offlineprüfungen
verwenden ausschließlich synthetische Daten und Kindprozesse. Die reale
geschützte Ordneranlage wird auf erhöhtem Windows-CI ohne VM/SQL geprüft;
Linux oder ein nicht erhöhter lokaler Prozess meldet `NOT_EXECUTED`.

Der zusätzliche initiale Lesegrant verwendet keine externe SID und keine
allgemeine Users-Gruppe. Er gilt nur für Evidence; Profil-ACLs bleiben
unverändert. Derselbe Benutzer kann damit auch ohne erhöhten Token lesen;
der lokale nicht erhöhte Testprozess kann die reale erhöhte Anlage jedoch
nicht beweisen. Windows-CI prüft den tatsächlichen Grant einschließlich
fehlender Schreib-/Löschrechte. Bei einer abweichenden Operatoridentität ist
ein gesonderter autorisierter Runner-Leseweg erforderlich; dieser Slice
implementiert keinen solchen Diagnose-Workflow und behauptet keinen Zugriff.

## Begrenzte lokale Gastdiagnose bei Sprachfehlern

Der spätere Lauf `36383157413` auf `cc947151` scheiterte bei der nativen
Sprachprobe mit SQL-Fehler 39048 während der Bibliotheksinstallation und
`E_FAIL`. Eigenes Cleanup war erfolgreich. Das belegt weder einen Defekt des
DLL-Formats noch die konkrete Hostfxr-Ursache; die native Freigabe bleibt offen.

Die eigene Registrierung von `dotnet` setzt `COREHOST_TRACE=1` und den exakt
gebundenen `COREHOST_TRACEFILE` über `CREATE EXTERNAL LANGUAGE ... ENVIRONMENT_VARIABLES`.
Die [SQL-Referenz](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-external-language-transact-sql?view=sql-server-ver17)
beschreibt die Übergabe vor dem Start des externen Prozesses;
Microsofts [Windows-Registrierungsbeispiel](https://learn.microsoft.com/en-us/sql/language-extensions/install/windows-java?view=sql-server-ver17)
zeigt das JSON-Format. Für .NET 8 verwendet
[Host-Tracing](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-environment-variables)
den Präfix `COREHOST_` und ohne `COREHOST_TRACEFILE` den stderr-Stream.
Der stderr-Versuch `36393433388` auf `faea6ad1` blieb `FAILED`: SQL 39004,
Bibliotheksinstallation mit 39048/E_FAIL, keine Hostfxr-Zeilen in den
begrenzten Diagnosen. Cleanup und Evidenceaufbewahrung waren erfolgreich.
Eine unveränderte Wiederholung ist daher kein weiterer Diagnoseschritt.

Der neue Dateipfad liegt ausschließlich im eigenen kurzlebigen Gastroot.
`CreateNew` erzeugt `hostfxr-trace.log` mit initial geschützter ACL und
Admin-Owner; vorhandene Ziele werden nicht übernommen. Nur Admin/SYSTEM
haben Vollzugriff. Die zuvor verifizierte Default-Identität
`NT SERVICE\MSSQLLaunchpad` und `ALL APPLICATION PACKAGES` erhalten
`FILE_GENERIC_WRITE` ausschließlich auf dieses File, ohne Vererbung,
Delete-, ACL- oder Ownerrechte. Der zweite Trustee ist ausdrücklich breit,
kein individueller Worker-SID. Verzeichnisse, Paketdateien und Host-ACLs
erhalten keine zusätzlichen Schreibrechte. CRT-Append benötigt Schreibzugriff;
dies ist kein ACL-erzwungenes Append-only. Die
[.NET-8.0.31-Implementierung](https://github.com/dotnet/runtime/blob/v8.0.31/src/native/corehost/hostmisc/trace.cpp)
verwendet den Modus `a` ohne Buffering. Ein tatsächlicher CRT-Schreibversuch
unter synthetisch schreibbeschränktem Windows-Token prüft den Einzelgrant und
verweigerte Nachbardatei-/Neuanlage; das ist kein AppContainer-Nachweis.

Ein separat mit initialer Admin-/SYSTEM-ACL exklusiv angelegter Marker bindet
Volume und File-ID über Kaltstarts. Öffnen und Prüfen verwenden dasselbe
Handle ohne Delete-Sharing: Reparse-Dateien, Verzeichnisse, mehrere Hardlinks,
abweichende Identität, Owner oder ACEs werden abgewiesen. Vor jeder Probe
wird erneut geprüft. Bereits mehr als 1 MiB Trace verhindert die nächste
Probe; dies ist **keine harte Größenbegrenzung während des Schreibens**.
Das bestehende Ausführungszeitlimit bleibt wirksam. Übermäßiges Wachstum
innerhalb einer Probe bleibt ein Risiko; der Trace besitzt keinen eigenen
physischen Byte-Cap.

Die Fehlerdiagnose überträgt höchstens 32 KiB des Dateiende mit Gesamtgröße,
Offset und Truncation-Marker. `EMPTY` unterscheidet eine leere Datei von
`UNAVAILABLE`; Rohdaten bleiben ausschließlich lokal. Das bestehende
operationseigene VM-Cleanup entfernt Datei und Marker, einschließlich
partieller Anlage. Persistente Host-Umgebungswerte bleiben unverändert.
Die tatsächliche Hostfxr-Erfassung über diesen neuen Pfad ist `UNPROVEN`;
ein nativer Versuch steht noch aus. Paketbindung, AppContainer-Isolation,
Kaltstart und alle Erfolgskriterien bleiben unverändert.

Der Lauf `36378690432` auf `43542f9b` erreichte nachweislich `SQL_PROBE_STARTED`
und endete mit `NativeAcceptanceStatus=FAILED`, HRESULT `0x80004004` und
`CSHARP_PROBE_ROW_COUNT`; eigenes Cleanup und Evidenceaufbewahrung waren
fehlerfrei. Die konkrete Sprachfehlerursache ist damit noch nicht bewiesen.
Die Zeilenzahlmeldung kann ein Folgefehler sein. Der gepinnte SDK-Outputpfad
verwendet generische DataFrameColumn-Werte und enthält keinen Cast auf
`Int32DataFrameColumn`; eine solche Ursache ist nicht belegt.

Der externe SQL-EXEC steht jetzt in TRY/CATCH mit unverändertem `THROW;`.
Erst nach erfolgreichem EXEC gelten die unveränderten drei Zeilen, Werte,
.NET 8, AppContainer 1 und positive Worker-PID; der zweite Test nach Neustart
bleibt verpflichtend. Der Gast erfasst bei einem Probe-Fehler bis zu acht
SqlException.Errors und acht InfoMessages (Message je 2048, Procedure 128
Zeichen). Ein kompilierter .NET-Collector verarbeitet InfoMessage-Callbacks
unter einem Lock ohne PowerShell-Runspacezugriff; erst nach ExecuteScalar
projiziert PowerShell die begrenzten Meldungen. Der tatsächliche Callback
auf einem fremden .NET-Thread ist offline unter PowerShell 7 und Windows
PowerShell 5.1 geprüft. SQL-Text, Credentials und Connection Strings werden
nicht gesammelt.
Die Diagnose wird nur im eigenen Gastroot gespeichert. Der Worker holt sie
vor dem VM-Cleanup erneut über dieselbe Run-/Scope-/VM-ID-Bindung mit 30
Sekunden Deadline ab und schreibt sie ausschließlich in seinen dauerhaften
lokalen stderr-Stream. Ein Diagnosefehler ersetzt nie den ursprünglichen
SQL-Fehler; GitHub erhält weiterhin ausschließlich feste Fehlercodes.

Die feste Log-Allowlist umfasst ausschließlich den aktuellen ERRORLOG der
neu angelegten Default-Instanz und dessen Geschwisterpfad
`ExtensibilityLog/ExtLaunchErrorlog`. Ausgangspunkt ist der eindeutige
`-e`-Startparameter dieser SQL-2025-Instanz; keine Dateisystemsuche oder andere
Instanz wird einbezogen. Pro Datei werden maximal 32 KiB vom Ende binär als
Base64 mit Offset und Bytezahl gespeichert. Reparse-/Netzwerkpfade und fehlende
Dateien liefern `UNAVAILABLE`. Gespeichertes SQL-JSON ist auf 256 KiB, die
übertragene Diagnose auf 512 KiB begrenzt. Die SQL-/Launchpad-Logkonvention
folgt [Microsofts Diagnosehinweisen](https://learn.microsoft.com/en-us/sql/machine-learning/troubleshooting/data-collection-ml-troubleshooting-process?view=sql-server-ver17).
Diese Quellen belegen keinen festen separaten CSharp-stderr-Dateinamen;
zusätzliche Extensionlogs werden daher nicht geraten oder global eingesammelt.
Fehlende Logs und ein fehlgeschlagener Transport bleiben erkennbare
Diagnosegrenzen. Synthetische Offlineprüfungen belegen Helfer und Fehlererhalt,
keinen erneuten SQL-/Launchpad-Lauf oder erfolgreichen Sprachtest.
