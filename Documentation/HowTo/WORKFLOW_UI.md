# Lokale Workflow-Oberfläche

## Zweck

### SA-Passwort bei neuen Container-Labs

**Neue SQL-Umgebung** prueft das eingegebene SA-Passwort und die Wiederholung
vor der Jobanlage. Standard sind 8 bis 128 Zeichen und drei Gruppen aus
Grossbuchstaben, Kleinbuchstaben, Ziffern und Sonderzeichen. Bei einem reinen
Laengenfehler auf einem neuen kurzlebigen SQL-2025-Container mit katalogisiertem
CU kann die Mindestlaenge fuer genau dieses Lab bewusst gewaehlt und bestaetigt
werden. Korrektur und Abbruch erzeugen keinen Job. Ein Manifeststart verwendet
immer die Standardkriterien. Der lokale Server prueft die Eingabe vor der
Jobanlage erneut; die Fachfunktion prueft vor State und Providermutation.
Nach der Erstellung liegt das SA-Passwort fuer spaetere Starts verschluesselt
run-lokal; der Browserjob und das Live-Log zeigen es nicht an.
Der echte Loopback-HTTP-Weg weist ungueltige Creationrequests vor dem Job ab.
Ein gueltiger Creationjob mit bewusster Mindestlaenge drei wurde im gerenderten
Browser fuer Docker und Podman getrennt bis zur SQL-Anmeldung und zum eigenen
Cleanup geprueft. Andere Mindestlaengen und CU-Images sind nativ offen.

### Container-Autostart nur vorprüfen

Unter **Lab verwalten → Container-Autostart vorprüfen · PLAN_ONLY** eine
registrierte laufende Docker-/Podman-SQL-Instanz und on/off auswählen,
dann **Autostartvorschau lesen**. Öffnen liest nur Metadaten des aktuellen
serverseitigen `Lab_Data`; Ziel- und Eingabewechsel lösen keinen Read aus.
Der vollständige Wunsch ruft denselben öffentlichen AutoStart-Core einmal auf;
zusätzliche eigene Ownership-Inspectreads bleiben erhalten. Feste ON/OFF-,
SAME_POLICY/DIFFERENT_POLICY-, UNKNOWN/DRIFTED- und Mountcount-Kategorien
zeigen kein Hostlogin oder SQL-Ergebnis. `CanApply=false`, `MutationAllowed=false`
und leere Actions gelten immer. Hostlogin, Endpoint, SQL, Backup und
Volumeeigentum bleiben NOT_CHECKED; Datenerhalt ist NOT_VERIFIED.
Keine Jobs, Reservierung oder Apply. Schließen/Escape, Bearbeitung und neue
Requests verwerfen späte Antworten; ein versandter Read darf fertiglaufen.
Die getrennten nativen CLI- und Browserdialogabnahmen unter Docker und Podman
sind bestanden. Der Browserlauf vom 2026-10-06 prüfte echte Loopback-HTTP-
Antworten, drei Vorschauaufrufe und eigenen Cleanup. Core77-Evidence ist
separat; Apply/Recovery und Scope A bleiben offen.

### SQL-Hostport nur vorprüfen

Unter **Lab verwalten → SQL-Hostport vorprüfen · PLAN_ONLY** werden ausschließlich
registrierte laufende Docker-/Podman-Ziele des aktuellen serverseitigen
`Lab_Data` gelesen. Geschützte, CMS-, Legacy- und fremde Ziele sind nicht
auswählbar. Öffnen liest nur Metadaten; Ziel- und Eingabewechsel lesen keine
Runtime. Erst ein vollständiges Ziel und Wunschport 1024–65535 mit bewusster
Vorschau rufen den unveränderten öffentlichen Portcore einmal auf.
Die Anzeige enthält feste Port-/Ausfallzeitkategorien und Mountcounts, keine
Istportzahl, Pfade, native IDs oder rohe Fehler. `CanApply=false`, leere
`Actions` und `NOT_CHECKED` für Endpoint, SQL, Backup und Volumeeigentum bleiben
sichtbar; Datenerhalt ist `NOT_VERIFIED`. Keine Jobs, Reservierung oder Apply.
Schließen/Escape, Bearbeitung und neue Requests verwerfen späte Antworten.
Bereits versandte lesende Aufrufe können weiterlaufen. Spezifische native
Preview-/Dialogabnahme und Port-Apply/Recovery bleiben getrennt offen.

### Collations im Katalog suchen

Unter **Lab erstellen → Collations suchen** SQL 2019, 2022 oder 2025 und
Suchwörter eingeben, dann bewusst **Suchen** wählen. Alle ASCII-Suchwörter
müssen in Name oder Locale passen; ohne solche Wörter erscheinen alle
Katalogeinträge. Die Ansicht zeigt höchstens 100 Treffer mit Metadaten und
weist auf weitere Treffer hin. `DEPRECATED` bleibt zulässig und wird gewarnt.
Die Suche prüft keinen SQL-Server (`NOT_CHECKED`) und übernimmt keine Auswahl
ins Manifest. Öffnen und Bearbeiten suchen nicht automatisch. Eingaben bleiben
im RAM; Zurück/Escape verwirft auch späte Antworten. Eine angeforderte lesende
Suche kann dabei weiterlaufen; Abbruch ist kein Nachweis ihrer Beendigung.

### Evaluation-Ersatzentscheid

Unter **Wartung, Aufräumen und Recovery → SQL-Evaluation: Ersatzentscheid**
ein vorhandenes registriertes `Lab_Data` eingeben und **Registrierte Instanzen
lesen** wählen. Eine gebundene einzelne Hyper-V-SQL-Instanz und Slotersatz,
Rekonstruktion oder Instanzmigration auswählen, dann **Vorschau lesen (keine
Änderung)**. Die Auswahl wird vor dem öffentlichen Plan erneut geprüft.
Windows- und SQL-Quelle, Evidencealter, Frist und Resttage erscheinen getrennt.
Alle Modi bleiben `BLOCKED`, SQL ist `NOT_CHECKED`; historische Windows-
Aktivierung ist keine frische Lizenzprüfung. Die festen Blocker und nächsten
Schritte geben keine Transfer- oder Ausführungsfreigabe. Der begrenzte Reader
liest höchstens 64 Run-Verzeichnisse, kein globales Watch-Inventar. Eingaben
bleiben im RAM; Zurück/Escape und späte Antworten erstellen keine Jobs.

