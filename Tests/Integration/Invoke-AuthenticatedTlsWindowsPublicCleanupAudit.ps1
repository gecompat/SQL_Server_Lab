#Requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9A-F]{64}\z')][string]$ExpectedConfigurationSha256)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if((Get-FileHash -LiteralPath $ConfigurationPath).Hash -cne $ExpectedConfigurationSha256){throw 'INDEPENDENT_AUDIT_CONFIG_CHANGED'}
$root=Split-Path $ConfigurationPath -Parent
$c=Get-Content -LiteralPath $ConfigurationPath -Raw|ConvertFrom-Json -Depth 24 -DateKind String
if($c.RepositoryRoot -cne $repo -or $c.EvidenceRoot -cne $root){throw 'INDEPENDENT_AUDIT_ROOT_CHANGED'}
$w=Get-Content (Join-Path $root 'worker-result.private.json') -Raw|ConvertFrom-Json -Depth 24 -DateKind String
$before=Get-Content (Join-Path $root 'baseline.private.json') -Raw|ConvertFrom-Json -Depth 24 -DateKind String
$returned=Get-Content (Join-Path $root 'returned-run.private.json') -Raw|ConvertFrom-Json -Depth 24 -DateKind String
$deadline=[datetimeoffset]::Parse((Get-Content (Join-Path $root 'supervisor-intent.private.json') -Raw|ConvertFrom-Json -DateKind String).DeadlineUtc)
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
if([datetimeoffset]::UtcNow -ge $deadline -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $c.ActorSid -or
    $w.Pid -eq $PID -or $w.NativeEndKnown -ne $true -or $w.Cleanup -cne 'REMOVED' -or $w.RunId -cne $returned.RunId -or
    $w.VmId -cne $returned.VmId -or $w.ScopeId -cne $returned.ScopeId){throw 'INDEPENDENT_AUDIT_BINDING_INVALID'}
$checks=[Collections.Generic.List[string]]::new()
$all=@(Get-VM -ErrorAction Stop)
if(@($all|Where-Object {$_.Id.ToString('D') -ceq $w.VmId}).Count){throw 'INDEPENDENT_OWN_VM_STILL_PRESENT'}
$checks.Add('OWN_VM_ABSENT')
$state=& $module {param($r,$s)Get-LabRunState -RunId $r -StateRoot $s} $w.RunId $c.StateRoot
if($state.state -cne 'REMOVED' -or $state.scopeId -cne $w.ScopeId){throw 'INDEPENDENT_STATE_NOT_REMOVED'}
$checks.Add('OWN_STATE_REMOVED')
if(Test-Path -LiteralPath (Join-Path $root 'export')){throw 'INDEPENDENT_OWN_EXPORT_STILL_PRESENT'}
$checks.Add('OWN_EXPORT_ABSENT')
$afterVms=@($all|Sort-Object Id|Select-Object @{n='Id';e={$_.Id.ToString('D')}},State,Notes)
if((ConvertTo-Json -InputObject @($before.Vms) -Depth 8 -Compress) -cne (ConvertTo-Json -InputObject $afterVms -Depth 8 -Compress)){throw 'INDEPENDENT_FOREIGN_VM_DRIFT'}
$checks.Add('FOREIGN_VM_BASELINE_UNCHANGED')
$switches=@(Get-VMSwitch|Sort-Object Id|Select-Object @{n='Id';e={$_.Id.ToString('D')}},SwitchType)
if((ConvertTo-Json -InputObject @($before.Switches) -Depth 8 -Compress) -cne (ConvertTo-Json -InputObject $switches -Depth 8 -Compress)){throw 'INDEPENDENT_SWITCH_DRIFT'}
$checks.Add('SWITCH_BASELINE_UNCHANGED')
$trust=@(Get-ChildItem Cert:/CurrentUser/Root|ForEach-Object {[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($_.RawData))}|Sort-Object)
if((ConvertTo-Json -InputObject @($before.Trust) -Compress) -cne (ConvertTo-Json -InputObject $trust -Compress)){throw 'INDEPENDENT_TRUST_DRIFT'}
$checks.Add('CURRENT_USER_ROOT_BASELINE_UNCHANGED')
foreach($f in $before.Files){if(-not(Test-Path -LiteralPath $f.Path) -or (Get-FileHash -LiteralPath $f.Path).Hash -cne $f.Sha256){throw 'INDEPENDENT_OTHER_CONSUMER_FILE_DRIFT'}}
$checks.Add('OTHER_CONSUMER_FILES_UNCHANGED')
. (Join-Path $repo 'Tests/Common/AuthenticatedTlsHyperVAcceptance.ps1')
if((@(Get-TlsHyperVSourceInventory $repo)-join ([string][char]10)) -cne (@($c.Sources.RelativePath)-join ([string][char]10))){throw 'INDEPENDENT_SOURCE_INVENTORY_DRIFT'}
foreach($f in $c.Sources){if((Get-FileHash -LiteralPath (Join-Path $repo $f.RelativePath)).Hash -cne $f.Sha256){throw 'INDEPENDENT_SOURCE_BYTES_DRIFT'}}
$checks.Add('SOURCE_PINS_UNCHANGED')
if([datetimeoffset]::UtcNow -ge $deadline){throw 'INDEPENDENT_AUDIT_DEADLINE_EXCEEDED'}
$result=@{ContractVersion='SqlServerLab.PublicWindowsTlsCleanupAudit/0.1';Status='PASS';Scope='READ_ONLY_CLEANUP_AUDIT_ONLY';Pid=$PID;WorkerPid=$w.Pid;RunId=$w.RunId;ScopeId=$w.ScopeId;VmId=$w.VmId;SourceDigest=$c.SourceDigest;Checks=$checks.ToArray();ObservedAtUtc=[datetimeoffset]::UtcNow.ToString('o');OriginalWorkerStatus=$w.Status;OriginalSupervisorStatus='FAIL';NoSqlOrGuestOperation=$true}
& $module {param($p,$s,$v)Write-LabTlsCaPrivateFile $p $s (ConvertTo-LabTlsRegistryWriterBytes $v)} (Join-Path $root 'independent-cleanup-audit.private.json') $c.ActorSid $result
[pscustomobject]@{Audit='PASS';Checks=$checks.Count;OriginalWorkerStatus=$w.Status;NoSqlOrGuestOperation=$true}|ConvertTo-Json -Compress
