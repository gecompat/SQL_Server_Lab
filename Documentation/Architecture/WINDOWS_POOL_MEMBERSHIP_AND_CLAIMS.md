# Windows-Pool: Membership, Claims und Recovery

Dieser Vertrag gilt ausschließlich für neue, ausdrücklich erzeugte Windows-
Poolmitglieder. Bestehende Windows-Labs werden niemals anhand ihres Namens
übernommen. SQL-Reserve und automatische Auffüllung bleiben unbekannt bzw.
nicht implementiert; die Reservepolicy bleibt advisory.

`New-SqlServerLabWindowsSlotPool` liefert eine Pool-ID. Ein Resume benötigt
dieselbe `-PoolId` und denselben Konfigurationsvertrag. Das vorhandene
`run-state.json` enthält `metadata.windowsPoolMember` nach
`Schemas/windows-pool-member.schema.json` und ist die einzige Membership- und
Claimauthority. Die vorhandene Operationsdatei hält den vorlaufenden Intent
und Fortschritt. Es gibt keine Atomicity über beide Dateien: ein Intent ohne
Membercommit reserviert keinen Member; ein Memberclaim bleibt trotz fehlendem
Folgejournal, Crash, totem Worker oder Leaseablauf bestehen.

Vor der ersten Providerarbeit werden Prepare-Intent und Run/Scope/Pool/Index/
Instance/Artifact-Bindung gespeichert. Namenskonflikte werden vor Mutation
geprüft. VM-Notes enthalten nur Pool-ID und StateRoot-Locator. Der Locator
muss exakt zum unabhängig ausgewählten autorisierten Root passen, bevor dort
eine Datei geöffnet wird. Er autorisiert weder eine fremde Root noch einen
Claim. Fehlende Marker, Reparse-Pfade und geänderte Bindungen scheitern geschlossen.

Eine DataRoot-Migration, die den kanonischen StateRoot tatsächlich verschiebt,
ist vor Copy und Providermutation blockiert, solange dort Poolmitglieder
einschließlich `CONSUMED` bestehen. `REMOVED`-Tombstones sind nur bei frisch
belegter Abwesenheit einer gebundenen VM ausgenommen; unbekannte bzw.
inkonsistente Bindungen bleiben blockiert. Diese begrenzte Migration darf
keinen neuen Notesroot übernehmen oder implizit autorisieren. Eine Migration
ohne StateRootwechsel sowie der normale Lifecycle am ausdrücklich
ausgewählten CustomRoot bleiben möglich.

`PREPARING`, `FREE`, `CLAIMED` und `RECOVERY_REQUIRED` sperren allgemeine
Mutatoren. Nur die private, exakt gebundene Operation darf diese Mitglieder
ändern. `CONSUMED` und `REMOVED` erlauben den normalen Lifecycle. Zentrale
Run-State-Writes bewahren die aktuell kanonischen Membership-/Claimfelder und
verwerfen alte Memberrevisionen; alte Whole-Run-Snapshots können keinen
terminalen Zustand zu `FREE` zurücksetzen.
Öffentliches `Start-SqlServerLab` und `Stop-SqlServerLab` prüfen diese Sperre
vor Runtime-Abgleich und zustandsbedingter No-op-Rückgabe. Auch ein bereits
gestopptes, geclaimtes Mitglied liefert dabei `WINDOWS_POOL_MEMBER_RESERVED`.

Die sessionsübergreifende Rootmutex wird aus der normalisierten absoluten Root
abgeleitet (Windows: `Global\\`, ohne Groß-/Kleinschreibungsunterschied).
Volume-/Dateisystemwurzeln und Netzwerk-StateRoots sind ausgeschlossen: die
Mutex bietet keine hostübergreifende Exklusion für geteilten Netzwerkstate.
Diese Grenze betrifft ausschließlich Poolauthority. Allgemeine Nicht-Pool-
Runwriter erben sie nicht. Poolroots benötigen ein eindeutig lokales Fixed-
Volume, eine reguläre DOS-Volumeidentität und einen passenden finalen
Directoryhandlepfad. Gemappte Netzlaufwerke, SUBST-/Pfadaliases, Reparse-
Vorfahren und unbekannte Lokalität werden geschlossen abgewiesen. Die private
Probe liest nur diese Plattformidentität; sie startet keinen Provider.
Der kleine idempotente PowerShell-`Add-Type`/PInvoke-Shim ist ausschließlich
Windows-Plattforminterop für diesen Guard. Directoryhandles werden auch bei
Fehlern über `SafeFileHandle`/`using` geschlossen. Unverfügbare Interop lässt
Poollocality unbekannt und damit blockiert; Nicht-Pool-Import/Lifecycle bleiben
verfügbar. Die zurückgestellte C#-Beschaffungs-/Runner-/SQL-Sprachlane wird
dadurch nicht aufgenommen.
Read/Modify/Write der StateMachine und Member-CAS halten nur diese kurze Mutex.
Ihre zentrale Writer-Reentrancy verwendet dieselbe Mutex. Providerarbeit,
Secrets, Warten und andere Locks bleiben außerhalb. Die exklusive
Operationsmutex liegt außen und verhindert zwei Executor mit derselben ID.
Cleanup hält zusätzlich zuerst den ursprünglichen Operationsslot und dann
seinen eigenen Slot; es ersetzt keinen laufenden Claimworker.

