#Requires -Version 7.2

Describe 'Privacy-Scanner: Runtime-Isolation und Git-Index' {
    BeforeAll {
        $sourceRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $fixtureRoot=Join-Path $TestDrive 'repository'
        $null=New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'Tests/Static') -Force
        $null=New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'Tests/Common') -Force
        Copy-Item -LiteralPath (Join-Path $sourceRoot 'Tests/Static/Invoke-PrivacyScannerChecks.ps1') -Destination (Join-Path $fixtureRoot 'Tests/Static')
        Copy-Item -LiteralPath (Join-Path $sourceRoot 'Tests/Common/CheckResult.ps1') -Destination (Join-Path $fixtureRoot 'Tests/Common')
        $gitPath=(Get-Command git -ErrorAction Stop).Source
        $pwshPath=(Get-Command pwsh -ErrorAction Stop).Source
        & $gitPath -C $fixtureRoot init --quiet
        if($LASTEXITCODE -ne 0){throw 'Synthetic Git fixture failed'}
        @('.runtime/','.state/','.secrets/','.artifacts/','.cache/','.local/') | Set-Content -LiteralPath (Join-Path $fixtureRoot '.gitignore')
        function Invoke-FixturePrivacy {
            $output=& $pwshPath -NoLogo -NoProfile -File (Join-Path $fixtureRoot 'Tests/Static/Invoke-PrivacyScannerChecks.ps1') 2>&1
            [pscustomobject]@{ExitCode=$LASTEXITCODE;Text=($output -join "`n")}
        }
    }

    It 'ignoriert fluechtige Secretdateien in den sechs lokalen Runtimewurzeln' {
        foreach($name in @('.runtime','.state','.secrets','.artifacts','.cache','.local')){
            $directory=Join-Path $fixtureRoot $name
            $null=New-Item -ItemType Directory -Path $directory -Force
            'SYNTHETIC_ONLY' | Set-Content -LiteralPath (Join-Path $directory 'temporary.secret')
        }
        $result=Invoke-FixturePrivacy
        if($result.ExitCode -ne 0){throw 'Ignorierter Runtime-State beeinflusst den Scanner'}
    }

    It 'erkennt eine Secretdatei im aktiven Quellumfang weiterhin' {
        $path=Join-Path $fixtureRoot 'active.secret'
        try {
            'SYNTHETIC_ONLY' | Set-Content -LiteralPath $path
            if((Invoke-FixturePrivacy).ExitCode -ne 1){throw 'Synthetische Secretdatei wurde nicht erkannt'}
        }
        finally {Remove-Item -LiteralPath $path -Force}
    }

    It 'erkennt eine trotz Runtimeausschluss im Git-Index eingetragene Secretdatei' {
        & $gitPath -C $fixtureRoot add --force -- '.artifacts/temporary.secret'
        if($LASTEXITCODE -ne 0){throw 'Synthetic index fixture failed'}
        try {if((Invoke-FixturePrivacy).ExitCode -ne 1){throw 'Synthetische Secretdatei wurde nicht erkannt'}}
        finally {
            & $gitPath -C $fixtureRoot rm --cached --quiet -- '.artifacts/temporary.secret'
            if($LASTEXITCODE -ne 0){throw 'Synthetic index cleanup failed'}
        }
    }

    It 'erkennt auch unter Linux eine versteckte Env-Datei im aktiven Umfang' {
        $path=Join-Path $fixtureRoot '.env'
        try {
            'SYNTHETIC_ONLY' | Set-Content -LiteralPath $path
            if((Invoke-FixturePrivacy).ExitCode -ne 1){throw 'Versteckte Env-Datei wurde nicht erkannt'}
        }
        finally {Remove-Item -LiteralPath $path -Force}
    }

    It 'behandelt aehnliche Verzeichnisnamen nicht als Runtimeausschluss' {
        $directory=Join-Path $fixtureRoot 'x.artifacts'
        $null=New-Item -ItemType Directory -Path $directory
        $path=Join-Path $directory 'temporary.secret'
        try {
            'SYNTHETIC_ONLY' | Set-Content -LiteralPath $path
            if((Invoke-FixturePrivacy).ExitCode -ne 1){throw 'Synthetische Secretdatei wurde nicht erkannt'}
        }
        finally {Remove-Item -LiteralPath $path -Force}
    }
}
