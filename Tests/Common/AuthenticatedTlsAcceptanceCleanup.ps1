# Test-only cleanup of the fixed export created by the owned acceptance run.
# No CA/key/trust dependency: trust drift must never prevent secret cleanup.
function Remove-OwnedTlsAcceptanceExport {
    param([string]$StateRoot,[string]$RunId,[object]$Module)
    & $Module {
        param($StateRoot,$RunId)
        $native=Get-LabTlsWindowsProcessFacts
        $root=Assert-LabDiagnosticPath ([IO.Path]::GetFullPath($StateRoot))
        $policy=Assert-LabTlsLabRoot $root
        $record=Read-LabTlsLabRecord (Read-LabTlsCaPrivateFile (Join-Path $root 'authenticated-tls-lab.json') $native.UserSid 32768)
        if($record.ContractVersion -cin @('SqlServerLab.AuthenticatedTlsLab/0.2','SqlServerLab.AuthenticatedTlsLab/0.3')){
            if(-not $policy){throw 'TLS_ACCEPTANCE_EXPORT_CLEANUP_POLICY_REQUIRED'}
            $null=Get-LabTlsRecordedRuntimePin $record $root
            $null=Get-LabOwnedHostRunPolicy -RunId $RunId -StateRoot $root
        }
        if($record.RunId -cne $RunId -or
            -not (Test-LabTlsRequestReference $record.AuditId) -or $record.InstanceId -cne 'primary' -or
            -not [string]::Equals($root,[IO.Path]::GetFullPath((Join-Path $record.DataRoot ('State/authenticated-tls-labs/'+$record.AuditId))),[StringComparison]::OrdinalIgnoreCase)){
            throw 'TLS_ACCEPTANCE_EXPORT_CLEANUP_SCOPE_INVALID'
        }
        $run=Get-LabRunState -RunId $RunId -StateRoot $root
        if($run.scopeId -cne $record.ScopeId -or $run.state -cnotin @('REMOVED','CLEANED_UP')){throw 'TLS_ACCEPTANCE_EXPORT_CLEANUP_REMOVED_RUN_REQUIRED'}
        $directory=Assert-LabDiagnosticPath (Join-Path $root 'qualified-export')
        if(-not (Test-Path -LiteralPath $directory)){return}
        Assert-LabTlsCaPrivateAcl $directory $native.UserSid -Directory
        $allowed=@('TestUmgebung.json','TestUmgebung.env','TestUmgebung.schema.json','TestUmgebung.md','TestUmgebung.prompt.md')
        $files=@(Get-ChildItem -LiteralPath $directory -Force)
        foreach($file in $files){
            if($file.PSIsContainer -or $file.Name -cnotin $allowed -or [IO.Path]::GetDirectoryName($file.FullName) -cne $directory){throw 'TLS_ACCEPTANCE_EXPORT_CLEANUP_UNEXPECTED_CONTENT'}
            Assert-LabTlsCaPrivateAcl $file.FullName $native.UserSid
        }
        # Only validated fixed leaves, followed by empty-directory removal.
        foreach($file in $files){Remove-Item -LiteralPath $file.FullName -Force}
        Remove-Item -LiteralPath $directory
        if(Test-Path -LiteralPath $directory){throw 'TLS_ACCEPTANCE_EXPORT_CLEANUP_UNCONFIRMED'}
    } $StateRoot $RunId
}
