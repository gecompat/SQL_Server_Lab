# Windows-Region, Sprache und Tastatur

Windows-Instanzen beschreiben ihre Einstellungen in `instances[].windowsLocale`.
Das [US-Beispiel](../../Schemas/example-hyperv-locale-us.json) kann mit
`New-SqlServerLab -ManifestPath ./Schemas/example-hyperv-locale-us.json`
ausgeführt werden, wenn eine passende veröffentlichte SQL-Prepared-Baseline
und die üblichen Hyper-V-Voraussetzungen vorhanden sind. Die Imageauswahl
und der Secret-Bezug folgen dem bestehenden Manifestvertrag.

Der vollständige Vertrag `SqlServerLab.WindowsLocaleIntent/1.0` enthält:

| Feld | US-Beispiel | Bedeutung |
|---|---|---|
| Region | US | Heimatregion, unabhängig von Sprache und Tastatur |
| SystemLocale | en-US | Windows-Systemkultur |
| UiLanguage | en-US | Durch das ausgewählte Image belegte UI-Sprache |
| InputLocale | 0409:00000409 | Windows-Sprache und Tastaturlayout als Input Method Tip |
| TimeZone | Pacific Standard Time | Windows-Zeitzonenbezeichner |

Ohne Manifest-Intent gelten ausdrücklich `DE`, `de-DE`, `en-US` und
`W. Europe Standard Time`. Fuer `InputLocale` liest der Resolver im aktuellen
interaktiven Windows-Benutzerkontext `Get-WinUserLanguageList`. Genau eine
verschiedene, freigegebene Input Method Tip wird als `host-current-user`
gebunden. Identische Duplikate bleiben eindeutig. Bei mehreren verschiedenen,
fehlenden oder nicht freigegebenen Methoden, auf Nicht-Windows-Hosts, in einem
System-/Dienstkonto oder ohne lesbaren interaktiven Benutzerkontext gilt
`0407:00000407` als `compatibility-default`; ein stabiler
`HOST_INPUT_LOCALE_*`-Grundcode erklaert den Fallback. Ein zufaellig aktives
Fensterlayout wird nicht gelesen.

`InputLocaleSource` und der optionale `InputLocaleReasonCode` sind aufgeloeste
read-only Metadaten. Der Manifest-Wizard fragt sie nicht als Eingabe ab. Ein
explizites `InputLocale` in Manifest, CLI, Batch oder Menue hat Vorrang und
bleibt bei unbekannten beziehungsweise nicht freigegebenen Werten ein
Validierungsfehler. Hostregion und Hostzeitzone werden weiterhin nicht
uebernommen. Der bestehende `New-SqlServerLabWindowsSlotPool` behaelt seine
Parameterdefaults `AT` und `de-AT`; seine Tastatur folgt derselben gemeinsamen
Auswahl. Explizite CLI-Parameter duerfen einem expliziten Manifest-Intent nicht
widersprechen.

Manifest-Wizard, direkte Workflow-Aktion, Slot-Pool und Batch nutzen denselben
Resolver. Ein Batch-Item kann das vollständige Objekt unter
`intent.WindowsLocale` enthalten. Der Batch führt dann vor seinem Startabschluss
die vorhandene unbeaufsichtigte OOBE mit generiertem, im Run DPAPI-geschützt
gespeichertem Gastkennwort aus. Batch-Items ohne diesen Intent behalten ihren
bisherigen Ablauf. Ein ausdrücklich gesetztes `RequiresUserSetup` bleibt ein
zusätzliches Benutzer-Gate. Das Kennwort ist über die bestehende öffentliche
Zugriffsfunktion für generierte Windows-Zugänge abrufbar.

Die UI-Sprache muss mit `operatingSystem.language` des gewählten Images
übereinstimmen. Fehlender Sprachnachweis und nicht unterstützte Sprachen
blockieren vor der ersten VM-Mutation. Offline-Language-Pack-Installation ist
noch nicht implementiert. Unterstützte eingebaute Tastaturlayout-IDs sind
`00000407`, `00000409`, `00000809`, `00000807`, `0000100C` und `0000040C`
(Deutsch, US, UK, Schweizerdeutsch, Schweizerfranzösisch und Französisch).
Andere Layouts werden explizit abgewiesen. Die Bezeichner folgen den
[Windows-Sprach- und Eingabestandards](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-language-pack-default-values?view=windows-11).

Bei Erstellung mit Intent wird dieser im Sollzustand, in Run-Metadaten, der
Run-Verbindung und `manifest.lock.json` gebunden. Die OOBE eines bereits
vorhandenen unkonfigurierten Slots ergänzt Run-Verbindung und Lock.
Die Spezialisierung verändert
nur die eigene Child-VHDX. `windows-locale-receipt.json` enthält den Intent,
die beobachteten Werte, Run-ID und Zeitpunkt. `POST_OOBE_VERIFIED` bestätigt
die OOBE-Beobachtung; es behauptet keinen zusätzlichen Kaltstartnachweis.
Der gesonderte Hyper-V-Akzeptanztest prüft diesen nach vollständigem Ausschalten.