Nur ein tatsächlich ausgeschaltetes, vollständig vorbereitetes, freies und
unclaimed Mitglied mit passender Notes-, VM-, Child-/Parent- und Schutzbindung
zählt als Reserve. Der neue Windows-Evidencevertrag gilt genau 24 Stunden ab
realer Gastcapture über strikt VM-ID-gebundene PowerShell Direct. Er bindet
Pool/Run/Scope/Instance/VM/Artifact, Preparationsrevision, Evidenceepoch und
den unveränderlichen Parentfingerprint. Alte `windowsActivation`-Metadaten
gelten nicht als Poolnachweis. Eine Providermutation invalidiert vorhandene
Evidence vor ihrer Ausführung. Warnfrist und Mindestrestlaufzeit sind
unabhängig; null ist eine gültige Reserve bzw. Mindestrestlaufzeit.
Fehlt bei der frischen Gastabfrage `EvaluationEndDate` oder wird ein Datum vor
1970 nach dem vorhandenen Lizenzvertrag als fehlendes Evaluationsende
normalisiert, darf der bestehende
Windows-Aktivierungsvertrag aus positiven `GracePeriodRemaining`-Minuten
und dem tatsächlich frischen `observedAt` das Ablaufdatum berechnen. Ohne
positive Grace, gültige Evaluation/Lizenz oder frische gebundene Capture
bleibt das Mitglied unbekannt. Persistierte alte Aktivierungsreceipts
werden dafür nicht übernommen.
Ein tatsächliches Enddatum ab 1970 behält Vorrang, auch wenn es bereits
abgelaufen ist. Unlesbare explizite Datumswerte führen weiter zum Fehler.

Kann eine Memberbindung nicht vollständig gelesen oder frisch nachgewiesen
werden, ist die Windows-Aggregatabdeckung `UNKNOWN`. Verfügbarkeit und
Defizit bleiben dann null; `WindowsVerifiedLowerBound` benennt nur die
tatsächlich belegte Untergrenze. Daraus folgt keine genaue Auffüllempfehlung.

Ein fehlender Notesmarker gewährt keine direkte Providermutation. Auch ein
Nicht-Pool-Run muss am unabhängig ausgewählten Root exakt zu Run/Scope,
Hyper-V-Provider, Instance und gespeicherter aktueller VM-ID passen. Fehlen
Run oder Connectionbindung, bleiben direkte Provideraktionen gesperrt.
Das ist die derzeitige Kompatibilitätsgrenze für ungebundene Legacy-VMs;
es gibt keine Rootsuche, Locatoradoption oder neue Ownershipregistry.
Eine separat beauftragte bewusste manuelle Hostdienststeuerung bleibt ein
eigener Auftrag. Neu erstellte VMs erhalten ihre initialen Notes unter der
prospektiven Run-/Ressourcenbindung vor der Connectionpersistenz.

CLI und GUI verwenden denselben Core und eine kurzlebige, opaque,
modulsitzungsgebundene Vorschau. Änderungen, Abbruch und Schließen verwerfen
die Vorschau. Apply revalidiert Root, Revision, Evidence und tatsächliche
gestoppte VM. Claim commitet atomar vor Providermutation. Release erfordert
belegt keine Providermutation. Consume hält den Claim bis SQL-Planpersistenz,
CPU/RAM-Postconditions und vorlaufendes Erfolgsjournal erfolgreich sind; erst
dann commitet `CONSUMED`. Fehler behalten eine Recoveryreservierung.

