# Read-only capacity observation for one already registered host location.
function Get-LabInitialSetupCapacityObservation {
    param([string]$LocationId,[ValidateSet('NOT_CHECKED','AVAILABLE','UNKNOWN','UNREADABLE','UNSUPPORTED')][string]$Status='NOT_CHECKED',
        [string]$Code='INITIAL_SETUP_CAPACITY_NOT_CHECKED',$AvailableBytes=$null,$TotalBytes=$null,[string]$ObservedAt)
    [pscustomobject]@{ContractVersion='SqlServerLab.InitialSetupCapacity/1.0';LocationId=$LocationId;Status=$Status;Code=$Code
        AvailableBytes=$AvailableBytes;TotalBytes=$TotalBytes;ObservedAt=$(if($ObservedAt){$ObservedAt}elseif($Status -ne 'NOT_CHECKED'){[datetime]::UtcNow.ToString('o')}else{$null})
        Notice='Momentaufnahme des Hostdatenträgers für diesen Zugriff; keine Reservierung, Schreibbarkeits- oder SQL-Abnahme. Native Container-Volumes sind nicht erfasst.'}
}

function Get-LabInitialSetupCapacityValues {
    param([Parameter(Mandatory)][string]$VolumeRoot)
    $drive=[IO.DriveInfo]::new($VolumeRoot)
    [pscustomobject]@{AvailableBytes=$drive.AvailableFreeSpace;TotalBytes=$drive.TotalSize}
}

