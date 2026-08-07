function Get-Lab7ZipExecutable {
    <#
    .SYNOPSIS
        Findet eine lokal installierte 7-Zip-Kommandozeile ohne sie zu starten.
    #>
    [CmdletBinding()]
    param()

    foreach ($commandName in @('7z', '7zz')) {
        $command = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and $command.Path -and (Test-Path -LiteralPath $command.Path -PathType Leaf)) {
            return [PSCustomObject]@{ Path = $command.Path; Source = 'PATH' }
        }
    }

    $candidatePaths = @(
        (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) '7-Zip\7z.exe'),
        (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)) '7-Zip\7z.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\7-Zip\7z.exe')
    ) | Where-Object { $_ }
    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [PSCustomObject]@{ Path = $candidate; Source = 'Standardpfad' }
        }
    }
    return $null
}
