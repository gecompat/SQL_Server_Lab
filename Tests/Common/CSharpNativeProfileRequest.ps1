# Internal request transport. Dot-sourcing performs no filesystem or runtime action.
. (Join-Path $PSScriptRoot 'CSharpNativeAcceptance.ps1')

function Assert-CSharpNativeRequestDirectory {
    param([Parameter(Mandatory)][string]$Path,[switch]$AncestorsOnly)
    Assert-CSharpNativeLocalPath $Path
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if(-not $item.PSIsContainer){throw 'CSHARP_NATIVE_REQUEST_DIRECTORY'}
        $acl=Get-Acl -LiteralPath $cursor -ErrorAction Stop
        $raw=[Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(),0)
        $descriptor=[pscustomobject]@{
            Owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value;DaclPresent=($null -ne $raw.DiscretionaryAcl)
            Rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|ForEach-Object {
                [pscustomobject]@{Sid=$_.IdentityReference.Value;Rights=[long]$_.FileSystemRights;Allow=($_.AccessControlType -eq 'Allow');InheritOnly=[bool]($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)}
            })
        }
        Assert-CSharpNativeProfileAcl $descriptor -Ancestor:($AncestorsOnly -or $cursor -ine $Path)
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}

function Get-CSharpNativeRequestVolumeRoot {
    if(-not $IsWindows){throw 'CSHARP_NATIVE_WINDOWS_REQUIRED'}
    $common=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if([string]::IsNullOrWhiteSpace($common)){throw 'CSHARP_NATIVE_REQUEST_VOLUME'}
    $root=[IO.Path]::GetPathRoot($common)
    if($root -cnotmatch '^[A-Za-z]:\\$'){throw 'CSHARP_NATIVE_REQUEST_VOLUME'}
    Assert-CSharpNativeRequestDirectory -Path $root -AncestorsOnly
    return $root
}

function Read-CSharpNativeRequestBytes {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedHash)
    if($ExpectedHash -cnotmatch '^[a-f0-9]{64}$'){throw 'CSHARP_NATIVE_REQUEST_HASH_FORMAT'}
    $stream=$null;$sha=$null
    try{
        Assert-CSharpNativeLocalPath $Path
        # Staging is untrusted data; authenticity comes from the caller-approved hash.
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($stream.Length -le 0 -or $stream.Length -gt 32768){throw 'CSHARP_NATIVE_REQUEST_SIZE'}
        $bytes=[byte[]]::new([int]$stream.Length);$offset=0
        while($offset -lt $bytes.Length){$count=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($count -le 0){throw 'CSHARP_NATIVE_REQUEST_READ'};$offset+=$count}
        if($stream.ReadByte() -ne -1){throw 'CSHARP_NATIVE_REQUEST_SIZE'}
        $sha=[Security.Cryptography.SHA256]::Create()
        $hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
        if($hash -cne $ExpectedHash){throw 'CSHARP_NATIVE_REQUEST_HASH'}
        return [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    }catch{
        $code=Get-CSharpNativeFailureCode $_
        if($code -eq 'CSHARP_NATIVE_UNCLASSIFIED_FAILURE'){$code='CSHARP_NATIVE_REQUEST_READ'}
        throw $code
    }finally{if($sha){$sha.Dispose()};if($stream){$stream.Dispose()}}
}

