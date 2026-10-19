# Hyper-V-SQL-Abschluss: explizite Roots und kein Transportreplay

## Strikter interner Run-Reader als vorgelagerte Grenze

Der interne Get-HyperVLabWorkflowRun akzeptiert optional ExpectedVmId.
Bei ausdrücklicher Angabe müssen die ID ungleich Null und der StateRoot
ausdrücklich ausgewählt sein. Gespeicherte Instanz-ID und genau eine aktuell
über gültige Run-/Scope-UUIDs gefundene VM müssen dieser ID entsprechen.
Ausgewählte und gespeicherte Run-ID müssen übereinstimmen; ungültige oder
leere Selektoren werden vor der nativen Suche abgelehnt. Ohne diese Prüfung
würden leere Providerfilter die Suche erweitern. Gespeicherte Instanz-ID und VM
bleiben gemeinsam gebunden. Fehlende,
mehrdeutige oder abweichende Bindungen werden abgelehnt. Eine Namensänderung
derselben VM wird nur im zurückgegebenen Objekt projiziert; dieser strikte
Pfad schreibt keine Verbindungsdatei und invalidiert keine Pool-Evidence.
Ohne ExpectedVmId bleiben Defaultroot und bisherige Rename-Reparatur erhalten.

Die [NoIO-Fixture](../../Tests/Static/Fixtures/HyperVImmutableRunReaderChecks.ps1)
führt die tatsächliche Readerfunktion mit synthetischen Datei-/Providerblättern
aus. Das ist eine interne Voraussetzung: Der öffentliche vollständige
Setupweg propagiert die ID und eine Direct-only-Wahl noch nicht durchgängig.
Der Reader reserviert keine VM und verhindert keine spätere Runtimeänderung;
jeder nachfolgende Effekt benötigt erneut die eigene Bindungsprüfung.
Verbraucherende, handlebasierte Rootanker und native Setup-/TLS-Abnahme
bleiben offen.

## Interne strikt gebundene Aktivierungsprüfung

`Invoke-LabWindowsSlotActivationReconcile` bietet intern optional
`ExpectedVmId`. Bei ausdrücklicher Wahl bindet der strikte Run-Reader zuerst
den angegebenen StateRoot, Run, Scope und die gespeicherte/native VM-ID.
Gespeicherter und gegebenenfalls ausdrücklich übergebener Intent müssen
`VerifyOnly/Denied` sein; ein External-Switchargument ist ausgeschlossen.
Nur bestätigte Abwesenheit überspringt den Journalcheck; ein Verzeichnis,
Reparsepoint, Zugriffsfehler oder eine leere beziehungsweise über 1 MiB große
Datei blockiert. Ein vorhandenes Aktivierungsnetzjournal muss ein einzelnes lesbares Objekt
mit passendem Vertrag, Run, Scope, VM und Status `CLEANED` sein. Andernfalls
blockiert die Lane vor Gastprobe und Evidencewrite; auch ein Einelementarray
wird abgelehnt. Sie führt weder die
bisherige Aktivierungs-/Netzreparatur aus noch verändert sie Intent oder
Journal. Ein `CLEANED`-Journal ist allein kein neuer nativer Abwesenheitsbeleg.

Lizenzprobe und Evidencewriter reichen die ID weiter. Vor Poolinvalidierung
und erneut vor dem Verbindungswrite wird strikt gelesen. Die Gastwartefunktion
prüft gültige Run-/Scope-UUIDs und VM-ID vor nativer Suche und bindet jeden
Probeaufruf an die bestehende VMId-Direct-Lane. Fallbackadresse und
Gastinitialisierungsscript sind bei ausdrücklicher ID ausgeschlossen.
Ein VM-ID-Wechsel blockiert; ein Transportfehler eines lesenden Probes darf
innerhalb der bestehenden endlichen Wartefrist erneut geprüft werden.
Eine inaktive/abgelaufene Lizenz wird als solche gespeichert und blockiert
nach dem bestehenden Entscheidungsvertrag; es erfolgt keine Aktivierung.
Ohne Option bleiben Aktivierungsdispatch, Defaulttransport und Buildbindung
unverändert.

Die [NoIO-Fixture](../../Tests/Static/Fixtures/HyperVStrictActivationVerifyChecks.ps1)
führt tatsächliche Reconcile-, Status-, Evidence- und Wartefunktionen mit
synthetischen nativen Blättern aus; Gastkörper werden nicht ausgeführt.
Dies ist eine interne Abhängigkeit. Öffentliche Complete-/HostSQL-Weitergabe,
weitere Netzwerk-/WMI-/Port-/Readinesspfade, Verbraucherende und native
Setup-/TLS-Qualifikation bleiben offen. Keine VM-Reservierung, atomare
Dateisystembindung oder neue Aktivierungsautorität entsteht daraus.

## Öffentliche Rootweitergabe

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
