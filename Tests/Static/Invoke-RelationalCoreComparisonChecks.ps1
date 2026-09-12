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
Add-RelationalCoreCheck 'Allowlist und RLS-/Sondertabellen-Blockade sind fail-closed' ($private -match 'HasRls' -and $private -match 'WHERE t\.is_ms_shipped=0' -and $private -notmatch 'WHERE t\.is_ms_shipped=0 AND t\.temporal_type=0' -and $private -match 'TEMPORAL_TABLE' -and $private -match 'FILETABLE' -and $private -match 'EXTERNAL_TABLE' -and $private -match 'MEMORY_OPTIMIZED_TABLE' -and $private -match 'NODE_TABLE' -and $private -match 'EDGE_TABLE' -and $private -match 'LEDGER_TABLE' -and $private -match "N'datetime2'" -and $private -notmatch "N'money'" -and $private -notmatch "N'smalldatetime'" -and $private -notmatch "N'decimal'" -and $private -match 'TABLE_UNSUPPORTED_OR_POLICY_BLOCKED')
Add-RelationalCoreCheck 'Primärschlüssel, max- und versteckte Spalten bleiben strikt blockiert' ($private -match 'PrimaryKeyTypes' -and $private -match 'PrimaryKeyUnsupportedReasons' -and $private -match "N'tinyint',N'smallint',N'int',N'bigint',N'uniqueidentifier'" -and $private -match 'c\.max_length=-1' -and $private -match 'c\.is_hidden=1')
Add-RelationalCoreCheck 'Streamingvergleich nutzt vollständige explizite Projektion und Bytevergleich' ($private -match 'SequentialAccess' -and $private -match 'SelectProjection' -and $private -notmatch 'SELECT \* FROM' -and $private -match 'ORDER BY' -and $private -match 'ConvertTo-LabRelationalCoreFieldBytes' -and $private -match '\$left\.Length -ne \$right\.Length' -and $private -match 'for\(\$i=0;\$i -lt \$left\.Length;\$i\+\+\)' -and $private -notmatch '(?i)hash.*match')
Add-RelationalCoreCheck 'Datenbankbindung fordert ONLINE, READ_ONLY und exakte Live-Identität' ($private -match 'Assert-LabRelationalCoreDatabaseBinding' -and $private -match "'ONLINE'" -and $private -match 'IsReadOnly' -and $private -match 'RELATIONAL_CORE_DATABASE_NOT_ONLINE_READ_ONLY')
$bindingStart=$private.IndexOf('function Assert-LabRelationalCoreDatabaseBinding')
$inventoryStart=$private.IndexOf('function Get-LabRelationalCoreTableInventory')
$binding=$private.Substring($bindingStart,$inventoryStart-$bindingStart)
Add-RelationalCoreCheck 'Datenbankbindung liest eine Einzelzeile vor der Mehrzeilenprüfung aus' ($binding.IndexOf('$observation=') -gt $binding.IndexOf('if(-not $reader.Read())') -and $binding.IndexOf('if($reader.Read())') -gt $binding.IndexOf('$observation=') -and $binding -match 'RELATIONAL_CORE_DATABASE_IDENTITY_UNVERIFIABLE')
Add-RelationalCoreCheck 'Findings enthalten keine Rohwerte und CI selektiert die Suite' ($private -match 'TABLE_ROW_VALUE_MISMATCH' -and $private -notmatch 'Value=\$' -and $selector -match 'Invoke-RelationalCoreComparisonChecks\.ps1')

Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
Add-RelationalCoreCheck 'Export ist nach Modulimport auflösbar' ([bool](Get-Command Test-SqlServerLabRelationalCoreComparison -Module SqlServerLab -ErrorAction SilentlyContinue))
$module=Get-Module SqlServerLab
$characterization=& $module {
    $nullBytes=ConvertTo-LabRelationalCoreFieldBytes -Value $null
    $emptyBytes=ConvertTo-LabRelationalCoreFieldBytes -Value ''
    $spaceBytes=ConvertTo-LabRelationalCoreFieldBytes -Value ' '
    $unicodeBytes=ConvertTo-LabRelationalCoreFieldBytes -Value 'ä'
    $binaryBytes=ConvertTo-LabRelationalCoreFieldBytes -Value ([byte[]](0,255))
    $decimalBlocked=$false;try{ConvertTo-LabRelationalCoreFieldBytes -Value ([decimal]1)|Out-Null}catch{$decimalBlocked=$_.Exception.Message -eq 'RELATIONAL_CORE_VALUE_TYPE_UNEXPECTED'}
    $allowed=[PSCustomObject]@{HasRls=$false;HasPrimaryKey=$true;PrimaryKeyOrder='[id]';PrimaryKeyTypes='int';PrimaryKeyUnsupportedReasons=$null;SelectProjection='[id]';UnsupportedReasons=$null}
    $unsupportedPk=[PSCustomObject]@{HasRls=$false;HasPrimaryKey=$true;PrimaryKeyOrder='[name]';PrimaryKeyTypes='nvarchar';PrimaryKeyUnsupportedReasons='UNSUPPORTED';SelectProjection='[name]';UnsupportedReasons=$null}
    $maxColumn=[PSCustomObject]@{HasRls=$false;HasPrimaryKey=$true;PrimaryKeyOrder='[id]';PrimaryKeyTypes='int';PrimaryKeyUnsupportedReasons=$null;SelectProjection='[id],[payload]';UnsupportedReasons='UNSUPPORTED'}
    $hiddenColumn=[PSCustomObject]@{HasRls=$false;HasPrimaryKey=$true;PrimaryKeyOrder='[id]';PrimaryKeyTypes='int';PrimaryKeyUnsupportedReasons=$null;SelectProjection='[id],[shadow]';UnsupportedReasons='UNSUPPORTED'}
    $specialTable=[PSCustomObject]@{HasRls=$false;HasPrimaryKey=$true;PrimaryKeyOrder='[id]';PrimaryKeyTypes='int';PrimaryKeyUnsupportedReasons=$null;SelectProjection='[id]';UnsupportedReasons='TEMPORAL_TABLE'}
    $missingReadOnly=$false;try{Test-LabRelationalCoreDatabaseObservation -RequestedDatabaseName SafeDb -Observation ([PSCustomObject]@{ActualName='SafeDb';DatabaseId=5;State='ONLINE';IsReadOnly=$false})|Out-Null}catch{$missingReadOnly=$_.Exception.Message -eq 'RELATIONAL_CORE_DATABASE_NOT_ONLINE_READ_ONLY'}
    $wrongIdentity=$false;try{Test-LabRelationalCoreDatabaseObservation -RequestedDatabaseName SafeDb -Observation ([PSCustomObject]@{ActualName='OtherDb';DatabaseId=5;State='ONLINE';IsReadOnly=$true})|Out-Null}catch{$wrongIdentity=$_.Exception.Message -eq 'RELATIONAL_CORE_DATABASE_NOT_ONLINE_READ_ONLY'}
    $unsupportedPkEligibility=Get-LabRelationalCoreTableEligibility -Table $unsupportedPk -TableOrdinal 7
    $maxColumnEligibility=Get-LabRelationalCoreTableEligibility -Table $maxColumn -TableOrdinal 8
    $hiddenColumnEligibility=Get-LabRelationalCoreTableEligibility -Table $hiddenColumn -TableOrdinal 9
    $specialTableEligibility=Get-LabRelationalCoreTableEligibility -Table $specialTable -TableOrdinal 10
    [PSCustomObject]@{NullDistinct=($nullBytes -join ',') -ne ($emptyBytes -join ',');EmptyDistinctFromSpace=($emptyBytes -join ',') -ne ($spaceBytes -join ',');UnicodeExact=($unicodeBytes -join ',') -eq '1,195,164';BinaryExact=($binaryBytes -join ',') -eq '1,0,255';DecimalBlocked=$decimalBlocked;AllowedTable=(Test-LabRelationalCoreTableSupported -Table $allowed);UnsupportedPkBlocked=-not (Test-LabRelationalCoreTableSupported -Table $unsupportedPk);MaxColumnBlocked=-not (Test-LabRelationalCoreTableSupported -Table $maxColumn);HiddenColumnBlocked=-not (Test-LabRelationalCoreTableSupported -Table $hiddenColumn);SpecialTableBlocked=-not (Test-LabRelationalCoreTableSupported -Table $specialTable);UnsupportedTableResultCodes=($unsupportedPkEligibility.Finding.Code -eq 'TABLE_UNSUPPORTED_OR_POLICY_BLOCKED' -and $maxColumnEligibility.Finding.Code -eq 'TABLE_UNSUPPORTED_OR_POLICY_BLOCKED' -and $hiddenColumnEligibility.Finding.Code -eq 'TABLE_UNSUPPORTED_OR_POLICY_BLOCKED' -and $specialTableEligibility.Finding.Code -eq 'TABLE_UNSUPPORTED_OR_POLICY_BLOCKED' -and $unsupportedPkEligibility.Finding.TableOrdinal -eq 7 -and $maxColumnEligibility.Finding.TableOrdinal -eq 8 -and $hiddenColumnEligibility.Finding.TableOrdinal -eq 9 -and $specialTableEligibility.Finding.TableOrdinal -eq 10);MissingReadOnlyBlocked=$missingReadOnly;WrongIdentityBlocked=$wrongIdentity}
}
Add-RelationalCoreCheck 'Byte-Charakterisierung trennt NULL, leer, Unicode, Leerzeichen und Binärdaten' ($characterization.NullDistinct -and $characterization.EmptyDistinctFromSpace -and $characterization.UnicodeExact -and $characterization.BinaryExact)
Add-RelationalCoreCheck 'Charakterisierung blockiert Decimal, Sondertabellen, unzulässige PKs, max/versteckte Spalten und fehlendes READ_ONLY' ($characterization.DecimalBlocked -and $characterization.AllowedTable -and $characterization.UnsupportedPkBlocked -and $characterization.MaxColumnBlocked -and $characterization.HiddenColumnBlocked -and $characterization.SpecialTableBlocked -and $characterization.UnsupportedTableResultCodes -and $characterization.MissingReadOnlyBlocked -and $characterization.WrongIdentityBlocked)
if($failures.Count){throw "RELATIONAL_CORE_COMPARISON_CHECKS_FAILED: $($failures -join '; ')"}
Write-Host 'Relational-Core-Comparison-Vertrag: PASS' -ForegroundColor Green
