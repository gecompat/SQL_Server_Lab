# Symptomorientierte Analyse-Runbooks

Runbooks beginnen bei einem beobachteten Symptom und führen über zwei unabhängige Evidenzquellen zu einer belastbaren Hypothese. Sie enthalten keine automatischen Eingriffe.

- [Benutzer melden Hänger oder Blocking](01_User_Hangs_Blocking.md)
- [CPU ist dauerhaft hoch](02_High_CPU.md)
- [Eine Query ist plötzlich langsamer](03_Query_Regression.md)
- [TempDB wächst oder ist fast voll](04_TempDB_Growth.md)
- [Transaktionslog läuft voll](05_Transaction_Log_Full.md)
- [Memory Grants warten](06_Memory_Grant_Queue.md)
- [I/O-Latenz ist hoch](07_IO_Latency.md)
- [Ein Index scheint ungenutzt](08_Unused_Index.md)
- [Backup- oder Integritätsrisiko](09_Backup_Integrity_Risk.md)
- [Availability Group hat Lag](10_Availability_Group_Lag.md)

## Gemeinsame Regel

Jede Analyse prüft zuerst Status, Zeitbezug und Nenner. Danach werden zusammengehörige Werte, ihre Auswirkung, eine unabhängige Gegenprobe und die erforderliche Folgeanalyse bewertet. Erst diese Reihenfolge kann eine Änderung begründen.
