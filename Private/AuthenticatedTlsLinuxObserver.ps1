# Fixed program, selected by the controller rather than by an export.
function Get-LabTlsLinuxObservationProgram {
    return @'
$ErrorActionPreference='Stop'
function Stat([string]$Path){
    $text=& /usr/bin/stat -c '%u:%a:%d:%i:%s' -- $Path
    if($LASTEXITCODE-ne0){throw 'STAT'}
    $parts=$text.Split(':')
    if($parts.Count-ne5){throw 'STAT'}
    @{Uid=[long]$parts[0];Mode=$parts[1];Device=[long]$parts[2];Inode=[long]$parts[3];Bytes=[long]$parts[4]}
}
function Binary([string]$Path){
    $file=Get-Item -LiteralPath $Path -Force
    if($file.PSIsContainer-or$file.LinkType-or$file.Length-lt1){throw 'BINARY'}
    @{Path=$Path;Sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant();Bytes=[long]$file.Length}
}
$home='/opt/tls-client';$ca=$home+'/ca.pem';$empty=$home+'/empty'
if($env:HOME-cne$home-or$env:SSL_CERT_FILE-cne$ca-or$env:SSL_CERT_DIR-cne$empty){throw 'ENVIRONMENT'}
foreach($path in @($home,$ca,$empty)){
    if((Get-Item -LiteralPath $path -Force).LinkType){throw 'LINK'}
}
$fs=& /usr/bin/stat -f -c '%T' -- $home
if($LASTEXITCODE-ne0-or$fs-cne'tmpfs'){throw 'FILESYSTEM'}
$parent=Stat $home;$file=Stat $ca;$dir=Stat $empty
$cert=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($ca)
try{$certificateHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($cert.RawData)).ToLowerInvariant()}finally{$cert.Dispose()}
$drivers=@(Get-ChildItem -LiteralPath /opt/microsoft/msodbcsql18/lib64 -Filter 'libmsodbcsql-18*.so.*' -File|Where-Object {-not $_.LinkType})
if($drivers.Count-ne1){throw 'ODBC'}
$namespace=& /usr/bin/readlink /proc/self/ns/net
if($LASTEXITCODE-ne0){throw 'NAMESPACE'}
$kernel=Get-Content -LiteralPath /proc/1/status
$cap=@($kernel|Where-Object {$_-cmatch'^Cap(?:Inh|Prm|Eff|Bnd|Amb):'})
if($cap.Count-ne5-or@($cap|Where-Object {$_-cnotmatch'^Cap(?:Inh|Prm|Eff|Bnd|Amb):\s+0000000000000000$'}).Count-or
    @($kernel|Where-Object {$_-cmatch'^NoNewPrivs:\s+1$'}).Count-ne1){throw 'KERNEL'}
if((& /usr/bin/id -u)-cne'10001'-or(& /usr/bin/id -g)-cne'0'){throw 'IDENTITY'}
$result=@{
    NetNamespace=$namespace
    Trust=@{
        Store='ISOLATED_CLIENT_CA_STORE';Path=$ca;CertificateSha256=$certificateHash
        FileSha256=(Get-FileHash -LiteralPath $ca -Algorithm SHA256).Hash.ToLowerInvariant()
        Bytes=$file.Bytes;Uid=$file.Uid;Mode=$file.Mode;FileSystem=$fs;Device=$file.Device;Inode=$file.Inode
        ParentUid=$parent.Uid;ParentMode=$parent.Mode;Home=$home;Directory=$empty
        DirectoryUid=$dir.Uid;DirectoryMode=$dir.Mode;DirectoryDevice=$dir.Device;DirectoryInode=$dir.Inode
        DirectoryEmpty=(@(Get-ChildItem -LiteralPath $empty -Force).Count-eq0)
        UserStoreAbsent=(-not(Test-Path -LiteralPath ($home+'/.dotnet/corefx/cryptography/x509stores')))
    }
    Binaries=@{
        PowerShell=Binary ($home+'/pwsh/pwsh')
        SqlClient=Binary ($home+'/pwsh/System.Data.SqlClient.dll')
        Sqlcmd=Binary '/opt/mssql-tools18/bin/sqlcmd'
        OdbcDriver=Binary $drivers[0].FullName
    }
}
$result|ConvertTo-Json -Depth 6 -Compress
'@
}

function Get-LabTlsLinuxExecArguments {
    param([string]$ContainerId,[string[]]$Command,[switch]$InputStream)
    if($ContainerId-cnotmatch'\A[0-9a-f]{64}\z'){throw 'TLS_LINUX_CLIENT_BINDING_INVALID'}
    $prefix=if($InputStream){@('exec','-i')}else{@('exec')}
    return @($prefix)+@('--user','10001:0',$ContainerId,'/usr/bin/env','-i',
        'HOME=/opt/tls-client','DOTNET_CLI_HOME=/opt/tls-client',
        'SSL_CERT_FILE=/opt/tls-client/ca.pem','SSL_CERT_DIR=/opt/tls-client/empty',
        'PATH=/usr/bin:/bin','LANG=C.UTF-8')+@($Command)
}
