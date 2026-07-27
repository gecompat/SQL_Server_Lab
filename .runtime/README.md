# SQL_Server_Lab Laufzeitdaten

Dieses Verzeichnis ist der standardmäßige lokale Datenbereich des SQL_Server_Lab.

Standardpfad:

```text
<RepositoryRoot>\.runtime
```

Darunter liegen ausschließlich nicht versionierte Laufzeitdaten, zum Beispiel:

- `state/` – Run-State, Scope-Marker und Verbindungsinformationen
- `runs/` – vom Lab verwaltete Laufzeitverzeichnisse
- `cache/` – heruntergeladene oder erzeugte Cache-Dateien
- `logs/` – Laufzeit- und Diagnoseprotokolle
- `secrets/` – lokale Zugangsdaten und Testsession-Metadaten

Die Inhalte werden durch `.gitignore` vom Repository ausgeschlossen.

## Pfadregeln

- Ein Datenroot darf niemals direkt ein Laufwerksroot wie `C:\` oder `D:\` sein.
- Ein neu gewählter globaler Datenroot muss leer sein oder darf noch nicht existieren.
- Explizite Storage-Pfade einer SQL-Umgebung dürfen bereits existieren, müssen aber Unterverzeichnisse sein.
- SQL_Server_Lab legt darin eigene Run-Unterverzeichnisse an.
- Beim Cleanup werden ausschließlich im Run-State als Lab-eigen dokumentierte Pfade und Objekte entfernt.
- Explizit angegebene C-/E-Verteilungen, etwa für TempDB, bleiben zulässig und werden nicht auf den globalen DataRoot umgebogen.

## Runner

Für lokale Aufrufe und GitHub Actions Runner gilt dieselbe Standardstruktur. Da der Modul-Root dem Checkout entspricht, liegt der DataRoot auch auf einem Self-hosted Runner unter `<RepositoryRoot>\.runtime`.

Ein explizit gesetzter Pfad über `SQL_SERVER_LAB_STATE` beziehungsweise einen Funktionsparameter hat weiterhin Vorrang.
