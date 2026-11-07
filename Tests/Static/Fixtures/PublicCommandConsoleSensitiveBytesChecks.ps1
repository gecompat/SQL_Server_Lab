# Actual display, parameter metadata, CLI editor and web conversion. Synthetic
# canaries only; no reader invocation, SQL or provider command is required.
$byteEvidence=& $module {
    $bytes=[Text.Encoding]::UTF8.GetBytes('{"password":"SYNTHETIC_BYTES_CANARY_891"}')
    $snapshot=[pscustomobject]@{ExportBytes=$bytes;Contract=[pscustomobject]@{password='SYNTHETIC_BYTES_CANARY_891'}}
    $display=ConvertTo-LabPublicCommandDisplayValue $snapshot
    $dictionary=ConvertTo-LabPublicCommandDisplayValue @{ExportBytes=@(1,2,3);Nested=@{Raw=$bytes}}
    $catalog=Get-LabPublicCommandConsoleCatalog|Where-Object Name -ceq 'Read-SqlServerLabQualifiedTestEnvironment'
    $set=$catalog.ParameterSets|Where-Object Name -ceq 'Bytes'
    $descriptor=Get-LabPublicCommandParameterDescriptor -Command $catalog.Command -ParameterSet $set.Metadata|Where-Object Name -ceq 'ExportBytes'
    $savedRead=(Get-Command Read-LabConsoleTextInput).ScriptBlock
    $savedWarning=(Get-Command Write-LabWarning).ScriptBlock
    try{
        Set-Item Function:script:Read-LabConsoleTextInput -Value {param($Prompt,[switch]$MaskInput,$Default)
            $script:bytesInputMasked=[bool]$MaskInput;$script:bytesInputDefault=$PSBoundParameters.ContainsKey('Default')
            [pscustomobject]@{Status='Confirmed';Value=$script:bytesInputText}
        }
        Set-Item Function:script:Write-LabWarning -Value {param($Message) $script:bytesInputWarning=[string]$Message}
        $script:bytesInputText='[65,66]'
        $edited=@(Edit-LabPublicCommandParameterValue -CurrentValue $bytes -Descriptor $descriptor)
        $masked=$script:bytesInputMasked;$noDefault=-not $script:bytesInputDefault
        $script:bytesInputText='["SYNTHETIC_INPUT_CANARY"]';$script:bytesInputWarning=''
        $null=Edit-LabPublicCommandParameterValue -CurrentValue $bytes -Descriptor $descriptor
        $safeWarning=$script:bytesInputWarning -ceq "Eingabe fuer 'ExportBytes' ist ungueltig."
    }finally{
        Set-Item Function:script:Read-LabConsoleTextInput -Value $savedRead
        Set-Item Function:script:Write-LabWarning -Value $savedWarning
    }
    $webError=''
    try{$null=Invoke-LabPublicCommandWebRequest -CommandName $catalog.Name -ParameterSetName 'Bytes' -Parameters @{ExportBytes=@('SYNTHETIC_INPUT_CANARY');RunId='synthetic-run';StateRoot='synthetic-state';InstanceId='primary'}}catch{$webError=$_.Exception.Message}
    $singleByte=@(ConvertFrom-LabPublicCommandInput -Text '[65]' -TargetType ([byte[]]))
    $singleString=@(ConvertFrom-LabPublicCommandInput -Text '["complete-value"]' -TargetType ([string[]]))
    $overflowRejected=$false
    try{$null=ConvertFrom-LabPublicCommandInput -Text '[300]' -TargetType ([byte[]])}catch{$overflowRejected=$true}
    [ordered]@{
        'Exportbytes are masked in object and dictionary displays'=($display.ExportBytes -ceq '<geschuetzt>' -and $dictionary.ExportBytes -ceq '<geschuetzt>')
        'Naked and nested binary displays never serialize credential bytes'=((ConvertTo-LabPublicCommandDisplayValue $bytes) -ceq '<geschuetzt>' -and $dictionary.Nested.Raw -ceq '<geschuetzt>' -and ($display|ConvertTo-Json -Depth 8) -notmatch 'SYNTHETIC_BYTES_CANARY_891')
        'Display projection leaves the programmatic reader bytes unchanged'=([Text.Encoding]::UTF8.GetString($snapshot.ExportBytes) -ceq '{"password":"SYNTHETIC_BYTES_CANARY_891"}')
        'Real reader byte parameter remains selectable and is sensitive'=($descriptor.Sensitive -and $descriptor.ParameterType -eq [byte[]] -and $set.MandatoryNames -contains 'ExportBytes')
        'CLI structured bytes use masked input without a secret default'=($masked -and $noDefault -and ($edited -join ',') -ceq '65,66')
        'CLI byte conversion failures never echo the input'=$safeWarning
        'Web byte conversion rejects before reader with a fixed safe error'=($webError -ceq 'PUBLIC_COMMAND_UI_PARAMETER_INVALID: ExportBytes')
        'Singleton structured arrays preserve whole values and reject byte overflow'=($singleByte.Count -eq 1 -and $singleByte[0] -eq 65 -and $singleString.Count -eq 1 -and $singleString[0] -ceq 'complete-value' -and $overflowRejected)
    }
}
foreach($name in $byteEvidence.Keys){Add-CheckResult $name ([bool]$byteEvidence[$name])}

