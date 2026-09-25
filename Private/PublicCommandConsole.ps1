function Get-LabPublicCommandCommonParameterNames {
    [CmdletBinding()]
    param()

    @('Verbose','Debug','ErrorAction','WarningAction','InformationAction','ProgressAction',
        'ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer',
        'PipelineVariable','WhatIf','Confirm')
}

function Get-LabPublicCommandDefaultExpressions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Management.Automation.FunctionInfo]$Command)

    $defaults=@{}
    $paramBlock=$Command.ScriptBlock.Ast.ParamBlock
    if (-not $paramBlock) { return $defaults }
    foreach($parameter in @($paramBlock.Parameters)) {
        if ($parameter.DefaultValue) {
            $defaults[[string]$parameter.Name.VariablePath.UserPath]=[string]$parameter.DefaultValue.Extent.Text
        }
    }
    $defaults
}

function Get-LabPublicCommandAllowedValueText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Parameter)

    $type=[type]$Parameter.ParameterType
    $parts=[System.Collections.Generic.List[string]]::new()
    $validateSet=@($Parameter.Attributes|Where-Object {$_ -is [Management.Automation.ValidateSetAttribute]}|Select-Object -First 1)
    if($validateSet){$parts.Add(('Werte: '+(@($validateSet.ValidValues)-join ', ')))}
    elseif($type.IsEnum){$parts.Add(('Werte: '+([Enum]::GetNames($type)-join ', ')))}
    elseif($type -eq [switch] -or $type -eq [bool]){$parts.Add('Werte: true, false')}
    foreach($attribute in @($Parameter.Attributes)){
        if($attribute -is [Management.Automation.ValidateRangeAttribute]){$parts.Add("Bereich: $($attribute.MinRange) bis $($attribute.MaxRange)")}
        elseif($attribute -is [Management.Automation.ValidatePatternAttribute]){$parts.Add("Muster: $($attribute.RegexPattern)")}
        elseif($attribute -is [Management.Automation.ValidateCountAttribute]){$parts.Add("Anzahl: $($attribute.MinLength) bis $($attribute.MaxLength)")}
        elseif($attribute -is [Management.Automation.ValidateLengthAttribute]){$parts.Add("Laenge: $($attribute.MinLength) bis $($attribute.MaxLength)")}
        elseif($attribute -is [Management.Automation.ValidateNotNullOrEmptyAttribute]){$parts.Add('Nicht leer')}
        elseif($attribute -is [Management.Automation.ValidateNotNullAttribute]){$parts.Add('Nicht null')}
        elseif($attribute -is [Management.Automation.ValidateScriptAttribute]){$parts.Add('Benutzerdefinierte Befehlspruefung')}
    }
    if($parts.Count -eq 0){$parts.Add("Typ: $($type.Name)")}
    $parts -join '; '
}

function ConvertTo-LabPublicCommandDisplayValue {
    [CmdletBinding()]
    param([AllowNull()]$Value,[int]$Depth=0)

    if($null -eq $Value){return $null}
    if($Value -is [Security.SecureString] -or $Value -is [Management.Automation.PSCredential]){return '<geschuetzt>'}
    if($Value -is [string] -or $Value.GetType().IsPrimitive -or $Value -is [datetime] -or $Value -is [guid]){return $Value}
    if($Depth -ge 8){return '<maximale Anzeigetiefe erreicht>'}
    if($Value -is [Collections.IDictionary]){
        $copy=[ordered]@{}
        foreach($key in @($Value.Keys)){
            $copy[[string]$key]=if([string]$key -match '(?i)(password|secret|credential|token|connectionstring)'){'<geschuetzt>'}else{ConvertTo-LabPublicCommandDisplayValue -Value $Value[$key] -Depth ($Depth+1)}
        }
        return [pscustomobject]$copy
    }
    if($Value -is [Collections.IEnumerable]){return @($Value|ForEach-Object {ConvertTo-LabPublicCommandDisplayValue -Value $_ -Depth ($Depth+1)})}
    $copy=[ordered]@{}
    foreach($property in @($Value.PSObject.Properties|Where-Object MemberType -in @('Property','NoteProperty'))){
        $copy[$property.Name]=if($property.Name -match '(?i)(password|secret|credential|token|connectionstring)'){'<geschuetzt>'}else{ConvertTo-LabPublicCommandDisplayValue -Value $property.Value -Depth ($Depth+1)}
    }
    [pscustomobject]$copy
}

