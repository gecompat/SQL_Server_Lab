#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$skillsRoot=Join-Path $repoRoot '.agents/skills'
$manifest=Import-PowerShellDataFile (Join-Path $repoRoot 'SqlServerLab.psd1')
$names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Read-RepositorySkillHeader {
    param([string]$Text)
    $header=[regex]::Match($Text,'\A---\r?\n(?<fields>.*?)\r?\n---(?:\r?\n|\z)',[Text.RegularExpressions.RegexOptions]::Singleline)
    if(-not $header.Success){throw 'SKILL_FRONTMATTER_REQUIRED'}
    # Die drei Repository-Skills verwenden nur einfache YAML-Strings ohne
    # Tags, Aliase, Mehrzeilenwerte oder optionale Metadaten.
    $values=@{}
    foreach($line in ($header.Groups['fields'].Value -split '\r?\n')){
        if($line -notmatch '^(name|description): ([^\r\n]+)$'){throw 'SKILL_FRONTMATTER_SHAPE_INVALID'}
        $key=$Matches[1];$value=$Matches[2]
        if($values.ContainsKey($key)){throw 'SKILL_FRONTMATTER_DUPLICATE_KEY'}
        if($value -match '[:#\[\]{}&*!|>''"%@`]' -or $value.Trim() -ne $value){throw 'SKILL_FRONTMATTER_PLAIN_STRING_REQUIRED'}
        $values[$key]=$value
    }
    if($values.Count -ne 2 -or $values.name -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $values.name.Length -ge 64 -or $values.description.Length -lt 20){throw 'SKILL_FRONTMATTER_VALUE_INVALID'}
    return $values
}

foreach($skill in @(Get-ChildItem -LiteralPath $skillsRoot -Filter SKILL.md -Recurse -File)){
    $text=Get-Content -LiteralPath $skill.FullName -Raw
    $header=Read-RepositorySkillHeader -Text $text
    if(-not $names.Add($header.name) -or $skill.Directory.Name -ne $header.name){throw 'SKILL_NAME_DUPLICATE_OR_DIRECTORY_MISMATCH'}
    foreach($link in [regex]::Matches($text,'\[[^\]]+\]\((?<target>[^)]+)\)')){
        $target=$link.Groups['target'].Value
        if($target -match '^https://'){continue}
        $resolved=[IO.Path]::GetFullPath((Join-Path $skill.Directory.FullName ($target -split '#')[0]))
        $boundary=[IO.Path]::GetFullPath($repoRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)){throw "SKILL_REFERENCE_INVALID: $($header.name)"}
    }
    foreach($command in [regex]::Matches($text,'(?<![\w-])[A-Z][a-z]+-SqlServerLab[A-Za-z]*(?![A-Za-z]|\.ps1)')){
        if($command.Value -notin @($manifest.FunctionsToExport)){throw "SKILL_COMMAND_NOT_EXPORTED: $($command.Value)"}
    }
    Write-Host "PASS: $($header.name) besitzt gueltige Metadaten, Referenzen und oeffentliche Befehle"
}
foreach($expected in @('sql-server-lab-readiness','sql-server-lab-validation','sql-server-lab-operate')){
    if(-not $names.Contains($expected)){throw "SKILL_REQUIRED: $expected"}
}
foreach($invalid in @(
    "---`nname: first`nname: second`ndescription: A sufficiently long description`n---`n",
    "---`nname: Invalid Name`ndescription: A sufficiently long description`n---`n",
    "---`nname: valid-name`ndescription: [invalid, yaml, shape]`n---`n"
)){
    $rejected=$false;try{$null=Read-RepositorySkillHeader -Text $invalid}catch{$rejected=$true}
    if(-not $rejected){throw 'SKILL_INVALID_HEADER_NOT_REJECTED'}
}
Write-Host 'PASS: Doppelte Schluessel, ungueltige Namen und Nicht-String-Frontmatter werden abgewiesen'
