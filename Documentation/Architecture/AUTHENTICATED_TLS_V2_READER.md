# Geprüfter V2-Snapshot für explizite Verbraucher

`Read-SqlServerLabQualifiedTestEnvironment` erweitert den
[operativen TLS-Vertrag](AUTHENTICATED_TLS_OPERATIONAL_LAB.md) um eine
öffentliche lesende Grenze. Der Consumer erhält den geprüften Vertrag
zusammen mit genau seinen Exportbytes, statt nach einem Boolean-Ergebnis
die Exportdatei erneut zu lesen.

## Ausdrückliche Auswahl und Ergebnis

Der Aufruf verlangt `RunId`, `InstanceId` und `StateRoot` des eigenen
operativen TLS-Labs. Aktuell gilt Windows mit PowerShell 7.5+, derselbe
registrierte Benutzer-/Client-/Trustkontext und Docker oder Podman mit
SQL 2019 CU32, SQL 2022 CU27 oder SQL 2025 CU9. Linux-SQL-Ziele sind von
Linux-Clientprozessen zu unterscheiden; ein operativer Linux-Clientreader
ist damit nicht implementiert. Die Modulimportgrenze bleibt PowerShell 7.2.

`-Path` liest die ausdrückliche private V2-Datei einmal. `-ExportBytes`
prüft einen bereits übernommenen Bytesnapshot erneut und öffnet keinen
ursprünglichen Exportpfad. Die Grenze beträgt 64 KiB. Der gemeinsame Kern
prüft die geschlossene JSON-Form, das kanonische V2-Schema, Signatur und
Eintragshash, Profil und Ziel sowie die aktuellen Authority-, Client-, Trust-,
Zertifikats- und Runtimebindungen einschließlich committed Rebindhistorie.
Es gibt keinen V1-, Provider-, Ziel- oder Trust-Fallback.

Das Ergebnis `SqlServerLab.QualifiedTestEnvironmentSnapshot/0.1` enthält:

| Feld | Bedeutung |
|---|---|
| `ExportBytes` | Eigene Kopie der tatsächlich geprüften Bytes |
| `ExportSha256` | SHA-256 genau dieser Bytes |
| `Contract` | Daraus geparster und geprüfter V2-Vertrag |
| `Qualification` | Signierte zeitlich begrenzte Qualifikation |
| `VerifiedAtUtc` | Zeitpunkt der abschließenden Bindungsbeobachtung |

**Das Ergebnis enthält Credentials.** Nicht ausgeben, protokollieren,
versionieren oder hochladen. Ein geändertes Callerobjekt wird bei einer
erneuten Prüfung nicht als Autorität übernommen; wieder die Exportbytes
übergeben und den daraus neu gelieferten Eintrag verwenden.

## Frische und tatsächliche Verbindung

Die signierte Frist bleibt höchstens 15 Minuten und endet spätestens mit
dem Leaf. Sie wird vor und nach den nativen Beobachtungen geprüft.
`VerifiedAtUtc` verlängert sie nicht. Ein Snapshot reserviert weder Runtime
noch Truststore und ist kein übertragbares Prüfticket für einen anderen
Clientkontext. Vor einer späteren Verwendung dieselben Bytes erneut gegen
die aktuelle Bindung prüfen. Keine Exportdatei nachlesen und keine
fehlgeschlagene Prüfung durch einen anderen Vertrag ersetzen.

Der Reader selbst führt keine neue SQL-Anmeldung aus und stellt kein
Zertifikat aus. Die tatsächlichen Verbindungen und deren Ergebnisse bleiben
Verantwortung des Consumers. ENV und Markdown bleiben Begleitformate;
der signierte JSON-Snapshot ist die Verbrauchergrundlage.

```powershell
$snapshot = Read-SqlServerLabQualifiedTestEnvironment `
    -Path $export.JsonPath -RunId $lab.RunId -InstanceId primary `
    -StateRoot $lab.StateRoot

# Unmittelbar vor einer späteren Verwendung erneut prüfen.
$current = Read-SqlServerLabQualifiedTestEnvironment `
    -ExportBytes $snapshot.ExportBytes -RunId $lab.RunId -InstanceId primary `
    -StateRoot $lab.StateRoot
# Nur $current.Contract im gebundenen Clientkontext verwenden; nicht ausgeben.
```

Toolbelt SC-2026-045 verwendet eine explizit vom Caller gewählte Labmoduldatei
und dieselbe Run-/Instanz-/StateRoot-Auswahl. Ein Schemaoverride oder ein
Modulpfad aus Exportdaten erteilt keine Prüfautorität. Der gemeinsame
Consumer-Cutover und seine echten Clientabnahmen werden getrennt belegt;
dieses API allein schließt weder SC-2026-045 noch die TLS-001-Matrix.

Die [native Windows-Consumer-Abnahme](../Quality/TLS_V2_CONSUMER_CUTOVER_ACCEPTANCE_2026-10-22.md)
bestand alle sechs Docker-/Podman-/SQL-Profile mit tatsächlichem Toolbelt-
Preflight, beiden Clientstacks und Signatur-Negativfall. Die generische
CLI-/Browserbefehlsanzeige maskiert `ExportBytes` und Binärwerte. Bytearray-
Eingaben bleiben als maskiertes strukturiertes JSON verfügbar; Fehler geben
keine Rohwerte wieder. Die programmgesteuerte Readerausgabe enthält weiterhin
den privaten Bytesnapshot und die benötigten Zugangsdaten.
