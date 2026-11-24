<#
.SYNOPSIS
Creates a new app from this template: the code, the GitHub repository, the Azure environment and the first deploy.

.DESCRIPTION
Run it with a name and it does the rest without asking anything:

  1. Copies the template to <Root>\<Name>, renames it and checks it builds and passes its tests.
  2. Creates the GitHub repository with its settings, labels and environments.
  3. Creates the Azure resource groups, the four managed identities, their federated credentials and roles.
  4. Deploys the infrastructure, creates the database users, and sets the GitHub variables and secrets.
  5. Pushes, protects main, waits for the first CI run to deploy, and checks the app answers.

Every step first checks whether its work is already done, so after an error, fix the cause and run the same
command again. It creates billable Azure resources and a public repository.

Afterwards run Set-AppSecrets.ps1 for the values only a person can create (Google sign-in, tokens, Slack).

.EXAMPLE
./New-App.ps1 -Name TrailLog -Tagline 'Plan and log your hikes.'
#>
[CmdletBinding()]
param(
    # The app's name in PascalCase: 3 to 17 letters and digits. Every other name is derived from it.
    [Parameter(Mandatory)][string]$Name,
    # A sentence shown under the logo and used as the repository description.
    [string]$Tagline,
    [string]$Owner = 'dylan-smith',
    [string]$Location = 'westus3',
    # The folder the app's folder is created in.
    [string]$Root = 'E:\git',
    # Where alerts are emailed. Defaults to the account signed in to the Azure CLI.
    [string]$AlertEmail,
    # Skips the local build and tests; CI still runs them.
    [switch]$SkipLocalChecks
)

. "$PSScriptRoot/Common.ps1"

Assert-AppName $Name
$app = Get-AppNames $Name $Owner
$templateRoot = Split-Path $PSScriptRoot -Parent
$templateOwner = 'dylan-smith'
$appRoot = Join-Path $Root $Name
# Holds the generated service token between runs, until it's stored as a GitHub secret. Deleted at the end.
$stateFile = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "new-app\$Name.json"

# ---------------------------------------------------------------------------------------------------------------
Write-Step 'Checking tools and sign-ins'
Assert-Tools 'az', 'gh', 'git', 'dotnet', 'node', 'npm'

$account = az account show --output json | ConvertFrom-Json
$subscriptionId = $account.id
$tenantId = $account.tenantId
$me = az ad signed-in-user show --output json | ConvertFrom-Json
if (-not $AlertEmail) { $AlertEmail = $me.userPrincipalName }
if (-not (Test-Command { gh auth status })) { throw 'Sign in to GitHub first: gh auth login' }
Write-Host "  Azure subscription: $($account.name) ($subscriptionId), signed in as $($me.userPrincipalName)"
Write-Host "  GitHub repository:  $($app.Repo)"

