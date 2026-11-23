# Shared by the scaffold scripts. Dot-source it: . "$PSScriptRoot/Common.ps1"

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# A failing az, gh, git, dotnet or npm call stops the script.
$PSNativeCommandUseErrorActionPreference = $true

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "== $Message" -ForegroundColor Cyan
}

# Runs a command that is allowed to fail, and says whether it succeeded. Its output is discarded.
function Test-Command([scriptblock]$Command) {
    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Continue'
    & $Command *> $null
    $LASTEXITCODE -eq 0
}

# Retries a command that can fail while Azure or GitHub catches up with something just created.
function Invoke-WithRetry([scriptblock]$Command, [string]$What, [int]$Attempts = 12, [int]$DelaySeconds = 10) {
    for ($attempt = 1; ; $attempt++) {
        try {
            return & $Command
        }
        catch {
            if ($attempt -ge $Attempts) { throw }
            Write-Host "  $What isn't ready yet (attempt $attempt of $Attempts); retrying in $DelaySeconds seconds"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Assert-AppName([string]$Name) {
    # 17 characters keeps the preview storage account name (<name>pr<number><5 characters>) within Azure's 24.
    if ($Name -cnotmatch '^[A-Z][A-Za-z0-9]{2,16}$') {
        throw "The name '$Name' must start with a capital letter and be 3 to 17 letters and digits, like MyApp."
    }
}

# The names everything is derived from, so the scripts agree on them.
function Get-AppNames([string]$Name, [string]$Owner) {
    $lower = $Name.ToLowerInvariant()
    [pscustomobject]@{
        Name                  = $Name
        Lower                 = $lower
        Repo                  = "$Owner/$Name"
        ResourceGroup         = $Name
        PreviewResourceGroup  = "$Name-Preview"
        AppService            = $Name
        Database              = $Name
        SqlServer             = "$lower-sql"
        PreviewSqlServer      = "$lower-preview-sql"
        StorageAccount        = "${lower}web"
        DeployIdentity        = "$lower-deploy"
        WhatIfIdentity        = "$lower-pr-whatif"
        PreviewIdentity       = "$lower-preview-deploy"
        InvestigatorIdentity  = "$lower-alert-investigator"
        WhatIfRole            = "$Name What-If Reader"
        ServiceTokenSecret    = "$($Name.ToUpperInvariant())_SERVICE_TOKEN"
    }
}

function Assert-Tools([string[]]$Tools) {
    foreach ($tool in $Tools) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "'$tool' isn't installed or isn't on the PATH."
        }
    }
}

# Replaces literal text in a file, and fails when the text isn't there so a template change can't go unnoticed.
function Edit-File([string]$File, [string]$Find, [string]$Replace, [switch]$Optional) {
    $text = [System.IO.File]::ReadAllText($File)
    if (-not $text.Contains($Find)) {
        if ($Optional) { return }
        throw "Expected to find '$Find' in $File. The template has changed; update the scaffold script to match."
    }
    [System.IO.File]::WriteAllText($File, $text.Replace($Find, $Replace), $script:Utf8NoBom)
}

# Sets the value of a "param name = '...'" line in a .bicepparam file.
function Set-BicepParam([string]$File, [string]$Name, [string]$Value) {
    $text = [System.IO.File]::ReadAllText($File)
    $pattern = "(?m)^param $([regex]::Escape($Name)) = '[^']*'"
    if ($text -notmatch $pattern) {
        throw "Expected a string parameter '$Name' in $File. The template has changed; update the scaffold script to match."
    }
    $replacement = "param $Name = '$Value'"
    [System.IO.File]::WriteAllText($File, [regex]::Replace($text, $pattern, { $replacement }), $script:Utf8NoBom)
}
