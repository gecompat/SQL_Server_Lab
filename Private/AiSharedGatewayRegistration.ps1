function Assert-LabAiSharedGatewayStoragePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full=[IO.Path]::GetFullPath($Path)
    $existing=$full
    while(-not(Test-Path -LiteralPath $existing)){
        $parent=Split-Path -Parent $existing
        if(-not $parent -or $parent -eq $existing){throw 'AI_SHARED_GATEWAY_STORAGE_PATH_INVALID'}
        $existing=$parent
    }
    Assert-LabPortableContainerTransferPreflightNoReparsePath -Root ([IO.Path]::GetPathRoot($existing)) -Path $existing
    return $full
}

function Protect-LabAiSharedGatewayStoragePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[switch]$File,[switch]$Executable)

    if($IsWindows){
        $acl=if($File){[Security.AccessControl.FileSecurity]::new()}else{[Security.AccessControl.DirectorySecurity]::new()}
        $acl.SetAccessRuleProtection($true,$false)
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $inheritance=if($File){'None'}else{'ContainerInherit,ObjectInherit'}
        $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl',$inheritance,'None','Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
        return
    }
    if($IsLinux -or $IsMacOS){
        $mode=[IO.UnixFileMode]::UserRead-bor[IO.UnixFileMode]::UserWrite
        if(-not $File -or $Executable){$mode=$mode-bor[IO.UnixFileMode]::UserExecute}
        [IO.File]::SetUnixFileMode($Path,$mode)
        return
    }
    throw 'AI_SHARED_GATEWAY_STORAGE_PLATFORM_UNSUPPORTED'
}

function Test-LabAiSharedGatewayStorageProtection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[switch]$File,[switch]$Executable)

    if($IsWindows){
        $acl=Get-Acl -LiteralPath $Path
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $rules=@($acl.Access)
        return $acl.AreAccessRulesProtected -and $rules.Count -eq 1 -and
            $rules[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ceq $sid -and
            $rules[0].AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            (($rules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl)
    }
    if($IsLinux -or $IsMacOS){
        $expected=[IO.UnixFileMode]::UserRead-bor[IO.UnixFileMode]::UserWrite
        if(-not $File -or $Executable){$expected=$expected-bor[IO.UnixFileMode]::UserExecute}
        return [IO.File]::GetUnixFileMode($Path) -eq $expected
    }
    return $false
}

function ConvertTo-LabAiSharedGatewayUtcText {
    param($Value)
    if($Value -is [datetime]){return $Value.ToUniversalTime().ToString('o')}
    if($Value -is [datetimeoffset]){return $Value.ToUniversalTime().ToString('o')}
    return [string]$Value
}

function Get-LabAiSharedGatewayRegistrationReceipt {
    param($Plan,$Preflight,[string]$Status,[string]$RegisteredAtUtc)
    $identity=[ordered]@{
        Contract='SqlServerLab.AiSharedGatewayStorageReceipt/1.0';Status=$Status;GatewayId=$Plan.GatewayId
        PlanKey=$Plan.PlanKey;PreflightReceiptKey=$Preflight.ReceiptKey;RuntimeSha256=$Plan.RuntimeSha256
        ModelSha256=$Plan.ModelSha256;ServerCertificateSha256=$Plan.ServerCertificateSha256
        CertificateAuthoritySha256=$Plan.CertificateAuthoritySha256;ConsumerCount=@($Plan.Consumers).Count
        RegisteredAtUtc=$RegisteredAtUtc
    }
    [pscustomobject][ordered]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.AiSharedGatewayStorageReceipt';Version='1.0'}
        Status=$Status;EvidenceStatus='PROTECTED_SHARED_STORAGE';GatewayId=$Plan.GatewayId;PlanKey=$Plan.PlanKey
        PreflightReceiptKey=$Preflight.ReceiptKey;RuntimeSha256=$Plan.RuntimeSha256;ModelSha256=$Plan.ModelSha256
        ServerCertificateSha256=$Plan.ServerCertificateSha256;CertificateAuthoritySha256=$Plan.CertificateAuthoritySha256
        ConsumerCount=@($Plan.Consumers).Count;RegisteredAtUtc=$RegisteredAtUtc
        VerifiedEvidence=@('RUNTIME_BINARY_MATCH','MODEL_FILE_MATCH','SERVER_CERTIFICATE_MATCH','CERTIFICATE_PRIVATE_KEY_MATCH','CERTIFICATE_AUTHORITY_MATCH','CERTIFICATE_CHAIN_MATCH','CERTIFICATE_HOST_MATCH','CERTIFICATE_TIME_VALID','PROTECTED_SHARED_STORAGE')
        PendingEvidence=@('PERSISTENT_GATEWAY_SERVICE','LIVE_ENDPOINT','SQL_CONSUMER_BINDINGS','BACKUP_RESTORE','ROTATION','ACCELERATOR_RUNTIME_ATTESTATION')
        ReceiptKey=Get-LabAiPlanKey $identity
    }
}

