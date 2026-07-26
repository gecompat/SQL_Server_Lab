@{
    RootModule        = 'SqlServerLab.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b3a7c4e1-9f2d-4a8b-b6c5-d1e0f3a2b4c7'
    Author            = 'gecompat - Gerhard Pisch'
    CompanyName       = 'gecompat'
    Copyright         = '(c) gecompat - Gerhard Pisch. Alle Rechte vorbehalten.'
    Description       = 'Isolierte, reproduzierbare SQL-Server-Testumgebungen (Docker, Podman, Hyper-V)'
    PowerShellVersion = '7.2'

    FunctionsToExport = @(
        'Invoke-SqlServerLab'
        'New-SqlServerLab'
        'Get-SqlServerLab'
        'Start-SqlServerLab'
        'Stop-SqlServerLab'
        'Restart-SqlServerLab'
        'Remove-SqlServerLab'
        'New-LabDatabase'
        'Invoke-LabScript'
        'Install-LabSoftware'
        'Test-LabResources'
        'Invoke-LabCleanup'
        'Invoke-LabRecovery'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('SQL-Server', 'Lab', 'Docker', 'HyperV', 'Testing')
            ProjectUri = 'https://github.com/gecompat/SQL_Server_Lab'
        }
    }
}
