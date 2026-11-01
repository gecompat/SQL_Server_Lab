#Requires -Version 7.2
param([Parameter(Mandatory)][string]$PayloadPath)
$ErrorActionPreference='Stop'
$payload=Get-Content -LiteralPath $PayloadPath -Raw|ConvertFrom-Json
if($payload.contract-cne 'SqlServerLab.WindowsSqlHostClient/1.0'){throw 'WINDOWS_SQL_HOST_CLIENT_PAYLOAD_CONTRACT'}
$code=1
try{
 if((Get-FileHash -LiteralPath $payload.script).Hash-cne $payload.scriptSha256){throw 'WINDOWS_SQL_HOST_CLIENT_SCRIPT_CHANGED'}
 # Native -File-Argumente werden durch PowerShell selbst gebunden; kein Eval.
 # Ein neues Kind erbt dieselbe flüchtige Netzwerkanmeldesitzung.
 $arguments=@('-NoLogo','-NoProfile','-File',[string]$payload.script)+@($payload.arguments)
 & (Get-Command pwsh -ErrorAction Stop).Source @arguments *> (Join-Path $payload.output 'client.private.log')
 $code=$LASTEXITCODE
}catch{
 # Die Quelle ist explizit gebundenes vertrauenswürdiges Testcode. Credentials
 # stehen weder in Args noch Payload; das Originalfehlerobjekt wird nicht exportiert.
 [IO.File]::WriteAllText((Join-Path $payload.output 'failure.private.txt'),$_.Exception.GetType().FullName,[Text.UTF8Encoding]::new($false))
}finally{
 @{contract=$payload.contract;exitCode=$code;qualificationPassNotImplied=$true}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $payload.output 'process.private.json') -Encoding utf8
}
exit $code