function Get-LabPublicCommandParameterDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Management.Automation.FunctionInfo]$Command,
        [Parameter(Mandatory)][Management.Automation.CommandParameterSetInfo]$ParameterSet
    )

    $common=Get-LabPublicCommandCommonParameterNames
    $defaults=Get-LabPublicCommandDefaultExpressions -Command $Command
    @($ParameterSet.Parameters|Where-Object {$_.Name -notin $common}|ForEach-Object {
        $name=[string]$_.Name
        $type=[type]$_.ParameterType
        [PSCustomObject]@{
            Name=$name
            ParameterType=$type
            TypeName=$type.FullName
            Mandatory=[bool]$_.IsMandatory
            Position=[int]$_.Position
            DefaultExpression=$(if($defaults.ContainsKey($name)){$defaults[$name]}elseif($_.IsMandatory){'<kein Standard>'}else{'<Befehlsstandard>'})
            AllowedValues=(Get-LabPublicCommandAllowedValueText -Parameter $_)
            Sensitive=($type -eq [Security.SecureString] -or $type -eq [Management.Automation.PSCredential] -or $name -match '(?i)(password|secret|credential)')
            IsCredential=($type -eq [Management.Automation.PSCredential])
            Attributes=@($_.Attributes)
        }
    })
}

function Get-LabPublicCommandExecutionDescriptors {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$CatalogItem)

    if (-not $CatalogItem.SupportsShouldProcess) { return @() }
    @([PSCustomObject]@{
        Name='WhatIf'
        ParameterType=[switch]
        TypeName=[switch].FullName
        Mandatory=$false
        Position=[int]::MinValue
        DefaultExpression='false'
        AllowedValues='Werte: true, false'
        Sensitive=$false
        IsCredential=$false
        Attributes=@()
    })
}

function Get-LabPublicCommandConsoleCatalog {
    [CmdletBinding()]
    param()

    $module=Get-Module SqlServerLab
    if(-not $module){throw 'PUBLIC_COMMAND_CATALOG_MODULE_NOT_LOADED'}
    @($module.ExportedFunctions.Values|Where-Object {$_.Name -ne 'Invoke-SqlServerLab'}|Sort-Object Name|ForEach-Object {
        $command=$_
        $sets=@($command.ParameterSets|ForEach-Object {
            [PSCustomObject]@{
                Name=[string]$_.Name
                IsDefault=([string]$_.Name -eq [string]$command.DefaultParameterSet)
                MandatoryNames=@($_.Parameters|Where-Object {$_.IsMandatory -and $_.Name -notin (Get-LabPublicCommandCommonParameterNames)}|ForEach-Object {$_.Name})
                Metadata=$_
            }
        })
        [PSCustomObject]@{
            Name=[string]$command.Name
            Verb=[string]$command.Verb
            Noun=[string]$command.Noun
            Command=$command
            ParameterSets=$sets
            SupportsShouldProcess=$command.Parameters.ContainsKey('WhatIf')
        }
    })
}

function ConvertFrom-LabPublicCommandInput {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text,[Parameter(Mandatory)][type]$TargetType)

    if([string]::IsNullOrWhiteSpace($Text)){return $null}
    if($TargetType -eq [string]){return $Text}
    if($TargetType -eq [switch] -or $TargetType -eq [bool]){return [bool]::Parse($Text)}
    if($TargetType -eq [Security.SecureString]){throw 'SECURE_INPUT_REQUIRES_MASKED_EDITOR'}
    if($TargetType -eq [hashtable]){return ($Text|ConvertFrom-Json -AsHashtable -Depth 100)}
    if($TargetType -eq [object] -or $TargetType -eq [pscustomobject]){
        if($Text.TrimStart().StartsWith('{') -or $Text.TrimStart().StartsWith('[')){return ($Text|ConvertFrom-Json -Depth 100)}
        return $Text
    }
    if($TargetType.IsArray){
        $elementType=$TargetType.GetElementType()
        $rawValues=if($Text.TrimStart().StartsWith('[')){@($Text|ConvertFrom-Json -Depth 100)}else{@($Text -split ','|ForEach-Object {$_.Trim()})}
        $array=[Array]::CreateInstance($elementType,$rawValues.Count)
        for($index=0;$index -lt $rawValues.Count;$index++){
            $array.SetValue([Management.Automation.LanguagePrimitives]::ConvertTo($rawValues[$index],$elementType,[Globalization.CultureInfo]::InvariantCulture),$index)
        }
        return $array
    }
    [Management.Automation.LanguagePrimitives]::ConvertTo($Text,$TargetType,[Globalization.CultureInfo]::InvariantCulture)
}

