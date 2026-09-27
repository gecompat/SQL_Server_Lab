# Offline-Build der CSharp Language Extension

Status: internes Buildwerkzeug; SQL-Registrierung und Launchpad-Abnahme offen.

`Tools/Build-ExternalRuntimeWindowsCSharp.ps1` baut den Microsoft-Quellstand
`9a897b70e1823573e7e455f3b3c3ecf3a6bf1f0f` für lokale SQL-Labtests unter
Windows x64. Es installiert nichts und ändert weder Dienste noch Provider oder
den Softwarekatalog. Die CSharp-Variante bleibt `PREVIEW`.

## Gebundene Eingaben

Der Caller stellt einen lokalen Archivroot bereit. Das Werkzeug lädt keine
Dateien herunter und akzeptiert ausschließlich die im Code und in
`Tools/CSharpBuild` gesperrten Inhalte:

- `source.zip`: [Microsoft-Quellarchiv](https://github.com/microsoft/sql-server-language-extensions/archive/9a897b70e1823573e7e455f3b3c3ecf3a6bf1f0f.zip), SHA256 im Werkzeug;
- `dotnet-runtime-8.0.31-win-x64.zip`: [Microsoft-Runtime](https://builds.dotnet.microsoft.com/dotnet/Runtime/8.0.31/dotnet-runtime-8.0.31-win-x64.zip), SHA512 aus den [Release-Metadaten](https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json);
- `nuget/<id>/<version>/<id>.<version>.nupkg`: 43 Archive gemäß
  `archives.lock.json`, einschließlich drei Referenzpacks. Die dort verzeichneten
  NuGet-Katalogquellen belegen die Archivhashes. `packages.lock.json` bindet
  zusätzlich die 40 aufgelösten Projektabhängigkeiten.

Der NuGet-`contentHash` ist nicht mit dem SHA512 des vollständigen signierten
Archivs gleichzusetzen. Beide Bindungen werden getrennt geprüft: Archivhash
vor Nutzung, Paketauflösung durch `restore --locked-mode` aus dem eigenen
Offline-Feed. NuGet-Audit läuft dabei nicht online. Vor einer Übernahme neuer
Locks ist eine gesonderte aktuelle Advisory-Prüfung erforderlich.

Die bereits vorhandene Toolchain wird ausdrücklich übergeben: .NET SDK
10.0.401, VC Tools 14.51.36231 und Windows SDK 10.0.26100.0. Der Build lädt oder
installiert diese Werkzeuge nicht. UAC ist nicht erforderlich. Ein anderer
Compilerstand erhält keinen stillen Fallback.

## Ablauf und Ergebnis

```powershell
.\Tools\Build-ExternalRuntimeWindowsCSharp.ps1 `
    -Inputs <lokaler-archivroot> -OutputRoot <neuer-buildroot> `
    -Dotnet <absoluter-dotnet-exe-pfad> -VcVars <absoluter-vcvars64-bat-pfad> `
    -ValidateInputsOnly
```

Ohne `ValidateInputsOnly` läuft der Build. Der reine Preflight prüft Dateien,
Hashes und Pfade; er führt keinen Compiler aus und bestätigt keine installierte
Toolversion. Build- und Eingaberoot gehören außerhalb versionierter Dateien.
Vorhandene Ausgabeverzeichnisse werden abgewiesen. Nach Fehlern bleibt nur der
neu angelegte Buildroot für Diagnose und eigenes gezieltes Cleanup erhalten.
Es gibt kein automatisches Resume oder pauschales Löschen.

Der Build verwendet neue Quell-, Feed-, Paket- und Zwischenverzeichnisse,
normalisierte Pfade, feste Toolversionen, begrenzte Kindprozesse und eine
feste ZIP-Reihenfolge mit festen Zeitstempeln. Übergeordnete MSBuild-Dateien,
Git-Metadaten und relevante geerbte Buildvariablen werden ausgeschlossen.
Die Runtimekonfiguration bindet .NET 8.0.31 mit `LatestPatch`. Die Runtime-ZIP
bleibt separat; das Extension-Paket enthält den passenden `hostfxr.dll`.

`csharp-net8.zip` enthält die Extension, ihre Abhängigkeiten, unveränderte
Lizenz-/Notice-Dateien und NuGet-Metadaten sowie ein Hashmanifest. Der lokale
Buildreceipt trägt `BUILT_NOT_SQL_VALIDATED`. Rohlogs bleiben im Buildroot.
Microsoft-spezifische Bedingungen einzelner Abhängigkeiten werden durch die
MIT-Lizenz der Extension nicht ersetzt. Das Werkzeug erteilt keine allgemeine
Weitergabefreigabe und veröffentlicht keine Binärdateien.

## Nachweise und Grenzen

### Paketübergabe an eine spätere native Acceptance

Die synthetische C#-Probe unter `Tests/Integration/Fixtures/CSharp` verdoppelt
Integerwerte und liefert .NET-Major, Prozess-ID sowie das per Windows-Token
ermittelte AppContainer-Flag zurück. Der SQL-Prüftext verlangt drei exakte
Wertepaare, .NET 8 und einen AppContainer-Worker. Er ist noch nicht gegen SQL
ausgeführt; insbesondere ist die geforderte Worker-Isolation noch kein
beobachteter Nachweis.

`Tools/CSharpBuild/Build-ExternalRuntimeWindowsCSharpProbe.ps1` kompiliert
diese Probe ohne MSBuild oder Paketdownload mit dem vorhandenen SDK 10.0.401,
dem geprüften Extension-Paket und dem SHA512-gesperrten
`microsoft.netcore.app.ref`-Archiv 8.0.31 aus dem bestehenden Build-Lock.
Referenzen werden nur unter festen eigenen Dateinamen in einen neuen
Outputroot kopiert. Geerbte DOTNET-, COMPlus-, CORECLR- und COR-Steuervariablen
werden vor dem Compilerstart entfernt. Ein Build mit synthetisch ungültigen
Profiler- und Startup-Hook-Einstellungen erzeugte denselben DLL-Hash.
Der Compiler besitzt ein 120-Sekunden-Limit. Der Root
bleibt auch bei Fehlern für gezielte Diagnose erhalten; vorhandene Roots
werden nicht überschrieben. Zwei lokale Builds in verschieden langen Pfaden
erzeugten bytegleiche Probe-DLLs. Das Receipt trägt ausschließlich
`PROBE_BUILT_NOT_SQL_VALIDATED`; Gastinstallation, Datenbankregistrierung,
SQL-Roundtrip und Neustart stehen weiterhin aus.

```powershell
.\Tools\CSharpBuild\Build-ExternalRuntimeWindowsCSharpProbe.ps1 `
    -Package <geprüftes-extension-paket> -PackageSha256 <geprüfter-sha256> `
    -ReferenceArchive <gesperrtes-net8-referenzpaket> `
    -Dotnet <vorhandene-dotnet-exe> -OutputRoot <neuer-buildroot>
```

`Tools/CSharpBuild/Test-ExternalRuntimeWindowsCSharpPackage.ps1` prüft ein
lokales Paket read-only gegen einen ausdrücklich übergebenen SHA-256 aus dem
zuvor geprüften Build. Es extrahiert nichts und führt weder Paketcode noch
Provider- oder SQL-Aktionen aus. Hash und ZIP-Inhalt werden aus demselben
geöffneten Dateihandle gelesen. Unter Windows ist ein lokales festes Laufwerk
erforderlich; gemappte Netzlaufwerke werden vor dem Dateizugriff abgewiesen.
Reparse Points, UNC-Pfade, doppelte oder
unsichere ZIP-Namen, übergroße Archive, unvollständige Hashmanifeste und
abweichende Quell-/Frameworkbindungen werden abgewiesen. Die Prüfung verlangt
die zentralen Runtime- und Notice-Dateien sowie .NET 8.0.31 mit `LatestPatch`.

```powershell
.\Tools\CSharpBuild\Test-ExternalRuntimeWindowsCSharpPackage.ps1 `
    -Package <lokales-buildpaket> -ExpectedSha256 <vorher-geprüfter-buildhash>
```

Der Status `PACKAGE_VERIFIED_NOT_SQL_VALIDATED` bestätigt Integrität und den
begrenzten Paketvertrag, keine Herausgeberauthentizität oder SQL-Fähigkeit.
`NativeAcceptanceStatus` bleibt `NOT_EXECUTED`. Ein Consumer muss seine eigene
Kopie unmittelbar vor Nutzung erneut prüfen; der Preflight stellt keine
dauerhafte Dateisperre oder Installationsfreigabe aus. Ungültige Eingaben
liefern `CSHARP_ACCEPTANCE_PACKAGE_INVALID` ohne lokale Pfade im Fehlertext.
Das vorhandene reale Buildpaket mit 142 Manifestdateien bestand diese Prüfung;
synthetische Negativtests prüfen Hash-, Pfad-, Manifest- und Versionsabwehr.
Der GitHub-Gast-/SQL-Runner ist weiterhin separat offen.
Der plattformunabhängige Archivvertrag kann unter Linux offline getestet
werden; dort ist die Erkennung beliebiger Netzwerk-Mounts nicht enthalten.

Das Repository-Werkzeug erzeugte am 2026-09-27 auf derselben Toolchain in zwei
unterschiedlich langen Quellpfaden bytegleiche Pakete, auch mit absichtlich
ungültigen geerbten Compiler-/SDK-Variablen und blockierenden übergeordneten
MSBuild-Dateien. Seine 49 Runtime-Dateien sind bytegleich zum zuvor geprüften
lokalen Paket. 129 Upstream-ABI-Tests
bestanden nach frischer Paketextraktion mit separat entpackter .NET-8-Runtime.
Die unveränderten Produktquellen benötigen für diesen Teststand Anpassungen
am Upstream-Testharness (C++17-Dateisystem und normalisierter Assemblyverweis).
Das Buildwerkzeug baut diesen Testharness nicht mit.

Die statische Windows-External-Runtime-Suite prüft Lock-Konsistenz,
Hashabwehr, Outputschutz und die Offlinegrenzen ohne Compiler. Ein erfolgreicher
Build ersetzt weder diese Prüfungen noch SQL-Server-2025-Registrierung,
Launchpad-Datenroundtrip, Worker-Identität und Neustart. Reproduzierbarkeit auf
anderen Hosts, automatische Beschaffung, Gastinstallation und Katalogpromotion
bleiben separate Nachweise.
