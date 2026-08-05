<#
.SYNOPSIS
    Fuehrt eine explizite, UI-taugliche Workflow-Aktion aus.
.DESCRIPTION
    Der Befehl ist der schmale, nicht interaktive Adapter fuer die lokale
    Workflow-Oberflaeche. Gastpasswoerter dienen nur dem unmittelbaren Aufruf
    und werden weder in Build-State noch Log-Ausgabe gespeichert.
.PARAMETER Action
    Eindeutige, zulässige Workflow-Aktion.
.PARAMETER BuildId
    Build-ID des vorhandenen Windows- oder SQL-Image-Builds.
.PARAMETER MediaRoot
    Externer Media Root für eine neue Windows- oder SQL-Vorbereitung.
.PARAMETER OperatingSystemId
    Windows-Server-Version eines neu anzulegenden Builds.
.PARAMETER WindowsEdition
    Gewünschte Windows-Evaluation-Edition für einen neuen Build.
.PARAMETER InstallationType
    Core oder Desktop Experience für einen neuen Build.
.PARAMETER SqlVersion
    Zielversion für ein neues SQL-Prepared-Image.
.PARAMETER SqlEdition
    Edition des SQL-Installationsmediums.
.PARAMETER Provider
    Docker oder Podman für eine neue Container-Lab-Umgebung.
.PARAMETER Profile
    Ressourcenprofil der neuen Container-Lab-Umgebung.
.PARAMETER InstanceId
    Sprechender Instanzname innerhalb einer Container-Lab-Umgebung.
.PARAMETER SaPassword
    Nicht persistiertes SA-Passwort für Containeraktionen.
.PARAMETER HostName
    SQL-Host für Datenbank- oder Skriptaktionen; Standard ist 127.0.0.1.
.PARAMETER Port
    Lokaler SQL-Port für Datenbank- oder Skriptaktionen.
.PARAMETER DatabaseName
    Name einer neu anzulegenden Datenbank.
.PARAMETER ScriptPath
    Absoluter Pfad zum auszuführenden SQL-Skript.
.PARAMETER Database
    Zieldatenbank einer Skriptausführung.
.PARAMETER GuestUserName
    Lokaler Administratorname im Gast für PowerShell Direct.
.PARAMETER GuestPassword
    Nicht persistiertes Gastpasswort für den unmittelbaren PowerShell-Direct-Aufruf.
.PARAMETER EvaluationExpiresAt
    Ablaufdatum, das beim Veröffentlichen eines Evaluation-Images gespeichert wird.
.PARAMETER MemoryStartupMB
    Startspeicher der neu anzulegenden VM in MB.
.PARAMETER ProcessorCount
    Anzahl virtueller Prozessoren der neu anzulegenden VM.
.PARAMETER OsDiskSizeGB
    Größe der Systemdisk einer neu anzulegenden VM in GB.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Liefert die Aktion, den
    Abschlusszeitpunkt und das Ergebnis des bestehenden Fachbefehls.
.EXAMPLE
    Invoke-SqlServerLabWorkflowAction -Action NewSqlBuild -MediaRoot D:\Lab_Base -SqlVersion 2022
