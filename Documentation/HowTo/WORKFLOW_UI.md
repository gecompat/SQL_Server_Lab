# Lokale Workflow-Oberfläche

## Zweck

Die lokale Browser-Oberfläche fasst vorhandene Windows-OS-Baselines,
Windows-Builder, SQL-Prepared-Images, Abnahmeumgebungen und aktive
Container-Labs in einer Sicht zusammen. Sie zeigt pro Build den nächsten
zulässigen Schritt statt nur interner Zustandsnamen.

Die Oberfläche ist ein zweiter Einstieg über denselben PowerShell-Core. Sie
enthält keine eigene Provisionierungslogik.

## Start

Im Repository unter PowerShell 7 starten:

    ./Tools/Start-SqlServerLabUi.ps1

Danach wird die Oberfläche unter http://127.0.0.1:8484 geöffnet. Sie lauscht
ausschließlich auf der Loopback-Adresse; ein Zugriff aus dem Netzwerk ist nicht
vorgesehen. Der Prozess muss als Administrator laufen, wenn Hyper-V-Aktionen
ausgeführt werden sollen.

## Workflow

1. SQL-Prepared-Image: Windows- und SQL-ISO auswählen, Windows in einer
   frischen Builder-VM installieren, SQL `PrepareImage` ausführen, einmal
   final syspreppen und veröffentlichen.
2. OS-Baselines, Abnahme-VMs und Sysprep-Recovery sind getrennte
   Experten-/Reparaturfunktionen.
3. Abnahme: Die Übersicht listet run-lokale Windows-/SQL-Abnahmeumgebungen
   samt ihrem Testzustand.

Gastpasswörter werden nur für den jeweiligen PowerShell-Direct-Aufruf
entgegengenommen. Sie werden nicht im Build-State, Browser-Speicher oder
Live-Log gespeichert.

## Container und Bereinigung

Container-Labs lassen sich ad hoc, aus einem gespeicherten Manifest oder über
die konsistente Mehrfachauswahl von katalogisierten Testdatenbanken erstellen.
Die Datenbankauswahl arbeitet eine ausgewählte Liste nacheinander ab und
fordert für Quellen ohne hinterlegten SHA-256 eine explizite einmalige
Vertrauensfreigabe. Der Menüpunkt **Alles aufräumen** zeigt vor dem Start eine
Bestätigung und führt ausschließlich die hinterlegten Cleanup-Pläne aus;
persistente Data-Root-Inhalte und veröffentlichte Hyper-V-Images bleiben
erhalten.

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
