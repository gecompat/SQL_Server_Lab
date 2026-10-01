#Requires -Version 7.2
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArgs
)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or
    @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or
    @($RemainingArgs) -contains '--help'
if ($showHelpRequested) { Get-Help -Full -Name $PSCommandPath | Out-Host; return }

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$temporaryLeaf = "sql-lab-initial-setup-$([guid]::NewGuid().ToString('N'))"
$temporaryRoot = Join-Path $temporaryParent $temporaryLeaf
$mediaRoot = Join-Path $temporaryRoot 'Lab1_Base'
$dataRootOne = Join-Path $temporaryRoot 'Lab1_Data'
$dataRootTwo = Join-Path $temporaryRoot 'Lab2_Data'
$previousMediaRoot = $env:SQL_SERVER_LAB_MEDIA_ROOT
$previousDataRoot = $env:SQL_SERVER_LAB_DATA_ROOT
$previousControllerId = $env:SQL_SERVER_LAB_CONTROLLER_ID
$userMediaRoot = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_MEDIA_ROOT', 'User')
$userDataRoot = [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', 'User')
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Initial Setup Checks' -ForegroundColor Cyan

try {
    if (Test-Path -LiteralPath $temporaryRoot) { throw 'INITIAL_SETUP_TEST_ROOT_EXISTS' }
    $null = New-Item -Path $temporaryRoot -ItemType Directory
    $env:SQL_SERVER_LAB_MEDIA_ROOT = $null
    $env:SQL_SERVER_LAB_DATA_ROOT = $null
    $env:SQL_SERVER_LAB_CONTROLLER_ID = $null
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    & $module {
        $script:SetupOriginalCandidates = ${function:Get-LabMediaRootCandidates}
        Set-Item -Path Function:script:Get-LabMediaRootCandidates -Value {
            if ($env:SQL_SERVER_LAB_MEDIA_ROOT) { [pscustomobject]@{ Source='ProcessEnvironment'; Path=$env:SQL_SERVER_LAB_MEDIA_ROOT; ResolvedPath=$env:SQL_SERVER_LAB_MEDIA_ROOT; Status='READY'; Selected=$true } }
        }
        Set-Item -Path Function:script:Get-LabMediaRootDefault -Value {
            if ($env:SQL_SERVER_LAB_MEDIA_ROOT -and (Test-Path -LiteralPath $env:SQL_SERVER_LAB_MEDIA_ROOT -PathType Container)) {
                return (Resolve-Path -LiteralPath $env:SQL_SERVER_LAB_MEDIA_ROOT).Path
            }
            return $null
        }
        Set-Item -Path Function:script:Get-LabDataRootDefault -Value {
            if ($env:SQL_SERVER_LAB_DATA_ROOT -and (Test-Path -LiteralPath $env:SQL_SERVER_LAB_DATA_ROOT -PathType Container)) {
                return (Resolve-Path -LiteralPath $env:SQL_SERVER_LAB_DATA_ROOT).Path
            }
            return $null
        }
        Set-Item -Path Function:script:Get-LabVolumeIdentity -Value {
            param([string]$Path)
            $full = [IO.Path]::GetFullPath($Path)
            $id = if ($full -match 'Lab2_Data') { 'test-volume-two' } else { 'test-volume-one' }
            [PSCustomObject]@{ VolumeId=$id; DriveLetter=$id; VolumeRoot=[IO.Path]::GetPathRoot($full) }
        }
    }

    $relativeRejected = try {
        & $module { New-LabInitialSetupPlan -MediaRoot 'D:' -LabDataRoot @('D:\') -DefaultDataRoot 'D:\Lab1_Data' }
        $false
    } catch { $_.Exception.Message -match 'INITIAL_SETUP_MEDIA_ROOT_NOT_FULLY_QUALIFIED' }
    Add-CheckResult -Name 'Ersteinrichtung lehnt laufwerksrelative Root-Angaben vor jeder Mutation ab' -Success $relativeRejected

    $plan = & $module {
        param($mediaRoot, $rootOne, $rootTwo, $defaultRoot)
        New-LabInitialSetupPlan -MediaRoot $mediaRoot -LabDataRoot @($rootOne, $rootTwo) -DefaultDataRoot $defaultRoot
    } $mediaRoot $dataRootOne $dataRootTwo $dataRootTwo
    Add-CheckResult -Name 'Plan akzeptiert frei wählbare gemeinsame Media- und Datenroots' -Success (
        $plan.ContractVersion -eq 'SqlServerLab.InitialSetupPlan/1.0' -and
        $plan.MediaAction.MediaRoot -eq $mediaRoot -and
        @($plan.LocationActions).Count -eq 2 -and
        $plan.LocationActions[0].LabDataRoot -eq $dataRootOne -and
        $plan.LocationActions[1].LabDataRoot -eq $dataRootTwo
    )
    Add-CheckResult -Name 'Globaler Lab_Data-Standard ist im Plan ausdrücklich gebunden' -Success ($plan.DefaultDataRoot -eq $dataRootTwo)
    Add-CheckResult -Name 'Read-only Planung erzeugt keine gemeinsamen Host-Wurzeln' -Success (
        -not (Test-Path -LiteralPath $mediaRoot) -and -not (Test-Path -LiteralPath $dataRootOne) -and -not (Test-Path -LiteralPath $dataRootTwo)
    )
    $missingDefaultRejected = try {
        & $module {
            param($mediaRoot, $dataRoot)
            New-LabInitialSetupPlan -MediaRoot $mediaRoot -LabDataRoot $dataRoot
        } $mediaRoot $dataRootOne
        $false
    } catch { $_.Exception.Message -match 'INITIAL_SETUP_DEFAULT_DATA_ROOT_REQUIRED' }
    Add-CheckResult -Name 'Erster Setup-Plan verlangt eine ausdrückliche globale Default-Auswahl' -Success $missingDefaultRejected
    $whatIfPlan = & $module {
        param($mediaRoot, $rootOne, $rootTwo, $defaultRoot)
        Invoke-LabInitialSetup -MediaRoot $mediaRoot -LabDataRoot @($rootOne, $rootTwo) `
            -DefaultDataRoot $defaultRoot -ProcessEnvironmentOnly -WhatIf
    } $mediaRoot $dataRootOne $dataRootTwo $dataRootTwo
    Add-CheckResult -Name 'WhatIf liefert den revalidierten Plan ohne Dateisystemmutation' -Success (
        $whatIfPlan.ContractVersion -eq 'SqlServerLab.InitialSetupPlan/1.0' -and
        -not (Test-Path -LiteralPath $mediaRoot) -and -not (Test-Path -LiteralPath $dataRootOne)
    )

    $result = & $module {
        param($plan)
        Invoke-LabInitialSetupPlan -Plan $plan -ProcessEnvironmentOnly -Confirm:$false
    } $plan
    $configuration = & $module { Get-LabStorageConfiguration }
    Add-CheckResult -Name 'Gemeinsamer Core initialisiert frei benannte, controllergebundene Host-Roots' -Success (
        $result.Complete -and (Test-Path -LiteralPath (Join-Path $mediaRoot 'SQL') -PathType Container) -and
        @($configuration.LabDataLocations).Count -eq 2 -and
        (Test-Path -LiteralPath (Join-Path $dataRootOne '.sql-server-lab-root.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $dataRootTwo '.sql-server-lab-root.json') -PathType Leaf)
    )
    Add-CheckResult -Name 'Ausdrücklich gewählter zweiter Root wird globaler Standard' -Success (
        [string]$configuration.DefaultDataRoot -eq $dataRootTwo -and [string]$env:SQL_SERVER_LAB_DATA_ROOT -eq $dataRootTwo
    )
    Add-CheckResult -Name 'Prozessisolierter Testlauf verändert keine dauerhaften Benutzervariablen' -Success (
        [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_MEDIA_ROOT', 'User') -eq $userMediaRoot -and
        [Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', 'User') -eq $userDataRoot
    )

    $mediaSentinel = Join-Path $mediaRoot 'existing-media.bin'
    $dataSentinel = Join-Path $dataRootOne 'existing-data.bin'
    Set-Content -LiteralPath $mediaSentinel -Value 'media-preserved' -Encoding utf8NoBOM
    Set-Content -LiteralPath $dataSentinel -Value 'data-preserved' -Encoding utf8NoBOM
    $secondResult = & $module { Invoke-LabInitialSetup -ProcessEnvironmentOnly -Confirm:$false }
    Add-CheckResult -Name 'Vollständige Ersteinrichtung ist ohne Rückfragen und Mutation idempotent' -Success (
        $secondResult.Complete -and
        (Get-Content -LiteralPath $mediaSentinel -Raw -Encoding utf8).Trim() -eq 'media-preserved' -and
        (Get-Content -LiteralPath $dataSentinel -Raw -Encoding utf8).Trim() -eq 'data-preserved'
    )

    $switchPlan = & $module { param($root) New-LabInitialSetupPlan -DefaultDataRoot $root } $dataRootOne
    Add-CheckResult -Name 'Wechsel auf registrierten Default ist kein No-op' -Success (-not $switchPlan.IsNoOp)
    $switched = & $module { param($plan) Invoke-LabInitialSetupPlan -Plan $plan -ProcessEnvironmentOnly -Confirm:$false } $switchPlan
    $repeated = & $module { param($root) New-LabInitialSetupPlan -DefaultDataRoot $root } $dataRootOne
    Add-CheckResult -Name 'Registrierter Defaultwechsel erhält beide Roots und wird danach idempotent' -Success (
        $switched.DefaultLocation.LabDataRoot -eq $dataRootOne -and @($switched.Locations).Count -eq 2 -and $repeated.IsNoOp -and
        (Get-Content -LiteralPath $mediaSentinel -Raw).Trim() -eq 'media-preserved' -and
        (Get-Content -LiteralPath $dataSentinel -Raw).Trim() -eq 'data-preserved'
    )
    $mediaChangeRejected = try {
        & $module { param($root) New-LabInitialSetupPlan -MediaRoot $root } (Join-Path $temporaryRoot 'replacement-base')
        $false
    } catch { $_.Exception.Message -eq 'INITIAL_SETUP_MEDIA_ROOT_CHANGE_UNSUPPORTED' }
    Add-CheckResult -Name 'Gültiger MediaRoot kann durch Grundkonfiguration nicht still ersetzt werden' -Success $mediaChangeRejected
    $candidateCheck = & $module {
        param($validRoot, $missingRoot)
        $savedPreference = ${function:Get-LabProjectPreferenceValue}
        $savedMedia = $env:SQL_SERVER_LAB_MEDIA_ROOT
        try {
            $script:SetupPreference = $validRoot
            $env:SQL_SERVER_LAB_MEDIA_ROOT = $missingRoot
            Set-Item Function:script:Get-LabProjectPreferenceValue { param($Name) $script:SetupPreference }
            $candidates = @(& $script:SetupOriginalCandidates)
            @($candidates | Where-Object Selected)[0].Source -eq 'ProjectPreference' -and
                $candidates[0].Source -eq 'ProcessEnvironment' -and $candidates[0].Status -eq 'ROOT_NOT_FOUND'
        }
        finally { $env:SQL_SERVER_LAB_MEDIA_ROOT=$savedMedia; Set-Item Function:script:Get-LabProjectPreferenceValue $savedPreference }
    } $mediaRoot (Join-Path $temporaryRoot 'missing-media')
    Add-CheckResult -Name 'Echte Herkunftsauflösung zeigt ungültigen Vorrangwert und gültigen Projektfallback' -Success $candidateCheck
    $stalePlan = & $module { param($root) New-LabInitialSetupPlan -DefaultDataRoot $root } $dataRootTwo
    $marker = Join-Path $dataRootTwo '.sql-server-lab-root.json'
    $markerHold = Join-Path $dataRootTwo '.test-marker-hold'
    Move-Item -LiteralPath $marker -Destination $markerHold
    try {
        $staleRejected = try { & $module { param($plan) Invoke-LabInitialSetupPlan -Plan $plan -ProcessEnvironmentOnly -Confirm:$false } $stalePlan; $false }
            catch { $_.Exception.Message -match 'INITIAL_SETUP_DEFAULT_DATA_ROOT_UNKNOWN' }
    }
    finally { Move-Item -LiteralPath $markerHold -Destination $marker }
    Add-CheckResult -Name 'Apply revalidiert Ownership und lehnt veralteten Defaultplan vor Mutation ab' -Success ($staleRejected -and $env:SQL_SERVER_LAB_DATA_ROOT -eq $dataRootOne)

    & $module {
        $script:SetupOriginalApply = ${function:Invoke-LabInitialSetupPlan}
        Set-Item Function:script:Invoke-LabInitialSetupPlan {
            param($Plan, [switch]$Confirm)
            & $script:SetupOriginalApply -Plan $Plan -ProcessEnvironmentOnly -Confirm:$false
        }
        Set-Item Function:script:Test-HyperVAvailable { throw 'UNEXPECTED_HYPERV_PROBE' }
        Set-Item Function:script:Get-LabClientRuntimeReadiness {
            param($Provider)
            $script:SetupProviders.Add($Provider)
            [pscustomobject]@{ Status='BLOCKED'; Code='PROVIDER_UNREACHABLE'; NextStep='Provider separat prüfen.' }
        }
        $script:SetupProviders = [Collections.Generic.List[string]]::new()
    }
    $projection = & $module {
        param($missingRoot, $validRoot)
        $original = ${function:Get-LabStorageConfiguration}
        try {
            $script:SetupStatusConfiguration = [pscustomobject]@{ ControllerId='synthetic'; DefaultLocationId='invalid'; LabDataLocations=@(
                [pscustomobject]@{ LocationId='missing'; LabDataRoot=$missingRoot },
                [pscustomobject]@{ LocationId='invalid'; LabDataRoot=$validRoot }
            ) }
            Set-Item Function:script:Get-LabStorageConfiguration { $script:SetupStatusConfiguration }
            $state = Get-LabInitialSetupState
            Set-Item Function:script:Get-LabStorageConfiguration { throw 'synthetic-private-detail' }
            $invalid = Get-LabInitialSetupState
            $blocked = try { New-LabInitialSetupPlan; $false } catch { $_.Exception.Message -eq 'INITIAL_SETUP_STORAGE_CONFIGURATION_INVALID' }
            [pscustomobject]@{ State=$state; Invalid=$invalid; Blocked=$blocked }
        }
        finally { Set-Item Function:script:Get-LabStorageConfiguration $original }
    } (Join-Path $temporaryRoot 'missing') $mediaRoot
    Add-CheckResult -Name 'Status behält ungültige Locations sichtbar und beschädigte Konfiguration fail-closed' -Success (
        $projection.State.InvalidLocationCount -eq 2 -and ($projection.State.LocationStatus.Status -join ',') -eq 'ROOT_NOT_FOUND,OWNERSHIP_INVALID' -and
        $projection.Invalid.ConfigurationStatus -eq 'STORAGE_CONFIGURATION_INVALID' -and $projection.Blocked -and
        $projection.State.Writeability -eq 'NOT_CHECKED'
    )
    $publicState = (Invoke-SqlServerLabWorkflowAction -Action GetInitialSetupState).Result
    $publicPlan = (Invoke-SqlServerLabWorkflowAction -Action PlanInitialSetup -DefaultDataRoot $dataRootTwo).Result
    $unconfirmedRejected = try { Invoke-SqlServerLabWorkflowAction -Action ApplyInitialSetup -InitialSetupPlan $publicPlan; $false }
        catch { $_.Exception.Message -eq 'INITIAL_SETUP_CONFIRMATION_REQUIRED' }
    $publicApplied = (Invoke-SqlServerLabWorkflowAction -Action ApplyInitialSetup -InitialSetupPlan $publicPlan -ConfirmSetup).Result
    $provider = (Invoke-SqlServerLabWorkflowAction -Action RefreshSetupProvider -SetupProvider docker).Result
    Add-CheckResult -Name 'Öffentliche Setupactions umgehen Hyper-V-Gate und verlangen explizites Apply' -Success (
        $publicState.Complete -and $unconfirmedRejected -and $publicApplied.DefaultLocation.LabDataRoot -eq $dataRootTwo -and
        $provider.Provider -eq 'docker' -and $provider.Check.Code -eq 'PROVIDER_UNREACHABLE'
    )
    $cli = & $module {
        param($defaultRoot)
        $script:SetupMenus = [Collections.Generic.Queue[object]]::new()
        foreach ($item in @(
            @{Status='Refresh'},
            @{Status='Selected'; SelectedItem=@{Id='root-0'}},
            @{Status='Selected'; SelectedItem=@{Id='Configure'}},
            @{Status='Selected'; SelectedItem=@{Data=$defaultRoot}},
            @{Status='Selected'; SelectedItem=@{Id='Provider'}},
            @{Status='Selected'; SelectedItem=@{Data='podman'}},
            @{Status='Cancelled'}
        )) { $script:SetupMenus.Enqueue([pscustomobject]$item) }
        $script:SetupScreens = [Collections.Generic.List[string]]::new()
        $script:SetupFrames = [Collections.Generic.List[object]]::new()
        $script:SetupInfo = [Collections.Generic.List[string]]::new()
        $script:SetupAcknowledged = [Collections.Generic.List[string]]::new()
        $script:SetupOriginalMenu = ${function:Invoke-LabConsoleMenu}
        $script:SetupFallbackAction = $null
        Set-Item Function:script:Update-LabConsoleAttentionSnapshot { return $null }
        Set-Item Function:script:Write-LabInfo { param($Message) $script:SetupInfo.Add([string]$Message) }
        Set-Item Function:script:Wait-LabConsoleAcknowledgement { $script:SetupAcknowledged.Add($script:SetupInfo[-1]) }
        Set-Item Function:script:Invoke-LabConsoleMenu {
            param($ScreenId, $Title, $Subtitle, $Items)
            $script:SetupScreens.Add($ScreenId)
            if ($ScreenId -eq 'initial-setup' -and -not $script:SetupFallbackAction) {
                $fallback = & $script:SetupOriginalMenu -ScreenId $ScreenId -Title $Title -Items $Items -Snapshot $null -ForceFallback -ReadInput { '1' } 6>$null
                $script:SetupFallbackAction = $fallback.SelectedItem.Id
            }
            if (-not $script:SetupMenus.Count) { throw 'UNEXPECTED_MENU' }
            $choice = $script:SetupMenus.Dequeue()
            $selectedId = if ($choice.Status -eq 'Selected') {
                if ($choice.SelectedItem.Id) { [string]$choice.SelectedItem.Id }
                else { [string]@($Items | Where-Object Data -eq $choice.SelectedItem.Data)[0].Id }
            } else { '' }
            $script:SetupTestKey = [pscustomobject]@{ Key=$(if($choice.Status -eq 'Refresh'){'F5'}elseif($choice.Status -eq 'Cancelled'){'Escape'}else{'Enter'}); KeyChar=[char]0; Modifiers=[ConsoleModifiers]0 }
            & $script:SetupOriginalMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -SelectedId $selectedId -Snapshot $null `
                -Capability ([pscustomobject]@{Supported=$true}) -StatusProvider $null -ReadKey { $script:SetupTestKey } `
                -FrameWriter { param($session, $frame) $script:SetupFrames.Add($frame) } `
                -GetViewport { [pscustomobject]@{Width=160; Height=20} } `
                -SessionFactory { [pscustomobject]@{OriginTop=0; PreviousLineCount=0; ForegroundColor='Gray'} } -SessionCompleter { param($session) }
        }
        Set-Item Function:script:Read-LabConfirm { param($Prompt, $Default) $false }
        $result = Invoke-LabInitialSetupInteractive
        [pscustomobject]@{ State=$result; Screens=@($script:SetupScreens); Providers=@($script:SetupProviders); Frames=@($script:SetupFrames); Acknowledged=@($script:SetupAcknowledged); FallbackAction=$script:SetupFallbackAction }
    } $dataRootOne
    Add-CheckResult -Name 'Echter CLI-Handler bleibt bei Complete bedienbar, Cancel mutiert nicht und Providerrefresh ist explizit' -Success (
        $cli.State.DefaultLocation.LabDataRoot -eq $dataRootTwo -and
        @($cli.Screens | Where-Object { $_ -eq 'initial-setup' }).Count -eq 5 -and
        ($cli.Providers -join ',') -eq 'docker,podman'
    )
    Add-CheckResult -Name 'Echter Cursorframe zeigt Rootstatus und F5 liest erneut statt den Dialog zu verlassen' -Success (
        ($cli.Frames[0].Lines -join "`n") -match 'Lab_Base.*ProcessEnvironment.*READY' -and
        ($cli.Frames[0].Lines -join "`n") -match 'Lab_Data.*READY' -and
        $cli.Frames.Count -eq 7 -and $cli.Screens[0] -eq 'initial-setup' -and $cli.Screens[1] -eq 'initial-setup'
    )
    Add-CheckResult -Name 'Volle Rootdetails und Providerbefund bleiben bis ausdrücklicher Bestätigung sichtbar' -Success (
        $cli.Acknowledged.Count -eq 2 -and $cli.Acknowledged[0].Contains($mediaRoot) -and
        $cli.Acknowledged[0] -match 'ProcessEnvironment' -and $cli.Acknowledged[1] -match 'podman.*PROVIDER_UNREACHABLE'
    )
    Add-CheckResult -Name 'Echter nummerierter Fallback erreicht Konfiguration mit Auswahl 1 trotz Statusitems' -Success ($cli.FallbackAction -eq 'Configure')

    $serverAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tools/Start-SqlServerLabUi.ps1'), [ref]$null, [ref]$null)
    $requestFunction = $serverAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-UiInitialSetupRequest'}, $true)
    . ([scriptblock]::Create($requestFunction.Extent.Text))
    function New-SetupTestRequest {
        param($Payload, $Origin='http://127.0.0.1:9999', $ContentType='application/json', $Method='POST')
        [pscustomobject]@{ HttpMethod=$Method; ContentType=$ContentType; Headers=@{ Origin=$Origin };
            Url=[uri]'http://127.0.0.1:9999/api/initial-setup'; ContentEncoding=[Text.Encoding]::UTF8;
            InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 12))) }
    }
    $httpPlan = Invoke-UiInitialSetupRequest -Request (New-SetupTestRequest @{action='PlanInitialSetup'; parameters=@{DefaultDataRoot=$dataRootOne}})
    $httpState = Invoke-UiInitialSetupRequest -Request (New-SetupTestRequest @{} -Method GET)
    Add-CheckResult -Name 'Echter HTTP-Adapter liest und plant ohne Defaultmutation oder Batchqueue' -Success (
        -not $httpPlan.Result.IsNoOp -and $httpState.Result.DefaultLocation.LabDataRoot -eq $dataRootTwo
    )
    $requestFailures = 0
    foreach ($request in @(
        (New-SetupTestRequest @{action='ApplyInitialSetup'; parameters=@{InitialSetupPlan=$httpPlan.Result; ConfirmSetup='false'}}),
        (New-SetupTestRequest @{action='PlanInitialSetup'; parameters=@{DefaultDataRoot=$dataRootOne}} -Origin 'https://foreign.invalid'),
        (New-SetupTestRequest @{action='PlanInitialSetup'; parameters=@{DefaultDataRoot=$dataRootOne}} -ContentType 'text/plain'),
        (New-SetupTestRequest @{action='StartContainerLab'; parameters=@{}}),
        (New-SetupTestRequest @{action='PlanInitialSetup'; parameters=@{Unexpected='value'}})
    )) { try { $null=Invoke-UiInitialSetupRequest -Request $request } catch { $requestFailures++ } }
    Add-CheckResult -Name 'HTTP-Grenze blockiert fremden Origin, Simple-POST, fremde Action/Parameter und falsche Bestätigung' -Success ($requestFailures -eq 5)
    $httpApplied = Invoke-UiInitialSetupRequest -Request (New-SetupTestRequest @{action='ApplyInitialSetup'; parameters=@{InitialSetupPlan=$httpPlan.Result; ConfirmSetup=$true}})
    Add-CheckResult -Name 'HTTP-Apply verwendet den gemeinsamen revalidierenden Core' -Success ($httpApplied.Result.DefaultLocation.LabDataRoot -eq $dataRootOne)
    $cliApplied = & $module {
        param($defaultRoot)
        $script:SetupMenus.Clear()
        foreach ($item in @(
            @{Status='Selected'; SelectedItem=@{Id='Configure'}},
            @{Status='Selected'; SelectedItem=@{Data=$defaultRoot}},
            @{Status='Cancelled'}
        )) { $script:SetupMenus.Enqueue([pscustomobject]$item) }
        $script:SetupConfirmCount = 0
        Set-Item Function:script:Read-LabConfirm {
            param($Prompt, $Default)
            $script:SetupConfirmCount++
            return $script:SetupConfirmCount -eq 2
        }
        Invoke-LabInitialSetupInteractive
    } $dataRootTwo
    Add-CheckResult -Name 'Echter CLI-Handler wendet erst bestätigten Defaultwechsel an und liest danach neuen Status' -Success ($cliApplied.DefaultLocation.LabDataRoot -eq $dataRootTwo)

    $env:SQL_SERVER_LAB_MEDIA_ROOT = $null
    $env:SQL_SERVER_LAB_DATA_ROOT = $null
    $foreignRoot = Join-Path $temporaryRoot 'foreign-data'
    $alternateMediaRoot = Join-Path $temporaryRoot 'alternate-media'
    $null = New-Item -Path $foreignRoot -ItemType Directory -Force
    Set-Content -LiteralPath (Join-Path $foreignRoot 'do-not-touch.txt') -Value 'foreign' -Encoding utf8NoBOM
    $foreignRejected = try {
        & $module {
            param($mediaRoot, $dataRoot, $defaultRoot)
            Invoke-LabInitialSetup -MediaRoot $mediaRoot -LabDataRoot $dataRoot `
                -DefaultDataRoot $defaultRoot -ProcessEnvironmentOnly -Confirm:$false
        } $alternateMediaRoot $foreignRoot $foreignRoot
        $false
    } catch { $_.Exception.Message -match 'INITIAL_SETUP_DATA_ROOT_NOT_EMPTY' }
    Add-CheckResult -Name 'Fremder nichtleerer frei benannter Datenroot wird vor Media-Root-Mutation fail-closed abgelehnt' -Success (
        $foreignRejected -and -not (Test-Path -LiteralPath $alternateMediaRoot) -and
        (Get-Content -LiteralPath (Join-Path $foreignRoot 'do-not-touch.txt') -Raw -Encoding utf8).Trim() -eq 'foreign'
    )

    $consoleText = Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1') -Raw -Encoding utf8
    $setupText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/InitialSetup.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Setup ist als Direktaktion und im Storage-Menü an denselben Core gebunden' -Success (
        $consoleText -match "ValidateSet\([^\r\n]+?'Setup'" -and
        $consoleText -match "New-LabConsoleItem -Id 'Setup'.+Ersteinrichtung" -and
        $consoleText -match "'Setup'\s*\{\s*Invoke-LabInitialSetupInteractive"
    )
    Add-CheckResult -Name 'Wizard nutzt den gemeinsamen abbrechbaren Eingabeadapter' -Success (
        $setupText -match 'Read-LabConsoleTextInput' -and $setupText -notmatch 'Read-Host'
    )
    & (Join-Path $PSScriptRoot 'Fixtures/InitialSetupWriteabilityChecks.ps1')
    Add-CheckResult -Name 'Explizite Schreibprobe: gemeinsamer Core, HTTP, CLI und eigene Dateisystemguards' -Success $true
}
catch { Add-CheckResult -Name 'Initial-Setup-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally {
    $env:SQL_SERVER_LAB_MEDIA_ROOT = $previousMediaRoot
    $env:SQL_SERVER_LAB_DATA_ROOT = $previousDataRoot
    $env:SQL_SERVER_LAB_CONTROLLER_ID = $previousControllerId
    if (Test-Path -LiteralPath $temporaryRoot) {
        $cleanup = Get-Item -LiteralPath $temporaryRoot -Force
        $resolvedCleanup = [IO.Path]::GetFullPath($cleanup.FullName).TrimEnd('\', '/')
        if ($cleanup.Attributes -band [IO.FileAttributes]::ReparsePoint -or
            [IO.Path]::GetDirectoryName($resolvedCleanup) -ne $temporaryParent -or
            [IO.Path]::GetFileName($resolvedCleanup) -ne $temporaryLeaf -or
            $resolvedCleanup -ne [IO.Path]::GetFullPath($temporaryRoot)) { throw 'INITIAL_SETUP_TEST_CLEANUP_SCOPE_INVALID' }
        Remove-Item -LiteralPath $resolvedCleanup -Recurse -Force
    }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
