<#
.SYNOPSIS
    Persistiert einen geheimnisfreien Sollzustand vor Provider-Mutationen.
#>
function New-LabDesiredStateSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ResolvedLab,
        [Parameter(Mandatory)][ValidateSet('manifest', 'adhoc')][string]$ProvisioningMode,
        [bool]$PersistentData
    )

    $snapshot = [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.RunDesiredState'; Version = '1.0' }
        ProvisioningMode = $ProvisioningMode
        LabName = [string]$ResolvedLab.name
        PersistentData = $PersistentData
        Instances = @($ResolvedLab.instances | ForEach-Object {
            [PSCustomObject]@{
                Id = [string]$_.id; Provider = [string]$_.provider; Version = [string]$_.version
                Profile = [string]$_.profile; DatabaseNames = @($_.databases | ForEach-Object { [string]$_.name })
            }
        })
    }
    return $snapshot
}

function Get-LabPersistedDesiredState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [string]$StateRoot)
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if (-not $run.metadata -or -not $run.metadata.desiredState) {
        return [PSCustomObject]@{
            Status = 'ABSENT'
            Snapshot = $null
            Reason = $null
        }
    }

    $snapshot = $run.metadata.desiredState
    if (-not $snapshot.Contract -or [string]$snapshot.Contract.Name -ne 'SqlServerLab.RunDesiredState' -or [string]$snapshot.Contract.Version -ne '1.0') {
        return [PSCustomObject]@{
            Status = 'INVALID'
            Snapshot = $snapshot
            Reason = 'Run metadata desiredState-Contract fehlt oder hat keine gueltige Contract-Identitaet.'
        }
    }

    if (-not $snapshot.Instances -or @($snapshot.Instances).Count -eq 0) {
        return [PSCustomObject]@{
            Status = 'INVALID'
            Snapshot = $snapshot
            Reason = 'Run metadata desiredState-Inhalt enthaelt keine Instanzen.'
        }
    }

    $validationErrors = New-Object System.Collections.Generic.List[string]
    foreach ($instance in @($snapshot.Instances)) {
        if (-not $instance.Id) { $validationErrors.Add("Instance entry hat keine Id.") }
        if (-not $instance.Provider) { $validationErrors.Add("Instance '$($instance.Id)' hat keinen Provider.") }
    }

    if ($validationErrors.Count -gt 0) {
        return [PSCustomObject]@{
            Status = 'INVALID'
            Snapshot = $snapshot
            Reason = ($validationErrors -join ' ')
        }
    }

    return [PSCustomObject]@{
        Status = 'VALID'
        Snapshot = $snapshot
        Reason = $null
    }
}
