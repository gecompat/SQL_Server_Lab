# Synthetic stdout boundary only; no filesystem or provider action.
param([string]$LocationId)
$snapshot=[ordered]@{ContractVersion='SqlServerLab.InitialSetupCapacity/1.0';LocationId=$LocationId;Status='AVAILABLE';Code='INITIAL_SETUP_CAPACITY_OBSERVED';AvailableBytes=[long]0;TotalBytes=[long]1099511627776;ObservedAt=[datetime]::UtcNow.ToString('o');Notice='SYNTHETIC_WORKER_NOTICE'}
switch($env:SQL_SERVER_LAB_CAPACITY_FIXTURE_CASE){
    'unknown' {$snapshot.Status='UNKNOWN';$snapshot.Code='INITIAL_SETUP_CAPACITY_BINDING_UNVERIFIED';$snapshot.AvailableBytes=$null;$snapshot.TotalBytes=$null}
    'wrong-id' {$snapshot.LocationId='22222222-2222-2222-2222-222222222222'}
    'private-code' {$snapshot.Status='UNKNOWN';$snapshot.Code='INITIAL_SETUP_CAPACITY_PRIVATE_DETAIL';$snapshot.AvailableBytes=$null;$snapshot.TotalBytes=$null}
    'extra' {$snapshot.PrivateDetail='SYNTHETIC_PRIVATE_DETAIL'}
    'unknown-with-zero' {$snapshot.Status='UNKNOWN';$snapshot.Code='INITIAL_SETUP_CAPACITY_BINDING_UNVERIFIED'}
    'negative' {$snapshot.AvailableBytes=[long]-1}
    'fractional' {$snapshot.AvailableBytes=0.5}
    'unsafe-number' {$snapshot.TotalBytes=[long]9007199254740992}
    'future' {$snapshot.ObservedAt=[datetime]::UtcNow.AddHours(1).ToString('o')}
    'stale' {$snapshot.ObservedAt=[datetime]::UtcNow.AddMinutes(-2).ToString('o')}
    'timeout' {Start-Sleep -Seconds 20}
}
$snapshot|ConvertTo-Json -Depth 4 -Compress
