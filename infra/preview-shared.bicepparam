using './preview-shared.bicep'

// Values for the resources shared by every preview environment in the AppTemplate-Preview resource group. CI
// deploys these from the PR's base branch, so a change here reaches previews once it's merged.
param location = 'westus2'

param appServicePlanName = 'AppTemplate-Preview-Plan'
param appServicePlanSku = 'F1'
param sqlServerName = 'apptemplate-preview-sql'

// The apptemplate-preview-deploy managed identity (see README, Identities & Permissions)
param sqlEntraAdminLogin = 'apptemplate-preview-deploy'
param sqlEntraAdminObjectId = '00000000-0000-0000-0000-000000000000'
