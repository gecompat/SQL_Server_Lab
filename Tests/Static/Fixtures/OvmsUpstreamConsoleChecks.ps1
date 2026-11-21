param([Parameter(Mandatory)]$Module)

$ErrorActionPreference = 'Stop'
& $Module {
    $originalProbe = ${function:Invoke-LabAiOvmsUpstreamProbe}
    $script:guidedOvmsCalls = [Collections.Generic.List[object]]::new()
    try {
        function script:Invoke-LabAiOvmsUpstreamProbe {
            param($Location, $RuntimeModel, $Dimension, $TimeoutSeconds)
            $null = Resolve-LabAiOvmsUpstreamLocation -Location $Location
            $script:guidedOvmsCalls.Add(@($Location, $RuntimeModel, $Dimension, $TimeoutSeconds))
            [pscustomobject]@{Status='UPSTREAM_VERIFIED'; Dimension=$Dimension; DurationMilliseconds=2}
        }
        function Select-LabConsoleDataItem { param($ScreenId, $Title, $Items) $Items[1].Data }
        $inputs = [Collections.Generic.Queue[string]]::new()
        function Read-LabConsoleTextInput { param($Prompt, $Default) [pscustomobject]@{Status='Confirmed'; Value=$inputs.Dequeue()} }
        $decisions = [Collections.Generic.Queue[bool]]::new()
        function Read-LabConfirm { param($Prompt, $Default) if ($Default) { throw 'UNSAFE_DEFAULT' }; $decisions.Dequeue() }
        function Write-LabError { param($Message) if ($Message -notmatch 'angegebenen Bereich') { throw $Message } }
        function Wait-LabConsoleAcknowledgement { $null }
        foreach ($inputValue in @('1023', '9000', '768', '30', 'example-model', '9000', '768', '30', 'example-model')) {
            $inputs.Enqueue($inputValue)
        }
        $decisions.Enqueue($false); $decisions.Enqueue($true)
        Invoke-LabMenuAction -ActionName OvmsUpstream
        if ($script:guidedOvmsCalls.Count -ne 0) { throw 'DECLINED_OVMS_PROBE_EXECUTED' }
        Invoke-LabMenuAction -ActionName OvmsUpstream
        if ($script:guidedOvmsCalls.Count -ne 1 -or ($script:guidedOvmsCalls[0] -join '|') -ne 'http://[::1]:9000/v3/embeddings|example-model|768|30') { throw 'GUIDED_OVMS_BINDING_INVALID' }
        $command = Get-LabPublicCommandWebCatalog | Where-Object Name -ceq 'Test-SqlServerLabOvmsUpstreamEndpoint'
        $receipt = Invoke-LabPublicCommandWebRequest -CommandName $command.Name -ParameterSetName $command.ParameterSets[0].Name -Parameters @{
            Location='http://127.0.0.1:9000/v3/embeddings'; RuntimeModel='example-model'; Dimension='768'; TimeoutSeconds='30'
        } -Confirmed
        if ($script:guidedOvmsCalls.Count -ne 2 -or $receipt.Result[0].Status -ne 'UPSTREAM_VERIFIED') { throw 'OVMS_WEB_CATALOG_MAPPING_FAILED' }
        Write-Host 'PASS: Geführte OVMS-Prüfung bindet eine numerische Loopback-Adresse und erfordert explizite Bestätigung.'
    }
    finally {
        Set-Item Function:script:Invoke-LabAiOvmsUpstreamProbe $originalProbe
        Remove-Variable -Name guidedOvmsCalls -Scope Script
    }
}
