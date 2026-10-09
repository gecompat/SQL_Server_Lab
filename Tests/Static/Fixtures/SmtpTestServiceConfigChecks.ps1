# Offline: direkter Helper, kein Modulimport/Provider/SQL/SMTP/HTTP.
[CmdletBinding()]
param([switch]$ConfigOnly)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo 'Private/SmtpTestServiceConfig.ps1')
$passed=0
function Check-SmtpConfig([string]$Name,[bool]$Success) {
    if (-not $Success) { throw ('SMTP_CONFIG_CHECK_FAILED: '+$Name) }
    $script:passed++; Write-Host ('PASS '+$Name)
}
function Reject-SmtpConfig([string]$Name,[scriptblock]$Action) {
    $code=$null
    try { & $Action | Out-Null } catch { $code=$_.Exception.Message }
    Check-SmtpConfig $Name ($code -ceq 'SMTP_TEST_CONFIG_INVALID')
}
Check-SmtpConfig 'Absent legacy branch' ($null -eq (ConvertTo-LabSmtpTestServiceConfig $null))
Check-SmtpConfig 'Disabled alone' ($null -eq (ConvertTo-LabSmtpTestServiceConfig @{enabled=$false}))
$d=ConvertTo-LabSmtpTestServiceConfig @{}
Check-SmtpConfig 'Selected defaults' ($d.maxStoredMessages -eq 1000 -and $d.maxStoredBytes -eq 268435456 -and $d.maxMessageBytes -eq 1048576 -and $d.acceptedMessagesPerUtc60Seconds -eq 120 -and $d.MemoryMiB -eq 256 -and $d.CPUs -eq 0.5)
$x=ConvertFrom-LabSmtpTestServiceJson '{"maxStoredBytes":1048576,"maxMessageMiB":64}'
Check-SmtpConfig 'Independent DATA storage caps' ($x.maxStoredBytes -eq 1048576 -and $x.maxMessageBytes -eq 67108864)
$ranges=@{maxStoredMessages=@(1L,100000L);maxStoredBytes=@(1048576L,4294967296L);maxMessageMiB=@(1L,64L);acceptedMessagesPerUtc60Seconds=@(1L,100000L);MemoryMiB=@(64L,4096L)}
foreach($key in $ranges.Keys) {
    foreach($value in $ranges[$key]) { $p=@{};$p[$key]=$value; $x=ConvertTo-LabSmtpTestServiceConfig $p; Check-SmtpConfig ($key+' boundary '+$value) ($x.$key -eq $value) }
    foreach($value in @(($ranges[$key][0]-1),($ranges[$key][1]+1),$null,$true,'1',1.0,@(1))) {
        $p=@{};$p[$key]=$value; Reject-SmtpConfig ($key+' wrong typed/range') {ConvertTo-LabSmtpTestServiceConfig $p}
    }
}
foreach($value in @(0.1,8.0)) { Check-SmtpConfig 'CPU exact boundary' ((ConvertTo-LabSmtpTestServiceConfig @{CPUs=$value}).CPUs -eq $value) }
foreach($value in @([byte]1,[uint16]1,[uint32]1,[uint64]1,[decimal]0.5)) { Check-SmtpConfig 'CPU actual numeric types' ((ConvertTo-LabSmtpTestServiceConfig @{CPUs=$value}).CPUs -eq $value) }
foreach($value in @(0.09,8.1,[double]::NaN,[double]::PositiveInfinity,$null,$false,'0.5',@(0.5))) { Reject-SmtpConfig 'CPU veto' {ConvertTo-LabSmtpTestServiceConfig @{CPUs=$value}} }
foreach($json in @('{"enabled":true,"enabled":true}','{"MemoryMiB":256,"memorymib":256}','{"unknown":1}','{"CPUs":"0.5"}','{"maxStoredMessages":1.0}','{"senderInstanceIds":{"x":1,"X":2}}','[]','null','{"maxStoredMessages":null}','{"enabled":false,"id":"smtp"}','{"senderInstanceIds":["primary","PRIMARY"]}','{"senderInstanceIds":"primary"}','{"id":"../smtp"}','{"id":"SMTP"}','{"enabled":1}','{"CPUs":1e999}','{')) {
    Reject-SmtpConfig 'Strict JSON veto' {ConvertFrom-LabSmtpTestServiceJson $json}
}
Reject-SmtpConfig 'Byte bound' {ConvertFrom-LabSmtpTestServiceJson ('{"id":"'+('x'*16384)+'"}')}
$copyInput=@{senderInstanceIds=@('primary')}
$copy=ConvertTo-LabSmtpTestServiceConfig $copyInput
$copyInput.senderInstanceIds[0]='changed'
Check-SmtpConfig 'Detached sender snapshot' ($copy.senderInstanceIds[0] -ceq 'primary')
Check-SmtpConfig 'Canonical JSON accepted' ((ConvertFrom-LabSmtpTestServiceJson '{"id":"smtp","senderInstanceIds":["primary","secondary"],"CPUs":1}').senderInstanceIds.Count -eq 2)
Write-Host ('SMTP config checks: '+$passed+' passed, 0 failed.')
