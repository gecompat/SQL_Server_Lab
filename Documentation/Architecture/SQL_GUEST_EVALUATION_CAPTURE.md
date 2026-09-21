# SQL-Gast-Evidence ohne erfundene Evaluationsfrist

`Update-SqlServerLabSqlGuestEvaluationEvidence` erfasst die Edition genau einer
laufenden SQL-2025-Instanz in einem verwalteten Hyper-V-Run aus einem
`SQL_PREPARED_SEALED`-Image. Die Aktion schreibt ausschließlich den bestehenden
runlokalen Receipt `SqlServerLab.SqlGuestEvaluationEvidence/1.0` und eine leere
runlokale Lockdatei. Die Gastabfrage ist ein festes SELECT. Der Watch bleibt
ein unabhängiger Reader ohne Gastzugriff.

## Beobachtung und Bedeutung

Die Abfrage liest `SERVERPROPERTY` für Edition, EditionID, ProductMajorVersion
und InstanceName mit expliziten SQL-Typen. Die Defaultinstanz wird aus NULL zu
`MSSQLSERVER` normalisiert. SQL-Major 17, Instanz und vollständige Edition
müssen zur bestehenden `SQL_READY_RUN`-Readiness und Instanzedition passen.
Es werden ausschließlich folgende bekannte IDs akzeptiert:

| EditionID | Klassifikation |
|---|---|
| 610778273 | EVALUATION |
| -2117995310 | NOT_EVALUATION, Enterprise Developer |
| -1785266663 | NOT_EVALUATION, Standard Developer |

Die ID und der Editionsname müssen zusammenpassen. Unbekannte Editionen oder
Widersprüche blockieren. Quelle ist die offizielle
[SERVERPROPERTY-Dokumentation](https://learn.microsoft.com/en-us/sql/t-sql/functions/serverproperty-transact-sql?view=sql-server-ver17).

Der Capture beobachtet keine authoritative Ablaufzeit. Erfolgreiche Receipts
verwenden `SQL_GUEST_NO_DEADLINE`, `NO_DEADLINE` und eine leere Ablaufzeit.
Evaluation bleibt im Watch `DEADLINE_UNKNOWN/UNKNOWN`; frische Developer-Evidence
wird `NOT_EVALUATION/NOT_APPLICABLE`. Installationsdatum, Imagefrist und
Windows-Aktivierung sind keine Ersatzquelle für eine SQL-Frist. Die feste
Freshness beträgt 24 Stunden ab der UTC-Beobachtung.

## Bindung und Credentialgrenze

Der Kontext liest Run- und Connection-State direkt und repariert keine alten
VM-Namen. Er prüft Run, Scope, einzelne Instanz, VM-ID, Notes-Instanzbindung,
Image und SQL-Readiness sowie den tatsächlichen OS-Child-/Prepared-Parent-Bezug.
Die Imageauflösung verwendet keine schreibende Integritätscache-Aktualisierung;
sie ist kein neuer Vollhash-Nachweis. Vor Secretauflösung und nach der Probe
werden die Bindungen erneut verglichen. Änderungen blockieren das Schreiben.

PowerShell Direct bindet den Aufruf an die bestätigte VM-ID. Im strikten Pfad
ist ein WinRM-Fallback ausgeschlossen. Die SQL-Verbindung läuft ausschließlich
im Gast gegen die Loopback-TCP-Adresse und den gebundenen Port, mit Encryption,
lokal akzeptiertem Serverzertifikat, getrenntem SqlCredential, deaktiviertem
Pooling und ohne persistierbare SecurityInfo. Gast- und SA-Secrets werden nur
aus dem eigenen Run gelesen und ihre temporären SecureString-Kopien freigegeben.
Öffentliche Ergebnisse enthalten IDs, Status und Zeiten, keine VM-/Hostnamen,
Endpunkte, SQL-Texte, Credentials oder Rohfehler.

## Atomicität, Fehler und Grenzen

Root, Vorfahren und betroffene State-/Secretpfade müssen frei von Reparse Points
sein. Eine runlokale FileStream-Sperre mit `FileShare.None` serialisiert Capture
auch über Windows-Sitzungen hinweg. Ein zweiter Aufruf endet `LOCKED` ohne Probe.
Die Sperre umfasst Vorgängerlesen, Probe, Revalidierung und atomaren Austausch.
Ein gültiger Vorgänger derselben vollständigen Bindung wird über
`PreviousEvidenceId` verkettet. Ein ungültiger oder fremder Vorgänger blockiert.
Schema und Semantik werden vor dem atomaren Austausch geprüft.

Probe-, Bindungs- oder Schreibfehler lassen den vorherigen Receipt unverändert.
Es gibt keinen Fehlerreceipt, der einen gültigen Nachweis überschreibt. WhatIf
liest weder Secrets noch Gast und erzeugt weder Receipt noch Lockdatei.
Der Gasttransport wartet 30–300 Sekunden, Standard 90; die Verbindung besitzt
15 Sekunden Connect-Timeout und die SQL-Abfrage höchstens 30 Sekunden.
Ein Timeout behauptet keinen erfolgreichen Capture.

Die fokussierte Suite `Invoke-SqlGuestEvaluationCaptureChecks.ps1` und die
erweiterte GuestProgress-Suite prüfen Bindung, Dateisperre, Fehlererhaltung,
VM-ID-Pinning, SqlClient und sequenzielles Lesen offline. Der native Runner
`Invoke-SqlGuestEvaluationCaptureAcceptance.ps1` verwendet ausschließlich einen
neuen eigenen Developer-Run aus einer expliziten vorhandenen Prepared-Artifact-ID.
Der Hyper-V-Workflowmodus `sql-guest-evaluation-capture-acceptance` führt ihn
auf dem erhöhten Runner ausschließlich über einen manuellen Dispatch aus
demselben Repository aus. Er verlangt die Prepared-Artifact-ID; der optionale
Dispatch-Input `capture_state_root` wird ausschließlich an den `StateRoot`-
Parameter des Runners weitergereicht. Ein leerer Wert verwendet die lokale
Runnerkonfiguration. Der State Root wird nicht in Projektartefakte versioniert.
Er baut kein Image und startet keinen PreparedImage-Bootstrap. Native
Capture-Evidence ist noch `NOT_EXECUTED`.
Positive Evaluation-/Deadline-Evidence, andere Versionen, Container,
automatischer Refresh und Lizenzverlängerung bleiben offen.
