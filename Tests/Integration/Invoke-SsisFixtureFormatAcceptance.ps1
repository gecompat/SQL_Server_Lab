#Requires -Version 5.1
<#
.SYNOPSIS
    Prüft die synthetische ISPAC mit der vorhandenen SSIS-17-Runtime, ohne SQL oder VM.
.DESCRIPTION
    Windows PowerShell verwenden. Lädt nur die bereits installierte Runtime;
    kein Download, SQL-Zugriff oder Providerstart. Prüft den tatsächlichen
    produktiven Writer mit Microsofts unabhängigem Project.OpenProject-Reader.
#>
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$null=[Reflection.Assembly]::Load('Microsoft.SqlServer.ManagedDTS, Version=17.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91')
. (Join-Path $repoRoot 'Private/SsisOwnedInstall.ps1')
$writer=(Get-LabSsisCatalogFixtureGuestProbe).Ast.Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-SsisFixtureProject'
},$true)
if(-not $writer){throw 'SSIS_FIXTURE_WRITER_MISSING'}
. ([scriptblock]::Create($writer.Extent.Text))
$directory=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ssis-format-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $directory
$project=$null
try {
    $path=Write-SsisFixtureProject -Directory $directory -ProjectName 'LabFormatAcceptance'
    $project=[Microsoft.SqlServer.Dts.Runtime.Project]::OpenProject($path)
    if($project.Name -cne 'LabFormatAcceptance' -or $project.PackageItems.Count -ne 3){throw 'SSIS_FIXTURE_PROJECT_INVALID'}
    foreach($name in @('Success','Failure','Incomplete')){
        $item=$project.PackageItems[$name+'.dtsx'];$package=$item.Package
        $expected=if($name -ceq 'Failure'){'Failure'}else{'Success'}
        if(-not $item.EntryPoint -or $package.Name -cne $name -or [string]$package.ForceExecutionResult -cne $expected -or
            $package.Connections.Count -ne 0 -or $package.Executables.Count -ne 0){throw 'SSIS_FIXTURE_PACKAGE_INVALID'}
        Write-Host "PASS: $name, ForceExecutionResult=$expected, keine Verbindungen oder Tasks"
    }
    Write-Host 'SSIS_FIXTURE_FORMAT_ACCEPTANCE_PASSED; SQL NOT_EXECUTED'
}
finally {
    if($project){$project.Dispose()}
    # Exactly the unique temporary directory created above; never a computed parent.
    if(Test-Path -LiteralPath $directory){Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Stop}
}
