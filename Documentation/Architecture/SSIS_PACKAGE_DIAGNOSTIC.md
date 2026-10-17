# Lesende SSIS-Paketdiagnose im gebundenen Gast

`Get-SqlServerLabSsisPackageDiagnostic` ergänzt die vorhandene
[Windows-Consumeranmeldung](../HowTo/SSIS_CONSUMER_WINDOWS_ACCESS.md).
Der Befehl beobachtet Komponenten und Paketladung in einem bereits laufenden
eigenen Hyper-V-/Windows-/SQL-2019-, -2022- oder -2025-Run. Native Nachweise
gelten nur für die tatsächlich geprüfte Kombination; siehe
[Validierung](../Quality/LOCAL_VALIDATION_STRATEGY.md#ssis-paketladediagnose).

## Eingabe und Bindung

Der Aufrufer liefert ein eigenes vertrauenswürdiges synthetisches DTSX oder
ISPAC und den erwarteten SHA-256 aus seiner bisherigen lokalen Receipt.
Der Befehl ist keine Sandbox: installierte Komponenten können bei der
Deserialisierung eigenen Code laden. Fremde oder ungeprüfte Pakete sind
außerhalb dieses Vertrags.

```powershell
$diagnostic = Get-SqlServerLabSsisPackageDiagnostic -RunId $runId `
    -InstanceId primary -StateRoot $stateRoot `
    -IspacPath $ownIspacPath -PackageName ExampleBasicSuccess.dtsx `
    -ExpectedSha256 $receipt.IspacSha256 -TimeoutSeconds 60

# Alternativ genau ein DTSX, dessen eigener Hash geprüft wird:
$diagnostic = Get-SqlServerLabSsisPackageDiagnostic -RunId $runId `
    -StateRoot $stateRoot -PackagePath $ownDtsxPath `
    -ExpectedSha256 $receipt.DtsxSha256
```

Nur absolute lokale Pfade ohne Reparse Points sind erlaubt. Ein ISPAC darf
höchstens 16 MiB und 256 Einträge enthalten. Der exakt benannte DTSX-Eintrag
muss im Root liegen und darf höchstens 8 MiB groß sein; doppelte Einträge
einschließlich Groß-/Kleinschreibungsalias werden abgewiesen. Es wird nichts
aus dem Archiv auf Platte extrahiert. Die einmal gelesenen Bytes binden sowohl
den Archivhash als auch den separaten Pakethash. Der Gast prüft den Pakethash
erneut. Dekodiert wird UTF-8 beziehungsweise eine durch BOM erkennbare
Unicode-Kodierung. Das ursprüngliche XML gelangt ohne Neuformatierung an
`Package.LoadFromXML`; DTD und externe XML-Auflösung werden vorher gesperrt.

Run, Scope, Instanz und laufende VM-ID werden über den bestehenden
SSIS-Binder vor und nach dem Gastaufruf frisch geprüft. Der vorhandene
PowerShell-Direct-Transport und geschützte Gast-Secretstore bleiben die
einzigen Zugangswege. Der Aufruf verwendet keine SA-Anmeldung und keinen
freien Host, Port, Gastpfad, Credential- oder Skriptparameter. Er wird nicht
automatisch wiederholt. Der Transport hat eine Frist von 10 bis 120 Sekunden.
Eine verlorene Antwort oder geänderte Zielbindung ergibt `INCONCLUSIVE`;
daraus folgt weder bestätigtes Laden noch bestätigter Abschluss im Gast.

## Beobachtung und Aussagegrenze

Die Rückgabe `SqlServerLab.SsisPackageDiagnostic/1.0` enthält beide Hashes,
die explizite Run-/Instanzbindung und `Observation`:

- `Runtime`: tatsächliche ManagedDTS-Assemblyidentität und Dateiversion,
  Prozess-/Betriebssystembitness, CLR- und PowerShell-Version. Geladen wird
  ausschließlich die installierte x64-Runtime mit Major 15, 16 oder 17 passend
  zur registrierten SQL-Version. Kein Versions- oder x86-Fallback.
- `Inventory`: im selben Prozess beobachtete `Application.ConnectionInfos`
  und `LogProviderInfos`, jeweils höchstens 512 Creation Names. Die
  Inventarsicht beweist keine erfolgreiche Komponenteninstanziierung oder
  Funktionsfähigkeit eines OLE-DB-Datenproviders.
- `Serialized`: deklarierte Creation Names von Connection Managern und
  Log Providern aus demselben Paket, ohne Connection Strings oder XML-Inhalt.
- `LoadStatus`: `NOT_ATTEMPTED`, `RETURNED` oder `FAILED`.
  `RETURNED` allein ist kein Erfolg, weil SSIS Fehler über Events melden kann.
  `LoadedObjectCounts` nennt die anschließend im Speicher vorhandenen
  Connection Manager, Log Provider und Executables ausschließlich als Anzahl.
- `Events`: bis zu 256 numerische Fehler-/Warncodes mit Art `ERROR`, `WARNING`
  oder `PACKAGE_ERROR`; zusätzlich `ExceptionHResult` bei einer Ladeexception.
  Rohe Beschreibungen, Objekt-/Hostnamen, Hilfepfade und Connection Strings
  werden verworfen. `EventsTruncated` verhindert einen grünen Befund.

`OBSERVED` bedeutet vollständig beobachtetes Inventar und eine ohne Fehler
zurückgekehrte Paketladung. `LOAD_FAILED` bezeichnet eine Ladeexception oder
gemeldete Paketfehler; `INCONCLUSIVE` kennzeichnet fehlende Runtime,
Inventar-/XML-/Transportprobleme oder überschrittene Grenzen. `ReasonCode`
trennt diese Fälle. Warnungen bleiben sichtbar.

`ExecutionStatus=NOT_EXECUTED` gilt immer. Der Diagnoseweg ruft weder
`Execute`, `Validate` noch `AcquireConnections` auf. Er verbindet sich nicht
zu SQL und legt keine Katalogordner, Projekte, Ausführungen oder Datenbanken
an. Installation, Registrierung, Diensteinstellungen und Paketänderungen
gehören nicht dazu. Das Laden ist keine Katalogausführung und reproduziert
weder automatisch deren Serverprozess noch deren Konfiguration.

Das Paket bleibt ausschließlich im Speicher. Der C#-Event-Collector nutzt
den vorhandenen lokalen Compiler von Windows PowerShell; dessen temporäre
Compilerartefakte enthalten keinen Paketinhalt. Diagnoseausgabe und Hashes
bleiben im geschützten lokalen Consumerbereich und werden nicht versioniert.
Es gibt keinen dauerhaften Diagnosejournal- oder Cleanupzustand im Lab-Run.

## Quellen

Microsoft beschreibt [Package.LoadFromXML und den Event-Parameter](https://learn.microsoft.com/en-us/dotnet/api/microsoft.sqlserver.dts.runtime.package.loadfromxml?view=sqlserver-2019),
die [Application-Komponentensammlungen](https://learn.microsoft.com/en-us/dotnet/api/microsoft.sqlserver.dts.runtime.application?view=sqlserver-2019)
und die Signaturen von [OnError](https://learn.microsoft.com/en-us/dotnet/api/microsoft.sqlserver.dts.runtime.defaultevents.onerror?view=sqlserver-2019)
sowie [OnWarning](https://learn.microsoft.com/en-us/dotnet/api/microsoft.sqlserver.dts.runtime.defaultevents.onwarning?view=sqlserver-2019).
