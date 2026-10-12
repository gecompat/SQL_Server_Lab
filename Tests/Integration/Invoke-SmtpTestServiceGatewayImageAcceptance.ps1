#Requires -Version 7.2
[CmdletBinding()]
param([ValidateSet('docker','podman')][string]$Provider='docker')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)
if($resolution.Count -ne 1 -or -not $resolution[0].Available -or $resolution[0].Invocation -isnot [string]){throw 'SMTP_GATEWAY_RUNTIME_UNAVAILABLE'}
$runtime=$resolution[0].Invocation
$token=[guid]::NewGuid().ToString('N')
$name="sql-lab-smtp-gateway-$token"
$tag="sql-server-lab/smtp-gateway-acceptance:$token"
$authPath=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-smtp-auth-$token"
$id=$null
try {
    [IO.File]::WriteAllText($authPath,'synthetic:credential',[Text.UTF8Encoding]::new($false))
    & $runtime build --file (Join-Path $repoRoot 'Tools/SmtpTestServiceGateway.Dockerfile') --tag $tag $repoRoot | Out-Null
    if($LASTEXITCODE -ne 0){throw 'SMTP_GATEWAY_IMAGE_BUILD_FAILED'}
    $id=@(& $runtime run -d --name $name --network none --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m --cap-drop ALL --security-opt no-new-privileges `
        --mount "type=bind,source=$authPath,target=/run/smtp-auth,readonly" `
        -e SMTP_GATEWAY_API_URL=http://127.0.0.1:18025 -e SMTP_GATEWAY_API_AUTH_FILE=/run/smtp-auth `
        -e SMTP_GATEWAY_MAX_MESSAGES=1 -e SMTP_GATEWAY_MAX_BYTES=1048576 -e SMTP_GATEWAY_MAX_MESSAGE_BYTES=1048576 `
        -e SMTP_GATEWAY_MAX_PER_UTC60=1 -e SMTP_GATEWAY_UPSTREAM_HOST=127.0.0.1 -e SMTP_GATEWAY_UPSTREAM_PORT=1025 $tag)[-1].Trim()
    if($id -notmatch '^[a-f0-9]{12,64}$'){throw 'SMTP_GATEWAY_CONTAINER_START_FAILED'}
    Start-Sleep -Seconds 2
    $state=@(& $runtime inspect --format '{{.State.Running}}|{{.Config.User}}' $id)[-1].Trim()
    if($state -cne 'true|smtp-gateway'){throw 'SMTP_GATEWAY_CONTAINER_STATE_INVALID'}
    $banner=@(& $runtime exec $id python -c "import socket; s=socket.create_connection(('127.0.0.1',1025),2); print(s.recv(128).decode('ascii').strip()); s.close()")[-1].Trim()
    if($banner -cne '220 sql-server-lab smtp quota gateway'){throw 'SMTP_GATEWAY_LISTENER_INVALID'}
    Write-Host "SMTP gateway image acceptance ($Provider): PASS"
} finally {
    if($id){& $runtime rm -f $id 1>$null 2>$null}
    & $runtime image rm -f $tag 1>$null 2>$null
    Remove-Item -LiteralPath $authPath -Force -ErrorAction SilentlyContinue
}
