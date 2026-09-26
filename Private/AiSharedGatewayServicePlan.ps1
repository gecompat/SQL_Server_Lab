function Get-LabAiSharedGatewayServiceCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$GatewayId)

    $blockers=[Collections.Generic.List[string]]::new();$verified=[Collections.Generic.List[string]]::new()
    $platform='Unsupported';$serviceMode='NONE'
    if($IsWindows){
        $platform='Windows';$serviceMode='WINDOWS_S4U_TASK'
        $required=@('Get-ScheduledTask','New-ScheduledTaskAction','New-ScheduledTaskPrincipal','New-ScheduledTaskTrigger','Register-ScheduledTask')
        if(@($required|Where-Object {-not(Get-Command $_ -ErrorAction SilentlyContinue)}).Count){$blockers.Add('AI_SHARED_GATEWAY_SERVICE_SCHEDULED_TASKS_UNAVAILABLE')}else{$verified.Add('WINDOWS_SCHEDULED_TASKS_AVAILABLE')}
        $full=[IO.Path]::GetFullPath($StateRoot)
        if($full.StartsWith('\\',[StringComparison]::Ordinal)){$blockers.Add('AI_SHARED_GATEWAY_SERVICE_WINDOWS_S4U_LOCAL_STORAGE_REQUIRED')}else{$verified.Add('LOCAL_STATE_ROOT')}
        $gatewayRoot=Join-Path (Join-Path $full 'shared-ai-gateways') $GatewayId
        if(Test-Path -LiteralPath $gatewayRoot){
            $encrypted=@(@(Get-Item -LiteralPath $gatewayRoot -Force -ErrorAction Stop)+@(Get-ChildItem -LiteralPath $gatewayRoot -Force -Recurse -ErrorAction Stop)|Where-Object {($_.Attributes -band [IO.FileAttributes]::Encrypted) -ne 0})
            if($encrypted.Count){$blockers.Add('AI_SHARED_GATEWAY_SERVICE_WINDOWS_S4U_EFS_UNSUPPORTED')}else{$verified.Add('STATE_ROOT_NOT_EFS_ENCRYPTED')}
        }
    }
    elseif($IsLinux){
        $platform='Linux';$serviceMode='LINUX_SYSTEMD_USER'
        $systemctl=Get-Command systemctl -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
        $loginctl=Get-Command loginctl -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
        if(-not $systemctl -or -not $loginctl){$blockers.Add('AI_SHARED_GATEWAY_SERVICE_SYSTEMD_USER_UNAVAILABLE')}
        else {
            & $systemctl.Source --user show-environment *> $null
            if($LASTEXITCODE -ne 0){$blockers.Add('AI_SHARED_GATEWAY_SERVICE_SYSTEMD_USER_UNAVAILABLE')}else{$verified.Add('SYSTEMD_USER_MANAGER_AVAILABLE')}
            $linger=[string](& $loginctl.Source show-user ([Environment]::UserName) --property=Linger --value 2>$null)
            if($LASTEXITCODE -ne 0 -or $linger.Trim() -cne 'yes'){$blockers.Add('AI_SHARED_GATEWAY_SERVICE_LINGER_REQUIRED')}else{$verified.Add('SYSTEMD_USER_LINGER_ENABLED')}
        }
    }
    else {$blockers.Add('AI_SHARED_GATEWAY_SERVICE_PLATFORM_UNSUPPORTED')}
    $principalKey=Get-LabAiPlanKey ([ordered]@{Platform=$platform;Machine=[Environment]::MachineName;User=[Environment]::UserName})
    $identity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayServiceCapability/1.0';Platform=$platform;ServiceMode=$serviceMode;PrincipalKey=$principalKey;VerifiedEvidence=@($verified|Sort-Object -Unique);Blockers=@($blockers|Sort-Object -Unique)}
    [pscustomobject][ordered]@{Contract=[pscustomobject]@{Name='SqlServerLab.AiSharedGatewayServiceCapability';Version='1.0'};Status=if($blockers.Count){'BLOCKED'}else{'READY'};Platform=$platform;ServiceMode=$serviceMode;PrincipalKey=$principalKey;VerifiedEvidence=$identity.VerifiedEvidence;Blockers=$identity.Blockers;CapabilityKey=Get-LabAiPlanKey $identity}
}

function New-LabAiSharedGatewayServicePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$GatewayStatus,[Parameter(Mandatory)]$HostCapability,
        [ValidateSet('Auto','WindowsS4U','SystemdUser')][string]$ServiceMode='Auto'
    )
    $canonical=Resolve-LabAiSharedGatewayPlan $Plan
    if([string]$GatewayStatus.GatewayId -cne $canonical.GatewayId -or [string]$GatewayStatus.PlanKey -cne $canonical.PlanKey -or [string]$GatewayStatus.ReceiptKey -notmatch '^[a-f0-9]{64}$'){throw 'AI_SHARED_GATEWAY_SERVICE_STATUS_INVALID'}
    if([string]$HostCapability.Contract.Name -cne 'SqlServerLab.AiSharedGatewayServiceCapability' -or [string]$HostCapability.Contract.Version -cne '1.0' -or [string]$HostCapability.CapabilityKey -notmatch '^[a-f0-9]{64}$'){throw 'AI_SHARED_GATEWAY_SERVICE_CAPABILITY_INVALID'}
    $capabilityIdentity=[ordered]@{
        Contract='SqlServerLab.AiSharedGatewayServiceCapability/1.0'
        Platform=[string]$HostCapability.Platform
        ServiceMode=[string]$HostCapability.ServiceMode
        PrincipalKey=[string]$HostCapability.PrincipalKey
        VerifiedEvidence=@($HostCapability.VerifiedEvidence|ForEach-Object {[string]$_}|Sort-Object -Unique)
        Blockers=@($HostCapability.Blockers|ForEach-Object {[string]$_}|Sort-Object -Unique)
    }
    $capabilityStatus=if($capabilityIdentity.Blockers.Count){'BLOCKED'}else{'READY'}
    $allowedEvidence=@('WINDOWS_SCHEDULED_TASKS_AVAILABLE','LOCAL_STATE_ROOT','STATE_ROOT_NOT_EFS_ENCRYPTED','SYSTEMD_USER_MANAGER_AVAILABLE','SYSTEMD_USER_LINGER_ENABLED')
    $allowedHostBlockers=@('AI_SHARED_GATEWAY_SERVICE_PLATFORM_UNSUPPORTED','AI_SHARED_GATEWAY_SERVICE_SCHEDULED_TASKS_UNAVAILABLE','AI_SHARED_GATEWAY_SERVICE_WINDOWS_S4U_LOCAL_STORAGE_REQUIRED','AI_SHARED_GATEWAY_SERVICE_WINDOWS_S4U_EFS_UNSUPPORTED','AI_SHARED_GATEWAY_SERVICE_SYSTEMD_USER_UNAVAILABLE','AI_SHARED_GATEWAY_SERVICE_LINGER_REQUIRED')
    $platformModeValid=switch($capabilityIdentity.Platform){'Windows'{$capabilityIdentity.ServiceMode -ceq 'WINDOWS_S4U_TASK'}'Linux'{$capabilityIdentity.ServiceMode -ceq 'LINUX_SYSTEMD_USER'}'Unsupported'{$capabilityIdentity.ServiceMode -ceq 'NONE'}default{$false}}
    if(
        [string]$HostCapability.Status -cne $capabilityStatus -or
        -not $platformModeValid -or
        $capabilityIdentity.PrincipalKey -notmatch '^[a-f0-9]{64}$' -or
        @($capabilityIdentity.VerifiedEvidence|Where-Object {$_ -notin $allowedEvidence}).Count -or
        @($capabilityIdentity.Blockers|Where-Object {$_ -notin $allowedHostBlockers}).Count -or
        (Get-LabAiPlanKey $capabilityIdentity) -cne [string]$HostCapability.CapabilityKey
    ){throw 'AI_SHARED_GATEWAY_SERVICE_CAPABILITY_INVALID'}
    $expectedMode=switch($ServiceMode){'WindowsS4U'{'WINDOWS_S4U_TASK'}'SystemdUser'{'LINUX_SYSTEMD_USER'}default{[string]$HostCapability.ServiceMode}}
    $blockers=[Collections.Generic.List[string]]::new()
    switch([string]$GatewayStatus.Status){
        'NOT_REGISTERED' {$blockers.Add('AI_SHARED_GATEWAY_SERVICE_REGISTRATION_REQUIRED')}
        'RECOVERY_REQUIRED' {$blockers.Add('AI_SHARED_GATEWAY_SERVICE_STORAGE_RECOVERY_REQUIRED')}
        {$_ -in @('REGISTERED_STOPPED','OWNER_SESSION_RUNNING')} {}
        default {throw 'AI_SHARED_GATEWAY_SERVICE_STATUS_INVALID'}
    }
    foreach($item in @($HostCapability.Blockers)){if($item){$blockers.Add([string]$item)}}
    if($expectedMode -cne [string]$HostCapability.ServiceMode -or $expectedMode -eq 'NONE'){$blockers.Add('AI_SHARED_GATEWAY_SERVICE_MODE_UNSUPPORTED')}
    [string[]]$warnings=@(if($expectedMode -ceq 'WINDOWS_S4U_TASK'){'WINDOWS_S4U_NO_NETWORK_OR_EFS_ACCESS';'WINDOWS_S4U_REGISTRATION_MAY_REQUIRE_ELEVATION'})
    $status=if($blockers.Count){'BLOCKED'}else{'READY'}
    $evidenceStatus=if($status -ceq 'READY'){'HOST_AND_REGISTRATION_READY'}elseif([string]$GatewayStatus.Status -in @('NOT_REGISTERED','RECOVERY_REQUIRED')){'GATEWAY_STATE_BLOCKED'}else{'HOST_CAPABILITY_BLOCKED'}
    $startupScope=if($expectedMode -ceq 'NONE'){'NONE'}else{'CURRENT_USER_AT_BOOT'}
    $verifiedEvidence=@($HostCapability.VerifiedEvidence|ForEach-Object {[string]$_}|Sort-Object -Unique)
    $identity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayServicePlan/1.0';GatewayId=$canonical.GatewayId;GatewayPlanKey=$canonical.PlanKey;GatewayStatusReceiptKey=[string]$GatewayStatus.ReceiptKey;HostCapabilityKey=[string]$HostCapability.CapabilityKey;Platform=[string]$HostCapability.Platform;ServiceMode=$expectedMode;StartupScope=$startupScope;PrincipalKey=[string]$HostCapability.PrincipalKey;Status=$status;EvidenceStatus=$evidenceStatus;RequiredActions=@('VERIFY_SERVICE_SECRETS','INSTALL_SERVICE_DEFINITION','ENABLE_AUTOSTART','START_SERVICE','VERIFY_ENDPOINT');VerifiedEvidence=$verifiedEvidence;Blockers=@($blockers|Sort-Object -Unique);Warnings=$warnings}
    [pscustomobject][ordered]@{Contract=[pscustomobject]@{Name='SqlServerLab.AiSharedGatewayServicePlan';Version='1.0'};Status=$status;EvidenceStatus=$evidenceStatus;GatewayId=$canonical.GatewayId;GatewayPlanKey=$canonical.PlanKey;GatewayStatusReceiptKey=[string]$GatewayStatus.ReceiptKey;HostCapabilityKey=[string]$HostCapability.CapabilityKey;Platform=[string]$HostCapability.Platform;ServiceMode=$expectedMode;StartupScope=$startupScope;PrincipalKey=[string]$HostCapability.PrincipalKey;RequiredActions=$identity.RequiredActions;VerifiedEvidence=$verifiedEvidence;Blockers=$identity.Blockers;Warnings=$warnings;PlanKey=Get-LabAiPlanKey $identity}
}

function Resolve-LabAiSharedGatewayServicePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ServicePlan,[Parameter(Mandatory)]$Plan)

    $canonical=Resolve-LabAiSharedGatewayPlan $Plan
    $expectedNames=@('Blockers','Contract','EvidenceStatus','GatewayId','GatewayPlanKey','GatewayStatusReceiptKey','HostCapabilityKey','PlanKey','Platform','PrincipalKey','RequiredActions','ServiceMode','StartupScope','Status','VerifiedEvidence','Warnings')
    if((@($ServicePlan.PSObject.Properties.Name|Sort-Object)-join ',') -cne (($expectedNames|Sort-Object)-join ',') -or [string]$ServicePlan.Contract.Name -cne 'SqlServerLab.AiSharedGatewayServicePlan' -or [string]$ServicePlan.Contract.Version -cne '1.0' -or [string]$ServicePlan.PlanKey -notmatch '^[a-f0-9]{64}$'){throw 'AI_SHARED_GATEWAY_SERVICE_PLAN_INVALID'}
    $identity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayServicePlan/1.0';GatewayId=[string]$ServicePlan.GatewayId;GatewayPlanKey=[string]$ServicePlan.GatewayPlanKey;GatewayStatusReceiptKey=[string]$ServicePlan.GatewayStatusReceiptKey;HostCapabilityKey=[string]$ServicePlan.HostCapabilityKey;Platform=[string]$ServicePlan.Platform;ServiceMode=[string]$ServicePlan.ServiceMode;StartupScope=[string]$ServicePlan.StartupScope;PrincipalKey=[string]$ServicePlan.PrincipalKey;Status=[string]$ServicePlan.Status;EvidenceStatus=[string]$ServicePlan.EvidenceStatus;RequiredActions=@($ServicePlan.RequiredActions|ForEach-Object {[string]$_});VerifiedEvidence=@($ServicePlan.VerifiedEvidence|ForEach-Object {[string]$_}|Sort-Object -Unique);Blockers=@($ServicePlan.Blockers|ForEach-Object {[string]$_}|Sort-Object -Unique);Warnings=@($ServicePlan.Warnings|ForEach-Object {[string]$_})}
    $hostMode=switch($identity.Platform){'Windows'{'WINDOWS_S4U_TASK'}'Linux'{'LINUX_SYSTEMD_USER'}'Unsupported'{'NONE'}default{$null}}
    $modeMismatch=$identity.ServiceMode -cne $hostMode
    $expectedScope=if($identity.ServiceMode -ceq 'NONE'){'NONE'}else{'CURRENT_USER_AT_BOOT'}
    $requiredActions=@('VERIFY_SERVICE_SECRETS','INSTALL_SERVICE_DEFINITION','ENABLE_AUTOSTART','START_SERVICE','VERIFY_ENDPOINT')
    $allowedEvidence=@('WINDOWS_SCHEDULED_TASKS_AVAILABLE','LOCAL_STATE_ROOT','STATE_ROOT_NOT_EFS_ENCRYPTED','SYSTEMD_USER_MANAGER_AVAILABLE','SYSTEMD_USER_LINGER_ENABLED')
    $allowedBlockers=@('AI_SHARED_GATEWAY_SERVICE_REGISTRATION_REQUIRED','AI_SHARED_GATEWAY_SERVICE_STORAGE_RECOVERY_REQUIRED','AI_SHARED_GATEWAY_SERVICE_PLATFORM_UNSUPPORTED','AI_SHARED_GATEWAY_SERVICE_MODE_UNSUPPORTED','AI_SHARED_GATEWAY_SERVICE_SCHEDULED_TASKS_UNAVAILABLE','AI_SHARED_GATEWAY_SERVICE_WINDOWS_S4U_LOCAL_STORAGE_REQUIRED','AI_SHARED_GATEWAY_SERVICE_WINDOWS_S4U_EFS_UNSUPPORTED','AI_SHARED_GATEWAY_SERVICE_SYSTEMD_USER_UNAVAILABLE','AI_SHARED_GATEWAY_SERVICE_LINGER_REQUIRED')
    $expectedWarnings=if($identity.ServiceMode -ceq 'WINDOWS_S4U_TASK'){@('WINDOWS_S4U_NO_NETWORK_OR_EFS_ACCESS','WINDOWS_S4U_REGISTRATION_MAY_REQUIRE_ELEVATION')}else{@()}
    $expectedStatus=if($identity.Blockers.Count){'BLOCKED'}else{'READY'}
    $gatewayBlocked=@($identity.Blockers|Where-Object {$_ -in @('AI_SHARED_GATEWAY_SERVICE_REGISTRATION_REQUIRED','AI_SHARED_GATEWAY_SERVICE_STORAGE_RECOVERY_REQUIRED')}).Count -gt 0
    $expectedEvidenceStatus=if($expectedStatus -ceq 'READY'){'HOST_AND_REGISTRATION_READY'}elseif($gatewayBlocked){'GATEWAY_STATE_BLOCKED'}else{'HOST_CAPABILITY_BLOCKED'}
    if($identity.GatewayId -cne $canonical.GatewayId -or $identity.GatewayPlanKey -cne $canonical.PlanKey -or $identity.GatewayStatusReceiptKey -notmatch '^[a-f0-9]{64}$' -or $identity.HostCapabilityKey -notmatch '^[a-f0-9]{64}$' -or $identity.PrincipalKey -notmatch '^[a-f0-9]{64}$' -or -not $hostMode -or ($modeMismatch -and $identity.Blockers -notcontains 'AI_SHARED_GATEWAY_SERVICE_MODE_UNSUPPORTED') -or (-not $modeMismatch -and $identity.Blockers -contains 'AI_SHARED_GATEWAY_SERVICE_MODE_UNSUPPORTED') -or $identity.StartupScope -cne $expectedScope -or $identity.Status -cne $expectedStatus -or $identity.EvidenceStatus -cne $expectedEvidenceStatus -or @($identity.VerifiedEvidence|Where-Object {$_ -notin $allowedEvidence}).Count -or @($identity.Blockers|Where-Object {$_ -notin $allowedBlockers}).Count -or ($identity.Warnings -join ',') -cne ($expectedWarnings -join ',') -or ($identity.RequiredActions -join ',') -cne ($requiredActions -join ',') -or (Get-LabAiPlanKey $identity) -cne [string]$ServicePlan.PlanKey){throw 'AI_SHARED_GATEWAY_SERVICE_PLAN_INVALID'}
    return $ServicePlan
}

function Get-LabAiSharedGatewayServicePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[string]$StateRoot,[ValidateSet('Auto','WindowsS4U','SystemdUser')][string]$ServiceMode='Auto')
    $canonical=Resolve-LabAiSharedGatewayPlan $Plan;if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $gatewayStatus=Get-LabAiSharedGatewayStatus -Plan $canonical -StateRoot $StateRoot
    $capability=Get-LabAiSharedGatewayServiceCapability -StateRoot $StateRoot -GatewayId $canonical.GatewayId
    New-LabAiSharedGatewayServicePlan -Plan $canonical -GatewayStatus $gatewayStatus -HostCapability $capability -ServiceMode $ServiceMode
}
