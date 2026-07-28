# Beitragen zu SQL_Server_Lab

## Geltungsbereich

Diese Regeln gelten für Änderungen an Code, Manifesten, Katalogen, Dokumentation, Tests und Provider-Metadaten.

Das Repository ist nicht Open Source. Rechte zur Nutzung, Weitergabe und Veränderung ergeben sich ausschließlich aus `LICENCE.md` und den vom Repository-Eigentümer erteilten Berechtigungen.

## Vor jeder Änderung

1. Root-`README.md` und `.ai/repo_map.yaml` lesen.
2. `Documentation/Quality/KNOWN_LIMITATIONS.md` prüfen.
3. Betroffene öffentliche Verträge bestimmen.
4. Verifizieren, ob bereits ein offener Branch oder Pull Request dieselbe Änderung enthält.
5. Sicherstellen, dass keine realen Secrets, personenbezogenen Daten, Kundendaten, Firmendaten, Hostinformationen oder proprietären internen Artefakte übernommen werden.

## Privacy- und Sicherheitsregel

Nicht versioniert werden dürfen insbesondere:

- Passwörter, Tokens, Zertifikate und Connection Strings mit Secrets
- Run-State, Secret-Dateien und Cache-Inhalte
- reale Hostnamen, IP-Adressen außerhalb bewusst generischer privater Beispiele, lokale Benutzerpfade oder Umgebungsdetails
- Produktionsbackups oder aus Produktivsystemen extrahierte Daten
- Screenshots, Logs oder Diagnoseausgaben mit nicht freigegebenen realen Informationen
- Kundennamen, Benutzerkonten, E-Mail-Adressen oder interne Organisationsdaten

Bei Unsicherheit muss die Verarbeitung vor dem Schreiben oder Committen angehalten und geklärt werden.

## Branches und Pull Requests

- Branch-Namen für automatisierte Arbeit: `agent/<kurze-beschreibung>`
- Ein Pull Request behandelt einen klar abgegrenzten Zweck.
- Unabhängige Änderungen werden nicht vermischt.
- Vor dem Merge müssen Diff, Tests, Dokumentation und bekannte Grenzen geprüft werden.
- Nach dem Merge wird der Arbeitsbranch entfernt, sofern er nicht ausdrücklich weiter benötigt wird.

## Commit-Nachrichten

Commit-Nachrichten sollen knapp und fachlich eindeutig sein. Die bestehende Projektkonvention verwendet englische Commit Messages; diese eigenständige Konvention ist kein Verstoß gegen die deutsche Dokumentationssprache.

Für von einer KI erzeugte Änderungen muss die Commit-Nachricht mit dem Namen der tatsächlich ausführenden KI und einem Doppelpunkt beginnen. Die KI verwendet dabei ihre eigene Produkt- oder Agentenbezeichnung und nicht pauschal einen gemeinsamen Sammelbegriff.

Format:

```text
<KI-Name>: <Commit-Nachricht>
```

Beispiele:

```text
ChatGPT: Correct Podman lifecycle provider selection
Codex: Add sample catalog schema validation
Genie: Align Getting Started with implemented restore parameters
```

Bei einem direkten Commit durch die KI darf die Commit-Nachricht zusätzlich einen mehrzeiligen Body enthalten, wenn dies für Scope, Auswirkungen oder Validierung sinnvoll ist. Das Präfix ist nur in der ersten Zeile erforderlich.

Kann die KI nicht direkt auf das Repository zugreifen und liefert stattdessen Dateien, einen Patch oder ein Downloadartefakt zur manuellen Übernahme, muss sie zusätzlich eine vollständige einzeilige Commit-Nachricht in einem separat kopierbaren Textblock bereitstellen. Auch diese Nachricht verwendet das KI-Präfix.

Beispiel für eine manuelle Übernahme:

```text
ChatGPT: Add GitHub-hosted Docker smoke
```

Für ausschließlich von Menschen erstellte Änderungen ist kein KI-Präfix erforderlich.

## PowerShell-Regeln

- Mindestversion: PowerShell 7.2
- Öffentliche Funktionen folgen dem PowerShell-Verb-Nomen-Schema.
- Neue öffentliche Funktionen benötigen comment-based Help.
- Interne Funktionen werden nicht in Benutzeranleitungen als stabile API verwendet.
- Fehler müssen mit hinreichendem Kontext abbrechen; stille Fallbacks auf vermutete Versionen, Provider oder Dateien sind zu vermeiden.
- Secrets dürfen nur so kurz wie technisch erforderlich als Klartext vorliegen und müssen anschließend verworfen werden.
- Mutierende Abläufe benötigen einen vorher angelegten Cleanup- oder Recovery-Pfad.

## Änderung öffentlicher Cmdlets

Bei einer neuen oder geänderten exportierten Funktion sind gemeinsam zu prüfen:

- `SqlServerLab.psd1`
- Implementierung und comment-based Help
- `Public/README.md`
- Root-`README.md`
- `Documentation/User/Getting_Started.md`
- `.ai/repo_map.yaml`
- statische Prüfung
- relevanter Integrationstest

