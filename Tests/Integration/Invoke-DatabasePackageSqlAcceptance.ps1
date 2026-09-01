#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt den nativen Windows-SQL-FILESTREAM-Paket- und Attach-Nachweis aus.
.DESCRIPTION
    Erzeugt eine ausschliesslich test-eigene SQL-2025-Datenbank mit MDF, NDF,
    LDF und verschachteltem FILESTREAM-Inhalt, setzt sie exklusiv offline,
    publiziert und verifiziert das Paket, detached die Quelle und attached eine
    unabhaengige Copy-then-Attach-Kopie. Inhalt, Dateipfade, Journal und Cleanup
    werden real gegen SQL Server geprueft. Es werden keine Secrets persistiert.
#>
[CmdletBinding()]
param([string]$Server='localhost')

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$token=[Guid]::NewGuid().ToString('N').Substring(0,12)
$databaseName="Psr009Native$token"
$testRoot=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-psr009-$token"
$dataRoot=Join-Path $testRoot 'Lab_Data'
$operationRoot=Join-Path $testRoot 'AttachOperation'
$module=$null;$cloneRoot=$null;$databaseCreated=$false;$databaseDetached=$false;$completed=$false
$connectionString="Server=$Server;Database=master;Integrated Security=True;Encrypt=False;Connect Timeout=30;"
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Database_Package_Native_Acceptance');$mutexAcquired=$false

function Invoke-NativePackageSql {
    param([Parameter(Mandatory)][string]$Query,[switch]$Scalar)
    $connection=[Data.SqlClient.SqlConnection]::new($connectionString)
    try{
        $connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=600;$command.CommandText=$Query
        if($Scalar){return $command.ExecuteScalar()}
        $reader=$command.ExecuteReader();$rows=[Collections.Generic.List[object]]::new()
        while($reader.Read()){
            $row=[ordered]@{}
            for($i=0;$i -lt $reader.FieldCount;$i++){$row[$reader.GetName($i)]=if($reader.IsDBNull($i)){$null}else{$reader.GetValue($i)}}
            $rows.Add([PSCustomObject]$row)
        }
        $reader.Dispose();return @($rows)
    } finally {$connection.Dispose()}
}

function Assert-NativePackage { param([bool]$Condition,[string]$Description) if(-not $Condition){throw "DATABASE_PACKAGE_NATIVE_ACCEPTANCE_FAILED: $Description"};Write-Host "PASS: $Description" -ForegroundColor Green }

