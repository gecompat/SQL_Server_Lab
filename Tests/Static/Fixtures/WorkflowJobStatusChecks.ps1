#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo 'Tools/WorkflowUiJobStatus.ps1')
. (Join-Path $repo 'Tools/WorkflowUiJsonBody.ps1')
. (Join-Path $repo 'Tools/WorkflowUiCommandGrants.ps1')
$passed = 0
function Check($Value, [string]$Name) { if (-not $Value) { throw $Name }; $script:passed++; Write-Host "PASS: $Name" }
$root = Join-Path $repo ('.artifacts/test-runs/ui-job-status-' + [guid]::NewGuid().ToString('n'))
foreach ($kind in @('batches','operations')) { $null = New-Item -ItemType Directory -Path (Join-Path $root $kind) }
$record = [pscustomobject]@{ Id='batch-own'; Action='SetDataRoot'; StateRoot=$root; OperationIds=@('op-own','op-other'); StartedAt='2026-10-05T00:00:00Z'; HostStart='Requested'; TerminalSnapshot=$null }
function Write-SyntheticState([string[]]$States, $BatchStatus='Running') {
    $record.TerminalSnapshot=$null
    @{contract='SqlServerLab.Batch/1.0'; batchId='batch-own'; status=$BatchStatus; operationIds=@('op-own','op-other'); intent='PRIVATE_SYNTHETIC_SECRET'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'batches/batch-own.json')
    for ($index=0; $index -lt 2; $index++) {
        @{contract='SqlServerLab.Operation/1.0'; operationId=$record.OperationIds[$index]; batchId='batch-own'; status=$States[$index]; updatedAt='2026-10-05T00:00:03Z'; error='PRIVATE_SYNTHETIC_SECRET'; result=@{Path='private-path'}} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root ('operations/' + $record.OperationIds[$index] + '.json'))
    }
}
foreach ($case in @(
    @('Queued','Queued','Waiting'), @('Completed','Queued','Waiting'),
    @('WaitingForDependency','Queued','Waiting'), @('WaitingForUser','Queued','Blocked'),
    @('Paused','Queued','Blocked'), @('Running','Queued','Running'),
    @('Completed','Completed','Completed'), @('Completed','Failed','Failed'),
    @('Completed','Cancelled','Cancelled'), @('CleanupQueued','Completed','Waiting')
)) {
    Write-SyntheticState @($case[0],$case[1]); $view=Get-UiPersistentJobSnapshot $record
    Check ($view.State -ceq $case[2]) ("Actual operation mapping: $($case[0])/$($case[1]) -> $($case[2])")
    Check (($view | ConvertTo-Json -Depth 5) -notmatch 'PRIVATE_SYNTHETIC_SECRET|private-path|StateRoot|operationId') 'Fixed projection omits intents, raw errors, results and private paths'
}
Write-SyntheticState @('Queued','Queued') 'Draft'; Check ((Get-UiPersistentJobSnapshot $record).State -ceq 'Blocked') 'Draft batch is blocked, not active work'
Write-SyntheticState @('Queued','Queued') @('Running'); Check ((Get-UiPersistentJobSnapshot $record).State -ceq 'Unknown') 'Array batch status fails closed'
Write-SyntheticState @('Completed','Completed'); $null=Get-UiPersistentJobSnapshot $record
[IO.File]::WriteAllText((Join-Path $root 'operations/op-own.json'), '{invalid')
Check ((Get-UiPersistentJobSnapshot $record).State -ceq 'Completed') 'Terminal snapshot remains available after source damage'
$record.TerminalSnapshot=$null; Check ((Get-UiPersistentJobSnapshot $record).State -ceq 'Unknown') 'Unreadable operation makes status Unknown without exception leak'
Write-SyntheticState @('Queued','Queued')
$saved=[IO.File]::ReadAllText((Join-Path $root 'operations/op-own.json'))
[IO.File]::WriteAllText((Join-Path $root 'operations/op-own.json'), $saved.Replace('Queued','Unexpected'))
Check ((Get-UiPersistentJobSnapshot $record).State -ceq 'Unknown') 'Unknown operation status veto'
[IO.File]::WriteAllText((Join-Path $root 'operations/op-own.json'), $saved.Replace('"Queued"','["Running"]'))
Check ((Get-UiPersistentJobSnapshot $record).State -ceq 'Unknown') 'Array status cannot authorize Running'
Write-SyntheticState @('Queued','Queued')
$record.OperationIds=@('op-foreign'); Check ((Get-UiPersistentJobSnapshot $record).State -ceq 'Unknown') 'Changed batch membership vetoes foreign status'
$record.OperationIds=@('op-own','op-other')
$missing=Join-Path $root 'missing'
$record.StateRoot=$missing; Check ((Get-UiPersistentJobSnapshot $record).State -ceq 'Unknown') 'Absent source is Unknown'
Check (-not (Test-Path -LiteralPath $missing)) 'Status read does not initialize workflow directories'
$record.StateRoot=$root
Write-SyntheticState @('Running','Queued')
$before=@(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash })
$null=Get-UiPersistentJobSnapshot $record
$view=Get-UiPersistentJobSnapshot $record
Check ($view.LastActivityAt -ceq '2026-10-05T00:00:03.0000000Z') 'Activity time comes from actual persisted update, not polling clock'
$after=@(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash })
Check (($before -join ',') -ceq ($after -join ',')) 'Polling leaves actual synthetic state bytes unchanged'
$large=Join-Path $root 'operations/op-own.json'
[IO.File]::WriteAllText($large, ('x' * 1048577))
Check ((Get-UiPersistentJobSnapshot $record).State -ceq 'Unknown') 'Oversized operation read is bounded and Unknown'
Write-SyntheticState @('Running','Queued')
function Get-Item { param($LiteralPath, [switch]$Force, $ErrorAction) if ($LiteralPath -ceq $large) { [pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint} } else { Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force -ErrorAction Stop } }
try { Check ((Get-UiPersistentJobSnapshot $record).State -ceq 'Unknown') 'Actual source ancestor guard vetoes synthetic reparse leaf without opening it' } finally { Remove-Item -LiteralPath Function:Get-Item }

