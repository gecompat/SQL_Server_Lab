# Resource Watch: bestehende monatliche CU-Lane

## Scope und Status

Die vorhandene `.github/workflows/sql-cu-monthly-monitor.yml` prüft unterstützte
SQL-Server-CUs und genau `sql2022-sqlpackage170-linux-derived`. Der Monatscron
`0 6 1 * *`, die Concurrencygruppe und der GitHub-Issuekanal bleiben erhalten.
Es gibt keine weitere Windows-Aufgabe, keinen Batchscheduler und keine
Provider-, Slot-, Modell-, Download- oder Installationsaktion.

`Tools/Invoke-VersionCatalogResourceWatch.ps1` ruft den unveränderten privaten
Resource-Watch-Core in einer eigenen Modulsitzung auf. Ohne `-PublishIssues`
bleibt der Runner ein Metadatencheck. Die interaktive CLI-/GUI-Sitzung und ihr
15-Minuten-Cache werden dadurch nicht persistent. Der ältere CU-Wrapper bleibt
kompatibel; sein unveränderter Einzelaufruf hat weiterhin seine eigene
Transportgrenze.

Der Ausbau besitzt ausführbare Offlineprüfungen und einen getrennten manuellen
Metadatenmodus. Dessen echte Dispatch-Abnahme, die Issue-Abnahme und ein
tatsächlich ausgelöster Monatscron sind separate Nachweise.

## Manueller Metadatenmodus ohne Issueveröffentlichung

`workflow_dispatch` mit `metadata_only=true` führt denselben vollständigen
CU-/SqlPackage-Check ohne `-PublishIssues` aus. Beide `acceptance_`-Eingaben
müssen leer bleiben; ihre Kombination mit diesem Modus wird vor dem Quellencheck
abgelehnt. Der getrennte Job besitzt `contents: read`, `issues: none` und keinen
Publishtoken. Er verwendet weder Issue-API noch Dedupe-, Continuation- oder
Cleanupaktionen. Cron, Concurrency und der Standardmodus bleiben erhalten.

```powershell
gh workflow run sql-cu-monthly-monitor.yml --ref <geprüfter-branch> -f metadata_only=true
```

Vor Dispatch den geprüften Head festhalten. Run-ID, Event `workflow_dispatch`
und exakten `headSha` nachlesen; nur der Metadatenjob darf ausgeführt werden.
Nach Runende ausschließlich `sql-cu-watch` lokal herunterladen: vollständiger
bereinigter Bericht und Nichtveröffentlichungs-Receipt mit
`ApiBoundary=NOT_EXECUTED`, `Status=NOT_EXECUTED`, `Verified=false` und
`RESOURCE_WATCH_ISSUE_NOT_REQUESTED`. Der Workflow prüft diese Bindung vor
Reportwrite. `UNCLEAR` und harte Checkfehler bleiben rot; `NEW` ist ein
erfolgreicher Quellenbefund, keine Katalog-, Download- oder Supportänderung.

