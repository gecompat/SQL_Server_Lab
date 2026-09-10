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

Ohne Manifest-Intent gelten ausdrücklich `DE`, `de-DE`, `en-US`,
`0407:00000407` und `W. Europe Standard Time`. Der bestehende
`New-SqlServerLabWindowsSlotPool` behält seine Parameterdefaults `AT` und
`de-AT`; seine übrigen Defaults entsprechen diesen Werten. Hostregion,
Hosttastatur und Hostzeitzone werden nicht übernommen. Explizite CLI-Parameter
dürfen einem expliziten Manifest-Intent nicht widersprechen.

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
Der direkte SQL-Prepared-Manifestlauf ist damit nicht separat nativ belegt.
