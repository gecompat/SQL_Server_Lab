# Internal durable local evidence; never an Actions artifact or dispatch input.
. (Join-Path $PSScriptRoot 'CSharpNativeProfileRequest.ps1')

function Assert-CSharpNativeEvidenceBinding {
    param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][string]$Commit,[Parameter(Mandatory)][string]$WorkflowRun)
    $names=@($Binding.PSObject.Properties.Name)
    if($names.Count -ne 4 -or @($names|Where-Object {$_ -cnotin @('Contract','OperationId','Commit','WorkflowRun')}).Count -or
        $Binding.Contract -cne 'SqlServerLab.CSharpNativeEvidence/1' -or $Binding.OperationId -cnotmatch '^csharp-native-[a-f0-9]{32}$' -or
        $Commit -cnotmatch '^[a-f0-9]{40}$' -or $WorkflowRun -cnotmatch '^[1-9][0-9]{0,19}$' -or
        $Binding.Commit -cne $Commit -or $Binding.WorkflowRun -cne $WorkflowRun){throw 'CSHARP_NATIVE_EVIDENCE_BINDING'}
}

function Get-CSharpNativeEvidence {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Commit,[Parameter(Mandatory)][string]$WorkflowRun)
    try {
        $volume=Get-CSharpNativeRequestVolumeRoot
        if([IO.Path]::GetDirectoryName($Root) -ine $volume.TrimEnd('\','/') -and [IO.Path]::GetDirectoryName($Root) -ine $volume){throw 'CSHARP_NATIVE_EVIDENCE_BINDING'}
        if([IO.Path]::GetFileName($Root) -cnotmatch '^SqlServerLab-CSharpEvidence-[a-f0-9]{32}$'){throw 'CSHARP_NATIVE_EVIDENCE_BINDING'}
        Assert-CSharpNativeRequestDirectory $Root
        $path=Join-Path $Root 'binding.json'
        Assert-CSharpNativeProfilePath $path
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            if($stream.Length -le 0 -or $stream.Length -gt 4096){throw 'CSHARP_NATIVE_EVIDENCE_BINDING'}
            $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$false,4096,$true)
            try {$binding=$reader.ReadToEnd()|ConvertFrom-Json -ErrorAction Stop}finally{$reader.Dispose()}
        }finally{$stream.Dispose()}
        Assert-CSharpNativeEvidenceBinding $binding $Commit $WorkflowRun
        if($binding.OperationId.Substring('csharp-native-'.Length) -cne [IO.Path]::GetFileName($Root).Substring('SqlServerLab-CSharpEvidence-'.Length)){throw 'CSHARP_NATIVE_EVIDENCE_BINDING'}
        return $binding
    }catch{throw 'CSHARP_NATIVE_EVIDENCE_BINDING'}
}

function New-CSharpNativeEvidence {
    param([Parameter(Mandatory)][string]$Commit,[Parameter(Mandatory)][string]$WorkflowRun)
    $id=[guid]::NewGuid().ToString('N')
    $binding=[pscustomobject]@{Contract='SqlServerLab.CSharpNativeEvidence/1';OperationId=('csharp-native-'+$id);Commit=$Commit;WorkflowRun=$WorkflowRun}
    Assert-CSharpNativeEvidenceBinding $binding $Commit $WorkflowRun
    try {
        $volume=Get-CSharpNativeRequestVolumeRoot
        $root=Join-Path $volume ('SqlServerLab-CSharpEvidence-'+$id)
        # Existing roots are never adopted. Initial ACL already excludes ordinary users.
        New-CSharpNativeTemporaryDirectory $root -CurrentIdentityRead
        $owned=[pscustomobject]@{Root=$root;File=(Join-Path $root 'binding.json');FileOwned=$false}
        Write-CSharpNativeTemporaryProfile -Owned $owned -Json ($binding|ConvertTo-Json -Compress) -CurrentIdentityRead
        $null=Get-CSharpNativeEvidence $root $Commit $WorkflowRun
        return $root
    }catch{throw 'CSHARP_NATIVE_EVIDENCE_CREATE'}
}

function Claim-CSharpNativeEvidence {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Commit,[Parameter(Mandatory)][string]$WorkflowRun)
    $binding=Get-CSharpNativeEvidence $Root $Commit $WorkflowRun
    try {
        $stream=[IO.File]::Open((Join-Path $Root 'supervisor.claim'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try {$bytes=[Text.Encoding]::UTF8.GetBytes($binding.OperationId);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    }catch{throw 'CSHARP_NATIVE_EVIDENCE_ALREADY_CLAIMED'}
    return $binding
}
