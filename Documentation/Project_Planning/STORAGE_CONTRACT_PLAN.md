# Storage Contract und Datenwurzel-Migration

## Status

Der versionierte Storage-Contract, Root-Marker, Volume-Mapping, zentrale
Pfadauflösung und die Konsolenverwaltung sind implementiert. Seit 2026-08-29
sind auch Legacy-Default-Übernahme, stabile `LocationId`, vollständige
Parent-Validierung, expliziter Defaultwechsel, Referenzschutz und lokale
Backing-Device-Erfassung umgesetzt. Die vollstaendige volumeuebergreifende
Migration ist weiterhin nicht implementiert und darf bis zu ihrem
End-to-End-Nachweis nicht als verfuegbare Funktion dokumentiert werden.

Die dateigenaue Bindung von SQL-Rollen und einzelnen SQL-Dateien an diese
Locations sowie deren realer Hyper-V-/SQL-Nachweis bleiben offen. Die weitere
Erweiterung ist im
[Konsolen-, Lifecycle- und Storage-Konsolidierungsplan](CONSOLE_LIFECYCLE_AND_STORAGE_CONSOLIDATION_PLAN_2026-08-12.md)
detailliert geplant.

## Ziel

SQL_Server_Lab schreibt generierte und veraenderliche Daten ausschliesslich in
eindeutig verwaltete `Lab_Data`-Wurzeln. Das Git-Repository bleibt Quellcode und
Dokumentation vorbehalten. Nach erfolgreichem `Clear-SqlServerLab` duerfen
ausserhalb des Repositorys, des einmaligen `Lab_Base`, der bekannten
`Lab_Data`-Wurzeln und explizit gemeldeter Runtime-Ressourcen keine durch das
Framework erzeugten Reste verbleiben.

## Verzeichnisrollen

| Rolle | Kardinalitaet | Inhalt |
|---|---:|---|
| Git-Repository | 1 | Quellcode, Dokumentation und statische Definitionen |
| `Lab_Base` | genau 1 | Installationsmedien, Basis-Images und wiederverwendbare Ausgangsartefakte |
| `Lab_Data` | hoechstens 1 je Volume | Run-State, Journale, Secrets, Exporte, Logs, temporaere Dateien und Environment-Daten |

`Lab_Base` ist eine einmalig konfigurierte globale Wurzel. Ein per Volume
konfigurierter Parent fuer `Lab_Data` hat keine Beziehung zu `Lab_Base`.

## Pfadvertrag je Volume

Standard ist das Root des Volumes:

```text
D:\Lab_Data
E:\Lab_Data
```

Falls ein System manuell angelegte Root-Verzeichnisse entfernt, darf je Volume
genau ein persistenter Parent konfiguriert werden:

```text
E:\PersistenteDaten\SQL_Server_Lab\Lab_Data
```

Der Benutzer waehlt bei der Environment-Erstellung nur das Volume. Das
Framework leitet den Zielpfad aus der zentralen Volume-Konfiguration ab. Frei
eingebbare Environment-Pfade sind nicht Teil des Vertrags.