Der erste Dispatch am 2026-10-07 auf `12d2df70` (Run `37573277399`) endete
wegen des abgelehnten CU-Quellenredirects mit `FAIL`. Die erneute Abnahme auf
`bdd2a214` bestand im [Run `37575512288`](https://github.com/gecompat/SQL_Server_Lab/actions/runs/37575512288):
CU 2019/2022/2025 `NO_CHANGE`, SqlPackage `NEW` (`170.5.96.0`), geprüft am
2026-10-07 um 05:17 UTC. Nur der Metadatenjob lief; der nachgelesene Receipt
bestätigt die Nichtveröffentlichung. Ein erfolgreicher Metadatendispatch
belegt weder Issueveröffentlichung, Deduplikation oder Zustellung noch den
Monatscron. Der Quellenbefund gilt nur für den dokumentierten Zeitpunkt.

## Veröffentlichung und Fehler

Die reine Projektion in `Tools/Common/VersionCatalogResourceWatchAutomation.ps1`
prüft erwartete, eindeutige Ressourcen, den vollständigen Quellenbefund, UTC-Zeit,
Versionsordnung und einen festen Fehlercodekatalog. Sie erzeugt Name und
betroffene Fähigkeit selbst. Übergebene Namen, Reports, FindingKeys, Historien,
Exceptions, Katalogpfade und sonstige Rohfelder werden nicht übernommen.

Erlaubt sind ausschließlich die beiden festen Microsoft-Quellen:

- CU: `https://support.microsoft.com/en-us/servicing/sql/kb321185-download-and-install-latest-updates`;
- SqlPackage: `https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-download?view=sql-server-ver17`.

Die aktive CU-Quelle ist seit der Quellenkorrektur vom 2026-10-07 der direkt
antwortende lokalisierte Supportartikel KB321185. Die frühere Learnadresse
antwortete mit einem Redirect; der erste eigene Metadatendispatch blieb deshalb
korrekt rot. Der neue Pfad wird ausdrücklich katalogisiert und ohne Redirect
gelesen. Er verwendet je SQL-Version genau eine HTML-Tabelle mit den fünf
bekannten Spalten. Formatdrift, mehrdeutige Tabellen und Parserdeadline ergeben
keine Aktualitätsbestätigung. Nur reine CU-Zeilen gehen in den bestehenden
Build-/KB-/Rücknahmevertrag ein; GDR-Kombinationen und historische Formate außerhalb
dieses Vertrags werden nicht umgedeutet. Git-Metadaten dieses Supportartikels
lösen keinen zusätzlichen Hop aus. Alte reine Markdownverträge bleiben erhalten.
Die SourceId und Ressourcenidentitäten bleiben gleich; die neue Bezugsadresse
ändert den quellgebundenen FindingKey. Eine echte Issueaktualisierung ist damit
nicht abgenommen.

Der Core begrenzt Quellenrequests einschließlich des festen Legacy-CU-Markdown-Hops
auf insgesamt 45 Sekunden und 512 KiB pro Antwort. Die Issue-API erlaubt nur
`https://api.github.com/repos/gecompat/SQL_Server_Lab/issues` und ihre exakt
numerischen Unterpfade. Redirects, Cookies, Proxy und Default-Credentials sind
ausgeschlossen. Der Bearertoken wird nur aus `GH_TOKEN` gelesen und nicht
ausgegeben. Requests haben höchstens 30 Sekunden, der Issueblock 180 Sekunden,
Antworten höchstens 1 MiB und die Liste höchstens zehn vollständige Seiten à
100 Einträge. Unvollständige oder ungültige Listen verhindern Schreibzugriffe.
Die vollständige Repo-Issueliste wird ohne Labelfilter gelesen. Ein verlorenes
`cu-watch`-Label kann einen vorhandenen Marker daher nicht vor der Deduplikation
verstecken; Labeldrift und Scope-Mehrdeutigkeit blockieren vor jedem Write.

`CheckFailed` und `NotificationFailed` bleiben getrennt. Eine unklare Quelle ist
auch nach erfolgreicher Issueveröffentlichung kein erfolgreicher Check.
Check-/Reportexceptions werden als bereinigter globaler `watch-check`-Befund
gemeldet. Fehler vor dem Adapter, Checkout-/Runnerausfall, Timeout oder fehlende
Issueberechtigung können keine Benachrichtigung garantieren. Der Workflow bleibt
bei jedem ausgeführten Fehlervorgang rot; er lädt ausschließlich den bereinigten
Markdownbericht und das kleine Issue-Receipt hoch.

## Persistente Deduplikation und Recovery

Ein verwaltetes Issue trägt das bestehende Label `cu-watch` und einen Marker mit
Scope, Ressourcen-ID, Befundhash und Hash der erzeugten Bodybytes. Der Befundhash
bindet Quelle, Fähigkeit, katalogisierte und beobachtete Version, Status und
Fehlercode. Zeitpunkt, Monat und HTMLdarstellung ändern diesen Hash nicht.

Pro Scope/Ressource ist genau ein Issue zulässig. Gleichbleibender Befund erzeugt
keinen Write und keinen Kommentar, auch im nächsten Monat. Ein manuell
geschlossenes Issue wird für denselben Befund nicht automatisch wieder geöffnet.
Ein neuer Befund aktualisiert das bestehende verwaltete Issue; `NO_CHANGE`
schließt genau dieses Issue. Fremde Labels und Kommentare bleiben erhalten.
Alte monatlich gruppierte CU-Issues ohne den neuen Marker werden nicht migriert
oder automatisch geschlossen; ihre manuelle Einordnung bleibt separat.

Vor PATCH wird das Issue erneut gelesen. Geänderte Bodybytes, Marker, Label, Scope,
Nummer, Zustand oder doppelte Ressourcenmarker blockieren die Änderung. Nach
POST/PATCH wird die exakte Postcondition erneut gelesen. Ein verlorener oder
abweichender Write-Receipt ergibt `RECOVERY_REQUIRED`; der gleiche Lauf wird
ohne blinden POST-Retry wiederaufgenommen. Der vorhandene Marker verhindert dann
ein zweites Issue. Ein gelungener globaler Check schließt einen vorherigen
globalen Fehlerhinweis, während unklare Einzelbefunde offen bleiben.

Die Workflow-Concurrency serialisiert diese Lane. Eine atomare Sperre gegen
beliebige externe GitHub-Schreibzugriffe besteht nicht; die GET-Revalidierung
ist kein serverseitiges Compare-and-swap. Ein gelesener Issue-Receipt bestätigt
die Veröffentlichung am gebundenen Issue, keine Zustellung an einzelne Personen
und keinen Agentstart.

## Eigene echte Issue-Abnahme: noch auszuführen

Die manuelle Eingabe `acceptance_scope=own-<32 kleine Hexzeichen>` isoliert die
Issuefixture vom normalen Scope `catalog`. Ein Schedule darf diesen Parameter
nicht verwenden. Andere Scopeformen scheitern vor dem Runner. Diese Option
erteilt keine Ausführungsfreigabe; der Orchestrator prüft zunächst den stabilen
Diff und die konkrete Remotegrenze.

Zusätzlich verlangt die Own-Veröffentlichung `acceptance_resource`: genau eine
Ressourcen-ID aus den tatsächlich konfigurierten erwarteten IDs (`sql-cu-2019`,
`sql-cu-2022`, `sql-cu-2025`, `sqlpackage` im aktuellen Katalog). Der Runnerparameter
heißt `AcceptanceResourceId`. Der Quellencheck und sein vollständiger Bericht
werden nicht verkürzt. Regulärer Scope `catalog` und Monatscron verwenden keine
Auswahl und behalten ihr bisheriges Verhalten.

Vor jedem Write zählt die Own-Projektion alle vorhandenen eigenen Issueidentitäten
sowie die ausgewählte neue Nachricht und globale `watch-check`-Fehler/Recovery.
Höchstens eine unterschiedliche Identität und ein POST oder PATCH pro Aufruf sind
zulässig. Eine zusätzliche vorhandene oder geplante Identität blockiert den ganzen
Writeblock; unselektierte eigene Issues verschwinden nicht aus dieser Prüfung.
Gleiche Befunde dürfen ohne Write erneut gelesen werden. Null Kandidaten ergeben
`NO_NOTICE_NEEDED`; es wird kein künstlicher Befund für einen Nachrichtennachweis
erzeugt. Der getrennte receiptgebundene Close ist keine zweite Publishmutation.

Ein unbekannter Write beendet den Own-Aufruf sofort. Danach sind Workflow-Retry
und neuer Dispatch desselben Scopes verboten. Nur der vorhandene Runner darf mit
`-ContinuationReceiptPath <lokales-receipt.json>` fortsetzen. Das Receipt bindet
Repository, Scope, Auswahl, Git-Head, Vertragsversion und den erwarteten Befund;
verifizierte Einträge binden zusätzlich Issue-ID und Bodyhash. Fremde, veränderte
oder zum aktuellen Befund veraltete Receipts erlauben keinen Write. Bei UNKNOWN
wird nur ein frisch gefundenes exakt passendes Issue wieder gebunden. Ohne Marker
bleibt `RECOVERY_REQUIRED` ohne neuen POST, auch bei erneuter Continuation. Der
Caller muss das Originalreceipt erhalten und diesen Wiederaufnahmevertrag beachten;
der Runner besitzt keine zusätzliche persistente Registry und kann einen ohne
Receipt neu gestarteten Aufruf nicht als früheren UNKNOWN-Versuch identifizieren.

Nach dieser Freigabe:

1. Geprüften Commit und Branch festhalten; eine neue GUID als `own-`-Scope
   erzeugen. Ausschließlich diesen Workflow über `workflow_dispatch` am
   geprüften Branch starten, zum Beispiel:
   `gh workflow run sql-cu-monthly-monitor.yml --ref <geprüfter-branch> -f acceptance_scope=<own-scope> -f acceptance_resource=sqlpackage`.
2. Run-ID, Event `workflow_dispatch` und exakten `headSha` prüfen. Ein anderer
   Head oder ein rot gebliebener Quellencheck ist kein PASS.
3. Ausschließlich `sql-cu-watch`-Report und -Receipt lokal lesen. Receipt muss
   `Repository=gecompat/SQL_Server_Lab`, den eigenen Scope, `ApiBoundary=GITHUB_API`
   sowie einen verifizierten `PUBLISHED`-Eintrag mit Issue-ID und FindingKey
   zeigen. `NO_NOTICE_NEEDED` allein belegt keine neue Nachricht.
4. Nur nach bestätigtem Receipt den gleichen geprüften Head, Scope und die gleiche
   Ressourcenauswahl erneut dispatchen. Bei identischem
   Quellenbefund muss das Issue `DEDUPLICATED` bleiben; keine neue Issue-ID,
   Bodyänderung oder zusätzliche Nachricht. Quellenänderung ist eine neue
   Beobachtung und kein Dedupefehler.
5. Das heruntergeladene Receipt mit `Tools/Close-VersionCatalogResourceWatchFixture.ps1`
   zuerst als `-WhatIf`, danach mit exakt gleichem `-ExpectedIssueScope` prüfen
   und die eigene Fixture schließen. Der Cleanup revalidiert Repository,
   Scope, ID, Ressourcenmarker, FindingKey und Bodyintegrität. Er erlaubt nur
   Schließen, kein Löschen und keinen `catalog`-Scope.
   Vor der Zielauswahl muss jeder Receiptstatus konsistent und strikt typisiert
   sein. `PUBLISHED` und `DEDUPLICATED` benötigen ein echtes boolesches
   `Verified=true` sowie vollständige Issue-/URL-/Befund-/Bodyhashbindung;
   fehlende Bindungen ergeben keine leere erfolgreiche Cleanupbestätigung.
6. Geschlossene Issues und unveränderte reguläre Watchissues bestätigen.
   Unbestätigte Writes ausschließlich durch den receiptgebundenen Runner fortsetzen;
   ein unbekanntes Issue wird niemals als Cleanupziel geraten. Fehler des
   Checks, der Benachrichtigung und des Cleanups getrennt festhalten.

Ein Dispatch belegt die Ausführung dieses Workflows, keinen tatsächlich vom
Cron ausgelösten Lauf. Dazu bleibt eine spätere Schedule-Run-ID mit dem dann
ausgeführten Head nötig. Rohlogs und Herstellerantworten bleiben ausschließlich
lokal; sie gehören nicht in Abnahmeissues oder öffentliche Evidence.