function Test-LabPublicCommandParameterValue {
    [CmdletBinding()]
    param([AllowNull()]$Value,[Parameter(Mandatory)]$Descriptor)

    if($null -eq $Value){return $(if($Descriptor.Mandatory){'Pflichtfeld ist nicht ausgefuellt.'}else{''})}
    foreach($attribute in @($Descriptor.Attributes)){
        if($attribute -is [Management.Automation.ValidatePatternAttribute] -and [string]$Value -notmatch $attribute.RegexPattern){return "Wert entspricht nicht dem Muster $($attribute.RegexPattern)."}
        if($attribute -is [Management.Automation.ValidateRangeAttribute] -and ($Value -lt $attribute.MinRange -or $Value -gt $attribute.MaxRange)){return "Wert muss zwischen $($attribute.MinRange) und $($attribute.MaxRange) liegen."}
        if($attribute -is [Management.Automation.ValidateSetAttribute] -and [string]$Value -notin @($attribute.ValidValues)){return "Zulaessig: $(@($attribute.ValidValues)-join ', ')."}
        if($attribute -is [Management.Automation.ValidateCountAttribute] -and (@($Value).Count -lt $attribute.MinLength -or @($Value).Count -gt $attribute.MaxLength)){return "Anzahl muss zwischen $($attribute.MinLength) und $($attribute.MaxLength) liegen."}
    }
    ''
}

function Edit-LabPublicCommandParameterValue {
    [CmdletBinding()]
    param([AllowNull()]$CurrentValue,[Parameter(Mandatory)]$Descriptor)

    $type=[type]$Descriptor.ParameterType
    $choices=@()
    $validateSet=@($Descriptor.Attributes|Where-Object {$_ -is [Management.Automation.ValidateSetAttribute]}|Select-Object -First 1)
    if($validateSet){$choices=@($validateSet.ValidValues)}
    elseif($type.IsEnum){$choices=@([Enum]::GetNames($type))}
    elseif($type -eq [switch] -or $type -eq [bool]){$choices=@('true','false')}
    if($choices.Count -gt 0){
        $items=@(for($index=0;$index -lt $choices.Count;$index++){New-LabConsoleItem -Id ([string]$choices[$index]) -Label ([string]$choices[$index]) -Shortcut ([string]($index+1))})
        $selection=Invoke-LabConsoleMenu -ScreenId 'public-command-value-selection' -Title $Descriptor.Name -Subtitle $Descriptor.AllowedValues -Items $items
        if($selection.Status -ne 'Selected'){return $CurrentValue}
        return ConvertFrom-LabPublicCommandInput -Text ([string]$selection.SelectedItem.Id) -TargetType $type
    }
    if($Descriptor.IsCredential){
        $user=Read-LabConsoleTextInput -Prompt "$($Descriptor.Name) - Benutzername"
        if($user.Status -ne 'Confirmed'){return $CurrentValue}
        $password=Read-LabConsoleTextInput -Prompt "$($Descriptor.Name) - Kennwort" -AsSecureString
        if($password.Status -ne 'Confirmed'){return $CurrentValue}
        return [Management.Automation.PSCredential]::new([string]$user.Value,$password.Value)
    }
    if($type -eq [Security.SecureString]){
        $input=Read-LabConsoleTextInput -Prompt "$($Descriptor.Name) ($($Descriptor.AllowedValues))" -AsSecureString
        if($input.Status -ne 'Confirmed'){return $CurrentValue}
        return $input.Value
    }
    if($Descriptor.Sensitive -and $type -eq [string]){
        $input=Read-LabConsoleTextInput -Prompt "$($Descriptor.Name) ($($Descriptor.AllowedValues))" -MaskInput
        if($input.Status -ne 'Confirmed'){return $CurrentValue}
        return [string]$input.Value
    }
    $defaultText=if($null -eq $CurrentValue){''}elseif($type -eq [string]){[string]$CurrentValue}else{$CurrentValue|ConvertTo-Json -Compress -Depth 20}
    $input=Read-LabConsoleTextInput -Prompt "$($Descriptor.Name) ($($Descriptor.AllowedValues))" -Default $defaultText
    if($input.Status -ne 'Confirmed'){return $CurrentValue}
    try{return ConvertFrom-LabPublicCommandInput -Text ([string]$input.Value) -TargetType $type}
    catch{Write-LabWarning "Eingabe fuer '$($Descriptor.Name)' ist ungueltig: $($_.Exception.Message)";return $CurrentValue}
}

