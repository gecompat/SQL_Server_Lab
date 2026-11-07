function Get-UiEnvironmentGroupsView {
    [CmdletBinding()]
    param()

    $groups = @(Get-SqlServerLabEnvironmentGroup -IncludeBindingStatus)
    $projectedGroups = @(
        foreach ($group in $groups) {
            $operation = $null
            if ($null -ne $group.operation) {
                $operation = [ordered]@{
                    action = [string]$group.operation.action
                    state = [string]$group.operation.state
                    startedAt = [string]$group.operation.startedAt
                    updatedAt = [string]$group.operation.updatedAt
                    members = @(
                        foreach ($memberOperation in @($group.operation.members)) {
                            [ordered]@{
                                runId = [string]$memberOperation.runId
                                action = [string]$memberOperation.action
                                status = [string]$memberOperation.status
                            }
                        }
                    )
                }
            }
            [ordered]@{
                groupId = [string]$group.groupId
                name = [string]$group.name
                createdAt = [string]$group.createdAt
                lifecycleState = [string]$group.lifecycleState
                operation = $operation
                members = @(
                    foreach ($member in @($group.members)) {
                        [ordered]@{
                            runId = [string]$member.runId
                            instanceIds = @($member.instanceIds | ForEach-Object { [string]$_ })
                            assignedAt = [string]$member.assignedAt
                            bindingStatus = [string]$member.bindingStatus
                        }
                    }
                )
            }
        }
    )

    [ordered]@{
        contractVersion = 'SqlServerLab.EnvironmentGroups.BrowserView/1.2'
        groups = $projectedGroups
    }
}
