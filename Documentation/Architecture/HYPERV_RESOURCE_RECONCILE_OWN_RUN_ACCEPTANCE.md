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

Der manuelle native Lauf `35564131935` vom 2026-09-21 bestand auf Commit
`a4510f5c`: zwei eigene Windows-2025-/SQL-2025-Developer-Runs aus einem
verifizierten Prepared-Artifact, dynamischer Live-/Restart-Abgleich, statischer
Restart-Abgleich, unverändertes `WhatIf`, einmaliger VM-ID-gebundener
Pre-Start-Fehler und Wiederaufnahme mit demselben Executor sowie persistentem
SQL-Datenmarker. Beide Runs wurden mit jeweils drei Cleanup-Schritten und null
Fehlern entfernt. Der frühere Lauf `35562372061` scheiterte bereits bei der
Windows-Aktivierung; sein eigener Run wurde ebenfalls vollständig bereinigt.
Die Ursache dieses früheren Aktivierungsfehlers bleibt ungeklärt.

Der Erfolg belegt den beschriebenen injizierten Executorfehler. Tatsächliche
Hyper-V-Plattformfehler, weitere Versionen und andere Ressourcenklassen bleiben
separate Nachweise.
