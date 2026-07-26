Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:QuickTestLabRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..')
)

foreach ($relativePath in @(
        'Private/Common.ps1'
        'Private/LifecycleState.ps1'
        'Private/LifecycleRuntime.ps1'
        'Public/Invoke-QuickTestPreflight.ps1'
        'Public/Install-QuickTestLab.ps1'
        'Public/Get-QuickTestLabStatus.ps1'
        'Public/Invoke-QuickTestLabDown.ps1'
        'Public/Start-QuickTestLab.ps1'
        'Public/Start-QuickTestStoppedLab.ps1'
        'Public/Stop-QuickTestLab.ps1'
        'Public/Restart-QuickTestLab.ps1'
        'Public/Reset-QuickTestLab.ps1'
        'Public/Update-QuickTestFramework.ps1'
        'Public/Remove-QuickTestLab.ps1'
    )) {
    . (Join-Path $PSScriptRoot $relativePath)
}

Export-ModuleMember -Function @(
    'ConvertTo-QuickTestSecureString'
    'Get-QuickTestDefaultPorts'
    'Get-QuickTestLabStatus'
    'Get-QuickTestResourceProfile'
    'Install-QuickTestLab'
    'Invoke-QuickTestLabDown'
    'Invoke-QuickTestPreflight'
    'New-QuickTestPassword'
    'Remove-QuickTestLab'
    'Reset-QuickTestLab'
    'Resolve-QuickTestPorts'
    'Restart-QuickTestLab'
    'Start-QuickTestLab'
    'Start-QuickTestStoppedLab'
    'Stop-QuickTestLab'
    'Test-QuickTestPassword'
    'Update-QuickTestFramework'
)
