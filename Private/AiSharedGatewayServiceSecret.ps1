function Test-LabAiSharedGatewayServiceSecretValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.SecureString]$Secret)

    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try {
        if($Secret.Length -lt 24 -or $Secret.Length -gt 256){return $false}
        for($index=0;$index -lt $Secret.Length;$index++){
            $code=[Runtime.InteropServices.Marshal]::ReadInt16($bstr,$index*2)
            if(-not(($code -ge 48 -and $code -le 57) -or ($code -ge 65 -and $code -le 90) -or ($code -ge 97 -and $code -le 122) -or $code -eq 45 -or $code -eq 95)){return $false}
        }
        return $true
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Test-LabAiSharedGatewayServiceSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$ServicePlan,
        [scriptblock]$SecretResolver,
        [datetime]$UtcNow=[datetime]::UtcNow
    )

    $canonical=Resolve-LabAiSharedGatewayPlan $Plan
    $resolvedService=Resolve-LabAiSharedGatewayServicePlan -ServicePlan $ServicePlan -Plan $canonical
    if([string]$resolvedService.Status -cne 'READY'){throw 'AI_SHARED_GATEWAY_SERVICE_PLAN_BLOCKED'}
    if([string]$resolvedService.PrincipalKey -cne (Get-LabAiSharedGatewayServicePrincipalKey)){throw 'AI_SHARED_GATEWAY_SERVICE_PRINCIPAL_MISMATCH'}
    if(-not $SecretResolver){
        $secretCommand=Get-Command -Name Get-Secret -ErrorAction SilentlyContinue
        if(-not $secretCommand){throw 'AI_SHARED_GATEWAY_SERVICE_SECRET_MANAGEMENT_UNAVAILABLE'}
        $SecretResolver={param($name)& $secretCommand -Name $name -ErrorAction Stop}.GetNewClosure()
    }
    $referenceKeys=[Collections.Generic.List[string]]::new()
    foreach($consumer in @($canonical.Consumers)){
        $secret=$null
        try {$secret=& $SecretResolver ([string]$consumer.ApiKeyReference)}
        catch {throw 'AI_SHARED_GATEWAY_SERVICE_SECRET_RESOLUTION_FAILED'}
        if($secret -isnot [Security.SecureString]){throw 'AI_SHARED_GATEWAY_SERVICE_SECRET_TYPE_UNSUPPORTED'}
        if(-not(Test-LabAiSharedGatewayServiceSecretValue -Secret $secret)){throw 'AI_SHARED_GATEWAY_SERVICE_SECRET_FORMAT_INVALID'}
        $referenceKeys.Add((Get-LabAiPlanKey ([ordered]@{PlanKey=$canonical.PlanKey;Reference=[string]$consumer.ApiKeyReference})))
        $secret=$null
    }
    $instant=([datetimeoffset]$UtcNow).ToUniversalTime()
    $verifiedAt=$instant.ToString('o')
    $expiresAt=$instant.AddMinutes(5).ToString('o')
    $pending=@('NONINTERACTIVE_SERVICE_LOGON_SECRET_RESOLUTION')
    $identity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayServiceSecretReceipt/1.0';EvidenceStatus='CURRENT_PRINCIPAL_SECRETS_RESOLVED';GatewayId=$canonical.GatewayId;GatewayPlanKey=$canonical.PlanKey;ServicePlanKey=[string]$resolvedService.PlanKey;PrincipalKey=[string]$resolvedService.PrincipalKey;SecretSource='POWERSHELL_SECRET_MANAGEMENT';ReferenceCount=$referenceKeys.Count;ReferenceKeys=@($referenceKeys|Sort-Object);VerifiedAtUtc=$verifiedAt;ExpiresAtUtc=$expiresAt;PendingEvidence=$pending}
    [pscustomobject][ordered]@{Contract=[pscustomobject]@{Name='SqlServerLab.AiSharedGatewayServiceSecretReceipt';Version='1.0'};Status='READY';EvidenceStatus='CURRENT_PRINCIPAL_SECRETS_RESOLVED';GatewayId=$canonical.GatewayId;GatewayPlanKey=$canonical.PlanKey;ServicePlanKey=[string]$resolvedService.PlanKey;PrincipalKey=[string]$resolvedService.PrincipalKey;SecretSource='POWERSHELL_SECRET_MANAGEMENT';ReferenceCount=$referenceKeys.Count;ReferenceKeys=@($referenceKeys|Sort-Object);VerifiedAtUtc=$verifiedAt;ExpiresAtUtc=$expiresAt;VerifiedEvidence=@('SECRET_MANAGEMENT_COMMAND_AVAILABLE','ALL_CONSUMER_SECRETS_RESOLVED','ALL_CONSUMER_SECRETS_SECURESTRING','ALL_CONSUMER_SECRETS_GATEWAY_FORMAT');PendingEvidence=$pending;ReceiptKey=Get-LabAiPlanKey $identity}
}

