# Lokale Workflow-Oberfläche

Die lokale Oberfläche erstellt und verwaltet eigene SQL-Labs und zeigt deren
Verbindungen. Richten Sie zuerst die [Voraussetzungen und den UI-Start](#start)
ein; wählen Sie anschließend die gewünschte Aufgabe. Die Container-Erstellung
und die Prüfung eines bereits authentifizierten TLS-Labs sind getrennte Abläufe.

## Lab-Katalog schreiben

Wähle unter **Lab-Umgebungen → Lab-Katalog schreiben** die Bestätigung.
Der lokale UI-Prozess erstellt oder aktualisiert
`catalog/sql-server-lab-catalog.json` im konfigurierten Zustandsverzeichnis.
Unter **Vorgänge** erscheinen der Dateiname und die zusammengefassten
Zahlen zu Container-Labs, Vorlagen und offenen Builds. Die Datei bleibt
lokal. Einen anderen Zielpfad kannst du in der CLI unter **Lab-Umgebungen
→ Datenbanken, Samples und Skripte → Lab-Katalog prüfen** wählen.

## Verbindungen anzeigen

Unter **Verbindungen und CMS → SSMS-Registrierungen herunterladen** erhältst
du eine kennwortfreie `.regsrvr`-Datei mit bis zu 500 gespeicherten
regulären Endpunkten. Importiere die Datei in SSMS unter **Ansicht →
Registrierte Server → Aufgaben → Importieren**. Die Browseraktion verwendet
gespeicherten Zustand und führt keinen Runtime-Abgleich durch. Der
Lab_Data-Standard muss für die Zuordnung der geschützten Testsysteme lesbar
sein.

Öffne **Registrierten CMS lesend prüfen** und wähle **CMS synchronisieren**,
um einen laufenden lokalen Docker-/Podman-CMS abzugleichen. Nach der
Bestätigung aktualisiert der Auftrag den Endpunktkatalog und den vom Lab
verwalteten CMS-Baum. Ein geänderter Registrierungs- oder Runtime-Befund
bricht den Auftrag ab. Lies die Registrierung anschließend erneut. Der
Browserauftrag unterstützt keine CMS-Konfiguration mit Kennwortaliasen.

Unter **Verbindungen und CMS** zeigt jede SQL-Zielkarte ihre angegebenen
**Connection Settings**: `Encrypt` und `TrustServerCertificate`. Der neue
Standard bleibt jeweils `True`. Explizites `False` bleibt sichtbar; fehlende
oder unlesbare Werte erhalten eine feste Meldung. Die Übersicht zeigt keine
Zugangsdaten und führt keinen Verbindungstest aus. Die CLI-Runstatusansicht
zeigt dieselben Werte; [Vertrag](../Architecture/SQL_CONNECTION_SETTINGS.md).

Direkt am SQL-Ziel steht zusätzlich der **TLS-Prüfstatus**. Bei gespeicherter
strikter Konfiguration lautet er „Hier nicht aktuell geprüft“; abgeschaltete
Zertifikatsprüfung und nicht angeforderte Verschlüsselung werden getrennt
benannt. Die Anzeige startet keine Verbindung und behauptet keinen aktuellen
Zertifikatsnachweis. Eine frühere Qualifikation wird dadurch nicht ausgewertet.
Die [ausdrückliche Liveprüfung](#tls-jetzt-prüfen) ist eine separate Aktion.

## Angezeigte Verbindung kopieren

1. Öffnen Sie die Karte des gewünschten Container- oder Hyper-V-Labs und
   suchen Sie die richtige SQL-Instanz.
2. Prüfen Sie den angezeigten **Connection String** und dessen TLS-Werte.
3. Klicken Sie daneben auf **Connection String kopieren**. Nach erfolgreicher
   Browserfreigabe erscheint „Connection String kopiert.“ an genau dieser Zeile.

Der angezeigte Text wird unverändert übernommen. Ein vorhandener
Passwortplatzhalter wie `***` bleibt erhalten und muss beim Verbinden durch
das eigene Passwort ersetzt werden. Der TLS-Prüfstatus hat weiterhin seine
[getrennte Bedeutung](#verbindungen-anzeigen).

Während ein Kopiervorgang auf den Browser wartet, sind weitere Kopieraktionen
gesperrt. Aktualisiert sich die Labansicht, erhält die neue Ansicht keine
Erfolgsmeldung für einen vorherigen Text. Ein bereits gestarteter Schreibvorgang
kann dabei noch abgeschlossen werden.

Wenn der Browser den Zugriff nicht unterstützt oder verweigert, erscheint
eine feste Meldung. Prüfen Sie die Browserfreigabe oder markieren und kopieren
Sie den sichtbaren Text manuell. Die Aktion benötigt einen sicheren
Browserkontext, beispielsweise den lokalen UI-Aufruf über `localhost`.
Technische Grenzen und Nachweise stehen im
[Verbindungsvertrag](../Architecture/SQL_CONNECTION_SETTINGS.md#angezeigten-connection-string-kopieren).
Die [getrennte Laufzeitabnahme](../Quality/TLS_UI_CONNECTION_CLIPBOARD_ACCEPTANCE_2026-10-25.md)
belegt kompakte Windows-/Docker-/Podman-Labs mit SQL 2025 CU9 in beiden
TLS-Modi. Sie prüft einen isolierten Headless-Browser; weitere Profile und
die vorhandene Windows-Benutzerzwischenablage bleiben getrennte Nachweise.

## Container-Lab erstellen

Über **SqlPackage-Version im Container prüfen** kannst du anschließend die
Version des bereits provisionierten Tools in einer laufenden Docker- oder
Podman-Instanz abfragen. Wähle die Instanz und bestätige die Versionsprobe.
Das Ergebnis steht im Live-Log. Die Probe installiert keine Software.

Starten Sie die Oberfläche gemäß [Start](#start) mit einem bereiten Provider
und den dort beschriebenen Datenroot-Einstellungen. Öffnen Sie
**Neue Container-Umgebung** und wählen Sie Provider, SQL-Version, Profil und
Labnamen ausdrücklich. Der Dialog nennt den unveränderten
Verbindungsstandard `Encrypt=True;TrustServerCertificate=True`: Die Verbindung
ist verschlüsselt, das Serverzertifikat wird vom Client dabei nicht geprüft.
Für diesen Standard sind weder eine eigene CA noch ein Trustimport erforderlich.

Für einen reproduzierbaren CU-Stand wählen Sie einen als **katalogisiert**
bezeichneten Eintrag, etwa **SQL Server 2019 CU32** oder **SQL Server 2022 CU27**.
Die Liste enthält katalogisierte Container-CUs für 2019, 2022 und 2025;
die bisherigen gleitenden Jahreseinträge bleiben verfügbar. Die Auswahl eines
CU-Eintrags bindet die Erstellung an diesen Katalogeintrag. Sie bestätigt
für sich weder einen erfolgreichen Lauf noch eine Zertifikatsprüfung.

Wählen Sie optionale Volltextsuche und Persistenz nur bewusst und bestätigen
Sie das SA-Passwort. **Umgebung erstellen** übermittelt einen Hintergrundauftrag;
Annahme und erfolgreicher Abschluss werden getrennt im Auftragsbereich
angezeigt. Warten Sie auf den erfolgreichen Abschluss und suchen Sie unter
**Lab-Umgebungen** das genaue neue Lab. Fehlen noch Metadaten, verwenden Sie
**Aktualisieren**; erstellen Sie deshalb kein zweites Lab.

Unter **Verbindungen und CMS** prüfen Sie für genau dieses Lab Instanz,
Provider, Host und Port sowie beide True-Werte in den **Connection Settings**.
Die angezeigte Konfiguration ist selbst kein Zertifikatsnachweis. Wiederholen
Sie einen Auftrag mit unklarem Ergebnis nicht blind, sondern prüfen Sie zuerst
seinen Status. Zum späteren Entfernen wählen Sie **Entfernen** am eigenen Lab,
bestätigen die Aktion und warten auf ihren Abschluss; die Auftragsannahme allein
belegt den Cleanup noch nicht.

Der [datierte Browsernachweis](../Quality/TLS_UI_DEFAULT_CREATION_ACCEPTANCE_2026-10-23.md)
belegt den kompakten, nicht persistenten Standardpfad mit Docker und Podman auf
Windows und SQL 2025 CU9, ohne Autostart, Volltextsuche oder FileStream.
Die [zusätzliche Profilabnahme](../Quality/TLS_UI_DEFAULT_CREATION_PROFILES_ACCEPTANCE_2026-10-23.md)
belegt dieselben Optionen separat mit SQL 2019 CU32 und 2022 CU27 für beide
Provider. Die [Ressourcenprofilabnahme](../Quality/TLS_UI_RESOURCE_PROFILES_ACCEPTANCE_2026-10-24.md)
ergänzt für alle drei SQL-Profile und beide Provider `standard`
(4 CPU, 4096 MiB) und `performance` (8 CPU, 8192 MiB) unter denselben
übrigen Optionen. Die kompakten Abnahmen bleiben ihre früheren Quellstände.
Andere Erstellungsoptionen benötigen eigene Nachweise.

## Vorhandene Umgebungen gemeinsam verwalten

Unter **Lab-Umgebungen > Lab-Umgebungsgruppen ansehen** können Sie die
gespeicherten Gruppen, ihre Run-IDs und Instanznamen anzeigen. Die Ansicht liest
nur die Registry des konfigurierten State-Roots. Der gespeicherte
Lifecycle-Status bestätigt weder den aktuellen Providerzustand noch SQL-
Bereitschaft. Bei einer aktuellen Mitgliedsbindung können Sie über
**Runtimestatus live lesen** den Providerstatus des ausgewählten Runs abfragen.
Die Anzeige vergleicht ihn mit dem gespeicherten `RUNNING`/`STOPPED` und meldet
`CURRENT`, `DRIFT` oder `INDETERMINATE`. Das ist eine Momentaufnahme ohne
SQL-Bereitschaftsprüfung und ohne Zustandsänderung. Bei veralteter Bindung wird
kein Provider abgefragt. Scope-IDs, Verbindungs-Hashes sowie Container- und
VM-IDs werden
nicht angezeigt. Nach einem Gruppenstart oder -stopp zeigt die Ansicht die
zuletzt gespeicherte Aktion und den Status jedes Runs. Das ist ein
Journalergebnis, keine Live-Runtimeprüfung.

Bei einer gestoppten Gruppe startet **Gruppe starten** ihre Mitglieder über
den bestehenden öffentlichen Befehl. Neu gestartete Runs durchlaufen danach
die SQL-Bereitschaftsprüfung; bereits laufende Runs bleiben unverändert. Eine
aktive oder wiederherzustellende Gruppe kann mit **Gruppe stoppen** gestoppt
werden. Runs, die eine andere aktive Gruppe benötigt, bleiben dabei aktiv.
Bei einer gestoppten Gruppe können Sie außerdem eine vorhandene Run-ID
zuordnen oder eine einzelne Zuordnung lösen. Derselbe Run kann in mehreren
Gruppen liegen; Zuordnen, Lösen und Stoppen ändern die anderen Zuordnungen
nicht. Das Lösen stoppt oder entfernt den Run nicht. Mitgliedschaften lassen
sich nur in gestoppten Gruppen bearbeiten. Über **Leere Gruppe erstellen**
können Sie außerdem eine neue Gruppe anlegen; dafür werden keine Runs oder
Runtime-Ressourcen gestartet. **Gruppe entfernen** ist ebenfalls nur bei einer
gestoppten Gruppe verfügbar und entfernt ausschließlich die Gruppe und ihre
Zuordnungen, nicht die Runs oder Runtime-Ressourcen.

Alle Aktionen zeigen vor dem Versand eine Bestätigung und erzeugen einen
normalen UI-Auftrag. Bei einem unbestätigten Ergebnis prüfen Sie zuerst den
Auftragsstatus und lesen danach die Gruppe erneut. Wiederholen Sie eine Aktion
nicht blind.

Die PowerShell-Konsole bietet dieselben Lifecycle- und Zuordnungsaktionen.
Unter **Lab-Umgebungen > Umgebung auswählen und verwalten > Lab-Umgebungsgruppen
verwalten** können Sie **Runtime-Zustand eines Mitglieds lesen** wählen und
ein oder mehrere Mitglieder ausdrücklich auswählen. Die Ausgabe zeigt den
gespeicherten und beobachteten Runtimezustand sowie `CURRENT`, `DRIFT` oder
`INDETERMINATE`. Eine veraltete oder nicht lesbare Bindung fragt keinen Provider
ab. Die Momentaufnahme ändert weder Gruppe noch Run und bestätigt keine
SQL-Bereitschaft. Ein Reconcile ist weder in dieser Gruppenansicht noch in der
Gruppenkonsole verfügbar; der Browser führt ihn ebenfalls nicht aus.

Öffnen Sie **Lab-Umgebungen > Umgebung auswählen und verwalten >
Lab-Umgebungsgruppen verwalten**. Erstellen Sie eine leere Gruppe, wählen Sie
sie aus und fügen Sie vorhandene RUNNING- oder STOPPED-Runs hinzu. Jede
Zuordnung wird einzeln bestätigt. Ein Run darf mehreren Gruppen angehören;
beim Stoppen einer Gruppe bleibt ein Run aktiv, solange eine andere aktive
Gruppe ihn benötigt. Mitgliedsänderungen und das Entfernen einer Gruppe sind
nur bei gestoppter Gruppe verfügbar. Das Entfernen der Gruppe löst nur ihre
Zuordnungen und stoppt oder entfernt keine Runs.

Der Gruppenstart startet gestoppte Mitglieder und prüft danach deren SQL-
Bereitschaft. Bereits laufende Mitglieder bleiben unverändert und werden dabei
nicht erneut auf SQL-Bereitschaft geprüft. Der gespeicherte Gruppenstatus
bleibt eine Registry-Aussage und kein aktueller Runtime- oder SQL-Nachweis.
Die Gruppe richtet weder ein gemeinsames Providernetz noch einen SQL-Linked-
Server ein. Für einen Containerfall müssen die Umgebungen daher vorher separat
erstellt und bei Bedarf mit demselben expliziten `NetworkName` an ein bereits
vorhandenes gemeinsames Netz gebunden werden. Siehe den vollständigen
[Gruppenvertrag](../Architecture/LAB_ENVIRONMENT_GROUPS.md) und dessen
[begrenzte Docker-/Podman-Abnahme](../Architecture/LAB_ENVIRONMENT_GROUPS.md#api-slice).

## Authentifiziertes Container-Lab erstellen

Für `Encrypt=True;TrustServerCertificate=False` öffnen Sie im Erstellungsdialog
**Stattdessen mit Zertifikatsprüfung erstellen …**. Dieser getrennte Weg
verlangt Windows, PowerShell 7.5+, Docker oder Podman, SQL 2019 CU32,
SQL 2022 CU27 oder SQL 2025 CU9 und die
bereits eingerichtete [CA-/Clientbindung des operativen TLS-Pfads](../Architecture/AUTHENTICATED_TLS_OPERATIONAL_LAB.md).
Er richtet weder CA noch Client-Trust ein und übernimmt keine vorhandenen Labs.
Die [native Dialogabnahme](../Quality/TLS_UI_AUTHENTICATED_CREATION_ACCEPTANCE_2026-10-24.md)
bestand mit Docker und Podman für das kompakte SQL-2025-CU9-Lab einschließlich
strikter Liveprüfung, Neustartablehnung, Wiederbindung und eigenem UI-Remove.
Die zusätzliche [Profilabnahme](../Quality/TLS_UI_AUTHENTICATED_PROFILES_ACCEPTANCE_2026-10-24.md)
bestand für kompakte SQL-2019-CU32- und SQL-2022-CU27-Labs mit beiden Providern.
Die [zusätzliche Ressourcenprofilabnahme](../Quality/TLS_UI_RESOURCE_PROFILES_ACCEPTANCE_2026-10-24.md)
belegt `standard` (4 CPU, 4096 MiB) und `performance` (8 CPU, 8192 MiB)
für alle drei SQL-Profile und beide Provider unter denselben übrigen
Optionen. Andere Erstellungsoptionen, Patch-, Client- und Plattformkontexte
bleiben getrennte Nachweise.

1. Wählen Sie Provider, SQL-Profil und Ressourcenprofil. Instanz `primary`, ausgeschalteter
   Autostart und ein nicht persistentes Lab sind fest vorgegeben.
2. Geben Sie die Kandidat-, Controller- und Location-Referenzen Ihrer vorhandenen
   TLS-Einrichtung sowie Labname und bestätigtes SA-Passwort ein. Der Data Root
   wird ausschließlich aus der Serverkonfiguration verwendet.
3. Wählen Sie **Authentifiziertes Lab erstellen** genau einmal und warten Sie
   auf den bestätigten Abschluss. Bei unbestätigter Annahme oder verlorenem
   Ergebnis nicht erneut erstellen; lesen Sie die Sitzungsziele erneut und
   prüfen Sie den privaten Allokationsbeleg gemäß
   [Zuordnungs- und Fehlervertrag](../Architecture/AUTHENTICATED_TLS_UI_CREATION.md).
4. Unter **Authentifizierte Labs dieser Sitzung** stehen die gebundenen
   Zielaktionen bereit. **TLS jetzt prüfen** beobachtet beide strikten Clients.
   Stop/Start allein qualifizieren TLS nicht; nach einem Neustart desselben
   Containers verwenden Sie die ausdrückliche Wiederbindung und prüfen erneut.
5. **Dieses Lab entfernen** betrifft ausschließlich das ausgewählte neue Lab.
   Warten Sie auf `REMOVED`; Annahme allein bestätigt keinen Cleanup. CA und
   Trust bleiben erhalten. Das Schließen der Oberfläche entfernt kein Lab.

Die Ansicht enthält nur Ziele dieses Serverstarts. Ein neuer UI-Start sucht
keine Auditroots zusammen; verwenden Sie für ein früheres Lab seinen privaten
zurückgegebenen StateRoot und die dokumentierte öffentliche API. Angezeigte
gespeicherte Zustände sind keine frische Runtime- oder TLS-Bereitschaft.

## TLS jetzt prüfen

Diese Aktion prüft ein bereits eigenes, registriertes und laufendes
Windows-/Docker-/Podman-Lab mit `Encrypt=True;TrustServerCertificate=False`.
Voraussetzung sind PowerShell 7.5, die qualifizierte CA-/Clientbindung des
[operativen TLS-Pfads](../Architecture/AUTHENTICATED_TLS_OPERATIONAL_LAB.md)
und beide dort vorgesehenen strikten Clients. Ein Lab mit dem einfachen
True/True-Standard bietet diese Aktion nicht an. Auf einem ungeeigneten Host
bleibt sie deaktiviert; die allgemeine Oberfläche benötigt weiterhin nur
ihre dokumentierte Mindestversion.

1. Starten Sie die Oberfläche im selben Windows-Benutzer-/Clientkontext und
   mit der Datenroot-Einstellung Ihres operativen Labs. Für ein solches Lab
   verwenden Sie vor dem UI-Start dessen zurückgegebenen Run-StateRoot:

   ```powershell
   $env:SQL_SERVER_LAB_STATE = $lab.StateRoot
   .\Tools\Start-SqlServerLabUi.ps1
   ```

   `$lab` bezeichnet hier das bereits erstellte eigene operative False-Lab.
   Die Variable gilt für diesen Prozess und seine Kinder. Verwenden Sie den
   vom Server ausgegebenen Operatorlink und die genaue Loopbackadresse;
   die UI sucht nicht global über sämtliche Auditroots.
2. Öffnen Sie **Verbindungen und CMS**. Prüfen Sie Lab, Instanz, Provider,
   Host/Port und die angezeigten True/False-Werte am gewünschten SQL-Ziel.
3. Wählen Sie dort **TLS jetzt prüfen**. Die Prüfung kann länger als eine
   Inventuraktualisierung dauern. Während der laufenden Prüfung bleibt ein
   weiterer Aufruf dieser Liveaktion gesperrt; die automatische
   Workflowaktualisierung wartet. Die Oberfläche bleibt bedienbar.
4. Bei Erfolg erscheint **Beide Clients erfolgreich geprüft am …** mit dem
   Beobachtungszeitpunkt. Das bestätigt die frische strikte SQL-Prüfung
   beider Clients für dieses Ziel. Es ist kein dauerhafter Status und keine
   Exportfreigabe. Gespeicherte Flags bleiben reine Konfiguration.

Eine neue Workflowansicht, weiterer Button, Formularaktion, Seitenwechsel
oder Ablauf verwerfen die Anzeige. Auch die nach Jobende fortgesetzte
automatische Aktualisierung kann sie deshalb wieder auf **Keine aktuelle
Liveprüfung** setzen. Das startet keinen neuen SQL-Test und macht aus dem
früheren Ergebnis keinen neuen Nachweis. Nach Änderungen ist eine neue
ausdrückliche Prüfung nötig.

Fehlt das Ziel oder die Aktion, prüfen Sie zuerst den passenden Run-StateRoot,
den laufenden Run, dessen Provider und die gespeicherten True/False-Werte.
Ein deaktivierter Button weist auf einen ungeeigneten Host oder einen noch
laufenden Job hin. **TLS-Prüfung nicht bestätigt** behauptet keine positive
Beobachtung: Prüfen Sie Labstatus, Clientvoraussetzungen und die
[Voraussetzungen der öffentlichen Live-API](../Architecture/AUTHENTICATED_TLS_LIVE_QUALIFICATION.md).
Nach einem beabsichtigten Neustart desselben eigenen operativen Containers
folgen Sie bei veralteter Startbindung dem
[expliziten Rebind-Vertrag](../Architecture/AUTHENTICATED_TLS_CONTAINER_REBIND.md)
und prüfen danach erneut. Das erneuert weder automatisch Schlüssel noch Trust.
Nach einem unklaren Browserabbruch kann der Serverjob weiterlaufen; ein neuer
Klick ersetzt ihn nicht. Wenn eine weitere Diagnose nötig ist, beschreibt der
[API-Vertrag](../Architecture/AUTHENTICATED_TLS_LIVE_QUALIFICATION.md) den
ausdrücklichen CLI-Aufruf und seine festen Fehlercodes. Warten Sie vor einer
erneuten SQL-Prüfung den terminalen Ausgang des bisherigen Jobs ab.

Die [native Browserabnahme](../Quality/TLS_UI_LIVE_QUALIFICATION_ACCEPTANCE_2026-10-23.md)
belegt Windows-/Docker-/Podman-SQL-2025-CU9. Die zusätzlich geprüften
SQL-2019-CU32-/SQL-2022-CU27-Zellen stehen in der
[getrennten Profilabnahme](../Quality/TLS_UI_PROFILE_MATRIX_ACCEPTANCE_2026-10-23.md).
Die [authentifizierte Erstellung](#authentifiziertes-container-lab-erstellen)
ist separat für kompakte Labs sowie die zusätzlichen
[Standard-/Performanceprofile](../Quality/TLS_UI_RESOURCE_PROFILES_ACCEPTANCE_2026-10-24.md)
der drei geschlossenen SQL-Profile abgenommen. Die hier beschriebene separate
Liveaktion bestehender Labkarten ist zusätzlich für
[Standard und Performance](../Quality/TLS_UI_LIVE_RESOURCE_PROFILES_ACCEPTANCE_2026-10-25.md)
mit Docker/Podman und denselben drei SQL-Profilen abgenommen. Der Server
verwendet dabei weiterhin den ausdrücklich gewählten Run-StateRoot; der
Erstellungsdialog mit ResultRef ist ein eigener Pfad.
Weitere Erstellungsoptionen, Patch-/Clientkontexte und weitere Clipboardprofile bleiben offen;
`WireCertificateFingerprint=NOT_OBSERVED` bleibt wahr.

Die Hintergrundinventur hält ein erfolgreich abgeschlossenes, nichtleeres
Ergebnis fünf Sekunden frisch. Auch eine langsamere Inventur kann dadurch
einen abgeschlossenen Snapshot liefern; fehlerhafte oder leere Jobs erneuern
die Frische nicht. Die begrenzte echte Windows-/Docker-/Podman-
[TLS-Anzeigeabnahme](../Quality/TLS_WINDOWS_RENDERED_CONNECTION_SETTINGS_2026-10-21.md)
bindet Ziel, Connection String und angegebene TLS-Werte an eigene qualifizierte
SQL-2025-CU9-Labs.

## Zweck

Alle Requests passieren die gemeinsame [HTTP-Grenze](../Architecture/WORKFLOW_UI_REQUEST_BOUNDARY.md)
vor Routing und Bodylesung. Browserzugriffe müssen die genaue
`http://127.0.0.1:<Port>`-Origin verwenden; POST verlangt JSON in UTF-8.
Fremde Origins, ungeeignete Medientypen und andere Methoden werden abgewiesen.
Lokale JSON-Clients ohne Origin benötigen dieselbe startgebundene
Operator-Capability. Commands benötigen zusätzlich einen einmaligen Grant;
die übrigen Aktions-/Replayfreigaben bleiben offen.
Die acht direkten JSON-POST-Routen akzeptieren höchstens 1 MiB UTF-8 und
teilen pro Body eine absolute Lesefrist von fünf Sekunden. Überlänge ergibt
413, ungültiges UTF-8 400 und Timeout 408 vor einem Fachaufruf.
Die acht internen Fachreader für CMS, Setup, Slots, Resource Watch, llama.cpp-
Installer/-Stop, Wartungsreparatur und Medienoverrides erhalten ebenfalls fünf
Sekunden absolute Lesefrist. Ihre engeren Zeichenlimits bleiben erhalten;
zusätzliche Byteobergrenzen gelten vor der Decodierung. Übrige spezifische
Adapter und Headerannahme besitzen dadurch keine neue Frist.

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

### Docker und Podman Autostart ändern

Wähle unter **Lab-Umgebungen → Docker-/Podman-Autostart ändern** das
registrierte Lab, die SQL-Instanz und die Policy `on` oder `off`.
Prüfe die angezeigte Ist- und Zielpolicy. Bei einem unveränderten Plan endet
der Dialog direkt. Bei einer Änderung bestätigt der Benutzer den aktuellen
Plan. Erhält die CLI keine sichere Quittung, prüfe den aktuellen Zustand und
offene Recovery vor einer erneuten Änderung.

Im Browser öffnet **Lab verwalten → Container-Autostart ändern** denselben
Ablauf. Nach **Änderung prüfen** zeigt der Dialog Ist- und Zielpolicy. Erst
das Kontrollkästchen und **Autostart ändern** führen den gebundenen Plan aus.
Eine andere Instanz oder Policy erfordert eine neue Vorschau. Der Server
nimmt die Bestätigung einmal und innerhalb von fünf Minuten nach dem Lesen
der Ziele an.

**Docker-/Podman-Autostart-Recovery fortsetzen** liest die passenden
Journaloperationen. Bestätige die gewünschte Operation. Wird das Journal
zwischen Auswahl und Ausführung ersetzt, liest der Benutzer die Auswahl
erneut. Die Wiederaufnahme prüft Containeridentität, Laufzustand und
Restartpolicy. Anschließend schreibt sie Lab-State.

Im Browser liegt **Container-Autostart-Recovery fortsetzen** unter **Lab
verwalten**. Wähle die Journaloperation aus der Liste und bestätige sie mit
dem Kontrollkästchen. Die Auswahl gilt fünf Minuten und kann einmal
verwendet werden. Nach Ablauf oder einem unbestätigten Ergebnis lies
den aktuellen Zustand erneut. Die separate Autostartvorschau bleibt der
Einstieg zur lesenden Prüfung der Restartpolicy.

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

Die getrennte gerenderte Katalogabnahme bestand am 2026-10-07 auf `8b2aba1c`
mit sechs bewussten Suchen über die echte Route und den öffentlichen Reader,
zwölf unveränderten Seitenassets und achtzehn Produktquelldigests. Der
Seitenbootstrap war synthetisch; SQL, State und Provider wurden nicht benutzt.
UTF-8, DEPRECATED-Warnung, Nulltreffer, Zero-Token-Suche und Rücksetzen beim
Wiederöffnen wurden beobachtet, eigener Listener und Tab geschlossen.

### Evaluation-Ersatzentscheid

In der CLI öffnet **Wartung, Aufräumen und Recovery → SQL-Evaluation: Ersatz-
und Migrationsentscheid** dieselbe lesende Vorschau. Wähle das registrierte
Lab_Data, die SQL-Instanz und die Entscheidungsart.
Für eine laufende Instanz bietet **Instanzzustand migrieren** zusätzlich
**SQL-Quellzähler im laufenden Gast lesen**. Der Befund einer vorbereiteten
SQL-2025-Instanz enthält Zähler für ausgewählte Datenbank- und Serverobjekte.
Positive Zähler markieren zusätzliche Prüfungen für Verschlüsselung,
Datenbankzustand, Snapshots, FILESTREAM-Dateityp, mögliche SSISDB, Linked
Server, Zugangsdaten und SQL Agent. Ein SSISDB-Treffer erfordert eine
Katalogprüfung.
Der Befund enthält Kategorien, Anzahlen und feste Prüfcodes. Eine
Transferfreigabe erfordert einen eigenen Nachweis.

Mit **Instanzzustand migrieren → Registriertes Ziellab vorprüfen** kannst du
in der CLI zusätzlich ein separates registriertes SQL-2025-Lab unter
demselben `Lab_Data` wählen. Im Browser wählst du es im Feld
**Registriertes Ziellab (optional)** vor **Vorschau lesen**. Die Vorschau
zeigt den registrierten Zielzustand und die ausstehenden Prüfungen für
Windows-Lizenz, SQL-Bereitschaft sowie Speicher und Transfer. Für ein als laufend
registriertes Ziellab kannst du anschließend **Windows-Lizenz im Ziellab lesen**
wählen. Die CLI bietet dieselbe getrennte Aktion unter **Instanzzustand
migrieren**. Im Browser erscheint das Ergebnis unter **Vorgänge**, zusammen
mit der ID des Ziellabs und seiner Instanz. Eine abgelaufene Ziel-Evaluation
bleibt erkennbar.

Wähle **SQL-Bereitschaft und Edition im Ziellab prüfen**. Die lesende
Gastabfrage prüft, ob die erwartete SQL-2025-Instanz antwortet, und
klassifiziert eine unterstützte Edition. Die CLI zeigt beide Befunde direkt.
Im Browser stehen sie unter **Vorgänge**. Erscheint `EVALUATION`, bleibt die
Evaluationsfrist unbeobachtet. Für eine erkannte Developer-Edition gilt die
Evaluationsfrist als nicht anwendbar. Lizenzgültigkeit, Speicher und
Transferfähigkeit brauchen weitere Nachweise. Der Plan bleibt `BLOCKED`.

Wähle **Freien Speicher im Ziellab prüfen**, um den freien Speicher für die
SQL-Standardpfade Daten, Log und Backup zu lesen. Nutzen mehrere Rollen
dasselbe lokale Volume, zeigt die Prüfung eine gemeinsame Zeile. In der
Konsole erscheint der Befund direkt, im Browser unter **Vorgänge**.
`NOT_OBSERVED` kennzeichnet fehlende oder nicht eindeutig zugeordnete
Pfade. Der freie Gastspeicher lässt noch keine Aussage über den nötigen
Transferspeicher oder die Hostkapazität zu.

**Windows-Lizenz im laufenden Gast lesen** ist eine eigene Auswahl in allen
drei Entscheidungsarten. Sie zeigt den aktuellen Lizenzstatus, den
Beobachtungszeitpunkt und eine belegte Evaluation-Frist getrennt von den
gespeicherten Fristzeilen. Die Abfrage ändert weder Lizenz noch Lab-Zustand.

Im Browser unter **Wartung und Recovery → SQL-Evaluation: Ersatzentscheid**
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
Für einen laufenden Gast und die Auswahl **Instanzzustand migrieren** gibt es
zusätzlich **SQL-Quellzähler im Gast lesen**. Im Auftragsprotokoll stehen
auch die laut SQL-Katalog zugewiesenen Daten- und Logdateigrößen für reguläre
Benutzerdatenbanken, sofern die Werte ermittelt wurden. Der ausdrücklich gewählte
Leseauftrag erscheint unter **Vorgänge**. Er speichert keine Diagnose im
Lab-Zustand. Kategorien, Anzahlen und feste Prüfcodes erscheinen gemeinsam
im laufenden Auftrag.
**Windows-Lizenz im Gast lesen** erscheint bei einer laufenden Instanz
unabhängig von der Entscheidungsart. Der aktuelle Befund erscheint unter
**Vorgänge**. Scheitert die lesende Gastabfrage, bleibt der Befund unbeobachtet.

### External Languages vor einer Lab-Erstellung

Unter **Lab erstellen → Python / R / Java: Katalog und Hostvoraussetzungen**
Docker oder Podman und SQL-Version wählen, dann **Katalogvarianten lesen**.
Python-, R- und Java-Varianten mit Sperrgrund bleiben sichtbar; nur unterstützte
Varianten sind auswählbar. **Katalogentscheidung anzeigen** prüft keinen Host.
**Hostvoraussetzungen bewusst lesend prüfen** beobachtet den gewählten Provider
einmal; `READY` ist keine SQL-Sprachabnahme oder Zielautorisierung.
Für eine zusätzliche Profilprüfung wähle ein **Ressourcenprofil** und dann
**Controller und Profilkapazität lesend prüfen**. Die Ausgabe unterscheidet
fehlende Controller, zu geringe Gesamtkapazität und unbekannte Werte. Die
angezeigte Gesamtkapazität belegt keine frei verfügbare CPU- oder RAM-Menge.
SQL 2025 shared-user-v2 besitzt keine Launchpad-Sandbox. Öffnen oder Ändern
fragt keinen Host ab. Zurück/Abbruch und Escape verwerfen den RAM-Entwurf und
ignorieren späte Antworten; eine laufende lesende Prüfung wird nicht gestoppt.
Kein Speichern, Apply, Job, Manifestübernahme oder Start. Der Prozess hat
20 Sekunden Ausführungsbudget plus bis zu fünf Sekunden Terminierungsversuch,
kein Gesamt-HTTP-/Listener-Zeitlimit. [Vertrag](../Architecture/EXTERNAL_RUNTIME_CAPABILITY.md).

Der gerenderte reine Katalogpfad wurde am 2026-10-07 auf `4007d414` für
Java/2019, Python/2022, R/2022 und die explizite Java/2025-shared-user-Variante
geprüft. Vier Optionsreads und vier öffentliche Entscheidungen, blockierte
Optionen sowie das Rücksetzen der Ausgabe beim Wiederöffnen bestanden.
Der Seitenbootstrap war synthetisch; Hostprüfung, Installation und SQL blieben
ungenutzt. [Abnahmegrenzen](../Quality/LOCAL_VALIDATION_STRATEGY.md).

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

Im Wartungsbereich lassen sich auch gespeicherte Diagnosebefunde,
Run-State-Formate und vorhandene Hyper-V-Checkpoints lesen. Wähle das Lab
oder die Instanz im jeweiligen Dialog und bestätige die Leseaktion.
**Gespeicherten Diagnosebefund lesen** zeigt historische Werte aus dem
registrierten Standard-Lab_Data. **Format eines Run-States prüfen** zeigt
geplante Felder und Blocker. **Hyper-V-Wiederherstellungspunkte lesen**
zeigt vorhandene Checkpoints. Die Ansichten führen keinen Upgrade- oder
Restore-Vorgang aus.

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
CLI und Browser zeigen je Mitglied zusätzlich Plattform, SQL-Version,
Patchziel und den gespeicherten Registrierungsstand. Auch vorgemerkte
Mitglieder sind sichtbar. SQL-Bereitschaft bleibt **nicht geprüft**. Starten oder Stoppen
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

### Linux-Testumgebung zur geschützten Testgruppe hinzufügen

Öffne **Geschützte Testsystem-Matrix → Linux-Testumgebung hinzufügen**.
Wähle Docker oder Podman, die SQL-Version und den Patch. Die Auswahl
enthält den aktuellen Patch und die für diese Version verfügbaren
katalogisierten CUs. Lies die Vorschau und bestätige den angezeigten
Gruppeneintrag. Das Lab erzeugt ein eigenes
Kennwort, registriert die Umgebung und aktualisiert den geschützten Export
unter dem konfigurierten Lab_Data. Der Browser zeigt das Kennwort nicht an.

Eine geänderte Runtime oder Gruppenregistrierung macht die Vorschau
ungültig. Nach einem unbestätigten Auftrag prüfe zuerst den Gruppenstatus.
Eine offene Vormerkung für dasselbe Ziel sperrt eine weitere Anlage.
### Windows hinzufügen, Testgruppe reparieren oder entfernen

Öffne **Geschützte Testsystem-Matrix → Testgruppe verwalten**.
Wähle die Aktion, lies die Vorschau und bestätige erst
dann den Auftrag.

- **Windows anlegen** klont eine für die Nutzung freigegebene
  SQL-Prepared-Vorlage. SQL-Version und Build stammen aus der Vorlage.
  Hyper-V, ein konfiguriertes Lab_Data, eine geeignete Vorlage und ein
  aus einer erhöhten PowerShell gestarteter Oberflächenserver sind für
  die Anlage erforderlich. Die Windows-Einrichtung nutzt ein generiertes Kennwort,
  das im Browser nicht erscheint. Die Windows-Aktivierung kann vorübergehend
  einen externen Netzwerkadapter verwenden. Der Auftrag meldet die Registrierung
  und getrennt davon die Bereitschaft der Gruppe. Wenn noch keine geeignete
  Vorlage vorhanden ist, öffne in der Matrix **Windows-/SQL-Vorlage aus
  ISOs vorbereiten** und folge dem [Vorlagen-Workflow](#workflow). Wähle
  die veröffentlichte Vorlage danach unter **Testgruppe verwalten →
  Windows anlegen**. Der direkte manuelle Medienpfad ist im Konsolenmenü
  unter **Testgruppe erstellen oder konfigurieren → Windows hinzufügen**
  erreichbar.
- **Gruppe reparieren** gleicht Runtime-Namen, Ressourcen, Readiness und
  Windows-Aktivierung ab. Die Reparatur kann Container ersetzen,
  Windows-VMs neu starten und vorübergehend einen externen
  Netzwerkadapter für die Windows-Aktivierung verwenden.
- **Gruppe entfernen** entfernt alle angezeigten Mitglieder, die ihnen
  zugeordneten Ressourcen und die Gruppenexporte dauerhaft. Sichere
  benötigte SQL-Daten vor der Bestätigung.
- **Gruppenexport aktualisieren** schreibt die vorhandenen lokalen
  TestUmgebung-Dateien unter Lab_Data neu. Der Browser meldet die Anzahl
  registrierter und bereiter Mitglieder. Die Dateien enthalten lokale
  SQL-Zugangsdaten und bleiben im geschützten Exportordner.

Reparatur und Entfernen im Browser setzen eine vollständig gebundene
Testgruppe voraus. Unklare Registrierungen, fremde Gruppenreferenzen,
reservierte Windows-Slots und offene Recovery-Journale können die
Vorschau sperren. Bei einer geänderten Bindung oder einem unbestätigten
Ergebnis prüfe zuerst die Testsystem-Matrix und lies anschließend eine
neue Vorschau. Für Reparatur gibt es dort auch einen Konsolenmenüpunkt.

### Funktionsbereiche der Browser-Oberfläche

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
Bindung und unbekannte Ergebnisse. Unter **CMS bereitstellen** erstellst du
einen neuen persistenten SQL-2025-CMS über Docker oder Podman oder übernimmst
einen geeigneten Run mit gespeichertem SA-Kennwort. Bestätige die Auswahl
und prüfe das Ergebnis unter **Vorgänge**. Der Synchronisationsschritt
bleibt bei der gebundenen Prüfung des registrierten CMS. Die
[Anleitung zur Verbindungszentrale](../User/SQL_CONNECTION_CENTER.md)
beschreibt die Voraussetzungen und den Zugang. Operative Slots, vollständiges
Provider-Setup und Fremdstart-/weiterer Hostdienst- sowie Modell-Lifecycle
bleiben offen. Der eigene llama.cpp-
Sitzungsstop besitzt den unten beschriebenen Fachdialog. Der Navigationseinstieg ist keine Abnahme
dieser fehlenden Funktionen.

Die geführten Gruppenaktionen sind davon getrennt: Der Gruppenbereich erlaubt
leere Gruppen anzulegen, Runs hinzuzufügen oder einzeln zu lösen, Gruppen zu
starten, zu stoppen und zu entfernen. Ein Run kann mehreren Gruppen angehören;
beim Stop einer Gruppe bleibt er aktiv, solange eine andere aktive Gruppe ihn
beansprucht. Diese Aktionen erzeugen bestätigte, typisierte Aufträge und sind
für die bestehenden sieben Gruppen-Cmdlets abgedeckt. Die Gruppe erstellt
weder ein gemeinsames Providernetz noch den SQL-Linked-Server; diese
Vorbereitung bleibt eine getrennte Run-Konfiguration. Der native Docker- und
Podman-Nachweis des Mehrgruppen-/Linked-Server-Falls ist in der [datierten
Abnahme](../Quality/LINKED_SERVER_ENVIRONMENT_GROUP_ACCEPTANCE_2026-11-08.md)
ausgewiesen.

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

HTTP-Commands erhalten vor der Übermittlung eine einmalige, an exakt diese
Eingaben und Serversitzung gebundene Freigabe. Der Browser übermittelt denselben
einmal serialisierten Body zweimal lokal; fachliche Bestätigungen und Prüfungen
bleiben wirksam. Nach unbekannter Annahme Status lesen und keine automatische
Wiederholung auslösen. Jede Sitzung besitzt insgesamt 256 Receipt-Slots;
abgelaufene und widerrufene Freigaben geben keinen Slot frei. Bei ausgeschöpfter
Quota meldet die Oberfläche das Veto. Sie wiederholt keinen Request und startet
keinen Server neu. Laufende Aufträge und Recovery vor bewusstem Serverende prüfen.

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

Windows benötigt weiterhin mindestens PowerShell 7.2. Unter Unix benötigt der
private UI-Handoff zusätzlich die UnixFileMode-APIs aus .NET 7 oder neuer.
Fehlen diese Hostfeatures, bricht der Start vor jeglicher Handoffanlage mit
`UI_OPERATOR_UNIX_MODE_UNAVAILABLE` ab.

    ./Tools/Start-SqlServerLabUi.ps1

Danach wird die Oberfläche mit einem privaten Startlink unter
http://127.0.0.1:8484 geöffnet. Jede Serversitzung erzeugt eine neue
Operator-Capability; alle API-Lese- und Aktionsrequests benötigen sie.
Der Browser entfernt das Startfragment sofort und hält die Capability nur
im Arbeitsspeicher. Für Reload oder weiteren Tab den privaten Startlink
erneut öffnen. Ein nackter Basislink lädt Produktassets, authentifiziert aber
keine APIrequests.

`-NoBrowser` erzeugt denselben privaten Handoff ohne Browserstart. Das Terminal
nennt den Locator einer ausschließlich lokal zu lesenden `operator.json` in
einem neuen privaten Runtimeverzeichnis. Sie enthält `StartUrl`, `ListenerUrl`
und `Capability`. Den Startlink lokal im Browser öffnen; HTTP-CLI-Clients senden
`Capability` als `X-SqlServerLab-Operator` an genau `ListenerUrl`. Dateien und
Werte nicht teilen, in Logs übernehmen oder in Git speichern. Bei Serverende
entfernt der Server nur sein unverändertes eigenes Handoffartefakt;
unbestätigter Cleanup bleibt lokal sichtbar. Ein alter Startlink funktioniert
nach Neustart nicht. Diese Operatorbindung ersetzt keine Aktionsbestätigung
oder fachliche Zielprüfung.

HTTP-CLI verwendet für `POST /api/commands` denselben Zweischritt. Nach lokalem
Lesen der privaten Startdatei muss `$requestJson` einen bekannten exportierten
Befehl, echten Parametersatz, `parameters`-Objekt und Boolean-`confirmed` enthalten.
Bestätigungspflichtige Befehle benötigen `true`; `"false"` ist kein Boolean.
Der folgende Ablauf hält Credentials und Body ausschließlich lokal im RAM:

```powershell
$operator = Get-Content -LiteralPath $operatorFile -Raw | ConvertFrom-Json
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($requestJson)
$headers = @{ 'X-SqlServerLab-Operator' = $operator.Capability }
$receiptId = $null
try {
    $grant = Invoke-RestMethod -Uri ($operator.ListenerUrl + 'api/command-grants') `
        -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes `
        -Headers $headers -MaximumRedirection 0 -MaximumRetryCount 0
    $receiptId = $grant.receiptId
    $headers['X-SqlServerLab-Action-Grant'] = $grant.grant
    $accepted = Invoke-RestMethod -Uri ($operator.ListenerUrl + 'api/commands') `
        -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes `
        -Headers $headers -MaximumRedirection 0 -MaximumRetryCount 0
}
finally {
    [Array]::Clear($bytes, 0, $bytes.Length)
    $headers.Clear(); $operator = $null; $grant = $null
}
```

Den Body zwischen beiden Requests nicht neu aufbauen; auch Whitespace, BOM,
Escapeform, Ziel, Plan und Consent sind gebunden. Ein Grant läuft nach 60 Sekunden
ab und wird vor Jobanlage unwiderruflich verbraucht. `$receiptId` ermöglicht
bei unbekannter Antwort ein authentifiziertes `GET` an
`api/command-grants/<receiptId>` mit nur `receiptId`, `state` und `jobId` als Ergebnis.
Ein noch unverbrauchter Grant kann über `POST` an denselben Pfad plus `/cancel`
mit exakt `{}` widerrufen werden. Das beendet keinen angenommenen Job. Keine
Credentials oder Bodys ausgeben oder speichern; Granttoken nach Bedarf lokal
verwerfen. Im Browser bleibt bei unbekannter Annahme ausschließlich diese sichere
Annahmereferenz in der Meldungskarte erhalten. Native PowerShell-/Konsolenbefehle
benötigen diesen HTTP-Grant nicht.

Sie lauscht
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

Unter **Vorgänge → Batch mit mehreren Umgebungen planen** kannst du mehrere
Gruppen hinzufügen und ihre jeweilige Anzahl einstellen. Zur Auswahl stehen
SQL Server unter Linux und Windows sowie eine reine Windows-Umgebung.
Für Linux gibst du den Namen einer `SQL_SERVER_LAB_SECRET_*`-Prozessvariable
an. Ihr Kennwortwert wird im Browserformular nicht eingegeben.

**Entwurf validieren und speichern** zeigt die Batch-ID, die Anzahl der
Umgebungen und die Zahl gemeinsamer Abhängigkeiten. Öffne in der
Batchübersicht **Entwurf prüfen und einreihen**, kontrolliere die Zahlen
und bestätige den Plan. Für Linux-Positionen müssen die hinterlegten
Kennwortvariablen im laufenden Browser-Serverprozess verfügbar sein. In der
Konsolensitzung geht derselbe Ablauf über **Vorgänge, Queue und
Benutzeraktionen → Gespeicherten Batch prüfen und einreihen**.

Über **Hintergrundscheduler anfordern** und eine Bestätigung kannst du die
aktuelle Warteschlange bedienen. Ob Vorgänge tatsächlich anlaufen, siehst du
anschließend bei ihrem Status.

Unter **Vorgänge, Warteschlange und Wiederaufnahme → Fortschritt
gespeicherter Batches** zeigt der Browser bei bis zu 50 Batches den Status,
den Fortschritt und die Zahl der fehlgeschlagenen oder abgebrochenen
Vorgänge. Die Ansicht überträgt keine Batch-Eingaben oder Quelldateipfade.

Wähle die ID eines Batches mit offenen Vorgängen, um seine Vorgangskarten
anzuzeigen. Mit **Alle Vorgänge anzeigen** löst du die Auswahl. Der Filter
ändert nur die Ansicht. Prioritäts- und Reihenfolgeänderungen verwenden
weiterhin die gesamte Warteschlange.

Bei einem übergebenen Batch mit offenen Vorgängen öffnet **Unfertige
Positionen stoppen** eine Vorschau mit Anzahl der Zielpositionen und der
bereits laufenden Schritte. Bestätige erst danach den Stopp und das Einreihen
der scopegebundenen Bereinigung. Fertige Positionen bleiben erhalten.
Eine geänderte oder abgelaufene Vorschau erfordert einen neuen Aufruf.
Unter **Letzte abgeschlossene Vorgänge** stehen bis zu 50 persistierte
Ergebnisse mit Provider, Status und Abschlusszeit. Ein fehlgeschlagener
Bereinigungsversuch erscheint dort als **Fehlgeschlagen**. Öffne bei einem
Fehler in der CLI **Vorgänge, Queue und Benutzeraktionen → Letzte
abgeschlossene Vorgänge**. Wähle die betroffene Position aus und kläre den
Status ihres Runs vor einem erneuten Auftrag.
**Gesamten Batch zurückbauen** zeigt auch die fertigen und fehlgeschlagenen
Positionen an, deren Ressourcen in die Bereinigung einbezogen werden.
Die Bestätigung reiht den Rückbau ein. Prüfe den Abschluss anschließend in
der Warteschlange.

Für wartende Vorgänge kannst du bei mindestens zwei verfügbaren Einträgen
die **Priorität** auf Hoch, Normal oder Niedrig setzen. **Nach oben** und
**Nach unten** erscheinen, wenn in derselben Priorität ein entsprechender
Nachbar vorhanden ist. Die Browseransicht liest die Queue nach der Änderung
neu. Laufende Vorgänge zeigen keine Reihenfolgensteuerung.
Während du die Priorität auswählst, bleibt das Feld bei automatischen
Aktualisierungen bedienbar.

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
hasht nicht bei jedem UI-Refresh alle Backup-Dateien.
Wähle an einer laufenden Docker- oder Podman-Instanz **Verifiziertes Backup
erstellen**, gib Datenbankname und SA-Passwort ein und bestätige die angezeigte
Instanz und Datenbank. Voraussetzung ist ein registriertes `Lab_Data`. Bei
Erfolg zeigt die Quittung BackupSet-ID, Datenbankname, SHA-256 und Größe. Für
Hyper-V bleibt der bestehende PowerShell-Weg verfügbar.

**SQL-Betriebsmetriken lesen** steht an derselben laufenden Container-Instanz.
Gib das SA-Passwort ein und bestätige die Instanz. Unter **Vorgänge** zeigt
der Auftrag aggregierte CPU-, Speicher-, Datenbank-, Query-Store- und
Wartewerte. Das Ergebnis enthält keine SQL-Texte, Datenbanknamen, Loginnamen oder Zugangsdaten.
In der CLI findest du die Abfrage unter **Datenbanken, Samples und Skripte**.

Der Menüpunkt **Alles
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

### Volltextsuche für eine vorhandene Umgebung ändern

Wähle in der CLI unter **Lab-Umgebungen → Umgebung auswählen und verwalten**
das laufende Lab und dann **Volltextsuche ändern**. Hat das Lab mehrere
SQL-Instanzen, wähle die betroffene Instanz. Im Browser steht die Aktion
unter **Lab verwalten** direkt an der laufenden SQL-Instanz. Bei Hyper-V
heißt sie **Volltextsuche / FILESTREAM** und gilt für die registrierte SQL-Standardinstanz.

Wähle **Nachinstallieren** oder **Deaktivieren** und bestätige die Änderung.
Beim Deaktivieren entfernt das Lab die Volltextkomponente. Abhängige
Volltextindizes sperren diesen Schritt. Eine tatsächliche Änderung startet
SQL Server neu. Unter Hyper-V müssen passende, verifizierte SQL-Medien im
konfigurierten Media Root verfügbar sein.

### SMTP-Testdienst prüfen

Öffne **Lab-Umgebungen → SMTP-Testdienst prüfen** und wähle ein
registriertes Docker- oder Podman-Lab mit SMTP-Testdienst. **Receiver
prüfen** liest die gebundene Mailpit-Runtime. Der Befund zeigt, ob der
Receiver läuft, gestoppt ist oder gerade nicht eindeutig geprüft werden
kann. Die geführte Konsole bietet denselben Einstieg.

Bei einem laufenden Receiver ist **WebMail im Standardbrowser öffnen**
verfügbar. Die Aktion öffnet für 15 Minuten einen lokalen Mailpit-Zugang
zum Lesen und Löschen von Testmails. Der Startlink erscheint in keinem
Ergebnisprotokoll. Die Zustellung selbst prüfst du separat.

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

## Schnellen Wartungsplan lesen

Unter **Wartung, Aufräumen und Recovery → Schnellen Wartungsplan lesen**
zeigt die Vorschau den Zustand von Docker, Podman und Hyper-V sowie die
Anzahl der für den beobachteten Zustand vorgeschlagenen Aktionen. Im
Browser beginnt die Inventur mit **Plan lesen**. Ein nicht erreichbarer
Provider erscheint als `UNAVAILABLE`. Diese Übersicht führt keine
Aktion aus. Für die Zuordnung einzelner Objekte nutze **Wartungsbefunde
und Zuordnung**.

**Vollständigen Wartungsplan lesen** prüft zusätzlich den Speicherbestand
und vorhandene Cleanup-Befunde. Die Übersicht zeigt Zähler für verwaltete
Vorlagen, Provider-Datenspeicher und Hyper-V-Befunde. Im Browser läuft die
Inventur im Hintergrund und das Ergebnis erscheint im Auftragsprotokoll.
Der vollständige Scan kann länger dauern. Er speichert keinen Auditbericht
und führt keine der vorgeschlagenen Aktionen aus.

## Hyper-V-Speicherziel vor einem Build prüfen

Wähle in Konsole oder Browser **Hyper-V: Vorlagen und Slots →
Hyper-V-Zielpfade und freien Speicher anzeigen**. Du siehst das
registrierte Lab_Data-Standardziel, die Klassenpfade für Runs, Builds,
Images, Staging und Recovery sowie den freien Speicher zum Lesezeitpunkt.
Liegt das Ziel auf dem Systemvolume, weist die Anzeige darauf hin. Der
Dialog liest den Speicherkatalog ohne UAC und reserviert keinen Speicher.
Fehlt das Ziel oder ist es nicht lesbar, prüfe die Registrierung unter
**Grundkonfiguration**.

## Windows-OS-Slot-Pool vorbereiten

Öffne **Hyper-V: Vorlagen und Slots → Windows-OS-Slot-Pool vorbereiten**
auf dem Hyper-V-Host mit Administratorrechten. Wähle eine versiegelte,
geeignete Windows-Baseline, Pool-ID, Slotnummern und Ressourcen. Der Host
prüft die gewählte Baseline einschließlich Integrität und Restlaufzeit vor
der Anlage. Die VMs werden für die Ersteinrichtung gestartet und danach
gestoppt. Falls die Evaluation online aktiviert werden muss, darf der
Auftrag dafür vorübergehend einen externen Netzwerkadapter verwenden.

Die Passwörter erzeugt und schützt der Host pro Slot. Den Status findest
du unter **Vorgänge**. Für die Fortsetzung benötigst du dieselbe Pool-ID,
Baseline und Konfiguration. Für die CLI-Varianten einschließlich eigener
Locale- und Passwortwahl siehe die [Funktionsübersicht](../User/FUNCTIONS_CLI_GUI.md).

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
Leser und Writer verwenden dieselbe dateigebundene Sperre. Der atomare
Merge erhält andere Felder. Entfernt eine Migration die vorher vorhandene
Datei, kann ein wartender Writer sie nicht erneut anlegen. Ungültiges JSON
und ungültige Policies werden nicht automatisch repariert. Ein Wechsel des globalen Datenroots
migriert keine Preferences; die anschließend aufgelöste Authority wird neu gelesen.

Die Bestandsansicht liest registrierte Hyper-V-Kandidaten und gebundene aktive
Vorgänge, einschließlich gestoppter Runs. Eine Vorgangsbindung ist keine
Poolreservierung. Windows-Fristen bleiben historische Aktivierungsmetadaten;
SQL-Fristen verwenden den vorhandenen gebundenen Receipt-/Aktualitätsvertrag.
Warnfrist und Mindestrestlaufzeit sind getrennte Bewertungen. Unbekannte,
ablaufende, belegte oder vorgangsgebundene Kandidaten zählen nicht als frei.
Nur kanonisch gebundene, freie und gestoppte Windows-Poolmitglieder mit
frischer Gastevidence zählen. Bei unklarer Bestandsbindung bleiben die exakte
Windows-Verfügbarkeit und das Defizit unbekannt. SQL-Reserve, Gesamtdefizit
und automatische Auffüllung bleiben offen. Bei Nullreserve lautet die Aussage
„keine Reserve angefordert“.

Wähle für eine einzelne Mitgliedaktion das gebundene Windows-Poolmitglied
und lies die Vorschau. **Für SQL-Ausbau übernehmen** verlangt einen aktiven
Claim mit frischer Evidence. Wähle SQL-Version, Edition des Mediums und
optionale Komponenten. Das Datenbankmodul ist obligatorisch. Gib die
ausgewählte Medien-ID, vCPU und Startspeicher an. Der Wert 0 für den
Startspeicher übernimmt den vorhandenen Wert. Beim Bestätigen prüft der Host
Bindung, Zustand und Evidence erneut, setzt die bestätigten VM-Ressourcen
und speichert den SQL-Ausbauplan.
Öffne danach **Lab verwalten → Reguläre Hyper-V-Umgebungen** und wähle beim
übernommenen Windows-Slot **SQL-Ausbau starten**. Bestätige Ziel, Version,
Edition und Features. Setup verwendet die gespeicherten Gastzugangsdaten und
das konfigurierte Medium. Es benötigt ein vorhandenes Hostnetzwerk. Bei
einem gespeicherten Wiederaufnahmezustand erscheint **SQL-Ausbau fortsetzen**.
Nach Status- oder Planänderungen lies die Übersicht vor erneuter Bestätigung
neu. Zugangsdaten erscheinen weder im Dialog noch in der Auftragsantwort.
Die Fachaktion zur Erstinstallation mit SQL Server 2025 wurde auf einem
übernommenen Windows-Server-2025-Desktop-Slot bis zur SQL-Bereitschaft
und zum vollständigen Test-Cleanup geprüft.
[Nativlauf](https://github.com/gecompat/SQL_Server_Lab/actions/runs/45360347068)
[Mitgliedschaft und Claims](../Architecture/WINDOWS_POOL_MEMBERSHIP_AND_CLAIMS.md)

CLI: `Invoke-SqlServerLab -Action ReservePolicy`. Nichtinteraktiv bietet
`Invoke-SqlServerLabWorkflowAction` die Aktionen `GetSlotReserveState`,
`PlanSlotReserve -SlotReservePolicy` und `ApplySlotReserve -SlotReservePlan
-ConfirmSlotReserve`. Die Browserroute `/api/slot-reserve` führt denselben
Core direkt aus; Lesen und Vorschau werden nicht in die Batchqueue eingereiht.

## Lokaler Bedarf an Beispieldaten und Laufzeitmedien

Öffne in CLI oder Browser **Ressourcen und Downloads → Lokalen
Ressourcenbedarf prüfen**. Wähle Beispieldaten, Windows-/Hyper-V-Laufzeitmedien
oder beide. Für jede Ressource siehst du die Zahl der vorhandenen und
benötigten Dateien sowie den vorgesehenen Beschaffungsweg. Die Prüfung
liest die konfigurierten Ordner und startet keinen Download. Im Browser
steht das Ergebnis unter **Vorgänge**.

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

Unter **Host-Dienste und Modelle → Persistente Retrieval-Collections**
kannst du Beispieldaten verwenden oder eigene Dokumente aus einer lokalen
JSON-Datei anlegen, abfragen, synchronisieren oder migrieren. Prüfe bei
den Löschaktionen Run-ID, Instanz sowie
Collection-ID, bevor du bestätigst. Die [Anleitung zum persistenten
Retrieval](../User/Getting_Started.md#persistentes-retrieval) erklärt den
Unterschied zwischen dem Löschen alter Generationen und der gesamten
Collection-Datenbank.

Unter **Host-Dienste und Modelle** kannst du in CLI und Browser ein
llama.cpp-Generationsmodell aus dem lokalen Katalog auswählen. Prüfe
Modellgröße, Lizenz und Medienordner vor der Bestätigung. Die Auswahl bindet
Katalogrevision und SHA-256. Der Download wird nach erfolgreicher Prüfung
unter `AI/Models` im Medienordner abgelegt. Das Ergebnis steht im Browser
unter **Vorgänge**. Start und Modellnutzung erfolgen in getrennten Schritten.

Über **Host-Dienste und Modelle → Lokales Ollama-Modell aufrufen** kannst
du ein katalogisiertes Generationsmodell wählen, das im lokalen Ollama-Dienst
bereitsteht. Gib dessen Loopback-Port und einen synthetischen Prompt ein.
Das Zeitlimit umfasst Modellstart und Antwort. Standard sind 180 Sekunden.
Erst nach Bestätigung sendet der Browserauftrag eine Abfrage an den lokalen
Dienst. Die Antwort steht unter **Vorgänge**. Für die ausdrücklich
freizugebende Cloud-Lane gibt es weiterhin den CLI-Einstieg.

Der geführte eigene llama.cpp-Sitzungsstop ist unter „Host-Dienste und Modelle“
über Auswahl, Vorschau, Abbruch und bewusste Bestätigung erreichbar. Die
Verbraucher-Coverage bleibt UNKNOWN; deklarierte geschützte Verbraucher sperren
den Stop. Fremdprozesse, Restart und Modellaktionen bleiben offen; eigener Start ist separat geführt und nicht nativ abgenommen.
Die GUI muss im selben PowerShell-Modulhost wie der bestehende Start geöffnet
werden; sie lädt den exakten vorhandenen Modulpfad ohne Force-Reload weiter.
Details und Workflow-Aktionen: [Sitzungsstop](../Architecture/LLAMA_CPP_OWNED_RUNTIME.md).

### Gemeinsamen Embedding-Gateway planen

Wähle in der CLI oder im Browser unter **Host-Dienste und Modelle**
**Gemeinsamen Embedding-Gateway planen**. Gib die HTTPS-Adresse des Gateways
mit `/v1/embeddings` und die numerische Loopback-Adresse des Upstreams an.
Beim OpenVINO Model Server verwendet der Upstream `/v3/embeddings`. Ergänze
Modellname, Dimension, Eingabeprofil und die SHA-256-Digests.

Ordne einen bis 64 SQL-Verbraucher mit Run-, Instanz- und Datenbank-ID,
SQL-Modellname und jeweils eigener `SQL_SERVER_LAB_SECRET_`-Referenz zu.
**Plan anzeigen** prüft die Eingaben und zeigt den Konfigurationsplan als JSON.
**Status für diesen Gateway-Plan lesen** prüft danach auf ausdrückliche Auswahl
die lokale Registrierung und Portbelegung. Im Browser erscheint das Ergebnis
im Auftragsprotokoll. Eine eigene Sitzung lässt sich nur in der Modulsitzung
nachweisen, die sie gestartet hat. Eine belegte Schnittstelle ohne diesen
Nachweis wird als ungeklärte Portbelegung ausgewiesen. Dienststart und
SQL-Anbindung sind getrennte Operationen.

In CLI und Browser öffnet **Lokale Gateway-Dateien für diesen Plan prüfen**
die Dateiprüfung. Gib absolute Pfade zu Runtime, Modell, Serverzertifikat,
privater Schlüsseldatei und CA-Zertifikat ein. Verwende reguläre Dateien
in lokalen Verzeichnissen ohne Verknüpfungen. Die drei Zertifikats- und
Schlüsseleingaben verwenden PEM. Der Schlüsselpfad wird bei der Eingabe
verdeckt. **Dateien jetzt prüfen** bestätigt die Prüfung. Das Ergebnis
`PREFLIGHT_VERIFIED` bindet die geprüften Inhalte an den angezeigten Plan.
Das JSON-Ergebnis dokumentiert die Übereinstimmung ohne Dateipfade. Die
getrennte Registrierung prüft die Dateien erneut. Im Browser steht das
Ergebnis im Auftragsprotokoll. Bei einem Pfadfehler prüfe Erreichbarkeit
und Dateityp.

Wähle **Gateway-Dateien für diesen Plan geschützt registrieren**, um dieselben
fünf Dateien für den angezeigten Plan zu hinterlegen. Bestätige die Kopie
einschließlich der privaten Schlüsseldatei in die geschützte Lab-Ablage.
Die Registrierung prüft die Dateien erneut. `REGISTERED` bestätigt die
neue Ablage, `ALREADY_REGISTERED` eine unveränderte passende Registrierung.
Bei einem Konflikt oder geänderten Inhalten lies zuerst den Status für
diesen Plan und prüfe die Quellartefakte. Anschließend kann der registrierte
Loopback-Upstream geprüft werden.

Wähle **Registrierten Loopback-Upstream mit Testanfrage prüfen**, um dem
gebundenen lokalen Upstream genau eine synthetische Embedding-Anfrage zu
senden. Die Dateien müssen für den angezeigten Plan registriert sein.
Der geführte Weg verwendet keinen API-Schlüssel. Das Ergebnis prüft
Modell, Dimension und Zahlenwerte der Antwort. Im Browser steht es im
Auftragsprotokoll.

Im Browser übernimmt **In Dienst-Secret-Prüfung übernehmen** den Plan in das
vorhandene Formular. Die Dienstprüfung benötigt weiterhin ihren eigenen
Dienstplan und eine Bestätigung. [Gateway-Backlog](../Project_Planning/AI_EXTERNAL_MODEL_ACCELERATION_BACKLOG.md)

### Vorhandene llama.cpp-Pakete prüfen

Wähle in CLI oder Browser **Host-Dienste und Modelle → Vorhandene
llama.cpp-Pakete prüfen**. Die Suche verwendet `SQL_SERVER_LAB_LLAMA_ROOT`
und das Verzeichnis des ersten `llama-server`-Fundes im Prozess-PATH.
Backend und Build stammen aus den gefundenen Paketdateien. Bei einer
unlesbaren Suchwurzel zeigt die Oberfläche an, dass die Suche unvollständig
war. Paketursprung, verfügbare Geräte und SQL-Embedding-Bereitschaft bleiben
ungeprüft. Für eine Suche in ausdrücklich angegebenen Verzeichnissen verwendet
ein Skript `Get-SqlServerLabLlamaCppRuntime -SearchRoot <Verzeichnis>`.

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