# Execute actual server route bodies with a synthetic batch leaf and synthetic host leaf.
# No listener, product action, provider or operation process is started.
$module = New-Module -Name SqlServerLab -ArgumentList $root -ScriptBlock {
    param($Root)
    $script:DefaultRoot=$Root; $script:HostRoots=@(); $script:FailHost=$true
    function Get-LabStateRoot { $script:DefaultRoot }
    function Start-SqlServerLabOperationHost { param($StateRoot) $script:HostRoots+=@($StateRoot); if ($script:FailHost) { throw 'PRIVATE_HOST_START_ERROR' } }
    function Submit-SqlServerLabBatch { param($BatchId) [pscustomobject]@{id=$BatchId} }
    $script:DraftCalls = [Collections.Generic.List[object]]::new()
    function Save-LabBrowserBatchDraft {
        param($Request,$StateRoot)
        $script:DraftCalls.Add([pscustomobject]@{Command=$Request.command;Root=$StateRoot})
        if ($Request.name -eq 'synthetic-failure') { throw 'PRIVATE_DRAFT_ERROR' }
        [pscustomobject]@{BatchId='batch-20261122203000-12345678';Status='Validated';Positions=3;Dependencies=1}
    }
    $script:BatchStopCalls = [Collections.Generic.List[object]]::new()
    function New-LabBrowserBatchStopPreview {
        param($BatchId,$StateRoot)
        $script:BatchStopCalls.Add([pscustomobject]@{Stage='Preview'; Batch=$BatchId; Root=$StateRoot})
        [pscustomobject]@{BatchId=$BatchId; PreviewId=('a'*32); Pending=2; Running=1}
    }
    function Invoke-LabBrowserBatchStopPreview {
        param($BatchId,$PreviewId,$StateRoot)
        $script:BatchStopCalls.Add([pscustomobject]@{Stage='Apply'; Batch=$BatchId; Root=$StateRoot; PreviewId=$PreviewId})
        [pscustomobject]@{BatchId=$BatchId; Requested=2}
    }
}
Import-Module $module
try {
    $server=Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'
    $tokens=$null; $errors=$null; $ast=[Management.Automation.Language.Parser]::ParseFile($server,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) 'Actual server parses'
    function Route([string]$Path) {
        $matches=@($ast.FindAll({param($Node) $Node -is [Management.Automation.Language.IfStatementAst] -and $Node.Clauses[0].Item1.Extent.Text.StartsWith("`$path -eq '$Path' -and")},$true))
        Check ($matches.Count -eq 1) "Actual route body uniquely extracted: $Path"
        [scriptblock]::Create('foreach($once in @(1)) ' + $matches[0].Clauses[0].Item2.Extent.Text)
    }
    function New-SqlServerLabBatch {
        param($StateRoot,$Name,$Items)
        $script:SubmittedRoot=$StateRoot
        & $module { $script:DefaultRoot='synthetic-new-default' }
        [pscustomobject]@{batchId='batch-own';operationIds=@('op-own','op-other')}
    }
    function Write-UiResponse { param($Context,$Body,$ContentType,$StatusCode=200) $script:ResponseBody=$Body; $script:ResponseCode=$StatusCode }
    $persistentJobs=@{}; $jobs=@{}
    $context=[pscustomobject]@{Request=[pscustomobject]@{InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"action":"SetDataRoot","parameters":{"DataRoot":"synthetic-new-default"}}'));ContentEncoding=[Text.Encoding]::UTF8}}
    & (Route '/api/actions')
    $accepted=$ResponseBody | ConvertFrom-Json
    Check ($ResponseCode -eq 202 -and $accepted.state -ceq 'Accepted' -and $accepted.hostStart -ceq 'Failed') 'Accepted response reports hoststart failure separately without claiming Running'
    Check ($SubmittedRoot -ceq $root -and $persistentJobs['batch-own'].StateRoot -ceq $root) 'NewBatch and accepted record bind the exact original root'
    Check ((& $module { $script:HostRoots[0] }) -ceq $root) 'Hoststart uses same bound root even if current default changes'
    & (Route '/api/jobs')
    $view=@($ResponseBody | ConvertFrom-Json)
    Check ($view.Count -eq 1 -and $view[0].Id -ceq 'batch-own' -and $view[0].State -ceq 'Running') 'Actual jobs route includes persistent batch from original root A after default becomes B'
    Check (($ResponseBody -notmatch 'PRIVATE_HOST_START_ERROR|StateRoot|synthetic-new-default')) 'Actual status route sanitizes source and host error details'
    $context.Request.InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"operationId":"op-own","command":"SubmitBatch","batchId":"batch-own"}'))
    & (Route '/api/operations')
    Check ($ResponseCode -eq 503 -and $ResponseBody -match '^OPERATION_HOST_START_FAILED:' -and $ResponseBody -notmatch 'PRIVATE_HOST') 'Operation control host failure is explicit, without rewriting queued operation state'
    & $module { $script:FailHost=$false }
    Check ((Invoke-UiOperationHostStart -StateRoot $root) -ceq 'Requested') 'Successful host request does not claim live worker or execution'

    & $module { param($Root) $script:DefaultRoot = $Root; $script:HostRoots = @() } $root
    $operationRoute = Route '/api/operations'
    $batchId = 'batch-20261122194200-01234567'
    function Invoke-BatchStopBody($RequestBody) {
        $context.Request.InputStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(($RequestBody | ConvertTo-Json -Compress)))
        & $operationRoute
    }
    Invoke-BatchStopBody @{command='BatchStopPreview';batchId=$batchId}
    $preview = $ResponseBody | ConvertFrom-Json
    Check ($ResponseCode -eq 200 -and $preview.Pending -eq 2 -and $preview.BatchId -ceq $batchId -and
        (& $module { $script:HostRoots.Count }) -eq 0) 'Batch stop preview uses bound authority without starting the operation host'
    Invoke-BatchStopBody @{command='BatchStopApply';batchId=$batchId;previewId=$preview.PreviewId;confirmed=$false}
    Check ($ResponseCode -eq 400 -and (& $module { $script:BatchStopCalls.Count }) -eq 1) 'Batch stop apply requires affirmative confirmation'
    Invoke-BatchStopBody @{command='BatchStopApply';batchId=$batchId;previewId=$preview.PreviewId;confirmed=$true;includeCompleted=$true}
    Check ($ResponseCode -eq 400 -and (& $module { $script:BatchStopCalls.Count }) -eq 1) 'Guided batch stop cannot widen scope to completed positions'
    Invoke-BatchStopBody @{command='BatchStopApply';batchId=$batchId;previewId=$preview.PreviewId;confirmed=$true}
    $result = $ResponseBody | ConvertFrom-Json
    $calls = @(& $module { $script:BatchStopCalls })
    Check ($ResponseCode -eq 200 -and $result.Requested -eq 2 -and $calls.Count -eq 2 -and
        $calls[1].PreviewId -ceq $preview.PreviewId -and $calls[1].Root -ceq $root -and
        (& $module { $script:HostRoots[0] }) -ceq $root) 'Confirmed batch stop and host request use the exact batch and root'
    & $module { $script:HostRoots = @() }
    Invoke-BatchStopBody @{command='StartOperationHost';confirmed=$false}
    Check ($ResponseCode -eq 400 -and (& $module { $script:HostRoots.Count }) -eq 0) 'Guided scheduler request without confirmation starts nothing'
    Invoke-BatchStopBody @{command='StartOperationHost';confirmed=$true;stateRoot='another-root'}
    Check ($ResponseCode -eq 400 -and (& $module { $script:HostRoots.Count }) -eq 0) 'Guided scheduler request cannot pick a different state root'
    Invoke-BatchStopBody @{command='StartOperationHost';confirmed=$true}
    Check ($ResponseCode -eq 202 -and ($ResponseBody | ConvertFrom-Json).state -ceq 'Requested' -and
        (& $module { $script:HostRoots.Count }) -eq 1 -and (& $module { $script:HostRoots[0] }) -ceq $root) 'Confirmed scheduler request resolves the server state root and reports only acceptance'
    & $module { $script:FailHost=$true }
    Invoke-BatchStopBody @{command='StartOperationHost';confirmed=$true}
    Check ($ResponseCode -eq 503 -and $ResponseBody -cnotmatch 'PRIVATE_HOST|StateRoot') 'Scheduler start failure carries neither a false success nor private details'

    & $module { $script:HostRoots = @() }
    $draftRoute = Route '/api/batches'
    $context.Request.InputStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(
        '{"command":"SaveGuidedDraft","name":"first","name":"duplicate","priority":"High","items":[{}]}'))
    & $draftRoute
    Check ($ResponseCode -eq 400 -and (& $module { $script:DraftCalls.Count }) -eq 0) 'Draft route rejects duplicate JSON before planning'
    $context.Request.InputStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(
        '{"command":"SaveGuidedDraft","name":"synthetic-failure","priority":"High","items":[{}]}'))
    & $draftRoute
    Check ($ResponseCode -eq 409 -and $ResponseBody -cnotmatch 'PRIVATE_DRAFT_ERROR') 'Draft route does not expose internal error details'
    $context.Request.InputStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(
        '{"command":"SaveGuidedDraft","name":"synthetic-draft","priority":"High","items":[{}]}'))
    & $draftRoute
    $draft = $ResponseBody | ConvertFrom-Json
    Check ($ResponseCode -eq 201 -and $draft.Status -ceq 'Validated' -and $draft.Positions -eq 3 -and
        (& $module { $script:DraftCalls[1].Root }) -ceq $root -and (& $module { $script:HostRoots.Count }) -eq 0) 'Draft request binds the server root and never starts the operation host'
} finally { Remove-Module $module -Force }
Write-Host "RESULT: $passed PASS; real actions/hosts/providers/listeners=0; synthetic evidence retained in ignored test scope"
