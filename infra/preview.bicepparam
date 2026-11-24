using './preview.bicep'

// Values for a pull request's preview environment in the AppTemplate-Preview resource group (the resources every
// preview shares are in preview-shared.bicepparam). The deploy-preview CI job sets PREVIEW_PR_NUMBER and
// PREVIEW_DATABASE_TAGS; to run the template by hand, set PREVIEW_PR_NUMBER to the PR's number first.
param location = 'westus3'
param prNumber = int(readEnvironmentVariable('PREVIEW_PR_NUMBER'))

// The shared resources, deployed by preview-shared.bicep
param appServicePlanName = 'AppTemplate-Preview-Plan'
param sqlServerName = 'apptemplate-preview-sql'

// Off: in this subscription the SQL free offer only works in West US 2, where there's no App Service quota left
// for new apps. The database costs about $0.25 an hour while active and nothing while paused (an existing
// database keeps the setting it was created with).
param useFreeLimit = false

// The database's current tags, as JSON, so the deployment keeps them (see the parameter in preview.bicep)
param existingDatabaseTags = json(readEnvironmentVariable('PREVIEW_DATABASE_TAGS', '{}'))
