# Hyper-V-SQL-Abschluss: explizite Roots, VM-ID und kein Transportreplay

## Öffentliche ausdrücklich gewählte VM-ID

`Invoke-SqlServerLabWorkflowAction` bietet für `CompleteHyperVLabSql` und
`EnableHyperVLabHostSqlAccess` optional `ExpectedVmId`. Diese Option verlangt
eine nicht leere VM-UUID und einen ausdrücklich angegebenen, nicht leeren
`StateRoot`; bei anderen Aktionen wird sie abgelehnt. Ohne Option bleiben
Defaultroots und die bisherige Transportwahl erhalten. HostSQL reicht jetzt
auch einen ausdrücklich gewählten StateRoot unverändert weiter und lehnt
explizite Leere vor dem Core-Aufruf ab.

Bei gewählter VM-ID erfolgt die strikte Run-/Scope-/gespeicherte und native
VM-ID-Prüfung vor der Poolinvalidierung. CompleteImage reicht diese Wahl
an die vorhandene VerifyOnly/Denied-Aktivierungsprüfung, WMI, Bootwartefunktion,
Instanzleser und -writer, isolierten Port-Setter und SQL-Readiness weiter.
Der HostSQL-Folgepfad reicht sie zusätzlich an die Gastnetzinitialisierung
und seinen SQL-Gastblock. Eine automatisch berechnete Fallbackadresse wird
in dieser Lane nicht angeboten; explizite Fallbackargumente der ausgewählten
internen Helfer werden abgelehnt. Auch eine Lab-WinRM-Markierung erweitert
die Wahl damit nicht. Die tatsächliche Transportgrenze verwendet `VMId`.

DVD- und Adapterzugriffe verwenden in dieser Lane das überprüfte native
VM-Objekt. HostSQL verlangt vor Effekten ein bereits gebundenes
`hostOnly`-Netz mit unverändertem Switch, Subnetz, Hostadresse, Präfix und
genau einem passenden Adapter sowie einem ReadOnly-Plan ohne Aktionen.
Gemeinsame Hostnetze werden nicht repariert, Adapter nicht hinzugefügt;
LAN oder ein anderer Switch blockieren diese zusätzliche Lane. Die
Gast-IP-/SQL-/Firewallkonfiguration bleibt ein ausdrücklich mutierender
Teil des ausgewählten Workflows. Das erteilt keine neue native Autorität.

Vor Secretpersistenz, Connection- und Readiness-Notes-Writes wird die
ausgewählte Identität erneut gelesen. Bei nachgewiesener Drift wird vor dem
folgenden Write abgebrochen; bereits eingetretene Effekte werden weder als
zurückgenommen noch als beliebig wiederholbar behandelt. Diese Prüfungen
reservieren keine VM und schließen keine Race-Fenster durch Root-Handles.
Sie ersetzen weder Verbraucherende noch Journal-Recovery oder einen festen
nativen Setupworker mit angemessener 90-Minuten-Setupfrist.

Die [öffentliche Entryfixture](../../Tests/Static/Fixtures/HyperVSqlPublicEntryChecks.ps1)
prüft beide tatsächlichen öffentlichen Aktionen mit synthetischen Core-Zielen.
Die [Kettenfixture](../../Tests/Static/Fixtures/HyperVSqlVmBindingChecks.ps1)
führt tatsächliche Reader-, Complete-, HostSQL-, WMI-, Netz-, Receipt-,
Restart-, Readiness-, Port- und Transportfunktionen mit synthetischen Datei-,
Provider- und weiteren abgegrenzten Blättern aus. Gastkörper werden nicht
ausgeführt. Beide gehören zur HyperVLabEnvironment-Suite. Das ist kein
nativer Gast-/Setup-/SQL-/TLS-Nachweis. Die bisherige GUI-Kennwortaktion
wählt diese neue Option nicht automatisch; aus diesem PowerShell-Vertrag
folgt keine frische GUI-Render- oder Livequalifikation. Connection- und
Exportformate sowie `Encrypt=True/TrustServerCertificate=True` bleiben erhalten.

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
aus. Das ist eine interne Voraussetzung der oben beschriebenen zusätzlichen
öffentlichen SQL-Lane; der Reader allein propagiert keine Transportwahl.
Der Reader reserviert keine VM und verhindert keine spätere Runtimeänderung;
jeder nachfolgende Effekt benötigt erneut die eigene Bindungsprüfung.
Verbraucherende, handlebasierte Rootanker und native Setup-/TLS-Abnahme
bleiben offen.

## Isolierter SQL-Port-Aufruf ohne Transportreplay

`Set-LabHyperVSqlPortBinding` verwendet auch für den isolierten CompleteImage-
Folgepfad `NoRetry`. Nach einem verlorenen Reply wird derselbe Registry-/
Firewall-/SQL-Dienstblock innerhalb dieses Aufrufs nicht erneut ausgeführt.
Die vorhandene Receiptprüfung und die unveränderte Wahl
`Encrypt=True/TrustServerCertificate=True` bleiben erhalten.

Die interne Option `ExpectedVmId` verlangt vor nativer Suche gültige, nicht
leere Run-/Scope-UUIDs, einen nicht leeren VM-Namen und dieselbe gespeicherte
`ConnectionInstance.vmId`. Der tatsächliche Transport prüft zusätzlich die
native VM-ID und verwendet den VMId-Direct-Selector. Der Setter übergibt
keine Fallbackadresse; eine Lab-WinRM-Markierung erweitert diese gewählte
Lane daher nicht. Ohne Option bleibt der bisherige VMName-Selector erhalten,
jedoch ebenfalls mit genau einem mutierenden Transportversuch.

Die [Funktionsfixture](../../Tests/Static/Fixtures/HyperVSqlPortMutationBoundaryChecks.ps1)
verwendet tatsächlichen Setter und Transport mit synthetischen nativen
Blättern. Vor der Korrektur wurden bei einem synthetischen Verbraucherwrite
mit anschließend verlorenem Reply zehn Direct-Aufrufe beobachtet. Danach
bleibt es bei einem. Gastkörper werden nicht ausgeführt. Der interne Setter
liest keinen registrierten Root neu und reserviert keine VM. Öffentliche
Reconcile-Gesamtpropagation, Verbraucherende, Journal-Recovery und
native Setup-/SQL-/TLS-Qualifikation sind damit nicht neu nachgewiesen;
ein Fehler erteilt keine Wiederholungs- oder Cleanupautorität.

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
Dies ist eine interne Abhängigkeit der oben beschriebenen öffentlichen
Complete-/HostSQL-Weitergabe. Verbraucherende und native
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
WinRM-Fallback desselben Gastblocks. Ohne ausdrücklich gewählte VM-ID bleibt
ein bereits an Lab-WinRM gebundener Transport eine eigene einmalige Aufrufwahl.
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