Der als Standard markierte Root ist ausschliesslich der globale Fallback fuer
neue persistente Lab-Ablagen. Das Registrieren einer weiteren Location darf
einen vorhandenen Standard niemals implizit aendern. Ein vorhandener
Legacy-Root wird vor der ersten Erweiterung idempotent uebernommen. Fuer einen
Parent sind nur vollqualifizierte Pfade zulaessig: `D:\` ist gueltig und ergibt
`D:\Lab_Data`; `D:` ist laufwerksrelativ und muss blockiert werden.

Empfohlenes Konfigurationsmodell:

```json
{
  "labBaseRoot": "D:\\Lab_Base",
  "labDataLocations": [
    {
      "volumeId": "\\\\?\\Volume{...}\\",
      "driveLetter": "D:",
      "labDataParent": "D:\\",
      "labDataRoot": "D:\\Lab_Data"
    },
    {
      "volumeId": "\\\\?\\Volume{...}\\",
      "driveLetter": "E:",
      "labDataParent": "E:\\PersistenteDaten\\SQL_Server_Lab",
      "labDataRoot": "E:\\PersistenteDaten\\SQL_Server_Lab\\Lab_Data"
    }
  ]
}
```

Die stabile Volume-ID ist autoritativ. Der Laufwerksbuchstabe dient der Anzeige
und muss bei Aenderungen neu aufgeloest werden.

## Besitz und Sicherheit

Jede `Lab_Data`-Wurzel erhaelt eine Markierungsdatei
`.sql-server-lab-root.json` mit mindestens Contract-Version, `ManagedBy`,
`ControllerId`, Volume-ID und Erstellungszeitpunkt. Das Framework darf eine
Wurzel nur automatisch veraendern oder loeschen, wenn diese Markierung zum
aktiven Controller passt.

Folgende Regeln sind verbindlich:

- Keine generierten Dateien im Git-Repository.
- Keine dauerhaften Dateien in `%TEMP%`, `%APPDATA%` oder beliebigen Profilpfaden.
- Temporaere Dateien liegen unter `<LabDataRoot>\Temp` und werden journalisiert.
- Provider duerfen keine anonymen Volumes oder unregistrierten Ressourcen erzeugen.
- Absolute externe Referenzen werden im Run-State und Cleanup-Manifest erfasst.
- Fremde oder nicht eindeutig markierte Verzeichnisse werden niemals automatisch geloescht.

## Storage-Verwaltung

Die Konsole soll eine zentrale Storage-Verwaltung erhalten:

```text
[1] Lab_Base anzeigen und konfigurieren
[2] Lab_Data-Ablage je Volume anzeigen
[3] Lab_Data-Parent eines Volumes konfigurieren
[4] Lab_Data eines Volumes verschieben
[5] Verwaiste Datenwurzeln und externe Ressourcen pruefen
```

Eine Aenderung von `labDataParent` ist keine einfache Konfigurationsaenderung,
sondern eine kontrollierte Storage-Migration.

## Migrationsvertrag

Eine Migration muss:

1. Betroffene laufende Umgebungen blockieren oder kontrolliert stoppen lassen.
2. Volume-Identitaet, Zielpfad, Besitz, Schreibrechte und freien Speicher pruefen.
3. Einen unveraenderlichen Plan und ein fortsetzbares Journal schreiben.
4. Framework-Daten verschieben und Integritaet pruefen.
5. Hyper-V-, Container-, Bind-Mount- und Katalogreferenzen aktualisieren.
6. Den autoritativen Katalog erst nach erfolgreicher Umschaltung aktualisieren.
7. Bei Fehlern einen eindeutigen `RECOVERY_REQUIRED`-State hinterlassen.
8. Die alte Wurzel nur entfernen, wenn sie leer und eindeutig frameworkverwaltet ist.

Ein einfaches `Move-Item` ist kein gueltiger Migrationsmechanismus, weil Provider
und Run-State absolute Pfade enthalten koennen.

## Umsetzungspakete

| ID | Paket | Ergebnis |
|---|---|---|
| STO-001 | Schreibpfad-Inventur | Alle aktuellen Schreiborte und externen Provider-Ressourcen sind erfasst |
| STO-002 | Storage-Contract | Implementiert: Schema `SqlServerLab.Storage/2.0`, Volume-Mapping und controllergebundener Root-Marker |
| STO-003 | Pfad-Resolver | Implementiert für persistente Environment-Daten und neuen Run-State |
| STO-004 | Guardrails | Implementiert: freie und unmarkierte Environment-Pfade werden abgelehnt |
| STO-005 | Storage-Menue | Implementiert: Anzeige und Parent-Konfiguration; Parent-Wechsel fordert Migration |
| STO-006 | Migrationsplan | Implementiert: unveraenderlicher Plan mit Kapazitaet, betroffenen Runs, Blockern und erforderlichen Aktionen |
| STO-007 | Migration | Implementiert: journalisierte, fortsetzbare Copy/Verify/Switch/Cleanup-Migration; Hyper-V-Rebind automatisch, Container-Bind-Mounts bleiben expliziter Plan-Blocker |
| STO-008 | Cleanup-Audit | Implementiert: read-only Nachweis ueber Datenwurzeln, State, Provider, externe Referenzen und Repository-Reste; Vorher-/Nachher-Audit in `Clear-SqlServerLab` |
| STO-009 | Legacy-Default-Uebernahme | Implementiert: vorhandene Roots bleiben beim Registrieren weiterer Locations autoritativ und werden mit Receipt uebernommen |
| STO-010 | Location-Identitaet und Pfadvalidierung | Implementiert: stabile `LocationId`; laufwerksrelative und nicht normalisierbare Parents werden vor Mutation blockiert und das normalisierte Ziel wird angezeigt |
| STO-011 | Expliziter Default- und Referenzschutz | Implementiert: Defaultwechsel ist eine eigene bestaetigte Aktion; aktive Bindings verhindern Deregistrierung |
| STO-012 | Volume- und Backing-Device-Topologie | Implementiert: logische Volume-Trennung und lokal nachweisbare physische Geraetetrennung werden getrennt ausgewiesen; reale Vier-Geräte-Abnahme bleibt bei SFP/HVS |
| STO-013 | Location-basierte Migration | Implementiert: Plan und Journal verwenden stabile Location-/Volume-IDs statt fluechtiger Laufwerksbuchstaben |
| SFP-001 | Storage-Intent und lokaler Bound Plan | Portable Rollenanforderungen und konkrete lokale Location-/Geraetebindungen sind getrennt versioniert |
| SFP-002 | Dateigenaue SQL-Platzierung | User-Data, User-Log, Backup, jedes TempDB-Datenfile und TempDB-Log sind einzeln plan- und reviewbar |
| SFP-003 | TempDB-Verteilungsregeln | Explizite, Round-Robin-, Volume- und physische Geraetemodi blockieren unzureichende oder unbekannte Topologie |

## Abnahmekriterien

- Jeder generierte Dateipfad ist einer bekannten `Lab_Data`-Wurzel zugeordnet.
- `Lab_Base` ist genau einmal vorhanden und wird nicht als per-Volume-Parent missverstanden.
- Pro Volume existiert hoechstens eine aktive, controllergebundene `Lab_Data`-Wurzel.
- Environment-Erstellung bietet eine Volume-, aber keine freie Pfadauswahl an.
- Das Hinzufuegen einer Location aendert keinen vorhandenen globalen Default.
- `D:` und andere laufwerksrelative Parents werden abgelehnt; das normalisierte
  Ziel wird vor der Bestaetigung angezeigt.
- SQL-Data, SQL-Log, Backup, einzelne TempDB-Datenfiles und TempDB-Log koennen
  getrennt gebunden werden.
- Vier TempDB-Files gelten nur bei paarweise disjunkten nachgewiesenen
  Backing-Devices als auf vier physischen Datentraegern getrennt.
- Ein Parent-Wechsel ist vorab als Plan sichtbar und nach Unterbrechung fortsetzbar.
- `Clear-SqlServerLab` meldet alle nicht dateibasierten oder externen Reste explizit.
- Nach erfolgreichem Cleanup koennen Repository, `Lab_Base` und alle bekannten
  `Lab_Data`-Wurzeln ohne weitere Framework-Reste entfernt werden.
