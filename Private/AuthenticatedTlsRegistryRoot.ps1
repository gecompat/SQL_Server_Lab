#Requires -Version 7.2
# Nur feste Metadatenpfade unter einem ausdruecklich registrierten Windows-Root.

function Read-LabTlsRegistryFileBytes {
    param([string]$Path)
    $stream=$null
    try {
        $null=Assert-LabDiagnosticPath $Path
        $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'TLS_ROOT_FILE_INVALID'}
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($stream.Length -lt 1 -or $stream.Length -gt 4194304){throw 'TLS_ROOT_FILE_INVALID'}
        $buffer=[byte[]]::new(4194305);$length=0
        while($length -lt $buffer.Length){
            $count=$stream.Read($buffer,$length,$buffer.Length-$length)
            if($count -eq 0){break};$length+=$count
        }
        if($length -lt 1 -or $length -gt 4194304){throw 'TLS_ROOT_FILE_INVALID'}
        $bytes=[byte[]]::new($length);[Buffer]::BlockCopy($buffer,0,$bytes,0,$length)
        return ,$bytes
    } finally {if($null -ne $stream){$stream.Dispose()}}
}

function Get-LabAuthenticatedTlsRegistryRoot {
    [CmdletBinding()]
    param([object]$DataRoot,[object]$ControllerId,[object]$LocationId)
    $bad=[pscustomobject][ordered]@{Success=$false;Value=$null;ErrorCode='TLS_REGISTRY_ROOT_INVALID'}
    try {
        # Nicht durch eine veraenderbare PowerShell-Plattformvariable umgehbar.
        if(-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows) -or
            $DataRoot -isnot [string] -or -not (Test-LabTlsRequestReference $ControllerId) -or -not (Test-LabTlsRequestReference $LocationId)){return $bad}
        if([string].GetProperty('Length').GetValue($DataRoot) -gt 4096 -or $DataRoot -cnotmatch '\A[A-Za-z]:[\\/][^:]*\z' -or
            $DataRoot -match '[\x00-\x1f<>"|?*]'){return $bad}
        foreach($segment in ($DataRoot -split '[\\/]')){if($segment -cin @('.','..') -or $segment -match '[. ]\z'){return $bad}}
        # Frische CLR-Zeichenfolge vor Pfadmethoden, keine Caller-ETS-Methoden.
        $root=Assert-LabDiagnosticPath ([IO.Path]::GetFullPath($DataRoot))
        $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
        if($drive.DriveType -ne [IO.DriveType]::Fixed -or -not (Test-Path -LiteralPath $root -PathType Container)){return $bad}
        $markerPath=Join-Path $root '.sql-server-lab-root.json'
        $catalogPath=Join-Path $root 'Catalog/storage-locations.json'
        $registryPath=Join-Path $root 'State/authenticated-tls/registry.json'
        # Der bestehende Reader verbietet Duplicate-/Casealias-Schluessel auch verschachtelt.
        $marker=Read-LabDiagnosticJson -Path $markerPath -MaximumBytes 16384 -MaximumDepth 8
        $catalog=Read-LabDiagnosticJson -Path $catalogPath -MaximumBytes 65536 -MaximumDepth 12
        if(-not (Test-LabTlsRequestEnum $marker.ContractVersion @('SqlServerLab.DataRoot/2.0')) -or
            -not (Test-LabTlsRequestEnum $marker.ManagedBy @('SQL_Server_Lab')) -or
            -not (Test-LabTlsRequestEnum $catalog.ContractVersion @('SqlServerLab.Storage/2.0')) -or
            -not (Test-LabTlsRequestEnum $marker.ControllerId @($ControllerId)) -or
            -not (Test-LabTlsRequestEnum $catalog.ControllerId @($ControllerId)) -or
            $marker.DataRoot -isnot [string] -or -not [string]::Equals($marker.DataRoot,$root,[StringComparison]::OrdinalIgnoreCase) -or
            $marker.VolumeId -isnot [string] -or [string]::IsNullOrWhiteSpace($marker.VolumeId) -or $marker.VolumeId.Length -gt 512 -or
            $catalog.LabDataLocations -isnot [array]){return $bad}
        $locations=$catalog.LabDataLocations
        if($locations.Count -lt 1 -or $locations.Count -gt 32){return $bad}
        $selected=$null;$rootMatches=0;$idMatches=0
        foreach($location in $locations){
            if($location.LabDataRoot -isnot [string] -or -not (Test-LabTlsRequestReference $location.LocationId)){return $bad}
            if([string]::Equals($location.LocationId,$LocationId,[StringComparison]::Ordinal)){$idMatches++}
            if([string]::Equals($location.LabDataRoot,$root,[StringComparison]::OrdinalIgnoreCase)){$rootMatches++;$selected=$location}
        }
        if($rootMatches -ne 1 -or $idMatches -ne 1 -or -not (Test-LabTlsRequestEnum $selected.LocationId @($LocationId)) -or
            -not (Test-LabTlsRequestEnum $selected.ControllerId @($ControllerId)) -or
            -not (Test-LabTlsRequestEnum $selected.VolumeId @($marker.VolumeId))){return $bad}
        $markerText=$marker|ConvertTo-Json -Depth 12 -Compress
        $catalogText=$catalog|ConvertTo-Json -Depth 12 -Compress
        $bytes=Read-LabTlsRegistryFileBytes $registryPath
        $parsed=Read-LabAuthenticatedTlsRegistryDocument $bytes
        if(-not $parsed.Success -or -not [string]::Equals($parsed.Value.RegistryDocument.Index.ControllerId,$ControllerId,[StringComparison]::Ordinal) -or
            -not [string]::Equals($parsed.Value.RegistryDocument.Index.LocationId,$LocationId,[StringComparison]::Ordinal)){return $bad}
        $fileDigest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        # Ein zweiter Befund erkennt beobachtete Drift, ist aber kein atomarer Snapshot oder CAS.
        $markerAgain=Read-LabDiagnosticJson -Path $markerPath -MaximumBytes 16384 -MaximumDepth 8
        $catalogAgain=Read-LabDiagnosticJson -Path $catalogPath -MaximumBytes 65536 -MaximumDepth 12
        $again=Read-LabTlsRegistryFileBytes $registryPath
        if(-not [string]::Equals($markerText,($markerAgain|ConvertTo-Json -Depth 12 -Compress),[StringComparison]::Ordinal) -or
            -not [string]::Equals($catalogText,($catalogAgain|ConvertTo-Json -Depth 12 -Compress),[StringComparison]::Ordinal) -or
            -not [string]::Equals($fileDigest,[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($again)).ToLowerInvariant(),[StringComparison]::Ordinal)){return $bad}
        $rootDigest=Get-LabTlsPayloadDigest @('SqlServerLab.TlsRegistryRootMetadata/0.1',$root,$markerText,$catalogText,$fileDigest)
        return [pscustomobject][ordered]@{Success=$true;Value=[pscustomobject][ordered]@{
            Status='REGISTERED_ROOT_METADATA_MATCH';DataRoot=$root;ControllerId=$marker.ControllerId;LocationId=$selected.LocationId;RegistryPath=$registryPath
            RegistryDocument=$parsed.Value.RegistryDocument;RegistryByteSha256=$fileDigest;ContentDigest=$parsed.Value.ContentDigest;RootMetadataDigest=$rootDigest
            RootBindingStatus='REGISTERED_METADATA_MATCH';NativeBindingStatus='NOT_EXECUTED';RegistrationStatus='NOT_EXECUTED';QualificationStatus='NOT_EXECUTED'
            SnapshotStatus='NON_ATOMIC_READ';Ready=$false;MutationAllowed=$false
        };ErrorCode=$null}
    } catch {return $bad}
}
