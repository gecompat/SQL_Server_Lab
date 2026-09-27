# Executable resolver and host-contract checks; no provider mutation.
$v2 = & $module {
    $results = [Collections.Generic.List[object]]::new()
    foreach ($provider in @('docker','podman')) {
        $plans = @('sql-python','sql-r','sql-java' | ForEach-Object {
            Resolve-LabExternalRuntimePlan -SoftwareItem ([pscustomobject]@{
                Id=$_; Variant="$_-2025-shared-user-v2"; Version=$null
                InstallMethod='catalog'; Packages=@(); RequestSource='test'
            }) -SqlVersion 2025 -Provider $provider -OperatingSystem linux
        })
        $image = New-LabExternalRuntimeContainerImagePlan -Provider $provider -SqlVersion 2025 -SoftwarePlans $plans
        $request = [pscustomobject]@{Id='sql-python';Variant=$null;Version=$null;InstallMethod='catalog';Packages=@();RequestSource='test'}
        $default = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion 2025 -Provider $provider -OperatingSystem linux
        $mixedRejected = $false
        try { $null = New-LabExternalRuntimeContainerImagePlan -Provider $provider -SqlVersion 2025 -SoftwarePlans @($default,$plans[1]) }
        catch { $mixedRejected = $_.Exception.Message -match 'MIXED_ISOLATION' }
        $request.Variant='sql-python-2025-shared-user-v2'
        $oldSql = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion 2022 -Provider $provider -OperatingSystem linux
        $info = if ($provider -eq 'docker') { [pscustomobject]@{OSType='linux';CgroupVersion='2';SecurityOptions=@()} }
            else { [pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupVersion='v2';security=[pscustomobject]@{rootless=$false}}} }
        $hostResult = Get-LabExternalRuntimeHostCapability -Provider $provider -SqlVersion 2025 -RequiredCgroupVersion 2 -RuntimeInfo $info -ToolAvailable $true -RuntimeReachable $true
        $defaultHost = Get-LabExternalRuntimeHostCapability -Provider $provider -SqlVersion 2025 -RuntimeInfo $info -ToolAvailable $true -RuntimeReachable $true
        $results.Add([pscustomobject]@{Provider=$provider;Plans=$plans;Image=$image;Default=$default;MixedRejected=$mixedRejected;OldSql=$oldSql;Host=$hostResult;DefaultHost=$defaultHost})
    }
    @($results)
}
foreach ($case in $v2) {
    Add-CheckResult -Name "$($case.Provider): shared-user nur explizit, SQL 2025 und einheitlich" -Success (
        @($case.Plans | Where-Object Status -ne RESOLVED).Count -eq 0 -and
        -not $case.Default.LaunchMode -and $case.MixedRejected -and
        $case.OldSql.Status -eq 'DECLARED_UNSUPPORTED'
    )
    Add-CheckResult -Name "$($case.Provider): v2-Profil bindet CU9, Worker-Isolation und Imageidentitaet" -Success (
        $case.Image.LaunchMode -eq 'sql2025-shared-user-v2' -and
        $case.Image.RequiredCgroupVersion -eq '2' -and -not $case.Image.NamespaceIsolation -and $case.Image.OutboundAccess -and
        $case.Image.ExtensibilityDebVersion -eq '17.0.5005.3-1' -and
        $case.Image.BaseImageDigest -eq '2b5b581621126574f3d1f75e78d3eebe8d05aedb59ad0cfdf9aa42cb0634d726' -and
        $case.Host.Supported -and -not $case.DefaultHost.Supported
    )
}
Add-CheckResult -Name 'Docker und Podman verwenden denselben gebundenen v2-Imageinhalt' -Success ($v2[0].Image.ImageKey -eq $v2[1].Image.ImageKey)
$negative = & $module {
    param($Image)
    $rootlessInfo=[pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupVersion='v2';security=[pscustomobject]@{rootless=$true}}}
    $rootless=Get-LabExternalRuntimeHostCapability -Provider podman -SqlVersion 2025 -RequiredCgroupVersion 2 -RuntimeInfo $rootlessInfo -ToolAvailable $true -RuntimeReachable $true
    $rejected=0
    foreach($field in @('SqlVersion','RequiredCgroupVersion','NamespaceIsolation','OutboundAccess')) {
        $bad=$Image|Select-Object *
        switch($field) {
            SqlVersion {$bad.SqlVersion='2022'}
            RequiredCgroupVersion {$bad.RequiredCgroupVersion='1'}
            NamespaceIsolation {$bad.NamespaceIsolation=$true}
            OutboundAccess {$bad.OutboundAccess=$false}
        }
        try {$null=Test-LabExternalRuntimeContainerHost -Provider docker -ImagePlan $bad}
        catch {if($_.Exception.Message -match 'LAUNCH_CONTRACT_INVALID'){$rejected++}}
    }
    [pscustomobject]@{Rejected=$rejected;Rootless=$rootless}
} $v2[0].Image
Add-CheckResult -Name 'v2 lehnt rootless und manipulierte Versions-/Isolationsvertraege vor Hostzugriff ab' -Success (
    $negative.Rejected -eq 4 -and $negative.Rootless.ReasonCode -eq 'ROOTFUL_PROVIDER_REQUIRED'
)