function Read-LabAiSharedGatewayRegistration {
    param([Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)]$ExpectedPlan)
    try {
        $directoryPath=Assert-LabAiSharedGatewayStoragePath $Directory
        if(-not(Test-Path -LiteralPath $directoryPath -PathType Container) -or -not(Test-LabAiSharedGatewayStorageProtection $directoryPath)){throw 'drift'}
        $registrationPath=Join-Path $directoryPath 'registration.json'
        $planPath=Join-Path $directoryPath 'plan.json'
        $preflightPath=Join-Path $directoryPath 'preflight.json'
        $expectedNames=@('certificate-authority.pem','model.gguf','plan.json','preflight.json','registration.json','runtime.bin','server-certificate.pem','server-private-key.pem')
        $actualNames=@(Get-ChildItem -LiteralPath $directoryPath -Force|Sort-Object Name|ForEach-Object Name)
        if(($actualNames -join "`n") -cne ($expectedNames -join "`n")){throw 'drift'}
        $artifactPaths=@('runtime.bin','model.gguf','server-certificate.pem','server-private-key.pem','certificate-authority.pem'|ForEach-Object{Join-Path $directoryPath $_})
        foreach($path in @($registrationPath,$planPath,$preflightPath)+$artifactPaths){
            $null=Assert-LabAiSharedGatewayStoragePath $path
            if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or -not(Test-LabAiSharedGatewayStorageProtection $path -File -Executable:($path.EndsWith('runtime.bin',[StringComparison]::Ordinal)))){throw 'drift'}
        }
        $registrationJson=Get-Content -LiteralPath $registrationPath -Raw -Encoding utf8
        if(-not($registrationJson|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-shared-gateway-storage-state.schema.json') -ErrorAction Stop)){throw 'drift'}
        $registration=$registrationJson|ConvertFrom-Json -Depth 30
        $storedPlan=Resolve-LabAiSharedGatewayPlan ((Get-Content -LiteralPath $planPath -Raw -Encoding utf8)|ConvertFrom-Json -Depth 30)
        $preflightJson=Get-Content -LiteralPath $preflightPath -Raw -Encoding utf8
        if(-not($preflightJson|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-shared-gateway-preflight-receipt.schema.json') -ErrorAction Stop)){throw 'drift'}
        $preflight=$preflightJson|ConvertFrom-Json -Depth 20
        $preflightIdentity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayPreflightReceipt/1.0';PlanKey=[string]$preflight.PlanKey;RuntimeSha256=[string]$preflight.RuntimeSha256;ModelSha256=[string]$preflight.ModelSha256;ServerCertificateSha256=[string]$preflight.ServerCertificateSha256;CertificateAuthoritySha256=[string]$preflight.CertificateAuthoritySha256;CertificateNotBeforeUtc=ConvertTo-LabAiSharedGatewayUtcText $preflight.CertificateNotBeforeUtc;CertificateNotAfterUtc=ConvertTo-LabAiSharedGatewayUtcText $preflight.CertificateNotAfterUtc;VerifiedAtUtc=ConvertTo-LabAiSharedGatewayUtcText $preflight.VerifiedAtUtc}
        $registeredAt=ConvertTo-LabAiSharedGatewayUtcText $registration.RegisteredAtUtc
        $stateIdentity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayStorageState/1.0';GatewayId=[string]$registration.GatewayId;PlanKey=[string]$registration.PlanKey;PreflightReceiptKey=[string]$registration.PreflightReceiptKey;RegisteredAtUtc=$registeredAt;Files=@($registration.Files)}
        if($storedPlan.PlanKey -cne $ExpectedPlan.PlanKey -or $registration.PlanKey -cne $ExpectedPlan.PlanKey -or $registration.GatewayId -cne $ExpectedPlan.GatewayId){throw 'conflict'}
        $expectedFiles=@(
            [pscustomobject]@{Role='Runtime';Name='runtime.bin';Sha256=$storedPlan.RuntimeSha256}
            [pscustomobject]@{Role='Model';Name='model.gguf';Sha256=$storedPlan.ModelSha256}
            [pscustomobject]@{Role='ServerCertificate';Name='server-certificate.pem';Sha256=$storedPlan.ServerCertificateSha256}
            [pscustomobject]@{Role='PrivateKey';Name='server-private-key.pem';Sha256=$null}
            [pscustomobject]@{Role='CertificateAuthority';Name='certificate-authority.pem';Sha256=$storedPlan.CertificateAuthoritySha256}
        )
        if((Get-LabAiPlanKey $stateIdentity) -cne $registration.StateKey -or $registration.PreflightReceiptKey -cne $preflight.ReceiptKey -or
           (Get-LabAiPlanKey @($registration.Files)) -cne (Get-LabAiPlanKey $expectedFiles)){throw 'drift'}
        if((Get-LabAiPlanKey $preflightIdentity) -cne $preflight.ReceiptKey -or $preflight.PlanKey -cne $storedPlan.PlanKey -or
           $preflight.RuntimeSha256 -cne $storedPlan.RuntimeSha256 -or $preflight.ModelSha256 -cne $storedPlan.ModelSha256 -or
           $preflight.ServerCertificateSha256 -cne $storedPlan.ServerCertificateSha256 -or $preflight.CertificateAuthoritySha256 -cne $storedPlan.CertificateAuthoritySha256){throw 'drift'}
        $null=Test-LabAiSharedGatewayPreflight -Plan $storedPlan -RuntimePath (Join-Path $directoryPath 'runtime.bin') `
            -ModelPath (Join-Path $directoryPath 'model.gguf') -CertificatePath (Join-Path $directoryPath 'server-certificate.pem') `
            -PrivateKeyPath (Join-Path $directoryPath 'server-private-key.pem') -CertificateAuthorityPath (Join-Path $directoryPath 'certificate-authority.pem')
        return Get-LabAiSharedGatewayRegistrationReceipt $storedPlan $preflight 'ALREADY_REGISTERED' $registeredAt
    }
    catch {
        if($_.Exception.Message -ceq 'conflict'){throw 'AI_SHARED_GATEWAY_STORAGE_CONFLICT'}
        throw 'AI_SHARED_GATEWAY_STORAGE_DRIFT'
    }
}

function Register-LabAiSharedGatewayStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$ModelPath,
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][string]$CertificateAuthorityPath,
        [string]$StateRoot,
        [switch]$WhatIf
    )
    $canonical=Resolve-LabAiSharedGatewayPlan $Plan
    $preflight=Test-LabAiSharedGatewayPreflight -Plan $canonical -RuntimePath $RuntimePath -ModelPath $ModelPath `
        -CertificatePath $CertificatePath -PrivateKeyPath $PrivateKeyPath -CertificateAuthorityPath $CertificateAuthorityPath
    if($WhatIf){return}
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $root=Assert-LabAiSharedGatewayStoragePath $StateRoot
    if((Test-Path -LiteralPath $root) -and -not(Test-Path -LiteralPath $root -PathType Container)){throw 'AI_SHARED_GATEWAY_STORAGE_PATH_INVALID'}
    $sharedRoot=Join-Path $root 'shared-ai-gateways'
    $gatewayRoot=Join-Path $sharedRoot $canonical.GatewayId
    foreach($path in @($sharedRoot,$gatewayRoot)){$null=Assert-LabAiSharedGatewayStoragePath $path}
    $mutexHash=Get-LabAiPlanKey ([ordered]@{StateRoot=$root;GatewayId=$canonical.GatewayId})
    $mutex=[Threading.Mutex]::new($false,"SQL_Server_Lab_Ai_Shared_Gateway_$($mutexHash.Substring(0,24))")
    $acquired=$false;$stage=$null;$published=$false;$sharedCreated=$false
    try {
        try{$acquired=$mutex.WaitOne([TimeSpan]::FromSeconds(30))}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not $acquired){throw 'AI_SHARED_GATEWAY_STORAGE_LOCKED'}
        if(Test-Path -LiteralPath $gatewayRoot){return Read-LabAiSharedGatewayRegistration -Directory $gatewayRoot -ExpectedPlan $canonical}
        if((Test-Path -LiteralPath $sharedRoot) -and -not(Test-Path -LiteralPath $sharedRoot -PathType Container)){throw 'AI_SHARED_GATEWAY_STORAGE_PATH_INVALID'}
        if(-not(Test-Path -LiteralPath $sharedRoot -PathType Container)){$null=New-Item -ItemType Directory -Path $sharedRoot;$sharedCreated=$true}
        Protect-LabAiSharedGatewayStoragePath $sharedRoot
        if(-not(Test-LabAiSharedGatewayStorageProtection $sharedRoot)){throw 'AI_SHARED_GATEWAY_STORAGE_PROTECTION_FAILED'}
        $stage=Join-Path $sharedRoot ('.register-'+$canonical.GatewayId+'-'+[guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $stage
        Protect-LabAiSharedGatewayStoragePath $stage
        $copies=[ordered]@{
            'runtime.bin'=$RuntimePath;'model.gguf'=$ModelPath;'server-certificate.pem'=$CertificatePath
            'server-private-key.pem'=$PrivateKeyPath;'certificate-authority.pem'=$CertificateAuthorityPath
        }
        foreach($entry in $copies.GetEnumerator()){
            $target=Join-Path $stage $entry.Key
            [IO.File]::Copy([IO.Path]::GetFullPath([string]$entry.Value),$target,$false)
            Protect-LabAiSharedGatewayStoragePath $target -File -Executable:($entry.Key -ceq 'runtime.bin')
        }
        $storedPreflight=Test-LabAiSharedGatewayPreflight -Plan $canonical -RuntimePath (Join-Path $stage 'runtime.bin') `
            -ModelPath (Join-Path $stage 'model.gguf') -CertificatePath (Join-Path $stage 'server-certificate.pem') `
            -PrivateKeyPath (Join-Path $stage 'server-private-key.pem') -CertificateAuthorityPath (Join-Path $stage 'certificate-authority.pem')
        $registeredAt=[datetime]::UtcNow.ToString('o')
        $fileBindings=@(
            [pscustomobject]@{Role='Runtime';Name='runtime.bin';Sha256=$canonical.RuntimeSha256}
            [pscustomobject]@{Role='Model';Name='model.gguf';Sha256=$canonical.ModelSha256}
            [pscustomobject]@{Role='ServerCertificate';Name='server-certificate.pem';Sha256=$canonical.ServerCertificateSha256}
            [pscustomobject]@{Role='PrivateKey';Name='server-private-key.pem';Sha256=$null}
            [pscustomobject]@{Role='CertificateAuthority';Name='certificate-authority.pem';Sha256=$canonical.CertificateAuthoritySha256}
        )
        $stateIdentity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayStorageState/1.0';GatewayId=$canonical.GatewayId;PlanKey=$canonical.PlanKey;PreflightReceiptKey=$storedPreflight.ReceiptKey;RegisteredAtUtc=$registeredAt;Files=$fileBindings}
        $state=[pscustomobject][ordered]@{
            Contract=[pscustomobject]@{Name='SqlServerLab.AiSharedGatewayStorageState';Version='1.0'}
            Status='STORAGE_REGISTERED';GatewayId=$canonical.GatewayId;PlanKey=$canonical.PlanKey
            PreflightReceiptKey=$storedPreflight.ReceiptKey;RegisteredAtUtc=$registeredAt
            Files=$fileBindings;StateKey=Get-LabAiPlanKey $stateIdentity
        }
        Write-LabArtifactJsonAtomic (Join-Path $stage 'plan.json') $canonical
        Write-LabArtifactJsonAtomic (Join-Path $stage 'preflight.json') $storedPreflight
        Write-LabArtifactJsonAtomic (Join-Path $stage 'registration.json') $state
        foreach($name in @('plan.json','preflight.json','registration.json')){Protect-LabAiSharedGatewayStoragePath (Join-Path $stage $name) -File}
        $stateJson=Get-Content -LiteralPath (Join-Path $stage 'registration.json') -Raw -Encoding utf8
        if(-not($stateJson|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-shared-gateway-storage-state.schema.json') -ErrorAction Stop)){throw 'AI_SHARED_GATEWAY_STORAGE_STATE_INVALID'}
        foreach($item in Get-ChildItem -LiteralPath $stage -Force){if(-not(Test-LabAiSharedGatewayStorageProtection $item.FullName -File -Executable:($item.Name -ceq 'runtime.bin'))){throw 'AI_SHARED_GATEWAY_STORAGE_PROTECTION_FAILED'}}
        [IO.Directory]::Move($stage,$gatewayRoot);$published=$true
        return Get-LabAiSharedGatewayRegistrationReceipt $canonical $storedPreflight 'REGISTERED' $registeredAt
    }
    catch {
        $known=@('AI_SHARED_GATEWAY_STORAGE_LOCKED','AI_SHARED_GATEWAY_STORAGE_PROTECTION_FAILED','AI_SHARED_GATEWAY_STORAGE_STATE_INVALID','AI_SHARED_GATEWAY_STORAGE_CONFLICT','AI_SHARED_GATEWAY_STORAGE_DRIFT','AI_SHARED_GATEWAY_STORAGE_PATH_INVALID')
        if($_.Exception.Message -cin $known){throw $_.Exception.Message}
        throw 'AI_SHARED_GATEWAY_STORAGE_REGISTRATION_FAILED'
    }
    finally {
        if(-not $published -and $stage -and (Test-Path -LiteralPath $stage)){
            $resolvedStage=[IO.Path]::GetFullPath($stage);$resolvedShared=[IO.Path]::GetFullPath($sharedRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if($resolvedStage.StartsWith($resolvedShared,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedStage) -match '^\.register-[a-z][a-z0-9-]{0,62}-[a-f0-9]{32}$'){Remove-Item -LiteralPath $resolvedStage -Recurse -Force}
        }
        if(-not $published -and $sharedCreated -and (Test-Path -LiteralPath $sharedRoot -PathType Container) -and -not @(Get-ChildItem -LiteralPath $sharedRoot -Force).Count){Remove-Item -LiteralPath $sharedRoot -Force}
        if($acquired){try{$mutex.ReleaseMutex()}catch{}}
        $mutex.Dispose()
    }
}
