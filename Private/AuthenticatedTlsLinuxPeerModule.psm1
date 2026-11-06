$script:ModuleRoot=Split-Path $PSScriptRoot -Parent
foreach($path in @('AuthenticatedTlsRegistryIndex.ps1','AuthenticatedTlsLab.ps1','AuthenticatedTlsLinuxPeer.ps1')){
    . (Join-Path $PSScriptRoot $path)
}
. (Join-Path $script:ModuleRoot 'Public/Read-SqlServerLabQualifiedTestEnvironment.ps1')
Export-ModuleMember -Function Read-SqlServerLabQualifiedTestEnvironment
