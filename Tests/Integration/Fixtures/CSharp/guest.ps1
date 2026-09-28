# Runs only inside the newly created acceptance guest over VM-ID-bound PowerShell Direct.
param(
    [ValidateSet('Configure','Register','Probe','Diagnostics')][string]$Stage,
    [string]$Root,[string]$PackageSha256,[string]$ProbeSha256,[string]$SqlSha256,
    [Security.SecureString]$SqlPassword
)
$ErrorActionPreference='Stop'
if($Root -cnotmatch '^C:\\SqlServerLab\\CSharpAcceptance\\[a-f0-9]{32}$'){throw 'CSHARP_NATIVE_GUEST_ROOT'}
$runtimeHash='9c55c58694676ee64b0eed2cd6d8cbf58b9aa8288420acc66841e15ca0099c75d4af0182d23a641c2342e5a151a325df4a12fa0bde2e47c0fb7e9a33e7b09896'
foreach($definition in @(
    @{Name='extension.zip';Hash=$PackageSha256;Algorithm='SHA256'},
    @{Name='SqlServerLab.CSharpProbe.dll';Hash=$ProbeSha256;Algorithm='SHA256'},
    @{Name='probe.sql';Hash=$SqlSha256;Algorithm='SHA256'},
    @{Name='runtime.zip';Hash=$runtimeHash;Algorithm='SHA512'})){
    if($definition.Hash -cnotmatch '^[a-f0-9]{64}([a-f0-9]{64})?$'){throw 'CSHARP_NATIVE_GUEST_EXPECTED_HASH'}
    $path=Join-Path $Root $definition.Name
    if((Get-FileHash -LiteralPath $path -Algorithm $definition.Algorithm).Hash.ToLowerInvariant() -cne $definition.Hash){throw 'CSHARP_NATIVE_GUEST_HASH'}
}
$ancestor=$Root
while($ancestor){
    if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'CSHARP_NATIVE_GUEST_REPARSE'}
    $ancestor=[IO.Path]::GetDirectoryName($ancestor)
}
function New-CSharpGuestSqlInfoCollector {
    if(-not ('SqlServerLab.CSharpSqlInfoCollector' -as [type])){
        $source=@'
using System;
using System.Collections.Generic;
using System.Data.SqlClient;
namespace SqlServerLab {
    public sealed class CSharpSqlInfoCollector {
        private readonly object gate = new object();
        private readonly List<SqlError> entries = new List<SqlError>();
        public SqlInfoMessageEventHandler Handler { get; private set; }
        public CSharpSqlInfoCollector() { Handler = Capture; }
        private void Capture(object sender, SqlInfoMessageEventArgs args) {
            lock (gate) {
                foreach (SqlError error in args.Errors) {
                    if (entries.Count >= 8) break;
                    entries.Add(error);
                }
            }
        }
        public SqlError[] Snapshot() { lock (gate) { return entries.ToArray(); } }
    }
}
'@
        $references=@([Data.SqlClient.SqlError].Assembly.Location)
        $options=@{}
        if($PSVersionTable.PSEdition -eq 'Core'){$references+=@('System.Runtime.dll','System.Collections.dll','System.Threading.dll');$options.CompilerOptions='/nowarn:1701,0618'}
        Add-Type -TypeDefinition $source -ReferencedAssemblies $references @options -ErrorAction Stop
    }
    return [SqlServerLab.CSharpSqlInfoCollector]::new()
}
function Add-CSharpGuestSqlMessages {
    param($Buffer,$Errors)
    foreach($item in $Errors){
        if($Buffer.Count -ge 8){break}
        $message=[string]$item.Message;$procedure=[string]$item.Procedure
        $Buffer.Add([pscustomobject]@{Number=[int]$item.Number;State=[int]$item.State;Class=[int]$item.Class;LineNumber=[int]$item.LineNumber;
            Procedure=$procedure.Substring(0,[Math]::Min(128,$procedure.Length));Message=$message.Substring(0,[Math]::Min(2048,$message.Length))})
    }
}
function Save-CSharpGuestSqlFailure {
    param($Failure,$Info,[string]$Path)
    $errors=[Collections.Generic.List[object]]::new();$exception=$Failure.Exception
    for($depth=0;$exception -and $depth -lt 8;$depth++){
        if($exception -is [Data.SqlClient.SqlException]){Add-CSharpGuestSqlMessages $errors $exception.Errors;break}
        $exception=$exception.InnerException
    }
    [pscustomobject]@{Status='SQL_FAILURE';Errors=@($errors.ToArray());InfoMessages=@($Info.ToArray())}|ConvertTo-Json -Depth 5 -Compress|Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
}
function Read-CSharpGuestLogTail {
    param([string]$Path,[string]$Name)
    try{
        $cursor=[IO.Path]::GetFullPath($Path)
        if($cursor -notmatch '^[A-Za-z]:\\'){throw 'PATH'}
        while($cursor){if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'REPARSE'};$cursor=[IO.Path]::GetDirectoryName($cursor)}
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        try{
            $count=[int][Math]::Min(32768,$stream.Length);$offset=$stream.Length-$count;$null=$stream.Seek($offset,[IO.SeekOrigin]::Begin)
            $bytes=New-Object byte[] $count;$read=0
            while($read -lt $count){$n=$stream.Read($bytes,$read,$count-$read);if($n -eq 0){break};$read+=$n}
            return [pscustomobject]@{Name=$Name;Status='AVAILABLE';Offset=$offset;Bytes=$read;TailBase64=[Convert]::ToBase64String($bytes,0,$read)}
        }finally{$stream.Dispose()}
    }catch{return [pscustomobject]@{Name=$Name;Status='UNAVAILABLE'}}
}
function Get-CSharpGuestDiagnostics {
    param([string]$GuestRoot)
    $sql=[pscustomobject]@{Status='UNAVAILABLE'};$logs=@()
    try{
        $path=Join-Path $GuestRoot 'sql-failure.json'
        if((Get-Item -LiteralPath $path -ErrorAction Stop).Length -gt 262144){throw 'SIZE'}
        if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'REPARSE'}
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{
            if($stream.Length -gt 262144){throw 'SIZE'}
            $bytes=New-Object byte[] ([int]$stream.Length);$read=0
            while($read -lt $bytes.Length){$n=$stream.Read($bytes,$read,$bytes.Length-$read);if($n -eq 0){break};$read+=$n}
            $sql=[Text.Encoding]::UTF8.GetString($bytes,0,$read).TrimStart([char]0xFEFF)|ConvertFrom-Json -ErrorAction Stop
        }finally{$stream.Dispose()}
    }catch{}
    try{
        $instance=[string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop).MSSQLSERVER
        if($instance -cnotmatch '^MSSQL17\.[A-Za-z0-9_]+$'){throw 'INSTANCE'}
        $parameters=Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\'+$instance+'\MSSQLServer\Parameters') -ErrorAction Stop
        $paths=@($parameters.PSObject.Properties|Where-Object {$_.Name -match '^SQLArg\d+$' -and [string]$_.Value -like '-e*'}|ForEach-Object {([string]$_.Value).Substring(2).Trim('"')})
        if($paths.Count -ne 1 -or [IO.Path]::GetFileName($paths[0]) -ine 'ERRORLOG'){throw 'PATH'}
        $logRoot=[IO.Path]::GetDirectoryName($paths[0])
        $logs=@((Read-CSharpGuestLogTail $paths[0] 'ERRORLOG'),(Read-CSharpGuestLogTail (Join-Path $logRoot 'ExtensibilityLog/ExtLaunchErrorlog') 'ExtLaunchErrorlog'))
    }catch{$logs=@([pscustomobject]@{Name='INSTANCE_LOGS';Status='UNAVAILABLE'})}
    return [pscustomobject]@{Status='CSHARP_GUEST_DIAGNOSTICS';Sql=$sql;Logs=$logs}
}
if($Stage -eq 'Diagnostics'){return (Get-CSharpGuestDiagnostics $Root)}
$launchpad=Get-Service -Name MSSQLLaunchpad -ErrorAction Stop
if($launchpad.Status -ne 'Running'){throw 'CSHARP_NATIVE_LAUNCHPAD_NOT_RUNNING'}
Add-Type -AssemblyName System.Data
function New-CSharpNativeSqlConnectionString {
    # PowerShell adapts this IDictionary: use canonical SQL keywords, not CLR property names.
    $builder=New-Object Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source']='localhost';$builder['Initial Catalog']='master';$builder['Connect Timeout']=15
    $builder['Encrypt']=$true;$builder['TrustServerCertificate']=$true;$builder['Pooling']=$false
    return $builder.ConnectionString
}
$connection=New-Object Data.SqlClient.SqlConnection (New-CSharpNativeSqlConnectionString)
function New-CSharpNativeSqlCredential {
    param([Security.SecureString]$Password)
    $copy=$Password.Copy();$copy.MakeReadOnly()
    try{return [pscustomobject]@{Secret=$copy;Credential=[Data.SqlClient.SqlCredential]::new('sa',$copy)}}catch{$copy.Dispose();throw}
}
$login=New-CSharpNativeSqlCredential $SqlPassword
$connection.Credential=$login.Credential
function Invoke-ProbeSql([string]$Text){
    $command=$connection.CreateCommand();$command.CommandText=$Text;$command.CommandTimeout=180
    $info=[Collections.Generic.List[object]]::new()
    $collector=New-CSharpGuestSqlInfoCollector
    $handler=$collector.Handler
    $connection.add_InfoMessage($handler)
    try{return $command.ExecuteScalar()}
    catch{
        $failure=$_
        if($Stage -eq 'Probe'){try{Add-CSharpGuestSqlMessages $info ($collector.Snapshot());Save-CSharpGuestSqlFailure -Failure $failure -Info $info -Path (Join-Path $Root 'sql-failure.json')}catch{}}
        throw $failure
    }finally{try{$connection.remove_InfoMessage($handler)}catch{};$command.Dispose()}
}
try{
    $connection.Open()
    if([int](Invoke-ProbeSql "SELECT CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))") -ne 17){throw 'CSHARP_NATIVE_SQL_MAJOR'}
    $runtime=Join-Path $Root 'dotnet'
    if($Stage -eq 'Configure'){
        if(Test-Path -LiteralPath $runtime){throw 'CSHARP_NATIVE_RUNTIME_EXISTS'}
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        # This exact Microsoft archive was independently hash-checked above.
        [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $Root 'runtime.zip'),$runtime)
        if(-not(Test-Path -LiteralPath (Join-Path $runtime 'host/fxr/8.0.31/hostfxr.dll'))){throw 'CSHARP_NATIVE_RUNTIME_LAYOUT'}
        $null=& "$env:SystemRoot/System32/icacls.exe" $Root /grant '*S-1-15-2-1:(OI)(CI)RX' 'NT SERVICE\MSSQLSERVER:(OI)(CI)RX' /T /Q
        if($LASTEXITCODE -ne 0){throw 'CSHARP_NATIVE_GUEST_ACL'}
        [Environment]::SetEnvironmentVariable('DOTNET_ROOT',$runtime,'Machine')
        $null=Invoke-ProbeSql "EXEC sp_configure 'show advanced options',1; RECONFIGURE; EXEC sp_configure 'external scripts enabled',1; RECONFIGURE; EXEC sp_configure 'max server memory (MB)',12288; RECONFIGURE;"
        return 'CSHARP_NATIVE_CONFIGURED_RESTART_REQUIRED'
    }
    if([Environment]::GetEnvironmentVariable('DOTNET_ROOT','Machine') -cne $runtime){throw 'CSHARP_NATIVE_RUNTIME_BINDING'}
    if($Stage -eq 'Register'){
        if([int](Invoke-ProbeSql "SELECT COUNT(*) FROM sys.databases WHERE name=N'CSharpAcceptance'") -ne 0){throw 'CSHARP_NATIVE_DATABASE_EXISTS'}
        $null=Invoke-ProbeSql 'CREATE DATABASE [CSharpAcceptance]'
        $connection.ChangeDatabase('CSharpAcceptance')
        # Language-scoped .NET 8 host tracing uses stderr; no trace file or new write grant.
        $null=Invoke-ProbeSql "CREATE EXTERNAL LANGUAGE [dotnet] FROM (CONTENT=N'$Root\extension.zip',FILE_NAME='nativecsharpextension.dll',ENVIRONMENT_VARIABLES=N'{`"COREHOST_TRACE`":`"1`"}');"
        $null=Invoke-ProbeSql "CREATE EXTERNAL LIBRARY [SqlServerLab.CSharpProbe] FROM (CONTENT=N'$Root\SqlServerLab.CSharpProbe.dll') WITH (LANGUAGE=N'dotnet');"
        return 'CSHARP_NATIVE_REGISTERED'
    }
    $connection.ChangeDatabase('CSharpAcceptance')
    $result=Invoke-ProbeSql ([IO.File]::ReadAllText((Join-Path $Root 'probe.sql')))
    if([string]$result -cne 'CSHARP_SQL_ROUNDTRIP_OK'){throw 'CSHARP_NATIVE_PROBE_RESULT'}
    [pscustomobject]@{Status='CSHARP_SQL_ROUNDTRIP_OK';BootTime=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')}
}finally{$connection.Dispose();$login.Secret.Dispose()}
