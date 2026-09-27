# Runs only inside the newly created acceptance guest over VM-ID-bound PowerShell Direct.
param(
    [ValidateSet('Configure','Register','Probe')][string]$Stage,
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
$launchpad=Get-Service -Name MSSQLLaunchpad -ErrorAction Stop
if($launchpad.Status -ne 'Running'){throw 'CSHARP_NATIVE_LAUNCHPAD_NOT_RUNNING'}
Add-Type -AssemblyName System.Data
$builder=New-Object Data.SqlClient.SqlConnectionStringBuilder
$builder.DataSource='localhost';$builder.InitialCatalog='master';$builder.ConnectTimeout=15
$builder.Encrypt=$true;$builder.TrustServerCertificate=$true;$builder.Pooling=$false
$connection=New-Object Data.SqlClient.SqlConnection $builder.ConnectionString
function New-CSharpNativeSqlCredential {
    param([Security.SecureString]$Password)
    $copy=$Password.Copy();$copy.MakeReadOnly()
    try{return [pscustomobject]@{Secret=$copy;Credential=[Data.SqlClient.SqlCredential]::new('sa',$copy)}}catch{$copy.Dispose();throw}
}
$login=New-CSharpNativeSqlCredential $SqlPassword
$connection.Credential=$login.Credential
function Invoke-ProbeSql([string]$Text){
    $command=$connection.CreateCommand();$command.CommandText=$Text;$command.CommandTimeout=180
    try{return $command.ExecuteScalar()}finally{$command.Dispose()}
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
        $null=Invoke-ProbeSql "CREATE EXTERNAL LANGUAGE [dotnet] FROM (CONTENT=N'$Root\extension.zip',FILE_NAME='nativecsharpextension.dll');"
        $null=Invoke-ProbeSql "CREATE EXTERNAL LIBRARY [SqlServerLab.CSharpProbe] FROM (CONTENT=N'$Root\SqlServerLab.CSharpProbe.dll') WITH (LANGUAGE=N'dotnet');"
        return 'CSHARP_NATIVE_REGISTERED'
    }
    $connection.ChangeDatabase('CSharpAcceptance')
    $result=Invoke-ProbeSql ([IO.File]::ReadAllText((Join-Path $Root 'probe.sql')))
    if([string]$result -cne 'CSHARP_SQL_ROUNDTRIP_OK'){throw 'CSHARP_NATIVE_PROBE_RESULT'}
    [pscustomobject]@{Status='CSHARP_SQL_ROUNDTRIP_OK';BootTime=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')}
}finally{$connection.Dispose();$login.Secret.Dispose()}
