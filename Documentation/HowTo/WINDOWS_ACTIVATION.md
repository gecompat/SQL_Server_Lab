# Windows-Aktivierung im eigenen Child-Slot

Windows- und SQL-Slots verwenden nach OOBE, vor SQL Setup sowie beim Start
eines eingerichteten Slots eine Live-Pruefung. Eine aktive Lizenz ist ein
No-Op. Eine abgelaufene Evaluation wird nicht verlaengert. Eine unlizenzierte
Vollversion bleibt mit `WINDOWS_ACTIVATION_FULL_VERSION_STRATEGY_REQUIRED`
blockiert; KMS-, ADBA- und MAK-Konfiguration sind noch nicht implementiert.

## Intent

Eine Hyper-V-Instanz im Manifest kann `windowsActivation` enthalten:

```json
"windowsActivation": {
  "ContractVersion": "SqlServerLab.WindowsActivationIntent/1.0",
  "Strategy": "EvaluationOnline",
  "EgressPolicy": "ExistingOnly"
}
```

`EvaluationOnline` erlaubt die Aktivierung einer gueltigen Evaluation.
`VerifyOnly` prueft ausschliesslich die bestehende Aktivierung.
`ExistingOnly` verwendet nur eine nachgewiesene permanente LAN-/NAT-NIC mit
IPv4-Adresse und Default-Route. Ihre Adapter-ID, Switch-Bindung, DHCP- und
DNS-Konfiguration bleiben erhalten. `AllowTemporary` erlaubt zusaetzlich eine
eigene temporaere NIC an einem vorhandenen verbundenen External-Switch.
`Denied` sperrt Online-Aktivierung. Ohne expliziten Intent gilt `ExistingOnly`,
bei isolierten Slots `Denied`. Ein bestehender Adapter ohne persistierte
Identitaetsbindung wird nicht anhand seines Namens als Eigentum angenommen.

Manifest, Batch-Intent `WindowsActivation`,
`New-SqlServerLabWindowsSlotPool -WindowsActivation` und
`Invoke-SqlServerLabWorkflowAction -Action NewHyperVLab -WindowsActivation`
verwenden denselben Resolver. Die Browser-Erstellung bietet die beiden
Auswahlfelder an. `NewHyperVLabFromExistingVm` akzeptiert denselben Parameter.
Ein expliziter Testumgebungsauftrag bewahrt den bestehenden temporaeren
Aktivierungspfad; explizite Manifestvorgaben und Isolation werden erhalten.

## Wiederaufnahme und Repair

`Start-SqlServerLab` prueft eingerichtete Hyper-V-Slots erneut live.
Pool-Wiederverwendung prueft jeden Slot nacheinander; ohne `LeaveRunning`
wird er danach wieder gestoppt. Ein Aktivierungsblocker verhindert SQL Setup.
Ein bereits laufender Slot kann ueber den oeffentlichen Adapter erneut
geprueft werden:

```powershell
Invoke-SqlServerLabWorkflowAction -Action RepairHyperVWindowsActivation -BuildId $runId
```

Das run-lokal gespeicherte Gastpasswort wird verwendet; alternativ kann
`GuestPassword` als SecureString uebergeben werden. Keine Product Keys oder
privaten Aktivierungsendpunkte gehoeren in den Intent. Intent, Live-Zustand
und verwendeter Netzwerkmodus werden im lokalen Aktivierungsreceipt gefuehrt.
Temporare Adapter werden anhand des Ownership-Journals auch nach Teilfehlern
und bei Wiederaufnahme bereinigt. Ungeklaerte Bindungen bleiben
`RECOVERY_REQUIRED` und werden nicht durch Namenssuche geloescht.

## Nachweisgrenze

Statische Verhaltenstests pruefen Entscheidungsmatrix, Ablaufdatum,
Manifestbindung, SQL-Gate, Pool-Wiederaufnahme sowie permanente NIC bei
Erfolg und Fehler. Der native Ownership-Test bestaetigt temporaere Adapter,
Teilfehler, Resume und Cleanup; er fuehrt keine Lizenzaktivierung aus.
Der native Lauf vom 2026-09-10 auf `0a8cb93` bestaetigt die tatsaechliche
Evaluationsaktivierung mit temporaerer NIC, deren Entfernung, den Live-Gate,
Kaltstart und Cleanup (drei Schritte, null Fehler). Es war kein
Bereits-aktiviert-No-Op. Der getrennte Nachweis mit permanenter NIC bleibt offen.
Die Host-Pruefung am 2026-09-10 ergab fuer die permanente Lane
`LAB_NETWORK_HYPERV_LAN_BINDING_REQUIRED` beziehungsweise
`LAB_NETWORK_HYPERV_NAT_PREFIX_CONFLICT`. Es fehlt eine autorisierte bestehende
LAN-Bindung oder ein konfliktfrei gebundener NAT-Plan; gemeinsame Hostnetze
werden fuer diesen Nachweis nicht umkonfiguriert.

Das Live-Evaluationsende folgt der Bedeutung von `EvaluationEndDate` im
[Microsoft-Vertrag fuer SoftwareLicensingProduct](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/sppwmi/softwarelicensingproduct).