### External Languages vor einer Lab-Erstellung

Unter **Lab erstellen → Python / R / Java: Katalog und Hostvoraussetzungen**
Docker oder Podman und SQL-Version wählen, dann **Katalogvarianten lesen**.
Python-, R- und Java-Varianten mit Sperrgrund bleiben sichtbar; nur unterstützte
Varianten sind auswählbar. **Katalogentscheidung anzeigen** prüft keinen Host.
**Hostvoraussetzungen bewusst lesend prüfen** beobachtet den gewählten Provider
einmal; `READY` ist keine SQL-Sprachabnahme oder Zielautorisierung.
SQL 2025 shared-user-v2 besitzt keine Launchpad-Sandbox. Öffnen oder Ändern
fragt keinen Host ab. Zurück/Abbruch und Escape verwerfen den RAM-Entwurf und
ignorieren späte Antworten; eine laufende lesende Prüfung wird nicht gestoppt.
Kein Speichern, Apply, Job, Manifestübernahme oder Start. Der Prozess hat
20 Sekunden Ausführungsbudget plus bis zu fünf Sekunden Terminierungsversuch,
kein Gesamt-HTTP-/Listener-Zeitlimit. [Vertrag](../Architecture/EXTERNAL_RUNTIME_CAPABILITY.md).

### Komponentenrelationsvorschau

Unter **Verbindungen und CMS → SQL-Komponenten: geführte Vorschau**
ein vorhandenes registriertes `Lab_Data` eingeben und **Registrierte Runs lesen**
wählen. Eigener Run und verbrauchende SQL-Instanz werden aus gebundenen lokalen
Metadaten ausgewählt; als Voraussetzung ist eine eigene Instanz oder genau eine
bereits verwaltete Shared-SQL-Referenz möglich. **Vorschau lesen** ruft ausschließlich
den öffentlichen PLAN_ONLY-Core auf. `RUNNING` beweist keine SQL-Bereitschaft:
`NOT_CHECKED`, `PRESERVE` und die gesperrte Ausführung werden ausdrücklich gezeigt.
Eingaben bleiben im RAM; Zurück/Abbruch verwirft sie. Kein Apply, Job, Export,
SQL-Zugriff oder Providerinventar. Nach geänderten Metadaten erneut lesen;
späte Antworten können eine verworfene Auswahl nicht wiederherstellen.

### llama.cpp-Runtimeinstallation

Unter „Ressourcen und Downloads“ öffnet „llama.cpp-Runtime installieren / prüfen“
den gemeinsamen Fachdialog zum kuratierten experimentellen Windows-x64-CPU-Pin
b11247. Release und vorhandenen Lab_Base wählen, Vorschau lesen und Download,
Extraktion sowie feste modellfreie `--version`-Probe separat bestätigen.
OS-/Architektur-/Backendalternativen bleiben ausdrücklich offen. Lokales Neulesen
startet keinen Download; die Online-Metadatenprüfung ist eine eigene Aktion.
No-op/Abbruch schreiben nichts. Fehlende VC/UCRT-Voraussetzungen, Drift und offene
Recovery sperren, ohne Prerequisites zu installieren. Empfehlung `UNASSESSED`;
`BINARY_PROBE_PASSED` wäre ausschließlich Paketausführbarkeit, Compute/SQL/Modelle
bleiben `NOT_CHECKED`. Native Probe ist derzeit `NOT_EXECUTED`.
Details: [Installervertrag](../Architecture/LLAMA_CPP_INSTALLER.md).

### Wartungsbefunde und Katalogzuordnung

Im Wartungsbereich öffnet „Wartungsbefunde und Zuordnung“ denselben Fachablauf
wie die CLI-Aktion `CleanupAudit`. Erst „Befunde lesen“ ruft das Audit mit
`-NoWrite` auf. Einträge zeigen Herkunft, Nutzung, Löschbarkeit und nächsten
Schritt getrennt. Unregistrierte Objekte bleiben unbekannt; ein Orphan-Befund
ist keine Löschfreigabe. Fehlende Providerinventur und unlesbare Run-States
werden angezeigt; unvollständige Run-/Referenzevidence sperrt Katalogrepair.

Nur ein moderner, terminaler ursprünglicher Docker-/Podman-SQL-Store kann
separat vorgeprüft und nach eigener Bestätigung im Katalog ergänzt werden.
Vorschau und Bestätigung binden serverseitig Originalstate, Controller, Roots,
Runtime-Scope, Volume-Wiederanlageidentität und Katalogrevision. Konflikte,
Attachments, Sidecars, Leases, aktive Referenzen, Schutzgruppen und Recovery
blockieren. Passende bestehende Zuordnung ist ein frisch geprüfter No-op.
Die bestehenden Registrylocks werden in kanonischer Reihenfolge vor dem
Kataloglock bis zum Commit gehalten. Nach der letzten nativen Beobachtung
prüft der Mutationcallback Referenzen, Recovery und Autorität erneut.
Es werden keine Daten oder Runtimeobjekte repariert, übernommen oder gelöscht.
Bei einem unbestätigten Ergebnis zuerst erneut lesen und vorprüfen.

Retained-Löschung verwendet weiterhin ihren separaten Plan/Executor und bei
Resume dieselbe OperationId. Die native Löschabnahme bleibt gesondert offen.

### Geschützte Testgruppe: Power-Start/Stop

Im Bereich Testsystem-Matrix öffnet „Gruppe ansehen · Power-Start/Stop“ die
tatsächlich registrierte Gruppe des kanonischen Exportroots. Nach der Auswahl
zeigen Mitglieder und Gesamtstatus den gemessenen Container-/VM-Powerzustand.
SQL-Bereitschaft bleibt ausdrücklich **nicht geprüft**. Starten oder Stoppen
betrifft die gesamte Gruppe; die Ist-/Zielvorschau muss gesondert bestätigt
werden. Eine neue Auswahl oder Aktualisierung verwirft die Bestätigung.