$resuming = Test-Path (Join-Path $appRoot '.git')
if ($resuming) {
    Write-Host "  $appRoot already exists, so this run continues where the last one stopped"
}
else {
    Write-Step 'Checking the names are free'
    $taken = @()
    if (Test-Path $appRoot) { $taken += "the folder $appRoot" }
    if (Test-Command { gh repo view $app.Repo }) { $taken += "the GitHub repository $($app.Repo)" }
    foreach ($group in $app.ResourceGroup, $app.PreviewResourceGroup) {
        if ((az group exists --name $group) -eq 'true') { $taken += "the resource group $group" }
    }
    $storageCheck = az storage account check-name --name $app.StorageAccount --output json | ConvertFrom-Json
    if (-not $storageCheck.nameAvailable) { $taken += "the storage account name $($app.StorageAccount)" }
    foreach ($server in $app.SqlServer, $app.PreviewSqlServer) {
        $body = Join-Path ([System.IO.Path]::GetTempPath()) "new-app-sqlname.json"
        @{ name = $server; type = 'Microsoft.Sql/servers' } | ConvertTo-Json | Set-Content $body
        $sqlCheck = az rest --method post --body "@$body" --output json `
            --url "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Sql/checkNameAvailability?api-version=2021-11-01" |
            ConvertFrom-Json
        Remove-Item $body
        if (-not $sqlCheck.available) { $taken += "the SQL server name $server" }
    }
    if ($taken) { throw "Already taken: $($taken -join '; '). Pick another name." }
    Write-Host '  All free'

    # The app needs two App Service plans: production's, and the one its pull request previews share.
    Write-Step "Checking the App Service quota in $Location"
    $usagesUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Web/locations/$Location/usages?api-version=2024-11-01"
    $usages = @((az rest --method get --url $usagesUrl --output json | ConvertFrom-Json).value)
    $row = $usages | Where-Object { $_.name.value -in 'F1', '*' } | Select-Object -First 1
    if (-not $row) {
        Write-Host '  Azure reported no quota for this region, so it is not checked'
    }
    else {
        # The limit is shared by every plan in the region, whatever its size.
        $used = ($usages | Measure-Object -Property currentValue -Sum).Sum
        $free = $row.limit - $used
        if ($free -lt 2) {
            throw "The subscription can have $($row.limit) App Service plans in $Location and $used are in use; this app needs 2. Use another region with -Location, delete an unused plan, or ask Azure for more quota (portal > Quotas > App Service)."
        }
        Write-Host "  $free of $($row.limit) plans are free"
    }
}

# ---------------------------------------------------------------------------------------------------------------
if (-not $resuming) {
    Write-Step "Creating the code in $appRoot"
    New-Item -ItemType Directory -Path $appRoot | Out-Null
    # Tracked files only, so build output and local settings in the template's folder don't come along.
    foreach ($file in git -C $templateRoot ls-files) {
        if ($file.StartsWith('scaffold/')) { continue }
        $target = Join-Path $appRoot $file
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $templateRoot $file) -Destination $target
    }

    & "$PSScriptRoot/Rename-App.ps1" -Path $appRoot -To $Name

    # The template's own repository skips the jobs that need Azure; the new app runs them.
    foreach ($workflow in 'ci.yml', 'preview-cleanup.yml') {
        Edit-File (Join-Path $appRoot ".github/workflows/$workflow") " && vars.SCAFFOLD_TEMPLATE != 'true'" ''
    }

    if ($Owner -ne $templateOwner) {
        foreach ($file in Get-ChildItem $appRoot -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
            Edit-File $file.FullName $templateOwner $Owner -Optional
        }
    }

    $mainParams = Join-Path $appRoot 'infra/main.bicepparam'
    Set-BicepParam $mainParams 'sqlEntraAdminLogin' $me.userPrincipalName
    Set-BicepParam $mainParams 'sqlEntraAdminObjectId' $me.id
    Set-BicepParam $mainParams 'alertEmail' $AlertEmail
    Set-BicepParam $mainParams 'budgetStartDate' (Get-Date -Day 1).AddMonths(1).ToString('yyyy-MM-01')
    foreach ($file in 'main.bicepparam', 'preview.bicepparam', 'preview-shared.bicepparam') {
        Set-BicepParam (Join-Path $appRoot "infra/$file") 'location' $Location
    }
    if ($Location -ne 'westus3') {
        Write-Warning "The service health alert in infra/modules/alerts.bicep and the README still name West US 3; change them to match $Location."
    }

    if ($Tagline) {
        foreach ($file in 'frontend/index.html', 'frontend/src/App.tsx', 'frontend/src/test/App.test.tsx') {
            Edit-File (Join-Path $appRoot $file) 'A starting point for new apps.' $Tagline
        }
    }

    # The logo spells out the name at a size that fits the longest allowed name.
    $fontSize = [Math]::Min(36, [Math]::Floor(430 / $Name.Length))
    foreach ($file in 'images/logo.svg', 'frontend/src/assets/logo.svg') {
        Edit-File (Join-Path $appRoot $file) 'font-size="36"' "font-size=`"$fontSize`""
    }

    git -C $appRoot init --quiet --initial-branch main
}

