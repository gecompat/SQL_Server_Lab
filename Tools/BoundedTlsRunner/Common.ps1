#Requires -Version 7.5
# Fixed Windows TLS acceptance lease. No command or script comes from requests.
function Assert-BoundedTlsFields {
    param($Value,[string[]]$Names)
    $actual=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)}
    if($actual.Count -ne $Names.Count -or @($actual|Where-Object {$_ -cnotin $Names}).Count){throw 'BOUNDED_TLS_FIELDS_INVALID'}
}

function Get-BoundedTlsHash {
    param([string]$Path)
    $stream=[IO.File]::Open($Path,'Open','Read','Read')
    try{[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))}finally{$stream.Dispose()}
}

function Read-BoundedTlsJson {
    param([string]$Path,[int]$MaximumBytes=4194304,[string]$ExpectedOwnerSid)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'BOUNDED_TLS_FILE_INVALID'}
    $stream=[IO.File]::Open($Path,'Open','Read','Read')
    try{
        if($IsWindows){
            Initialize-BoundedTlsNativeSecurity
            if([SqlServerLabBoundedSecurity]::FinalPath($stream.SafeFileHandle) -ine [IO.Path]::GetFullPath($Path)){throw 'BOUNDED_TLS_OPENED_PATH_CHANGED'}
            if($ExpectedOwnerSid -and [IO.FileSystemAclExtensions]::GetAccessControl($stream).GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $ExpectedOwnerSid){throw 'BOUNDED_TLS_REQUEST_OWNER_CHANGED'}
        }
        if($stream.Length -lt 1 -or $stream.Length -gt $MaximumBytes){throw 'BOUNDED_TLS_FILE_SIZE_INVALID'}
        $bytes=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($bytes)
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $document=[Text.Json.JsonDocument]::Parse($text)
        try{Assert-BoundedTlsJsonElement $document.RootElement}finally{$document.Dispose()}
        $text|ConvertFrom-Json -Depth 30 -DateKind String
    }finally{$stream.Dispose()}
}

function Assert-BoundedTlsJsonElement {
    param([Text.Json.JsonElement]$Element)
    if($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object){
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($p in $Element.EnumerateObject()){
            if(-not $seen.Add($p.Name)){throw 'BOUNDED_TLS_DUPLICATE_JSON_FIELD'}
            Assert-BoundedTlsJsonElement $p.Value
        }
    }elseif($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array){foreach($value in $Element.EnumerateArray()){Assert-BoundedTlsJsonElement $value}}
}

function Read-BoundedTlsPinnedJson {
    param([string]$Path,[string]$ExpectedSha256,[int]$MaximumBytes=4194304)
    # Hash and parse one immutable byte snapshot, never a second path lookup.
    $stream=[IO.File]::Open($Path,'Open','Read','Read')
    try{
        if($stream.Length -lt 1 -or $stream.Length -gt $MaximumBytes){throw 'BOUNDED_TLS_FILE_SIZE_INVALID'}
        $bytes=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($bytes)
        if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $ExpectedSha256){throw 'BOUNDED_TLS_APPROVED_BYTES_CHANGED'}
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $document=[Text.Json.JsonDocument]::Parse($text)
        try{Assert-BoundedTlsJsonElement $document.RootElement}finally{$document.Dispose()}
        $text|ConvertFrom-Json -Depth 30 -DateKind String
    }finally{$stream.Dispose()}
}

function Assert-BoundedTlsRequest {
    param($Request,[string]$RunnerId,$State)
    Assert-BoundedTlsFields $Request @('ContractVersion','RunnerId','RequestId','Operation')
    $id=[guid]::Empty
    if($Request.ContractVersion -cne 'SqlServerLab.BoundedTlsRequest/0.1' -or $Request.RunnerId -cne $RunnerId -or
        $Request.Operation -cnotin @('Ready','Run','Close') -or -not [guid]::TryParseExact($Request.RequestId,'D',[ref]$id) -or
        $id -eq [guid]::Empty -or $id.ToString('D') -cne $Request.RequestId){throw 'BOUNDED_TLS_REQUEST_INVALID'}
    if($Request.RequestId -cin @($State.ConsumedRequestIds)){throw 'BOUNDED_TLS_REQUEST_REPLAY'}
    if(@($State.ConsumedRequestIds).Count -ge 64){throw 'BOUNDED_TLS_CONTROL_BUDGET_EXHAUSTED'}
}

function Write-BoundedTlsJson {
    param([string]$Path,$Value,[switch]$Replace)
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 30 -Compress))
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $stream=[IO.File]::Open($temp,'CreateNew','Write','None')
        try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
        [IO.File]::Move($temp,$Path,[bool]$Replace)
    }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}

