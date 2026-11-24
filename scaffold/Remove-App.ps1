<#
.SYNOPSIS
Deletes everything New-App.ps1 created in Azure for an app, and optionally its GitHub repository.

.DESCRIPTION
Deletes both resource groups (the app, its database and backups, the identities and the previews), the custom
what-if role and the alert investigator's subscription-level role assignment. With -DeleteRepository it also
deletes the GitHub repository, which needs the delete_repo scope: gh auth refresh -s delete_repo

Nothing can be recovered afterwards, so it asks you to type the app's name first. The local folder is left alone.

.EXAMPLE
./Remove-App.ps1 -Name ScaffoldTest -DeleteRepository
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Owner = 'dylan-smith',
    [switch]$DeleteRepository,
    # Skips the question. For scripts only: there is no undo.
    [switch]$Force
)

. "$PSScriptRoot/Common.ps1"

Assert-AppName $Name
Assert-Tools 'az', 'gh'
$app = Get-AppNames $Name $Owner
$account = az account show --output json | ConvertFrom-Json

Write-Host "This permanently deletes, in the subscription '$($account.name)':"
Write-Host "  - the resource groups $($app.ResourceGroup) and $($app.PreviewResourceGroup), with the database and its backups"
Write-Host "  - the role '$($app.WhatIfRole)'"
if ($DeleteRepository) { Write-Host "  - the GitHub repository $($app.Repo)" }
if (-not $Force -and (Read-Host "Type the app's name to go ahead") -cne $Name) {
    throw 'The name did not match; nothing was deleted.'
}

Write-Step 'Removing the alert investigator from the subscription'
if (Test-Command { az identity show --name $app.InvestigatorIdentity --resource-group $app.ResourceGroup }) {
    $principalId = az identity show --name $app.InvestigatorIdentity --resource-group $app.ResourceGroup --query principalId --output tsv
    az role assignment delete --assignee $principalId --scope "/subscriptions/$($account.id)" --only-show-errors
}

# Before the resource group goes: the role is scoped to it, and can't be deleted while it's still assigned.
Write-Step "Deleting the role '$($app.WhatIfRole)'"
$groupId = "/subscriptions/$($account.id)/resourceGroups/$($app.ResourceGroup)"
$roles = az role definition list --name $app.WhatIfRole --scope $groupId --output json | ConvertFrom-Json
if ($roles) {
    az role assignment delete --role $app.WhatIfRole --scope $groupId --only-show-errors
    Invoke-WithRetry -What 'The role' {
        az role definition delete --name $app.WhatIfRole --scope $groupId --only-show-errors
    }
}

# A deleted Log Analytics workspace stays recoverable for 14 days. An app recreated under the same name in that
# time gets the old workspace back, and its first deploy then fails on the log alert rules, so purge it for good.
if ((az group exists --name $app.ResourceGroup) -eq 'true') {
    Write-Step 'Purging the Log Analytics workspace'
    foreach ($workspace in @(az monitor log-analytics workspace list --resource-group $app.ResourceGroup --query '[].name' --output tsv)) {
        az monitor log-analytics workspace delete --resource-group $app.ResourceGroup --workspace-name $workspace --force true --yes
    }
}

foreach ($group in $app.PreviewResourceGroup, $app.ResourceGroup) {
    if ((az group exists --name $group) -eq 'true') {
        Write-Step "Deleting the resource group $group (several minutes)"
        az group delete --name $group --yes
    }
}

if ($DeleteRepository -and (Test-Command { gh repo view $app.Repo })) {
    Write-Step "Deleting the GitHub repository $($app.Repo)"
    gh repo delete $app.Repo --yes
}

Remove-Item (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "new-app\$Name.json") -ErrorAction SilentlyContinue
Write-Step 'Done'
