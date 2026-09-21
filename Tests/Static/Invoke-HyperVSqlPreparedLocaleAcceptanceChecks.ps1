#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-prepared-locale-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        param($Repo,$Root)
        . (Join-Path $Repo 'Tests/Common/HyperVPreparedLocaleAcceptance.ps1')
        $script:count=0
        function Check {
            param([bool]$Condition,[string]$Name)
            if (-not $Condition) { throw "PREPARED_LOCALE_CHECK_FAILED: $Name" }
            $script:count++
            Write-Host "PASS: $Name"
        }
        function Reject {
            param([scriptblock]$Action,[string]$Code)
            $caught=''
            try { & $Action | Out-Null } catch { $caught=$_.Exception.Message }
            Check ($caught -match $Code) "Rejected $Code (actual: $caught)"
        }
        $id='hyperv-sql-prepared-sealed-'+('a'*64)
        $dispatch=[pscustomobject]@{
            EventName='workflow_dispatch';Repository='synthetic/repository';EventRepository='synthetic/repository'
            ExpectedCommit=('a'*40);CheckoutCommit=('a'*40);ArtifactId=$id;CloneSourceRunId=''
        }
        Assert-HyperVPreparedLocaleDispatch $dispatch
        Check $true 'Trusted exact-commit manual dispatch accepted'
        foreach ($case in @('event','repository','commit','short','artifact','clone')) {
            $changed=$dispatch | ConvertTo-Json | ConvertFrom-Json
            switch ($case) {
                event {$changed.EventName='pull_request'}
                repository {$changed.EventRepository='foreign/repository'}
                commit {$changed.CheckoutCommit='b'*40}
                short {$changed.ExpectedCommit='aaaaaaa';$changed.CheckoutCommit='aaaaaaa'}
                artifact {$changed.ArtifactId='latest'}
                clone {$changed.CloneSourceRunId=[guid]::NewGuid().ToString()}
            }
            Reject {Assert-HyperVPreparedLocaleDispatch $changed} 'PREPARED_LOCALE_'
        }
        $manifest=New-HyperVPreparedLocaleManifest -ArtifactId $id -OperationId ([guid]::NewGuid().ToString())
        $null=New-Item -ItemType Directory -Path $Root
        $manifestPath=Join-Path $Root 'manifest.json'
        $manifest | ConvertTo-Json -Depth 20 | Set-Content $manifestPath -Encoding utf8
        Check ((Test-SqlServerLabManifest -Path $manifestPath).IsValid) 'Real manifest schema accepts explicit Prepared artifact, US locale and activation'
        Check ($manifest.instances[0].windowsActivation.Strategy -ceq 'EvaluationOnline' -and
            $manifest.instances[0].windowsActivation.EgressPolicy -ceq 'AllowTemporary') 'Manifest uses existing temporary evaluation activation contract'
        function Get-WinHomeLocation {[pscustomobject]@{GeoId=244}}
        function Get-WinSystemLocale {'en-US'}
        function Get-WinUILanguageOverride {'en-US'}
        function Get-WinDefaultInputMethodOverride {[pscustomobject]@{InputMethodTip='0409:00000409'}}
        function Get-TimeZone {[pscustomobject]@{Id='Pacific Standard Time'}}
        $script:observation=& (Get-HyperVPreparedLocaleGuestProbe)
        Assert-HyperVPreparedLocaleObservation $script:observation
        Check $true 'Actual guest probe executes all five locale observations'
        foreach ($field in @('GeoId','SystemLocale','UiLanguage','InputLocale','TimeZone')) {
            $wrong=$script:observation | ConvertTo-Json | ConvertFrom-Json
            $wrong.$field=if($field -eq 'GeoId'){94}else{'wrong'}
            Reject {Assert-HyperVPreparedLocaleObservation $wrong} 'GUEST_MISMATCH'
        }
        function Reset-Fixture {
            $script:binding=@{
                OperationId=[guid]::NewGuid().ToString();RunId=[guid]::NewGuid().ToString()
                ScopeId=[guid]::NewGuid().ToString();VmId=[guid]::NewGuid().ToString();StateRoot=$Root
            }
            $script:owned=[pscustomobject]@{
                runId=$script:binding.RunId;scopeId=$script:binding.ScopeId
                metadata=[pscustomobject]@{workflowOperationId=$script:binding.OperationId}
            }
            $script:context=[pscustomobject]@{
                Run=$script:owned;RunDirectory=$Root;StateRoot=$Root
                Instance=[pscustomobject]@{
                    vmId=$script:binding.VmId;vmName='synthetic-own-vm';windowsLocale=$manifest.instances[0].windowsLocale
                    sqlReadiness=[pscustomobject]@{instanceName='MSSQLSERVER';edition='Developer Edition'}
                }
            }
            $script:managed=[pscustomobject]@{
                VM=[pscustomobject]@{Id=[guid]$script:binding.VmId;State='Running'}
                Identity=[pscustomobject]@{instanceId='primary';childVhdxPath=$null;additionalVhdxPaths=@()}
            }
            $script:events=[Collections.Generic.List[string]]::new()
            $script:afterStop=$null;$script:guestFailure=$false;$script:sqlFailure=$false
            $script:sqlMajor=17;$script:removeDone=$false;$script:vmRemains=$false;$script:sqlReads=0
            $script:parentChanged=$false;$script:parentReads=0;$script:failNew=$false;$script:arranged=$true
            $script:artifactInvalid=$false
        }
        function Get-LabOperationOwnedRun {param($OperationId,$StateRoot) if($script:arranged){$script:owned}}
        function Get-HyperVLabWorkflowRun {param($RunId,$StateRoot)$script:context}
        function Get-HyperVManagedVM {param($VMName,$ExpectedRunId,$ExpectedScopeId)$script:managed}
        function Stop-SqlServerLab {
            param($RunId,$StateRoot,[switch]$Force,[switch]$Confirm)
            $script:events.Add('STOP');$script:managed.VM.State='Off'
            if($script:afterStop){& $script:afterStop}
        }
        function Start-HyperVLabEnvironment {
            param($RunId,$StateRoot)
            $script:events.Add('START');$script:managed.VM.State='Running'
        }
        function Get-LabSecret {param($Path,$Name)[Security.SecureString]::new()}
        function Invoke-HyperVPowerShellDirect {
            param($VMName,$ExpectedRunId,$ExpectedScopeId,[guid]$ExpectedVmId,$Credential,$TimeoutSeconds,$ScriptBlock)
            Check ($ExpectedVmId -eq [guid]$script:binding.VmId -and $ExpectedRunId -ceq $script:binding.RunId -and
                $ExpectedScopeId -ceq $script:binding.ScopeId -and $TimeoutSeconds -le 30) 'Guest invocation carries exact VM/run/scope IDs and bounded timeout'
            if($script:guestFailure){throw 'PREPARED_LOCALE_GUEST_MISMATCH'}
            & $ScriptBlock
        }
        function Get-LabSqlGuestCaptureContext {param($RunId,$StateRoot)$script:context}
        function Invoke-LabSqlGuestCaptureProbe {
            param($Context,$TimeoutSeconds)
            $script:sqlReads++
            if($script:sqlFailure){throw 'SQL_GUEST_CAPTURE_PROBE_FAILED'}
            [pscustomobject]@{MajorVersion=$script:sqlMajor;InstanceName='MSSQLSERVER';Edition='Developer Edition'}
        }
        function Get-HyperVLabVMs {
            param($RunId,$ScopeId)
            if(-not $script:removeDone){[pscustomobject]@{VMName='synthetic-own-vm'}}
        }
        function Remove-SqlServerLab {
            param($RunId,$StateRoot,[switch]$Force,[switch]$Confirm)
            $script:events.Add('REMOVE');$script:removeDone=$true
            [pscustomobject]@{Status='REMOVED';Cleanup='CLEANUP_SUCCEEDED'}
        }
        function Get-VM {param([guid]$Id)if($script:vmRemains){$script:managed.VM}}
        Reset-Fixture
        $null=Invoke-HyperVPreparedLocaleColdStart -Binding $script:binding
        $null=Wait-HyperVPreparedLocaleGuest -Binding $script:binding
        $null=Wait-HyperVPreparedLocaleSql -Binding $script:binding
        Check (($script:events -join ',') -ceq 'STOP,START' -and $script:sqlReads -eq 1) 'Cold stop/start and real SQL probe boundary execute in order'
        foreach ($case in @('missing','swapped','operation','scope','connection')) {
            Reset-Fixture
            switch($case){
                missing {$script:binding.VmId=''}
                swapped {$script:managed.VM.Id=[guid]::NewGuid()}
                operation {$script:owned.metadata.workflowOperationId='foreign'}
                scope {$script:binding.ScopeId=[guid]::NewGuid().ToString()}
                connection {$script:context.Instance.vmId=[guid]::NewGuid().ToString()}
            }
            Reject {Invoke-HyperVPreparedLocaleColdStart -Binding $script:binding} 'PREPARED_LOCALE_'
            Check ($script:events.Count -eq 0) "$case rejected before any stop or start"
        }
        Reset-Fixture
        $script:afterStop={$script:managed.VM.Id=[guid]::NewGuid()}
        Reject {Invoke-HyperVPreparedLocaleColdStart -Binding $script:binding} 'VM_ID_MISMATCH'
        Check (($script:events -join ',') -ceq 'STOP') 'VM replacement between stop and start prevents start'
        Reset-Fixture;$script:sqlMajor=16
        Reject {Wait-HyperVPreparedLocaleSql -Binding $script:binding} 'SQL_IDENTITY_MISMATCH'
        Reset-Fixture;$script:sqlFailure=$true
        Reject {Wait-HyperVPreparedLocaleSql -Binding $script:binding -TimeoutSeconds 1} 'SQL_TIMEOUT'
        Check ($script:sqlReads -gt 0 -and $script:sqlReads -le 3) 'Unavailable SQL has a bounded readiness timeout'
        Reset-Fixture
        Remove-HyperVPreparedLocaleOwnRun @script:binding
        Check $script:removeDone 'Own cleanup verifies absence of exact recorded VM ID'
        Reset-Fixture;$script:vmRemains=$true
        Reject {Remove-HyperVPreparedLocaleOwnRun @script:binding} 'CLEANUP_VM_REMAINS'
        Reset-Fixture;$script:owned.metadata.workflowOperationId='foreign'
        Reject {Remove-HyperVPreparedLocaleOwnRun @script:binding} 'CLEANUP_OPERATION_MISMATCH'
        Check (-not $script:removeDone) 'Operation mismatch never calls removal'
        Reset-Fixture;$script:managed.VM.Id=[guid]::NewGuid()
        Reject {Remove-HyperVPreparedLocaleOwnRun @script:binding} 'CLEANUP_VM_MISMATCH'
        Check (-not $script:removeDone) 'Changed cleanup VM identity never calls removal'
        function Get-HyperVImageArtifact {
            param($ArtifactId,$StateRoot)
            [pscustomobject]@{
                artifactState='SQL_PREPARED_SEALED';sql=[pscustomobject]@{version='2025'}
                operatingSystem=[pscustomobject]@{language=if($script:artifactInvalid){'de-DE'}else{'en-US'}}
                integrityVerification=[pscustomobject]@{status='VERIFIED_HASH'}
                Path=(Join-Path $Root 'synthetic-parent.vhdx');sha256=('a'*64)
            }
        }
        function Get-FileHash {
            param($LiteralPath,$Algorithm)
            $script:parentReads++
            [pscustomobject]@{Hash=if($script:parentChanged -and $script:parentReads -gt 1){'b'*64}else{'a'*64}}
        }
        function New-HyperVSqlUnattendedPassword {[Security.SecureString]::new()}
        function New-SqlServerLab {
            param($Manifest,$GuestPassword,$SqlSaPassword,$StateRoot,[switch]$NonInteractive)
            $script:arranged=$true
            if($script:failNew){throw 'SYNTHETIC_NEW_RESPONSE_LOST'}
            [pscustomobject]@{
                RunId=$script:binding.RunId;ScopeId=$script:binding.ScopeId;State='RUNNING'
                Instances=@($script:context.Instance)
            }
        }
        function Get-HyperVWindowsSlotLicenseStatus {param($RunId,$StateRoot)[pscustomobject]@{State='EVALUATION_ACTIVE'}}
        foreach($case in @('success','deferred','sql-version','receipt','parent','lost-new','cleanup','artifact')) {
            Reset-Fixture
            $receipt=[pscustomobject]@{
                ContractVersion='SqlServerLab.WindowsLocaleReceipt/1.0';Status='POST_OOBE_VERIFIED'
                RunId=$script:binding.RunId;Intent=$manifest.instances[0].windowsLocale;Observed=$script:observation
            }
            switch($case){
                sql-version {$script:sqlMajor=16}
                receipt {$receipt.RunId=[guid]::NewGuid().ToString()}
                parent {$script:parentChanged=$true}
                lost-new {$script:failNew=$true}
                cleanup {$script:vmRemains=$true}
                artifact {$script:artifactInvalid=$true;$script:arranged=$false}
            }
            $receipt | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $Root 'windows-locale-receipt.json') -Encoding utf8
            $scenario=@{
                ArtifactId=$id;StateRoot=$Root;OperationId=$script:binding.OperationId
                WorkingDirectory=(Join-Path $Root ('scenario-'+$case))
            }
            if($case -in @('success','deferred')) {
                $result=Invoke-HyperVPreparedLocaleScenario @scenario -DeferCleanup:($case -eq 'deferred')
                $expectedEvents=if($case -eq 'deferred'){'STOP,START'}else{'STOP,START,REMOVE'}
                Check ($result.Status -ceq 'VERIFIED' -and $result.SqlMajorVersion -eq 17 -and
                    ($script:events -join ',') -ceq $expectedEvents) "$case scenario preserves parent versus local cleanup ownership"
            }
            else {
                $code=switch($case){
                    sql-version {'SQL_IDENTITY_MISMATCH'}
                    receipt {'WINDOWS_LOCALE_RECEIPT_INVALID'}
                    parent {'PARENT_CHANGED'}
                    lost-new {'SYNTHETIC_NEW_RESPONSE_LOST'}
                    cleanup {'CLEANUP_REQUIRED'}
                    artifact {'ARTIFACT_INVALID'}
                }
                Reject {Invoke-HyperVPreparedLocaleScenario @scenario} $code
                if($case -eq 'artifact') { Check (-not $script:arranged -and -not $script:removeDone) 'Invalid parent rejected before Arrange and cleanup discovery' }
                else { Check $script:removeDone "$case executes cleanup after begun Arrange, including lost New response" }
            }
        }
        $workflow=Get-Content (Join-Path $Repo '.github/workflows/runtime-smoke-hyperv.yml') -Raw
        $ciRunner=Get-Content (Join-Path $Repo 'Tests/Integration/Invoke-HyperVSqlPreparedLocaleCiAcceptance.ps1') -Raw
        Check ($workflow -match "inputs.mode == 'sql-prepared-locale-acceptance' && !\(github.event_name == 'workflow_dispatch'" -and
            $workflow -match 'SQL_SERVER_LAB_CI_PREPARED_LOCALE_STATE_ROOT' -and
            $workflow -match 'Invoke-HyperVSqlPreparedLocaleCiAcceptance.ps1' -and
            $ciRunner -match 'Assert-HyperVPreparedLocaleDispatch' -and $ciRunner -match 'ExpectedCommit=\$env:GITHUB_SHA') 'Workflow and checked-out runner connect the tested dispatch guard and StateRoot'
        Write-Host "HYPERV SQL PREPARED LOCALE: $script:count PASS"
    } $repoRoot $testRoot
}
finally {
    if(Test-Path -LiteralPath $testRoot){
        $path=[IO.Path]::GetFullPath($testRoot)
        $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if(-not $path.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($path) -notlike 'sql-lab-prepared-locale-*') {throw 'TEST_ROOT_INVALID'}
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}
