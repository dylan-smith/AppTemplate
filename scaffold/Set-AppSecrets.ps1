<#
.SYNOPSIS
Asks for the values only a person can create for an app made by New-App.ps1, and stores them in GitHub.

.DESCRIPTION
Run it yourself in a terminal: it prompts for each value, hides the secret ones as you paste, and never prints
them. Press Enter at any prompt to skip that value (or keep the one already set); run it again later for the rest.

  GOOGLE_CLIENT_ID           Turns on Google sign-in.
  AUTOMERGE_TOKEN            Lets Dependabot pull requests merge themselves, and Claude open CI fix pull requests.
  CLAUDE_CODE_OAUTH_TOKEN    Lets Claude investigate CI failures and alerts.
  SLACK_WEBHOOK_URL          Posts alerts to a Slack channel.
  ALERT_INVESTIGATION_TOKEN  Lets an alert start Claude's investigation (needs the Slack webhook too).

It then starts a deploy so the new values take effect, and turns on auto-merge for the open Dependabot pull
requests.

.EXAMPLE
./Set-AppSecrets.ps1 -Name TrailLog
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Owner = 'dylan-smith'
)

. "$PSScriptRoot/Common.ps1"

Assert-AppName $Name
Assert-Tools 'az', 'gh'
$app = Get-AppNames $Name $Owner

$frontendUrl = (az storage account show --name $app.StorageAccount --resource-group $app.ResourceGroup `
        --query primaryEndpoints.web --output tsv).TrimEnd('/')
$repositorySecrets = @(gh secret list --repo $app.Repo --json name | ConvertFrom-Json | ForEach-Object name)
$productionVariables = @(gh variable list --repo $app.Repo --env production --json name | ConvertFrom-Json | ForEach-Object name)
$needsDeploy = $false
$autoMergeSet = $false

function Read-Value([string]$Title, [string[]]$Instructions, [bool]$AlreadySet, [switch]$Secret, [string]$MustMatch, [string]$Open) {
    Write-Step $Title
    foreach ($line in $Instructions) { Write-Host "  $line" }
    if ($Open) {
        Write-Host "  Opening $Open"
        Start-Process $Open
    }
    $hint = $AlreadySet ? 'already set; press Enter to keep it' : 'press Enter to skip'
    while ($true) {
        $prompt = "  Paste the value ($hint)"
        $value = ($Secret ? (Read-Host $prompt -MaskInput) : (Read-Host $prompt)).Trim()
        if (-not $value) { return $null }
        if (-not $MustMatch -or $value -match $MustMatch) { return $value }
        Write-Host "  That doesn't look right: it should match $MustMatch" -ForegroundColor Yellow
    }
}

# Sends the value on standard input, so it never appears in a command line.
function Set-Secret([string]$SecretName, [string]$Value, [string[]]$Scope = @()) {
    $Value | gh secret set $SecretName --repo $app.Repo @Scope
}

$tokenPage = 'https://github.com/settings/personal-access-tokens/new'

$value = Read-Value 'Google sign-in (GOOGLE_CLIENT_ID)' -AlreadySet ($productionVariables -contains 'GOOGLE_CLIENT_ID') `
    -MustMatch '\.apps\.googleusercontent\.com$' -Open 'https://console.cloud.google.com/apis/credentials' -Instructions @(
    'Create credentials > OAuth client ID > Web application, named after the app.',
    "Under Authorized JavaScript origins add exactly: $frontendUrl",
    'Create it, then copy the Client ID (it ends in .apps.googleusercontent.com). It is not a secret.')
if ($value) {
    gh variable set GOOGLE_CLIENT_ID --repo $app.Repo --env production --body $value
    $needsDeploy = $true
}

$value = Read-Value 'Dependabot auto-merge and CI fix pull requests (AUTOMERGE_TOKEN)' -Secret `
    -AlreadySet ($repositorySecrets -contains 'AUTOMERGE_TOKEN') -MustMatch '^(github_pat_|ghp_)' -Open $tokenPage -Instructions @(
    'Create a fine-grained personal access token:',
    "  Repository access: Only select repositories > $($app.Repo)",
    '  Repository permissions: Contents: Read and write; Pull requests: Read and write',
    '  Note its expiry date: the workflows stop working when it expires.')
if ($value) {
    # Workflows that Dependabot starts can only read Dependabot secrets, so it goes in both places.
    Set-Secret 'AUTOMERGE_TOKEN' $value
    Set-Secret 'AUTOMERGE_TOKEN' $value '--app', 'dependabot'
    $autoMergeSet = $true
}

$value = Read-Value 'Claude investigations (CLAUDE_CODE_OAUTH_TOKEN)' -Secret `
    -AlreadySet ($repositorySecrets -contains 'CLAUDE_CODE_OAUTH_TOKEN') -Instructions @(
    'In another terminal run: claude setup-token',
    'and copy the token it prints.')
if ($value) { Set-Secret 'CLAUDE_CODE_OAUTH_TOKEN' $value }

$value = Read-Value 'Slack alerts (SLACK_WEBHOOK_URL)' -Secret -AlreadySet ($repositorySecrets -contains 'SLACK_WEBHOOK_URL') `
    -MustMatch '^https://hooks\.slack\.com/' -Open 'https://api.slack.com/apps' -Instructions @(
    'Create New App > From scratch, in your workspace.',
    'Incoming Webhooks > turn on > Add New Webhook to Workspace > pick the alerts channel > Allow.',
    'Copy the webhook URL (it starts with https://hooks.slack.com/services/).')
if ($value) {
    Set-Secret 'SLACK_WEBHOOK_URL' $value
    $needsDeploy = $true
}

$value = Read-Value 'Alert investigation (ALERT_INVESTIGATION_TOKEN)' -Secret `
    -AlreadySet ($repositorySecrets -contains 'ALERT_INVESTIGATION_TOKEN') -MustMatch '^(github_pat_|ghp_)' -Open $tokenPage -Instructions @(
    'Only useful with the Slack webhook. Create a second fine-grained personal access token:',
    "  Repository access: Only select repositories > $($app.Repo)",
    '  Repository permissions: Actions: Read and write')
if ($value) {
    Set-Secret 'ALERT_INVESTIGATION_TOKEN' $value
    $needsDeploy = $true
}

if ($needsDeploy) {
    Write-Step 'Starting a deploy so the new values take effect'
    gh workflow run ci.yml --repo $app.Repo --ref main
    Write-Host "  Watch it at https://github.com/$($app.Repo)/actions/workflows/ci.yml"
}

if ($autoMergeSet) {
    Write-Step 'Turning on auto-merge for the open Dependabot pull requests'
    # The workflow ran without the token when each pull request opened, so run it again. It leaves major updates
    # for you to review.
    $pullRequests = @(gh pr list --repo $app.Repo --app dependabot --state open --json number,headRefName | ConvertFrom-Json)
    foreach ($pullRequest in $pullRequests) {
        $runs = @(gh run list --repo $app.Repo --workflow dependabot-auto-merge.yml --branch $pullRequest.headRefName `
                --limit 1 --json databaseId | ConvertFrom-Json)
        if ($runs) {
            gh run rerun $runs[0].databaseId --repo $app.Repo | Out-Null
            Write-Host "  #$($pullRequest.number)"
        }
    }
    if (-not $pullRequests) { Write-Host '  None are open' }
}

Write-Step 'Done'
Write-Host "  Sign in at $frontendUrl once the deploy finishes to check Google sign-in."
Write-Host "  To check Slack: in the Azure portal, open the $Name-Alerts action group and choose Test."
