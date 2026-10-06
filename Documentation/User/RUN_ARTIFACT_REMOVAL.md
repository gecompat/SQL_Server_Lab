# Artefakte eines entfernten Runs prüfen und entfernen

`Remove-SqlServerLab` entfernt die gebundenen Providerressourcen und behält den
Run-State für Diagnose und Recovery. `REMOVED` allein beweist weder die
physische Ressourcenabwesenheit noch die sichere Löschbarkeit dieses States.

Der separate CLI-Vertrag prüft genau einen modernen entfernten Run unter einem
registrierten `Lab_Data/State`. Beide Befehle sind auch im Konsolenmenü unter
**Alle öffentlichen Befehle** erreichbar.

```powershell
$plan = Get-SqlServerLabRunArtifactRemovalPlan `
    -RunId $runId -StateRoot $stateRoot -DataRoot $dataRoot
$plan

# Nur einen zugelassenen Plan nach bewusster Prüfung ausführen.
if ($plan.CanApply) {
    Invoke-SqlServerLabRunArtifactRemoval `
        -RunId $runId -ExpectedPlanKey $plan.PlanKey `
        -StateRoot $stateRoot -DataRoot $dataRoot -WhatIf

    Invoke-SqlServerLabRunArtifactRemoval `
        -RunId $runId -ExpectedPlanKey $plan.PlanKey `
        -StateRoot $stateRoot -DataRoot $dataRoot
}
```

Die Vorschau schreibt nichts. Apply verlangt einen unveränderten PlanKey,
fragt über `ShouldProcess` nach Bestätigung und revalidiert vor der Mutation.
`-Confirm:$false` betrifft nur diese native Bestätigung und hebt keine Sperre
auf. Run-State, Cleanup, Dateiinventar, Referenzen und Runtime müssen weiterhin
zur Vorschau passen.

Zugelassen sind ausschließlich `REMOVED`, ein vollständig abgeschlossener
gebundener Cleanup und bestätigte Ressourcenabwesenheit. Docker/Podman benötigen
die bei der Erstellung verwendete feste Endpointbindung, Runtime-Identität und Runtime-Inkarnation
(Docker-Engine-ID oder gebundene Podman-Machine samt Erstellungszeit). Fehlende
historische Bindung, Runtime-Wechsel und Podman ohne gebundene Machine bleiben
gesperrt. Hyper-V bleibt gesperrt, bis ein eigener physischer Abwesenheitsvertrag
gelöschte von verschobenen VHDX unterscheiden kann. Dieser Befehl entfernt
selbst keine nativen Ressourcen.

Container benötigen außerdem vollständige 64-stellige Original-IDs aus der
gebundenen `connection-info.json`, deren Run-/Scope-IDs und eindeutige
Provider-/Instanz-/Cleanup-Namenszuordnung passen müssen. Fehlende, verkürzte,
falsch zugeordnete oder doppelte Evidence blockiert auch ein Resume-Journal.
Eine leere Namens- oder Labelliste ersetzt diesen ID-Nachweis nicht.

Neue Standardcontainer verwenden die aufgezeichnete Route bereits während der
Erstellung, einschließlich Volumeinitialisierung und Fehlercleanup. Die
Abwesenheitsprüfung verwendet den festen Endpoint mit bereinigtem
Routing-Environment. Eine reine Contextnamen-Aufnahme berechtigt nicht zum
Purge. Der vorhandene Owned-Host-Custodyvertrag bleibt geschützt und erhält
keine Freigabe über diesen Metadatenvertrag.

Retention, persistente Daten, externe Host-Mounts, Referenzen aus anderen Runs, Katalogen,
Backup-/Package-Bibliotheken, Batch-/Operationsdaten und geschützten Gruppen
blockieren. Workflow-, Testgruppen- und Windows-Pool-Mitgliedschaft blockieren
auch bei momentan fehlender externer Referenz. Zugehörige Recovery-Evidence bleibt erhalten. Eine Sicherung wird
nicht als Nebenwirkung gelöscht. Registrierte lokale Evidenzarchive besitzen
ihren [eigenen Lifecycle](../Quality/LOCAL_EVIDENCE_ARCHIVES.md).

Nur bekannte Metadatendateinamen und `log/provider.log` sind zugelassen;
unbekannte JSON-, Text- und Logdateien bleiben erhalten. Verschachtelte Recovery-
und Diagnosejournale werden ebenfalls geprüft. Unbekannte Payloadtypen,
Reparsepfade, defekte oder zu große Referenzinventare,
unvollständiger Cleanup und nicht abgeschlossene Journale bleiben `BLOCKED`.
Der öffentliche ReasonCode enthält keine Hostpfade oder nativen Ressourcen-IDs.
Die Begrenzung liegt bei 8.192 Inventarobjekten pro Root und 16 MiB pro gelesener
Metadatendatei. Legacy-, unregistrierte oder abweichende State-Roots werden
nicht automatisch übernommen.

Vor der ersten Löschung legt Apply ein lokales Journal an und verschiebt das
Runverzeichnis atomar in den eigenen Recovery-Scope. Es entfernt nur
manifestgebundene Metadaten, den passenden Scope-Marker und leere gebundene
Runverzeichnisse. Eine neue oder veränderte Datei verhindert den Abschluss.
Bei Teilfehler bleibt `RECOVERY_REQUIRED`; die Vorschau desselben RunId zeigt
die vorhandene Operation. Deren unveränderter PlanKey nimmt ausschließlich
diesen Vorgang vorwärts wieder auf. Bereits gelöschte Metadaten werden nicht
wiederhergestellt. Ein lokaler Abschlussreceipt unter `run-artifact-removals`
erhält Identität und Inhaltsbindung für die idempotente Ergebnisabfrage.

Die Offline-Suite `Invoke-RunArtifactRemovalChecks.ps1` prüft den echten
öffentlichen und privaten Dateilifecycle mit synthetischen Runtime-Leaves.
Dies ist kein nativer Provider- oder SQL-Nachweis. Separate Providerabnahmen
und die Pflichtgates müssen den stabilen Stand belegen.
