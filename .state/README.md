# Lokaler Zustandsbereich

Dieses Verzeichnis ist ausschließlich für lokalen, repositorynahen Laufzeit-State vorgesehen.

Der produktive Standard-State des Moduls liegt außerhalb des Git-Checkouts:

- Windows: `%LOCALAPPDATA%\SqlServerLab`
- Linux/macOS: `~/.sql-server-lab`
- Override: Umgebungsvariable `SQL_SERVER_LAB_STATE`

Typische Laufzeitinhalte sind `config.json`, `runs/`, `scope-markers/`, Run-Logs, Cleanup-Pläne und Connection-Metadaten. Diese Daten können lokale Benutzer-, Host-, Port- und Umgebungsinformationen enthalten und dürfen nicht versioniert werden.

Nur diese Dokumentation und die lokale `.gitignore` gehören ins Repository.
