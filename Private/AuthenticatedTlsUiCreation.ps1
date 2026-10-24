# A browser selects references, never a filesystem root. All target custody is
# server-private and scoped to one authenticated UI start.
function Get-LabTlsUiCreationRequest {
    param([string]$Body)
    try {
        if($Body.Length -gt 4096){throw 'INVALID'}
        $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=2
        $doc=[Text.Json.JsonDocument]::Parse($Body,$options)
        try {
            if($doc.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'INVALID'}
            $names=@('RequestId','Provider','Version','Profile','LabName','SaPassword','TlsCandidateId','TlsControllerId','TlsLocationId')
            $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $p=@{}
            foreach($item in $doc.RootElement.EnumerateObject()){
                if($item.Name -cnotin $names -or -not $seen.Add($item.Name) -or $item.Value.ValueKind -ne [Text.Json.JsonValueKind]::String){throw 'INVALID'}
                $p[$item.Name]=$item.Value.GetString()
            }
            if($p.Count -ne $names.Count -or $p.RequestId -cnotmatch '\A[a-f0-9]{32}\z' -or
                $p.Provider -cnotin @('docker','podman') -or $p.Version -cne '2025-CU9' -or
                $p.Profile -cnotin @('compact','standard','performance') -or
                $p.LabName -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9 _-]{0,63}\z'){throw 'INVALID'}
            foreach($key in @('TlsCandidateId','TlsControllerId','TlsLocationId')){
                if(-not (Test-LabTlsRequestReference $p[$key])){throw 'INVALID'}
            }
            Assert-LabSaPasswordWorkflowPreflight -Action NewContainerLab -Parameters @{Provider=$p.Provider;SqlVersion=$p.Version;SaPassword=$p.SaPassword}
            return $p
        }finally{$doc.Dispose()}
    }catch{throw 'TLS_CREATION_REQUEST_REJECTED'}
}

