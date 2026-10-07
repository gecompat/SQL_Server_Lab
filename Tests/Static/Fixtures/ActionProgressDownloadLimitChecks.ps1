param()
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repoRoot 'Private/ActionProgress.ps1')
$root=Join-Path $repoRoot ('.artifacts/test-runs/download-limit-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$server=[powershell]::Create();$requests=[Collections.Concurrent.ConcurrentQueue[string]]::new()
$checks=0
function Check-DownloadLimit([bool]$Condition,[string]$Name){if(-not $Condition){throw ('DOWNLOAD_LIMIT_CHECK_FAILED: '+$Name)};$script:checks++;Write-Host ('PASS '+$Name)}
try{
 $listener.Start();$port=$listener.LocalEndpoint.Port
 $null=$server.AddScript({param($Listener,$Requests)
  $counts=@{}
  while($true){
   if(-not $Listener.Pending()){Start-Sleep -Milliseconds 10;continue}
   $client=$Listener.AcceptTcpClient()
   try{
    $stream=$client.GetStream();$stream.ReadTimeout=2000
    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,1024,$true)
    $request=$reader.ReadLine();while($reader.ReadLine()){}
    $path=($request -split ' ')[1];$Requests.Enqueue($path);$counts[$path]++
    $payload='abcdefghijklmnop';$status='200 OK';$extra='Content-Length: 16'
    switch($path){
     '/oversize'{$payload+='q';$extra='Content-Length: 17'}
     '/unknown'{$payload+='q';$extra=''}
     '/chunked'{$payload="8`r`nabcdefgh`r`n9`r`nijklmnopq`r`n0`r`n`r`n";$extra='Transfer-Encoding: chunked'}
     '/chunked-exact'{$payload="8`r`nabcdefgh`r`n8`r`nijklmnop`r`n0`r`n`r`n";$extra='Transfer-Encoding: chunked'}
     '/empty'{$payload='';$extra='Content-Length: 0'}
     '/truncated'{$payload='abcdefgh'}
     '/retry'{if($counts[$path] -eq 1){$status='503 Service Unavailable';$payload='';$extra='Content-Length: 0'}}
     '/redirect'{$status='302 Found';$payload='';$extra="Content-Length: 0`r`nLocation: /oversize"}
    }
    $headerLine=if($extra){$extra+"`r`n"}else{''}
    $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`n${headerLine}Connection: close`r`n`r`n")
    $stream.Write($header);if($payload){$stream.Write([Text.Encoding]::ASCII.GetBytes($payload))};$stream.Flush()
   }catch{}finally{$client.Dispose()}
  }
 }).AddArgument($listener).AddArgument($requests)
 $run=$server.BeginInvoke();$target=Join-Path $root 'payload.bin'
 foreach($path in @('oversize','unknown','chunked')){
  [IO.File]::WriteAllText($target,'sentinel');$before=$requests.Count;$code=$null
  try{Save-LabProgressDownload -Uri "http://127.0.0.1:$port/$path" -OutFile $target -MaximumBytes 16 -MaximumRetryCount 2 -RetryIntervalSec 1 -TimeoutSec 5}catch{$code=$_.Exception.Message}
  Check-DownloadLimit ($code -ceq 'LAB_DOWNLOAD_MAXIMUM_BYTES_EXCEEDED') ('Ueberlaenge verworfen '+$path)
  Check-DownloadLimit ($requests.Count -eq $before+1) ('Keine Wiederholung nach Bytegrenze '+$path)
  if($path -eq 'oversize'){Check-DownloadLimit ([IO.File]::ReadAllText($target) -ceq 'sentinel') 'Deklarierte Ueberlaenge oeffnet oder kuerzt kein Ziel'}
  else{Check-DownloadLimit ((Get-Item -LiteralPath $target).Length -eq 16) ('Kein Byte ueber Grenze geschrieben '+$path)}
 }
 foreach($path in @('exact','chunked-exact')){
  $output=@(Save-LabProgressDownload -Uri "http://127.0.0.1:$port/$path" -OutFile $target -MaximumBytes 16 -TimeoutSec 5)
  Check-DownloadLimit ($output.Count -eq 0 -and [IO.File]::ReadAllText($target) -ceq 'abcdefghijklmnop') ('Exakte Grenze erfolgreich '+$path)
 }
 Save-LabProgressDownload -Uri "http://127.0.0.1:$port/empty" -OutFile $target -MaximumBytes 1 -TimeoutSec 5
 Check-DownloadLimit ((Get-Item -LiteralPath $target).Length -eq 0) 'Leere Response bleibt erlaubt'
 Save-LabProgressDownload -Uri "http://127.0.0.1:$port/exact" -OutFile $target -MaximumBytes ([long]::MaxValue) -TimeoutSec 5
 Check-DownloadLimit ((Get-Item -LiteralPath $target).Length -eq 16) 'Long-Maximum ohne Additionsoverflow'
 $before=$requests.Count;$code=$null
 try{Save-LabProgressDownload -Uri "http://127.0.0.1:$port/redirect" -OutFile $target -MaximumBytes 16 -TimeoutSec 5}catch{$code=$_.Exception.Message}
 Check-DownloadLimit ($code -ceq 'LAB_DOWNLOAD_MAXIMUM_BYTES_EXCEEDED' -and $requests.Count -eq $before+2) 'Bytegrenze gilt auch nach bestehender Redirectfolge'
 $code=$null
 try{Save-LabProgressDownload -Uri "http://127.0.0.1:$port/truncated" -OutFile $target -MaximumBytes 16 -TimeoutSec 5}catch{$code=$_.Exception.Message}
 Check-DownloadLimit ([bool]$code -and (Get-Item -LiteralPath $target).Length -le 16) 'Abgeschnittene Response bleibt Fehler'
 Save-LabProgressDownload -Uri "http://127.0.0.1:$port/retry" -OutFile $target -MaximumBytes 16 -MaximumRetryCount 1 -RetryIntervalSec 1 -TimeoutSec 5
 Check-DownloadLimit ([IO.File]::ReadAllText($target) -ceq 'abcdefghijklmnop') 'Vorhandener HTTP-Retry bleibt begrenzt erfolgreich'
 $before=$requests.Count;$rejected=$false
 try{Save-LabProgressDownload -Uri "http://127.0.0.1:$port/exact" -OutFile $target -MaximumBytes 0}catch{$rejected=$true}
 Check-DownloadLimit ($rejected -and $requests.Count -eq $before) 'Nullgrenze wird vor Netzwerk verworfen'
 # Nach jedem Fehler sind die Dateihandles frei; Caller koennen ihren eigenen
 # Teilstand entfernen. Keine Loeschautoritaet fuer OutFile im Downloader.
 $handle=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$handle.Dispose()
 Check-DownloadLimit $true 'Dateihandle nach Erfolg und Fehler entsorgt'
 Write-Host ('DOWNLOAD_LIMIT_CHECKS: '+$checks+' PASS; actual loopback requests: '+$requests.Count+'; SQL/providers NOT_EXECUTED')
}finally{
 $listener.Stop();if($run){$server.Stop()};$server.Dispose()
 $expected=[IO.Path]::GetFullPath((Join-Path $repoRoot '.artifacts/test-runs')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
 $resolved=[IO.Path]::GetFullPath($root)
 if(-not $resolved.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^download-limit-[a-f0-9]{32}$'){throw 'DOWNLOAD_TEST_ROOT_INVALID'}
 $cursor=$resolved;while($cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'DOWNLOAD_TEST_ROOT_LINK'};$cursor=[IO.Path]::GetDirectoryName($cursor)}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