function Assert-BoundedTlsAdministrator {
    if(-not $IsWindows -or -not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        throw 'BOUNDED_TLS_ELEVATED_INSTALLATION_REQUIRED'
    }
}

function Get-BoundedTlsRoot {
    param([string]$RunnerId)
    $id=[guid]::Empty
    if(-not [guid]::TryParseExact($RunnerId,'D',[ref]$id) -or $id -eq [guid]::Empty){throw 'BOUNDED_TLS_ID_INVALID'}
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ('SQL_Server_Lab_BoundedTls/'+$RunnerId)
}

function Assert-BoundedTlsLocalPath {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if($full.StartsWith('\\') -or $full.IndexOfAny([char[]]'&|<>^%!') -ge 0 -or [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full)).DriveType -ne 'Fixed'){
        throw 'BOUNDED_TLS_LOCAL_PATH_REQUIRED'
    }
    $current=[IO.DirectoryInfo]::new($full)
    while($current){if($current.Exists -and ($current.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'BOUNDED_TLS_REPARSE_REJECTED'};$current=$current.Parent}
    $full
}

function Assert-BoundedTlsSourceRow {
    param($Row,[string]$Root)
    Assert-BoundedTlsFields $Row @('RelativePath','Sha256')
    if($Row.RelativePath -isnot [string] -or $Row.RelativePath -match '\.\.|[:\\]|(?i)^\.git(?:/|$)' -or $Row.RelativePath.StartsWith('/') -or
        $Row.Sha256 -cnotmatch '\A[0-9A-F]{64}\z'){throw 'BOUNDED_TLS_SOURCE_ROW_INVALID'}
    $path=[IO.Path]::GetFullPath((Join-Path $Root $Row.RelativePath))
    if(-not $path.StartsWith($Root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'BOUNDED_TLS_SOURCE_ESCAPE'}
    $path
}

function Assert-BoundedTlsPlan {
    param($Plan,[switch]$Installed)
    $names=@('ContractVersion','RunnerId','ActorSid','StageSourceRoot','InstallRoot','DataRoot','StateRoot','ControllerId','LocationId','CandidateId','AuthorityRef','ClientRef',
        'PackageFamilyName','AppId','Binaries','Sources','MaximumAttempts','LeaseMinutes','AttemptMinutes')
    if($Installed){$names+=@('InstalledAtUtc','ExpiresUtc','TaskName')}
    Assert-BoundedTlsFields $Plan $names
    foreach($name in @('MaximumAttempts','LeaseMinutes','AttemptMinutes')){
        if($Plan.$name -isnot [int] -and $Plan.$name -isnot [long]){throw 'BOUNDED_TLS_NUMERIC_TYPE_INVALID'}
    }
    if($Plan.ContractVersion -cne 'SqlServerLab.BoundedTlsRunner/0.1' -or $Plan.ActorSid -cnotmatch '\AS-1-(?:5-21|12-1)(?:-[0-9]+){4}\z' -or
        $Plan.MaximumAttempts -ne 2 -or $Plan.LeaseMinutes -ne 120 -or $Plan.AttemptMinutes -ne 45 -or
        $Plan.PackageFamilyName -cnotmatch '\A[A-Za-z0-9.]+_[A-Za-z0-9]+\z' -or $Plan.AppId -cnotmatch '\A[A-Za-z0-9.]+\z'){
        throw 'BOUNDED_TLS_PLAN_INVALID'
    }
    if($Plan.InstallRoot -cne (Get-BoundedTlsRoot $Plan.RunnerId) -or $Plan.StateRoot -cne (Join-Path $Plan.DataRoot 'State')){throw 'BOUNDED_TLS_ROOT_INVALID'}
    foreach($name in @('ControllerId','LocationId','CandidateId','AuthorityRef','ClientRef')){
        $id=[guid]::Empty;if(-not [guid]::TryParseExact($Plan.$name,'D',[ref]$id) -or $id -eq [guid]::Empty){throw 'BOUNDED_TLS_REFERENCE_INVALID'}
    }
    $null=Assert-BoundedTlsLocalPath $Plan.InstallRoot
    $null=Assert-BoundedTlsLocalPath $Plan.DataRoot
    $null=Assert-BoundedTlsLocalPath $Plan.StageSourceRoot
    Assert-BoundedTlsFields $Plan.Binaries @('PowerShell','Git','Sqlcmd')
    foreach($name in @('PowerShell','Git','Sqlcmd')){
        $binary=$Plan.Binaries.$name;Assert-BoundedTlsFields $binary @('Path','Sha256')
        $path=Assert-BoundedTlsLocalPath $binary.Path
        $program=[Environment]::GetFolderPath('ProgramFiles').TrimEnd('\')+'\'
        if(-not $path.StartsWith($program,[StringComparison]::OrdinalIgnoreCase) -or $binary.Sha256 -cnotmatch '\A[0-9A-F]{64}\z'){
            throw 'BOUNDED_TLS_PROTECTED_BINARY_REQUIRED'
        }
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if(@($Plan.Sources).Count -lt 1 -or @($Plan.Sources).Count -gt 10000){throw 'BOUNDED_TLS_SOURCE_COUNT_INVALID'}
    foreach($row in $Plan.Sources){$null=Assert-BoundedTlsSourceRow $row $Plan.StageSourceRoot;if(-not $seen.Add($row.RelativePath)){throw 'BOUNDED_TLS_DUPLICATE_SOURCE'}}
    foreach($required in @('SqlServerLab.psd1','SqlServerLab.psm1','Tools/BoundedTlsRunner/Common.ps1','Tools/BoundedTlsRunner/Invoke.ps1',
        'Tests/Integration/Invoke-AuthenticatedTlsWindowsPublicAcceptance.ps1','Tests/Integration/Invoke-AuthenticatedTlsWindowsPublicCleanupAudit.ps1')){
        if(-not $seen.Contains($required)){throw 'BOUNDED_TLS_REQUIRED_SOURCE_MISSING'}
    }
    if($Installed){
        if($Plan.TaskName -cne ('SQL_Server_Lab-BoundedTls-'+$Plan.RunnerId)){throw 'BOUNDED_TLS_TASK_BINDING_INVALID'}
        $start=[datetimeoffset]::ParseExact($Plan.InstalledAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture)
        $end=[datetimeoffset]::ParseExact($Plan.ExpiresUtc,'o',[Globalization.CultureInfo]::InvariantCulture)
        if($end -ne $start.AddMinutes(120)){throw 'BOUNDED_TLS_LEASE_INVALID'}
    }
}

function Get-BoundedTlsDecision {
    param($Plan,$State,[string]$Operation,[datetimeoffset]$Now=[datetimeoffset]::UtcNow)
    if($Operation -cnotin @('Ready','Run','Close')){throw 'BOUNDED_TLS_OPERATION_REJECTED'}
    if($State.Status -cnotin @('INSTALLED','READY','BLOCKED','FAILED_CLEANED','RUNNING','CLOSED','PASS','RECOVERY_REQUIRED') -or
        ($State.Attempts -isnot [int] -and $State.Attempts -isnot [long]) -or $State.Attempts -lt 0 -or $State.Attempts -gt 2){throw 'BOUNDED_TLS_STATE_INVALID'}
    if($State.Status -ceq 'RUNNING'){return 'RECOVERY'}
    if($State.Status -cin @('CLOSED','PASS','RECOVERY_REQUIRED')){return 'CLOSED'}
    if($Operation -ceq 'Close' -or $Now -ge [datetimeoffset]::Parse($Plan.ExpiresUtc)){return 'CLOSE'}
    if($Operation -ceq 'Ready'){return 'READY'}
    if($State.Attempts -ge $Plan.MaximumAttempts){return 'EXHAUSTED'}
    'RUN'
}

function Set-BoundedTlsAccess {
    param([string]$Path,[string]$ActorSid,[switch]$Directory,[switch]$Requests)
    $admin=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl=if($Directory){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
    $acl.SetOwner($admin);$acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @('S-1-5-18','S-1-5-32-544',$ActorSid)){
        $rights=if($sid -ceq $ActorSid){if($Requests){[Security.AccessControl.FileSystemRights]'ReadAndExecute, Write'}else{[Security.AccessControl.FileSystemRights]::ReadAndExecute}}else{[Security.AccessControl.FileSystemRights]::FullControl}
        $rule=if($Directory){[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)}
        else{[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,[Security.AccessControl.AccessControlType]::Allow)}
        $null=$acl.AddAccessRule($rule)
    }
    if($Directory -and $Requests){
        # Permit atomic replacement of request FILES, never deletion/replacement
        # of the administrator-owned request directory itself.
        $null=$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($ActorSid),
            [Security.AccessControl.FileSystemRights]::Modify,[Security.AccessControl.InheritanceFlags]::ObjectInherit,
            [Security.AccessControl.PropagationFlags]::InheritOnly,[Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-BoundedTlsAccess {
    param([string]$Path,[string]$ActorSid)
    $acl=Get-Acl -LiteralPath $Path
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544' -or -not $acl.AreAccessRulesProtected){throw 'BOUNDED_TLS_PROTECTED_OWNER_REQUIRED'}
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if($rules.Count -ne 3){throw 'BOUNDED_TLS_PROTECTED_ACL_REQUIRED'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($rule in $rules){
        $sid=$rule.IdentityReference.Value
        $wanted=if($sid -ceq $ActorSid){[Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize'}else{[Security.AccessControl.FileSystemRights]::FullControl}
        if($sid -cnotin @('S-1-5-18','S-1-5-32-544',$ActorSid) -or $rule.IsInherited -or $rule.AccessControlType -ne 'Allow' -or
            $rule.FileSystemRights -ne $wanted -or -not $seen.Add($sid)){throw 'BOUNDED_TLS_PROTECTED_ACL_REQUIRED'}
    }
}

function Initialize-BoundedTlsNativeSecurity {
    if('SqlServerLabBoundedSecurity' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class SqlServerLabBoundedSecurity {
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string s,uint r,out IntPtr p,out uint n);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetSecurityDescriptorSacl(IntPtr p,out bool present,out IntPtr sacl,out bool def);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern uint SetNamedSecurityInfo(string n,int t,uint i,IntPtr o,IntPtr g,IntPtr d,IntPtr s);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandle(SafeFileHandle h,StringBuilder p,uint n,uint f);
 public static string FinalPath(SafeFileHandle h) {
  var b=new StringBuilder(32768);uint n=GetFinalPathNameByHandle(h,b,32768,0);
  if(n==0||n>=32768)throw new InvalidOperationException("BOUNDED_TLS_FINAL_PATH_UNAVAILABLE");
  string s=b.ToString();return s.StartsWith(@"\\?\")?s.Substring(4):s;
 }
 public static void Label(string path,bool high) {
  IntPtr sd=IntPtr.Zero;uint n;bool present,def;IntPtr sacl;
  if(!ConvertStringSecurityDescriptorToSecurityDescriptor(high?"S:(ML;OICI;NW;;;HI)":"S:(ML;OICI;NW;;;ME)",1,out sd,out n))throw new InvalidOperationException("BOUNDED_TLS_LABEL_DESCRIPTOR_FAILED");
  try {if(!GetSecurityDescriptorSacl(sd,out present,out sacl,out def)||!present)throw new InvalidOperationException("BOUNDED_TLS_LABEL_MISSING");
   if(SetNamedSecurityInfo(path,1,0x10,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,sacl)!=0)throw new InvalidOperationException("BOUNDED_TLS_LABEL_WRITE_FAILED");
  }finally{LocalFree(sd);}
 }
}
'@
}

function Set-BoundedTlsLabel {
    param([string]$Path,[switch]$Medium)
    Initialize-BoundedTlsNativeSecurity
    [SqlServerLabBoundedSecurity]::Label($Path,-not [bool]$Medium)
}

function Get-BoundedTlsTaskSddl {
    param([string]$ActorSid)
    if($ActorSid -cnotmatch '\AS-1-(?:5-21|12-1)(?:-[0-9]+){4}\z'){throw 'BOUNDED_TLS_ACTOR_INVALID'}
    'O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGX;;;'+$ActorSid+')'
}

function Assert-BoundedTlsBinaryPins {
    param($Plan)
    foreach($name in @('PowerShell','Git','Sqlcmd')){
        if((Get-BoundedTlsHash $Plan.Binaries.$name.Path) -cne $Plan.Binaries.$name.Sha256){throw 'BOUNDED_TLS_BINARY_CHANGED'}
    }
}

function Set-BoundedTlsProcessEnvironment {
    param($Plan)
    foreach($name in @('DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','DOTNET_ROOT','DOTNET_ROOT_X64','CORECLR_ENABLE_PROFILING','CORECLR_PROFILER','CORECLR_PROFILER_PATH','CORECLR_PROFILER_PATH_32','CORECLR_PROFILER_PATH_64','COR_ENABLE_PROFILING','COR_PROFILER','COR_PROFILER_PATH','COR_PROFILER_PATH_32','COR_PROFILER_PATH_64')){
        [Environment]::SetEnvironmentVariable($name,$null,'Process')
    }
    foreach($entry in @(Get-ChildItem Env:|Where-Object Name -like 'GIT_*')){[Environment]::SetEnvironmentVariable($entry.Name,$null,'Process')}
    $env:GIT_CONFIG_NOSYSTEM='1';$env:GIT_CONFIG_GLOBAL='NUL';$env:GIT_CONFIG_SYSTEM='NUL';$env:DOTNET_EnableDiagnostics='0'
    $windows=[Environment]::GetFolderPath('Windows')
    $env:PATH=(@((Split-Path $Plan.Binaries.Git.Path -Parent),(Split-Path $Plan.Binaries.Sqlcmd.Path -Parent),(Split-Path $Plan.Binaries.PowerShell.Path -Parent),
        (Join-Path $windows 'System32'),$windows,(Join-Path $windows 'System32/Wbem')) -join ';')
    $env:PSModulePath=(@((Join-Path (Split-Path $Plan.Binaries.PowerShell.Path -Parent) 'Modules'),(Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/Modules'),
        (Join-Path $windows 'System32/WindowsPowerShell/v1.0/Modules')) -join ';')
}
