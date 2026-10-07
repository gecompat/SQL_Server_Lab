#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den echten Loopback-HTTP-Weg der SA-Passwortbarriere ohne Creationjob.
.DESCRIPTION
    Startet nur einen eigenen lokalen UI-Listener mit isoliertem Testroot.
    Ungueltige Requests werden vor der Jobanlage abgewiesen. Der Test startet
    keinen Provider und bewahrt bei Fehlschlag lokale Diagnosen fuer Recovery.
#>
[CmdletBinding()]
param([switch]$Child,[int]$Port=0,[string]$Root='')
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if($Child){
    if([string]::IsNullOrWhiteSpace($Root)){throw 'SA_HTTP_CHILD_SCOPE_INVALID'}
    $childRoot=[IO.Path]::GetFullPath($Root)
    $tempBoundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if($Port -lt 1025 -or $Port -gt 65535 -or
        -not $childRoot.StartsWith($tempBoundary,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($childRoot) -cnotmatch '^sql-lab-sa-http-[a-f0-9]{32}$' -or
        -not (Test-Path -LiteralPath $childRoot -PathType Container) -or
        (Get-Item -LiteralPath $childRoot).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)){
        throw 'SA_HTTP_CHILD_SCOPE_INVALID'
    }
    $env:SQL_SERVER_LAB_STATE=Join-Path $childRoot 'state'
    $env:SQL_SERVER_LAB_DATA_ROOT=Join-Path $childRoot 'Lab_Data'
    $global:saHttpChildRoot=$childRoot;$global:saHttpControl=$null;$global:saHttpHandle=$null
    function Write-Host {
        param([Parameter(Position=0,ValueFromRemainingArguments)][object[]]$Object,[ConsoleColor]$ForegroundColor='Gray',[switch]$NoNewline,[string]$Separator=' ')
        if($Object.Count -eq 1 -and $Object[0] -ceq "SQL_Server_Lab Workflow UI: http://127.0.0.1:$Port/"){
            $listener=Get-Variable listener -Scope 1 -ValueOnly;$session=Get-Variable operatorSession -Scope 1 -ValueOnly
            $ready=Join-Path $global:saHttpChildRoot 'operator-locator.private.json'
            $file=[IO.FileStream]::new($ready,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$bytes=[Text.Encoding]::UTF8.GetBytes((@{OperatorFile=$session.File}|ConvertTo-Json -Compress));$file.Write($bytes);$file.Flush($true)}finally{$file.Dispose()}
            $global:saHttpControl=[powershell]::Create()
            $null=$global:saHttpControl.AddScript({param($owned,$stop)
                $deadline=[datetime]::UtcNow.AddMinutes(2)
                while($owned.IsListening -and -not [IO.File]::Exists($stop) -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
                if($owned.IsListening){$owned.Stop()}
            }).AddArgument($listener).AddArgument((Join-Path $global:saHttpChildRoot 'stop.private.json'))
            $global:saHttpHandle=$global:saHttpControl.BeginInvoke()
        }
        Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
    }
    try { & (Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1') -Port $Port -NoBrowser }
    finally { if($global:saHttpControl){try{$null=$global:saHttpControl.EndInvoke($global:saHttpHandle)}finally{$global:saHttpControl.Dispose()}} }
    return
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-sa-http-'+[guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $root){throw 'SA_HTTP_ROOT_EXISTS'}
$null=New-Item -ItemType Directory -Path $root
$socket=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$socket.Start();$port=[int]$socket.LocalEndpoint.Port;$socket.Stop()
$process=$null;$started=$false;$client=$null;$stdout=$null;$stderr=$null;$complete=$false
try {
    $tool=@(Get-Command pwsh -CommandType Application -ErrorAction Stop |
        Where-Object { [IO.Path]::IsPathFullyQualified([string]$_.Source) -and (Test-Path -LiteralPath $_.Source -PathType Leaf) })[0]
    if(-not $tool){throw 'SA_HTTP_POWERSHELL_UNRESOLVED'}
    $start=[Diagnostics.ProcessStartInfo]::new([string]$tool.Source)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in @('-NoProfile','-File',$PSCommandPath,'-Child','-Port',([string]$port),'-Root',$root)){
        $null=$start.ArgumentList.Add($argument)
    }
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    $started=$process.Start()
    if(-not $started){throw 'SA_HTTP_SERVER_START_FAILED'}
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $client=[Net.Http.HttpClient]::new();$client.Timeout=[TimeSpan]::FromSeconds(8)
    $base="http://127.0.0.1:$port"
    $ready=$false
    for($attempt=0;$attempt -lt 30;$attempt++){
        if($process.HasExited){throw 'SA_HTTP_SERVER_EXITED'}
        try {
            $response=$client.GetAsync($base+'/').GetAwaiter().GetResult()
            try {
                $html=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if($response.IsSuccessStatusCode -and $html.Contains('container-password-adjustment')){$ready=$true;break}
            } finally {$response.Dispose()}
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    if(-not $ready){throw 'SA_HTTP_SERVER_NOT_READY'}
    $locator=Get-Content -LiteralPath (Join-Path $root 'operator-locator.private.json') -Raw|ConvertFrom-Json
    $operator=Get-Content -LiteralPath $locator.OperatorFile -Raw|ConvertFrom-Json
    if($operator.ListenerUrl -cne ($base+'/') -or $operator.Capability -cnotmatch '^[a-f0-9]{64}$'){throw 'SA_HTTP_OPERATOR_BINDING'}
    $null=$client.DefaultRequestHeaders.TryAddWithoutValidation('X-SqlServerLab-Operator',$operator.Capability)
    $cases=@(
        '{"action":"NewContainerLab","parameters":{"SaPassword":"Ab3","Provider":"docker","SqlVersion":"2025-CU9"}}',
        '{"action":"NewContainerLab","parameters":{"SaPassword":"Ab3","Provider":"docker","SqlVersion":"2025","SaPasswordMinimumLength":3}}',
        '{"action":"NewContainerLab","parameters":{"SaPassword":"Ab3xxxxx","SaPassword":"Ab3xxxxx","Provider":"docker","SqlVersion":"2025-CU9"}}'
    )
    foreach($body in $cases){
        $content=[Net.Http.StringContent]::new($body,[Text.Encoding]::UTF8,'application/json')
        try {
            $response=$client.PostAsync($base+'/api/actions',$content).GetAwaiter().GetResult()
            try {
                $reply=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if([int]$response.StatusCode -ne 500 -or $reply -notmatch '^UI_REQUEST_UNCONFIRMED:' -or
                    $reply.Contains('Ab3')){throw 'SA_HTTP_REJECTION_INVALID'}
            } finally {$response.Dispose()}
        } finally {$content.Dispose()}
    }
    $jobs=$client.GetAsync($base+'/api/jobs').GetAwaiter().GetResult()
    try {
        $jobBody=$jobs.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if(-not $jobs.IsSuccessStatusCode -or $jobBody.Contains('NewContainerLab')){
            throw 'SA_HTTP_CREATION_JOB_UNEXPECTED'
        }
    } finally {$jobs.Dispose()}
    $complete=$true
}
finally {
    if($client){$client.Dispose()}
    if($process){
        if($started -and -not $process.HasExited){[IO.File]::WriteAllText((Join-Path $root 'stop.private.json'),'STOP');$null=$process.WaitForExit(10000)}
        if($started -and -not $process.HasExited){$process.Kill($true)}
        if($started){$null=$process.WaitForExit(10000)}
        if(-not $complete){
            if($stdout){[IO.File]::WriteAllText((Join-Path $root 'server.stdout.private.log'),$stdout.GetAwaiter().GetResult())}
            if($stderr){[IO.File]::WriteAllText((Join-Path $root 'server.stderr.private.log'),$stderr.GetAwaiter().GetResult())}
        }
        $process.Dispose()
    }
    if($complete){
        $absolute=[IO.Path]::GetFullPath($root)
        $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($absolute) -notmatch '^sql-lab-sa-http-[a-f0-9]{32}$' -or
            (Get-Item -LiteralPath $absolute).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)){
            throw 'SA_HTTP_TEMP_SCOPE_INVALID'
        }
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}
if(-not $complete){throw 'SA_HTTP_NETWORK_INCOMPLETE'}
Write-Host 'SA PASSWORD HTTP NETWORK: PASS (loopback; invalid requests; no creation job; own listener cleanup)'
