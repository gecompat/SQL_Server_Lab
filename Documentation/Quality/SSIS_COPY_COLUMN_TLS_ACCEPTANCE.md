# Aktuelles SSIS-Copy-Column-Artefakt strikt über TLS prüfen

Die neue [Abnahmemethode](../../Tests/Integration/Invoke-ToolbeltSsisCopyColumnTlsAcceptance.ps1)
bindet ausschließlich den reproduzierbaren ANSI-korrigierten Copy-Column-Build
mit vier gezielten nativen Kontexten und frischen Abschlussaudits. Die früheren
vollständigen C7-ZIP-Nachweise bleiben historisch. Sie verwendet denselben öffentlichen Windows-/Hyper-V-/SQL-
2025-RTM-Neuaufbau, beide strikten Clientstacks, signierten V2-Export und die
frischen SQL-/Lab-Cleanup-Audits wie die frühere Current-Build-Methode.
Der alte Adapter und seine historischen Records bleiben unverändert.

Für eine bestehende Authority verwendet die kanonische Registrierung deren
bereits gebundene Client-/Signerreferenzen zusätzlich zur vollständigen
Prozessidentität. Identitätsgleiche, aber getrennt referenzierte Kontexte einer
anderen Authority bleiben unverändert. Eine neue Authority ohne Referenzbindung
weist eine mehrdeutige Auswahl weiterhin ab. Fehlende, doppelte oder nicht zur
aktuellen Identität passende gebundene Referenzen sind ebenfalls gesperrt.
Diese Auswahlkorrektur ersetzt nicht die vollständige Frischeprüfung des
[Registry-Writers](../Architecture/AUTHENTICATED_TLS_REGISTRY_WRITER.md).
Vor jedem Commit müssen auch unveränderte aktive Authorities frisch passen.
Verschiedene Laufzeitbindungen können deshalb eine Revision weiterhin sperren;
weder das Überspringen fremder Datensätze noch deren Anpassung an den
ausgewählten Prozess ist Bestandteil dieser Abnahmemethode.
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
Cleanup voraus. Der aktuelle native Lauf ist noch nicht ausgeführt; frühere
PASS-Records qualifizieren ihre damaligen Artefakte. Keine Veröffentlichung/Tags.

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