try{
    $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(15));if(-not $mutexAcquired){throw 'DATABASE_PACKAGE_NATIVE_ACCEPTANCE_HOST_LOCK_TIMEOUT'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-NativePackage $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) 'Runner besitzt das für detached FILESTREAM-Dateien erforderliche erhöhte Token'
    $tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    foreach($stale in @(Get-ChildItem -LiteralPath $tempParent -Directory -Filter 'sql-lab-psr009-*')){
        $stalePath=[IO.Path]::GetFullPath($stale.FullName)
        if(-not $stalePath.StartsWith("$tempParent\sql-lab-psr009-",[StringComparison]::OrdinalIgnoreCase)){throw 'DATABASE_PACKAGE_NATIVE_STALE_SCOPE_INVALID'}
        $staleSource=@(Get-ChildItem -LiteralPath $stalePath -Directory -Filter 'Psr009Native*_source')
        if($staleSource.Count -eq 1){
            $staleDatabase=$staleSource[0].Name -replace '_source$',''
            if($staleDatabase -notmatch '^Psr009Native[a-f0-9]{12}$'){throw 'DATABASE_PACKAGE_NATIVE_STALE_DATABASE_SCOPE_INVALID'}
            $registered=[int](Invoke-NativePackageSql -Scalar -Query "SELECT CASE WHEN DB_ID(N'$staleDatabase') IS NULL THEN 0 ELSE 1 END;")
            if($registered -ne 0){throw "DATABASE_PACKAGE_NATIVE_STALE_DATABASE_REGISTERED: $staleDatabase"}
        }
        Remove-Item -LiteralPath $stalePath -Recurse -Force -ErrorAction Stop
    }
    $serverEvidence=[string](Invoke-NativePackageSql -Scalar -Query "SELECT CONCAT(CONVERT(nvarchar(10),SERVERPROPERTY('ProductMajorVersion')),N'|',CONVERT(nvarchar(10),SERVERPROPERTY('FilestreamEffectiveLevel')),N'|',CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultDataPath')));")
    $parts=$serverEvidence.Split('|',3);$sqlMajor=[string]$parts[0];$fileStreamLevel=[int]$parts[1];$defaultDataPath=[IO.Path]::GetFullPath([string]$parts[2])
    Assert-NativePackage ([int]$sqlMajor -ge 17 -and $fileStreamLevel -gt 0 -and (Test-Path -LiteralPath $defaultDataPath -PathType Container)) 'SQL 2025 und native FILESTREAM-Capability sind verfügbar'
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    $serviceAccount=[string](Invoke-NativePackageSql -Scalar -Query "SELECT TOP(1) service_account FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server (%' ORDER BY servicename;")
    if([string]::IsNullOrWhiteSpace($serviceAccount)){throw 'DATABASE_PACKAGE_NATIVE_SQL_SERVICE_ACCOUNT_NOT_OBSERVED'}
    $null=& icacls $testRoot /grant "${serviceAccount}:(OI)(CI)M" /Q
    if($LASTEXITCODE -ne 0){throw 'DATABASE_PACKAGE_NATIVE_TEST_ACL_FAILED'}
    $sourceRoot=Join-Path $testRoot "${databaseName}_source";$cloneRoot=Join-Path $testRoot "${databaseName}_clone"
    New-Item -ItemType Directory -Path $sourceRoot -Force|Out-Null
    $currentAccount=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $null=& icacls $sourceRoot /grant "${currentAccount}:(OI)(CI)F" /Q
    if($LASTEXITCODE -ne 0){throw 'DATABASE_PACKAGE_NATIVE_SOURCE_ACL_FAILED'}
    $primary=Join-Path $sourceRoot "$databaseName.mdf";$secondary=Join-Path $sourceRoot "${databaseName}_2.ndf";$log=Join-Path $sourceRoot "${databaseName}_log.ldf";$stream=Join-Path $sourceRoot "${databaseName}_stream"
    $escapedDatabase=$databaseName.Replace(']',']]')
    $createDatabase=@"
