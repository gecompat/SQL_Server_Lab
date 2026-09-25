# Shared pinned Ubuntu bootstrap; caller supplies its owned VM/disk/serial context.
function Assert-ScopedRuntimePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not $fullPath.StartsWith("$fullRoot\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "EXTERNAL_RUNTIME_CONTAINER_HYPERV_SCOPE_VIOLATION: $fullPath"
    }
}

function Send-ExternalRuntimeSerialLine {
    param(
        [Parameter(Mandatory)][IO.StreamWriter]$Writer,
        [Parameter(Mandatory)][string]$Value,
        [ValidateRange(20, 500)][int]$DelayMilliseconds = 100
    )
    foreach ($character in $Value.ToCharArray()) {
        $Writer.Write($character)
        Start-Sleep -Milliseconds $DelayMilliseconds
    }
    $Writer.Write("`r")
    Start-Sleep -Seconds 1
}

function Initialize-ExternalRuntimeNoCloudGuest {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new(
        '.',
        $serialPipeName,
        [IO.Pipes.PipeDirection]::InOut,
        [IO.Pipes.PipeOptions]::Asynchronous
    )
    $connectTask = $pipe.ConnectAsync()
    Start-VM -Name $vmName | Out-Null
    if (-not $connectTask.Wait(10000)) {
        throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_SERIAL_CONNECT_TIMEOUT'
    }

    try {
        $writer = [IO.StreamWriter]::new($pipe)
        $writer.AutoFlush = $true

        # Das gepinnte Azure-VHD priorisiert Azure/IMDS und beendet bei dessen
        # Fehlen die Datasource-Suche. Der hashgebundene Erstboot setzt deshalb
        # vor cloud-init ausschließlich NoCloud und startet danach normal neu.
        for ($index = 0; $index -lt 120; $index++) {
            $writer.Write([char]27)
            Start-Sleep -Milliseconds 25
        }
        Send-ExternalRuntimeSerialLine -Writer $writer -Value 'c'
        Send-ExternalRuntimeSerialLine -Writer $writer -Value 'search --no-floppy --fs-uuid --set=root 7f4dba93-74c0-4e0e-b8a8-854571dc965e'
        Send-ExternalRuntimeSerialLine -Writer $writer -Value 'linux /boot/vmlinuz-6.8.0-1064-azure root=PARTUUID=446bbf5a-4a8b-4efb-8173-e738bcba8b93 rw console=tty1 console=ttyS0 earlyprintk=ttyS0 nvme_core.io_timeout=240 init=/bin/bash'
        Send-ExternalRuntimeSerialLine -Writer $writer -Value 'initrd /boot/initrd.img-6.8.0-1064-azure'
        Send-ExternalRuntimeSerialLine -Writer $writer -Value 'boot'

        $buffer = [byte[]]::new(8192)
        $serialTail = ''
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        $readTask = $null
        while ([DateTime]::UtcNow -lt $deadline -and $serialTail -notmatch 'root@\(none\):/#') {
            if (-not $readTask) { $readTask = $pipe.ReadAsync($buffer,0,$buffer.Length) }
            if ($readTask.Wait(1000)) {
                if ($readTask.Result -gt 0) {
                    $serialTail += [Text.Encoding]::ASCII.GetString($buffer,0,$readTask.Result)
                    if ($serialTail.Length -gt 32768) {
                        $serialTail = $serialTail.Substring($serialTail.Length - 32768)
                    }
                }
                $readTask = $null
            }
        }
        if ($serialTail -notmatch 'root@\(none\):/#') {
            throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_DIAGNOSTIC_SHELL_TIMEOUT'
        }

        Send-ExternalRuntimeSerialLine -Writer $writer -DelayMilliseconds 50 -Value "echo 'datasource_list: [ NoCloud ]' > /etc/cloud/cloud.cfg.d/99-sql-server-lab-nocloud.cfg; rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance; sync; /sbin/poweroff -f"
    }
    finally {
        $pipe.Dispose()
    }

    $shutdownDeadline = [DateTime]::UtcNow.AddSeconds(60)
    while ((Get-VM -Name $vmName).State -ne 'Off' -and [DateTime]::UtcNow -lt $shutdownDeadline) {
        Start-Sleep -Seconds 1
    }
    if ((Get-VM -Name $vmName).State -ne 'Off') {
        Stop-VM -Name $vmName -TurnOff -Force -Confirm:$false
    }
    Write-Host 'NoCloud-Datasource wurde im hashgebundenen Erstboot vorbereitet.' -ForegroundColor DarkCyan
    Start-VM -Name $vmName | Out-Null
}

function New-CidataIso {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not ('SqlServerLabImapiStreamCopy' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class SqlServerLabImapiStreamCopy
{
    public static void ToFile(object source, string path)
    {
        IStream stream = (IStream)source;
        byte[] buffer = new byte[65536];
        IntPtr bytesReadPointer = Marshal.AllocCoTaskMem(sizeof(int));
        try
        {
            using (FileStream file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                while (true)
                {
                    Marshal.WriteInt32(bytesReadPointer, 0);
                    stream.Read(buffer, buffer.Length, bytesReadPointer);
                    int bytesRead = Marshal.ReadInt32(bytesReadPointer);
                    if (bytesRead <= 0) break;
                    file.Write(buffer, 0, bytesRead);
                }
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(bytesReadPointer);
        }
    }
}
'@
    }

    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.FileSystemsToCreate = 3 # ISO 9660 + Joliet fuer NoCloud CIDATA
    $image.VolumeName = 'CIDATA'
    $image.Root.AddTree($SourceDirectory, $false)
    $result = $image.CreateResultImage()
    try {
        [SqlServerLabImapiStreamCopy]::ToFile($result.ImageStream, $DestinationPath)
    }
    finally {
        foreach ($comObject in @($result,$image)) {
            if ($comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
            }
        }
    }
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf) -or
        (Get-Item -LiteralPath $DestinationPath).Length -lt 32768) {
        throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_CIDATA_ISO_INVALID'
    }
    $mounted = $false
    try {
        Mount-DiskImage -ImagePath $DestinationPath -StorageType ISO -Access ReadOnly -PassThru | Out-Null
        $mounted = $true
        $volume = Get-DiskImage -ImagePath $DestinationPath | Get-Volume
        if (-not $volume.DriveLetter) { throw 'EXTERNAL_RUNTIME_CONTAINER_HYPERV_PROVISIONING_VOLUME_MISSING' }
        $entries = @(Get-ChildItem -LiteralPath "$($volume.DriveLetter):\" | ForEach-Object { $_.Name })
        foreach ($requiredEntry in @('user-data','meta-data')) {
            if ($entries -notcontains $requiredEntry) {
                throw "EXTERNAL_RUNTIME_CONTAINER_HYPERV_PROVISIONING_ENTRY_MISSING: $requiredEntry"
            }
        }
    }
    finally {
        if ($mounted) { Dismount-DiskImage -ImagePath $DestinationPath | Out-Null }
    }
}