function ConvertFrom-CSharpNativeRequest {
    param([Parameter(Mandatory)][string]$Json,[Parameter(Mandatory)][string]$ProfileName,[Parameter(Mandatory)][string]$Commit,[DateTimeOffset]$UtcNow=[DateTimeOffset]::UtcNow)
    $document=$null
    try{
        if([Text.Encoding]::UTF8.GetByteCount($Json) -gt 32768){throw 'CSHARP_NATIVE_REQUEST_SIZE'}
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=4
        $document=[Text.Json.JsonDocument]::Parse($Json,$options)
        if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'CSHARP_NATIVE_REQUEST_SCHEMA'}
        $expected=@('SchemaVersion','Purpose','ProfileName','Nonce','MainCommit','ExpiresUtc','Profile')
        $values=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach($property in $document.RootElement.EnumerateObject()){
            if($property.Name -cnotin $expected -or $values.ContainsKey($property.Name)){throw 'CSHARP_NATIVE_REQUEST_SCHEMA'}
            if($property.Name -ceq 'Profile'){
                if($property.Value.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'CSHARP_NATIVE_REQUEST_SCHEMA'}
                $values.Add($property.Name,$property.Value.GetRawText())
            }else{
                if($property.Value.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'CSHARP_NATIVE_REQUEST_SCHEMA'}
                $value=$property.Value.GetString()
                if([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 128){throw 'CSHARP_NATIVE_REQUEST_SCHEMA'}
                $values.Add($property.Name,$value)
            }
        }
        if($values.Count -ne $expected.Count -or $values['SchemaVersion'] -cne '1' -or $values['Purpose'] -cne 'CSharpNativeAcceptance' -or
            $ProfileName -cne 'csharp-sql2025' -or $values['ProfileName'] -cne $ProfileName -or
            $Commit -cnotmatch '^[a-f0-9]{40}$' -or $values['MainCommit'] -cne $Commit){throw 'CSHARP_NATIVE_REQUEST_BINDING'}
        $nonce=[guid]::Empty
        if(-not [guid]::TryParseExact($values['Nonce'],'D',[ref]$nonce) -or $nonce -eq [guid]::Empty -or $values['Nonce'] -cne $nonce.ToString('D')){throw 'CSHARP_NATIVE_REQUEST_NONCE'}
        $expires=[DateTimeOffset]::MinValue
        if(-not [DateTimeOffset]::TryParseExact($values['ExpiresUtc'],"yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$expires) -or
            $expires -le $UtcNow -or $expires -gt $UtcNow.AddHours(4)){throw 'CSHARP_NATIVE_REQUEST_EXPIRY'}
        $null=ConvertFrom-CSharpNativeProfile $values['Profile']
        [pscustomobject]@{ProfileJson=$values['Profile'];ExpiresUtc=$expires;Nonce=$values['Nonce']}
    }catch{
        $code=Get-CSharpNativeFailureCode $_
        if($code -eq 'CSHARP_NATIVE_UNCLASSIFIED_FAILURE'){$code='CSHARP_NATIVE_REQUEST_SCHEMA'}
        throw $code
    }finally{if($document){$document.Dispose()}}
}

function New-CSharpNativeTemporaryDirectory {
    param([Parameter(Mandatory)][string]$Path,[switch]$CurrentIdentityRead)
    if(-not ('SqlServerLab.CSharpNativeDirectory' -as [type])){
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace SqlServerLab {
    public static class CSharpNativeDirectory {
        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes { public int Length; public IntPtr SecurityDescriptor; [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectoryW(string path, ref SecurityAttributes attributes);
        public static int Create(string path, byte[] descriptor) {
            IntPtr memory=Marshal.AllocHGlobal(descriptor.Length);
            try {
                Marshal.Copy(descriptor,0,memory,descriptor.Length);
                var attributes=new SecurityAttributes {Length=Marshal.SizeOf<SecurityAttributes>(), SecurityDescriptor=memory, InheritHandle=false};
                if(CreateDirectoryW(path,ref attributes)) return 0;
                int error=Marshal.GetLastWin32Error(); return error == 0 ? -1 : error;
            } finally {Marshal.FreeHGlobal(memory);}
        }
    }
}
"@
    }
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)')
    if($CurrentIdentityRead){
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try{$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User,[Security.AccessControl.FileSystemRights]::ReadAndExecute,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))}finally{$identity.Dispose()}
    }
    $code=[SqlServerLab.CSharpNativeDirectory]::Create($Path,$acl.GetSecurityDescriptorBinaryForm())
    if($code -eq 183){throw 'CSHARP_NATIVE_PROFILE_EXISTS'}
    if($code -ne 0){throw 'CSHARP_NATIVE_PROFILE_CREATE'}
}

function Write-CSharpNativeTemporaryProfile {
    param([Parameter(Mandatory)]$Owned,[Parameter(Mandatory)][string]$Json,[switch]$CurrentIdentityRead)
    Assert-CSharpNativeRequestDirectory $Owned.Root
    $acl=[Security.AccessControl.FileSecurity]::new()
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;BA)(A;;FA;;;SY)')
    if($CurrentIdentityRead){
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try{$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User,[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow))}finally{$identity.Dispose()}
    }
    $stream=$null
    try{
        $stream=[IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($Owned.File),[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::None,$acl)
        $Owned.FileOwned=$true
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Json)
        $stream.Write($bytes,0,$bytes.Length)
    }finally{if($stream){$stream.Dispose()}}
}

