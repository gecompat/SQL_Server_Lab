#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')

if (-not ('SqlServerLabFakeCollationConnection' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Data;
public sealed class SqlServerLabFakeCollationParameter { public object Value { get; set; } }
public sealed class SqlServerLabFakeCollationParameters {
  private readonly Dictionary<string, SqlServerLabFakeCollationParameter> items = new Dictionary<string, SqlServerLabFakeCollationParameter>(StringComparer.Ordinal);
  public SqlServerLabFakeCollationParameter Add(string name, SqlDbType type, int size) { var item = new SqlServerLabFakeCollationParameter(); items.Add(name, item); return item; }
  public SqlServerLabFakeCollationParameter this[string name] { get { return items[name]; } }
}
public sealed class SqlServerLabFakeCollationReader {
  public static bool CatalogAvailable = true;
  public static string ServerCollation = "Latin1_General_100_CS_AS";
  public bool Read() { return true; }
  public bool GetBoolean(int ordinal) { return CatalogAvailable; }
  public bool IsDBNull(int ordinal) { return String.IsNullOrEmpty(ServerCollation); }
  public string GetString(int ordinal) { return ServerCollation; }
  public void Dispose() { }
}
public sealed class SqlServerLabFakeCollationCommand {
  public int CommandTimeout { get; set; }
  public string CommandText { get; set; }
  public SqlServerLabFakeCollationParameters Parameters { get; } = new SqlServerLabFakeCollationParameters();
  public SqlServerLabFakeCollationReader ExecuteReader() { return new SqlServerLabFakeCollationReader(); }
  public void Dispose() { }
}
public sealed class SqlServerLabFakeCollationConnection {
  public void Open() { }
  public SqlServerLabFakeCollationCommand CreateCommand() { return new SqlServerLabFakeCollationCommand(); }
  public void Dispose() { }
}
'@
}

$sourcePath = Join-Path $repoRoot 'Private\CollationRuntimeEvidence.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding utf8
$tokens = $null
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
Add-CheckResult -Name 'Collation-Runtime-Helfer besitzt einen fehlerfreien AST' -Success ($parseErrors.Count -eq 0)
Add-CheckResult -Name 'Runtime-Abfrage bleibt eine parametrisierte read-only SQL-Abfrage' -Success (
    $source -match 'sys\.fn_helpcollations\(\).*@collation' -and
    $source -match "SERVERPROPERTY\(N'Collation'\)" -and
    $source -match "Parameters\.Add\('@collation'" -and
    $source -notmatch '(?i)\b(?:insert|update|delete|alter|create|drop)\b'
)
Add-CheckResult -Name 'Verbindung verwendet SqlCredential ohne Passwort in der ConnectionString-Ausgabe' -Success (
    $source -match 'SqlCredential\]::new\(' -and $source -match 'MakeReadOnly' -and
    $source -match 'Pooling=False' -and $source -match 'Persist Security Info=False' -and
    $source -notmatch '(?i)(?:password|pwd)\s*='
)
Add-CheckResult -Name 'Fehlercodes sind fail-closed und sanitisert' -Success (
    $source -match 'SQL_COLLATION_RUNTIME_CATALOG_REJECTED' -and
    $source -match 'SQL_COLLATION_RUNTIME_CATALOG_UNAVAILABLE' -and
    $source -match 'SQL_COLLATION_RUNTIME_POSTCONDITION_FAILED' -and
    $source -match 'SQL_COLLATION_RUNTIME_QUERY_FAILED' -and
    $source -notmatch 'Write-(?:Host|Information|Verbose|Warning).*Connection'
)
$newLabSource = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\New-SqlServerLab.ps1') -Raw -Encoding utf8
$readinessOffset = $newLabSource.IndexOf('if ($readiness.Ready) { break }')
$evidenceOffset = $newLabSource.IndexOf('Test-LabContainerSqlCollationRuntimeEvidence')
$instanceOffset = $newLabSource.IndexOf('$labInstances += [PSCustomObject]@{')
$serverConfigOffset = $newLabSource.IndexOf('foreach ($instance in ($resolved.instances | Where-Object { $_.serverConfig }))')
Add-CheckResult -Name 'Collation-Evidence liegt nach Readiness und vor Konfiguration, Datenbanken und Samples' -Success (
    $readinessOffset -ge 0 -and $evidenceOffset -gt $readinessOffset -and $instanceOffset -gt $evidenceOffset -and $serverConfigOffset -gt $instanceOffset
)
Add-CheckResult -Name 'Rungebundene Connection-Evidence persistiert die sanitisierte Collation-Postcondition' -Success (
    $newLabSource -match 'collation\s*=\s*\$_\.Collation'
)

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
$module = Import-Module $modulePath -Force -PassThru
try {
    $observations = & $module {
        $original = ${function:script:New-LabCollationRuntimeSqlConnection}
        try {
            function script:New-LabCollationRuntimeSqlConnection { param($HostName,$Port,$SaPassword) [SqlServerLabFakeCollationConnection]::new() }
            [SqlServerLabFakeCollationReader]::CatalogAvailable = $true
            [SqlServerLabFakeCollationReader]::ServerCollation = 'Latin1_General_100_CS_AS'
            $secret = [Security.SecureString]::new()
            foreach ($character in 'Synthetic_collation_only_7!Aa'.ToCharArray()) { $secret.AppendChar($character) }
            $secret.MakeReadOnly()
            $success = Test-LabContainerSqlCollationRuntimeEvidence -Provider docker -SqlVersion 2025 `
                -Collation Latin1_General_100_CS_AS -HostName 127.0.0.1 -Port 1433 -SaPassword $secret
            [SqlServerLabFakeCollationReader]::CatalogAvailable = $false
            $catalogCode = try {
                $null = Test-LabContainerSqlCollationRuntimeEvidence -Provider podman -SqlVersion 2022 `
                    -Collation Latin1_General_100_CS_AS -HostName 127.0.0.1 -Port 1433 -SaPassword $secret
                ''
            }
            catch { $_.Exception.Message }
            [SqlServerLabFakeCollationReader]::CatalogAvailable = $true
            [SqlServerLabFakeCollationReader]::ServerCollation = 'SQL_Latin1_General_CP1_CI_AS'
            $postconditionCode = try {
                $null = Test-LabContainerSqlCollationRuntimeEvidence -Provider docker -SqlVersion 2025 `
                    -Collation Latin1_General_100_CS_AS -HostName 127.0.0.1 -Port 1433 -SaPassword $secret
                ''
            }
            catch { $_.Exception.Message }
            [PSCustomObject]@{ Success=$success; CatalogCode=$catalogCode; PostconditionCode=$postconditionCode }
        }
        finally { Set-Item Function:script:New-LabCollationRuntimeSqlConnection -Value $original }
    }
    Add-CheckResult -Name 'Katalog und SQL-Postcondition liefern nur sanitisierte Erfolgs-Evidence' -Success (
        $observations.Success.Status -eq 'VERIFIED' -and $observations.Success.Provider -eq 'docker' -and
        $observations.Success.ExpectedCollation -eq 'Latin1_General_100_CS_AS' -and
        $observations.Success.ActualCollation -eq 'Latin1_General_100_CS_AS' -and
        ($observations.Success | ConvertTo-Json -Depth 5) -notmatch '(?i)password|hostname|port|connection'
    )
    Add-CheckResult -Name 'Fehlender SQL-Collation-Katalogwert bricht fail-closed ab' -Success ($observations.CatalogCode -eq 'SQL_COLLATION_RUNTIME_CATALOG_UNAVAILABLE')
    Add-CheckResult -Name 'Abweichende SQL-Instanzcollation bricht fail-closed ab' -Success ($observations.PostconditionCode -eq 'SQL_COLLATION_RUNTIME_POSTCONDITION_FAILED')
}
finally { Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue }

if ($failures.Count -gt 0) { Write-Error "$($failures.Count) Checks fehlgeschlagen."; exit 1 }
Write-Host "$passed Checks bestanden." -ForegroundColor Green