CREATE DATABASE [$escapedDatabase]
ON PRIMARY (NAME=N'${databaseName}_Primary',FILENAME=N'$($primary.Replace("'","''"))',SIZE=16MB),
FILEGROUP [${databaseName}_Rows] (NAME=N'${databaseName}_Secondary',FILENAME=N'$($secondary.Replace("'","''"))',SIZE=8MB),
FILEGROUP [${databaseName}_Fs] CONTAINS FILESTREAM (NAME=N'${databaseName}_Stream',FILENAME=N'$($stream.Replace("'","''"))')
LOG ON (NAME=N'${databaseName}_Log',FILENAME=N'$($log.Replace("'","''"))',SIZE=8MB);
"@
    $databaseCreated=$true;$null=Invoke-NativePackageSql -Query $createDatabase
    $createEvidence=@"
ALTER DATABASE [$escapedDatabase] SET FILESTREAM (NON_TRANSACTED_ACCESS=FULL, DIRECTORY_NAME=N'$databaseName');
USE [$escapedDatabase];
CREATE TABLE dbo.Evidence(Id uniqueidentifier ROWGUIDCOL NOT NULL UNIQUE,Payload varbinary(max) FILESTREAM NOT NULL,Label nvarchar(40) NOT NULL) FILESTREAM_ON [${databaseName}_Fs];
INSERT dbo.Evidence VALUES(NEWID(),CONVERT(varbinary(max),REPLICATE('native-filestream-',4096)),N'preserved');
"@
    $null=Invoke-NativePackageSql -Query $createEvidence
    $contentHash=[string](Invoke-NativePackageSql -Scalar -Query "USE [$escapedDatabase]; SELECT CONVERT(varchar(64),HASHBYTES('SHA2_256',Payload),2) FROM dbo.Evidence WHERE Label=N'preserved';")
    $inventory=@(Invoke-NativePackageSql -Query "SELECT name AS LogicalName,CASE type WHEN 0 THEN 'DATA' WHEN 1 THEN 'LOG' WHEN 2 THEN 'FILESTREAM' END AS Type,physical_name AS FullPath FROM sys.master_files WHERE database_id=DB_ID(N'$databaseName') ORDER BY file_id;")
    Assert-NativePackage ($inventory.Count -eq 4 -and @($inventory|Where-Object Type -eq 'FILESTREAM').Count -eq 1) 'SQL inventarisiert MDF, NDF, LDF und FILESTREAM-Container'
    $null=Invoke-NativePackageSql -Query "ALTER DATABASE [$escapedDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; EXEC master.dbo.sp_detach_db @dbname=N'$databaseName';"
    $databaseDetached=$true;$databaseCreated=$false
    $state=[string](Invoke-NativePackageSql -Scalar -Query "SELECT CASE WHEN DB_ID(N'$databaseName') IS NULL THEN N'DETACHED' ELSE N'ATTACHED' END;")
    Assert-NativePackage ($state -eq 'DETACHED') 'Datenbank ist nach exklusivem Lock erneut als DETACHED beobachtet'
    $module=Import-Module $modulePath -Force -PassThru
    $package=& $module {
        param($Root,$Name,$Major,$Inventory)
        $null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([Guid]::NewGuid().ToString('D')) -Confirm:$false;$env:SQL_SERVER_LAB_DATA_ROOT=$Root
        New-LabDatabasePackage -DatabaseName $Name -Provider hyperv -SqlMajorVersion $Major -SourceEvidence ([PSCustomObject]@{DatabaseState='DETACHED';DetachState='CLEAN_DETACHED';AccessMode='EXCLUSIVE';WriterCount=0;StateObservedAfterLock=$true}) -DatabaseMetadata ([PSCustomObject]@{HasFileStream=$true;FileStreamInventoryComplete=$true;IsEncrypted=$false;TdeKeyEvidenceVerified=$false}) -FileInventory $Inventory -DataRoot $Root
    } $dataRoot $databaseName $sqlMajor $inventory
    $selected=& $module {param($Id,$Root)$env:SQL_SERVER_LAB_DATA_ROOT=$Root;Get-LabDatabasePackage -DatabasePackageId $Id -DataRoot $Root} $package.DatabasePackageId $dataRoot
    Assert-NativePackage ($selected.Record.Objects.Count -gt 4 -and $selected.Record.ManifestSha256 -eq $package.ManifestSha256) 'Rekursiv gehashtes FILESTREAM-Paket ist unverändert selektierbar'
    $plan=& $module {param($Package,$Target,$Major) Get-LabDatabasePackageAttachPlan -Package $Package -TargetDirectory $Target -TargetEvidence ([PSCustomObject]@{SqlMajorVersion=[int]$Major;FileStreamEnabled=$true;TdeKeyAvailable=$false;DatabaseExists=$false;ExclusiveUseAvailable=$true;PackageWriterCount=0})} $selected $cloneRoot $sqlMajor
    $databaseCreated=$true
    $attach=& $module {
        param($Plan,$Package,$Operation,$ConnectionString)
        Invoke-LabDatabasePackageAttachPlan -Plan $Plan -Package $Package -OperationDirectory $Operation -Confirm:$false -AttachAction {
            param($Name,$Files);$connection=[Data.SqlClient.SqlConnection]::new($ConnectionString);try{$connection.Open();$command=$connection.CreateCommand();$command.CommandTimeout=600;$escaped=$Name.Replace(']',']]');$fileClauses=@($Files|ForEach-Object{"(FILENAME=N'$(([string]$_.Path).Replace("'","''"))')"}) -join ',';$command.CommandText="CREATE DATABASE [$escaped] ON $fileClauses FOR ATTACH;";$null=$command.ExecuteNonQuery()}finally{$connection.Dispose()}
        }.GetNewClosure() -VerifyAction {
            param($Name,$Files);$connection=[Data.SqlClient.SqlConnection]::new($ConnectionString);try{$connection.Open();$command=$connection.CreateCommand();$command.CommandText="SELECT state_desc FROM sys.databases WHERE name=@name;";$null=$command.Parameters.Add('@name',[Data.SqlDbType]::NVarChar,128);$command.Parameters['@name'].Value=$Name;$state=[string]$command.ExecuteScalar();$command.Parameters.Clear();$command.CommandText="SELECT physical_name FROM sys.master_files WHERE database_id=DB_ID(@name) ORDER BY file_id;";$null=$command.Parameters.Add('@name',[Data.SqlDbType]::NVarChar,128);$command.Parameters['@name'].Value=$Name;$reader=$command.ExecuteReader();$actual=[Collections.Generic.List[string]]::new();while($reader.Read()){$actual.Add([IO.Path]::GetFullPath([string]$reader.GetString(0)))};$reader.Dispose();$expected=@($Files.Path|ForEach-Object{[IO.Path]::GetFullPath([string]$_)});[PSCustomObject]@{DatabaseState=$state;AttachmentCount=1;PathsMatch=(Compare-Object $expected $actual).Count -eq 0}}finally{$connection.Dispose()}
        }.GetNewClosure()
    } $plan $selected $operationRoot $connectionString
    $attachedHash=[string](Invoke-NativePackageSql -Scalar -Query "USE [$escapedDatabase]; SELECT CONVERT(varchar(64),HASHBYTES('SHA2_256',Payload),2) FROM dbo.Evidence WHERE Label=N'preserved';")
    Assert-NativePackage ($attach.Status -eq 'ATTACHED' -and $attachedHash -eq $contentHash) 'Unabhängige Paketkopie ist online und FILESTREAM-Inhalt identisch'
    $journal=Get-Content -LiteralPath $attach.JournalPath -Raw|ConvertFrom-Json
    Assert-NativePackage ($journal.Status -eq 'COMPLETED' -and $journal.TargetCopyVerified -and $journal.PostconditionVerified) 'Attach-Journal belegt Kopie und Online-Postcondition'
    $completed=$true
}
finally{
    try{if($databaseCreated){$null=Invoke-NativePackageSql -Query "IF DB_ID(N'$databaseName') IS NOT NULL BEGIN ALTER DATABASE [$databaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$databaseName]; END"}}catch{Write-Warning "SQL-Cleanup fehlgeschlagen: $($_.Exception.Message)"}
    if(Test-Path -LiteralPath $testRoot){
        $resolved=[IO.Path]::GetFullPath($testRoot);$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if(-not $resolved.StartsWith("$tempParent\sql-lab-psr009-",[StringComparison]::OrdinalIgnoreCase)){throw 'DATABASE_PACKAGE_NATIVE_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if($mutexAcquired){$mutex.ReleaseMutex()};$mutex.Dispose()
}
if(-not $completed){throw 'DATABASE_PACKAGE_NATIVE_ACCEPTANCE_INCOMPLETE'}
Write-Host 'Native Windows-SQL-DATABASE_PACKAGE-/FILESTREAM-Akzeptanz erfolgreich.' -ForegroundColor Green
