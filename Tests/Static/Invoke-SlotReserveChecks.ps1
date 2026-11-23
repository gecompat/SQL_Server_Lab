#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Private/LabPreferences.ps1')
. (Join-Path $repoRoot 'Private/ArtifactResolver.ps1')
. (Join-Path $repoRoot 'Private/SlotReserveGuidance.ps1')
. (Join-Path $repoRoot 'Private/WindowsPoolClaims.ps1')
. (Join-Path $repoRoot 'Private/BatchWorkflow.ps1')
. (Join-Path $repoRoot 'Private/SqlGuestEvaluationEvidence.ps1')
. (Join-Path $repoRoot 'Public/Invoke-SqlServerLabWorkflowAction.ps1')
function Get-LabTimestamp { [datetime]::UtcNow.ToString('o') }
$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$leaf='sql-lab-slot-policy-'+[guid]::NewGuid().ToString('N')
$fixture=Join-Path $tempParent $leaf
$null=New-Item -ItemType Directory -Path $fixture
$script:PreferenceTestPath=Join-Path $fixture 'preferences.json'
function Get-LabProjectPreferencesPath { $script:PreferenceTestPath }
$count=0
function Assert-Policy($Condition,$Name) { if (-not $Condition) { throw "ASSERT: $Name" }; $script:count++ }
$policy=@{WindowsReserve=0;SqlReserve=0;MinimumDaysRemaining=45;WarningDaysRemaining=10}
try {
    Assert-Policy ((Get-LabSlotReserveState).Status -eq 'MISSING') 'missing separate'
    $plan=(Invoke-SqlServerLabWorkflowAction -Action PlanSlotReserve -SlotReservePolicy $policy).Result
    Assert-Policy (-not (Test-Path $script:PreferenceTestPath)) 'preview no file'
    $null=Invoke-LabSlotReservePlan -Plan $plan -WhatIf
    Assert-Policy (-not (Test-Path $script:PreferenceTestPath)) 'whatif no file'
    $rejected=$false; try { Invoke-SqlServerLabWorkflowAction -Action ApplySlotReserve -SlotReservePlan $plan } catch { $rejected=$true }
    Assert-Policy $rejected 'explicit confirmation'
    $result=Invoke-SqlServerLabWorkflowAction -Action ApplySlotReserve -SlotReservePlan $plan -ConfirmSlotReserve
    Assert-Policy ($result.Result.Policy.WindowsReserve -eq 0 -and $result.Result.Policy.MinimumDaysRemaining -eq 45 -and $result.Result.Policy.WarningDaysRemaining -eq 10) 'zero and independent thresholds'
    Assert-Policy (New-LabSlotReservePlan -Policy $policy).IsNoOp 'noop'
    & {
        $noOpPlan=New-LabSlotReservePlan -Policy $policy
        $realLock=${function:Invoke-WithLabPreferencesLock}
        function Invoke-WithLabPreferencesLock {
            param($Path,$Body)
            $changed=Get-LabPreferencesSnapshot
            $changed.Document['interleaved']='synthetic'
            Write-LabArtifactJsonAtomic -Path $changed.Path -InputObject $changed.Document
            & $realLock -Path $Path -Body $Body
        }
        $rejected=$false;try{Invoke-LabSlotReservePlan $noOpPlan -Confirm:$false}catch{$rejected=$_.Exception.Message -eq 'PREFERENCES_PREVIEW_STALE'}
        Assert-Policy $rejected 'noop revalidates predecessor after lock acquisition'
    }
    Set-LabProjectPreferenceValue -Name mediaRoot -Value 'synthetic-media'
    Assert-Policy ((Get-LabSlotReserveState).Policy.SqlReserve -eq 0 -and (Get-LabProjectPreferenceValue mediaRoot) -eq 'synthetic-media') 'string writer preserves policy'
    $stale=New-LabSlotReservePlan -Policy $policy
    Set-LabProjectPreferenceValue -Name unrelated -Value 'keep'
    $rejected=$false; try { Invoke-LabSlotReservePlan $stale -Confirm:$false } catch { $rejected=$_.Exception.Message -eq 'PREFERENCES_PREVIEW_STALE' }
    Assert-Policy $rejected 'stale content rejected'
    $stale=New-LabSlotReservePlan -Policy $policy
    $script:PreferenceTestPath=Join-Path $fixture 'other.json'
    $rejected=$false; try { Invoke-LabSlotReservePlan $stale -Confirm:$false } catch { $rejected=$true }
    Assert-Policy ($rejected -and -not (Test-Path $script:PreferenceTestPath)) 'authority drift rejected'
    $script:PreferenceTestPath=Join-Path $fixture 'preferences.json'
    $before=[IO.File]::ReadAllText($script:PreferenceTestPath)
    $writer=${function:Write-LabArtifactJsonAtomic}
    function Write-LabArtifactJsonAtomic { throw 'SYNTHETIC_WRITE_FAILURE' }
    try { Set-LabProjectPreferenceValue -Name unrelated -Value 'bad' } catch { }
    Set-Item Function:Write-LabArtifactJsonAtomic $writer
    Assert-Policy ([IO.File]::ReadAllText($script:PreferenceTestPath) -ceq $before) 'aborted write preserves predecessor'
    $readerReady = Join-Path $fixture 'reader-at-lock.marker'
    $readerCustody = [pscustomobject]@{ Job = $null }
    try {
        Invoke-WithLabPreferencesLock -Path $script:PreferenceTestPath -Body {
            $readerCustody.Job = Start-Job -ArgumentList $repoRoot,$script:PreferenceTestPath,$readerReady -ScriptBlock {
                param($repo,$target,$ready)
                $ErrorActionPreference = 'Stop'
                . (Join-Path $repo 'Private/LabPreferences.ps1')
                $realAuthorityLock = ${function:Invoke-WithLabPreferencesAuthorityLock}
                function Invoke-WithLabPreferencesAuthorityLock {
                    param($CanonicalPath,$Body)
                    [IO.File]::WriteAllText($ready,'attempted')
                    & $realAuthorityLock -CanonicalPath $CanonicalPath -Body $Body
                }
                (Get-LabPreferencesSnapshot -Path $target).Document['readerObservation']
            }
            $startupDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $readerReady -PathType Leaf) -and
                $readerCustody.Job.State -cin @('NotStarted','Running') -and [DateTime]::UtcNow -lt $startupDeadline) {
                Start-Sleep -Milliseconds 25
            }
            Assert-Policy ((Test-Path -LiteralPath $readerReady -PathType Leaf) -and $readerCustody.Job.State -ceq 'Running') 'reader reaches the same held authority lock'
            $document = (Get-LabPreferencesSnapshot).Document
            $document['readerObservation'] = 'after-replacement'
            Write-LabArtifactJsonAtomic -Path $script:PreferenceTestPath -InputObject $document
        }
        $null = Wait-Job $readerCustody.Job -Timeout 15
        Assert-Policy ($readerCustody.Job.State -ceq 'Completed') 'reader finishes after writer releases'
        $observed = Receive-Job $readerCustody.Job -ErrorAction Stop
        Assert-Policy ($observed -ceq 'after-replacement') 'reader sees exactly the committed successor'
    }
    finally {
        if ($readerCustody.Job) {
            Stop-Job $readerCustody.Job
            Remove-Job $readerCustody.Job
        }
    }
    $jobs=@(1..4 | ForEach-Object { Start-Job -ArgumentList $repoRoot,$script:PreferenceTestPath,$_ -ScriptBlock {
        param($repo,$target,$index)
        $ErrorActionPreference='Stop'
        . (Join-Path $repo 'Private/LabPreferences.ps1'); . (Join-Path $repo 'Private/ArtifactResolver.ps1')
        function Get-LabProjectPreferencesPath { $target }
        function Get-LabTimestamp { [datetime]::UtcNow.ToString('o') }
        try { Set-LabProjectPreferenceValue -Name ('writer'+$index) -Value ('synthetic'+$index) }
        catch {
            if ($_.Exception.Message -cmatch '^PREFERENCES_[A-Z_]+$') { throw }
            $cause = $_.Exception
            while ($cause.InnerException) { $cause = $cause.InnerException }
            throw ('PREFERENCES_WRITER_HRESULT_' + $cause.HResult.ToString('X8'))
        }
    } })
    $null=$jobs | Wait-Job -Timeout 30
    try {
        $incomplete=@($jobs | Where-Object { $_.State -ne 'Completed' })
        if ($incomplete.Count -gt 0) {
            # Capture privacy-safe child failure evidence before Stop/Remove-Job destroys it.
            # Keep the deadline and completion requirement: a timeout is never a passed writer.
            $diagnostics=@(foreach($job in $incomplete) {
                $children=@($job.ChildJobs)
                $errors=@($children | ForEach-Object { $_.Error } | Where-Object { $_ })
                $reasons=@(@($job.JobStateInfo.Reason) + @($children | ForEach-Object { $_.JobStateInfo.Reason }) | Where-Object { $_ })
                [ordered]@{
                    State=[string]$job.State
                    ChildStates=@($children | ForEach-Object { [string]$_.State })
                    ExceptionTypes=@(@($errors | ForEach-Object { $_.Exception.GetType().Name }) + @($reasons | ForEach-Object { $_.GetType().Name }) | Sort-Object -Unique)
                    PreferenceCodes=@($errors | ForEach-Object { if ($_.Exception.Message -cmatch '^PREFERENCES_[A-Z0-9_]+$') { $_.Exception.Message } } | Sort-Object -Unique)
                }
            })
            throw ('PARALLEL_WRITER_NOT_COMPLETED: '+($diagnostics | ConvertTo-Json -Depth 6 -Compress))
        }
        foreach($job in $jobs) { Assert-Policy ($job.State -eq 'Completed') 'parallel writer completed'; Receive-Job $job -ErrorAction Stop | Out-Null }
    }
    finally { $jobs | Stop-Job; $jobs | Remove-Job }
    $document=(Get-LabPreferencesSnapshot).Document
    Assert-Policy (@(1..4 | Where-Object { $document['writer'+$_] -eq ('synthetic'+$_) }).Count -eq 4 -and $document.unrelated -eq 'keep' -and $document.slotReservePolicy.WindowsReserve -eq 0) 'parallel merges preserve every key'
    foreach($invalid in @('null','[]','42','{broken')) {
        [IO.File]::WriteAllText($script:PreferenceTestPath,$invalid)
        $rejected=$false; try { Set-LabProjectPreferenceValue -Name mediaRoot -Value 'bad' } catch { $rejected=$_.Exception.Message -eq 'PREFERENCES_INVALID' }
        Assert-Policy ($rejected -and [IO.File]::ReadAllText($script:PreferenceTestPath) -ceq $invalid) 'invalid preferences unchanged'
    }
    [IO.File]::WriteAllText($script:PreferenceTestPath,'{"slotReservePolicy":{"WindowsReserve":0}}')
    Assert-Policy ((Get-LabSlotReserveState).Status -eq 'INVALID') 'partial policy not zero'
    $rejected=$false; try { New-LabSlotReservePlan $policy } catch { $rejected=$true }
    Assert-Policy $rejected 'invalid policy cannot repair implicitly'
    foreach($invalid in @(@{WindowsReserve='0';SqlReserve=0;MinimumDaysRemaining=1;WarningDaysRemaining=1},@{WindowsReserve=-1;SqlReserve=0;MinimumDaysRemaining=1;WarningDaysRemaining=1})) {
        $rejected=$false; try { ConvertTo-LabSlotReservePolicy $invalid } catch {$rejected=$true}; Assert-Policy $rejected 'typed ranges'
    }
    [IO.File]::WriteAllText($script:PreferenceTestPath,'{}')
    $null=Invoke-LabSlotReservePlan (New-LabSlotReservePlan $policy) -Confirm:$false
    function Get-LabStateRoot { Join-Path $fixture 'absent-state' }
    function Get-LabActiveRuns { @() }
    $inventory=Get-LabSlotReserveInventory
    Assert-Policy ($null -eq $inventory.VerifiedAvailable -and $null -eq $inventory.Deficit -and $inventory.Recommendation -eq 'NO_RESERVE_REQUESTED' -and -not (Test-Path (Get-LabStateRoot))) 'empty inventory not healthy and no state mutation'
    & {
        $id='11111111-1111-4111-8111-111111111111'
        function Get-LabActiveRuns {
            1..5 | ForEach-Object { [pscustomobject]@{runId=('11111111-1111-4111-8111-'+($_).ToString('000000000000'));state='STOPPED';metadata=@{workflowKind='hyperv-lab'}} }
        }
        function Get-LabStateRoot { $fixture }
        function Test-LabPathWithinRoot { [pscustomobject]@{Valid=$true} }
        function Test-Path { param($LiteralPath,$PathType) $true }
        function Get-ChildItem { [pscustomobject]@{FullName=(Join-Path $fixture 'operations/synthetic.json')} }
        function Get-Content {
            param($LiteralPath,[switch]$Raw,$ErrorAction)
            if ($LiteralPath -like '*operations*') { return '{"runId":"11111111-1111-4111-8111-000000000002","status":"Running"}' }
            $expiry=if ($LiteralPath -like '*000000000001*') { [datetime]::UtcNow.AddDays(-1).ToString('o') } else { [datetime]::UtcNow.AddDays(5).ToString('o') }
            @{instances=@(@{provider='hyperv';workload=$(if($LiteralPath -match '00000000000[45]'){'sql'}else{'windows'});windowsActivation=@{evaluationExpiresAt=$expiry}})} | ConvertTo-Json -Depth 6
        }
        function Get-LabSqlGuestEvaluationEvidence {
            param($RunId)
            @{Status='VALID';RunId=$RunId;InstanceId='primary';Evidence=@{
                EvidenceFreshUntil=$(if($RunId -like '*000000000004'){[datetime]::UtcNow.AddDays(-1).ToString('o')}else{[datetime]::UtcNow.AddDays(1).ToString('o')})
                LicenseClassification='EVALUATION';DeadlineSource='SQL_GUEST_OBSERVED';EvaluationExpiresAt=[datetime]::UtcNow.AddDays(5).ToString('o')
            }}
        }
        # Keep real policy reader outside synthetic path adapters.
        function Get-LabSlotReserveState { @{Status='CONFIGURED';Policy=@{WindowsReserve=2;SqlReserve=1;MinimumDaysRemaining=10;WarningDaysRemaining=3}} }
        $view=Get-LabSlotReserveInventory
        Assert-Policy ($view.CandidateCount -eq 5 -and $null -eq $view.Deficit -and $null -eq $view.VerifiedAvailable) 'candidates never free or exact deficit'
        Assert-Policy ($view.Rows[0].WindowsLifetime -eq 'EXPIRED' -and $view.Rows[1].Allocation -eq 'OPERATION_BOUND' -and $view.Rows[2].WindowsLifetime -eq 'BELOW_MINIMUM' -and $view.Rows[2].Warning -eq 'NOT_EVALUATED') 'stopped expired bound and independent thresholds'
        Assert-Policy ($view.Rows[3].SqlLifetime -eq 'UNKNOWN' -and $view.Rows[3].SqlEvidence -eq 'EVIDENCE_STALE') 'SQL evidence distinct'
        Assert-Policy ($view.Rows[4].SqlLifetime -eq 'OK' -and $view.Rows[4].SqlEvidence -eq 'CURRENT' -and $view.Rows[4].SqlMinimum -eq 'BELOW_MINIMUM') 'real SQL projection separates fresh evidence, warning and minimum'
    }
    . (Join-Path $repoRoot 'Private/ConsoleUi.ps1')
    $realMenu=${function:Invoke-LabConsoleMenu}
    & {
        $script:menuVisits=0; $script:inputIndex=0
        function Get-LabSlotReserveInventory { @{Configuration=@{Status='CONFIGURED'};CandidateCount=0;Notice='synthetic'} }
        function Invoke-LabConsoleMenu {
            param($ScreenId,$Title,$Subtitle,$Items)
            $script:menuVisits++
            if($script:menuVisits -eq 1) { return @{Status='Refresh'} }
            & $realMenu -ScreenId $ScreenId -Title $Title -Items $Items -ForceFallback -ReadInput $(if($script:menuVisits -eq 2){{'1'}}else{{'0'}})
        }
        function Read-LabConsoleTextInput { $values=@('1','2','45','10'); $value=$values[$script:inputIndex]; $script:inputIndex++; @{Status='Confirmed';Value=$value} }
        function Read-LabConfirm { $false }
        function Wait-LabConsoleAcknowledgement { }
        $before=[IO.File]::ReadAllText($script:PreferenceTestPath)
        Show-LabSlotReserveInteractive
        Assert-Policy ($script:menuVisits -eq 3 -and $script:inputIndex -eq 4 -and [IO.File]::ReadAllText($script:PreferenceTestPath) -ceq $before) 'real fallback1 and F5 return to dialog; cancel preserves policy'
        $script:menuVisits=1; $script:inputIndex=0
        function Read-LabConfirm { $true }
        function Write-LabInfo { }
        Show-LabSlotReserveInteractive
        Assert-Policy ((Get-LabSlotReserveState).Policy.SqlReserve -eq 2) 'CLI confirmed core apply'
    }
    & {
        $script:poolRequests = [Collections.Generic.List[object]]::new()
        $script:poolFeatureStatus = 'Confirmed'
        $memberView = @{ Rows=@([pscustomobject]@{ Reference='synthetic-run'; PoolId='synthetic-pool'; MemberState='CLAIMED'; Evidence='CURRENT' }) }
        function Invoke-LabConsoleMenu {
            param($ScreenId,$Title,$Items)
            $id = @{ 'windows-pool-member'='synthetic-run'; 'windows-pool-operation'='Consume'; 'windows-pool-sql-version'='2022'; 'windows-pool-sql-edition'='Eval' }[$ScreenId]
            @{ Status='Selected'; SelectedItem=($Items | Where-Object Id -CEQ $id) }
        }
        function Read-LabConsoleTextInput {
            param($Prompt,$Default)
            $value = if ($Default) { if ($Default -eq '4') { '6' } else { '8192' } } else { ' SQL/2022/Eval/setup.iso ' }
            @{ Status='Confirmed'; Value=$value }
        }
        function Invoke-LabConsoleMultiSelect {
            param($ScreenId,$Title,$Items,$SelectedIds)
            @{ Status=$script:poolFeatureStatus; SelectedItems=@($Items | Where-Object Id -CEQ 'REPLICATION') }
        }
        function Read-LabConfirm { $false }
        function Wait-LabConsoleAcknowledgement { }
        function Invoke-SqlServerLabWorkflowAction {
            param($Action,$RunId,$SlotReserveOperation,$SlotReserveSqlPlan,$SlotReservePreviewId)
            $script:poolRequests.Add([pscustomobject]@{ Action=$Action; RunId=$RunId; Operation=$SlotReserveOperation; Plan=$SlotReserveSqlPlan; Id=$SlotReservePreviewId })
            @{ Result=@{ PreviewId='held-token' } }
        }
        Show-LabWindowsPoolMemberInteractive -View $memberView
        $plan = $script:poolRequests[0].Plan
        Assert-Policy ($script:poolRequests.Count -eq 2 -and $script:poolRequests[0].Operation -ceq 'Consume' -and
            $plan.SqlVersion -ceq '2022' -and $plan.MediaEdition -ceq 'Eval' -and $plan.SqlMediaPath -ceq 'SQL/2022/Eval/setup.iso' -and
            ($plan.SqlFeatures -join ',') -ceq 'SQLENGINE,REPLICATION' -and $plan.ProcessorCount -eq 6 -and $plan.MemoryStartupMB -eq 8192 -and
            $script:poolRequests[1].Action -ceq 'CancelWindowsPoolMember' -and $script:poolRequests[1].Id -ceq 'held-token') 'guided CLI binds SQL edition, optional features and resources to the preview'
        $script:poolRequests.Clear()
        $script:poolFeatureStatus = 'Cancelled'
        Show-LabWindowsPoolMemberInteractive -View $memberView
        Assert-Policy ($script:poolRequests.Count -eq 0) 'cancel during SQL feature selection sends no preview or mutation'
    }
    & {
        . (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1')
        . (Join-Path $repoRoot 'Public/BatchConsole.ps1')
        function Test-HyperVAvailable { @{Available=$false;Message='synthetic unavailable'} }
        function Show-LabSubMenu { param($ScreenId,$Title,$Subtitle,$Items) return ,$Items }
        $configuration=Show-LabConfigurationMenu
        $templates=Show-LabHyperVMenu
        $choice=& $realMenu -ScreenId slot-reserve -Title synthetic -Items $configuration -ForceFallback -ReadInput {'7'}
        $script:dispatchCount=0
        function Show-LabSlotReserveInteractive { $script:dispatchCount++ }
        Invoke-LabAction -ActionName $choice.SelectedItem.Id
        Assert-Policy ($script:dispatchCount -eq 1 -and @($templates | Where-Object { $_.Id -eq 'ReservePolicy' -and -not $_.Disabled }).Count -eq 1) 'actual configuration shortcut and dispatcher; templates independent of HyperV'
    }
    . (Join-Path $repoRoot 'Tools/WorkflowUiJsonBody.ps1')
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tools/Start-SqlServerLabUi.ps1'),[ref]$null,[ref]$null)
    $requestFunction=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-UiSlotReserveRequest'},$true)
    Invoke-Expression $requestFunction.Extent.Text
    function New-ReserveRequest($Payload,$Origin='http://127.0.0.1:8484') {
        @{HttpMethod='POST';ContentType='application/json';Headers=@{Origin=$Origin};Url=[uri]'http://127.0.0.1:8484/api/slot-reserve';ContentEncoding=[Text.Encoding]::UTF8;InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(($Payload|ConvertTo-Json -Depth 12)))}
    }
    $httpPlan=(Invoke-UiSlotReserveRequest (New-ReserveRequest @{action='PlanSlotReserve';parameters=@{SlotReservePolicy=$policy}})).Result
    Assert-Policy ($httpPlan.Policy.WindowsReserve -eq 0) 'real HTTP preview'
    foreach($request in @(
        (New-ReserveRequest @{action='PlanSlotReserve';parameters=@{SlotReservePolicy=$policy}} 'https://foreign.invalid'),
        (New-ReserveRequest @{action='ApplySlotReserve';parameters=@{SlotReservePlan=$httpPlan;ConfirmSlotReserve='true'}}),
        (New-ReserveRequest @{action='RefreshSetupProvider';parameters=@{SetupProvider='hyperv'}}),
        (New-ReserveRequest @{action='PlanSlotReserve';parameters=@{SlotReservePolicy=$policy;StateRoot='synthetic'}})
    )) { $rejected=$false; try { Invoke-UiSlotReserveRequest $request } catch {$rejected=$true}; Assert-Policy $rejected 'HTTP boundary' }
    $null=Invoke-UiSlotReserveRequest (New-ReserveRequest @{action='ApplySlotReserve';parameters=@{SlotReservePlan=$httpPlan;ConfirmSlotReserve=$true}})
    Assert-Policy ((Get-LabSlotReserveState).Policy.SqlReserve -eq 0) 'real HTTP apply'
    Write-Host "Slot Reserve Checks: $count PASS"
}
finally {
    # Only flat, newly-created synthetic files; bind cleanup to the exact saved parent and GUID leaf.
    $actual=Get-Item -LiteralPath $fixture -Force
    if ($actual.FullName -cne [IO.Path]::GetFullPath((Join-Path $tempParent $leaf)) -or $actual.Parent.FullName.TrimEnd('\','/') -cne $tempParent -or $actual.Name -cne $leaf -or ($actual.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'FIXTURE_CLEANUP_BINDING' }
    foreach($file in Get-ChildItem -LiteralPath $actual.FullName -Force) {
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.DirectoryName -cne $actual.FullName) { throw 'FIXTURE_CLEANUP_CONTENT' }
        Remove-Item -LiteralPath $file.FullName -Force
    }
    Remove-Item -LiteralPath $actual.FullName -Force
}