function Remove-CSharpNativeTemporaryProfile {
    param([Parameter(Mandatory)]$Owned)
    if(-not $Owned.DirectoryOwned -or [IO.Path]::GetDirectoryName($Owned.Root) -ine $Owned.VolumeRoot -or
        [IO.Path]::GetFileName($Owned.Root) -cnotmatch '^SqlServerLab-CSharpProfile-[a-f0-9]{32}$' -or
        $Owned.File -cne (Join-Path $Owned.Root 'csharp-sql2025.json')){throw 'CSHARP_NATIVE_PROFILE_CLEANUP_BINDING'}
    Assert-CSharpNativeRequestDirectory $Owned.Root
    if($Owned.FileOwned){
        if([IO.File]::Exists($Owned.File)){Assert-CSharpNativeProfilePath $Owned.File}
        [IO.File]::Delete($Owned.File)
    }
    [IO.Directory]::Delete($Owned.Root,$false)
}

function New-CSharpNativeRecoveryRecordPath {
    $base=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if([string]::IsNullOrWhiteSpace($base)){throw 'CSHARP_NATIVE_PROFILE_RECORD_LOCATION'}
    $scope=Join-Path (Join-Path $base 'SqlServerLab/CSharpRequestRecovery') ([guid]::NewGuid().ToString('N'))
    Assert-CSharpNativeLocalPath $scope
    $null=[IO.Directory]::CreateDirectory($scope)
    Assert-CSharpNativeLocalPath $scope
    return (Join-Path $scope 'profile-recovery.jsonl')
}

function Write-CSharpNativeRecoveryRecord {
    param([Parameter(Mandatory)]$Stream,[Parameter(Mandatory)]$Owned,[Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)][ValidateSet('PREPARED','CREATED','FILE_CREATED','CLEANED','NOT_CREATED','CLEANUP_FAILED')][string]$Status,
        [AllowNull()][string]$PrimaryFailure,[AllowNull()][string]$CleanupFailure,[AllowNull()][string]$RunCleanupFailure)
    try{
        $entry=[ordered]@{Contract='CSharpNativeProfileRecovery/1';OperationId=$Owned.OperationId;Nonce=$Binding.Nonce;MainCommit=$Binding.MainCommit;RequestSha256=$Binding.RequestSha256;
            Root=$Owned.Root;File=$Owned.File;Status=$Status;DirectoryOwned=$Owned.DirectoryOwned;FileOwned=$Owned.FileOwned;
            PrimaryFailure=$PrimaryFailure;CleanupFailure=$CleanupFailure;RunCleanupFailure=$RunCleanupFailure;Utc=[DateTimeOffset]::UtcNow.ToString('o')}
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($entry|ConvertTo-Json -Compress)+"`n")
        $Stream.Write($bytes,0,$bytes.Length);$Stream.Flush($true)
    }catch{throw 'CSHARP_NATIVE_PROFILE_RECORD_FAILED'}
}

function Get-CSharpNativeRequestFailureDiagnostic {
    param([Parameter(Mandatory)]$ErrorRecord)
    $main=Get-CSharpNativeFailureDiagnostic $ErrorRecord
    $extra=@{}
    foreach($key in @('ProfileCleanupFailure','RecoveryRecordFailure')){
        $value=[string]$ErrorRecord.Exception.Data[$key]
        if($value -and ($value.Length -gt 128 -or $value -cnotmatch '^CSHARP_NATIVE_[A-Z_]+$')){$value='CSHARP_NATIVE_UNCLASSIFIED_FAILURE'}
        $extra[$key]=$value
    }
    [pscustomobject]@{PrimaryFailure=$main.PrimaryFailure;CleanupFailure=$main.CleanupFailure;EvidenceFailure=$main.EvidenceFailure;ProfileCleanupFailure=$extra.ProfileCleanupFailure;RecoveryRecordFailure=$extra.RecoveryRecordFailure;
        RecoveryRequired=($main.RecoveryRequired -or [bool]$extra.ProfileCleanupFailure -or [bool]$extra.RecoveryRecordFailure);
        ReasonCode=$(if($extra.ProfileCleanupFailure -or $extra.RecoveryRecordFailure){'CSHARP_NATIVE_PROFILE_RECOVERY_REQUIRED'}else{$main.ReasonCode})}
}

