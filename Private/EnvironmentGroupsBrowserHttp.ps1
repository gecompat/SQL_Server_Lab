function Get-UiEnvironmentGroupsView {
    [CmdletBinding()]
    param()

    $groups = @(Get-SqlServerLabEnvironmentGroup)
    $projectedGroups = @(
        foreach ($group in $groups) {
            $operation = $null
            if ($null -ne $group.operation) {
                $operation = [ordered]@{
                    action = [string]$group.operation.action
                    state = [string]$group.operation.state
                    startedAt = [string]$group.operation.startedAt
                    updatedAt = [string]$group.operation.updatedAt
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
                        }
                    }
                )
            }
        }
    )

    [ordered]@{
        contractVersion = 'SqlServerLab.EnvironmentGroups.BrowserView/1.0'
        groups = $projectedGroups
    }
}