function Open-LabInitialSetupCapacityReadGuards {
    param([Parameter(Mandatory)]$Binding)
    $guards=[Collections.Generic.List[IDisposable]]::new()
    try {
        foreach($ancestor in @($Binding.Ancestors|Sort-Object {$_.Path.Length})) {
            $guards.Add([IO.File]::OpenHandle($ancestor.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read,[IO.FileOptions]0x02000000))
        }
        foreach($path in @($Binding.MarkerPath,(Join-Path $Binding.Root 'Catalog/storage-locations.json'))) {
            $guards.Add([IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
        }
        return ,$guards
    } catch {
        for($index=$guards.Count-1;$index -ge 0;$index--){$guards[$index].Dispose()}
        throw
    }
}

function Get-LabInitialSetupCapacityWorkerCore {
    param([Parameter(Mandatory)][string]$LocationId)
    $guards=$null;$observation=$null
    try {
        # The existing read binding validates the stored registration, controller,
        # volume identity and every ancestor. Fallback IDs, UNC, subst and folder
        # mounts/reparse paths cannot become capacity authority.
        $binding=Get-LabSetupWriteProbeBinding -LocationId $LocationId
        $guards=Open-LabInitialSetupCapacityReadGuards -Binding $binding
        $held=Get-LabSetupWriteProbeBinding -LocationId $LocationId
        if($held.Key -cne $binding.Key -or $held.Root -cne $binding.Root){throw 'INITIAL_SETUP_CAPACITY_BINDING_CHANGED'}
        $values=Get-LabInitialSetupCapacityValues -VolumeRoot ([IO.Path]::GetPathRoot($held.Root))
        $observedAt=[datetime]::UtcNow.ToString('o')
        if($values.AvailableBytes -isnot [long] -or $values.TotalBytes -isnot [long] -or
            $values.AvailableBytes -lt 0 -or $values.TotalBytes -le 0 -or $values.AvailableBytes -gt $values.TotalBytes -or
            $values.TotalBytes -gt 9007199254740991){throw 'INITIAL_SETUP_CAPACITY_VALUE_INVALID'}
        $after=Get-LabSetupWriteProbeBinding -LocationId $LocationId
        if($after.Key -cne $binding.Key -or $after.Root -cne $binding.Root){throw 'INITIAL_SETUP_CAPACITY_BINDING_CHANGED'}
        $observation=Get-LabInitialSetupCapacityObservation -LocationId $LocationId -Status AVAILABLE -Code INITIAL_SETUP_CAPACITY_OBSERVED -AvailableBytes $values.AvailableBytes -TotalBytes $values.TotalBytes -ObservedAt $observedAt
    } catch {
        $status='UNKNOWN';$code='INITIAL_SETUP_CAPACITY_BINDING_UNVERIFIED'
        if($_.Exception.Message -cmatch '^INITIAL_SETUP_PROBE_(PLATFORM|ROOT|FILESYSTEM)_UNSUPPORTED$'){$status='UNSUPPORTED';$code='INITIAL_SETUP_CAPACITY_UNSUPPORTED'}
        elseif($_.Exception.Message -ceq 'INITIAL_SETUP_PROBE_LOCATION_UNKNOWN'){$code='INITIAL_SETUP_CAPACITY_LOCATION_UNKNOWN'}
        elseif($_.Exception.Message -cmatch '^INITIAL_SETUP_CAPACITY_(BINDING_CHANGED|VALUE_INVALID)$'){$code=$_.Exception.Message}
        elseif($_.Exception.Message -cnotmatch '^INITIAL_SETUP_PROBE_[A-Z_]+$'){$status='UNREADABLE';$code='INITIAL_SETUP_CAPACITY_UNREADABLE'}
        $observation=Get-LabInitialSetupCapacityObservation -LocationId $LocationId -Status $status -Code $code
    } finally {
        if($guards){
            for($index=$guards.Count-1;$index -ge 0;$index--){
                try{$guards[$index].Dispose()}catch{$observation=Get-LabInitialSetupCapacityObservation -LocationId $LocationId -Status UNKNOWN -Code INITIAL_SETUP_CAPACITY_GUARD_CLOSE_UNCONFIRMED}
            }
        }
    }
    $observation
}

function Get-LabInitialSetupCapacity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$')][string]$LocationId,
        [ValidateRange(1000,20000)][int]$TimeoutMilliseconds=20000)
    $process=$null;$started=$false;$observation=$null
    try {
        $pwsh=Get-Command pwsh -ErrorAction Stop
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$pwsh.Source;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $script:ModuleRoot 'Tools/Read-InitialSetupCapacity.ps1'),'-LocationId',$LocationId)){$start.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$started=$process.Start()
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutMilliseconds)){throw 'INITIAL_SETUP_CAPACITY_TIMEOUT'}
        $json=$output.GetAwaiter().GetResult()
        if($json.Length -gt 8192){throw 'INITIAL_SETUP_CAPACITY_RESULT_INVALID'}
        # PowerShell versions may auto-convert ISO strings into local DateTime values.
        # Preserve the actual JSON timestamp string without requiring PS 7.5 DateKind.
        $document=[Text.Json.JsonDocument]::Parse([string]$json)
        try {
            if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
                $document.RootElement.GetProperty('ObservedAt').ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'INITIAL_SETUP_CAPACITY_RESULT_INVALID'}
            $properties=@($document.RootElement.EnumerateObject())
            if($properties.Count -ne 8 -or @($properties.Name|Sort-Object -Unique).Count -ne 8){throw 'INITIAL_SETUP_CAPACITY_RESULT_INVALID'}
            $timestampText=$document.RootElement.GetProperty('ObservedAt').GetString()
            $result=$json|ConvertFrom-Json -Depth 5 -ErrorAction Stop
            $result.ObservedAt=$timestampText
        } catch {throw 'INITIAL_SETUP_CAPACITY_RESULT_INVALID'}
        finally {$document.Dispose()}
        $null=$errors.GetAwaiter().GetResult()
        $timestamp=[datetimeoffset]::MinValue
        $allowedCodes=@{
            AVAILABLE=@('INITIAL_SETUP_CAPACITY_OBSERVED');UNSUPPORTED=@('INITIAL_SETUP_CAPACITY_UNSUPPORTED');UNREADABLE=@('INITIAL_SETUP_CAPACITY_UNREADABLE')
            UNKNOWN=@('INITIAL_SETUP_CAPACITY_BINDING_UNVERIFIED','INITIAL_SETUP_CAPACITY_LOCATION_UNKNOWN','INITIAL_SETUP_CAPACITY_BINDING_CHANGED','INITIAL_SETUP_CAPACITY_VALUE_INVALID','INITIAL_SETUP_CAPACITY_GUARD_CLOSE_UNCONFIRMED')
        }
        if($process.ExitCode -ne 0 -or $result -isnot [pscustomobject] -or $result.ContractVersion -cne 'SqlServerLab.InitialSetupCapacity/1.0' -or $result.LocationId -cne $LocationId -or
            $result.Status -cnotin @('AVAILABLE','UNKNOWN','UNREADABLE','UNSUPPORTED') -or $result.Code -isnot [string] -or $result.Code -cnotin $allowedCodes[$result.Status] -or
            @($result.PSObject.Properties.Name|Where-Object{$_ -cnotin @('ContractVersion','LocationId','Status','Code','AvailableBytes','TotalBytes','ObservedAt','Notice')}).Count -or
            $result.ObservedAt -isnot [string] -or -not [datetimeoffset]::TryParse($result.ObservedAt,[ref]$timestamp) -or $timestamp.Offset -ne [timespan]::Zero -or
            $timestamp.UtcDateTime -gt [datetime]::UtcNow.AddSeconds(5) -or $timestamp.UtcDateTime -lt [datetime]::UtcNow.AddMinutes(-1)) {throw 'INITIAL_SETUP_CAPACITY_RESULT_INVALID'}
        if($result.Status -ceq 'AVAILABLE') {
            if($result.AvailableBytes -isnot [long] -or $result.TotalBytes -isnot [long] -or $result.AvailableBytes -lt 0 -or $result.TotalBytes -le 0 -or $result.AvailableBytes -gt $result.TotalBytes -or $result.TotalBytes -gt 9007199254740991 -or $result.Code -cne 'INITIAL_SETUP_CAPACITY_OBSERVED'){throw 'INITIAL_SETUP_CAPACITY_RESULT_INVALID'}
        } elseif($null -ne $result.AvailableBytes -or $null -ne $result.TotalBytes) {throw 'INITIAL_SETUP_CAPACITY_RESULT_INVALID'}
        # Reconstruct the public DTO; do not expose a worker's raw notice or extra data.
        $observation=Get-LabInitialSetupCapacityObservation -LocationId $LocationId -Status $result.Status -Code $result.Code -AvailableBytes $result.AvailableBytes -TotalBytes $result.TotalBytes -ObservedAt $result.ObservedAt
    } catch {
        $code=if($_.Exception.Message -ceq 'INITIAL_SETUP_CAPACITY_TIMEOUT'){'INITIAL_SETUP_CAPACITY_TIMEOUT'}elseif($_.Exception.Message -ceq 'INITIAL_SETUP_CAPACITY_RESULT_INVALID'){'INITIAL_SETUP_CAPACITY_RESULT_INVALID'}else{'INITIAL_SETUP_CAPACITY_WORKER_UNAVAILABLE'}
        $observation=Get-LabInitialSetupCapacityObservation -LocationId $LocationId -Status UNKNOWN -Code $code
    } finally {
        if($process){
            try {
                if($started -and -not $process.HasExited){$process.Kill($true);if(-not $process.WaitForExit(2000)){throw 'OWN_WORKER_NOT_TERMINATED'}}
            } catch {$observation=Get-LabInitialSetupCapacityObservation -LocationId $LocationId -Status UNKNOWN -Code INITIAL_SETUP_CAPACITY_WORKER_TERMINATION_UNCONFIRMED}
            finally {try{$process.Dispose()}catch{$observation=Get-LabInitialSetupCapacityObservation -LocationId $LocationId -Status UNKNOWN -Code INITIAL_SETUP_CAPACITY_WORKER_UNAVAILABLE}}
        }
    }
    $observation
}

function Format-LabInitialSetupCapacity {
    param($Capacity)
    if($Capacity.Status -ceq 'AVAILABLE') {
        return ('Datenträgerfrei (Momentaufnahme): {0:N1} GiB verfügbar von {1:N1} GiB · gelesen {2}' -f ($Capacity.AvailableBytes/1GB),($Capacity.TotalBytes/1GB),([datetimeoffset]::Parse($Capacity.ObservedAt).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss UTC')))
    }
    switch($Capacity.Status){
        'UNSUPPORTED' {'Freien Speicher lesen wird für diesen Host oder Ablageort nicht unterstützt.'}
        'UNREADABLE' {'Der freie Speicher konnte nicht gelesen werden. Zugriff und Ablageort prüfen.'}
        'UNKNOWN' {'Freier Speicher unbekannt. Location und Zuordnung prüfen; bei Zeitüberschreitung später erneut lesen.'}
        default {'Datenträgerfrei: noch nicht gelesen.'}
    }
}
