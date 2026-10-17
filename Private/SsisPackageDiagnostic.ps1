# Begrenzte lokale Artefaktlesung; keine Extraktion auf Platte und kein Paketumbau.
function Read-LabSsisDiagnosticPackage {
    [CmdletBinding()]
    param([string]$Path,[string]$ExpectedSha256,[string]$PackageName,[switch]$Ispac)
    $stream=$null;$memory=$null;$archive=$null;$entryStream=$null
    try {
        $full=Assert-LabDiagnosticPath -Path $Path
        $extension=if($Ispac){'.ispac'}else{'.dtsx'}
        if ([IO.Path]::GetExtension($full) -ine $extension) { throw 'SSIS_DIAGNOSTIC_ARTIFACT_INVALID' }
        $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ($stream.Length -lt 1 -or $stream.Length -gt 16MB) { throw 'SSIS_DIAGNOSTIC_SIZE_LIMIT' }
        # Dieselben begrenzten Bytes werden gehasht und gelesen; keine zweite Pfadöffnung.
        $bytes=[byte[]]::new([int]$stream.Length)
        $offset=0
        while ($offset -lt $bytes.Length) {
            $count=$stream.Read($bytes,$offset,$bytes.Length-$offset)
            if ($count -eq 0) { throw 'SSIS_DIAGNOSTIC_ARTIFACT_UNREADABLE' };$offset+=$count
        }
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        if ($hash -ine $ExpectedSha256) { throw 'SSIS_DIAGNOSTIC_HASH_MISMATCH' }
        $package=$bytes
        if ($Ispac) {
            $memory=[IO.MemoryStream]::new($bytes,$false)
            $archive=[IO.Compression.ZipArchive]::new($memory,[IO.Compression.ZipArchiveMode]::Read,$true)
            if ($archive.Entries.Count -gt 256) { throw 'SSIS_DIAGNOSTIC_ENTRY_LIMIT' }
            $entries=@($archive.Entries | Where-Object { $_.FullName -ieq $PackageName })
            if ($entries.Count -ne 1 -or $entries[0].FullName -cne $PackageName) { throw 'SSIS_DIAGNOSTIC_PACKAGE_ENTRY_INVALID' }
            if ($entries[0].Length -lt 1 -or $entries[0].Length -gt 8MB) { throw 'SSIS_DIAGNOSTIC_SIZE_LIMIT' }
            $entryStream=$entries[0].Open()
            $package=[byte[]]::new([int]$entries[0].Length)
            $offset=0
            while ($offset -lt $package.Length) {
                $count=$entryStream.Read($package,$offset,$package.Length-$offset)
                if ($count -eq 0) { throw 'SSIS_DIAGNOSTIC_ARTIFACT_UNREADABLE' };$offset+=$count
            }
            if ($entryStream.ReadByte() -ne -1) { throw 'SSIS_DIAGNOSTIC_SIZE_LIMIT' }
        }
        if ($package.Length -gt 8MB) { throw 'SSIS_DIAGNOSTIC_SIZE_LIMIT' }
        [pscustomobject]@{ArtifactSha256=$hash;PackageSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($package));Bytes=$package}
    }
    catch {
        $code=$_.Exception.Message
        if ($code -cnotmatch '^SSIS_DIAGNOSTIC_(ARTIFACT_INVALID|SIZE_LIMIT|HASH_MISMATCH|ENTRY_LIMIT|PACKAGE_ENTRY_INVALID)$') { $code='SSIS_DIAGNOSTIC_ARTIFACT_UNREADABLE' }
        throw $code
    }
    finally {
        if($entryStream){$entryStream.Dispose()};if($archive){$archive.Dispose()}
        if($memory){$memory.Dispose()};if($stream){$stream.Dispose()}
    }
}

function Invoke-LabSsisPackageDiagnostic {
    [CmdletBinding()]
    param([guid]$RunId,[string]$InstanceId,[string]$StateRoot,$Artifact,[int]$TimeoutSeconds)
    $credential=$null;$observation=$null;$reason='NONE'
    try {
        $context=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $credential=Get-LabSecret -Path $context.Directory -Name 'guest-administrator-password'
        if (-not $credential) { throw 'SSIS_DIAGNOSTIC_CREDENTIAL_UNAVAILABLE' }
        $fresh=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ($fresh.Fingerprint -cne $context.Fingerprint) { throw 'SSIS_DIAGNOSTIC_BINDING_CHANGED' }
        $result=@(Invoke-HyperVPowerShellDirect -VMName ([string]$context.Instance.vmName) -ExpectedRunId $RunId.ToString() `
            -ExpectedScopeId ([string]$context.Run.scopeId) -ExpectedVmId ([guid]$context.Instance.vmId) `
            -Credential ([pscredential]::new('Administrator',$credential)) -ScriptBlock (Get-LabSsisPackageDiagnosticGuest) `
            -ArgumentList @($Artifact.Bytes,$Artifact.PackageSha256,[int]$context.ExpectedMajor) `
            -NoRetry -TimeoutSeconds $TimeoutSeconds -ErrorAction Stop 3>$null 4>$null 5>$null 6>$null)
        $fresh=Get-LabSsisPrerequisiteContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ($fresh.Fingerprint -cne $context.Fingerprint) { throw 'SSIS_DIAGNOSTIC_BINDING_CHANGED' }
        if ($result.Count -ne 1 -or $result[0].ContractVersion -cne 'SqlServerLab.SsisPackageGuest/1.0' -or
            $result[0].PackageSha256 -cne $Artifact.PackageSha256 -or $result[0].Status -cnotin @('OBSERVED','LOAD_FAILED','INCONCLUSIVE')) { throw 'SSIS_DIAGNOSTIC_RESULT_INVALID' }
        $observation=$result[0]
    }
    catch {
        $reason=$_.Exception.Message
        if ($reason -cnotin @('SSIS_DIAGNOSTIC_CREDENTIAL_UNAVAILABLE','SSIS_DIAGNOSTIC_BINDING_CHANGED','SSIS_DIAGNOSTIC_RESULT_INVALID')) { $reason='SSIS_DIAGNOSTIC_TARGET_OR_TRANSPORT_UNAVAILABLE' }
    }
    finally { if($credential){$credential.Dispose()} }
    [pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.SsisPackageDiagnostic/1.0'
        Target=[pscustomobject]@{RunId=$RunId.ToString();InstanceId=$InstanceId;Provider='hyperv'}
        ArtifactSha256=$Artifact.ArtifactSha256;PackageSha256=$Artifact.PackageSha256
        Status=$(if($observation){$observation.Status}else{'INCONCLUSIVE'})
        ReasonCode=$(if($observation){$observation.ReasonCode}else{$reason})
        Observation=$observation
        ExecutionStatus='NOT_EXECUTED';ReadOnly=$true
    }
}
