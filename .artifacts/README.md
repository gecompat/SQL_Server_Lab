# Lokale Laufzeitartefakte

Dieses Verzeichnis ist für lokal erzeugte Diagnose-, Export-, Evidence- und Testartefakte vorgesehen. Inhalte können SQL-Pläne, Logs, Dumps, Backups oder umgebungsbezogene Metadaten enthalten und dürfen nicht versioniert werden.

Nur diese Dokumentation und die `.gitignore` gehören ins Repository.

Reguläre Pester-Vertragsprüfungen werten ihr Ergebnis direkt aus und schreiben
keine dauerhaften XML-Berichte in dieses Verzeichnis. Explizit angeforderte
Diagnose- oder Release-Artefakte müssen durch ihren jeweiligen Erzeuger einen
klaren Aufbewahrungs- und Cleanup-Vertrag besitzen.
