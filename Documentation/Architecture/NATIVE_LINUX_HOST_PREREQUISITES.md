# Voraussetzungen des nativen Linux-/WSL-Planers

`Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1 -Action Plan` liefert
`SqlServerLab.NativeLinuxContainerHost/1.1`. Der bestehende Planer bleibt
read-only und verwendet den gemeinsamen OS-/cgroup-/Rootful-Classifier aus
`Private/ContainerImageArtifact.ps1`; eine zweite Kompatibilitätstabelle entsteht
nicht. Docker und Podman sind getrennte Beobachtungen. Hyper-V und C# gehören
nicht zu diesem Teilvertrag von CORE-102 / [#619](https://github.com/gecompat/SQL_Server_Lab/issues/619).

`Status=COMPATIBLE` bestätigt nur den ausgewählten engen Prüfpfad.
`FullLaunchReadiness=INCOMPLETE`, `ExecutionSupported=false`,
`MutationAllowed=false` und `SqlLanguageEvidence=NOT_EXECUTED` bleiben erhalten.
Der Plan ist weder Zielbesitz noch SQL-Sprachabnahme oder Ausführungsfreigabe.
Bestehende gesonderte `Initialize`-/`Test`-Operationen behalten ihre eigenen
Autorisierungs-, Ownership-, Ressourcen- und Cleanupgrenzen.

## Getrennte Befunde

`Controllers` prüft die bisherigen Provideranforderungen: unter Docker die
booleschen `MemoryLimit`-/`PidsLimit`-Angaben, unter Podman `cpu`, `memory` und
`pids` aus der typisierten Controllerliste. Ein ausdrücklich fehlender
Controller ist `MISSING`; eine fehlende, nullwertige oder falsch typisierte
Angabe ist `UNKNOWN`. Gemischte Befunde behalten fehlende und unbekannte
Controller getrennt. Das sind Anzeigen des Providers, keine Delegations- oder
Schreibtests. Bekannte fehlende Controller blockieren; unbekannte verhindern
`COMPATIBLE`. Fehlerhafte OS-/cgroup-/Rootful-Fakten verwenden die kanonische
`PROVIDER_RESPONSE_INVALID`-Entscheidung, ohne einen nativen Fallback zu starten.

`-ResourceProfile standard` löst das vorhandene Profil exakt aus
`Catalogs/sql-server-versions.json` auf; `compact` und `performance` bleiben
dieselben Katalogprofile. `ResourceCapacity` vergleicht positive ganzzahlige
Engine-Gesamtwerte mit deren RAM-/CPU-Anforderungen. Eine bekannte
Unterschreitung blockiert mit `RESOURCE_PROFILE_CAPACITY_INSUFFICIENT`, eine
ungültige oder fehlende Kapazität bleibt `RESOURCE_PROFILE_CAPACITY_UNKNOWN`.
Gesamtkapazität ist kein freier RAM, keine Reservierung und kein Peaknachweis;
`FreeMemory` und `Reservation` bleiben `NOT_CHECKED`. Reale Inventarwerte werden
nicht in diesem reduzierten Befund ausgegeben. Der bestehende
[Ressourcen-Preflight](RESOURCE_ASSESSMENT_DECISION.md) bleibt separat erforderlich.

`SharedKernel` unterscheidet unbekannten Providerbackend und den ausdrücklich
ausgewählten, bereits laufenden WSL-Kontext. Lesbare eindeutige Kernelconfig
liefert `AVAILABLE` oder `MISSING` für MEMCG_V1; unlesbare, widersprüchliche
oder nicht beweiskräftige Angaben bleiben unbekannt. Ein v1-Ausschluss wird
nicht auf einen ausdrücklich gewählten v2-Modus übertragen. Der WSL-Dispatcher
bindet Profil und Provider an den ausgewählten Aufruf und übernimmt nur eine
Planantwort ohne Ausführungsautorität. Diese Kontextbeobachtung beweist weder
die Kernelbindung eines möglicherweise entfernten Providers noch die
Kompatibilität paralleler Workloads. `IsolationProven=false`,
`ProviderKernelBinding=NOT_CHECKED` und `ParallelWorkloads=NOT_CHECKED` bleiben
auch bei anderem Distributionsnamen oder positiver Kernelconfig bestehen.

Es entstehen keine Installationen, Runtime-/WSL-Starts oder -Stopps,
Kerneländerungen, Defaultwechsel oder versteckten SQL-Tests. Reale Diagnosewerte
bleiben lokal. Synthetische Prüfungen der bestehenden NativeLinux-Suite sind
keine native Provider-/Sprachqualifikation. Die übergreifende
[Hostmatrix](HOST_CAPABILITY_MATRIX.md) und die
[öffentliche Detailentscheidung](EXTERNAL_RUNTIME_CAPABILITY.md) behalten ihren
bisherigen Scope; die neuen Planbefunde sind dort noch keine zusätzliche Zusage.
