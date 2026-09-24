function Get-LabAiSharedGatewayInputFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try{$item=Get-Item -LiteralPath ([IO.Path]::GetFullPath($Path)) -ErrorAction Stop}catch{throw 'AI_SHARED_GATEWAY_INPUT_FILE_INVALID'}
    if($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'AI_SHARED_GATEWAY_INPUT_FILE_INVALID'}
    return $item
}

function Get-LabAiSharedGatewayFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IO.FileInfo]$File)
    try{$stream=$File.OpenRead();try{return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()}finally{$stream.Dispose()}}
    catch{throw 'AI_SHARED_GATEWAY_INPUT_FILE_UNREADABLE'}
}

function Test-LabAiSharedGatewayPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$ModelPath,
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][string]$CertificateAuthorityPath,
        [datetime]$VerifiedAtUtc=[datetime]::UtcNow
    )
    $canonical=Resolve-LabAiSharedGatewayPlan -Plan $Plan
    $files=@(
        Get-LabAiSharedGatewayInputFile -Path $RuntimePath
        Get-LabAiSharedGatewayInputFile -Path $ModelPath
        Get-LabAiSharedGatewayInputFile -Path $CertificatePath
        Get-LabAiSharedGatewayInputFile -Path $PrivateKeyPath
        Get-LabAiSharedGatewayInputFile -Path $CertificateAuthorityPath
    )
    $comparison=if([OperatingSystem]::IsWindows()){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}
    $unique=[Collections.Generic.HashSet[string]]::new($comparison)
    if(@($files|Where-Object{-not $unique.Add($_.FullName)}).Count){throw 'AI_SHARED_GATEWAY_INPUT_PATHS_MUST_DIFFER'}
    $runtimeHash=Get-LabAiSharedGatewayFileSha256 -File $files[0]
    if($runtimeHash -cne $canonical.RuntimeSha256){throw 'AI_SHARED_GATEWAY_RUNTIME_HASH_MISMATCH'}
    $modelHash=Get-LabAiSharedGatewayFileSha256 -File $files[1]
    if($modelHash -cne $canonical.ModelSha256){throw 'AI_SHARED_GATEWAY_MODEL_HASH_MISMATCH'}

    $leaf=$null;$root=$null;$chain=$null
    try {
        try{$leaf=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($files[2].FullName,$files[3].FullName)}catch{throw 'AI_SHARED_GATEWAY_CERTIFICATE_KEY_MISMATCH'}
        if(-not $leaf.HasPrivateKey){throw 'AI_SHARED_GATEWAY_CERTIFICATE_KEY_MISMATCH'}
        try{$root=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem([IO.File]::ReadAllText($files[4].FullName))}catch{throw 'AI_SHARED_GATEWAY_CERTIFICATE_AUTHORITY_INVALID'}
        $leafHash=$leaf.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
        $rootHash=$root.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
        if($leafHash -cne $canonical.ServerCertificateSha256){throw 'AI_SHARED_GATEWAY_SERVER_CERTIFICATE_HASH_MISMATCH'}
        if($rootHash -cne $canonical.CertificateAuthoritySha256){throw 'AI_SHARED_GATEWAY_CERTIFICATE_AUTHORITY_HASH_MISMATCH'}
        $now=$VerifiedAtUtc.ToUniversalTime()
        if($now -lt $leaf.NotBefore.ToUniversalTime() -or $now -gt $leaf.NotAfter.ToUniversalTime() -or
           $now -lt $root.NotBefore.ToUniversalTime() -or $now -gt $root.NotAfter.ToUniversalTime()){throw 'AI_SHARED_GATEWAY_CERTIFICATE_TIME_INVALID'}
        $hostName=([Uri]$canonical.Location).Host
        if(-not $leaf.MatchesHostname($hostName,$false,$false)){throw 'AI_SHARED_GATEWAY_CERTIFICATE_HOST_MISMATCH'}
        $chain=[Security.Cryptography.X509Certificates.X509Chain]::new()
        $chain.ChainPolicy.TrustMode=[Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        $null=$chain.ChainPolicy.CustomTrustStore.Add($root)
        $chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.DisableCertificateDownloads=$true
        $chain.ChainPolicy.VerificationTime=$now
        $null=$chain.ChainPolicy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        if(-not $chain.Build($leaf)){throw 'AI_SHARED_GATEWAY_CERTIFICATE_CHAIN_INVALID'}
        $identity=[ordered]@{Contract='SqlServerLab.AiSharedGatewayPreflightReceipt/1.0';PlanKey=$canonical.PlanKey;RuntimeSha256=$runtimeHash;ModelSha256=$modelHash;ServerCertificateSha256=$leafHash;CertificateAuthoritySha256=$rootHash;CertificateNotBeforeUtc=$leaf.NotBefore.ToUniversalTime().ToString('o');CertificateNotAfterUtc=$leaf.NotAfter.ToUniversalTime().ToString('o');VerifiedAtUtc=$now.ToString('o')}
        [pscustomobject]@{Contract=[pscustomobject]@{Name='SqlServerLab.AiSharedGatewayPreflightReceipt';Version='1.0'};Status='PREFLIGHT_VERIFIED';EvidenceStatus='LOCAL_ARTIFACTS_AND_CERTIFICATES';PlanKey=$canonical.PlanKey;RuntimeSha256=$runtimeHash;ModelSha256=$modelHash;ServerCertificateSha256=$leafHash;CertificateAuthoritySha256=$rootHash;CertificateNotBeforeUtc=$identity.CertificateNotBeforeUtc;CertificateNotAfterUtc=$identity.CertificateNotAfterUtc;VerifiedAtUtc=$identity.VerifiedAtUtc;VerifiedEvidence=@('RUNTIME_BINARY_MATCH','MODEL_FILE_MATCH','SERVER_CERTIFICATE_MATCH','CERTIFICATE_PRIVATE_KEY_MATCH','CERTIFICATE_AUTHORITY_MATCH','CERTIFICATE_CHAIN_MATCH','CERTIFICATE_HOST_MATCH','CERTIFICATE_TIME_VALID');PendingEvidence=@('PROTECTED_SHARED_STORAGE','PERSISTENT_GATEWAY_SERVICE','LIVE_ENDPOINT','SQL_CONSUMER_BINDINGS','BACKUP_RESTORE','ROTATION','ACCELERATOR_RUNTIME_ATTESTATION');ReceiptKey=Get-LabAiPlanKey -InputObject $identity}
    }
    finally{if($chain){$chain.Dispose()};if($root){$root.Dispose()};if($leaf){$leaf.Dispose()}}
}
