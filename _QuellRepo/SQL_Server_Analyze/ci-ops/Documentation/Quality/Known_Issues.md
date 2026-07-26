# Bekannte Einschränkungen

Stand: 2026-07-21

Diese Liste beschreibt fachliche und betriebliche Aussagegrenzen des aktuellen Frameworkstands. Ein Eintrag bedeutet nicht zwangsläufig einen Defekt; er kennzeichnet einen bewusst begrenzten oder plattformabhängigen Nachweis.

## Plattform und Kompatibilität

- Freigegeben ist SQL Server 2019 oder neuer innerhalb der dokumentierten Collationgrenze. Abweichende Server-/`tempdb`-Collations sind nicht Teil der unterstützten Matrix.
- Die nachgewiesenen synthetischen Linuxpfade ersetzen keine vollständigen Windows-, Azure-MI-, kundenspezifischen Last- oder Feature-Positivtests.
- Full-Text-, Availability-, Replikations-, In-Memory-, Agent- und weitere optionale Features können plattform- oder editionsabhängig fehlen. Das Framework liefert dafür Capability- oder Teilstatus.
- Der Offline-Build- und Lifecyclekatalog von `USP_ServerVersionInformation` besitzt den Stand 21. Juli 2026. Ein neuerer unbekannter Build führt zu einer Evidenzlücke, nicht automatisch zur Aussage „veraltet“.

## Zeitreihen und Historie

- Der Frameworkkern ist zustandslos. Live-DMVs liefern Momentaufnahmen oder quellenabhängig kumulative Werte.
- Kurze In-Procedure-Samples sind Deltas eines begrenzten Fensters und keine langfristige Baseline.
- Query Store und vorhandene Extended Events sind von Aktivierung, Capture, Retention und Berechtigung abhängig.
- Das optionale Snapshotpaket persistiert derzeit begrenzte Performance-Counter-Evidenz und Modulstatus. Wait-, I/O-, Datenbank-, Query-, Plan- und Rollup-Collector sind nicht Bestandteil dieses Pakets.

## Plan-, Text- und XML-Evidenz

- Actual-Plan-XML bleibt außerhalb der meisten Defaultpfade. Plan-XML kann groß und seine Auflösung ressourcenintensiv sein.
- Geschützte, gekürzte oder fehlende SQL-/Plantexte begrenzen die Aussage. Eine leere Textspalte beweist keine leere Query.
- Die Execution-Plan-Analyse führt den Plan nicht aus. Estimated Plans enthalten keine tatsächlichen Laufzeitzähler; Query-Store- und Cachepläne müssen keiner konkreten aktuellen Ausführung entsprechen.
- Reale große oder ungewöhnlich strukturierte XML-, JSON- und Unicode-Payloads benötigen eine eigene kontrollierte Prüfung.

## Integrität, Backup und Restore

- `USP_DatabaseIntegrityAnalysis` ersetzt keinen vollständigen, aktuellen und erfolgreich dokumentierten Integritätslauf.
- Backuphistorie und LSN-Kette beweisen keinen erfolgreichen externen Restore.
- `USP_EncryptionAnalysis` beweist weder Besitz und Wiederherstellbarkeit externer Schlüsselkopien noch die Lesbarkeit eines Sicherungsmediums.

## Spezialfeatures

- `USP_InMemoryOltpAnalysis` ist eine Momentaufnahme. Der Hashkettenpfad kann breit lesen und bleibt opt-in; Poolwerte sind nicht immer datenbankgenau zurechenbar.
- `USP_TemporalAnalysis` liest keine Current-/History-Nutzzeilen. Periodenüberlappung und tatsächlicher Cleanupfortschritt bleiben außerhalb.
- `USP_ServiceBrokerAnalysis` liest keine Nachrichtenkörper. Queue-, Transmission- und Conversationzustand beweisen nicht allein Poison Message, Routing- oder Aktivierungsursache.
- `USP_FullTextAnalysis` liest keine indizierten Inhalte, Keywords oder Crawl-Logs. Population-, Batch- und FDHostwerte sind Momentaufnahmen.
- `USP_DataCaptureDeepAnalysis` kann Change-Tracking-Verlust nur mit explizitem Consumer-Wasserstand bewerten. Remote Distributor, Subscriber und Netzwerkpfade können außerhalb der lokalen Sicht liegen.
- `USP_MaintenanceOperations` ist eine Momentaufnahme und verändert keine Operation. Pause, Laufdauer und Jobüberlappung benötigen Verlauf und Betriebsabsicht.

## Diagnose- und Sicherheitsgrenzen

- Ein Finding ist ein Prüfauftrag, keine automatische Änderungsanweisung.
- `NOLOCK` und `LOCK_TIMEOUT 0` reduzieren Blockierungsrisiko, erzeugen aber keinen atomaren Snapshot und verhindern nicht jede Schema-Sperrkollision.
- Eingeschränkte Rechte, nicht lesbare Datenbanken, Zeilenlimits oder optionale deaktivierte Quellen können partielle Ergebnisse erzeugen.
- CONSOLE, RAW, TABLE und JSON anonymisieren Laufzeitdaten nicht automatisch.
- Der interne Gruppen-Gate erteilt keine SQL-Server-Berechtigung und ersetzt keine fachliche Datenfreigabe.

## Detaillierte Aussagegrenzen

Die jeweilige [Procedure-Seite](../Analysis_Guides/Procedures/README.md) ist für Scope, Zeitmodell, Reset, Kosten, sensible Felder und Gegenprobe maßgeblich. Die [Testmatrix](Test_Matrix.md) trennt nachgewiesene Plattformpfade von nicht ausgeführten Fällen.
