@{
    RootModule='Private/AuthenticatedTlsLinuxPeerModule.psm1'
    ModuleVersion='0.1.0'
    GUID='45a560c2-8938-4730-adba-068d1e98eff8'
    Author='SQL_Server_Lab'
    Description='Read-only public V2 peer; usable only inside an explicitly bootstrapped own Linux session.'
    PowerShellVersion='7.5'
    FunctionsToExport=@('Read-SqlServerLabQualifiedTestEnvironment')
    CmdletsToExport=@()
    VariablesToExport=@()
    AliasesToExport=@()
}