Nicht implementierte Funktionen dürfen nicht in `FunctionsToExport` stehen.

## Änderung von Manifestfeldern

Ein Manifestfeld ist erst vollständig implementiert, wenn alle Ebenen übereinstimmen:

1. `Schemas/lab-manifest.schema.json`
2. `Private/ManifestParser.ps1`
3. zuständige Runtimefunktion
4. mindestens ein korrektes Beispiel
5. Dokumentation und Known Limitations
6. statische oder Integrationstests

Ein Schemaeintrag allein ist kein Runtime-Nachweis.

## Änderung von Providern

Gemeinsam zu pflegen sind:

- `Providers/<Provider>/<Provider>Provider.ps1`
- `Providers/<Provider>/provider.json`
- Provider-README
- Root-README und Known Limitations
- Lifecycle-Cmdlets, sofern die Providerbindung betroffen ist
- eigener Smoke-Test-Lauf für den Provider

Docker- und Podman-Tests sind getrennte Nachweise.

## Änderung von Katalogen

Bei Versionen, Builds oder Sample-Datenbanken sind gemeinsam zu prüfen:

- Katalog-JSON
- zugehöriges JSON-Schema
- Auflösungslogik in `Private/VersionCatalog.ps1` oder `Private/ManifestParser.ps1`
- `Catalogs/README.md`
- statische Prüfung
- fachliche Quelle, Lizenz und gegebenenfalls Prüfsumme

Neue CU- oder Buildangaben dürfen nicht aus einer vermuteten Tag-Konvention erfunden werden.

## Lokale Validierung

Mindestens ausführen:

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

Bei Runtimeänderungen zusätzlich:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

Nur verfügbare Provider können lokal getestet werden. Ein nicht ausgeführter Test muss im Pull Request ausdrücklich genannt werden.

## Sprachstil und Übersetzungen

- Die Primärsprache der aktiven Projektdokumentation ist Deutsch.
- Jedes Dokument und jeder zusammenhängende Text verwendet grundsätzlich eine klare Hauptsprache. Unbeabsichtigte Mischsprache ist zu vermeiden.
- Technische Fachbegriffe, Produktnamen, Programmiersprachen, SQL-Befehle, API-Namen, Dateinamen, Parameter, Cmdlets, Klassen-, Funktions- und Variablennamen werden nicht übersetzt.
- Etablierte englische IT-Begriffe wie `Repository`, `Branch`, `Commit`, `Pull Request`, `Workflow`, `Provider`, `Runtime`, `State`, `Cleanup` oder `Smoke Test` dürfen in deutscher Dokumentation verwendet werden, wenn eine deutsche Übersetzung ungebräuchlich oder missverständlich wäre.
- Künstliche oder neu erfundene Übersetzungen technischer Begriffe sind nicht zulässig.
- Gleiche Fachbegriffe werden projektweit konsistent verwendet; synonyme Wechsel wie `Provider`/`Anbieter` oder `Branch`/`Zweig` sind zu vermeiden.
- Bestehende Dokumentation wird nicht allein zur sprachlichen Vereinheitlichung vollständig übersetzt. Übersetzungen erfolgen nur auf ausdrücklichen Auftrag, zur Behebung eines konkreten Konsistenzproblems oder für ausdrücklich gepflegte Sprachversionen.
- Neue Texte orientieren sich am Sprachstil des jeweiligen Dokuments und fügen sich unauffällig in die vorhandene hochwertige Dokumentation ein.
- Kommentare in Quellcode folgen der im jeweiligen File bereits vorherrschenden Sprache. Bestehende Kommentare werden nicht ohne fachlichen Grund übersetzt.
- Texte sind sachlich, eindeutig, technisch präzise, gut lesbar und möglichst zeitlos zu formulieren.
- Marketing-Sprache, übertriebene Werbung, unnötige Füllwörter, emotionale Wertungen, Spekulationen und unbegründete Behauptungen sind zu vermeiden.
- Aktive Formulierungen sind zu bevorzugen, sofern sie klarer sind als passive Formulierungen.
- Code, Befehle, Konfigurationswerte und Beispiele bleiben technisch unverändert und müssen der tatsächlichen Implementierung entsprechen; sie werden nicht sinngemäß übersetzt.
- Ist-Stand, Planung, Entscheidung und Vermutung sind sprachlich klar zu trennen.
- Nicht implementierte oder teilweise implementierte Funktionen werden ausdrücklich gekennzeichnet.
- Beispiele verwenden keine individuellen Entwicklerpfade.
- Relative Links und referenzierte Dateien müssen existieren.
- Projekt- oder artefaktspezifische Sprachkonventionen, etwa englische Commit Messages, bleiben erhalten und werden ausdrücklich dokumentiert.

## Pull-Request-Abnahme

Vor dem Merge muss die Beschreibung mindestens enthalten:

- Problem und Ursache
- konkrete Änderung
- Auswirkungen auf Benutzer und konsumierende Projekte
- ausgeführte Prüfungen
- nicht ausführbare Prüfungen mit Begründung
- neue oder verbleibende Grenzen
- Privacy-Prüfung
