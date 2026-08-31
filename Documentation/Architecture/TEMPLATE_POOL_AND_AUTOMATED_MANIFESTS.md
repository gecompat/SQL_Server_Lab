# Vorlagenpool und automatisierte Manifeste

| Merkmal | Wert |
|---|---|
| Status | `IMPLEMENTED_GUARDRAILS_WITH_DOCUMENTED_HYPERV_SCOPE` |
| Stand | 2026-08-07 |

Dieses Dokument definiert den sicheren Standardpfad. Es trennt bewusst
veröffentlichte Vorlagen, kurzlebige Labs und seltene Expertenaktionen. Ein
Manifest ist der primäre, nicht interaktive Bereitstellungsweg; der Wizard ist
eine Hilfe zum Erstellen und Prüfen eines Manifests, keine Voraussetzung für
seine Ausführung.

## 1. Drei getrennte Ebenen

| Ebene | Zweck | Schreibrecht und Lebensdauer |
|---|---|---|
| Vorlagenpool | Wiederverwendbare `OS_SEALED`- und `SQL_PREPARED_SEALED`-Images | Registry-Parent sind hashverifiziert und read-only. Höchstens 20 veröffentlichte Vorlagen pro State Root.|
| Wegwerf-Lab | Schnelles Training, Test oder CI | Jede Hyper-V-VM erhält eine differenzierende Child-VHDX; Container erhalten run-lokale Ressourcen. Entfernen löscht nur den Run und seine Kinder.|
| Expertenaktion | Image bauen, veröffentlichen, umbenennen, entfernen oder beliebige Host-Mounts schreiben | Kein Teil des Standard-Setups. Sie erfordern eine sichtbare Einzelaktion bzw. eine doppelte explizite Freigabe.|

`Get-SqlServerLabWorkflow` und die lokale Oberfläche zeigen die Belegung als
`Vorlagenpool used/capacity`. Beim 21. veröffentlichten Image endet die
Publikation fail-closed mit `HYPERV_TEMPLATE_POOL_CAPACITY_EXCEEDED`; vorhandene
Vorlagen werden weder ersetzt noch automatisch bereinigt.

Ein aktiver Lab-Run hält sein `imageArtifactId` als Referenz. Das Entfernen des
zugehörigen Parent-Images wird bis zum Ende des Runs mit
`HYPERV_ARTIFACT_IN_USE` blockiert. Dadurch kann ein normaler Lab-Cleanup die
Vorlagenbibliothek nicht beschädigen.

## 2. Daten und Backups

Die zentrale Testdatenbibliothek liegt im Media Root unter `Testdaten`. Der
Artifact Resolver übernimmt nur hashverifizierte Artefakte in diese Bibliothek;
Staging, Trust-Entscheidungen und Quarantäne bleiben im State Root. Ein Lab
erhält keine globale Schreibfreigabe auf diese Bibliothek.

Schreibbare SQL-Daten und Backups gehören stattdessen in den explizit
initialisierten Data Root, gegliedert unter `Labs/<Lab>/...`. Ein flüchtiges Lab
verwendet verwaltete run-lokale Volumes beziehungsweise differenzierende VHDX.
`persistentData` ist die ausdrückliche Ausnahme: Es bindet ausschließlich den
bekannten, pro Lab erzeugten Data-Root-Bereich ein und wird von normalem
Run-Cleanup nicht entfernt.

Ein beliebiger `drives[].hostPath`-Mount ist bei Manifestausführung
standardmäßig `readOnly`; Docker und Podman geben ihn mit `:ro` weiter.
`readWrite` ist nur zulässig, wenn das Manifest
`expertActions.hostWriteMounts: true` enthält **und** der Aufruf den Schalter
`-AllowExpertHostWriteMounts` setzt. Dieser doppelte Opt-in verhindert, dass ein
Manifest versehentlich globale Hostdaten beschreibbar macht.

## 3. Unbeaufsichtigtes Manifest

Manifeste laufen standardmäßig mit `automation.mode: unattended`. Fehlende
Voraussetzungen führen zu einem klaren Fehler statt zu einer Eingabeaufforderung.
Passwörter stehen nie im Manifest, im Lock oder im Run-State. Das Manifest darf
nur den Namen einer eng benannten Prozess-Umgebungsvariablen referenzieren:

