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
gesperrt. Der Gruppenstart prüft die SQL-Bereitschaft jedes gestoppten Mitglieds,
das er neu startet. Bereits laufende Mitglieder bleiben unverändert; für sie
führt er keine erneute SQL-Bereitschaftsprüfung aus.

Die Gruppenoperation ist kein atomarer Provider-Transaktionsmechanismus. Bei
Teilfehlern bleibt sie ausdrücklich RECOVERY_REQUIRED, bis Stop die bekannten
Mitglieder sicher abgeglichen hat. Die geführte PowerShell-CLI ist unter
**Lab-Umgebungen > Umgebung auswählen und verwalten > Lab-Umgebungsgruppen
verwalten** verfügbar. Sie erstellt leere Gruppen, bindet vorhandene Runs,
startet und stoppt Gruppen und löst Zuordnungen. Die Workflow-UI zeigt die
gespeicherten Gruppen und Run-Referenzen an, kann leere Gruppen anlegen und
gestoppte Gruppen samt Zuordnungen entfernen. Die Gruppenentfernung stoppt oder
entfernt keine Runs.
Bei gestoppten Gruppen startet sie Mitglieder über
`Start-SqlServerLabEnvironmentGroup`; aktive oder
wiederherzustellende Gruppen lassen sich über `Stop-SqlServerLabEnvironmentGroup`
beenden. In gestoppten Gruppen kann ein vorhandener Run per Run-ID zugeordnet
oder eine einzelne Zuordnung gelöst werden. Derselbe Run darf mehreren Gruppen
angehören; das Lösen stoppt oder entfernt ihn nicht. Alle Aktionen verwenden
den katalogisierten öffentlichen Befehl, seine Einmal-Grant-Grenze und eine
ausdrückliche UI-Bestätigung. Die Ansicht gibt weder Scope-IDs noch
Verbindungs-Hashes aus und behauptet keinen aktuellen Runtime- oder SQL-Zustand.
Bei einem unbestätigten Auftragsergebnis muss zuerst der Auftragsstatus und die
Registry erneut gelesen werden; die UI wiederholt keine Aktion automatisch.
Die Reconcile-UI bleibt offen. Die Registry allein beweist keine
Runtimebereitschaft. Die Gruppe erstellt auch kein gemeinsames
Providernetz. Für einen Container-Linked-Server-Fall können zwei getrennte
Runs mit demselben expliziten `NetworkName` angelegt und anschließend
gruppiert werden. Run-Erstellung, Netzwerkerstellung und deren Cleanup bleiben
getrennte Verantwortlichkeiten. Dieses Muster belegt weder Kerberos noch MSDTC
oder eine TLS-Identitätsprüfung.

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

Der begrenzte native Vertrag dafür ist
[`Invoke-LinkedServerEnvironmentGroupAcceptance.ps1`](../../Tests/Integration/Invoke-LinkedServerEnvironmentGroupAcceptance.ps1).
Er legt genau zwei eigene Container-Runs auf einem frisch benannten gemeinsamen
Netz an, weist den Ziel-Run zusätzlich einer zweiten Gruppe zu und prüft eine
synthetische `OPENQUERY`-Abfrage über `MSOLEDBSQL`. Danach muss das Ziel beim
Stop der ersten Gruppe weiterlaufen und erst nach Freigabe der zweiten Gruppe
stoppen. Der Test entfernt nur seine beiden Runs, Gruppen und das zuvor nicht
vorhandene, anhand Name, ID, Label und leerer Endpoints gebundene Netz. Seine
Abnahme ist getrennt für Docker und Podman auszuführen; sie erweitert keine
TLS-, Kerberos- oder Distributed-Transaction-Aussage.

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
