#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Private/DiagnosticBundleReader.ps1')
. (Join-Path $repoRoot 'Private/SsisPackageDiagnostic.ps1')
. (Join-Path $repoRoot 'Providers/HyperV/HyperVSsisPackageDiagnostic.ps1')
. (Join-Path $repoRoot 'Public/Get-SqlServerLabSsisPackageDiagnostic.ps1')
$passed=0
function Check {param($Name,[bool]$Value) if(-not $Value){throw "FAIL: $Name"};$script:passed++;Write-Host "PASS: $Name"}
function FailureCode {param([scriptblock]$Action) try {& $Action|Out-Null;'NONE'} catch {$_.Exception.Message}}
function Hash {param([byte[]]$Bytes) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))}
function XmlBytes {param([string]$Mode='ok') [Text.Encoding]::UTF8.GetBytes("<DTS:Executable xmlns:DTS='www.microsoft.com/SqlServer/Dts' Mode='$Mode'><DTS:ConnectionManager DTS:CreationName='OLEDB'/><DTS:LogProvider DTS:CreationName='Microsoft.LogProviderSQLServer'/></DTS:Executable>")}
$directory=Join-Path $repoRoot ('.artifacts/test-runs/ssis-package-static-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $directory
try {
    $bytes=XmlBytes;$path=Join-Path $directory 'Synthetic.dtsx'
    [IO.File]::WriteAllBytes($path,$bytes)
    $artifact=Read-LabSsisDiagnosticPackage -Path $path -ExpectedSha256 (Hash $bytes)
    Check 'DTSX hashes the exact original bytes' ($artifact.PackageSha256 -ceq (Hash $bytes) -and [Convert]::ToBase64String($artifact.Bytes) -ceq [Convert]::ToBase64String($bytes))
    Check 'Hash mismatch fails before guest dispatch' ((FailureCode {Read-LabSsisDiagnosticPackage -Path $path -ExpectedSha256 ('0'*64)}) -ceq 'SSIS_DIAGNOSTIC_HASH_MISMATCH')
    Check 'Relative artifact path fails closed without leaking a path' ((FailureCode {Read-LabSsisDiagnosticPackage -Path 'Synthetic.dtsx' -ExpectedSha256 (Hash $bytes)}) -ceq 'SSIS_DIAGNOSTIC_ARTIFACT_UNREADABLE')
    $ispac=Join-Path $directory 'Synthetic.ispac'
    function Write-SyntheticIspac {param([switch]$Duplicate,[switch]$Excess)
        $zip=[IO.Compression.ZipFile]::Open($ispac,[IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach($name in @('Synthetic.dtsx')+$(if($Duplicate){@('synthetic.dtsx')}else{@()})) {
                $entry=$zip.CreateEntry($name);$output=$entry.Open()
                try {$payload=if($Excess){[byte[]]::new(8MB+1)}else{$bytes};$output.Write($payload,0,$payload.Length)} finally {$output.Dispose()}
            }
        } finally {$zip.Dispose()}
    }
    Write-SyntheticIspac
    $ispacHash=(Get-FileHash -LiteralPath $ispac).Hash
    $zipped=Read-LabSsisDiagnosticPackage -Path $ispac -ExpectedSha256 $ispacHash -PackageName Synthetic.dtsx -Ispac
    Check 'ISPAC receipt binds archive and exact package independently' ($zipped.ArtifactSha256 -ceq $ispacHash -and $zipped.PackageSha256 -ceq (Hash $bytes))
    Check 'Wrong package case fails instead of choosing another entry' ((FailureCode {Read-LabSsisDiagnosticPackage -Path $ispac -ExpectedSha256 $ispacHash -PackageName synthetic.dtsx -Ispac}) -ceq 'SSIS_DIAGNOSTIC_PACKAGE_ENTRY_INVALID')
    Remove-Item -LiteralPath $ispac;Write-SyntheticIspac -Duplicate
    Check 'Case-alias duplicate ZIP entries fail closed' ((FailureCode {Read-LabSsisDiagnosticPackage -Path $ispac -ExpectedSha256 (Get-FileHash $ispac).Hash -PackageName Synthetic.dtsx -Ispac}) -ceq 'SSIS_DIAGNOSTIC_PACKAGE_ENTRY_INVALID')
    Remove-Item -LiteralPath $ispac;Write-SyntheticIspac -Excess
    Check 'Compressed oversized package is rejected before decompression' ((FailureCode {Read-LabSsisDiagnosticPackage -Path $ispac -ExpectedSha256 (Get-FileHash $ispac).Hash -PackageName Synthetic.dtsx -Ispac}) -ceq 'SSIS_DIAGNOSTIC_SIZE_LIMIT')
    $id=[guid]'11111111-1111-1111-1111-111111111111'
    function Test-LabSsisWindowsHost {$mode -ne 'non-windows'}
    function Get-LabSsisPrerequisiteContext {
        param($RunId,$InstanceId,$StateRoot)
        $tracker.Context++
        if ($mode -eq 'target') {throw 'PRIVATE_TARGET'}
        [pscustomobject]@{Directory=$directory;Run=@{scopeId='synthetic'};Instance=@{vmName='synthetic';vmId='22222222-2222-2222-2222-222222222222'};ExpectedMajor=17;
            Fingerprint=$(if(($mode -eq 'pre-drift' -and $tracker.Context -gt 1) -or ($mode -eq 'post-drift' -and $tracker.Context -gt 2)){'changed'}else{'stable'})}
    }
    function Get-LabSecret {
        $tracker.Secrets++;if($mode -eq 'credential'){return $null}
        $tracker.Secret=[securestring]::new();$tracker.Secret.AppendChar('x');$tracker.Secret
    }
    function Invoke-HyperVPowerShellDirect {
        param($VMName,$ExpectedRunId,$ExpectedScopeId,$ExpectedVmId,$Credential,$ScriptBlock,$ArgumentList,$TimeoutSeconds,[switch]$NoRetry)
        $tracker.Calls++;$tracker.Bound=$ExpectedRunId -ceq $id.ToString() -and $ExpectedVmId -eq '22222222-2222-2222-2222-222222222222' -and $ExpectedScopeId -ceq 'synthetic'
        $tracker.NoRetry=[bool]$NoRetry;$tracker.Args=$ArgumentList
        if($mode -eq 'transport'){throw 'PRIVATE_TRANSPORT'}
        if($mode -eq 'extra'){return @(@{},@{})}
        [pscustomobject]@{ContractVersion='SqlServerLab.SsisPackageGuest/1.0';PackageSha256=$ArgumentList[1];Status='LOAD_FAILED';ReasonCode='PACKAGE_LOAD_FAILED';Events=@(@{Kind='ERROR';Code=-1073659899})}
    }
    foreach($mode in @('ok','target','credential','pre-drift','post-drift','transport','extra','non-windows')) {
        $tracker=@{Context=0;Calls=0;Secrets=0;Secret=$null}
        $value=$null;$errorCode=FailureCode {$script:value=Get-SqlServerLabSsisPackageDiagnostic -RunId $id -StateRoot $directory -PackagePath $path -ExpectedSha256 (Hash $bytes)}
        if($mode -eq 'ok') {
            Check 'Public diagnostic preserves load failure and exact transport binding' ($value.Status -ceq 'LOAD_FAILED' -and $tracker.Bound -and $tracker.NoRetry -and $tracker.Args[1] -ceq (Hash $bytes) -and $tracker.Args[2] -eq 17)
        } elseif($mode -in @('target','credential','pre-drift','non-windows')) {
            Check "$mode cannot dispatch" ($tracker.Calls -eq 0)
        } else {
            Check "$mode discards unconfirmed results" ($value.Status -ceq 'INCONCLUSIVE' -and $null -eq $value.Observation)
        }
        if($tracker.Secret) {Check 'Protected guest secret is disposed' ((FailureCode {$tracker.Secret.Copy()}) -match 'disposed')}
        Check 'No raw target or transport exception leaks' (($errorCode+($value|ConvertTo-Json -Depth 6)) -notmatch 'PRIVATE_')
    }
    $metadata=Get-Command Get-SqlServerLabSsisPackageDiagnostic
    Check 'Public API has separate mandatory ISPAC and DTSX inputs' ($metadata.ParameterSets.Count -eq 2 -and @($metadata.Parameters.Keys|Where-Object {$_ -in @('HostName','Port','GuestCredential','ScriptBlock')}).Count -eq 0)
    $guest=Get-LabSsisPackageDiagnosticGuest
    $badBytes=[Text.Encoding]::UTF8.GetBytes('<!DOCTYPE DTS:Executable [<!ENTITY e "synthetic">]><DTS:Executable xmlns:DTS="www.microsoft.com/SqlServer/Dts">&e;</DTS:Executable>')
    $bad=& $guest $badBytes (Hash $badBytes) 17
    Check 'Actual guest rejects DTD before assembly loading' ($bad.ReasonCode -ceq 'PACKAGE_XML_INVALID' -and $bad.LoadStatus -ceq 'NOT_ATTEMPTED')
    $bad=& $guest $bytes ('0'*64) 17
    Check 'Actual guest rechecks transferred package hash' ($bad.ReasonCode -ceq 'PACKAGE_HASH_MISMATCH' -and $bad.LoadStatus -ceq 'NOT_ATTEMPTED')

    # Testdouble nur an der Assemblyladegrenze; gesamter produktiver Gastcode und Event-Collector laufen.
    $assemblyPath=Join-Path $directory 'SyntheticSsis.dll'
    Add-Type -OutputAssembly $assemblyPath -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Reflection;
[assembly: AssemblyVersion("17.0.0.0")]
namespace Microsoft.SqlServer.Dts.Runtime {
    public class DtsObject {}
    public class DefaultEvents {
        public virtual bool OnError(DtsObject s,int c,string sub,string d,string h,int x,string id) { return false; }
        public virtual void OnWarning(DtsObject s,int c,string sub,string d,string h,int x,string id) {}
    }
    public class Info { public string CreationName; public Info(string name) { CreationName=name; } }
    public class Application {
        public Info[] ConnectionInfos { get { return new [] {new Info("OLEDB")}; } }
        public Info[] LogProviderInfos { get { return new [] {new Info("Microsoft.LogProviderSQLServer")}; } }
    }
    public class Error { public int ErrorCode=-1073659843; }
    public class Package : IDisposable {
        public static string LastXml;
        public static int Disposed;
        public List<Error> Errors = new List<Error>();
        public List<Info> Connections = new List<Info>();
        public List<Info> LogProviders = new List<Info>();
        public List<Info> Executables = new List<Info>();
        public void LoadFromXML(string xml, DefaultEvents events) {
            LastXml=xml;
            if (xml.Contains("Mode='fail'")) {events.OnError(thisObject,-1073659899,"PRIVATE","Password=PRIVATE","PRIVATE",0,"PRIVATE");Errors.Add(new Error());}
            if (xml.Contains("Mode='warn'")) {events.OnWarning(thisObject,42,"PRIVATE","Password=PRIVATE","PRIVATE",0,"PRIVATE");}
            if (xml.Contains("Mode='overflow'")) {for(int i=0;i<300;i++) events.OnError(thisObject,-1,"PRIVATE","PRIVATE","PRIVATE",0,"PRIVATE");}
            if (xml.Contains("Mode='throw'")) {throw new InvalidOperationException("PRIVATE");}
        }
        private DtsObject thisObject = new DtsObject();
        public void Execute() {throw new Exception("EXECUTE_MUST_NOT_RUN");}
        public void Validate() {throw new Exception("VALIDATE_MUST_NOT_RUN");}
        public void AcquireConnections() {throw new Exception("CONNECTION_MUST_NOT_OPEN");}
        public void Dispose() {Disposed++;}
    }
}
'@
    $assemblyStream=[IO.MemoryStream]::new([IO.File]::ReadAllBytes($assemblyPath))
    try {$testSsisAssembly=[Runtime.Loader.AssemblyLoadContext]::Default.LoadFromStream($assemblyStream)} finally {$assemblyStream.Dispose()}
    $source=$guest.ToString()
    $loadExpression='$assembly=[Reflection.Assembly]::Load("Microsoft.SqlServer.ManagedDTS, Version=$ExpectedMajor.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91")'
    Check 'Test runtime substitution targets exactly one assembly boundary' (($source.Split(@($loadExpression),[StringSplitOptions]::None)).Count -eq 2)
    $syntheticGuest=[scriptblock]::Create($source.Replace($loadExpression,'$assembly=$testSsisAssembly').Replace('$assembly.Location','$assemblyPath'))
    foreach($case in @('ok','fail','warn','overflow','throw')) {
        $payload=XmlBytes $case
        $result=& $syntheticGuest $payload (Hash $payload) 17
        Check "Actual guest $case reports runtime and same-process component inventory" ($result.Runtime.ProcessBitness -eq 64 -and $result.Runtime.AssemblyIdentity -match '17.0.0.0' -and $result.Inventory.Complete -and $result.Inventory.ConnectionManagers -contains 'OLEDB' -and $result.Inventory.LogProviders -contains 'Microsoft.LogProviderSQLServer')
        Check 'Exact original XML reaches LoadFromXML without serialization rewrite' ([Microsoft.SqlServer.Dts.Runtime.Package]::LastXml -ceq [Text.Encoding]::UTF8.GetString($payload))
        Check 'Serialized component identities are observed without package content' ($result.Serialized.ConnectionManagers -contains 'OLEDB' -and $result.Serialized.LogProviders -contains 'Microsoft.LogProviderSQLServer' -and ($result|ConvertTo-Json -Depth 8) -notmatch 'PRIVATE|Password|Mode=')
        switch($case) {
            ok {Check 'Successful load remains NOT_EXECUTED' ($result.Status -ceq 'OBSERVED' -and $result.ExecutionStatus -ceq 'NOT_EXECUTED')}
            fail {Check 'Returning LoadFromXML with errors is a load failure' ($result.Status -ceq 'LOAD_FAILED' -and $result.Events.Code -contains -1073659899 -and $result.Events.Code -contains -1073659843)}
            warn {Check 'Warnings retain their numeric code separately' ($result.Status -ceq 'OBSERVED' -and $result.Events[0].Kind -ceq 'WARNING' -and $result.Events[0].Code -eq 42)}
            overflow {Check 'Bounded collector truncation cannot be green' ($result.Status -ceq 'INCONCLUSIVE' -and $result.Events.Count -eq 256 -and $result.EventsTruncated)}
            throw {Check 'Load exception retains HRESULT without raw text' ($result.Status -ceq 'LOAD_FAILED' -and $null -ne $result.ExceptionHResult)}
        }
    }
    Check 'Every loaded package is disposed' ([Microsoft.SqlServer.Dts.Runtime.Package]::Disposed -eq 5)
    Write-Host "Ergebnis: $passed PASS, 0 FAIL (synthetisch; keine native SSIS-Abnahme)"
} catch {Write-Host "Diagnostic check failure: $($_.Exception.Message)";throw} finally {
    if(-not $directory.StartsWith((Join-Path $repoRoot '.artifacts/test-runs/'),[StringComparison]::OrdinalIgnoreCase)){throw 'STATIC_CLEANUP_ROOT_INVALID'}
    Remove-Item -LiteralPath $directory -Recurse -Force
}
