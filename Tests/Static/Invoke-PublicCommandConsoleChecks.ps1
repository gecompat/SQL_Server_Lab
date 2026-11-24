#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    . (Join-Path $PSScriptRoot 'Fixtures/PublicCommandConsoleSensitiveBytesChecks.ps1')
    $manifest=Import-PowerShellDataFile (Join-Path $repoRoot 'SqlServerLab.psd1')
    $exports=@($manifest.FunctionsToExport|Sort-Object -Unique)
    $evidence=& $module {
        $catalog=@(Get-LabPublicCommandConsoleCatalog)
        $portCommand=$catalog|Where-Object Name -eq 'Get-SqlServerLabReconcilePlan'
        $portSet=$portCommand.ParameterSets|Where-Object Name -eq 'ContainerPortPreview'
        $portDescriptors=@(Get-LabPublicCommandParameterDescriptor -Command $portCommand.Command -ParameterSet $portSet.Metadata)
        $autoStartSet=$portCommand.ParameterSets|Where-Object Name -eq 'ContainerAutoStartPreview'
        $autoStartDescriptors=@(Get-LabPublicCommandParameterDescriptor -Command $portCommand.Command -ParameterSet $autoStartSet.Metadata)
        $selection=$catalog|Where-Object Name -eq 'Get-SqlServerLabAiComputeSelection'
        $auto=$selection.ParameterSets|Where-Object Name -eq 'Auto'
        $pinned=$selection.ParameterSets|Where-Object Name -eq 'Pinned'
        $autoDescriptors=@(Get-LabPublicCommandParameterDescriptor -Command $selection.Command -ParameterSet $auto.Metadata)
        $pinnedDescriptors=@(Get-LabPublicCommandParameterDescriptor -Command $selection.Command -ParameterSet $pinned.Metadata)
        $whatIfCommand=$catalog|Where-Object SupportsShouldProcess|Select-Object -First 1
        $webCatalog=@(Get-LabPublicCommandWebCatalog)
        $catalogExport=$webCatalog | Where-Object Name -CEQ 'Get-SqlServerLabCatalog'
        $catalogSet=@($catalogExport.ParameterSets)[0]
        $catalogExportErrors=@(foreach ($parameters in @(@{},@{Path='DO_NOT_WRITE'},@{StateRoot='DO_NOT_WRITE'},@{MediaRoot='DO_NOT_READ'})) {
            try {
                $null = Invoke-LabPublicCommandWebRequest -CommandName $catalogExport.Name -ParameterSetName $catalogSet.Name -Parameters $parameters -Confirmed:($parameters.Count -ne 0)
            } catch { $_.Exception.Message }
        })
        $catalogExportProjection=@(ConvertTo-LabPublicCommandWebResult -CommandName $catalogExport.Name -Parameters @{} -Result @([pscustomobject]@{
            Path='PRIVATE_PATH'; Catalog=[pscustomobject]@{
                CatalogFormat='1'; StateRoot='PRIVATE_ROOT'; Workflow='PRIVATE_WORKFLOW'
                Summary=[pscustomobject]@{ActiveContainerLabs=1;WindowsBaselines=2;SqlPreparedImages=3;PendingWindowsBuilds=4;PendingSqlBuilds=5}
            }
        }))
        $catalogRootReader = (Get-Command Get-LabStateRoot).ScriptBlock
        $catalogWriter = (Get-Command Get-SqlServerLabCatalog).ScriptBlock
        $script:catalogBrowserTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('catalog-browser-' + [guid]::NewGuid().ToString('N'))
        try {
            Set-Item Function:script:Get-LabStateRoot -Value { $script:catalogBrowserTestRoot }
            Set-Item Function:script:Get-SqlServerLabCatalog -Value {
                [CmdletBinding()]
                param([string]$Path,[string]$StateRoot)
                if ($StateRoot -cne $script:catalogBrowserTestRoot -or $Path -cne (Join-Path $StateRoot 'catalog/sql-server-lab-catalog.json')) {
                    throw 'CATALOG_TEST_TARGET_INVALID'
                }
                [pscustomobject]@{Path=$Path;Catalog=[pscustomobject]@{CatalogFormat='1'
                    Summary=[pscustomobject]@{ActiveContainerLabs=1;WindowsBaselines=0;SqlPreparedImages=0;PendingWindowsBuilds=0;PendingSqlBuilds=0}
                }}
            }
            $writerUnderTest = Get-LabPublicCommandConsoleCatalog | Where-Object Name -CEQ $catalogExport.Name
            if (-not $writerUnderTest.Command.ScriptBlock.ToString().Contains('CATALOG_TEST_TARGET_INVALID')) {
                throw 'CATALOG_TEST_MOCK_NOT_BOUND'
            }
            $catalogBoundReceipt = Invoke-LabPublicCommandWebRequest -CommandName $catalogExport.Name -ParameterSetName $catalogSet.Name -Parameters @{} -Confirmed
        }
        finally {
            Set-Item Function:script:Get-LabStateRoot -Value $catalogRootReader
            Set-Item Function:script:Get-SqlServerLabCatalog -Value $catalogWriter
            Remove-Variable catalogBrowserTestRoot -Scope Script -ErrorAction SilentlyContinue
        }
        $autoStartWebCommands=@($webCatalog|Where-Object Name -ceq 'Get-SqlServerLabReconcilePlan')
        $autoStartWebSets=@($autoStartWebCommands[0].ParameterSets|Where-Object Name -ceq 'ContainerAutoStartPreview')
        $hyperVPlanWeb=@($webCatalog|Where-Object Name -ceq 'Get-SqlServerLabHyperVAutoStartPlan')
        $hyperVSetWeb=@($webCatalog|Where-Object Name -ceq 'Set-SqlServerLabHyperVAutoStart')
        $hyperVSetDescriptors=@($hyperVSetWeb[0].ParameterSets[0].Parameters)
        $slotPoolWeb=$webCatalog|Where-Object Name -ceq 'New-SqlServerLabWindowsSlotPool'
        $slotGenerated=$slotPoolWeb.ParameterSets|Where-Object Name -ceq 'GeneratedPassword'
        $slotSupplied=$slotPoolWeb.ParameterSets|Where-Object Name -ceq 'UserPassword'
        $confirmationError=''
        try { Invoke-LabPublicCommandWebRequest -CommandName $whatIfCommand.Name -ParameterSetName $whatIfCommand.ParameterSets[0].Name -Parameters @{} } catch { $confirmationError=$_.Exception.Message }
        $unknownError=''
        try { Invoke-LabPublicCommandWebRequest -CommandName 'Invoke-NotExported' -ParameterSetName 'Default' -Parameters @{} -Confirmed } catch { $unknownError=$_.Exception.Message }
        $credential=ConvertFrom-LabPublicCommandWebValue -Value ([pscustomobject]@{userName='lab-user';password='temporary-value'}) -TargetType ([Management.Automation.PSCredential])
        $backupCommand=$webCatalog | Where-Object Name -CEQ 'Backup-SqlServerLabDatabase'
        $backupSet=$backupCommand.ParameterSets | Where-Object Name -CEQ 'RunBased'
        $backup=[pscustomobject]@{Status='BACKUP_REUSABLE';BackupSetId='11111111-1111-4111-8111-111111111111';DatabaseName='Demo'
            Provider='docker';Sha256='a'*64;Bytes=[long]8192;HasFileStream=$false;Path='CANARY_PRIVATE_PATH'
            RegistryPath='CANARY_PRIVATE_REGISTRY';Credential='CANARY_PRIVATE_CREDENTIAL'}
        $backupProjection=@(ConvertTo-LabPublicCommandWebResult -CommandName Backup-SqlServerLabDatabase -Parameters @{DatabaseName='Demo'} -Result @($backup))
        $backupMismatch=$null
        try { $null=ConvertTo-LabPublicCommandWebResult -CommandName Backup-SqlServerLabDatabase -Parameters @{DatabaseName='Other'} -Result @($backup) }
        catch { $backupMismatch=$_.Exception.Message }
        [pscustomobject]@{
            PortMandatory=@($portSet.MandatoryNames)
            AutoStartPreviewMandatory=@($autoStartSet.MandatoryNames)
            AutoStartPreviewNames=@($autoStartDescriptors.Name)
            AutoStartPreviewValues=($autoStartDescriptors|Where-Object Name -eq 'AutoStart').AllowedValues
            AutoStartWebCommands=$autoStartWebCommands.Count
            AutoStartWebSets=$autoStartWebSets.Count
            AutoStartWebRequiresConfirmation=$autoStartWebCommands[0].RequiresConfirmation
            AutoStartWebMandatory=@($autoStartWebSets[0].Parameters|Where-Object Mandatory|ForEach-Object Name)
            HyperVPlanWeb=$hyperVPlanWeb.Count; HyperVSetWeb=$hyperVSetWeb.Count
            HyperVSetConfirmation=$hyperVSetWeb[0].RequiresConfirmation
            HyperVSetMandatory=@($hyperVSetDescriptors|Where-Object Mandatory|ForEach-Object Name)
            SlotPoolConfirmation=$slotPoolWeb.RequiresConfirmation
            SlotPoolGenerated=@($slotGenerated.Parameters|Where-Object Name -ceq 'GenerateAdministratorPasswords')
            SlotPoolSupplied=@($slotSupplied.Parameters|Where-Object Name -ceq 'AdministratorPassword')
            SlotPoolGeneratedNames=@($slotGenerated.Parameters.Name)
            PortDescriptorNames=@($portDescriptors.Name)
            PortRange=($portDescriptors|Where-Object Name -eq 'Port').AllowedValues
            Names=@($catalog.Name)
            DuplicateNames=@($catalog|Group-Object Name|Where-Object Count -gt 1|ForEach-Object Name)
            EmptyParameterSets=@($catalog|Where-Object {$_.ParameterSets.Count -eq 0}|ForEach-Object Name)
            AutoMandatory=@($auto.MandatoryNames)
            PinnedMandatory=@($pinned.MandatoryNames)
            AutoDescriptorNames=@($autoDescriptors.Name)
            PinnedDescriptorNames=@($pinnedDescriptors.Name)
            HashConstraint=($autoDescriptors|Where-Object Name -eq 'ModelSha256').AllowedValues
            WhatIfDescriptor=@(Get-LabPublicCommandExecutionDescriptors -CatalogItem $whatIfCommand)
            BoolTrue=(ConvertFrom-LabPublicCommandInput -Text 'true' -TargetType ([bool]))
            StringArray=@(ConvertFrom-LabPublicCommandInput -Text '["a","b"]' -TargetType ([string[]]))
            Hashtable=(ConvertFrom-LabPublicCommandInput -Text '{"a":1}' -TargetType ([hashtable]))
            Sanitized=(ConvertTo-LabPublicCommandDisplayValue -Value ([pscustomobject]@{Name='lab';Password='sensitive';Nested=[pscustomobject]@{ConnectionString='Server=x;Password=secret';Value=42}}))
            SanitizedWebMail=@(ConvertTo-LabPublicCommandWebResult -CommandName Open-SqlServerLabSmtpTestServiceWebMail -Parameters @{} -Result @(
                [pscustomobject]@{ContractVersion='SqlServerLab.SmtpTestServiceWebMailAccess/1.0'; Url='synthetic-capability-url'; Status='OPENED'; BrowserStarted=$true}
            ))
            CatalogExportConfirmation=$catalogExport.RequiresConfirmation
            CatalogExportParameterCount=@($catalogSet.Parameters).Count
            CatalogExportErrors=$catalogExportErrors
            CatalogExportProjection=$catalogExportProjection
            CatalogBoundReceipt=$catalogBoundReceipt.Result
            BackupConfirmation=$backupCommand.RequiresConfirmation
            BackupMandatory=@($backupSet.MandatoryNames)
            BackupPassword=$backupSet.Parameters | Where-Object Name -CEQ 'SaPassword'
            BackupProjection=$backupProjection
            BackupMismatch=$backupMismatch
            WebNames=@($webCatalog.Name)
            WebJson=($webCatalog|ConvertTo-Json -Depth 12)
            WebCmsCount=@($webCatalog|Where-Object Area -eq 'CMS').Count
            WebEmptyParameterSets=@($webCatalog|Where-Object {@($_.ParameterSets).Count -eq 0}|ForEach-Object Name)
            ConfirmationError=$confirmationError
            UnknownError=$unknownError
            CredentialUserName=$credential.UserName
            CredentialPasswordLength=$credential.GetNetworkCredential().Password.Length
        }
    }
    $expectedCatalog=@($exports|Where-Object {$_ -ne 'Invoke-SqlServerLab'})
    Add-CheckResult 'Browser-Katalogexport benötigt Bestätigung und lehnt alle Pfad- oder Root-Overrides vor der Ausführung ab' (
        $evidence.CatalogExportConfirmation -eq $true -and $evidence.CatalogExportParameterCount -eq 0 -and
        $evidence.CatalogExportErrors.Count -eq 4 -and $evidence.CatalogExportErrors[0] -ceq 'PUBLIC_COMMAND_UI_CONFIRMATION_REQUIRED' -and
        @($evidence.CatalogExportErrors | Where-Object {$_ -ceq 'PUBLIC_COMMAND_UI_CATALOG_SCOPE_INVALID'}).Count -eq 3
    )
    Add-CheckResult 'Browser-Katalogexport zeigt nur Bestätigung, festen Dateinamen und aggregierte Zähler' (
        $evidence.CatalogExportProjection.Count -eq 1 -and $evidence.CatalogExportProjection[0].Status -ceq 'CATALOG_WRITTEN' -and
        $evidence.CatalogExportProjection[0].FileName -ceq 'sql-server-lab-catalog.json' -and $evidence.CatalogExportProjection[0].PendingSqlBuilds -eq 5 -and
        ($evidence.CatalogExportProjection | ConvertTo-Json -Depth 5) -cnotmatch 'PRIVATE_|StateRoot|Workflow|"Path"'
    )
    Add-CheckResult 'Bestätigter Browser-Katalogexport bindet serverseitig genau Standard-State-Root und Standarddatei' (
        $evidence.CatalogBoundReceipt.Count -eq 1 -and $evidence.CatalogBoundReceipt[0].Status -ceq 'CATALOG_WRITTEN' -and
        $evidence.CatalogBoundReceipt[0].ActiveContainerLabs -eq 1
    )
    Add-CheckResult 'AutoStart PLAN_ONLY catalog derives mandatory union and ValidateSet from actual metadata' (
        (@($evidence.AutoStartPreviewMandatory|Sort-Object) -join '|') -ceq 'AutoStart|ContainerAutoStartPreview|InstanceId|RunId' -and
        'StateRoot' -in $evidence.AutoStartPreviewNames -and 'Cpu' -notin $evidence.AutoStartPreviewNames -and
        'Port' -notin $evidence.AutoStartPreviewNames -and $evidence.AutoStartPreviewValues -match 'on' -and
        $evidence.AutoStartPreviewValues -match 'off' -and $evidence.AutoStartWebCommands -eq 1 -and
        $evidence.AutoStartWebSets -eq 1 -and $evidence.AutoStartWebRequiresConfirmation -is [bool] -and
        $evidence.AutoStartWebRequiresConfirmation -eq $false -and
        (@($evidence.AutoStartWebMandatory|Sort-Object) -join '|') -ceq 'AutoStart|ContainerAutoStartPreview|InstanceId|RunId'
    )
    Add-CheckResult 'Port-PLAN_ONLY erscheint als getrennter nativer Parametersatz im generischen Konsolenkatalog' (
        (@($evidence.PortMandatory|Sort-Object) -join '|') -ceq 'ContainerPortPreview|InstanceId|Port|RunId' -and
        'StateRoot' -in $evidence.PortDescriptorNames -and 'Cpu' -notin $evidence.PortDescriptorNames -and
        'TargetState' -notin $evidence.PortDescriptorNames -and $evidence.PortRange -match '1024' -and $evidence.PortRange -match '65535'
    )
    Add-CheckResult 'Hyper-V-Autostartplan und bestätigter Executor erscheinen im gemeinsamen GUI-Katalog' (
        $evidence.HyperVPlanWeb -eq 1 -and $evidence.HyperVSetWeb -eq 1 -and $evidence.HyperVSetConfirmation -eq $true -and
        (@($evidence.HyperVSetMandatory|Sort-Object) -join '|') -ceq 'AutoStart|ExpectedAutoStartPlanKey|RunId'
    )
    Add-CheckResult 'Windows-Pool erlaubt den Generierungsschalter und schützt das eingegebene Passwort' (
        $evidence.SlotPoolConfirmation -eq $true -and
        $evidence.SlotPoolGenerated.Count -eq 1 -and $evidence.SlotPoolGenerated[0].Mandatory -eq $true -and
        $evidence.SlotPoolGenerated[0].TypeName -ceq 'System.Management.Automation.SwitchParameter' -and
        $evidence.SlotPoolGenerated[0].Sensitive -eq $false -and
        'AdministratorPassword' -notin $evidence.SlotPoolGeneratedNames -and
        $evidence.SlotPoolSupplied.Count -eq 1 -and $evidence.SlotPoolSupplied[0].Sensitive -eq $true
    )
    Add-CheckResult 'Jeder Modulexport erscheint exakt einmal im vollständigen Konsolenkatalog' (
        @($expectedCatalog|Where-Object {$_ -notin $evidence.Names}).Count -eq 0 -and
        @($evidence.Names|Where-Object {$_ -notin $expectedCatalog}).Count -eq 0 -and
        $evidence.DuplicateNames.Count -eq 0
    )
    Add-CheckResult 'Invoke-SqlServerLab bleibt der einzelne Einstieg statt eines rekursiven Katalogeintrags' (
        'Invoke-SqlServerLab' -in $exports -and 'Invoke-SqlServerLab' -notin $evidence.Names
    )
    Add-CheckResult 'Jeder Katalogeintrag besitzt mindestens einen nativen Parametersatz' ($evidence.EmptyParameterSets.Count -eq 0)
    Add-CheckResult 'Alternative Auto- und Pinned-Parametersätze bleiben getrennt' (
        'Benchmark' -in $evidence.AutoDescriptorNames -and 'PinnedCandidateId' -notin $evidence.AutoDescriptorNames -and
        'PinnedCandidateId' -in $evidence.PinnedDescriptorNames -and 'Benchmark' -notin $evidence.PinnedDescriptorNames
    )
    Add-CheckResult 'Pflichtfelder und Validierungshinweise stammen aus den Befehlsmetadaten' (
        'Benchmark' -in $evidence.AutoMandatory -and 'PinnedCandidateId' -in $evidence.PinnedMandatory -and
        $evidence.HashConstraint -match 'Muster:'
    )
    Add-CheckResult 'SupportsShouldProcess erhält WhatIf mit sicherem Standard false' (
        $evidence.WhatIfDescriptor.Count -eq 1 -and $evidence.WhatIfDescriptor[0].Name -ceq 'WhatIf' -and
        $evidence.WhatIfDescriptor[0].DefaultExpression -ceq 'false'
    )
    Add-CheckResult 'Boolesche, Array- und Hashtable-Eingaben werden strukturiert konvertiert' (
        $evidence.BoolTrue -eq $true -and @($evidence.StringArray).Count -eq 2 -and
        $evidence.StringArray[1] -ceq 'b' -and $evidence.Hashtable.a -eq 1
    )
    Add-CheckResult 'Generische Befehlsausgabe maskiert sensible Eigenschaften rekursiv' (
        $evidence.Sanitized.Name -ceq 'lab' -and $evidence.Sanitized.Password -ceq '<geschuetzt>' -and
        $evidence.Sanitized.Nested.ConnectionString -ceq '<geschuetzt>' -and $evidence.Sanitized.Nested.Value -eq 42
    )
    Add-CheckResult 'Generische Ausgabe protokolliert keinen WebMail-Zugangslink' (
        $evidence.SanitizedWebMail.Count -eq 1 -and $evidence.SanitizedWebMail[0].Url -ceq '<geschuetzt>' -and
        $evidence.SanitizedWebMail[0].Status -ceq 'OPENED' -and $evidence.SanitizedWebMail[0].BrowserStarted -eq $true)
    Add-CheckResult 'Backup im Browser bindet RunBased und maskiertes Passwort hinter der Bestätigung' (
        $evidence.BackupConfirmation -eq $true -and
        (@($evidence.BackupMandatory | Sort-Object) -join ',') -ceq 'DatabaseName,RunId,SaPassword' -and
        $evidence.BackupPassword.TypeName -ceq 'System.Security.SecureString' -and $evidence.BackupPassword.Sensitive -eq $true)
    Add-CheckResult 'Backupquittung enthält feste Angaben und keine Pfade oder Zugangsdaten' (
        $evidence.BackupProjection.Count -eq 1 -and $evidence.BackupProjection[0].Status -ceq 'BACKUP_REUSABLE' -and
        $evidence.BackupProjection[0].BackupSetId -ceq '11111111-1111-4111-8111-111111111111' -and
        $evidence.BackupProjection[0].Bytes -eq 8192 -and
        ($evidence.BackupProjection | ConvertTo-Json) -cnotmatch 'CANARY_PRIVATE|RegistryPath|Credential' -and
        $evidence.BackupMismatch -ceq 'PUBLIC_COMMAND_UI_RESULT_INVALID')
    Add-CheckResult 'GUI und CLI verwenden denselben vollständigen Exportkatalog' (
        @($expectedCatalog|Where-Object {$_ -notin $evidence.WebNames}).Count -eq 0 -and
        @($evidence.WebNames|Where-Object {$_ -notin $expectedCatalog}).Count -eq 0 -and
        $evidence.WebEmptyParameterSets.Count -eq 0
    )
    Add-CheckResult 'GUI-Katalog bleibt JSON-sicher und gruppiert CMS-Funktionen' (
        $evidence.WebCmsCount -gt 0 -and $evidence.WebJson -notmatch 'CommandParameterSetInfo|FunctionInfo|ValidateSetAttribute'
    )
    Add-CheckResult 'GUI-Ausführung sperrt unbekannte Befehle und fordert Mutationsbestätigung' (
        $evidence.UnknownError -match 'PUBLIC_COMMAND_UI_COMMAND_NOT_EXPORTED' -and
        $evidence.ConfirmationError -match 'PUBLIC_COMMAND_UI_CONFIRMATION_REQUIRED'
    )
    Add-CheckResult 'GUI-Credentials werden erst im Prozess in PSCredential umgewandelt' (
        $evidence.CredentialUserName -ceq 'lab-user' -and $evidence.CredentialPasswordLength -eq 15
    )
    $entrySource=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1') -Raw
    Add-CheckResult 'Direktaktion und Hauptmenü führen in den vollständigen Befehlszugang' (
        $entrySource -match "'Commands'" -and $entrySource -match "'commands'\s*\{\s*Manage-LabPublicCommandsInteractive" -and
        $entrySource -match "-Id 'commands'"
    )
}
finally {Remove-Module $module -Force}
if($failures.Count){throw ($failures -join '; ')}
Write-Host "PUBLIC COMMAND CONSOLE CONTRACT: PASS ($passed)"
