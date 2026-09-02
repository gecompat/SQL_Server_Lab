# Lokale Workflow-Oberfläche

## Zweck

Die lokale Browser-Oberfläche fasst vorhandene Windows-OS-Baselines,
Windows-Builder, SQL-Prepared-Images, Abnahmeumgebungen und aktive
Container-Labs in einer Sicht zusammen. Sie zeigt pro Build den nächsten
zulässigen Schritt statt nur interner Zustandsnamen.

Die Oberfläche ist ein zweiter Einstieg über denselben PowerShell-Core. Sie
enthält keine eigene Provisionierungslogik.

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

Die Datenbankpaket-Ansicht arbeitet ebenso pfadfrei. Für ein auswählbares,
nicht TDE-geschütztes Paket kann genau ein laufender Hyper-V-SQL-Run gewählt
werden. Erst nach Eingabe des flüchtigen Gast-Credentials revalidiert der
gemeinsame Core Paket, VM-Eigentum, SQL-Version, FILESTREAM-Capability,
Datenbankname und Zielzustand. Das Ziel wird live aus SQLs Default-Data-
Verzeichnis abgeleitet; ein Host- oder Gastpfad kann nicht eingegeben werden.
Die Paketkopie wird im Gast vollständig gehasht und erst danach attached.

## Einheitliche Umgebungsaktionen

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
