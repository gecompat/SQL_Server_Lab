<#
.SYNOPSIS
    Erstellt den lokalen, nicht ausführbaren Automation-API-Planvertrag.
.DESCRIPTION
    Dieser Core projiziert ausschließlich die bereits öffentliche PowerShell-
    Plan-/Action-Grenze. Er liest keinen State, verbindet keine Runtime und
    erzeugt keine Dateien. Ein späterer lokaler oder externer Adapter muss
    weiterhin den jeweiligen öffentlichen Plan neu abrufen und darf aus
    diesem Vertrag keine Ausführungsautorität ableiten.
#>

function Get-LabAutomationApiPlanKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Identity)

    $json = $Identity | ConvertTo-Json -Depth 10 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function Get-LabAutomationApiPlan {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Action)

    $catalog = @{
        Reconcile = [ordered]@{
            PlanCommand = 'Get-SqlServerLabReconcilePlan'; PlanContract = 'SqlServerLab.ReconcilePlan/1.0'
            ActionCommand = 'Invoke-SqlServerLabReconcileAction'; RequiredParameters = @('RunId')
        }
        Maintenance = [ordered]@{
            PlanCommand = 'Get-SqlServerLabMaintenancePlan'; PlanContract = 'SqlServerLab.MaintenancePlan/1.0'
            ActionCommand = 'Invoke-SqlServerLabMaintenance'; RequiredParameters = @()
        }
        PersistentStorageRemoval = [ordered]@{
            PlanCommand = 'Get-SqlServerLabPersistentStorageRemovalPlan'; PlanContract = 'SqlServerLab.PersistentStorageRemovalPlan/1.0'
            ActionCommand = 'Invoke-SqlServerLabPersistentStorageRemoval'; RequiredParameters = @('RunId','Policy')
        }
        RunStateUpgrade = [ordered]@{
            PlanCommand = 'Get-SqlServerLabRunStateUpgradePlan'; PlanContract = 'SqlServerLab.RunStateUpgradePlan/1.0'
            ActionCommand = 'Invoke-SqlServerLabRunStateUpgrade'; RequiredParameters = @('RunId')
        }
        PortableLabImport = [ordered]@{
            PlanCommand = 'Get-SqlServerLabPortableLabImportPlan'; PlanContract = 'SqlServerLab.PortableLabImportPlan/1.0'
            ActionCommand = $null; RequiredParameters = @('PackagePath','TargetProvider')
        }
        HyperVRecoveryPoint = [ordered]@{
            PlanCommand = 'Get-SqlServerLabHyperVRecoveryPointPlan'; PlanContract = 'SqlServerLab.HyperVRecoveryPointPlan/1.0'
            ActionCommand = $null; RequiredParameters = @('RunId','InstanceId')
        }
    }

    $blockers = [Collections.Generic.List[string]]::new()
    $selected = $null
    if ([string]::IsNullOrWhiteSpace($Action)) {
        $blockers.Add('AUTOMATION_ACTION_REQUIRED')
    }
    elseif ($catalog.ContainsKey($Action)) {
        $selected = $catalog[$Action]
    }
    else {
        # Never reflect an arbitrary value: it could contain a host path or a secret.
        $blockers.Add('AUTOMATION_ACTION_UNSUPPORTED')
    }

    $identity = [ordered]@{
        ContractVersion = 'SqlServerLab.AutomationApiPlan/1.0'
        Action = if ($selected) { $Action } else { 'INVALID' }
        PlanContract = if ($selected) { [string]$selected.PlanContract } else { $null }
    }
    $planKey = Get-LabAutomationApiPlanKey -Identity $identity
    $plan = [PSCustomObject][ordered]@{
        ContractVersion = 'SqlServerLab.AutomationApiPlan/1.0'
        PlanId = "automation-api-$planKey"
        PlanKey = $planKey
        Status = if ($selected) { 'READY' } else { 'BLOCKED' }
        Request = [PSCustomObject][ordered]@{ Action = if ($selected) { $Action } else { $null }; LocalOnly = $true }
        Plan = if ($selected) {
            [PSCustomObject][ordered]@{
                Command = [string]$selected.PlanCommand
                ContractVersion = [string]$selected.PlanContract
                RequiredParameters = @($selected.RequiredParameters)
                Mutation = 'NONE'
            }
        } else { $null }
        Result = [PSCustomObject][ordered]@{
            ContractVersion = 'SqlServerLab.AutomationApiResult/1.0'
            Status = 'NOT_EXECUTED'
            ActionCommand = if ($selected) { [string]$selected.ActionCommand } else { $null }
            ExecutionImplemented = $false
        }
        Blockers = @($blockers)
        ExecutionImplemented = $false
        PlannedAt = Get-LabTimestamp
    }

    try {
        $valid = $plan | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $script:SchemasPath 'automation-api-plan.schema.json') -ErrorAction Stop
    }
    catch { throw "AUTOMATION_API_PLAN_INVALID: $($_.Exception.Message)" }
    if (-not $valid) { throw 'AUTOMATION_API_PLAN_INVALID' }
    return $plan
}
