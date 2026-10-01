#Requires -Version 7.2
param([string]$ExpectedPlanKey)
$case=$env:SQL_SERVER_LAB_CMS_FIXTURE_CASE
if($case -eq 'timeout'){Start-Sleep -Seconds 20;exit 1}
$dto=[ordered]@{ContractVersion='SqlServerLab.CmsInspection/1.0';Status='OBSERVED';Code='CMS_INSPECTION_OBSERVED';RunId='11111111-1111-1111-1111-111111111111';InstanceId='primary';Provider='docker';SelectionKey=$ExpectedPlanKey;ObservedAt=[datetime]::UtcNow.ToString('o');SqlMajor=17;ManagedGroupCount=3;ManagedServerCount=0;Notice='SYNTHETIC_PRIVATE_NOTICE'}
switch($case){
 'unknown' {$dto.Status='UNKNOWN';$dto.Code='CMS_INSPECTION_READ_FAILED';$dto.SqlMajor=$null;$dto.ManagedGroupCount=$null;$dto.ManagedServerCount=$null}
 'wrong-run' {$dto.RunId='22222222-2222-2222-2222-222222222222'}
 'wrong-provider' {$dto.Provider='podman'}
 'wrong-key' {$dto.SelectionKey='d'*64}
 'extra' {$dto.Private='SYNTHETIC_PRIVATE_DATA'}
 'private-code' {$dto.Code='SYNTHETIC_PRIVATE_CODE'}
 'negative' {$dto.ManagedServerCount=-1}
 'fractional' {$dto.ManagedServerCount=0.5}
 'unsafe' {$dto.ManagedServerCount=9007199254740992}
 'unknown-zero' {$dto.Status='UNKNOWN';$dto.Code='CMS_INSPECTION_READ_FAILED';$dto.SqlMajor=$null;$dto.ManagedGroupCount=$null}
 'future' {$dto.ObservedAt=[datetime]::UtcNow.AddMinutes(5).ToString('o')}
 'stale' {$dto.ObservedAt=[datetime]::UtcNow.AddMinutes(-5).ToString('o')}
 'invalid-json' {Write-Output '{broken';exit 0}
}
$dto|ConvertTo-Json -Compress
