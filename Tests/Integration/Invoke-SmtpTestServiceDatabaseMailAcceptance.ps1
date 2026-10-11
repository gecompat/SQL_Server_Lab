#Requires -Version 7.2
[CmdletBinding()]
param([ValidateSet('docker','podman')][string]$Provider='docker')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)
if($resolution.Count -ne 1 -or -not $resolution[0].Available -or $resolution[0].Invocation -isnot [string]){throw 'SMTP_DATABASEMAIL_RUNTIME_UNAVAILABLE'}
$runtime=$resolution[0].Invocation
$token=[guid]::NewGuid().ToString('N');$network="sql-lab-smtp-dbmail-$token";$receiver="smtp-receiver-$token";$gateway="smtp-gateway-$token";$sql="smtp-sql-$token";$tag="sql-server-lab/smtp-gateway-dbmail:$token"
$authPath=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-smtp-auth-$token";$password='Dbmail1!Pass';$receiverId=$null;$gatewayId=$null;$sqlId=$null
try {
    [IO.File]::WriteAllText($authPath,'synthetic:credential',[Text.UTF8Encoding]::new($false))
    & $runtime build --file (Join-Path $repoRoot 'Tools/SmtpTestServiceGateway.Dockerfile') --tag $tag $repoRoot | Out-Null;if($LASTEXITCODE -ne 0){throw 'SMTP_DATABASEMAIL_IMAGE_BUILD_FAILED'}
    & $runtime network create --internal $network | Out-Null;if($LASTEXITCODE -ne 0){throw 'SMTP_DATABASEMAIL_NETWORK_CREATE_FAILED'}
    $receiverId=@(& $runtime run -d --name $receiver --network $network --mount "type=bind,source=$authPath,target=/run/smtp-auth,readonly" ghcr.io/axllent/mailpit:v1.31.3 --ui-auth-file /run/smtp-auth)[-1].Trim();if($receiverId -notmatch '^[a-f0-9]{12,64}$'){throw 'SMTP_DATABASEMAIL_RECEIVER_START_FAILED'}
    $gatewayId=@(& $runtime run -d --name $gateway --network $network --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m --cap-drop ALL --security-opt no-new-privileges --mount "type=bind,source=$authPath,target=/run/smtp-auth,readonly" -e SMTP_GATEWAY_API_URL=http://$receiver`:8025 -e SMTP_GATEWAY_API_AUTH_FILE=/run/smtp-auth -e SMTP_GATEWAY_MAX_MESSAGES=10 -e SMTP_GATEWAY_MAX_BYTES=1048576 -e SMTP_GATEWAY_MAX_MESSAGE_BYTES=1048576 -e SMTP_GATEWAY_MAX_PER_UTC60=10 -e SMTP_GATEWAY_UPSTREAM_HOST=$receiver -e SMTP_GATEWAY_UPSTREAM_PORT=1025 $tag)[-1].Trim();if($gatewayId -notmatch '^[a-f0-9]{12,64}$'){throw 'SMTP_DATABASEMAIL_GATEWAY_START_FAILED'}
    $sqlId=@(& $runtime run -d --name $sql --network $network -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD=$password -e MSSQL_PID=Developer mcr.microsoft.com/mssql/server:2025-latest)[-1].Trim();if($sqlId -notmatch '^[a-f0-9]{12,64}$'){throw 'SMTP_DATABASEMAIL_SQL_START_FAILED'}
    $deadline=[Diagnostics.Stopwatch]::StartNew();$ready=$false
    while($deadline.Elapsed.TotalSeconds -lt 180){& $runtime exec $sqlId /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $password -C -Q 'SELECT 1' -b 1>$null 2>$null;if($LASTEXITCODE -eq 0){$ready=$true;break};Start-Sleep -Seconds 2}
    if(-not $ready){throw 'SMTP_DATABASEMAIL_SQL_NOT_READY'}
    $sqlText=@"
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1; RECONFIGURE;
EXEC msdb.dbo.sysmail_add_account_sp @account_name=N'LabSmtpAccount', @email_address=N'lab@example.invalid', @display_name=N'SQL Server Lab', @mailserver_name=N'$gateway', @port=1025;
EXEC msdb.dbo.sysmail_add_profile_sp @profile_name=N'LabSmtpProfile';
EXEC msdb.dbo.sysmail_add_profileaccount_sp @profile_name=N'LabSmtpProfile', @account_name=N'LabSmtpAccount', @sequence_number=1;
EXEC msdb.dbo.sp_send_dbmail @profile_name=N'LabSmtpProfile', @recipients=N'receiver@example.invalid', @subject=N'acceptance', @body=N'database-mail';
"@
    & $runtime exec $sqlId /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $password -C -d msdb -Q $sqlText -b
    if($LASTEXITCODE -ne 0){throw 'SMTP_DATABASEMAIL_CONFIGURATION_FAILED'}
    $delivered=$false;$wait=[Diagnostics.Stopwatch]::StartNew();while($wait.Elapsed.TotalSeconds -lt 45){$count=@(& $runtime exec $gatewayId python -c "import base64,json,urllib.request; r=urllib.request.Request('http://$receiver`:8025/api/v1/messages',headers={'Authorization':'Basic '+base64.b64encode(b'synthetic:credential').decode('ascii')}); print(len(json.load(urllib.request.urlopen(r,timeout=5))['messages']))")[-1].Trim();if($count -eq '1'){$delivered=$true;break};Start-Sleep -Seconds 1}
    if(-not $delivered){throw 'SMTP_DATABASEMAIL_DELIVERY_NOT_OBSERVED'}
    Write-Host "SMTP Database Mail acceptance ($Provider): PASS"
} finally {
    if($sqlId){& $runtime rm -f $sqlId 1>$null 2>$null};if($gatewayId){& $runtime rm -f $gatewayId 1>$null 2>$null};if($receiverId){& $runtime rm -f $receiverId 1>$null 2>$null}
    & $runtime network rm $network 1>$null 2>$null;& $runtime image rm -f $tag 1>$null 2>$null
    Remove-Item -LiteralPath $authPath -Force -ErrorAction SilentlyContinue
}