function Resolve-LabAiSharedGatewayServiceSecretReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Receipt,[Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$ServicePlan,[datetime]$UtcNow=[datetime]::UtcNow)

    $canonical=Resolve-LabAiSharedGatewayPlan $Plan
    $resolvedService=Resolve-LabAiSharedGatewayServicePlan -ServicePlan $ServicePlan -Plan $canonical
    if([string]$resolvedService.Status -cne 'READY'){throw 'AI_SHARED_GATEWAY_SERVICE_SECRET_RECEIPT_INVALID'}
    if([string]$resolvedService.PrincipalKey -cne (Get-LabAiSharedGatewayServicePrincipalKey)){throw 'AI_SHARED_GATEWAY_SERVICE_PRINCIPAL_MISMATCH'}
    $expectedNames=@('Contract','EvidenceStatus','ExpiresAtUtc','GatewayId','GatewayPlanKey','PendingEvidence','PrincipalKey','ReceiptKey','ReferenceCount','ReferenceKeys','SecretSource','ServicePlanKey','Status','VerifiedAtUtc','VerifiedEvidence')
    if((@($Receipt.PSObject.Properties.Name|Sort-Object)-join ',') -cne (($expectedNames|Sort-Object)-join ',') -or [string]$Receipt.Contract.Name -cne 'SqlServerLab.AiSharedGatewayServiceSecretReceipt' -or [string]$Receipt.Contract.Version -cne '1.0' -or [string]$Receipt.ReceiptKey -notmatch '^[a-f0-9]{64}$'){throw 'AI_SHARED_GATEWAY_SERVICE_SECRET_RECEIPT_INVALID'}
    try{$verified=[datetimeoffset]::ParseExact([string]$Receipt.VerifiedAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture);$expires=[datetimeoffset]::ParseExact([string]$Receipt.ExpiresAtUtc,'o',[Globalization.CultureInfo]::InvariantCulture)}catch{throw 'AI_SHARED_GATEWAY_SERVICE_SECRET_RECEIPT_INVALID'}
    $referenceKeys=@($Receipt.ReferenceKeys|ForEach-Object {[string]$_}|Sort-Object)
    $pending=@($Receipt.PendingEvidence|ForEach-Object {[string]$_})
    $identity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayServiceSecretReceipt/1.0';EvidenceStatus=[string]$Receipt.EvidenceStatus;GatewayId=[string]$Receipt.GatewayId;GatewayPlanKey=[string]$Receipt.GatewayPlanKey;ServicePlanKey=[string]$Receipt.ServicePlanKey;PrincipalKey=[string]$Receipt.PrincipalKey;SecretSource=[string]$Receipt.SecretSource;ReferenceCount=[int]$Receipt.ReferenceCount;ReferenceKeys=$referenceKeys;VerifiedAtUtc=$verified.ToUniversalTime().ToString('o');ExpiresAtUtc=$expires.ToUniversalTime().ToString('o');PendingEvidence=$pending}
    $expectedReferenceKeys=@($canonical.Consumers|ForEach-Object {Get-LabAiPlanKey ([ordered]@{PlanKey=$canonical.PlanKey;Reference=[string]$_.ApiKeyReference})}|Sort-Object)
    $expectedVerifiedEvidence=@('SECRET_MANAGEMENT_COMMAND_AVAILABLE','ALL_CONSUMER_SECRETS_RESOLVED','ALL_CONSUMER_SECRETS_SECURESTRING','ALL_CONSUMER_SECRETS_GATEWAY_FORMAT')
    if([string]$Receipt.Status -cne 'READY' -or $identity.EvidenceStatus -cne 'CURRENT_PRINCIPAL_SECRETS_RESOLVED' -or $identity.GatewayId -cne $canonical.GatewayId -or $identity.GatewayPlanKey -cne $canonical.PlanKey -or $identity.ServicePlanKey -cne [string]$resolvedService.PlanKey -or $identity.PrincipalKey -cne [string]$resolvedService.PrincipalKey -or $identity.SecretSource -cne 'POWERSHELL_SECRET_MANAGEMENT' -or $identity.ReferenceCount -ne $expectedReferenceKeys.Count -or ($referenceKeys -join ',') -cne ($expectedReferenceKeys -join ',') -or (@($Receipt.VerifiedEvidence|ForEach-Object {[string]$_}) -join ',') -cne ($expectedVerifiedEvidence -join ',') -or ($pending -join ',') -cne 'NONINTERACTIVE_SERVICE_LOGON_SECRET_RESOLUTION' -or $expires -ne $verified.AddMinutes(5) -or (Get-LabAiPlanKey $identity) -cne [string]$Receipt.ReceiptKey){throw 'AI_SHARED_GATEWAY_SERVICE_SECRET_RECEIPT_INVALID'}
    $now=[datetimeoffset]$UtcNow.ToUniversalTime()
    if($now -lt $verified.AddMinutes(-1) -or $now -gt $expires){throw 'AI_SHARED_GATEWAY_SERVICE_SECRET_RECEIPT_EXPIRED'}
    return $Receipt
}
