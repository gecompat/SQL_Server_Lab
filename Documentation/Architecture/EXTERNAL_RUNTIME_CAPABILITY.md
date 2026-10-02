# External-Languages-Entscheidung für einen Manifestentwurf

`Get-SqlServerLabExternalRuntimeCapability` ist der enge CORE-102-Teilvertrag
`SqlServerLab.ExternalRuntimeCapability/1.0`. Er bewertet eine zukünftige
Docker-/Podman-Linux-Instanz mit expliziter SQL-Katalogversion, Software-ID
(`sql-python`, `sql-r`, `sql-java`), Runtimeversion und Katalogvariante.
Diese Entwurfsangaben sind keine registrierte Run-/Scope- oder Besitzbindung.
C# und Hyper-V gehören nicht zu diesem Slice.

Der bestehende Software-Resolver bleibt die Katalogautorität. Sein Ergebnis
wird als `CatalogDecision` mit `DECLARED_SUPPORTED` oder `BLOCKED` und einem
festen Reason-Code projiziert. Unbekannte Anforderungen erhalten keine
zurückgespiegelte Identität oder Rohbegründung. Eine unterstützte Identität
stammt aus dem aufgelösten Katalog. Der Launchmodus und die erforderliche
cgroup-Version kommen aus dem bestehenden Containerrezept, einschließlich der
ausdrücklich ausgewählten SQL-2025-Variante `sql2025-shared-user-v2`.

Standardmäßig ist `CurrentReadiness` gleich `NOT_CHECKED`; kein Hostwerkzeug
wird aufgerufen. `-CheckProviderReadiness` veranlasst bei katalogunterstützter
Anforderung genau eine lesende `info --format`-Abfrage über den absoluten
HostTools-Aufrufpfad. Der native Formatstring projiziert nur OS, cgroup und
Rootless-/Security-Metadaten. Der vorhandene RAM-basierte Prozessreader begrenzt
die Ausführung auf 20 Sekunden und beide Streams zusammen auf 64 KiB; sein
separater Terminierungsversuch wartet höchstens fünf Sekunden. Synchroner
Prozessstart und Dispose sind keine Kernel-Wallclock-Garantie. Es gibt keinen
Retry, Bootstrap, Pull, vollständigen Client-Readiness-Aufruf, Storagezugriff
oder erneuten Modulimport durch diese API.

Die Antwort wird auf einen geschlossenen, typisierten Vertrag reduziert.
Fehlende Docker-`SecurityOptions` und unbekannte/nullwertige Rootless-, OS- oder
cgroup-Fakten werden abgelehnt. Podmans `v1`/`v2` wird ausdrücklich auf `1`/`2`
normalisiert. Stringwerte werden nicht in Boolwerte umgedeutet. Erst danach
erhält der bestehende Hostclassifier ausschließlich die internen Fakten,
sodass sein ungebundener nativer Fallback nicht erreicht wird.

`READY` bestätigt ausschließlich die Hostvoraussetzung des konkreten
Launchmodus. `SqlLanguageExecution` und `TargetAuthorization` bleiben
`NOT_CHECKED`, `ExecutionSupported` und `MutationAllowed` bleiben `false`,
`Actions` bleibt leer. Tool-/Runtimefehler, Timeout, Streamgrenze, unbestätigte
Terminierung und ungeeignete Hostkombinationen bleiben `BLOCKED`. Pfade,
Endpoints, volle Providerantworten, Security-Options, PlanKeys, Secrets und
Rohfehler werden nicht zurückgegeben.

Es gibt noch keine definierte Zuordnung dieses vertikalen Vertrags zu den
Records des bestehenden Evidence-Index. `HistoricalEvidence` bleibt deshalb
`NOT_RECORDED` mit `MappingStatus=NOT_DEFINED`; ältere dokumentierte
Referenzabnahmen werden weder umetikettiert noch zu aktueller Bereitschaft.
Es entsteht keine zweite Registry und kein persistiertes Assessment.

## Manifestdialog

Die vorhandene Softwareauswahl verwendet denselben Reducer. Sie zeigt auch
Katalogablehnungen mit festen Gründen an; blockierte Varianten werden nicht
übernommen. Eine unterstützte Katalogvariante darf als Entwurf gewählt werden,
während die Hostprüfung ausdrücklich `NOT_CHECKED` bleibt. Das ist keine
Ausführungsfreigabe: vorhandene Erstellungs-/Reconcile-Guards bleiben wirksam.
Die Aktion **Hostvoraussetzungen bewusst lesend prüfen** beobachtet den
ausgewählten Provider einmal für alle Varianten. Ein neu erkannter Block
entfernt bereits gewählte ungeeignete Varianten aus dem RAM-Entwurf.
Zurück, Abbruch, sechs bestehende Manifestfelder und die Warnung des
SQL-2025-Modus ohne Launchpad-Sandbox bleiben erhalten.

Die bestehende private `Get-LabExternalRuntimeSelectionOptions`-Rückgabe,
Desired-State-Assessment, Manifestfelder und Runtime-Executor bleiben
unverändert. Die API ist über den allgemeinen Konsolenbefehlszugang erreichbar.
Ein geführter Browserconsumer und die vollständige CORE-102-Kombinationenmatrix
bleiben offen. Synthetische Transportprüfungen sind keine aktuelle
Docker-/Podman-/SQL-Sprachabnahme.
