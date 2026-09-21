# Behaltenen SQL-Speicher endgültig löschen

Ein nach dem Entfernen seiner Umgebung bewusst behaltener SQL-Instanzspeicher
kann getrennt über seine `PersistentStorageId` gelöscht werden. Die Aktion
entfernt **alle Datenbanken, Systemdatenbanken und Serverobjekte** dieses Stores.
Sie prüft kein Backup und bestätigt keine Wiederherstellbarkeit.

Der enge Pfad unterstützt einen einzelnen modernen, katalogisierten
Docker-/Podman-`INSTANCE_STORE` im Zustand `DETACHED` mit `Retention=RETAINED`
und `CleanupDisposition=PRESERVE`. Original-Run, Scope, Instanz, UUID-Labels,
vollständiger persistierter Sollzustand, Connection-Evidence und aktuelle
Runtime müssen übereinstimmen. Aktive Referenzen, Leases oder Container-Anhänge
blockieren. Sidecars, mehrteilige Gruppen, unvollständige historische Evidence,
UUID-lose Stores, externe Ablagen und Hyper-V bleiben ausgeschlossen.

Podman benötigt eine eindeutig gewählte, benannte und verfügbare lokale
Connection. Natives Linux-Podman ohne solche Connection bleibt blockiert;
der Löschpfad richtet keine Connection oder Maschine ein und startet sie nicht.

## Bedienung

In der CLI: **Infrastruktur und Medien → Medien, Testdaten und Speicher →
Behaltenen SQL-Speicher löschen**. Zuerst den
eigenen Store wählen, die Folgen prüfen und die endgültige Löschung ausdrücklich
bestätigen. Die Browser-Workflow-UI bietet denselben getrennten Bereich; ein
Preview ist vor dem Löschen erforderlich. Beide Oberflächen verwenden die
öffentliche API und keine freie Eingabe von Volume-Namen oder Dateipfaden.

Die API-Vorschau ist read-only:

```powershell
$workflow = Get-SqlServerLabWorkflow
$workflow.RetainedStoreRemovalCandidates
$storageId = Read-Host 'Gewünschte PersistentStorageId aus der Liste'
$dataRoot = $workflow.Defaults.DataRoot
$plan = Get-SqlServerLabRetainedStoreRemovalPlan `
    -PersistentStorageId $storageId -DataRoot $dataRoot
$plan
```

Die Vorschau nennt SQL-Version, die Anzahl katalogisierter Datenbankreferenzen
und `ContentInventory=OFFLINE_NOT_INSPECTED`. Diese historischen Referenzen sind
kein vollständiges aktuelles SQL-Inhaltsinventar. Es wird weder ein Container
gestartet noch der Store zur Inhaltsprüfung angehängt. Vor einer Löschung muss
der Benutzer selbst klären, ob benötigte Inhalte gesichert sind.

```powershell
$arguments = @{
    PersistentStorageId      = $storageId
    DataRoot                 = $dataRoot
    ExpectedCatalogRevision  = $plan.CatalogRevision
    ExpectedPlanKey          = $plan.PlanKey
}
Invoke-SqlServerLabRetainedStoreRemoval @arguments -WhatIf
$result = Invoke-SqlServerLabRetainedStoreRemoval @arguments -Confirm
```

Ein veralteter Plan wird abgelehnt. Die Revision bindet den Katalog; `PlanKey`
bindet zusätzlich Original-Evidence, aktuelle Runtime und Volume-Fingerprint.
Beobachtungszeiten verändern den Schlüssel nicht. `WhatIf` und abgelehnte
Bestätigungen schreiben weder Katalog noch Journal und löschen keine Ressource.
Bei einem eigenen abweichenden StateRoot ist derselbe `-StateRoot` für Vorschau,
Apply und Resume zu verwenden.

## Fehler und Wiederaufnahme

Vor dem ersten Delete wird ein eigenes Journal atomar geschrieben und der Store
per CAS als `DELETE_PENDING` reserviert. Continue, Clone und Recovery können ihn
nicht übernehmen. Die letzte Ownership-/Attachment-Prüfung erfolgt frisch; die
Runtime-Löschung verwendet weder Force noch Prune. Ein Fehler bleibt sichtbar als
`RECOVERY_REQUIRED` mit `OperationId`. Derselbe Vorgang ist ausschließlich
vorwärts fortsetzbar:

```powershell
Invoke-SqlServerLabRetainedStoreRemoval `
    -PersistentStorageId $storageId -DataRoot $dataRoot `
    -OperationId $result.OperationId -Confirm
```

Resume löscht kein Ersatzvolume und mutiert bei geänderter Runtime, Original-
Evidence oder Ownership nichts. Ein fehlgeschlagenes `inspect` beweist keine
Abwesenheit: Eine erfolgreiche exakte Volume-Inventur ist zusätzlich erforderlich.
Ein verlorener erfolgreicher Delete-Reply oder fehlgeschlagener terminaler
Katalogcommit kann deshalb ohne erneute physische Löschung abgeschlossen werden.

Nach bestätigter Abwesenheit bleibt die unveränderte ID als `REMOVED`-Tombstone
mit Deletion-Receipt dauerhaft reserviert. Normale Wiederholung verändert keine
Katalog- oder Journalbytes. Der read-only Planner behandelt den Tombstone nicht
als unerwartet vermissten nutzbaren Store. Erscheint dieselbe Bindung erneut,
entsteht ein Konflikt; die ID wird weder neu registriert noch wiederverwendet.
Bei beschädigtem oder verlorenem Journal beziehungsweise uneindeutigen
Katalogspiegeln bleibt Recovery blockiert. Keine automatische Adoption oder
Rücksetzung auf `DETACHED` erfolgt.

Die Offline-Prüfungen verwenden synthetische Producer, echte Katalogspiegel,
injizierte Schreibfehler und getrennte Prozesse. Der native SQL-2025-Harness
`Tests/Integration/Invoke-RetainedStoreRemovalAcceptance.ps1` ist für Docker
und Podman vorbereitet; seine Ausführung steht für diesen Stand noch aus.
