# SqlPackage 170.5.96.0: native Containerabnahme

## Gegenstand und Quellen

Am 2026-10-25 wurde der bestehende SqlPackage-Pfad für SQL Server 2022 unter
Linux getrennt mit Docker und Podman geprüft. Der Katalog und das Toolrezept
verwenden Version `170.5.96.0` und Rezeptversion `2`. Der bisherige
SQL-2022-Basisdigest, die Extraktionsbasis und der libunwind8-Pin bleiben erhalten.

Die [Microsoft-Releaseinformationen](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/release-notes-sqlpackage?view=sql-server-ver17)
und der [Downloadvertrag](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-download?view=sql-server-ver17)
führen auf das versionierte Microsoft-Archiv. Geprüft wurden:

| Eigenschaft | Gebundener Wert |
|---|---|
| Archiv | `sqlpackage-linux-x64-en-170.5.96.0.zip`, 47.298.634 Bytes |
| SHA-256 | `e2ee0d6ec74b9089db926f44fdc681fe5d22bd1e68c938ff10c25a54f53ce5d4` |
| Mitgelieferte Laufzeit | `net10.0`, Microsoft.NETCore.App `10.0.11` |
| Lizenzdatei | `LICENSE.TXT`, Microsoft SQL Server Data-Tier Application Framework |

Der Hash wurde lokal am offiziellen versionierten Download berechnet und
unabhängig nachgeprüft. Er ist keine Herausgebersignatur. Das unveränderte
Containerrezept übernimmt den vollständigen Archivinhalt einschließlich
Lizenzdatei; Binärdateien werden nicht im Repository gespeichert.

## Ausgeführter Umfang

Der unveränderte Harness
[`Invoke-ContainerToolAcceptance.ps1`](../../Tests/Integration/Invoke-ContainerToolAcceptance.ps1)
verwendete je Provider einen frischen eigenen OwnedHost-StateRoot und genau
einen neuen SQL-2022-Run über den normalen Manifestpfad. Bestehende Runtimes
waren erreichbar; sie wurden nicht gestartet oder umkonfiguriert.

| Provider | Native Assertions | Ergebnis | Eigener Cleanup |
|---|---:|---|---|
| Docker | 30 | `PASS` | Run, Container, Volume und eigener Derived-Image-Tag entfernt |
| Podman | 30 | `PASS` | Run, Container, Volume und eigener Derived-Image-Tag entfernt |

Beide Läufe bestätigten die öffentliche Versionsprobe mit `170.5.96.0`,
SQL-Bereitschaft nach Restart und dieselbe erneute Versionsprobe. Ein im eigenen
Run erzeugtes BACPAC wurde exportiert, über den normalen Handler importiert
und per SQL-Marker geprüft. Temporäre BACPAC-Dateien wurden entfernt.

Eine zweite synthetische Datenbank lieferte detachierte MDF/LDF-Dateien für
den normalen Container-Attach. ONLINE-Zustand, SQL-Inhalt und Abschlussjournal
bestanden. Ein kontrollierter zweiter Attach auf die vorhandene Zieldatenbank
erzeugte den erwarteten SQL-Fehler und das zugehörige `RECOVERY_REQUIRED`-Journal.
Das belegt den Fehler-/Journalvertrag, keinen separat ausgeführten
Detach-Recovery-Executor. Der anschließende eigene Run-Cleanup bestand.
Vorhandene Tool-Images behielten ihre Tag- und Image-ID-Bindung.

## Quellbindung und Grenzen

Die Laufzeitquellen stammen von `caa4414df669b49b54f78dbdfb64590793956075`
mit dem gezielten Katalog-/Rezeptdelta dieser Aktualisierung. Vor und nach
beiden Läufen waren die folgenden Bytes gebunden:

| Quelle | SHA-256 |
|---|---|
| `Catalogs/software.json` | `594fe553eb8ba80287b6bf6fb881ae274cf07af901aa8487e6c4c596210d1862` |
| `Images/Tools/Linux/recipe.json` | `009d326840cdf23e648ae814085863885418301a8c587445389900b3a6263080` |

Private Logs, Runtime-IDs, Pfade, Ownershiprecords und Credentials bleiben
außerhalb von Git. Die Abnahme gilt für diesen SQL-2022-Linux-Toolpfad;
Windows, Hyper-V, weitere SQL-Versionen und kombinierte External-Runtime-Images
wurden in dieser Welle nicht neu nativ ausgeführt. Historische Nachweise
behalten ihre ausgewiesenen Versionen und Quellen.

Ein ausdrücklicher alter Softwareversionspin wird nicht automatisch auf die
neue Version umgeschrieben. Bestehende Runs und Images werden nicht verändert.

Die additive Testauswahl bindet Softwarekatalog und Resource-Watch-Fixtures an
ihre tatsächlich ausführende VersionCatalog-Suite. Beide Pfadseparatoren,
reine Fixtures, alle fünf bisherigen Katalog-Providergates und der gemischte
Unknown-Product-Fallback sind geprüft. Elf betroffene lokale statische Suites
und der zusätzliche vorgeschriebene Sample-Handler-Check bestanden.
Ein Implementierer und derselbe unabhängige Reviewer bearbeiten den Scope;
vollständige Logs bleiben lokal. Die finalen PR-Gates bleiben ein eigener
Integrationsnachweis und werden nicht aus diesen lokalen Läufen abgeleitet.
