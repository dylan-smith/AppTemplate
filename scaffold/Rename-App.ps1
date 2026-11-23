<#
.SYNOPSIS
Renames the app in a copy of the template: file contents, file names and folder names.

.DESCRIPTION
Replaces the name in its three casings (AppTemplate, apptemplate, APPTEMPLATE) everywhere under -Path, skipping
.git, build output and binary files. New-App.ps1 calls this; run it by hand only to rename a copy yourself.

.EXAMPLE
./Rename-App.ps1 -Path E:\git\MyApp -To MyApp
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][ValidatePattern('^[A-Z][A-Za-z0-9]+$')][string]$To,
    [ValidatePattern('^[A-Z][A-Za-z0-9]+$')][string]$From = 'AppTemplate'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path $Path).Path
$skipDirs = '.git', 'node_modules', 'bin', 'obj', 'dist', 'TestResults', 'playwright-report', 'test-results'
$binaryExtensions = '.png', '.jpg', '.jpeg', '.gif', '.ico', '.woff', '.woff2', '.ttf', '.pdf', '.zip', '.bacpac'
$pairs = @(
    @{ From = $From; To = $To },
    @{ From = $From.ToLowerInvariant(); To = $To.ToLowerInvariant() },
    @{ From = $From.ToUpperInvariant(); To = $To.ToUpperInvariant() }
)
$utf8 = [System.Text.UTF8Encoding]::new($false)
$utf8WithBom = [System.Text.UTF8Encoding]::new($true)

function Get-Renamed([string]$text) {
    foreach ($pair in $pairs) {
        $text = $text.Replace($pair.From, $pair.To, [System.StringComparison]::Ordinal)
    }
    $text
}

function Test-Skipped([string]$fullName) {
    $relative = [System.IO.Path]::GetRelativePath($root, $fullName)
    foreach ($part in $relative.Split([System.IO.Path]::DirectorySeparatorChar)) {
        if ($skipDirs -contains $part) { return $true }
    }
    $false
}

$filesChanged = 0
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
    if ((Test-Skipped $file.FullName) -or ($binaryExtensions -contains $file.Extension.ToLowerInvariant())) { continue }
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $renamed = Get-Renamed $text
    if (-not [string]::Equals($renamed, $text, [System.StringComparison]::Ordinal)) {
        # Keep a byte order mark when the file had one, so the rename is the only change.
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $hadBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        [System.IO.File]::WriteAllText($file.FullName, $renamed, $hadBom ? $utf8WithBom : $utf8)
        $filesChanged++
    }
}

# Deepest paths first, so a folder is renamed after everything inside it.
$pathsRenamed = 0
$items = Get-ChildItem -LiteralPath $root -Recurse -Force |
    Where-Object { -not (Test-Skipped $_.FullName) } |
    Sort-Object { $_.FullName.Length } -Descending
foreach ($item in $items) {
    $newName = Get-Renamed $item.Name
    if (-not [string]::Equals($newName, $item.Name, [System.StringComparison]::Ordinal)) {
        Rename-Item -LiteralPath $item.FullName -NewName $newName
        $pathsRenamed++
    }
}

Write-Host "Renamed $From to $To in $filesChanged file(s) and $pathsRenamed path(s)"
