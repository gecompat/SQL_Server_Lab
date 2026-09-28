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
