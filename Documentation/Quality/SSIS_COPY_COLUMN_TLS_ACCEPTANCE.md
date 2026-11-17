# Aktuelles SSIS-Copy-Column-Artefakt strikt über TLS prüfen

Die neue [Abnahmemethode](../../Tests/Integration/Invoke-ToolbeltSsisCopyColumnTlsAcceptance.ps1)
bindet ausschließlich den reproduzierbaren ANSI-korrigierten Copy-Column-Build
mit vier gezielten nativen Kontexten und frischen Abschlussaudits. Die früheren
vollständigen C7-ZIP-Nachweise bleiben historisch. Sie verwendet denselben öffentlichen Windows-/Hyper-V-/SQL-
2025-RTM-Neuaufbau, beide strikten Clientstacks, signierten V2-Export und die
frischen SQL-/Lab-Cleanup-Audits wie die frühere Current-Build-Methode.
Der alte Adapter und seine historischen Records bleiben unverändert.

Bei der erneuten Registrierung derselben aktiven Authority verwendet `UPDATE`
deren bereits gebundene Client-/Signerreferenzen zusätzlich zur vollständigen
Prozessidentität. Identitätsgleiche, aber getrennt referenzierte Kontexte einer
anderen Authority bleiben unverändert. Eine fehlende, doppelte oder nicht zur
aktuellen Identität passende gebundene Referenz wird abgewiesen.

Für einen neuen Kandidaten verwendet `APPEND_AUTHORITY` dagegen frische,
separate Client- und Signerreferenzen. Identitätsgleiche Kontexte bestehender
Authorities machen diesen Append nicht mehrdeutig und werden nicht umgebunden.
Vorhandene Records bleiben unverändert; die neue Authority und ihre beiden
Kontexte werden frisch gegen Kandidat, Actor, Rootmetadaten und ReadOnly-Trust
geprüft. Bestehende Authorities gelten dadurch nicht als betriebsbereit.
Die Frischeprüfung des [Registry-Writers](../Architecture/AUTHENTICATED_TLS_REGISTRY_WRITER.md)
unterscheidet diese Append-Transaktion von `UPDATE`: Bei `UPDATE` müssen
unveränderte Authorities mit vorhandenem Kandidatenverzeichnis frisch passen;
ein nachweislich fehlendes Verzeichnis darf nur nach vollständiger
Indexbindung unverändert erhalten bleiben. Verschiedene Laufzeitbindungen
können eine solche Aktualisierung daher weiterhin sperren. Weder das
Überspringen fremder Records noch deren Anpassung an den ausgewählten Prozess
ist Bestandteil dieser Abnahmemethode.
Die [Auswahlgegenproben](../../Tests/Static/Invoke-AuthenticatedTlsContextSelectionChecks.ps1)
prüfen beide Kontextarten ohne Registry-/CA-/VM-/SQL-Effekte.

Der feste Consumer erhält explizit den vertrauenswürdigen Toolbeltcheckout,
die releasegebundenen Dateien und das vollständige Inputmanifest. Weder Export
noch Browser wählen Codepfade. Der aktuelle Toolbeltrecord bindet Produktquellen,
Provider und abgegrenztes ANSI-Sicherheitsdelta; eine alte DLL oder Quellenabweichung
wird vor VM-/SQL-Effekten zurückgewiesen. Alle eigenen Ziele bleiben synthetisch.

Die [SQL-freien Gegenproben](../../Tests/Static/Invoke-ToolbeltSsisCopyColumnTlsChecks.ps1)
prüfen die tatsächliche Komposition und Abweisung falscher Config-/Buildinputs.
Das ist kein nativer TLS-Nachweis. Für einen echten Lauf sind eine vorhandene
Authority, bereits identisch vertraute CA, explizite Clientreferenz und ein
erhöhter Prozess im registrierten Paket-/Benutzerkontext erforderlich.
Der [Windows-Vertrag](../Architecture/AUTHENTICATED_TLS_WINDOWS_OPERATIONAL_LAB.md)
bleibt maßgeblich. Keine UAC-Automatisierung, Übernahme bestehender VMs,
Hosttruständerung oder Umgehung von Kontextdrift.

