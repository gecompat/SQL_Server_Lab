# Hyper-V-SQL-Abschluss: explizite Roots und kein Transportreplay

`Invoke-SqlServerLabWorkflowAction -Action CompleteHyperVLabSql` reicht einen
ausdrücklich angegebenen `StateRoot` und `MediaRoot` unverändert an
`Complete-HyperVLabSqlImage` weiter. Nicht angegebene Roots bleiben ungebunden;
die bisherigen Core-Defaults gelten. Ausdrücklich leere oder ausschließlich
aus Leerzeichen bestehende Werte werden vor Aufruf des Core-Ziels mit
`HYPERV_LAB_SQL_COMPLETE_STATE_ROOT_REQUIRED` beziehungsweise
`HYPERV_LAB_SQL_COMPLETE_MEDIA_ROOT_REQUIRED` abgelehnt. Die bestehende
Windows-/Providerfähigkeitssperre und die Pflicht zum flüchtigen Gastkennwort
bleiben vorgeschaltet. Kein globaler Root-/Medienwechsel und kein neuer Export.
Run, Credential und die getrennte SQL-SA-Kennwortwahl bleiben unverändert.

## Vier mutierende Gastaufrufe

Die folgenden Aufrufer setzen beim bestehenden
`Invoke-HyperVPowerShellDirect` ausdrücklich `NoRetry`:

| Aufrufer | Möglicher Gasteffekt |
|---|---|
| `Complete-HyperVLabSqlImage` | SQL CompleteImage, gegebenenfalls angeforderter Gastneustart |
| `Initialize-HyperVGuestLabNetwork` | Gast-IP, DHCP, Route und DNS-Konfiguration |
| `Repair-HyperVLabSqlWmiProvider` | SQL-MOF-Registrierung und WMI-Dienstneustart |
| `Enable-HyperVLabHostSqlAccess` | SQL-TCP, Dienstneustart, SA-Konfiguration und Gastfirewall |

Auch ein `OpenError` kann erst nach einem Verbraucherwrite entstanden sein.
Der Fehler wird deshalb nach dem ersten Direct-Aufruf weitergegeben. Es folgen
weder die bisherigen weiteren Direct-Versuche noch ein nachträglicher
WinRM-Fallback desselben Gastblocks. Ein bereits ausdrücklich an Lab-WinRM
gebundener Transport bleibt eine eigene einmalige Aufrufwahl.
Die Transportimplementierung und ihre übrigen, insbesondere lesenden Aufrufer
werden nicht global geändert. Lesende Boot-/SQL-Bereitschaftsprüfungen dürfen
weiter auf ihren bestehenden begrenzten Wiederholungsverträgen beruhen.

## Ausgeführter isolierter Vertragsnachweis

Die [Fixture](../../Tests/Static/Fixtures/HyperVSqlCompletionBoundaryChecks.ps1)
verwendet die tatsächliche öffentliche Workflowfunktion, die vier tatsächlichen
Caller-Command-ASTs und den tatsächlichen Transport. Ausschließlich native
Blätter sind synthetisch injiziert; Gastscriptblöcke werden nicht ausgeführt.
Vor der Korrektur verlor der öffentliche Aufruf die expliziten Roots. Bei
synthetischem Verbraucherwrite mit danach verlorenem Reply wurden je Caller
zehn Direct-Aufrufe und ein Fallback beobachtet. Danach bleibt es bei einem
Direct-Aufruf ohne Fallback. Die Fixture prüft zusätzlich die einmalige
ausdrückliche Lab-WinRM-Wahl, Root-Einzelwahl, unveränderte Defaults und frühe
Ablehnung leerer expliziter Roots. Sie wird von der bestehenden
`Invoke-HyperVLabEnvironmentChecks.ps1`-Suite ausgeführt.

Dies ist kein nativer Setup-, Netz-, WMI-, SQL- oder TLS-Nachweis. `NoRetry`
beweist weder Verbraucherende noch Rücknahme eines Effekts; eine verlorene
Antwort erteilt keine erneute Setup-, Stop- oder Recoveryautorität. Es entsteht
kein Resume-/Idempotenzjournal für beliebige Teilzustände. Weitere Pfade wie
der isolierte SQL-Port-Reconcile bleiben eigenständige Verträge.
Vor einem eigenen nativen TLS-Setup sind weiterhin vollständig feste und
unabhängig geprüfte Worker-/Supervisorquellen, neue dauerhafte Intents,
frische Ressourcen-/Root-/Actorbindungen, endliche Fristen und bestätigtes
Verbraucherende für den eigenen Cleanup erforderlich. Die vorhandene VM,
ihr Gastkey und der erhaltene CSR werden durch diese Produktkorrektur nicht
verändert. CA-/Store-/SQLServiceACL-/TLS-Abnahme und SC-2026-045 bleiben offen.