$membershipWebEvidence=& $module {
    $saved=@{}
    foreach($name in @('Get-LabPublicCommandConsoleCatalog','Get-LabPublicCommandWebCatalog','Get-LabPublicCommandParameterDescriptor','Get-LabPublicCommandExecutionDescriptors','Add-SqlServerLabEnvironmentGroupMember','Remove-SqlServerLabEnvironmentGroupMember')){
        $saved[$name]=(Get-Command $name -ErrorAction SilentlyContinue).ScriptBlock
    }
    $script:membershipCommand='Add-SqlServerLabEnvironmentGroupMember'
    $script:membershipReceiptMode='VALID'
    Set-Item Function:script:Add-SqlServerLabEnvironmentGroupMember -Value {
        param([string]$GroupId,[string]$RunId)
        [pscustomobject]@{Status='ADDED';GroupId=$(if($script:membershipReceiptMode -ceq 'MISMATCH'){'99999999-9999-4999-8999-999999999999'}else{$GroupId});Member=[pscustomobject]@{runId=$RunId;scopeId='PRIVATE_SCOPE_CANARY';connectionInfoSha256='PRIVATE_HASH_CANARY'}}
    }
    Set-Item Function:script:Remove-SqlServerLabEnvironmentGroupMember -Value {
        param([string]$GroupId,[string]$RunId)
        [pscustomobject]@{Status='REMOVED';GroupId=$GroupId;RunId=$RunId;scopeId='PRIVATE_SCOPE_CANARY';connectionInfoSha256='PRIVATE_HASH_CANARY'}
    }
    Set-Item Function:script:Get-LabPublicCommandConsoleCatalog -Value {
        $command=Get-Command $script:membershipCommand
        @([pscustomobject]@{Name=$script:membershipCommand;Command=$command;ParameterSets=@([pscustomobject]@{Name='Default';Metadata=$null})})
    }
    Set-Item Function:script:Get-LabPublicCommandWebCatalog -Value {@([pscustomobject]@{Name=$script:membershipCommand;RequiresConfirmation=$true})}
    Set-Item Function:script:Get-LabPublicCommandParameterDescriptor -Value {
        @(@('GroupId','RunId')|ForEach-Object {[pscustomobject]@{Name=$_;ParameterType=[string];Mandatory=$true;Attributes=@()}})
    }
    Set-Item Function:script:Get-LabPublicCommandExecutionDescriptors -Value {@()}
    try{
        $parameters=@{GroupId='11111111-2222-4333-8444-555555555555';RunId='33333333-4444-4555-8666-777777777777'}
        $added=Invoke-LabPublicCommandWebRequest -CommandName 'Add-SqlServerLabEnvironmentGroupMember' -ParameterSetName 'Default' -Parameters $parameters -Confirmed
        $addedJson=$added|ConvertTo-Json -Depth 10 -Compress
        $script:membershipCommand='Remove-SqlServerLabEnvironmentGroupMember'
        $removed=Invoke-LabPublicCommandWebRequest -CommandName 'Remove-SqlServerLabEnvironmentGroupMember' -ParameterSetName 'Default' -Parameters $parameters -Confirmed
        $removedJson=$removed|ConvertTo-Json -Depth 10 -Compress
        $script:membershipCommand='Add-SqlServerLabEnvironmentGroupMember';$script:membershipReceiptMode='MISMATCH'
        $invalidCode=''
        try{$null=Invoke-LabPublicCommandWebRequest -CommandName $script:membershipCommand -ParameterSetName 'Default' -Parameters $parameters -Confirmed}catch{$invalidCode=$_.Exception.Message}
        [ordered]@{
            'Actual web-command receipt projects Add to fixed public fields' = ($added.Result.Count -eq 1 -and $added.Result[0].Status -ceq 'ADDED' -and $added.Result[0].GroupId -ceq $parameters.GroupId -and $added.Result[0].RunId -ceq $parameters.RunId)
            'Actual web-command receipt omits private Add member bindings' = ($addedJson -notmatch 'scopeId|connectionInfoSha256|PRIVATE_SCOPE_CANARY|PRIVATE_HASH_CANARY')
            'Actual web-command receipt projects Remove to the same fixed fields' = ($removed.Result.Count -eq 1 -and $removed.Result[0].Status -ceq 'REMOVED' -and $removed.Result[0].GroupId -ceq $parameters.GroupId -and $removed.Result[0].RunId -ceq $parameters.RunId)
            'Actual web-command receipt omits unexpected Remove fields' = ($removedJson -notmatch 'scopeId|connectionInfoSha256|PRIVATE_SCOPE_CANARY|PRIVATE_HASH_CANARY')
            'Mismatched membership receipt fails closed without reflecting private data' = ($invalidCode -ceq 'PUBLIC_COMMAND_UI_RESULT_INVALID' -and $invalidCode -notmatch 'PRIVATE_')
        }
    }finally{
        foreach($name in $saved.Keys){if($saved[$name]){Set-Item ('Function:script:'+$name) -Value $saved[$name]}}
        Remove-Variable membershipCommand,membershipReceiptMode -Scope Script -ErrorAction SilentlyContinue
    }
}
foreach($name in $membershipWebEvidence.Keys){Add-CheckResult $name ([bool]$membershipWebEvidence[$name])}