Push-Location $appRoot
try {
    # -----------------------------------------------------------------------------------------------------------
    $hasCommit = Test-Command { git rev-parse --verify HEAD }
    if (-not $hasCommit) {
        # The name changes how imports sort and where long lines wrap, and CI fails on either.
        Write-Step 'Formatting the code for the new name'
        dotnet restore --verbosity quiet
        dotnet format "$Name.slnx" --no-restore
        Push-Location frontend
        try {
            npm ci --no-audit --no-fund --loglevel error
            npx prettier --write . --log-level warn
        }
        finally { Pop-Location }
    }

    if ($SkipLocalChecks -or $hasCommit) {
        Write-Step 'Skipping the local build and tests'
    }
    else {
        Write-Step 'Building and testing the backend'
        dotnet build --no-restore --verbosity quiet --nologo
        dotnet format "$Name.slnx" --verify-no-changes --no-restore
        dotnet test --no-build --verbosity quiet --nologo

        Write-Step 'Building and testing the frontend'
        Push-Location frontend
        try {
            npx tsc -b
            npx vite build --logLevel error
            npx eslint . --max-warnings 0
            npx prettier --check . --log-level warn
            npm test --silent
        }
        finally { Pop-Location }

        Write-Step 'Checking the infrastructure templates'
        az bicep build --file infra/main.bicep --stdout --only-show-errors | Out-Null
        az bicep build --file infra/preview.bicep --stdout --only-show-errors | Out-Null
        az bicep build --file infra/preview-shared.bicep --stdout --only-show-errors | Out-Null
    }

    # -----------------------------------------------------------------------------------------------------------
    Write-Step 'Creating the GitHub repository'
    if (Test-Command { gh repo view $app.Repo }) {
        Write-Host '  Already exists'
    }
    else {
        $description = $Tagline ? $Tagline : "$Name, built from AppTemplate."
        gh repo create $app.Repo --public --description $description | Out-Null
    }
    $repo = gh api "repos/$($app.Repo)" | ConvertFrom-Json
    gh api --method PATCH "repos/$($app.Repo)" -F allow_auto_merge=true -F delete_branch_on_merge=true --silent

    foreach ($label in @{ name = 'dependencies'; color = '0366d6' }, @{ name = 'frontend'; color = '1d76db' }, @{ name = 'backend'; color = '5319e7' }) {
        gh label create $label.name --repo $app.Repo --color $label.color --force | Out-Null
    }

    # Only main can use an environment, so a pull request can't reach its secrets or its deploy identity.
    foreach ($environment in 'production', 'alert-investigation') {
        gh api --method PUT "repos/$($app.Repo)/environments/$environment" --silent `
            -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true'
        $policies = gh api "repos/$($app.Repo)/environments/$environment/deployment-branch-policies" | ConvertFrom-Json
        if (@($policies.branch_policies | ForEach-Object name) -notcontains 'main') {
            gh api --method POST "repos/$($app.Repo)/environments/$environment/deployment-branch-policies" -f name=main --silent
        }
    }

    # -----------------------------------------------------------------------------------------------------------
    Write-Step 'Creating the Azure resource groups and identities'
    $groupId = "/subscriptions/$subscriptionId/resourceGroups/$($app.ResourceGroup)"
    $previewGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($app.PreviewResourceGroup)"
    az group create --name $app.ResourceGroup --location $Location --output none
    az group create --name $app.PreviewResourceGroup --location $Location --output none

    # GitHub issues this repository's tokens with subjects built from the owner's and repository's numeric IDs.
    $subject = "repo:$Owner@$($repo.owner.id)/$Name@$($repo.id)"
    $identities = @{}
    foreach ($entry in @(
            @{ Name = $app.DeployIdentity; Subject = "${subject}:environment:production" },
            @{ Name = $app.WhatIfIdentity; Subject = "${subject}:pull_request" },
            @{ Name = $app.PreviewIdentity; Subject = "${subject}:pull_request" },
            @{ Name = $app.InvestigatorIdentity; Subject = "${subject}:environment:alert-investigation" })) {
        # All four live in the main resource group: the preview identity can change everything in the preview one.
        $identities[$entry.Name] = az identity create --name $entry.Name --resource-group $app.ResourceGroup `
            --location $Location --output json | ConvertFrom-Json
        # A new identity can take a moment before it accepts a credential.
        Invoke-WithRetry -What "The identity $($entry.Name)" {
            az identity federated-credential create --name github --identity-name $entry.Name `
                --resource-group $app.ResourceGroup --issuer 'https://token.actions.githubusercontent.com' `
                --subject $entry.Subject --audiences 'api://AzureADTokenExchange' --only-show-errors --output none
        }
    }

    Write-Step 'Assigning roles'
    # Created without looking first: Azure can go on listing a role for a while after it was deleted. Creating one
    # that exists fails, which is fine as long as it's then really there.
    $roleFile = Join-Path ([System.IO.Path]::GetTempPath()) "new-app-whatif-role.json"
    (Get-Content "$PSScriptRoot/whatif-role.json" -Raw).Replace('__ROLE_NAME__', $app.WhatIfRole).Replace('__SCOPE__', $groupId) |
        Set-Content $roleFile
    $created = Test-Command { az role definition create --role-definition $roleFile }
    Remove-Item $roleFile
    if (-not $created -and -not (az role definition list --name $app.WhatIfRole --scope $groupId --output json | ConvertFrom-Json)) {
        throw "Couldn't create the role '$($app.WhatIfRole)'. Run: az role definition create --role-definition scaffold/whatif-role.json (with its placeholders filled in) to see why."
    }

    $grants = @(
        @{ Identity = $app.DeployIdentity; Role = 'Contributor'; Scope = $groupId },
        # On the resource group, not the storage account: the first deploy uses it straight after creating the account.
        @{ Identity = $app.DeployIdentity; Role = 'Storage Blob Data Owner'; Scope = $groupId },
        @{ Identity = $app.WhatIfIdentity; Role = $app.WhatIfRole; Scope = $groupId },
        @{ Identity = $app.PreviewIdentity; Role = 'Contributor'; Scope = $previewGroupId },
        @{ Identity = $app.PreviewIdentity; Role = 'Storage Blob Data Owner'; Scope = $previewGroupId },
        @{ Identity = $app.InvestigatorIdentity; Role = 'Reader'; Scope = $groupId },
        @{ Identity = $app.InvestigatorIdentity; Role = 'Monitoring Reader'; Scope = $groupId },
        @{ Identity = $app.InvestigatorIdentity; Role = 'Log Analytics Reader'; Scope = $groupId },
        @{ Identity = $app.InvestigatorIdentity; Role = 'Cost Management Reader'; Scope = $groupId },
        @{ Identity = $app.InvestigatorIdentity; Role = 'Monitoring Reader'; Scope = "/subscriptions/$subscriptionId" }
    )
    foreach ($grant in $grants) {
        # A new identity or role definition takes a moment to be assignable.
        Invoke-WithRetry -What "$($grant.Role) for $($grant.Identity)" {
            az role assignment create --assignee-object-id $identities[$grant.Identity].principalId `
                --assignee-principal-type ServicePrincipal --role $grant.Role --scope $grant.Scope `
                --only-show-errors --output none
        }
    }

    # The preview identity is the Entra admin of the SQL server the previews share.
    Set-BicepParam 'infra/preview-shared.bicepparam' 'sqlEntraAdminObjectId' $identities[$app.PreviewIdentity].principalId

    # -----------------------------------------------------------------------------------------------------------
    Write-Step 'Deploying the infrastructure (about 5 minutes)'
    $connectionString = "Server=tcp:$($app.SqlServer).database.windows.net,1433;Initial Catalog=$($app.Database);" +
        'Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;Connection Timeout=120;'
    $deployment = $null
    if (Test-Command { az deployment group show --resource-group $app.ResourceGroup --name scaffold }) {
        $deployment = az deployment group show --resource-group $app.ResourceGroup --name scaffold --output json | ConvertFrom-Json
    }
    if ($deployment -and $deployment.properties.provisioningState -eq 'Succeeded') {
        Write-Host '  Already deployed'
    }
    else {
        if (Test-Path $stateFile) {
            $serviceToken = (Get-Content $stateFile -Raw | ConvertFrom-Json).serviceToken
        }
        else {
            $serviceToken = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
            New-Item -ItemType Directory -Path (Split-Path $stateFile -Parent) -Force | Out-Null
            @{ serviceToken = $serviceToken } | ConvertTo-Json | Set-Content $stateFile
        }
        # The parameter file reads these, the same way it does in CI. Google sign-in and Slack are added later, so
        # their variables must not leak in from this shell.
        $env:AZURE_SQL_CONNECTION_STRING = $connectionString
        Remove-Item env:GOOGLE_CLIENT_ID, env:SLACK_WEBHOOK_URL, env:ALERT_INVESTIGATION_TOKEN -ErrorAction SilentlyContinue
        Set-Item "env:$($app.ServiceTokenSecret)" $serviceToken
        try {
            # More tries cover Azure's passing failures, such as one resource not yet seeing another.
            Invoke-WithRetry -What 'The deployment' -Attempts 3 -DelaySeconds 60 {
                az deployment group create --resource-group $app.ResourceGroup --name scaffold `
                    --template-file infra/main.bicep --parameters infra/main.bicepparam --only-show-errors --output none
            }
        }
        finally {
            Remove-Item "env:$($app.ServiceTokenSecret)", env:AZURE_SQL_CONNECTION_STRING
        }
        $deployment = az deployment group show --resource-group $app.ResourceGroup --name scaffold --output json | ConvertFrom-Json
    }
    $backendUrl = $deployment.properties.outputs.appServiceUrl.value.TrimEnd('/')
    $frontendUrl = $deployment.properties.outputs.frontendWebEndpoint.value.TrimEnd('/')
    Write-Host "  API:      $backendUrl"
    Write-Host "  Frontend: $frontendUrl"

    # Done now so the first pull request doesn't connect to a SQL server whose firewall rule is seconds old.
    Write-Step 'Deploying the resources that pull request previews share'
    az deployment group create --resource-group $app.PreviewResourceGroup --name scaffold-shared `
        --template-file infra/preview-shared.bicep --parameters infra/preview-shared.bicepparam `
        --only-show-errors --output none

    # -----------------------------------------------------------------------------------------------------------
    Write-Step 'Creating the database users'
    $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 30).Trim()
    Invoke-WithRetry -What 'The SQL server' {
        az sql server firewall-rule create --resource-group $app.ResourceGroup --server $app.SqlServer `
            --name scaffold-temporary --start-ip-address $myIp --end-ip-address $myIp --only-show-errors --output none
    }
    try {
        # A token for the signed-in Azure CLI account, which is the SQL server's Entra admin.
        $env:SQL_ACCESS_TOKEN = az account get-access-token --resource 'https://database.windows.net/' --query accessToken --output tsv
        dotnet run "$PSScriptRoot/create-db-users.cs" -- "$($app.SqlServer).database.windows.net" $app.Database `
            $app.DeployIdentity $app.AppService
    }
    finally {
        Remove-Item env:SQL_ACCESS_TOKEN -ErrorAction SilentlyContinue
        Invoke-WithRetry -What 'Removing the temporary firewall rule' {
            az sql server firewall-rule delete --resource-group $app.ResourceGroup --server $app.SqlServer `
                --name scaffold-temporary --only-show-errors --output none
        }
    }

    # -----------------------------------------------------------------------------------------------------------
    Write-Step 'Setting the GitHub variables and secrets'
    $variables = @(
        @{ Name = 'AZURE_TENANT_ID'; Value = $tenantId },
        @{ Name = 'AZURE_SUBSCRIPTION_ID'; Value = $subscriptionId },
        @{ Name = 'AZURE_RESOURCE_GROUP'; Value = $app.ResourceGroup },
        @{ Name = 'AZURE_WHATIF_CLIENT_ID'; Value = $identities[$app.WhatIfIdentity].clientId },
        @{ Name = 'AZURE_PREVIEW_CLIENT_ID'; Value = $identities[$app.PreviewIdentity].clientId },
        @{ Name = 'AZURE_CLIENT_ID'; Value = $identities[$app.DeployIdentity].clientId; Environment = 'production' },
        @{ Name = 'AZURE_BACKEND_APP_NAME'; Value = $app.AppService; Environment = 'production' },
        @{ Name = 'AZURE_BACKEND_URL'; Value = $backendUrl; Environment = 'production' },
        @{ Name = 'AZURE_STORAGE_ACCOUNT_NAME'; Value = $app.StorageAccount; Environment = 'production' },
        @{ Name = 'AZURE_ALERT_INVESTIGATOR_CLIENT_ID'; Value = $identities[$app.InvestigatorIdentity].clientId; Environment = 'alert-investigation' }
    )
    foreach ($variable in $variables) {
        $scope = $variable.ContainsKey('Environment') ? @('--env', $variable.Environment) : @()
        gh variable set $variable.Name --repo $app.Repo --body $variable.Value @scope
    }
    gh secret set AZURE_SQL_CONNECTION_STRING --repo $app.Repo --env production --body $connectionString
    if (Test-Path $stateFile) {
        $serviceToken = (Get-Content $stateFile -Raw | ConvertFrom-Json).serviceToken
        gh secret set $app.ServiceTokenSecret --repo $app.Repo --env production --body $serviceToken
    }
    else {
        $secrets = gh secret list --repo $app.Repo --env production --json name | ConvertFrom-Json
        if (@($secrets | ForEach-Object name) -notcontains $app.ServiceTokenSecret) {
            throw "The service token from the infrastructure deployment is lost. Delete the 'scaffold' deployment in the $($app.ResourceGroup) resource group (az deployment group delete) and run this again."
        }
    }

    # -----------------------------------------------------------------------------------------------------------
    Write-Step 'Committing and pushing'
    Edit-File 'README.md' "$Name@<repo id>:" "$Name@$($repo.id):" -Optional
    Edit-File 'README.md' '`<repo id>`' "``$($repo.id)``" -Optional
    Edit-File 'README.md' "https://$($app.Lower)-<generated>.azurewebsites.net" $backendUrl -Optional
    Edit-File 'README.md' "$($app.StorageAccount).<zone>.web.core.windows.net" ([uri]$frontendUrl).Host -Optional

    if (-not $hasCommit) {
        git add --all
        git commit --quiet --message "Create $Name from AppTemplate"
    }
    elseif (git status --porcelain) {
        git add --all
        git commit --quiet --message 'Fill in the deployed values'
    }
    if (-not (Test-Command { git remote get-url origin })) {
        git remote add origin "https://github.com/$($app.Repo).git"
    }
    $rulesets = gh api "repos/$($app.Repo)/rulesets" | ConvertFrom-Json
    $protected = @($rulesets | ForEach-Object name) -contains 'MainRuleset'
    if ((Test-Command { git rev-parse --verify origin/main }) -and -not (git log origin/main..main --oneline)) {
        Write-Host '  Already pushed'
    }
    elseif ($protected) {
        throw 'There are local commits, but main is already protected. Push them on a branch and open a pull request.'
    }
    else {
        git push --quiet --set-upstream origin main
    }

    # After the push: the rules only let changes into main through pull requests.
    if (-not $protected) {
        gh api --method POST "repos/$($app.Repo)/rulesets" --input "$PSScriptRoot/ruleset.json" --silent
        Write-Host '  Protected main with MainRuleset'
    }

    # -----------------------------------------------------------------------------------------------------------
    Write-Step 'Waiting for the first CI run to build, test and deploy (about 15 minutes)'
    $head = git rev-parse HEAD
    $run = Invoke-WithRetry -What 'The CI run' {
        $found = gh run list --repo $app.Repo --workflow ci.yml --commit $head --limit 1 --json databaseId,url | ConvertFrom-Json
        if (-not $found) { throw 'No CI run yet' }
        $found[0]
    }
    Write-Host "  $($run.url)"
    if (-not (Test-Command { gh run watch $run.databaseId --repo $app.Repo --interval 30 --exit-status })) {
        throw "The CI run failed: $($run.url). Fix the cause, then run this again or re-run the failed jobs."
    }

    Write-Step 'Checking the app answers'
    $probes = @(
        @{ Url = "$backendUrl/health"; Expected = 200 },
        @{ Url = $frontendUrl; Expected = 200 },
        @{ Url = "$backendUrl/api/projects"; Expected = 401 }
    )
    foreach ($probe in $probes) {
        $status = Invoke-WithRetry -What $probe.Url -Attempts 6 {
            $response = Invoke-WebRequest -Uri $probe.Url -SkipHttpErrorCheck -TimeoutSec 60
            if ($response.StatusCode -ne $probe.Expected) {
                throw "$($probe.Url) returned $($response.StatusCode), expected $($probe.Expected)"
            }
            $response.StatusCode
        }
        Write-Host "  $status $($probe.Url)"
    }

    Remove-Item $stateFile -ErrorAction SilentlyContinue

    Write-Step "$Name is live"
    Write-Host "  Code:       $appRoot"
    Write-Host "  Repository: https://github.com/$($app.Repo)"
    Write-Host "  Frontend:   $frontendUrl"
    Write-Host "  API:        $backendUrl"
    Write-Host ''
    Write-Host '  Google sign-in, Dependabot auto-merge, the Claude workflows and Slack alerts are off until you run:'
    Write-Host "    pwsh $PSScriptRoot\Set-AppSecrets.ps1 -Name $Name" -ForegroundColor Yellow
}
finally {
    Pop-Location
}
