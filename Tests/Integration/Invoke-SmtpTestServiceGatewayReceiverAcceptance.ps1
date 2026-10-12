#Requires -Version 7.2
[CmdletBinding()]
param([ValidateSet('docker','podman')][string]$Provider='docker')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)
if($resolution.Count -ne 1 -or -not $resolution[0].Available -or $resolution[0].Invocation -isnot [string]){throw 'SMTP_GATEWAY_RUNTIME_UNAVAILABLE'}
$runtime=$resolution[0].Invocation;$token=[guid]::NewGuid().ToString('N')
$network="sql-lab-smtp-$token";$receiver="smtp-receiver-$token";$gateway="smtp-gateway-$token";$tag="sql-server-lab/smtp-gateway-receiver:$token"
$authPath=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-smtp-auth-$token";$receiverId=$null;$gatewayId=$null
$send="import smtplib; d='example'+'.invalid'; c=smtplib.SMTP('127.0.0.1',1025,timeout=5); c.sendmail('from'+'@'+d,['to'+'@'+d],b'Subject: synthetic\r\n\r\nbody\r\n'); c.quit()"
$reject=@'
import smtplib
d='example'+'.invalid'
c=smtplib.SMTP('127.0.0.1',1025,timeout=5)
try:
    c.sendmail('from'+'@'+d,['to'+'@'+d],b'Subject: synthetic\r\n\r\nbody\r\n')
except smtplib.SMTPDataError as e:
    print(e.smtp_code)
else:
    raise SystemExit(1)
finally:
    c.quit()
'@
try {
    [IO.File]::WriteAllText($authPath,'synthetic:credential',[Text.UTF8Encoding]::new($false))
    & $runtime build --file (Join-Path $repoRoot 'Tools/SmtpTestServiceGateway.Dockerfile') --tag $tag $repoRoot | Out-Null;if($LASTEXITCODE -ne 0){throw 'SMTP_GATEWAY_IMAGE_BUILD_FAILED'}
    & $runtime network create $network | Out-Null;if($LASTEXITCODE -ne 0){throw 'SMTP_GATEWAY_NETWORK_CREATE_FAILED'}
    $receiverId=@(& $runtime run -d --name $receiver --network $network --mount "type=bind,source=$authPath,target=/run/smtp-auth,readonly" ghcr.io/axllent/mailpit:v1.31.3 --ui-auth-file /run/smtp-auth)[-1].Trim()
    if($receiverId -notmatch '^[a-f0-9]{12,64}$'){throw 'SMTP_RECEIVER_START_FAILED'}
    $gatewayId=@(& $runtime run -d --name $gateway --network $network --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m --cap-drop ALL --security-opt no-new-privileges --mount "type=bind,source=$authPath,target=/run/smtp-auth,readonly" -e SMTP_GATEWAY_API_URL=http://$receiver`:8025 -e SMTP_GATEWAY_API_AUTH_FILE=/run/smtp-auth -e SMTP_GATEWAY_MAX_MESSAGES=3 -e SMTP_GATEWAY_MAX_BYTES=1048576 -e SMTP_GATEWAY_MAX_MESSAGE_BYTES=1048576 -e SMTP_GATEWAY_MAX_PER_UTC60=2 -e SMTP_GATEWAY_UPSTREAM_HOST=$receiver -e SMTP_GATEWAY_UPSTREAM_PORT=1025 $tag)[-1].Trim()
    if($gatewayId -notmatch '^[a-f0-9]{12,64}$'){throw 'SMTP_GATEWAY_CONTAINER_START_FAILED'}
    Start-Sleep -Seconds 6
    & $runtime exec $gatewayId python -c "import smtplib; c=smtplib.SMTP('$receiver',1025,timeout=5); c.noop(); c.quit()";if($LASTEXITCODE -ne 0){throw 'SMTP_RECEIVER_SMTP_UNAVAILABLE'}
    & $runtime exec $gatewayId python -c "import smtplib; d='example'+'.invalid'; c=smtplib.SMTP('$receiver',1025,timeout=5); c.sendmail('direct'+'@'+d,['receiver'+'@'+d],b'Subject: direct\r\n\r\nbody\r\n'); c.quit()";if($LASTEXITCODE -ne 0){throw 'SMTP_RECEIVER_DIRECT_RELAY_FAILED'}
    & $runtime exec $gatewayId python -c "import runpy; d='example'+'.invalid'; g=runpy.run_path('/app/SmtpTestServiceGateway.py'); g['_relay'](b'Subject: helper\r\n\r\nbody\r\n','helper'+'@'+d,['receiver'+'@'+d],'$receiver',1025)";if($LASTEXITCODE -ne 0){throw 'SMTP_GATEWAY_HELPER_RELAY_FAILED'}
    & $runtime exec $gatewayId python -c $send;if($LASTEXITCODE -ne 0){throw 'SMTP_GATEWAY_RELAY_FAILED'}
    $count=@(& $runtime exec $gatewayId python -c "import base64,json,urllib.request; r=urllib.request.Request('http://$receiver`:8025/api/v1/messages',headers={'Authorization':'Basic '+base64.b64encode(b'synthetic:credential').decode('ascii')}); print(len(json.load(urllib.request.urlopen(r,timeout=5))['messages']))")[-1].Trim()
    if($count -cne '3'){throw 'SMTP_GATEWAY_RECEIVER_COUNT_INVALID'}
    $rejected=@(& $runtime exec $gatewayId python -c $reject)[-1].Trim()
    if($rejected -cne '452'){throw 'SMTP_GATEWAY_QUOTA_REJECTION_INVALID'}
    Write-Host "SMTP gateway receiver acceptance ($Provider): PASS"
} finally {
    if($gatewayId){& $runtime rm -f $gatewayId 1>$null 2>$null};if($receiverId){& $runtime rm -f $receiverId 1>$null 2>$null}
    & $runtime network rm $network 1>$null 2>$null;& $runtime image rm -f $tag 1>$null 2>$null
    Remove-Item -LiteralPath $authPath -Force -ErrorAction SilentlyContinue
}