function Invoke-CSharpNativeWithTemporaryProfile {
    param([Parameter(Mandatory)][string]$ProfileJson,[Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$RecoveryRecordPath,[Parameter(Mandatory)]$RequestBinding)
    $null=ConvertFrom-CSharpNativeProfile $ProfileJson
    if($RequestBinding.Nonce -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' -or
        $RequestBinding.MainCommit -cnotmatch '^[a-f0-9]{40}$' -or $RequestBinding.RequestSha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'CSHARP_NATIVE_PROFILE_RECORD_BINDING'}
    $volume=Get-CSharpNativeRequestVolumeRoot
    $id=[guid]::NewGuid().ToString('N')
    $root=Join-Path $volume ('SqlServerLab-CSharpProfile-'+$id)
    $owned=[pscustomobject]@{OperationId=('csharp-profile-'+$id);VolumeRoot=$volume;Root=$root;File=(Join-Path $root 'csharp-sql2025.json');DirectoryOwned=$false;FileOwned=$false}
    $prior=$env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT;$primary=$null;$cleanup=$null;$recordFailure=$null;$result=$null;$record=$null
    try{
        Assert-CSharpNativeLocalPath $RecoveryRecordPath
        try{$record=[IO.File]::Open($RecoveryRecordPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)}catch{throw 'CSHARP_NATIVE_PROFILE_RECORD_CREATE'}
        Write-CSharpNativeRecoveryRecord $record $owned $RequestBinding 'PREPARED' $null $null
        New-CSharpNativeTemporaryDirectory $root
        $owned.DirectoryOwned=$true
        Write-CSharpNativeRecoveryRecord $record $owned $RequestBinding 'CREATED' $null $null
        Write-CSharpNativeTemporaryProfile -Owned $owned -Json $ProfileJson
        Write-CSharpNativeRecoveryRecord $record $owned $RequestBinding 'FILE_CREATED' $null $null
        $env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT=$root
        $null=Get-CSharpNativeProfile -Name 'csharp-sql2025'
        $result=& $Action
    }catch{$primary=Get-CSharpNativeFailureDiagnostic $_}
    finally{
        $env:SQL_SERVER_LAB_CSHARP_PROFILE_ROOT=$prior
        if($owned.DirectoryOwned){try{Remove-CSharpNativeTemporaryProfile $owned}catch{$cleanup=Get-CSharpNativeFailureCode $_}}
        if($record){
            $state=if($cleanup){'CLEANUP_FAILED'}elseif($owned.DirectoryOwned){'CLEANED'}else{'NOT_CREATED'}
            try{Write-CSharpNativeRecoveryRecord $record $owned $RequestBinding $state $(if($primary){$primary.PrimaryFailure}else{$null}) $cleanup $(if($primary){$primary.CleanupFailure}else{$null})}catch{$recordFailure='CSHARP_NATIVE_PROFILE_RECORD_FAILED'}
            try{$record.Dispose()}catch{$recordFailure='CSHARP_NATIVE_PROFILE_RECORD_FAILED'}
        }
    }
    if($primary -or $cleanup -or $recordFailure){
        $failure=[InvalidOperationException]::new('CSHARP_NATIVE_REQUEST_FAILED')
        $failure.Data['PrimaryFailure']=$(if($primary){$primary.PrimaryFailure}elseif($cleanup){'CSHARP_NATIVE_PROFILE_CLEANUP_FAILED'}else{'CSHARP_NATIVE_PROFILE_RECORD_FAILED'})
        $failure.Data['CleanupFailure']=$(if($primary){$primary.CleanupFailure}else{$null})
        $failure.Data['EvidenceFailure']=$(if($primary){$primary.EvidenceFailure}else{$null})
        $failure.Data['ProfileCleanupFailure']=$cleanup
        $failure.Data['RecoveryRecordFailure']=$recordFailure
        throw $failure
    }
    return $result
}
