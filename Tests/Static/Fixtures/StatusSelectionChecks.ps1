# Exercise the real status selector with synthetic run records and menu input.
& {
    . (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1')
    function New-StatusRun {
        param([string]$Id,[string]$Name,[string]$Provider,[string]$Kind='',[string]$BaseKind='')
        return [pscustomobject]@{
            runId=$Id
            metadata=[pscustomobject]@{name=$Name;workflowKind=$Kind;baseKind=$BaseKind;desiredState=$null}
            providerSubRuns=@([pscustomobject]@{provider=$Provider})
            runtime=[pscustomobject]@{state='RUNNING'}
        }
    }
    $script:statusRuns=@(
        (New-StatusRun 'r-slot-z' 'Slot Z' hyperv hyperv-lab windows-baseline),
        (New-StatusRun 'r-podman-beta' 'Beta' podman),
        (New-StatusRun 'r-docker-zulu' 'Zulu' docker),
        (New-StatusRun 'r-hyperv-other' 'Other' hyperv hyperv-lab),
        (New-StatusRun 'r-docker-alpha' 'Alpha' docker),
        (New-StatusRun 'r-slot-a' 'Slot A' hyperv hyperv-lab windows-baseline),
        (New-StatusRun 'r-cms' 'CMS' docker)
    )
    $script:statusChoices=[Collections.Generic.Queue[string]]::new()
    $script:statusFrames=[Collections.Generic.List[object]]::new()
    $script:statusShown=[Collections.Generic.List[string]]::new()
    function Get-LabActiveRuns { return $script:statusRuns }
    function Get-LabConnectionCenterCmsConfiguration { return @{RunId='r-cms'} }
    function Invoke-LabConsoleMenu {
        param($ScreenId,$Title,$Subtitle,$Items,$Footer,$SelectedId)
        $script:statusFrames.Add([pscustomobject]@{ScreenId=$ScreenId;Items=@($Items)})
        $choice=$script:statusChoices.Dequeue()
        if ($choice -in @('Cancelled','Refresh')) { return @{Status=$choice} }
        $selected=@($Items | Where-Object { $_.Id -eq $choice })
        if ($selected.Count -ne 1) { throw "STATUS_SELECTION_MISSING: $choice" }
        return @{Status='Selected';SelectedItem=$selected[0]}
    }
    function Show-LabEnvironmentStatusInteractive { param($RunId) $script:statusShown.Add([string]$RunId) }

    $script:statusChoices.Enqueue('group:Lab-Umgebung')
    $script:statusChoices.Enqueue('r-docker-alpha')
    $selectionError=$null
    try { Show-LabEnvironmentStatusSelectionInteractive 6>$null } catch { $selectionError=$_ }
    $root=@($script:statusFrames | Where-Object ScreenId -eq 'environment-status-select')
    $group=@($script:statusFrames | Where-Object ScreenId -eq 'environment-status-group')
    Add-ConsoleUiCheck 'Statusauswahl zeigt nur Alle und vorhandene Typgruppen, ohne CMS' (
        -not $selectionError -and $script:statusChoices.Count -eq 0 -and $root.Count -eq 1 -and
        (@($root[0].Items | ForEach-Object Id) -join ',') -eq '__all,group:Lab-Umgebung,group:Hyper-V-Windows-Slot,group:Hyper-V-Umgebung' -and
        [string]$root[0].Items[0].Value -match '6 Umgebung' -and
        (@($root[0].Items | Where-Object { $_.Id -eq 'group:Lab-Umgebung' })[0].Value -match '3 Umgebung')
    )
    Add-ConsoleUiCheck 'Aufgeklappte Lab-Gruppe sortiert zuerst Provider, dann Name und wählt gebundene Run-ID' (
        $group.Count -eq 1 -and
        (@($group[0].Items | ForEach-Object Id) -join ',') -eq 'r-docker-alpha,r-docker-zulu,r-podman-beta' -and
        (@($script:statusShown) -join ',') -eq 'r-docker-alpha'
    )

    $script:statusFrames.Clear(); $script:statusShown.Clear()
    $script:statusChoices.Enqueue('group:Hyper-V-Windows-Slot')
    $script:statusChoices.Enqueue('Cancelled')
    $script:statusChoices.Enqueue('__all')
    $selectionError=$null
    try { Show-LabEnvironmentStatusSelectionInteractive 6>$null } catch { $selectionError=$_ }
    $group=@($script:statusFrames | Where-Object ScreenId -eq 'environment-status-group')
    Add-ConsoleUiCheck 'Esc klappt Gruppe zu; Alle zeigt sämtliche regulären Runs in Provider-/Namensfolge' (
        -not $selectionError -and $script:statusChoices.Count -eq 0 -and $group.Count -eq 1 -and
        (@($group[0].Items | ForEach-Object Id) -join ',') -eq 'r-slot-a,r-slot-z' -and
        (@($script:statusFrames | ForEach-Object ScreenId) -join ',') -eq 'environment-status-select,environment-status-group,environment-status-select' -and
        (@($script:statusShown) -join ',') -eq 'r-docker-alpha,r-docker-zulu,r-hyperv-other,r-slot-a,r-slot-z,r-podman-beta'
    )
}

& {
    . (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1')
    $script:statusConnectionReads=0
    $script:statusSecretReads=0
    $script:statusRecoveryWarnings=[Collections.Generic.List[string]]::new()
    function Get-LabStateRoot { return 'X:\synthetic-status-state' }
    function Get-SqlServerLab { param($RunId,[switch]$Detailed) return [pscustomobject]@{State='RECOVERY_REQUIRED';RuntimeState='MISSING'} }
    function Get-LabRunConnectionStrings { $script:statusConnectionReads++; return @() }
    function Get-SqlServerLabGeneratedSqlAccess { $script:statusSecretReads++; return $null }
    function Get-LabAutomaticallyGeneratedRunSaPassword { $script:statusSecretReads++; return $null }
    function Write-LabWarning { param($Message) $script:statusRecoveryWarnings.Add([string]$Message) }
    $statusError=$null
    try { Show-LabEnvironmentStatusInteractive -RunId 'r-recovery' 6>$null } catch { $statusError=$_ }
    Add-ConsoleUiCheck 'Fehlende Recovery-Runtime zeigt keinen gespeicherten SQL-Zugang als erreichbar an' (
        -not $statusError -and $script:statusConnectionReads -eq 0 -and $script:statusSecretReads -eq 0 -and
        (@($script:statusRecoveryWarnings) -join ' ') -match 'Wiederherstellung'
    )
    $run=[pscustomobject]@{
        runId='r-recovery';state='RECOVERY_REQUIRED'
        metadata=[pscustomobject]@{name='Recovery';workflowKind='hyperv-lab';baseKind='';desiredState=$null}
        providerSubRuns=@([pscustomobject]@{provider='hyperv'})
    }
    $presentation=Get-LabRunSelectorPresentation -Run $run -RuntimeState 'MISSING'
    Add-ConsoleUiCheck 'Recovery-Run bleibt im Typmenue und ist dort als RECOVERY_REQUIRED erkennbar' (
        $presentation.Role -eq 'Hyper-V-Umgebung' -and $presentation.Value -match 'RECOVERY_REQUIRED'
    )
}