Statische Prüfungen: `Tests/Static/Invoke-WindowsLocaleChecks.ps1` sowie die
gekoppelten Manifest-, Batch-, Slot-Pool- und Hyper-V-Suites. Der native
Nachweis `Tests/Integration/Invoke-HyperVWindowsLocaleAcceptance.ps1` benötigt
eine englische `OS_SEALED`-Baseline, einen erhöhten Prozess, 5 GB freien RAM
und 20 GB freien Platz. Er serialisiert sich mit anderen Runtime-Smokes,
führt nur seinen eigenen Batch aus und entfernt dessen Run. Bei fehlgeschlagenem
Cleanup bleibt der State für Recovery erhalten. Seine bloße Existenz ist kein
Nachweis eines erfolgreichen Laufs.

Am 2026-09-10 hat [Run 34435602810](https://github.com/gecompat/SQL_Server_Lab/actions/runs/34435602810)
auf Commit `bbd29e7` den Windows-Server-2025-Batch mit dem geparsten US-Manifest,
OOBE, Kaltstart, allen fuenf Locale-Werten und vollstaendigem Cleanup bestaetigt.
Dieser ältere Lauf belegt den OS-Batch-Pfad; der direkte SQL-Prepared-Pfad
wurde anschließend separat abgenommen.

Die direkte SQL-Prepared-Locale-Abnahme ist als separater manueller Workflowmodus
`sql-prepared-locale-acceptance` verfügbar. `image_artifact_id` ist dabei eine
explizite verifizierte englische SQL-2025-Prepared-ID; `prepared_locale_state_root`
bindet den bestehenden Artifactkatalog und ausschließlich den neuen eigenen Run.
Der Checkout muss exakt dem 40-stelligen `GITHUB_SHA` desselben Repositorys entsprechen.
Ein Clone-Quellrun ist in diesem Modus verboten; zusätzliche Berechtigungen werden
nicht eingerichtet. Der bestehende erhöhte Hyper-V-Runner führt die Abnahme aus.

Die Abnahme bindet Operation, Run, Scope und VM-ID vor Stop/Start sowie jeder
Gast-/SQL-Probe neu. Nach dem Kaltstart werden alle fünf Locale-Werte und ein echter
SQL-SELECT über die vorhandene Capture-Probe geprüft (SQL-Major 17, Instanz und Edition).
`EvaluationOnline` mit `AllowTemporary` verwendet den vorhandenen Aktivierungsvertrag;
aktiver Lizenzzustand und gegebenenfalls Adapter-Cleanup werden geprüft.
Der OOBE-Receipt bleibt separat vom Kaltstartnachweis; der Parent wird tatsächlich
vor und nach dem Lauf gehasht. Cleanup kontrolliert die exakten VM-IDs und Child-Disks,
auch bei verlorener New-Rückgabe.

Am 2026-09-21 bestand [Run 35574934252](https://github.com/gecompat/SQL_Server_Lab/actions/runs/35574934252)
auf Commit `bf72dc32` die direkte Abnahme mit einem englischen SQL-2025-Prepared-
Artifact: frischer eigener US-Manifest-Child, alle fünf Locale-Werte nach Kaltstart,
VM-ID-gebundener SQL-SELECT mit Major 17, aktiver Windows-Lizenzzustand,
Locale-Receipt und unveränderter Parent-Hash. Der überwachte Cleanup endete mit
`COMPLETED`; der genau zugehörige Run-State wurde separat als `REMOVED` bestätigt.
Andere Image-Sprachen und SQL-Versionen sind durch diesen Referenzlauf nicht belegt.

Der CI-Parent legt vor Arrange eine Operation-ID fest und überwacht einen verborgenen
Kindprozess (maximal 90 Minuten). Erst nach bestätigtem Prozessende startet er den
separaten eigenen Cleanup (maximal 15 Minuten); beide verwenden
`Global\SQL_Server_Lab_Runtime_Smoke`. Bei unbestätigtem Ende bleibt Cleanup gesperrt.
Rohmeldungen, Operation-Bindung und kleine Statusquittungen bleiben im nur für den
Runnerbenutzer zugänglichen lokalen Temp-Verzeichnis
`sql-server-lab-prepared-locale-ci-*`, außerhalb des Repositorys und ohne Upload.
GitHub erhält ausschließlich feste Ergebnis-/Fehlercodes. Ein erfolgreicher Cleanup
verdeckt keinen ursprünglichen Fehler; fehlgeschlagener Cleanup erfordert lokale Recovery.
