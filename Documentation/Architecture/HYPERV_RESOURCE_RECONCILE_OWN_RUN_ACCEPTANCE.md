# Hyper-V-Ressourcenabnahme mit eigenen Runs

`resource-reconcile-own-run-acceptance` ergänzt den bestehenden Main-only-Modus
`resource-reconcile-acceptance`. Der zusätzliche Modus akzeptiert ausschließlich
einen manuellen Dispatch aus demselben Repository, eine explizite SQL-2025-
`SQL_PREPARED_SEALED`-Artifact-ID und den tatsächlich ausgecheckten Commit mit
exakter Bindung an `GITHUB_SHA`. Eine Clone-Quell-Run-ID wird abgewiesen.

Der optionale Dispatch-Input `resource_state_root` wird an den vorhandenen
Supervisor weitergereicht. Leer verwendet er die Runnerkonfiguration. Lokale
Hostpfade bleiben außerhalb versionierter Projektartefakte.

Der vorhandene Supervisor und native Runner erzeugen und bereinigen zwei
operationseigene Runs. Ein lokaler Runner-Temp-Receipt hält Artifact und
Checkout-Commit fest. Die testinterne Unterbrechung vor `Start-VM` belegt einen
injizierten Executorfehler, keinen Fehler der Hyper-V-Plattform.

Der Weg ist implementiert und offline geprüft. Der native Nachweis bleibt
`NOT_EXECUTED`, bis der gebundene manuelle Dispatch erfolgreich abgeschlossen ist.
