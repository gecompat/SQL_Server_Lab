@{
    RootModule        = 'SqlServerLab.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'b3a7c4e1-9f2d-4a8b-b6c5-d1e0f3a2b4c7'
    Author            = 'gecompat - Gerhard Pisch'
    CompanyName       = 'gecompat'
    Copyright         = '(c) gecompat - Gerhard Pisch. Alle Rechte vorbehalten.'
    Description       = 'Isolierte SQL-Server-Testumgebungen mit Docker und Podman sowie Hyper-V-Lifecycle- und Image-Registry-Grundlage.'
    PowerShellVersion = '7.2'

    FunctionsToExport = @(
        'New-SqlServerLabBatch'
        'Get-SqlServerLabBatch'
        'Get-SqlServerLabQueue'
        'Get-SqlServerLabOperation'
        'Confirm-SqlServerLabOperationUserAction'
        'Move-SqlServerLabOperation'
        'Set-SqlServerLabOperationPriority'
        'Suspend-SqlServerLabOperation'
        'Resume-SqlServerLabOperation'
        'Stop-SqlServerLabOperation'
        'Stop-SqlServerLabBatch'
        'Invoke-SqlServerLabScheduler'
        'Invoke-SqlServerLab'
        'Get-SqlServerLabWorkflow'
        'Get-SqlServerLabCatalog'
        'Get-SqlServerLabConnectionCenter'
        'Sync-SqlServerLabConnectionCenter'
        'Export-SqlServerLabSsmsRegistration'
        'Export-SqlServerLabCmsSyncScript'
        'Initialize-SqlServerLabCms'
        'Sync-SqlServerLabCms'
        'Get-SqlServerLabReconcilePlan'
        'Invoke-SqlServerLabReconcileAction'
        'Invoke-SqlServerLabWorkflowAction'
        'New-SqlServerLabManifest'
        'Test-SqlServerLabManifest'
        'New-SqlServerLab'
        'Get-SqlServerLab'
        'Get-SqlServerLabGeneratedSqlAccess'
        'New-SqlServerLabAutomatedTestEnvironment'
        'Export-SqlServerLabTestEnvironment'
        'Clear-SqlServerLabAutomatedTestEnvironment'
        'Start-SqlServerLab'
        'Stop-SqlServerLab'
        'Restart-SqlServerLab'
        'Remove-SqlServerLab'
        'Clear-SqlServerLab'
        'Get-SqlServerLabCleanupAudit'
        'New-SqlServerLabDatabase'
        'Invoke-SqlServerLabScript'
        'Restore-SqlServerLabDatabase'
        'Test-SqlServerLabPrerequisite'
        'Test-SqlServerLabAdapter'
        'Install-SqlServerLabAdapter'
        'Install-SqlServerLab7Zip'
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