Der gemeinsame CLI-/GUI-Core bindet Registry, Roots, Mitglieder und feste
Runtime-IDs. Geänderte Vorschauen, unbekannte Zustände, Mehrinstanz-Runs,
zusätzliche Runtimeobjekte und ungeklärte Recovery sperren Apply. Abbruch und
No-op verändern nichts. Ein Teilfehler bleibt im Meldungsbereich je Mitglied
sichtbar; Wiederholung erfordert eine neue Vorschau. Bei verlorener Antwort
ist das Ergebnis unbestätigt, nicht automatisch wirkungslos.

Dieser Powerpfad verwendet keine SQL-Dienst-, Lizenz-, Export-, CMS-,
ConnectionCenter- oder Hostspeicheraktion. Vorhandener Autostart innerhalb
eines gestarteten Containers oder Gasts kann Dienste starten. Persistierte
Run-/Exportstatus werden hier nicht neu geschrieben. Der bestehende öffentliche
Gruppenbereitsteller mit SQL-Prüfung behält seine eigene Semantik.

Die lokale Browser-Oberfläche fasst vorhandene Windows-OS-Baselines,
Windows-Builder, SQL-Prepared-Images, Abnahmeumgebungen und aktive
Container-Labs in einer Sicht zusammen. Sie zeigt pro Build den nächsten
zulässigen Schritt statt nur interner Zustandsnamen.

Die Oberfläche ist ein zweiter Einstieg über denselben PowerShell-Core. Sie
enthält keine eigene Provisionierungslogik.

