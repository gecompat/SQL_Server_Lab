# Lokale Workflow-Oberfläche

## Zweck

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
Grundkonfiguration bietet einen eigenen gemeinsamen Plan-/Apply-Pfad. Die Verbindungsansicht zeigt nur
vorhandene Host-/Port-Felder. Bei Hyper-V werden Host und Port eng aus dem führenden Serverfeld des Connection Strings und TcpPort projiziert; Credentials und Connection Strings werden hier nie angezeigt. Fehlende oder nicht unterstützte Werte bleiben unbekannt; ein Verbindungstest wird nicht behauptet.

Die geschützte Testmatrix wird im Browser ausdrücklich auf die vorhandenen
Gruppenabläufe der Konsole verwiesen. Geführte Browser-Gruppenaktionen, CMS,
operative Slots, vollständiges Provider-Setup und manueller Hostdienst- sowie
Modell-Lifecycle bleiben offen. Der Navigationseinstieg ist keine Abnahme
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
Bindings. Schreibbarkeit und Kapazität bleiben ungeprüft. Dieser kurze Pfad
läuft direkt im lokalen Server; seine begrenzte Providerprüfung kann die
Annahme weiterer Anfragen vorübergehend verzögern.

Die Workflow-Inventur (ISO-, Image- und Runtime-Erkennung) läuft getrennt von
der HTTP-Annahme eines Klicks. Nach einer Aktion schließt der Dialog daher
sofort; Live-Log, Auftragsbestätigung, Laufzeit und Herzschlag erscheinen
unmittelbar. Die möglicherweise langsamere vollständige Inventur wird danach
im Hintergrund aktualisiert.

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
