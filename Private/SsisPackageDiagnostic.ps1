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

# Remotingobjekte niemals direkt veröffentlichen: auch verschachtelte Werte
# werden auf den dokumentierten, begrenzten Diagnosevertrag projiziert.
function ConvertTo-LabSsisDiagnosticObservation {
    [CmdletBinding()]
    param($Value,[string]$PackageSha256,[int]$ExpectedMajor)
    function Assert-DiagnosticFields {
        param($Object,[string[]]$Names)
        if ($null -eq $Object) { throw 'INVALID' }
        foreach ($name in $Names) {
            if ($null -eq $Object.PSObject.Properties[$name]) { throw 'INVALID' }
        }
    }
    function Get-DiagnosticNames {
        param($Values)
        if ($null -eq $Values -or $Values -is [string] -or $Values -isnot [Collections.IEnumerable] -or @($Values).Count -gt 512) { throw 'INVALID' }
        foreach ($item in $Values) {
            if ($item -isnot [string] -or $item -cnotmatch '^[A-Za-z0-9_{}.,:=+ -]{1,512}$') { throw 'INVALID' }
            [string]$item
        }
    }
    try {
        Assert-DiagnosticFields $Value @('ContractVersion','PackageSha256','Status','ReasonCode','Runtime','Inventory','Serialized','LoadStatus','LoadedObjectCounts','ExceptionHResult','Events','EventsTruncated','ExecutionStatus')
        foreach ($name in @('ContractVersion','PackageSha256','Status','ReasonCode','LoadStatus','ExecutionStatus')) {
            if ($Value.$name -isnot [string]) { throw 'INVALID' }
        }
        if ($Value.ContractVersion -cne 'SqlServerLab.SsisPackageGuest/1.0' -or $Value.PackageSha256 -cne $PackageSha256 -or
            $Value.Status -cnotin @('OBSERVED','LOAD_FAILED','INCONCLUSIVE') -or $Value.ExecutionStatus -cne 'NOT_EXECUTED' -or
            $Value.LoadStatus -cnotin @('NOT_ATTEMPTED','RETURNED','FAILED') -or $Value.EventsTruncated -isnot [bool] -or
            $Value.ReasonCode -cnotin @('NONE','RUNTIME_UNAVAILABLE','PACKAGE_XML_INVALID','PACKAGE_HASH_MISMATCH','X64_RUNTIME_REQUIRED','COMPONENT_INVENTORY_FAILED','PACKAGE_LOAD_FAILED','EVENT_LIMIT')) { throw 'INVALID' }
        $runtime=$null
        if ($null -ne $Value.Runtime) {
            Assert-DiagnosticFields $Value.Runtime @('AssemblyIdentity','FileVersion','ProcessBitness','OperatingSystemBitness','ClrVersion','PowerShellVersion')
            if ($Value.Runtime.AssemblyIdentity -isnot [string] -or $Value.Runtime.AssemblyIdentity -cne "Microsoft.SqlServer.ManagedDTS, Version=$ExpectedMajor.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91" -or
                $Value.Runtime.ProcessBitness -isnot [int] -or $Value.Runtime.ProcessBitness -ne 64 -or
                $Value.Runtime.OperatingSystemBitness -isnot [int] -or $Value.Runtime.OperatingSystemBitness -ne 64) { throw 'INVALID' }
            foreach ($name in @('FileVersion','ClrVersion','PowerShellVersion')) {
                if ($Value.Runtime.$name -isnot [string] -or $Value.Runtime.$name -cnotmatch '^[0-9]{1,8}(\.[0-9]{1,8}){1,3}$') { throw 'INVALID' }
            }
            $runtime=[pscustomobject]@{AssemblyIdentity=[string]$Value.Runtime.AssemblyIdentity;FileVersion=[string]$Value.Runtime.FileVersion;
                ProcessBitness=64;OperatingSystemBitness=64;ClrVersion=[string]$Value.Runtime.ClrVersion;PowerShellVersion=[string]$Value.Runtime.PowerShellVersion}
        }
        Assert-DiagnosticFields $Value.Inventory @('Complete','ConnectionManagers','LogProviders')
        Assert-DiagnosticFields $Value.Serialized @('ConnectionManagers','LogProviders')
        if ($Value.Inventory.Complete -isnot [bool]) { throw 'INVALID' }
        $inventory=[pscustomobject]@{Complete=[bool]$Value.Inventory.Complete;ConnectionManagers=@(Get-DiagnosticNames $Value.Inventory.ConnectionManagers);LogProviders=@(Get-DiagnosticNames $Value.Inventory.LogProviders)}
        $serialized=[pscustomobject]@{ConnectionManagers=@(Get-DiagnosticNames $Value.Serialized.ConnectionManagers);LogProviders=@(Get-DiagnosticNames $Value.Serialized.LogProviders)}
        $counts=$null
        if ($null -ne $Value.LoadedObjectCounts) {
            Assert-DiagnosticFields $Value.LoadedObjectCounts @('ConnectionManagers','LogProviders','Executables')
            foreach ($name in @('ConnectionManagers','LogProviders','Executables')) {
                if ($Value.LoadedObjectCounts.$name -isnot [int] -or $Value.LoadedObjectCounts.$name -lt 0) { throw 'INVALID' }
            }
            $counts=[pscustomobject]@{ConnectionManagers=[int]$Value.LoadedObjectCounts.ConnectionManagers;LogProviders=[int]$Value.LoadedObjectCounts.LogProviders;Executables=[int]$Value.LoadedObjectCounts.Executables}
        }
        if ($null -ne $Value.ExceptionHResult -and $Value.ExceptionHResult -isnot [int]) { throw 'INVALID' }
        if ($null -eq $Value.Events -or $Value.Events -is [string] -or $Value.Events -isnot [Collections.IEnumerable] -or @($Value.Events).Count -gt 256) { throw 'INVALID' }
        $events=@(foreach ($eventItem in $Value.Events) {
            Assert-DiagnosticFields $eventItem @('Kind','Code')
            if ($eventItem.Kind -isnot [string] -or $eventItem.Kind -cnotin @('ERROR','WARNING','PACKAGE_ERROR') -or $eventItem.Code -isnot [int]) { throw 'INVALID' }
            [pscustomobject]@{Kind=[string]$eventItem.Kind;Code=[int]$eventItem.Code}
        })
        $hasErrors=@($events | Where-Object Kind -in @('ERROR','PACKAGE_ERROR')).Count -gt 0
        if ($Value.Status -cne 'INCONCLUSIVE' -and ($null -eq $runtime -or -not $inventory.Complete -or $null -eq $counts -or $Value.EventsTruncated)) { throw 'INVALID' }
        if ($Value.Status -ceq 'OBSERVED' -and ($Value.ReasonCode -cne 'NONE' -or $Value.LoadStatus -cne 'RETURNED' -or $null -ne $Value.ExceptionHResult -or $hasErrors)) { throw 'INVALID' }
        if ($Value.Status -ceq 'LOAD_FAILED' -and ($Value.ReasonCode -cne 'PACKAGE_LOAD_FAILED' -or
            $Value.LoadStatus -ceq 'NOT_ATTEMPTED' -or (-not $hasErrors -and $null -eq $Value.ExceptionHResult))) { throw 'INVALID' }
        if ($Value.Status -ceq 'INCONCLUSIVE' -and $Value.ReasonCode -ceq 'NONE') { throw 'INVALID' }
        [pscustomobject][ordered]@{
            ContractVersion='SqlServerLab.SsisPackageGuest/1.0';PackageSha256=$PackageSha256
            Status=[string]$Value.Status;ReasonCode=[string]$Value.ReasonCode;Runtime=$runtime;Inventory=$inventory;Serialized=$serialized
            LoadStatus=[string]$Value.LoadStatus;LoadedObjectCounts=$counts;ExceptionHResult=$Value.ExceptionHResult
            Events=$events;EventsTruncated=[bool]$Value.EventsTruncated;ExecutionStatus='NOT_EXECUTED'
        }
    }
    catch { throw 'SSIS_DIAGNOSTIC_RESULT_INVALID' }
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
        if ($result.Count -ne 1) { throw 'SSIS_DIAGNOSTIC_RESULT_INVALID' }
        $observation=ConvertTo-LabSsisDiagnosticObservation -Value $result[0] -PackageSha256 $Artifact.PackageSha256 -ExpectedMajor $context.ExpectedMajor
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
