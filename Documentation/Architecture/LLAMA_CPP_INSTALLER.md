# Kuratierter llama.cpp-Runtimeinstaller

Slice H (`AIX-001/008`) stellt einen begrenzten Ressourcenworkflow für lokale
SQL-Server-KI-Integrationen bereit. Der erste Pin ist **experimentell**:
Windows, x64, CPU, b11247. Andere Kombinationen bleiben offen. Empfehlung:
`UNASSESSED`. Modelldownload, Dienststeuerung und Compute-Auswahl sind getrennt.

## Integrität und Herkunft

Der Repositorykatalog bindet Release-ID, Asset-ID, Dateiname, Größe, SHA256,
Commit und die vollständige Dateimenge einschließlich Einzelhashes.
Die bewusst begrenzte Trustbasis ist die offizielle
[ggml-org/llama.cpp-Distribution](https://github.com/ggml-org/llama.cpp/releases/tag/b11247)
mit offiziellem GitHub-Assetdigest und anschließend kuratiertem Repositorypin.
Dies ist **keine unabhängige Signatur**; der Upstreamrelease ist nicht immutable.
Fehlende oder geänderte Metadaten sperren, statt einen neueren Release auszuwählen.
„Upstream prüfen“ liest nur die Metadaten dieses Pins; es ist kein vollständiger
Releasekatalog und aktualisiert den Repositorykatalog nicht automatisch.

Der initiale ZIP-Pin umfasst 51 reguläre Rootdateien. Alle Dateien werden
beibehalten; `llama.exe` enthält aggregierte Notices für llama.cpp, jsonhpp,
cpp-httplib, BoringSSL und LLVM. `LICENSE-LLVM-OpenMP` liegt zusätzlich bei.
Maßgeblich sind die [MIT-Lizenz](https://github.com/ggml-org/llama.cpp/blob/0bc845d356f437d5ce4fe975c36428f7522829cb/LICENSE)
und die mitgelieferten Drittanbieterhinweise. Das Repository verteilt hier nur
den Pin und die Verträge, keine Runtimebinärdateien.

Statische PE- und Buildquellenanalyse belegt AMD64, mitgeliefertes libomp und
CPUvarianten einschließlich x64-Fallback. Externe VC140-/MSVCP140-/UCRT-DLLs
werden benötigt. Konkrete Mindest-VC-Version und vollständige OS-/CPU-Unterstützung
bleiben `UNKNOWN`; PE-Header6.0 und x64-Dateinamen sind keine Supportgarantie.
Der Installer ergänzt weder VC-Runtime noch Treiber. Eine fehlende Voraussetzung
oder fehlgeschlagene Paketprobe beendet den Vorgang ohne Veröffentlichung.

## Auswahl, Vorschau und Veröffentlichung

CLI: Ressourcen und Downloads → llama.cpp-Runtime installieren / prüfen,
auch `Invoke-SqlServerLab -Action RuntimeInstaller`.
GUI: derselbe Bereich, eigener Fachdialog mit Release, unterstützter
OS-/Architektur-/Backendkombination, vorhandenem Lab_Base und Vorschau.
Weitere Kombinationen werden nicht als ausführbar angeboten.

Der Client liefert ausschließlich kuratierte Kandidaten-ID, opaque Root-ID,
ExpectedKey und separate boolesche Bestätigung. Quellen-URLs, Hashes und Pfade
sind keine Clientautorität. Vorschau und lokales Neulesen schreiben nichts.
F5/r ist lokal; Upstreamabfrage und Installation sind getrennte bewusste Aktionen.
Windows verwendet einen globalen, canonical-rootgebundenen Mutex. Link-/Reparse-
Roots, UNC- und Netzlaufwerksziele werden in der initialen lokalen Lane abgewiesen.
Unter Lock werden Rootauthority, Katalog und Zielzustand
frisch geprüft. Ein vollständig byteverifizierter passender Bestand ist No-op
vor Download oder Ausführung. Bestandsdrift wird nicht überschrieben.

Die Übertragung ist HTTPS-only, unauthentifiziert, ohne Cookies oder Proxy,
mit höchstens drei einzeln validierten Redirects zu fest erlaubten GitHubhosts.
Größe, Streambytes und Zeit sind begrenzt. Erst exakte Größe und SHA256 erlauben
die ZIP-Verarbeitung. Alle Einträge werden vor Extraktion auf die vollständige
kuratierte flache Dateimenge, Größen, Typen und Kollisionen geprüft; Links,
Pfadwechsel, Sonderdateien, ADS und Windows-Gerätenamen sind unzulässig.
Entpackte Bytes werden während des Kopierens begrenzt und einzeln gehasht.

Die eigene Operation liegt neben dem versionierten Ziel unter
`Lab_Base/AI/Runtimes/llama.cpp`. Erst nach Paketprüfung, begrenzter Probe und
erneuter Dateimengen-/Hashprüfung wird der eigene Stage ohne Überschreiben
atomar veröffentlicht. Receipt und Journal gehören nicht zum Runtimepaketdigest.
Der Rückgabewert enthält den exakten SearchRoot für bestehende Discovery;
`FILES_ONLY`/`UNVERIFIED` bleiben deren unveränderte DTO-Semantik.
Es gibt keine Aktivierung, PATH-, Modell-, Dienst- oder Defaultänderung.

## Begrenzte Ausführung und Recovery

Vor Bestätigung wird genau `llama-server.exe --version` angekündigt:
maximal15 Sekunden und kumulativ64KiB stdout/stderr. Exit0 **und** build11247/
commit0bc845d35 sind erforderlich. Kein `--help`-Ersatz. Der vorhandene eigene
Windows-Jobworker schützt den Prozessbaum auch bei Ownerverlust. Paketdateien
sind während der Probe gegen Schreibzugriff gesperrt. Ein eigener leerer CWD
und eine neu aufgebaute Environment binden auch PROGRAMDATA/APPDATA/Profil-/
Temppfade an den eigenen Scope; geerbte Modell-, Proxy- und Credentialvariablen
werden nicht übernommen. Native Ausgaben bleiben begrenzt und lokal.
Nach bestätigtem Copy-Ende werden beide Logwriter geschlossen, bevor der
Worker die vollständige Ausgabe auf die feste Build-/Commitidentität prüft.

`BINARY_PROBE_PASSED` bezeichnet ausschließlich Paketausführbarkeit;
Compute, SQL, Modelle und Backendleistung bleiben `NOT_CHECKED`.
Ein UI-Verbindungsverlust bestätigt weder Erfolg noch Abbruch. Vor Apply ist
Abbrechen schreibfrei; während Apply wartet die UI den begrenzten Vorgang ab.
Cleanup entfernt ausschließlich den im selben Aufruf erzeugten, identitäts-
geprüften Stage nach bestätigtem Worker- und ausdrücklich bestätigtem Childende.
Workerexit allein, fehlende Endeevidence oder ein Recoveryreceipt erlauben kein
Cleanup; ein falsches/fehlendes WaitForExit-Ergebnis bleibt unbestätigt.
Auch eine bestätigt beendete, fehlgeschlagene Probe bewahrt die private Operation
mit begrenzter Diagnose. Feste Fehlerklassen unterscheiden Paket-/Workersetup,
Startfehler, Outputlimit, Timeout, Ownerverlust, Exitcode und Versionsabweichung.
`LaunchAttempted`, `ProbeStarted`, nullable Exitcode und
`ChildTerminationConfirmed` bleiben getrennt. Eine bewahrte Diagnose bedeutet
nicht, dass noch ein Prozess läuft. Raw-Ausgaben bleiben ausschließlich lokal;
Vorprobe-Downloadfehler behalten den bisherigen eigenen Cleanup.
Ein bereits vorhandener Vorgang,
unklares Prozessende oder unbestätigter Cleanup bleibt `RECOVERY_REQUIRED`.
Es gibt **keine automatische Probe-Wiederholung, Journalpfad-Ausführung oder
Entfernung älterer Ziele**. Manuelle Recovery benötigt einen separat geklärten
Own-Vertrag; der Installer bietet keinen allgemeinen Lösch-/Repairpfad.

## Evidencegrenze

Fokussierte synthetische Checks führen reale Plan-/Apply-/Transport-/ZIP-/CLI-/
HTTP-/DOM-Pfade mit synthetischen Bytes und abgegrenzter Probe aus. Sie ersetzen
keine native Windows-Paketprobe. Am 2026-09-29 bestand ein neuer eigener
Windows-x64-CPU-Nachweis neun Prüfungen: echte Vorschau und Abbruch,
Installieren mit Exit0 und exakter Build-/Commitidentität, vollständige
51-Dateien-Prüfung, unveränderte Discovery-Semantik, frischer No-op sowie
Stale-/Drift-Abweisung. Eigenes Fixture- und Prozess-Cleanup wurde bestätigt.
Das ist `BINARY_PROBE_PASSED`, keine SQL-, Modell- oder Computeabnahme.

Zwei vorherige Versuche bleiben fehlgeschlagen: Die erste genaue Ursache
bleibt mangels erhaltener Diagnose `UNKNOWN`. Die zweite gestartete Probe
bestätigte Exit0 und Buildidentität, scheiterte aber am anschließend synthetisch
korrigierten Ausgabereader. Ihre privaten Diagnosebelege bleiben erhalten;
der spätere Erfolg schreibt diese Historie nicht um. Weitere Releases,
OS-/Backendpfade, allgemeine Kompatibilität und Empfehlungen bleiben offen.
