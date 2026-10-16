#Requires -Version 5.1
<#
.SYNOPSIS
    Prüft den tatsächlichen Managementloader mit vorhandenen IS-17-Assemblies ohne SQL-Zugriff.
.DESCRIPTION
    Windows PowerShell verwenden. Es werden ausschließlich die vorhandenen
    IS-Dateien geladen, eine geschlossene SqlConnection konstruiert und die
    IS-/Catalog-Konstruktorsignaturen geprüft. Kein Open(), Create(), Download,
    SDK-Setup oder Providerstart.
#>
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/SsisOwnedInstall.ps1')
$loader=(Get-LabSsisCatalogFixtureGuestProbe).Ast.Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SsisInstalledCatalogManagementTypes'
},$true)
if(-not $loader){throw 'SSIS_MANAGEMENT_LOADER_MISSING'}
. ([scriptblock]::Create($loader.Extent.Text))
$types=Get-SsisInstalledCatalogManagementTypes -BinnDirectory (Join-Path $env:ProgramFiles 'Microsoft SQL Server/170/DTS/Binn')
$connection=$null
try {
    # Deliberately unused loopback endpoint. Neither connection.Open nor catalog.Create
    # is invoked: this is a loader/constructor proof, not a database acceptance.
    $connection=[Activator]::CreateInstance($types.SqlConnection,[object[]]@('Data Source=tcp:127.0.0.1,1;Integrated Security=SSPI;Connect Timeout=1;Encrypt=False;Pooling=False'))
    # IntegrationServices itself opens SQL in its constructor. Inspect that
    # signature instead; only the closed SqlConnection object is instantiated.
    $servicesConstructor=$types.IntegrationServices.GetConstructor([type[]]@($types.SqlConnection))
    $catalogConstructor=$types.Catalog.GetConstructor([type[]]@($types.IntegrationServices,[string],[string]))
    if($connection.State -ne 'Closed' -or -not $servicesConstructor -or -not $catalogConstructor){throw 'SSIS_MANAGEMENT_CONSTRUCTION_INVALID'}
    $null=$servicesConstructor.ToString();$null=$catalogConstructor.ToString()
    foreach($request in @(
        'Untrusted.Assembly, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null',
        'System.Memory, Version=9.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51',
        'System.Memory, Version=4.0.1.1, Culture=neutral, PublicKeyToken=0000000000000000'
    )){
        if($null -ne $types.Resolver.Invoke($null,[ResolveEventArgs]::new($request))){throw 'SSIS_MANAGEMENT_RESOLVER_FAIL_OPEN'}
    }
    Write-Host 'SSIS_CATALOG_MANAGEMENT_ACCEPTANCE_PASSED; installed dependencies and Microsoft.Data.SqlClient constructor verified; SQL NOT_EXECUTED'
} finally {if($connection){$connection.Dispose()};if($types.Resolver){[AppDomain]::CurrentDomain.remove_AssemblyResolve($types.Resolver)}}