function Invoke-LabPublicCommandInteractive {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$CatalogItem)

    $sets=@($CatalogItem.ParameterSets)
    $selectedSet=if($sets.Count -eq 1){$sets[0]}else{
        $items=@(for($index=0;$index -lt $sets.Count;$index++){
            $set=$sets[$index];$required=if($set.MandatoryNames.Count){$set.MandatoryNames -join ', '}else{'keine Pflichtfelder'}
            New-LabConsoleItem -Id $set.Name -Label $set.Name -Value $required -Shortcut ([string]($index+1)) -Data $set
        })
        $selection=Invoke-LabConsoleMenu -ScreenId 'public-command-parameter-set' -Title $CatalogItem.Name -Subtitle 'Parametersatz auswaehlen' -Items $items
        if($selection.Status -ne 'Selected'){return}
        $selection.SelectedItem.Data
    }
    $descriptors=@(
        Get-LabPublicCommandParameterDescriptor -Command $CatalogItem.Command -ParameterSet $selectedSet.Metadata
        Get-LabPublicCommandExecutionDescriptors -CatalogItem $CatalogItem
    )
    $fields=@(for($index=0;$index -lt $descriptors.Count;$index++){
        $descriptor=$descriptors[$index]
        $editor={param($current,$all) Edit-LabPublicCommandParameterValue -CurrentValue $current -Descriptor $descriptor}.GetNewClosure()
        $validator={param($value,$all) Test-LabPublicCommandParameterValue -Value $value -Descriptor $descriptor}.GetNewClosure()
        $formatter={param($value) if($null -eq $value){$descriptor.DefaultExpression}elseif($descriptor.Sensitive){'<gesetzt>'}elseif($value -is [Array]){@($value)-join ', '}elseif($value -is [string] -or $value.GetType().IsPrimitive){[string]$value}else{$value|ConvertTo-Json -Compress -Depth 5}}.GetNewClosure()
        [PSCustomObject]@{Id=$descriptor.Name;Label="$($descriptor.Name) ($(if($descriptor.Mandatory){'Pflicht'}else{'optional'}))";Shortcut=[string]($index+1);Value=$null;Sensitive=[bool]$descriptor.Sensitive;Required=[bool]$descriptor.Mandatory;Disabled=$false;DisabledReason='';Editor=$editor;Validator=$validator;Formatter=$formatter;Descriptor=$descriptor}
    })
    Write-LabInfo "Parametersatz: $($selectedSet.Name). Defaults und erlaubte Werte stehen an jedem Feld. Komplexe Werte als JSON eingeben."
    $form=Invoke-LabConsoleForm -ScreenId 'public-command-parameters' -Title $CatalogItem.Name -Subtitle "Parametersatz $($selectedSet.Name)" -Fields $fields
    if($form.Status -ne 'Confirmed'){return}
    $arguments=@{}
    foreach($descriptor in $descriptors){
        $hasValue=if($descriptor.Sensitive){$form.SecureValues.ContainsKey($descriptor.Name)}else{$form.Values.ContainsKey($descriptor.Name) -and $null -ne $form.Values[$descriptor.Name]}
        if(-not $hasValue){continue}
        $value=if($descriptor.Sensitive){$form.SecureValues[$descriptor.Name]}else{$form.Values[$descriptor.Name]}
        if($descriptor.ParameterType -eq [switch] -and -not [bool]$value){continue}
        $arguments[$descriptor.Name]=$value
    }
    Write-LabInfo "Fuehre $($CatalogItem.Name) mit Parametersatz $($selectedSet.Name) aus."
    $result=@(& $CatalogItem.Command @arguments)
    if($result.Count -gt 0){
        foreach($item in $result){
            $display=ConvertTo-LabPublicCommandDisplayValue -Value $item
            if($display -is [string] -or $display.GetType().IsPrimitive){Write-Host ([string]$display)}
            else{$display|Format-List *|Out-String|Write-Host}
        }
    }
    else{Write-LabSuccess "$($CatalogItem.Name) wurde ohne Rueckgabe abgeschlossen."}
    Wait-LabConsoleAcknowledgement
}

function Manage-LabPublicCommandsInteractive {
    [CmdletBinding()]
    param()

    while($true){
        $catalog=@(Get-LabPublicCommandConsoleCatalog)
        $items=@(for($index=0;$index -lt $catalog.Count;$index++){
            $entry=$catalog[$index]
            $setNames=@($entry.ParameterSets.Name)-join ', '
            New-LabConsoleItem -Id $entry.Name -Label $entry.Name -Value "Parametersaetze: $setNames" -Shortcut ([string]($index+1)) -Data $entry
        })
        $selection=Invoke-LabConsoleMenu -ScreenId 'public-command-menu' -Title 'Alle oeffentlichen Befehle' -Subtitle 'Vollstaendiger exportierter Funktionsumfang mit Defaults und Eingabevertraegen' -Items $items
        if($selection.Status -ne 'Selected'){return}
        Invoke-LabPublicCommandInteractive -CatalogItem $selection.SelectedItem.Data
    }
}