#>
function Invoke-SqlServerLabWorkflowAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'Refresh',
            'NewContainerLab', 'StartContainerLab', 'StopContainerLab', 'RestartContainerLab', 'RemoveContainerLab',
            'CreateContainerDatabase', 'ExecuteContainerScript',
            'NewWindowsBuild', 'OpenWindowsConsole', 'ConfirmWindowsInstall', 'GeneralizeWindowsBuild', 'PublishWindowsBuild',
            'NewSqlBuild', 'OpenSqlConsole', 'PrepareSqlImage', 'ResumeSqlImage', 'PublishSqlImage'
        )]
        [string]$Action,
        [string]$BuildId,
        [string]$MediaRoot,
        [ValidateSet('windows-server-2022', 'windows-server-2025')][string]$OperatingSystemId = 'windows-server-2025',
        [ValidateSet('standard-evaluation', 'datacenter-evaluation')][string]$WindowsEdition = 'standard-evaluation',
        [ValidateSet('core', 'desktop-experience')][string]$InstallationType = 'desktop-experience',
        [ValidateSet('2019', '2022', '2025')][string]$SqlVersion = '2022',
        [ValidateSet('Eval', 'Enterprise', 'Standard')][string]$SqlEdition = 'Eval',
        [ValidateSet('docker', 'podman')][string]$Provider = 'docker',
        [ValidateSet('compact', 'standard', 'performance')][string]$Profile = 'standard',
        [string]$InstanceId = 'primary',
        [SecureString]$SaPassword,
        [string]$HostName = '127.0.0.1',
        [int]$Port,
        [string]$DatabaseName,
        [string]$ScriptPath,
        [string]$Database = 'master',
        [string]$GuestUserName = 'Administrator',
        [SecureString]$GuestPassword,
        [Nullable[datetime]]$EvaluationExpiresAt,
        [ValidateRange(2, 1048576)][int]$MemoryStartupMB = 4096,
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [ValidateRange(32, 1048576)][int]$OsDiskSizeGB = 80
    )

    if ($Action -eq 'Refresh') {
        return [PSCustomObject]@{
            Action = $Action
            CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
            Result = Get-SqlServerLabWorkflow
        }
    }

    $containerActions = @(
        'NewContainerLab', 'StartContainerLab', 'StopContainerLab', 'RestartContainerLab', 'RemoveContainerLab',
        'CreateContainerDatabase', 'ExecuteContainerScript'
    )
    if ($Action -notin $containerActions) {
        if (-not $IsWindows) { throw 'HYPERV_WORKFLOW_WINDOWS_HOST_REQUIRED' }
        $availability = Test-HyperVAvailable
        if (-not $availability.Available) { throw "HYPERV_WORKFLOW_UNAVAILABLE: $($availability.Message)" }
    }

    $credential = $null
    $credentialRequired = $Action -in @('ConfirmWindowsInstall', 'PrepareSqlImage')
    if ($Action -eq 'GeneralizeWindowsBuild') {
        $existingWindowsBuild = Get-HyperVImageBuildPlan -BuildId $BuildId
        $credentialRequired = $existingWindowsBuild -and [string]$existingWindowsBuild.state -eq 'MANUAL_ACTION_REQUIRED'
    }
    if ($credentialRequired) {
        if (-not $GuestPassword) { throw 'HYPERV_WORKFLOW_GUEST_PASSWORD_REQUIRED' }
        $credential = [PSCredential]::new($GuestUserName, $GuestPassword)
    }
    if ($Action -in @('NewContainerLab', 'CreateContainerDatabase', 'ExecuteContainerScript') -and -not $SaPassword) {
        throw 'CONTAINER_WORKFLOW_SA_PASSWORD_REQUIRED'
    }

    if ($Action -in @('NewWindowsBuild', 'NewSqlBuild')) {
        if (-not $MediaRoot) { $MediaRoot = Get-LabMediaRootDefault }
        if (-not $MediaRoot) { throw 'HYPERV_WORKFLOW_MEDIA_ROOT_REQUIRED' }
        $MediaRoot = Set-LabMediaRootDefault -MediaRoot $MediaRoot
    }

    $result = switch ($Action) {
        'NewContainerLab' {
            New-SqlServerLab -Version $SqlVersion -Provider $Provider -Profile $Profile -InstanceId $InstanceId -SaPassword $SaPassword
        }
        'StartContainerLab' { Start-SqlServerLab -RunId $BuildId }
        'StopContainerLab' { Stop-SqlServerLab -RunId $BuildId -Force -Confirm:$false }
        'RestartContainerLab' { Restart-SqlServerLab -RunId $BuildId -Force -Confirm:$false }
        'RemoveContainerLab' { Remove-SqlServerLab -RunId $BuildId -Force -Confirm:$false }
        'CreateContainerDatabase' {
            if ($Port -lt 1 -or -not $DatabaseName) { throw 'CONTAINER_WORKFLOW_DATABASE_TARGET_REQUIRED' }
            New-SqlServerLabDatabase -HostName $HostName -Port $Port -SaPassword $SaPassword -DatabaseName $DatabaseName
        }
        'ExecuteContainerScript' {
            if ($Port -lt 1 -or -not $ScriptPath) { throw 'CONTAINER_WORKFLOW_SCRIPT_TARGET_REQUIRED' }
            Invoke-SqlServerLabScript -ScriptPath $ScriptPath -HostName $HostName -Port $Port -SaPassword $SaPassword -Database $Database
        }
        'NewWindowsBuild' {
            Initialize-HyperVWindowsImageBuild -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -Edition $WindowsEdition -InstallationType $InstallationType -LicenseType evaluation -MemoryStartupBytes ($MemoryStartupMB * 1MB) -ProcessorCount $ProcessorCount -OsDiskSizeBytes ($OsDiskSizeGB * 1GB)
        }
        'OpenWindowsConsole' {
            $build = Get-HyperVImageBuildPlan -BuildId $BuildId
            if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
            if ((Get-VM -Name $build.builder.vmName -ErrorAction Stop).State -eq 'Off') {
                $null = Start-HyperVWindowsImageBuildVM -BuildId $BuildId
            }
            Start-Process -FilePath vmconnect.exe -ArgumentList ([string]$build.builder.vmName)
            [PSCustomObject]@{ VMName = [string]$build.builder.vmName; Console = 'VMConnect' }
        }
        'ConfirmWindowsInstall' { Confirm-HyperVWindowsImageInstallation -BuildId $BuildId -Credential $credential }
        'GeneralizeWindowsBuild' { Invoke-HyperVWindowsImageGeneralization -BuildId $BuildId -Credential $credential }
        'PublishWindowsBuild' { Publish-HyperVWindowsImageBuild -BuildId $BuildId -EvaluationExpiresAt $EvaluationExpiresAt }
        'NewSqlBuild' {
            if ($OperatingSystemId -ne 'windows-server-2025') { throw 'HYPERV_WORKFLOW_SQL_PREPARED_REQUIRES_WINDOWS_SERVER_2025' }
            Initialize-HyperVSqlFreshPreparedImageBuild -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -WindowsEdition $WindowsEdition -InstallationType $InstallationType -SqlVersion $SqlVersion -MediaEdition $SqlEdition -MemoryStartupBytes ($MemoryStartupMB * 1MB) -ProcessorCount $ProcessorCount -OsDiskSizeBytes ($OsDiskSizeGB * 1GB)
        }
        'OpenSqlConsole' {
            $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId
            if (-not $build) { throw 'HYPERV_SQL_IMAGE_BUILD_NOT_FOUND' }
            if ((Get-VM -Name $build.builder.vmName -ErrorAction Stop).State -eq 'Off') {
                $null = Start-HyperVSqlImageBuildVM -BuildId $BuildId
            }
            Start-Process -FilePath vmconnect.exe -ArgumentList ([string]$build.builder.vmName)
            [PSCustomObject]@{ VMName = [string]$build.builder.vmName; Console = 'VMConnect' }
        }
        'PrepareSqlImage' { Invoke-HyperVSqlPrepareAndGeneralize -BuildId $BuildId -Credential $credential }
        'ResumeSqlImage' { Resume-HyperVSqlPreparedImageGeneralization -BuildId $BuildId }
        'PublishSqlImage' { Publish-HyperVSqlPreparedImageBuild -BuildId $BuildId -EvaluationExpiresAt $EvaluationExpiresAt }
    }

    [PSCustomObject]@{
        Action = $Action
        CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
        Result = $result
    }
}
