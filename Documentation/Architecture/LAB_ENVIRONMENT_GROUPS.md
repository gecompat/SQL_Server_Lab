# Lab-Umgebungsgruppen

## Zweck und Grenze

Eine Umgebungsgruppe verbindet bereits unabhängig angelegte SQL-Lab-Runs für
ein gemeinsames Szenario, zum Beispiel einen Linked-Server-Test. Die Gruppe
besitzt die Runs nicht. Eine Run-ID kann in mehreren Gruppen vorkommen; innerhalb
derselben Gruppe ist sie eindeutig. Die Registry speichert deshalb Referenzen
auf Run-ID und Scope-ID sowie einen Hash der `connection-info.json`, aber keine
Verbindungsdaten oder Kennwörter.

Die Gruppen-Registry liegt als `EnvironmentGroups.registry.json` im kanonischen
State-Root und damit getrennt von `TestUmgebung.registry.json`. Die
geschützte Automated-Test-Environment-Gruppe behält ihren bestehenden
Erstellungs-, Schutz- und Cleanupvertrag. Eine Lab-Umgebungsgruppe löscht beim
Entfernen ausschließlich ihre Zuordnungen; Run-Remove bleibt eine separate,
explizite Aktion.

## Lifecycle-Vertrag

Die vereinbarte Lifecycle-Semantik lautet:

- Start einer Gruppe startet jedes eindeutige Mitglied höchstens einmal.
- Gruppen, die denselben Run referenzieren, teilen dessen Laufzeitnachfrage.
- Stop einer Gruppe stoppt ein Mitglied nur, wenn keine andere aktive Gruppe
  diesen Run benötigt.
- Gruppenentfernung entfernt Zuordnungen und gruppeneigene Konfiguration, aber
  stoppt oder entfernt keine Runs.
- Teilfehler müssen die Nachfrage so lange konservativ halten, bis der Zustand
  ausdrücklich abgeglichen oder die Gruppe erfolgreich gestoppt wurde.

Die CLI-Start-/Stop-Operationen speichern Zustandsübergänge und jeden
Mitgliederschritt unter demselben StateRoot-Mutex wie die Registry. Der
StateRoot-Mutex schützt Anspruchsprüfung und Registry-Übergänge; ein
Run-Ressourcenmutex serialisiert die vollständige Runtimewirkung desselben
Runs. Einzel-Start und Einzel-Stop geben den Registry-Mutex nach
Anspruchsprüfung und Übernahme des Run-Mutex frei. Unabhängige Starts und Stops
können dadurch parallel fortschreiten. Restart, Remove, Clear und
Gruppen-Lifecycle behalten ihre bestehende übergreifende Serialisierung.
STARTING,
ACTIVE, STOPPING und RECOVERY_REQUIRED gelten konservativ als Ansprüche. Ein
fehlgeschlagener oder unbestätigter Schritt behält den Gruppenanspruch; Start
wiederholt RECOVERY_REQUIRED nicht. Stop kann die Gruppe kontrolliert
wiederherstellen und stoppt ein gemeinsames Mitglied nur, wenn keine weitere
Gruppe es beansprucht. Einzel-Stop, Restart, Remove und Clear respektieren diese
Ansprüche. Remove eines Runs erfordert das vorherige Lösen sämtlicher
Gruppenreferenzen. Gruppenmitglieder können nur bei STOPPED geändert werden.
Geschützte automatisierte Test- und Windows-Pool-Runs können nicht neu gebunden
oder durch eine freie Gruppe gestartet werden. Ein vorhandener Altverweis wird
beim Gruppen-Stop als extern verwaltet behalten, damit die übrigen Mitglieder
stoppen und der Gruppenanspruch anschließend freigegeben werden kann. Live-
Nachbedingungen und gebundene, abgeschlossene Run-Journale sind Voraussetzung
für den bestätigten Gruppenabschluss; unbekannte Runtimezustände bleiben
gesperrt.

Die Gruppenoperation ist kein atomarer Provider-Transaktionsmechanismus. Bei
Teilfehlern bleibt sie ausdrücklich RECOVERY_REQUIRED, bis Stop die bekannten
Mitglieder sicher abgeglichen hat. CLI-/Browser-Bedienung, Reconcile-UI und
Provider-Runtime-Evidence für zusammengesetzte Gruppen bleiben separate offene
Arbeiten; die Registry allein beweist keine Runtimebereitschaft.

## API-Slice

Beispiel für zwei separat erstellte Runs und ein gemeinsames Szenario:

```powershell
$group = (New-SqlServerLabEnvironmentGroup -Name 'Linked Server Demo').Group
Add-SqlServerLabEnvironmentGroupMember -GroupId $group.groupId -RunId $source.RunId
Add-SqlServerLabEnvironmentGroupMember -GroupId $group.groupId -RunId $target.RunId
Start-SqlServerLabEnvironmentGroup -GroupId $group.groupId
```

Wird ein Run zusätzlich einer zweiten Gruppe zugeordnet, hält deren aktiver
Anspruch ihn beim Stoppen der ersten Gruppe am Laufen. Die Gruppen-API
konfiguriert selbst noch keinen SQL-Linked-Server.

- `New-SqlServerLabEnvironmentGroup` erstellt eine leere Gruppe.
- `Get-SqlServerLabEnvironmentGroup` listet Gruppen oder liest eine Gruppe nach
  `GroupId`.
- `Add-SqlServerLabEnvironmentGroupMember` bindet einen vorhandenen Run an eine
  Gruppe. Derselbe Run darf weiteren Gruppen hinzugefügt werden.
- `Remove-SqlServerLabEnvironmentGroupMember` löst genau eine Zuordnung.
- `Remove-SqlServerLabEnvironmentGroup` entfernt die Gruppe und ihre
  Zuordnungen, ohne Runtimeaktionen.
- `Start-SqlServerLabEnvironmentGroup` startet Gruppenmitglieder und protokolliert
  den Lifecycle mit fail-closed Recovery.
- `Stop-SqlServerLabEnvironmentGroup` stoppt nur exklusiv beanspruchte Mitglieder;
  gemeinsame Mitglieder bleiben aktiv.

Beim Zuordnen werden der Run-State, Scope und alle Instanz-IDs gelesen. Beim
Lesen einer einzelnen Gruppe wird die gespeicherte Bindung als `CURRENT` oder
`STALE` ausgewiesen. Die Gruppe ist an den kanonischen State-Root gebunden; ein
anderer State-Root wird abgelehnt. Die Registry wird unter einem
State-Root-weiten Mutex aktualisiert und atomar geschrieben. Derselbe Mutex
serialisiert Anspruchsprüfung und Registry-Übergänge; ein Run-Ressourcenmutex
serialisiert Gruppen- und Einzel-Lifecycle-Aktionen desselben Runs über die
Runtimewirkung.
