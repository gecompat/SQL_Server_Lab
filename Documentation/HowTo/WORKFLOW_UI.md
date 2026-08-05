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

1. Windows-OS-Baseline: Build anlegen, VMConnect öffnen, Windows installieren,
   Installation bestätigen, generalisieren und veröffentlichen.
2. SQL-Prepared-Image: frischen Build mit Windows- und SQL-Medium anlegen,
   Windows in VMConnect abschließen, SQL PrepareImage und finalen Sysprep
   ausführen, Image veröffentlichen.
3. Abnahme: Die Übersicht listet run-lokale Windows-/SQL-Abnahmeumgebungen
   samt ihrem Testzustand.

Gastpasswörter werden nur für den jeweiligen PowerShell-Direct-Aufruf
entgegengenommen. Sie werden nicht im Build-State, Browser-Speicher oder
Live-Log gespeichert.

## Plattformen

Die Oberfläche kann mit PowerShell 7 unter Windows und Linux gestartet werden.
Docker und Podman bleiben plattformabhängig nutzbar. Hyper-V-Schritte sind nur
auf einem lokalen Windows-Hyper-V-Host verfügbar und werden sonst deaktiviert.

Die Steuerung eines entfernten Windows-Hyper-V-Hosts ist bewusst noch nicht
implementiert; die fachlichen Vorbedingungen stehen im
[Remote-Hyper-V-Host-Backlog](../Project_Planning/HYPERV_REMOTE_HOST_BACKLOG.md).
