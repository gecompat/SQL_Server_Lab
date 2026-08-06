function Initialize-LabVmConnectWindowApi {
    [CmdletBinding()]
    param()

    if ('SqlServerLabVmConnectWindow' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SqlServerLabVmConnectWindow {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);
}
'@ -ErrorAction Stop
}

function Show-LabVmConnectWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)

    $deadline = [datetime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 150
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne 0) {
            Initialize-LabVmConnectWindowApi
            $null = [SqlServerLabVmConnectWindow]::ShowWindowAsync($Process.MainWindowHandle, 9)
            # SetForegroundWindow allein kann aus einem ThreadJob von Windows
            # abgewiesen werden. Ein kurzer Topmost-Uebergang macht das gerade
            # angeforderte VMConnect-Fenster sichtbar, ohne es oben festzuhalten.
            $showFlags = [uint32]0x0043 # SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW
            $null = [SqlServerLabVmConnectWindow]::SetWindowPos($Process.MainWindowHandle, [intptr](-1), 0, 0, 0, 0, $showFlags)
            $null = [SqlServerLabVmConnectWindow]::SetWindowPos($Process.MainWindowHandle, [intptr](-2), 0, 0, 0, 0, $showFlags)
            $null = [SqlServerLabVmConnectWindow]::BringWindowToTop($Process.MainWindowHandle)
            return [bool][SqlServerLabVmConnectWindow]::SetForegroundWindow($Process.MainWindowHandle)
        }
    } while ([datetime]::UtcNow -lt $deadline -and -not $Process.HasExited)
    return $false
}

<#
.SYNOPSIS
    Öffnet VMConnect für eine lokale, verwaltete Hyper-V-VM und bringt dessen
    Fenster in den Vordergrund.
#>
function Start-LabVmConnect {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VMName)

    if (-not $IsWindows) { throw 'HYPERV_VMCONNECT_WINDOWS_HOST_REQUIRED' }
    $vmConnect = Join-Path $env:SystemRoot 'System32\vmconnect.exe'
    if (-not (Test-Path -LiteralPath $vmConnect -PathType Leaf)) { throw "HYPERV_VMCONNECT_NOT_FOUND: $vmConnect" }
    $hostName = if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { 'localhost' } else { $env:COMPUTERNAME }
    $existing = @(Get-Process -Name vmconnect -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -match [regex]::Escape($VMName)
    } | Sort-Object StartTime -Descending | Select-Object -First 1)
    $reused = $existing.Count -eq 1
    $process = if ($reused) { $existing[0] } else {
        Start-Process -FilePath $vmConnect -ArgumentList @($hostName, $VMName) -WindowStyle Normal -PassThru -ErrorAction Stop
    }
    $focused = Show-LabVmConnectWindow -Process $process
    return [PSCustomObject]@{ VMName = $VMName; HostName = $hostName; ProcessId = $process.Id; Reused = $reused; Focused = $focused; Console = 'VMConnect' }
}
