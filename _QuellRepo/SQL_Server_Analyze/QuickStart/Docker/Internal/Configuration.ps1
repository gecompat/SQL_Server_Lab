$configurationRoot = Join-Path $PSScriptRoot 'Configuration'
foreach ($configurationScript in @(
        'Parameters.ps1',
        'Environment.ps1',
        'Storage.ps1',
        'SetupConfiguration.ps1'
    )) {
    . (Join-Path $configurationRoot $configurationScript)
}