Ein eigener begrenzter Lauf darf einen öffentlichen Neuaufbau, den festen
SSIS-Consumer lokal/zentral und die getrennten Abschlussaudits umfassen.
Er benötigt vorher definierte endliche Grenzen und Ressourcenownership.
Ein PASS setzt einen tatsächlich erfolgreichen Gesamtkoordinator und erforderlichen
Cleanup voraus. Frühere PASS-Records qualifizieren ihre damaligen Artefakte.
Keine Veröffentlichung/Tags.

## Native Abnahme vom 2026-11-15

Der separat genehmigte isolierte Aufbau bestand mit dem ANSI-korrigierten
SSIS-Provider: öffentlicher ununterbrochener Windows-/Hyper-V-/SQL2025-RTM-
Neuaufbau, beide strikten Clientstacks, signierter V2-Export und unveränderte
Exportbytes vor jedem Consumer-Open. Der SSIS-Consumer bestand lokal/zentral
auf CL170 mit 416 Assertions; sein frischer separater SQL-Audit ist PASS.
Worker und Supervisor bestanden mit sechs beziehungsweise acht Fällen,
einschließlich unabhängigem Lab-Abschlussaudit.
Der [Toolbeltrecord](https://github.com/gecompat/SQL_Server_Toolbelt/blob/main/Modules/toolbelt.tsql.ssis-debug/Tests/Qualification/Tls.CopyColumn.SecurityCorrection.20261115.json)
bindet Provider, Quellen und den begrenzten Umfang.

Die ursprüngliche Revision des bestehenden Registers bleibt vor Commit
gesperrt; unveränderte aktive Authorities werden weiterhin frisch geprüft.
Der zusätzliche eigene Root verwendete eigene Controller-/Location-/Registry-
und CA-Bindungen. Bestehende Authorities und Standardspeicher blieben erhalten.
Genau ein ausdrücklich freigegebener CurrentUser/Root-Trust wurde vor der
Methode importiert und nach belegtem Receiverende wieder entfernt; der eigene
verschlüsselte CA-Schlüssel ist entfernt. Der frische separate Hostaudit ist
PASS. Eine eigene VM und vier Testdatenbanken wurden entfernt. Der geschlossene
Root und Originaljournale bleiben ausschließlich als private Evidenz erhalten.

Zwei zusätzliche Setup-/Cleanupfindings bleiben mit ihren Originalen erhalten:
Der Generator ist jetzt exakt an den isolierten Plan und die tatsächliche
Authority gebunden; Cleanup schließt Dispatch und verlangt zuerst das Ende
der eigenen Receiverinstanz. Beide Korrekturen sind unabhängig quellseitig
akzeptiert; 30 gezielte SQL-freie Gegenproben und neun Receiverprüfungen bestanden.
Die einmalige UAC wurde vom Benutzer bestätigt. Keine automatisierte Anmeldung
oder Sicherheitsdialogbedienung. SQL-Anmeldung ist kein kombinierter Windows-/
TLS-Anmeldeweg; ein Wire-Fingerprint wurde nicht beobachtet. Weder vollständige
SSIS-Modulqualifikation noch neue ZIP-/SSMS-Abnahme werden daraus abgeleitet.

## Auswahlprüfung und Prüfkosten

Die neue kurze Auswahlprüfung wird für Änderungen am Authority-Registrar oder
an ihrem eigenen Testskript einmal ausgewählt. Sie führt 15 Gegenproben an den
tatsächlichen Auswahl-/Revisionsblöcken mit synthetischen Abhängigkeiten aus;
CA, Registry, VM und SQL bleiben dabei unangetastet. Die bestehenden 18
Authority-Prüfungen mit eigenen RSA-/DPAPI-Fixtures bleiben zusätzlich erhalten.
Sie prüfen den kanonischen Writer und entfernen ihre eigenen Dateien wieder.
Die vorhandenen Provider-/Runtimegates werden nicht reduziert. Die Ergänzung
rechtfertigt keine Wiederholung bereits grüner Toolbelt-Funktionsmatrizen und
keine weitere Reviewkette über den ausdrücklich beauftragten geänderten Scope.