Die Navigation bietet neun fachliche Bereiche: Lab-Umgebungen, geschützte
Testsystem-Matrix, Hyper-V-Vorlagen und Slots, Ressourcen und Downloads,
Host-Dienste und Modelle, Verbindungen und CMS, SQL-Lab-Grundkonfiguration,
Wartung/Recovery und Vorgänge. Inaktive Inventare sind ausgeblendet; technische
Secret-Parameter unter Host-Dienste sind zusätzlich eingeklappt. Zurück
wechselt in den vorherigen Bereich ohne Formulare zu löschen. Ein Refresh
behält Bereich und ungespeicherte Eingaben. Expertenbefehle und Meldungen
haben eigene Einstiege. Ressourcen öffnen den bestehenden Quellen-/Speicherortdialog;
**SQL-2022/2025-Bootstrapperquellen bearbeiten** bietet die sechs festen
katalogisierten Bootstrapper zur Auswahl. Vorschau, Bestätigung und gezielter
Reset verwenden dieselbe lokale Preferences-Authority; sie laden oder starten
kein Medium. [Bedienung und Grenzen](../User/Getting_Started.md#lokale-sql-20222025-bootstrapperquellen).
Grundkonfiguration bietet einen eigenen gemeinsamen Plan-/Apply-Pfad. Die Verbindungsansicht zeigt nur
vorhandene Host-/Port-Felder. Bei Hyper-V werden Host und Port eng aus dem führenden Serverfeld des Connection Strings und TcpPort projiziert; Credentials und Connection Strings werden hier nie angezeigt. Fehlende oder nicht unterstützte Werte bleiben unbekannt; ein Verbindungstest wird nicht behauptet.

Die geschützte Testmatrix besitzt den oben beschriebenen Power-Fachdialog.
Für den bereits registrierten CMS bietet der Verbindungsbereich eine ausdrückliche
lesende Prüfung mit Zeitpunkt und markierten Metadatenzählern. Registrierung
lesen und Dialog schließen führen keine SQL-Prüfung aus. Der gemeinsame
[CMS-Vertrag](../Architecture/CMS_READONLY_INSPECTION.md) begrenzt Provider,
Bindung und unbekannte Ergebnisse. CMS-Setup und Synchronisation im Browser
sowie weitere geführte Browser-Gruppenaktionen,
operative Slots, vollständiges Provider-Setup und Fremdstart-/weiterer
Hostdienst- sowie Modell-Lifecycle bleiben offen. Der eigene llama.cpp-
Sitzungsstop besitzt den unten beschriebenen Fachdialog. Der Navigationseinstieg ist keine Abnahme
dieser fehlenden Funktionen.

Der Arbeitsbereich **Alle Funktionen** wird aus demselben Export- und
Parameterkatalog erzeugt wie **Alle öffentlichen Befehle** in
`Invoke-SqlServerLab`. Damit ist jeder veröffentlichte Modulbefehl auch im
Browser erreichbar. Suche und Fachbereichsfilter führen zum Befehl; danach
zeigt die Oberfläche dessen echte Parametersätze, Pflichtfelder, Standards und
zulässige Werte. Neue Exporte erscheinen ohne zweite manuell gepflegte
GUI-Befehlsliste.

Ändernde Befehle verlangen den einheitlichen Bestätigungsdialog. Eingaben mit
Geheimnissen werden nur an einen flüchtigen Hintergrundjob übergeben, niemals
in die persistente Queue geschrieben. Befehlsname und Parametersatz müssen im
frisch erzeugten Katalog enthalten sein; freie PowerShell-Befehlszeilen nimmt
die Browser-API nicht an. Ergebnisse werden vor der Ausgabe rekursiv um
Kennwörter, Credentials, Tokens, Secrets und Connection Strings bereinigt.

Der Grundkonfigurationsdialog liest Lab_Base-Herkunft und registrierte
Lab_Data-Roots einschließlich ungültiger Einträge. Er ergänzt fehlende Roots
und wählt den globalen Standard für künftige Vorgänge. Ein gültiger Media-Root
bleibt erhalten. Vorschau und Abbruch erzeugen keine Ordner oder Queueeinträge;
erst **Angezeigten Plan revalidieren und anwenden** führt den gemeinsamen Core
aus. Änderungen an Eingaben oder Schließen verwerfen die Vorschau.
Providerrefresh prüft ausschließlich den ausdrücklich gewählten Provider über
den vorhandenen Readinessvertrag, ohne Installation, Start oder Änderung von
Bindings. Statuslesen prüft weder Schreibbarkeit noch Kapazität. Die separate
Schreibprobe verlangt Vorschau und Bestätigung. **Freien Speicher lesen** liest
ausdrücklich genau die ausgewählte registrierte Lab_Data-Location und zeigt
Datenträgerfrei mit Zeitpunkt. Unbekannt, unlesbar oder nicht unterstützt bleibt
ohne Bytewert. Diese Hostdatenträger-Momentaufnahme reserviert nichts und
bestätigt weder Schreibbarkeit noch native Container-Volumes. Dieser kurze Pfad
läuft direkt im lokalen Server; seine begrenzte Providerprüfung kann die
Annahme weiterer Anfragen vorübergehend verzögern.

Die Workflow-Inventur (ISO-, Image- und Runtime-Erkennung) läuft getrennt von
der HTTP-Annahme eines Klicks. Nach einer Aktion schließt der Dialog daher
sofort; Auftragsbestätigung und belegte Statusmeldungen erscheinen
unmittelbar. Die möglicherweise langsamere vollständige Inventur wird danach
im Hintergrund aktualisiert.

### Angenommene Aktionen und belegter Status

„Angenommen · Start unbestätigt“ bestätigt nur die Übergabe. `/api/jobs` führt
Thread-Jobs und die in dieser Serversitzung angenommenen persistenten Batches
zusammen. Jeder Batch bleibt an den beim Annehmen verwendeten StateRoot
gebunden, auch wenn `SetDataRoot` danach den Default verändert. Der Poll liest
höchstens 64 gebundene Kindvorgänge je Batch, ohne Storeinitialisierung,
Scheduler, Recovery oder Hoststart. Kindstatus unterscheiden Wartend,
Blockiert, servergemeldetes Running, Erfolgreich, Fehlgeschlagen und Abgebrochen.
Ein Running-Status beweist weder CPU-Arbeit noch SQL-Bereitschaft. Ein
Batch-Summarystatus allein ist kein Laufnachweis; es gibt keinen künstlichen
HEARTBEAT und keine simulierte Fortschrittsanimation. Persistente Karten zeigen
keine aus ihrer Annahmezeit oder Queuewartezeit abgeleitete Ausführungslaufzeit.

Fehlende, widersprüchliche oder unlesbare Statusdaten werden als Unbekannt
angezeigt. Eine fehlgeschlagene oder länger als fünf Sekunden ausbleibende
Statusantwort zeigt „Verbindung verloren · Status unbekannt“; eine verspätete
Antwort überschreibt keinen neueren Stand. Bereits bestätigte Terminalkarten
bleiben in Browser und Serversitzung erhalten. Der Server hält höchstens 256
eigene Batchzuordnungen und lehnt weitere vor dem Enqueue ab, statt Ergebnisse
zu verdrängen. Nach Serverneustart werden keine beliebigen alten Batches gesucht.

Ein Fehler beim OperationHoststart erscheint getrennt; er schreibt einen
angenommenen Queuevorgang nicht auf Failed um. Bei POST-Ausfall oder Timeout
nach 15 Sekunden bleibt die Annahme unbekannt: keine automatische Wiederholung.
Noch offene oder unbestätigte Action-/PublicCommand-Übermittlungen an dasselbe
nicht sensible Ziel
werden im Browser gegen Doppelclick und erneutes Rendering geschützt; nach
bestätigtem Terminalstatus ist eine bewusste Wiederholung möglich. Der Schutz
gilt innerhalb der Browserseite, nicht als globale Idempotenzgarantie über
Server-/Browserneustarts. Parameter, Secrets und Logs werden dafür nicht in
Browserstorage geschrieben. Vor dem Hashing tragen ausschließlich fest
erlaubte nicht sensible Ziel-/Rootmerkmale zur Identität bei; unbekannte und
verschachtelte Eingaben werden weggelassen. Bei generischen Befehlen muss auch
die Parametermetadatenprojektion den skalaren String als nicht sensibel
bestätigen. Kennwort- oder Credentialänderungen erzeugen keinen neuen Dedupekey;
Hashkeys sind keine kennwortabgeleiteten Verifier. Andere Eingabeänderungen
am selben Ziel können daher ebenfalls bis zum bestätigten Abschluss blockieren.

## Start

Im Repository unter PowerShell 7 starten:

    ./Tools/Start-SqlServerLabUi.ps1

Danach wird die Oberfläche unter http://127.0.0.1:8484 geöffnet. Sie lauscht
ausschließlich auf der Loopback-Adresse; ein Zugriff aus dem Netzwerk ist nicht
vorgesehen. Die normale Sitzung startet nicht erhöht. Read-only-Aktionen laufen
als Benutzer, Container-Lifecycle-Aktionen mit den vorhandenen Runtimerechten.
Eine privilegierte Hyper-V-Aktion zeigt zuerst Zweck und Umfang an und öffnet
erst nach ausdrücklicher, standardmäßig abgelehnter Bestätigung einen separaten
Administratorprozess; die aktuelle Sitzung bleibt unverändert. Vor dieser
Bestätigung werden die stabile Storage-Location, der registrierte
`Lab_Data`-Root, der beobachtete freie Speicher und die physischen Run-, Build-,
Image-, Staging- und Recovery-Klassenroots angezeigt. Der erhöhte Prozess
erhält diese geheimnisfreie Vorschau explizit und revalidiert Controller,
Location, Volume und Root gegen die lokale Registry. Geänderte Evidence
blockiert vor der ersten Hyper-V-Mutation.

## Workflow

1. SQL-Prepared-Image: Windows- und SQL-ISO auswählen und Windows einmal in
   einer frischen Builder-VM installieren. Nach der sichtbaren Bestätigung der
   Windows-Installation führt die Oberfläche SQL `PrepareImage`, benötigte
   Neustarts, finalen Sysprep und die Veröffentlichung automatisch aus.
2. OS-Baselines werden einmal manuell installiert und generalisiert. Danach
   können sie direkt als reine Windows-VM geklont werden; dieser Klon führt
   automatisierte OOBE aus, aber keine SQL-Operation.
3. Abnahme: Die Übersicht listet run-lokale Windows-/SQL-Abnahmeumgebungen
   samt ihrem Testzustand.
4. SQL-basierte Hyper-V-Klone konfigurieren nach SQL `CompleteImage` automatisch
   den SQL-WMI-Provider, eine feste IP im gewählten Lab-Switch, SQL-TCP und
   eine auf den Host begrenzte Firewallregel. Der ausgegebene Connection String
   ist damit für SSMS und Host-Anwendungen nutzbar. Bewusst isolierte VMs
   bleiben davon ausgenommen.
5. Bei neuen Hyper-V-Labs kann **VM beim Hochfahren des Hyper-V-Hosts
   automatisch starten** aktiviert werden. Die Übersicht zeigt den wirksamen
   Zustand als `Autostart: ein|aus`; ohne Auswahl bleibt er ausgeschaltet.
6. Neue Docker-/Podman-Labs bieten dieselbe Option. Die Runtime erhält eine
   Restart-Policy; auf Windows startet der verwaltete Auftrag sie nach der
   Benutzeranmeldung und fährt nur entsprechend markierte Lab-Container hoch.

Gastpasswörter werden nur für den jeweiligen PowerShell-Direct-Aufruf
entgegengenommen. Sie werden nicht im Build-State, Browser-Speicher oder
Live-Log gespeichert.

## Evaluationsfristen lesen

**Evaluationsfristen** öffnet einen read-only Fachdialog. Erst **Fristen lesen /
aktualisieren** liest `Get-SqlServerLabEvaluationWatch` mit 30 Tagen Warnfrist
und 7 Tagen kritischer Restlaufzeit. Danach lässt sich eine Vorlage oder Instanz
auswählen; manuelle Run-, Instanz- oder Artifact-IDs sind nicht erforderlich.
Die Details trennen Geltungsbereich, Referenz, Bewertung, Quelle, Aktualität,
Frist, Resttage und nächsten Schritt. Die Konsole bietet denselben Ablauf unter
**Wartung und Diagnose → Windows-/SQL-Evaluationsfristen**.

Die Sicht gilt für den konfigurierten State-Root: registrierte Hyper-V-Vorlagen,
Windows-Instanzen im registrierten Zustand `RUNNING` sowie SQL-Instanzen in
`RUNNING` oder `STOPPED`. Sie ist kein vollständiges Hostinventar. Lesezeit und
Ablaufdatum belegen keine Aktualität der zugrunde liegenden Evidence. Windows-
und Vorlagenwerte bleiben historische Metadaten; SQL-Gast-Evidence wird durch
den bestehenden Core auf Bindung und Aktualität geprüft. `UNKNOWN`, veraltete
Evidence und eine leere Liste sind kein Nachweis gültiger Lizenzen.

Auswahl, Zurück, Schließen und Wiederholung verändern weder Runs noch Lizenzen
oder Ereignisdateien. Der Dialog startet keine Runtime oder geschützte
Testgruppe, liest keinen Gast, registriert keinen Zeittrigger und führt keine
Ersatz- oder Migrationsaktion aus. Fehler zeigen eine erneute Lesemöglichkeit
mit Hinweis auf State-Konfiguration und Leserechte; alte Ergebnisse werden
verworfen. Nichtinteraktiv bleibt der unveränderte öffentliche Aufruf möglich:

```powershell
Get-SqlServerLabEvaluationWatch -WarningDaysRemaining 30 -CriticalDaysRemaining 7
```

## Container und Bereinigung

Container-Labs lassen sich ad hoc, aus einem gespeicherten Manifest oder über
die konsistente Mehrfachauswahl von katalogisierten Testdatenbanken erstellen.
Die Datenbankauswahl arbeitet eine ausgewählte Liste nacheinander ab und
fordert für Quellen ohne hinterlegten SHA-256 eine explizite einmalige
Vertrauensfreigabe. Im selben Dialog kann ein kompatibles, verifiziertes Backup
aus der konfigurierten `Lab_Data`-Bibliothek gewählt werden. Browser und Aktion
übergeben dabei ausschließlich die stabile `BackupSetId`; der gemeinsame
Restore-Core löst Pfad und Hash intern auf und prüft sie unmittelbar vor dem
Restore erneut. Die Bibliotheksübersicht selbst liest nur kleine Metadaten und
hasht nicht bei jedem UI-Refresh alle Backup-Dateien. Der Menüpunkt **Alles
aufräumen** zeigt vor dem Start eine
Bestätigung und führt ausschließlich die hinterlegten Cleanup-Pläne aus;
persistente Data-Root-Inhalte und veröffentlichte Hyper-V-Images bleiben
erhalten.

Die Auswahl zeigt für jedes ausführbare Sample den read-only Trust- und
Cache-Status. Fehlt eine Katalog-SHA-256, zeigt sie erst
**SHA-256-Freigabe erforderlich**. Nach einer ausdrücklich bestätigten ersten
Bereitstellung wird die automatisch berechnete SHA-256 lokal an genau diese
Sample-Variante gebunden; spätere Inventuren zeigen **lokale SHA-256** und bei
vorhandenem verifiziertem Inhalt **Cache bereit**. Die Oberfläche erhält dabei
weder den Hashwert noch Trust-Store-, Cache- oder Hostpfade und kann keinen
Trust erzeugen. Der Startpfad prüft den lokalen Record erneut, sodass die
Anzeige keine Sicherheitsentscheidung ersetzt.

Die Datenbankpaket-Ansicht arbeitet ebenso pfadfrei. Für ein auswählbares,
nicht TDE-geschütztes Paket kann genau ein laufender Hyper-V-SQL-Run gewählt
werden. Erst nach Eingabe des flüchtigen Gast-Credentials revalidiert der
gemeinsame Core Paket, VM-Eigentum, SQL-Version, FILESTREAM-Capability,
Datenbankname und Zielzustand. Das Ziel wird live aus SQLs Default-Data-
Verzeichnis abgeleitet; ein Host- oder Gastpfad kann nicht eingegeben werden.
Die Paketkopie wird im Gast vollständig gehasht und erst danach attached.
Die Katalogauswahl zeigt außerdem nur den Status, die Schrittzahl und die
Blocker des beim Paket erfassten nicht ausführbaren Migrationsplans. Diese
Planprojektion gehört zum hashgebundenen Paketmanifest; sie erteilt keine
Transfer- oder Mutationsautorität.

Die Aktion **Migrationsabhängigkeiten prüfen** bleibt gleichfalls read-only.
Ihr Live-Log zeigt das sanitisierte Inventar zusammen mit dem versionierten
`SqlServerLab.DatabaseMigrationExecutionPlan/1.0`. Der Browser akzeptiert und
rendert diesen Plan nur als `DATABASE_FILES_ONLY` mit
`MutationAllowed=false` und `TransferAuthority=NONE`; seine Kategorie-Schritte
und TDE-Blocker sind Hinweise für getrennte manuelle Arbeit, keine Export-,
Import- oder Transferaktion.

## Einheitliche Umgebungsaktionen

Containerkarten nennen jede Instanz ausdrücklich. Der gemeinsame SQL-Aktionsdialog
zeigt vor der Eingabe Umgebung, Instanz, Provider und SQL-Version aus dem aktuellen
Inventar. Fehlende Metadaten erscheinen als „unbekannt“; bei benannten Hyper-V-
Instanzen ohne eigene Versionsmetadaten wird keine Version geraten. Diese Anzeige
ändert weder die technische Zielbindung noch die serverseitige Prüfung.
Die statische UI-Suite führt hierfür zusätzlich das echte JavaScript mit
synthetischem Inventar und einem DOM-Testdouble aus. Sie benötigt Node.js 18
oder neuer, aber keine npm-Pakete, Browserinstallation oder laufenden Provider.
Fehlender Node wird als nicht ausgeführter Nachweis gemeldet und blockiert den
UI-Gate; eine Installation erfolgt nicht automatisch.

Docker-, Podman- und Hyper-V-Labs zeigen den tatsächlichen Laufzeitstatus sowie
ihre Connection Strings. **CPU und Speicher ändern** ist für alle drei
Provider verfügbar: Container übernehmen ihre Limits direkt; bei Hyper-V muss
die VM ausgeschaltet sein und erhält einen begrenzten dynamischen Bereich
(mindestens 1 GB bzw. die Hälfte des Startwerts, maximal das Doppelte). Die
Hyper-V-Verwaltung ergänzt nur die Windows-/SQL-spezifischen Aktionen wie
VMConnect, Daten-VHDX oder WMI-Reparatur.

Katalogisierte Hyper-V-Daten-VHDX werden ausschließlich per stabiler
`PersistentStorageId` ausgewählt. **Sauber freigeben** prüft im laufenden Gast
alle SQL-Dateibindungen unter dem Datenpfad und fährt die VM nur bei fehlenden
aktiven Datenbankdateien herunter. **Reattach** und **Klonen** verlangen einen
weiterhin zur unveränderten VHDX passenden Detach-Receipt sowie eine kompatible
ausgeschaltete SQL-VM. Dieselben Aktionen sind ohne Hostpfade über die CLI
aufrufbar, zum Beispiel:

```powershell
Invoke-SqlServerLabWorkflowAction `
    -Action ReattachHyperVPersistentData `
    -PersistentStorageId '<storage-guid>' `
    -BuildId '<target-run-guid>'
```

Ein Reattach bindet nur den Datenträger. Vorhandene Datenbankdateien werden
erst über eine ausdrückliche Restore- oder Attach-Aktion online gebracht.

## Namen in Runtime und Oberfläche

Der frei wählbare Projektname ist zugleich der führende Teil der Runtime-Namen.
Neue Docker- und Podman-Container heißen
`projektname-instanz-runid`, reguläre Hyper-V-VMs `Projektname-RunId`.
Die kurze Run-ID verhindert Kollisionen bei gleichen Projektnamen. Eine spätere
Umbenennung aktualisiert Container beziehungsweise die ausgeschaltete Hyper-V-VM
sowie Verbindungsdaten und Cleanup-Plan. Docker und Podman dürfen dabei laufen;
eine Hyper-V-VM muss vorher gestoppt werden.

## Plattformen

Die Oberfläche kann mit PowerShell 7 unter Windows und Linux gestartet werden.
Docker und Podman bleiben plattformabhängig nutzbar. Hyper-V-Schritte sind nur
auf einem lokalen Windows-Hyper-V-Host verfügbar und werden sonst deaktiviert.

Die Steuerung eines entfernten Windows-Hyper-V-Hosts ist bewusst noch nicht
implementiert; die fachlichen Vorbedingungen stehen im
[Remote-Hyper-V-Host-Backlog](../Project_Planning/HYPERV_REMOTE_HOST_BACKLOG.md).

## Geführte CPU/RAM-Änderung (`UX-202/622`, `CNT-211` bis `CNT-214`, `HV-601` bis `HV-607`)

CLI `Set-LabResourcesInteractive` und GUI `openResourceDialog` wählen eine
konkrete gewöhnliche Lab-Instanz samt Provider. Der gemeinsame read-only
`Get-LabResourceChangePlan` zeigt gemessene Istlimits und gewünschte CPU/RAM-
Werte. Die GUI liest über `/api/resource-change`; vor Apply ist eine aktuelle
Vorschau erforderlich. Cancel und No-op rufen keinen mutierenden Executor auf.

Die CPU/RAM-Vorschau zeigt im Browser und PowerShell-Menü für Docker und Podman außerdem die gemessene Anzahl
von Volumes, Host-Bindings, schreibbaren Host-Bindings und anderen Mounttypen.
Sie verwendet dasselbe bereits gelesene Inspect; eine weitere Runtime-Abfrage
ist dafür nicht nötig. Fehlende oder ungültige Mountdaten bleiben unbekannt;
eine ausdrücklich leere Liste zeigt 0. Volumeeigentum und Sicherung sind nicht
geprüft. Für Hyper-V ist diese Mountanzeige nicht verfügbar. Eingabeänderung,
Zielwechsel und Abbruch verwerfen auch die Mountanzeige der alten Vorschau.
Das PowerShell-Menü zeigt die Anzahlen mit dem Istplan und erneut mit der
angeforderten Vorschau vor der Bestätigung. Beide verwenden jeweils nur den
bereits gelesenen gemeinsamen Plan; die Anzeige führt keine weitere Abfrage aus.

Der instanzgebundene Container-Apply verwendet `Update-SqlServerLabContainer`
mit `ExpectedResourcePlanKey`, nur CPU und MemoryMB. Er serialisiert pro Run,
normalisiert Root-Aliase, prüft stabile Run-/Providerzustände, Schutzstatus,
offene/fremde/ungültige Journale sowie die Bindung an
Runtime-ID, Lifecycle, Istwerte, Ports, Restartpolicy und Mounts erneut. Live-Apply
und Live-Rollback adressieren die unveränderliche Container-ID; ein wiederbelegter
alter Name darf keinen Nachbarn treffen. Laufende Container
übernehmen Limits live; gestoppte bleiben gestoppt. Autostart, Ports und SQL
max memory werden nicht als zusätzliche Änderungen übergeben.

Fehlende, unbegrenzte, widersprüchliche oder nicht als NanoCPU beziehungsweise
positive Quota/Period und ganze MB nachgewiesene Limits
bleiben unbekannt und sperren Apply; gespeicherte Ersatzwerte sind kein
Istnachweis. Hyper-V bietet nur Ist-/Zielvorschau, keinen Apply: Die dauerhafte
Sollzustandsautorität für neue Werte und der journalisierte Teilfehler-/Recovery-
Vertrag bleiben unter den bestehenden HV-IDs offen. DynamicMemory und Min/Max
werden nicht verändert. Am 2026-09-28 bestanden Docker und Podman getrennt jeweils neun native
SQL-2025-Prüfungen des neuen Plan-/Workflow-Apply-/No-op-/Driftpfads samt
SQL-Probe und bestätigtem Own-Runtime-Cleanup. Das belegt Container-CPU/RAM,
keinen Hyper-V-Apply und keine weiteren Eigenschaften oder Versionspaare.

## Zentrale Slotreservepolicy (`HV-401` bis `HV-508`, `CORE-107/111`)

**Grundkonfiguration** und **Hyper-V: Vorlagen und Slots** öffnen denselben
Dialog **Slotreserve: Policy und Kandidaten**. Windows- und SQL-Zielreserve
(je 0–100), Mindestrestlaufzeit und separate Warnfrist (je 0–3650 Tage) sind
Advisory-Werte. Null ist ein ausdrücklich gespeicherter Zielwert; eine fehlende
oder ungültige Policy wird davon unterschieden. Versions-, Ressourcen- und
Localeprofile, Budget, Parallelität und Erneuerung bleiben Folgearbeit.

Vorschau und Abbruch schreiben nichts. Erst das ausdrückliche Speichern prüft
Speicherautorität und bisherigen Preferences-Inhalt erneut. Die Policy liegt
als `slotReservePolicy` in derselben durch `Get-LabProjectPreferencesPath`
aufgelösten lokalen Preferences-Datei wie die bestehenden Einstellungen.
Alle Writer verwenden einen gemeinsamen dateigebundenen Lock und atomaren
Merge; andere Felder bleiben erhalten. Ungültiges JSON und ungültige Policies
werden nicht automatisch repariert. Ein Wechsel des globalen Datenroots
migriert keine Preferences; die anschließend aufgelöste Authority wird neu gelesen.

Die Bestandsansicht liest registrierte Hyper-V-Kandidaten und gebundene aktive
Vorgänge, einschließlich gestoppter Runs. Eine Vorgangsbindung ist keine
Poolreservierung. Windows-Fristen bleiben historische Aktivierungsmetadaten;
SQL-Fristen verwenden den vorhandenen gebundenen Receipt-/Aktualitätsvertrag.
Warnfrist und Mindestrestlaufzeit sind getrennte Bewertungen. Unbekannte,
ablaufende, belegte oder vorgangsgebundene Kandidaten zählen nicht als frei.
Da dauerhafte Poolmitgliedschaft und Slotclaims fehlen, bleiben bestätigte
Verfügbarkeit, Defizit und exakte Auffüllzahl ausdrücklich unbekannt. Bei
Nullreserve lautet die Aussage nur „keine Reserve angefordert“; sie belegt
keinen gesunden Pool. Auffüllempfehlung ist zunächst die Aufforderung,
Poolzugehörigkeit und Claims zu prüfen. Es gibt keine automatische Auffüllung,
Slot-/VM-Erstellung, Installation oder Provideraktion.

CLI: `Invoke-SqlServerLab -Action ReservePolicy`. Nichtinteraktiv bietet
`Invoke-SqlServerLabWorkflowAction` die Aktionen `GetSlotReserveState`,
`PlanSlotReserve -SlotReservePolicy` und `ApplySlotReserve -SlotReservePlan
-ConfirmSlotReserve`. Die Browserroute `/api/slot-reserve` führt denselben
Core direkt aus; Lesen und Vorschau werden nicht in die Batchqueue eingereiht.

## Ressourcenstand: CUs und SqlPackage

Unter **Ressourcen → Ressourcenstand prüfen** liest das Öffnen ausschließlich
Katalog und Sitzungscache. **Jetzt bei Microsoft prüfen** startet ausdrücklich
einen Metadatenvergleich: vorhandener CU-Core plus genau die katalogisierte
SqlPackage-Variante `sql2022-sqlpackage170-linux-derived`. CLI und GUI verwenden
`Invoke-SqlServerLabWorkflowAction -Action GetResourceWatchState` beziehungsweise
`RefreshResourceWatch`; der Browser nutzt den synchronen `/api/resource-watch`-
Endpunkt im langlebigen Servermodul, keinen kurzlebigen Aktionsjob.

Katalogversion, aktueller Quellenbefund und letzte erfolgreiche Beobachtung
werden getrennt angezeigt. `NEW` ist ein Hinweis auf kuratierbare Metadaten,
keine Freigabe für SQL-2022-Linux, Provider, Download oder Installation.
`NO_CHANGE` gilt nur für den erfolgreichen Vergleich zum angegebenen Zeitpunkt.
Offline, Timeout, HTTP 429, Redirect, fehlende/mehrdeutige oder ältere Versionsfelder
liefern `UNCLEAR`; ein älterer Erfolg bleibt als Historie gekennzeichnet.

Der flüchtige Cache gilt 15 Minuten, danach `EXPIRED`. Ablauf löst keinen
Netzzugriff aus; nach Prozessneustart gilt `NOT_CHECKED`. Katalogbytes, feste
Quelle, Variante und Parserrevision binden den Cache. Eine erneute Prüfung bleibt
sichtbar, auch wenn ihre normalisierte Befundidentität unverändert ist.
Es gibt keine dauerhafte Monitoring-, Scheduler- oder Benachrichtigungsgarantie.

Nur dieser interaktive Watchpfad nutzt die neue Transportgrenze: feste exakte
HTTPS-Quellen, keine Redirects, Proxy-/Defaultcredentials oder Cookies, höchstens
512 KiB unkomprimierter UTF-8-Inhalt je Antwort und gemeinsames 45-Sekunden-Budget
mit begrenzter Parserauswertung. Komprimierte Antworten werden abgewiesen.
Der bestehende öffentliche CU-Befehl und monatliche CU-Workflow behalten ihren
bisherigen Transportvertrag. Kein Download, Katalogupdate, Issue oder Agentstart
wird durch den Ressourcenstand ausgelöst.

Der geführte eigene llama.cpp-Sitzungsstop ist unter „Host-Dienste und Modelle“
über Auswahl, Vorschau, Abbruch und bewusste Bestätigung erreichbar. Die
Verbraucher-Coverage bleibt UNKNOWN; deklarierte geschützte Verbraucher sperren
den Stop. Fremdprozesse, Restart und Modellaktionen bleiben offen; eigener Start ist separat geführt und nicht nativ abgenommen.
Die GUI muss im selben PowerShell-Modulhost wie der bestehende Start geöffnet
werden; sie lädt den exakten vorhandenen Modulpfad ohne Force-Reload weiter.
Details und Workflow-Aktionen: [Sitzungsstop](../Architecture/LLAMA_CPP_OWNED_RUNTIME.md).

### Reine llama.cpp-Dateivorschau im Browser

Unter „Host-Dienste und Modelle“ → „llama.cpp: reine Startvorschau“ werden
Runtime-Verzeichnis, GGUF-Datei, Backend, Beschleuniger und die sechs
Modell-/Budgetwerte ausdrücklich im Arbeitsspeicher erfasst. Erst
„Dateivorschau lesen“ ruft den unveränderten öffentlichen Dateiplan auf.
Öffnen, Bearbeiten, Zurück und Escape lesen keine Dateien und erzeugen keinen
Job. Abbruch verwirft die Eingaben und ignoriert verspätete Antworten.

Die Vorschau bleibt PLAN_ONLY/BLOCKED mit leeren Actions. Geräte, Port, TLS,
Modellkompatibilität und SQL bleiben NOT_CHECKED. Pfade werden maskiert erfasst
und weder im Ergebnis noch in Fehlern gespiegelt; es gibt keine Persistenz oder
Ausführungsfreigabe. Clearing ist keine sichere Speicherlöschung. Die zwei
Dateimetadatenbeobachtungen bieten keinen CAS-, Integritäts- oder späteren
Startnachweis. Kein Startknopf, ComputeSelection, Secret-, Zertifikats-,
Sitzungs- oder Inventarzugriff. Der bestehende Start und eigene Sitzungsstop
bleiben getrennte Verträge; die neue geführte Startfunktion bleibt ohne Native-Abnahme.

## Geführter eigener llama.cpp-Start im Browser

Unter „Host-Dienste und Modelle“ → „llama.cpp: eigene Sitzung starten“ erfasst
der Dialog fünfzehn explizite Eingaben einschließlich optionalem CA-PEM und
transientem API-Key. Öffnen, Bearbeiten und Abbruch vor Versand lesen keine
Dateien und rufen keinen Start auf. Erst die bewusste Wirkungsbestätigung
sendet START; eine ausdrücklich gewählte WhatIf-Aktion braucht diese Bestätigung
nicht und ruft denselben öffentlichen Start mit WhatIf ohne Bereitschaftsprüfung auf.
Beide Aufrufe erzeugen wegen dessen Pflichtparameter einen frischen dialogeigenen
SecureString und entsorgen ihn anschließend. Der HTTP-String und Browser-RAM
sind nicht garantiert sicher löschbar; keine Jobs, Logs, URL- oder Storageablage
für die Eingaben. Gemeinsame 65536-Byte-/32768-Zeichenlimits können Kombinationen
maximaler Einzelwerte abweisen; Pfade sind zusätzlich auf 4096 Zeichen begrenzt.

Der dedizierte synchrone POST /api/llama-start verlangt exakte IPv4-Loopback-
Listener-/Request-/Originbindung und nutzt das unveränderte vorhandene Modul.
Kein Force-Reload oder Hintergrundjob. Natürliche ShouldProcess-Semantik bleibt:
Low/Medium/unbekannte effektive ConfirmPreference blockieren vor Public, High/None
werden nicht überschrieben. WhatIf/No-op ist kein Erfolg oder Readinessnachweis.
Das Startbudget von 1–600 Sekunden begrenzt nur Core-Bereitschaftspolls nach
Workerstart, nicht gesamten HTTP-Aufruf, Datei-/TLS-I/O oder Cleanup. Der
UI-Listener kann synchron blockieren; Modulhost für die eigene Sitzung behalten.

Abbruch nach Versand betrifft ausschließlich die Anzeige. Eine verlorene oder
unerwartete Antwort kann eine aktive eigene Sitzung bedeuten. Feste Ergebnis-
und Recoveryanzeigen enthalten keine Pfade, Modellaliase, Zertifikatspins oder
Secrets; nur bestätigte eigene UUID/Port-/Sitzungsbindung wird projiziert.
Kein automatischer Stop, Retry, Ownershipadoption oder Cleanup-Erfolgsversprechen.
Bestehende eigene Sitzungsführung bleibt separat; SQL bleibt NOT_CHECKED.
Die Browserführung ist synthetisch geprüft; neue reale Start-/Modell-/TLS-/
Compute-/Cleanup-Abnahme und ausgewählte Provider-Gates sind NOT_EXECUTED.
