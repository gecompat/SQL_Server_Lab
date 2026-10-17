# Native Linux-Clientfähigkeit vor einer TLS-Abnahme

| Merkmal | Wert |
|---|---|
| Stand | 2026-10-16 (UTC) |
| Ergebnis | Linux-PowerShell, SqlClient-Konstruktion und erster sqlcmd-Hilfeaufruf ausgeführt; authentifizierte Linux-SQL-Verbindungen nicht ausgeführt |
| Quelle | `eb7dd890a354c5400f522e70cd49fa0f9c652e6e`, integriert mit [PR774](https://github.com/gecompat/SQL_Server_Lab/pull/774) |
| Quellen-Pflichtgate | [Run 38981729683](https://github.com/gecompat/SQL_Server_Lab/actions/runs/38981729683): erforderliche Windows-, Ubuntu- und PR-Gates am exakten PR-Head erfolgreich |

Diese begrenzte Vorbereitung ergänzt die
[Windows-Containermatrix](TLS_WINDOWS_CONTAINER_VERSION_MATRIX_2026-10-16.md).
Sie prüft verfügbare Linux-Clientbausteine vor einer konkreten Trustentscheidung.
Sie registriert keinen Linux-Clientkontext und qualifiziert keinen SQL-Zielbuild.

## Tatsächlich beobachtet

| Bereich | Beobachtung und Aussagegrenze |
|---|---|
| Laufzeit | PowerShell `7.6.6`, .NET `10.0.12`, X64 auf Ubuntu `24.04.4 LTS` im eigenen Clientcontainer |
| System.Data.SqlClient | Geladene Assemblymetadaten `4.6.1.6`; Objekt mit `Encrypt=True`, `TrustServerCertificate=False`, `Pooling=False` und Timeout 1 konstruiert. Ein Open am absichtlich nicht verfügbaren lokalen Port lieferte `SqlException`, keine Abfrage. Dies ist API-/Netzwerkpfad-Evidence, kein TLS- oder erfolgreicher SQL-Verbindungsnachweis. |
| Natives sqlcmd | Erstes erwartetes Application-Ziel im ausdrücklich gesetzten eigenen Prozess-PATH frisch dateigebunden; `-?` endete mit Exit 0 und meldete `18.6.0002.1 Linux`. Kein Serverkontakt. Ein tatsächlich geladener ODBC-Treiber wurde nicht beobachtet. |
| Trust | Keine Lab-CA-Datei, kein Import und keine `SSL_CERT_FILE`-/`SSL_CERT_DIR`-Vorgabe. Die Windows-CurrentUser-Freigabe wurde nicht erweitert. |
| SQL | Kein SQL-Server im Clientcontainer gestartet und keine SQL-Abfrage ausgeführt. Der Container hatte kein externes Netzwerk. |

Assemblymetadaten und Dateidigests sind getrennte Beobachtungen; ein Digest
des tatsächlich geladenen Speicherimages wird nicht behauptet. Aus vorhandenem
sqlcmd oder einem Netzwerkfehler folgt weder wirksamer Client-Trust noch eine
erfolgreiche Zertifikatsprüfung.

Das offizielle [PowerShell-Releasepaket](https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6)
wurde einmal größen- und SHA-256-gebunden geladen. Auf dem Windows-Host wurde
es weder entpackt noch installiert. Die Ausführung erfolgte ausschließlich
im eigenen Container aus dem bereits vorhandenen festen SQL-2025-CU9-Stockimage;
dessen SQL-Entrypoint wurde durch einen begrenzten Sleep-Prozess ersetzt.
Das Image als Clientbasis beweist keinen laufenden SQL Server.

## Eigener Scope, Fehlerbelege und Cleanup

Die Fixture hatte keine Hostmounts oder veröffentlichten Ports, ein
schreibgeschütztes Root-Dateisystem, zwei eigene tmpfs-Pfade, verworfene
Capabilities und keine neuen Privilegien. CPU, RAM, PID-Anzahl und Laufzeit
waren begrenzt. Clientprozesse liefen als fest gebundener unprivilegierter
Benutzer; nur Paketübertragung und Entpacken schrieben als eigener
Container-Root in das eigene tmpfs. Native Metadaten und tatsächlich beobachteter
Dateisystemtyp wurden vor den Nutzdatenoperationen getrennt geprüft.
Run-/Scopeübernahme oder eine Bindung fremder Ressourcen erfolgte nicht.

Eine erste eigene Fixture scheiterte vor der Clientprobe: Die Copy-API
verweigerte die Übertragung bei schreibgeschütztem Container-Root. Der eigene
Container wurde entfernt; der nächste separat gebundene Scope übertrug nur
die frisch geprüften öffentlichen Paket-/Probedateien über begrenztes STDIN
in das eigene tmpfs. Das Root-Dateisystem blieb schreibgeschützt.
Der zweite Lauf erreichte Linux-PowerShell und sqlcmd, blieb beim
SqlClient-Testinitialisierer vor Open aber mit `ArgumentException` unbestätigt.
Eine Offline-Reproduktion zeigte den fehlerhaften `DataSource`-Dictionarysetter;
der feste Konstruktor wurde geprüft und in einem neuen eigenen Scope verwendet.
Der abschließende Lauf lieferte die obigen tatsächlichen Beobachtungen.
Kein alter Intent wurde wiederholt oder nachträglich überschrieben.

Alle drei eigenen Fixturecontainer wurden entfernt. Workerende und eigene
Ressourcenabwesenheit sind bestätigt; vorher erfasste Run-, Root-, Katalog-
und Exportdateien blieben bytegleich, nach jedem Workerende frisch geprüft.
Private Intents, Quellbindungen, erste Fehler und Cleanupbelege bleiben erhalten.
Jeder Abschnitt hatte ein dokumentiertes endliches gemeinsames Budget mit
höchstens einem neuen Clientcontainer und genau einem Implementierer.
Stabile Quellen und enge Folgediffs wurden unabhängig geprüft.

Der neue Prozess-/Ausgabepfad bestand zunächst zwölf lokale Checks.
Nach dem gezielten Isolationsfix bestanden dreizehn reine Guardfälle;
nach der STDIN-Änderung zehn fokussierte Prozess-/Transferfälle. Der letzte
Konstruktor wurde aus den tatsächlichen AST-Statements ohne Open geprüft.
Unveränderte Helfer wurden anhand ihrer tatsächlichen Quellbytes wiederverwendet;
die bestandene Windows-SQL-Matrix und unveränderte grüne Guards wurden nicht
erneut ausgeführt. Kosten und Tokenverbrauch sind unbekannt.

## Offene Grenze

Authentifizierte positive und negative Linux-SQL-Verbindungen beider Stacks,
tatsächliche Treiberbeobachtung, frische Ziel-/Client-/Trustbindung und deren
konkrete Freigabe fehlen. Der öffentliche Kontextvertrag unterstützt dadurch
noch keinen Linux-Selektor. Hyper-V, Trustdrift, TLS-Abbruch/Resume, operative
Registry/AuthorityRef, gebundene Qualifikationsrecords, V2-Export und tatsächlicher
Toolbelt-Labpreflight bleiben offen. Toolbelt SC-2026-045 bleibt gesperrt.

Reale Container-/Prozess-/Benutzeridentitäten, Endpunkte, Dateidigests und
Rohdiagnosen bleiben ausschließlich lokal und ignoriert. Die sechs geschützten
Toolbelt-Umgebungen, die erhaltene SSISDB-Quelle, fremde Ressourcen und frühere
Löschsperren bleiben erhalten. Diese Vorbereitung ändert keinen öffentlichen
Verbindungsdefault und erteilt keine neue Trustautorität.