```json
{
  "$schema": "./Schemas/lab-manifest.schema.json",
  "name": "ci-sql-2025",
  "automation": {
    "mode": "unattended",
    "secrets": {
      "saPassword": "SQL_SERVER_LAB_SECRET_SA_PASSWORD"
    }
  },
  "instances": [
    {
      "id": "primary",
      "version": "2025",
      "provider": "docker",
      "databases": [
        {
          "name": "Demo",
          "restore": {
            "source": "https://example.invalid/Demo.bak",
            "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          }
        }
      ]
    }
  ]
}
```

Eine CI-Plattform stellt den Wert als Prozess-Secret bereit; lokal kann derselbe
Weg verwendet werden:

```powershell
$env:SQL_SERVER_LAB_SECRET_SA_PASSWORD = '<aus Secret Store oder CI-Injection>'
New-SqlServerLab -Manifest .\ci-sql-2025.json
Remove-Item Env:SQL_SERVER_LAB_SECRET_SA_PASSWORD
```

Alternativ können Aufrufer `-SaPassword`, `-GuestPassword` und
`-SqlSaPassword` als `SecureString` übergeben. `automation.mode: interactive`
ist ausschließlich ein expliziter Kompatibilitätsmodus. Remote-Restores ohne
`sha256` werden schon bei der Validierung als `TRUST_REQUIRED` sichtbar; in
einem unbeaufsichtigten Lauf wird ihnen niemals implizit vertraut. Katalog-
Samples folgen derselben Regel und benötigen entweder eine Katalog-Checksumme
oder einen zuvor bekannten lokalen Trust-Eintrag.

## 4. Provider- und Ressourcenwirkung

| Bereich | Standardpfad | Aktueller Umfang/Grenze |
|---|---|---|
| Credentials | Externe Prozess-Secret-Referenz oder `SecureString` | Keine Klartextwerte im Manifest, State oder Workflow-Überblick. Hyper-V braucht im unattended Lauf zusätzlich Guest- und ggf. SQL-SA-Secret. |
| Netzwerk | Portabler Intent/Exposure-Plan: Docker/Podman `nat`/`host`, Hyper-V `hostOnly`/`host`, `isolated`/`none` oder `nat`/`host` | Hyper-V-LAN und Netzwerk-Reconcile bleiben offen; ein fremdes WinNAT blockiert NAT fail-closed. |
| Data/Backup | Testdatenbibliothek nur verifiziert; pro Lab Data Root für Schreibdaten | Normales Entfernen berührt weder Testdatenbibliothek noch Data Root oder Vorlagenpool. |
| Samples/Restores | SHA-256, Trust Store, Cache und Run Lock | Ungehashte Remote-Quellen stoppen unattended mit `TRUST_REQUIRED`. |
| Ressourcen | Vorabprüfung und Profile bleiben aktiv | `skipAssessment` ist eine explizite Manifestoption. |
| UI/Konsole | Workflow zeigt Poolbelegung; Manifest ist als Container-Standardaktion vorhanden | Image-Bau, Vorlagenlöschung und schreibende Host-Mounts sind klar als Expertenaktionen getrennt. |

Der Container-Manifestpfad kann mehrere Docker-/Podman-Instanzen einschließlich
ausführbarer Datenbanken, Samples, Restores und Post-Provisioning atomar
bereitstellen. Der Hyper-V-Manifestpfad ist bewusst enger: genau eine
`SQL_PREPARED_SEALED`-Vorlage, ein explizites `preparedImageId`, differenzierender
Klon sowie optionale `persistentData`. Freie Drives und die gebundenen
Hyper-V-Netzwerkmodi `hostOnly`, `isolated` und `nat` sind deklarativ ausführbar.
NAT wird nur nach einem mutationsfreien WinNAT-/CIDR-Plan aktiviert und bindet
scopegebundene IPAM-Leases, Gateway und DNS. Datenbanken, Post-Provisioning,
Hyper-V-LAN und Netzwerk-Reconcile sind noch nicht vollständig atomar implementiert.

## 5. Sicher validieren

Diese Änderungen werden ohne Container-, VM- oder Netzwerkmutation geprüft:

```powershell
.\Tests\Static\Invoke-ManifestBuilderChecks.ps1
.\Tests\Static\Invoke-HyperVImageRegistryChecks.ps1
.\Tests\Static\Invoke-AllChecks.ps1
```

Ein echter Provider-Smoke-Test bleibt ein separater, bewusst beauftragter
Schritt. Der nächste Netzwerkausbau soll Hyper-V-LAN und Netzwerk-Reconcile
ergänzen, ohne den oben beschriebenen Eigentums- und Schreibschutz aufzuweichen.