function Invoke-LabTlsUiCreation {
    param([hashtable]$Parameters,[hashtable]$Ticket,[string]$DataRoot)
    $secure=$null
    try {
        Assert-LabTlsCaCandidateCapability
        $sid=(Get-LabTlsWindowsProcessFacts).UserSid
        $data=Assert-LabDiagnosticPath ([IO.Path]::GetFullPath($DataRoot))
        $secure=[SecureString]::new()
        foreach($character in $Parameters.SaPassword.ToCharArray()){$secure.AppendChar($character)}
        $secure.MakeReadOnly()
        $createParameters=@{TrustServerCertificate=$false;Provider=$Parameters.Provider;Version=$Parameters.Version;Profile=$Parameters.Profile;
            InstanceId='primary';AutoStart='off';LabName=$Parameters.LabName;SaPassword=$secure;NonInteractive=$true;DataRoot=$data;
            TlsCandidateId=$Parameters.TlsCandidateId;TlsControllerId=$Parameters.TlsControllerId;TlsLocationId=$Parameters.TlsLocationId}
        $observer={
            param($audit,$state)
            $expected=[IO.Path]::GetFullPath((Join-Path $data ('State/authenticated-tls-labs/'+$audit)))
            if(-not (Test-LabTlsRequestReference $audit) -or $state -cne $expected -or $Ticket.StateRoot -or (Test-Path -LiteralPath $state)){throw 'TLS_CREATION_ALLOCATION_INVALID'}
            $receiptRoot=Join-Path $data 'State/authenticated-tls-ui-tickets'
            Initialize-LabTlsCaPrivateDirectory $receiptRoot $sid
            $receipt=[pscustomobject]@{ContractVersion='SqlServerLab.UiTlsAllocation/0.1';TicketId=$Ticket.Id;SessionId=$Ticket.SessionId;
                UserSid=$sid;AuditId=$audit;StateRoot=$state;Provider=$Parameters.Provider;RequestId=$Ticket.RequestId;AtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
            Write-LabTlsCaPrivateFile (Join-Path $receiptRoot ($Ticket.Id+'.json')) $sid (ConvertTo-LabTlsRegistryWriterBytes $receipt)
            $Ticket.AuditId=$audit;$Ticket.StateRoot=$state
        }
        $run=New-LabAuthenticatedTlsEnvironment -Parameters $createParameters -AllocationObserver $observer
        if(-not $Ticket.StateRoot -or $run.StateRoot -cne $Ticket.StateRoot -or
            $run.RunId -isnot [string] -or $run.RunId -cnotmatch '^[a-f0-9-]{36}$'){throw 'TLS_CREATION_RESULT_INVALID'}
        $own=Get-LabTlsOwnBinding -StateRoot $Ticket.StateRoot -RunId $run.RunId -InstanceId primary
        if($own.Record.AuditId -cne $Ticket.AuditId -or (Get-LabTlsBindingProvider $own.Record) -cne $Parameters.Provider){throw 'TLS_CREATION_RESULT_INVALID'}
        $Ticket.RunId=$run.RunId;$Ticket.Port=[int]$own.Record.Port;$Ticket.Status='COMPLETE';$Ticket.RunState='RUNNING'
    }catch{
        # The original canonical intent/compensation remains authoritative.
        # Never retry creation or scan other audit roots after an unknown result.
        $Ticket.Status=if($Ticket.StateRoot){'UNCONFIRMED'}else{'REJECTED'}
    }finally{if($secure){$secure.Dispose()};$Parameters.SaPassword=$null}
}

function Get-LabTlsUiCreationTarget {
    param([hashtable]$Ticket)
    if($Ticket.Status -cne 'COMPLETE' -or -not $Ticket.StateRoot -or -not $Ticket.RunId){throw 'TLS_CREATION_TARGET_UNCONFIRMED'}
    $root=Assert-LabDiagnosticPath ([IO.Path]::GetFullPath($Ticket.StateRoot))
    $null=Assert-LabTlsLabRoot $root
    $sid=(Get-LabTlsWindowsProcessFacts).UserSid
    $record=Read-LabTlsLabRecord (Read-LabTlsCaPrivateFile (Join-Path $root 'authenticated-tls-lab.json') $sid 32768)
    $null=Get-LabTlsRecordedRuntimePin $record $root
    $expected=[IO.Path]::GetFullPath((Join-Path $record.DataRoot ('State/authenticated-tls-labs/'+$record.AuditId)))
    if($record.AuditId -cne $Ticket.AuditId -or $record.RunId -cne $Ticket.RunId -or $record.InstanceId -cne 'primary' -or
        (Get-LabTlsBindingProvider $record) -cne $Ticket.Provider -or $expected -cne $root){throw 'TLS_CREATION_TARGET_CHANGED'}
    $policy=Get-LabOwnedHostRunPolicy -RunId $record.RunId -StateRoot $root
    if(-not $policy -or $policy.PolicyId -cne $record.RuntimeBinding.PolicyId){throw 'TLS_CREATION_POLICY_CHANGED'}
    [pscustomobject]@{StateRoot=$root;RunId=$record.RunId;Provider=$Ticket.Provider;InstanceId='primary'}
}

function Invoke-LabTlsUiTargetAction {
    param([hashtable]$Ticket,[ValidateSet('Live','Rebind','Start','Stop','Remove')][string]$Action)
    $target=Get-LabTlsUiCreationTarget -Ticket $Ticket
    switch($Action){
        'Live' {return Test-SqlServerLabTlsQualification -RunId $target.RunId -InstanceId primary -StateRoot $target.StateRoot}
        'Rebind' {$null=Update-SqlServerLabTlsBinding -RunId $target.RunId -InstanceId primary -StateRoot $target.StateRoot -Confirm:$false;$Ticket.RunState='RUNNING';return}
        'Start' {
            $result=Start-SqlServerLab -RunId $target.RunId -StateRoot $target.StateRoot
            if($result.Status -isnot [string] -or $result.Status -cne 'RUNNING' -or $result.Errors -gt 0){throw 'TLS_CREATION_START_UNCONFIRMED'}
            $Ticket.RunState='RUNNING';return
        }
        'Stop' {
            $result=Stop-SqlServerLab -RunId $target.RunId -StateRoot $target.StateRoot -Force -SkipHostMemoryRelease -Confirm:$false
            if($result.Status -isnot [string] -or $result.Status -cne 'STOPPED' -or $result.Errors -gt 0){throw 'TLS_CREATION_STOP_UNCONFIRMED'}
            $Ticket.RunState='STOPPED';return
        }
        'Remove' {
            $result=Remove-SqlServerLab -RunId $target.RunId -StateRoot $target.StateRoot -Force -Confirm:$false
            if($result.Status -cne 'REMOVED'){throw 'TLS_CREATION_CLEANUP_UNCONFIRMED'}
            $Ticket.RunState='REMOVED'
        }
    }
}
