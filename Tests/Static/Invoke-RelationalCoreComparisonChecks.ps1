#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures=[Collections.Generic.List[string]]::new()
function Add-RelationalCoreCheck { param([string]$Name,[bool]$Success) if($Success){Write-Host "PASS $Name" -ForegroundColor Green}else{$failures.Add($Name);Write-Host "FAIL $Name" -ForegroundColor Red} }

$private=Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Private\RelationalCoreComparison.ps1') -Encoding utf8
$public=Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Public\Test-SqlServerLabRelationalCoreComparison.ps1') -Encoding utf8
$manifest=Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'SqlServerLab.psd1') -Encoding utf8
$selector=Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'Tools\Get-CiTestSelection.ps1') -Encoding utf8

Add-RelationalCoreCheck 'Öffentlicher Export und Paarvertrag sind vorhanden' ($manifest -match "'Test-SqlServerLabRelationalCoreComparison'" -and $public -match '\[object\[\]\]\$ComparisonPair' -and $public -notmatch '(?i)ConnectionString|HostName|\[string\]\$Sql|\[SecureString\]')
Add-RelationalCoreCheck 'Schema bindet Read-only-Profil und blockierten Executor' ((Test-Json -LiteralPath (Join-Path $repoRoot 'Schemas\relational-core-comparison.schema.json')) -and $private -match 'SqlServerLab\.RelationalCoreComparison/1\.0' -and $private -match "TransferExecutorStatus='BLOCKED'" -and $private -match 'MutationAllowed=\$false')
Add-RelationalCoreCheck 'Livebindung verlangt Container und RuntimeScope vor SQL' ($private -match 'Get-LabContainerRuntimeScope' -and $private -match 'RELATIONAL_CORE_LIVE_CONTAINER_BINDING_UNVERIFIABLE' -and $private -match "Provider -notin @\('docker','podman'\)")
Add-RelationalCoreCheck 'Credentials verbleiben SecureString-basiert im Prozess' ($private -match '\[System\.Data\.SqlClient\.SqlCredential\]::new' -and $private -match 'MakeReadOnly' -and $private -match 'Get-LabSecret' -and $private -notmatch 'ConvertFrom-LabSecureString' -and $private -notmatch 'PtrToStringBSTR')
Add-RelationalCoreCheck 'Allowlist und RLS-/Sondertabellen-Blockade sind fail-closed' ($private -match 'HasRls' -and $private -match 't\.temporal_type=0' -and $private -match 't\.is_filetable=0' -and $private -match 't\.is_external=0' -and $private -match 't\.is_memory_optimized=0' -and $private -match "N'varbinary'" -and $private -match 'TABLE_UNSUPPORTED_OR_POLICY_BLOCKED')
Add-RelationalCoreCheck 'Streamingvergleich nutzt PK-Ordnung und vollständigen Bytevergleich' ($private -match 'SequentialAccess' -and $private -match 'ORDER BY' -and $private -match 'ConvertTo-LabRelationalCoreFieldBytes' -and $private -match '\$left\.Length -ne \$right\.Length' -and $private -match 'for\(\$i=0;\$i -lt \$left\.Length;\$i\+\+\)' -and $private -notmatch '(?i)hash.*match')
Add-RelationalCoreCheck 'Findings enthalten keine Rohwerte und CI selektiert die Suite' ($private -match 'TABLE_ROW_VALUE_MISMATCH' -and $private -notmatch 'Value=\$' -and $selector -match 'Invoke-RelationalCoreComparisonChecks\.ps1')

Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
Add-RelationalCoreCheck 'Export ist nach Modulimport auflösbar' ([bool](Get-Command Test-SqlServerLabRelationalCoreComparison -Module SqlServerLab -ErrorAction SilentlyContinue))
if($failures.Count){throw "RELATIONAL_CORE_COMPARISON_CHECKS_FAILED: $($failures -join '; ')"}
Write-Host 'Relational-Core-Comparison-Vertrag: PASS' -ForegroundColor Green
