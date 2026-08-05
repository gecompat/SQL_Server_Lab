@{
    RootModule        = 'SqlServerLab.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b3a7c4e1-9f2d-4a8b-b6c5-d1e0f3a2b4c7'
    Author            = 'gecompat - Gerhard Pisch'
    CompanyName       = 'gecompat'
    Copyright         = '(c) gecompat - Gerhard Pisch. Alle Rechte vorbehalten.'
    Description       = 'Isolierte SQL-Server-Testumgebungen mit Docker und Podman sowie Hyper-V-Lifecycle- und Image-Registry-Grundlage.'
    PowerShellVersion = '7.2'

    FunctionsToExport = @(
        'Invoke-SqlServerLab'
        'Get-SqlServerLabWorkflow'
        'Invoke-SqlServerLabWorkflowAction'
        'New-SqlServerLabManifest'
        'Test-SqlServerLabManifest'
        'New-SqlServerLab'
        'Get-SqlServerLab'
        'Start-SqlServerLab'
        'Stop-SqlServerLab'
        'Restart-SqlServerLab'
        'Remove-SqlServerLab'
        'Clear-SqlServerLab'
        'New-SqlServerLabDatabase'
        'Invoke-SqlServerLabScript'
        'Restore-SqlServerLabDatabase'
        'Test-SqlServerLabPrerequisite'
        'Test-SqlServerLabAdapter'
        'Install-SqlServerLabAdapter'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('SQL-Server', 'Lab', 'Docker', 'Podman', 'Testing')
            ProjectUri = 'https://github.com/gecompat/SQL_Server_Lab'
        }
    }
}
