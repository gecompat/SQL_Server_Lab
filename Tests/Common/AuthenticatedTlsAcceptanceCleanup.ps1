# Test-only cleanup of the fixed exports created by the owned acceptance run.
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
        $allowed=@('TestUmgebung.json','TestUmgebung.env','TestUmgebung.schema.json','TestUmgebung.md','TestUmgebung.prompt.md')
        $targets=[Collections.Generic.List[object]]::new()
        foreach($name in @('qualified-export','rebound-qualified-export')){
            $directory=Assert-LabDiagnosticPath (Join-Path $root $name)
            if(-not (Test-Path -LiteralPath $directory)){continue}
            Assert-LabTlsCaPrivateAcl $directory $native.UserSid -Directory
            $files=@(Get-ChildItem -LiteralPath $directory -Force)
            foreach($file in $files){
                if($file.PSIsContainer -or $file.Name -cnotin $allowed -or [IO.Path]::GetDirectoryName($file.FullName) -cne $directory){throw 'TLS_ACCEPTANCE_EXPORT_CLEANUP_UNEXPECTED_CONTENT'}
                Assert-LabTlsCaPrivateAcl $file.FullName $native.UserSid
            }
            $targets.Add([pscustomobject]@{Directory=$directory;Files=$files})
        }
        # Validate both targets before deleting any leaf, then remove only the
        # fixed files and empty directories. Unknown content remains untouched.
        foreach($target in $targets){
            foreach($file in $target.Files){Remove-Item -LiteralPath $file.FullName -Force}
            Remove-Item -LiteralPath $target.Directory
            if(Test-Path -LiteralPath $target.Directory){throw 'TLS_ACCEPTANCE_EXPORT_CLEANUP_UNCONFIRMED'}
        }
    } $StateRoot $RunId
}
