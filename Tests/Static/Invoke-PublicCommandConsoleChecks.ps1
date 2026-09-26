#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $PSScriptRoot '../Common/CheckResult.ps1')
$failures=[Collections.Generic.List[string]]::new();$passed=0
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $manifest=Import-PowerShellDataFile (Join-Path $repoRoot 'SqlServerLab.psd1')
    $exports=@($manifest.FunctionsToExport|Sort-Object -Unique)
    $evidence=& $module {
        $catalog=@(Get-LabPublicCommandConsoleCatalog)
        $selection=$catalog|Where-Object Name -eq 'Get-SqlServerLabAiComputeSelection'
        $auto=$selection.ParameterSets|Where-Object Name -eq 'Auto'
        $pinned=$selection.ParameterSets|Where-Object Name -eq 'Pinned'
        $autoDescriptors=@(Get-LabPublicCommandParameterDescriptor -Command $selection.Command -ParameterSet $auto.Metadata)
        $pinnedDescriptors=@(Get-LabPublicCommandParameterDescriptor -Command $selection.Command -ParameterSet $pinned.Metadata)
        $whatIfCommand=$catalog|Where-Object SupportsShouldProcess|Select-Object -First 1
        $webCatalog=@(Get-LabPublicCommandWebCatalog)
        $confirmationError=''
        try { Invoke-LabPublicCommandWebRequest -CommandName $whatIfCommand.Name -ParameterSetName $whatIfCommand.ParameterSets[0].Name -Parameters @{} } catch { $confirmationError=$_.Exception.Message }
        $unknownError=''
        try { Invoke-LabPublicCommandWebRequest -CommandName 'Invoke-NotExported' -ParameterSetName 'Default' -Parameters @{} -Confirmed } catch { $unknownError=$_.Exception.Message }
        $credential=ConvertFrom-LabPublicCommandWebValue -Value ([pscustomobject]@{userName='lab-user';password='temporary-value'}) -TargetType ([Management.Automation.PSCredential])
        [pscustomobject]@{
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