Cleanup ist eine separat bestätigte eigene Operation über den bestehenden
Cleanupvertrag. Sie revalidiert den eigenen Scope und darf auch nach einem
Crash vor Connectionpersistenz bzw. nach VM-Entfernung fortgesetzt werden.
Originalfehler und Fehler beim Recoverypersist bleiben getrennt. Es gibt kein
automatisches Löschen beim normalen Poolfehler und kein Freigeben durch
Worker-/Leaseheuristiken. `-LeaveRunning` hinterlässt ein vorbereitetes,
laufendes, weiterhin reserviertes Mitglied, keine verfügbare Reserve.
Prepare-Fehler bewahren getrennte feste Original-/Stopcodes. Runlokale
`windows-pool-cause-*.json` enthalten ausschließlich Code, Exceptiontyp,
Quelldateiname und Zeile samt eigener Bindung; keine Rohmeldungen, Stacks,
Secrets oder Gastdiagnosen. Der Native-Bericht bewahrt dieselben begrenzten
Fehlerdetails für Original- und Stopfehler getrennt.
Fehlgeschlagene Poolcapture ergänzt ausschließlich feste, allowlistgeprüfte
`captureMismatchCodes` im eigenen Cause-Receipt. Diese Codes benennen ungültige
Felder ohne beobachtete oder erwartete Gastwerte; die Capturebedingungen bleiben
unverändert. `PlanWindowsPoolMember` bindet die expliziten Workflowparameter
`RunId` und `StateRoot` an den kanonischen Membervertrag.

Eine eigene, separat bestätigte `Stop`-Mitgliedaktion revalidiert auch ein
laufendes gehaltenes Mitglied und stoppt es unter demselben Operationsslot.
Sie verwirft die Evidence und bewahrt die Reservierung. `Refresh` startet,
erfasst und stoppt ein gehaltenes Claimmitglied erneut; erst ein vollständiger
frischer Nachweis stellt `CLAIMED` wieder her. Release bleibt nach jeglicher
Providermutation gesperrt; Cleanup ist eine getrennte Bestätigung.

Der lokale synthetische Vertragstest umfasst Fehler vor und nach CPU/RAM,
Connectionpersistenz und Erfolgsjournal sowie echte Prozessrennen,
Root-Aliase und Workercrash. Diese Nachweise ersetzen keinen realen Windows-
2025-Poolnachweis. Native Ausführung benötigt eine ausdrücklich freigegebene
erhöhte Lane und einen verifizierten Desktop-Parent; sie wird separat erfasst.

Der Native-Harness bewahrt ursprüngliche Run/Scope/VM/Child-/Adapterbindungen
im lokalen Abnahmebericht bis zur abschließenden Absenceprüfung. Umbenennung
ersetzt keine Identität; fehlende Rediscovery oder State ergibt Recovery.
Erfolg verlangt VM-ID- und Notes-Scope-Absence, Child-VHDX-, Ownadapter-,
aktive eigene IPAM- und Secretverzeichnis-Absence sowie einen unabhängigen
vollständigen Parent-SHA256-/Längen-/Zeit-/Attributvergleich vor und nach
dem Lauf und erneute öffentliche Integritätsprüfung. Die testinternen
In-Memory-Bindings sind kein Membership- oder Claimregister.

Der Native-Harness bindet ein vorhandenes SQL-2025-Medium über expliziten
`MediaRoot`, relativen `SqlMediaPath` und `MediaEdition` (`Eval`, `Enterprise`
oder `Standard`). Der kanonische Resolver prüft Version und Edition; der
Harness prüft die absolute ISO-Datei und ihren tatsächlichen SHA256 gegen
das vorhandene Sidecar. Der Consume-Plan erhält ausschließlich den
kanonischen relativen Pfad. Das bestehende Mapping `EnterpriseDeveloper`
zu `Enterprise` beziehungsweise `StandardDeveloper` zu `Standard` bleibt
maßgeblich. Die explizite Pfadprüfung liest die Setup-Version über einen
temporären lokalen ISO-Mount in der erhöhten Lane; der Resolver entfernt
seinen eigenen Mount im `finally`. Dieser Nachweis installiert SQL nicht
und lädt keine Medien herunter.
Ein vorher vorhandener ISO-Mount wird weder übernommen noch entfernt. Der
Harness verlangt vor dem Resolver eine frisch belegte Detached-Bindung und
danach unabhängig die Abwesenheit seines eigenen Mounts. Ein unterdrückter
Dismountfehler oder unbekannte Attachment-Evidence blockiert vor jeder
VM-Mutation; Resolveroriginalfehler und Mount-Cleanupfehler bleiben getrennt.
