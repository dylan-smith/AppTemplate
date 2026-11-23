# Scaffold

Scripts that turn this template into a new, deployed app. They need PowerShell 7, the Azure CLI and GitHub CLI
(both signed in), the .NET SDK and Node.js. New apps don't get a copy of this folder.

## Create an app

```powershell
./New-App.ps1 -Name TrailLog -Tagline 'Plan and log your hikes.'
```

In Claude Code, `/new-app TrailLog` runs the same thing and deals with any errors.

It asks nothing and takes about 25 minutes. When it finishes, the app is live: the code is in `E:\git\TrailLog`,
the repository is on GitHub with `main` protected, production is deployed in Azure, and pull requests get preview
environments. It creates billable Azure resources (mainly a Basic SQL database) and a public repository.

The name is 3 to 17 letters and digits in PascalCase. Every other name comes from it: the resource groups
`TrailLog` and `TrailLog-Preview`, the storage account `traillogweb`, the SQL server `traillog-sql`, and so on.
The script stops before creating anything if one of them is taken.

If it fails partway, fix the cause and run the same command again. Each step skips what's already done.

## Finish the setup

```powershell
./Set-AppSecrets.ps1 -Name TrailLog
```

Run this yourself in a terminal. It walks through the five values a script can't create (the Google OAuth
client, two GitHub tokens, the Claude token and the Slack webhook), opening the page for each and hiding what
you paste. Skip any of them with Enter and run it again later. Until then the app works, with these turned off:

| Value | Without it |
|-------|-----------|
| `GOOGLE_CLIENT_ID` | Nobody can sign in to production (previews and local runs use test sign-in) |
| `AUTOMERGE_TOKEN` | Dependabot pull requests wait for you to merge them |
| `CLAUDE_CODE_OAUTH_TOKEN` | CI failures and alerts aren't investigated |
| `SLACK_WEBHOOK_URL` | Alerts only go to email and the Azure mobile app |
| `ALERT_INVESTIGATION_TOKEN` | Alerts aren't investigated |

## Delete an app

```powershell
./Remove-App.ps1 -Name TrailLog -DeleteRepository
```

Deletes the app's Azure resources for good, including the database and its backups, and with
`-DeleteRepository` the GitHub repository too. It asks you to type the name first.

## Files

| File | Purpose |
|------|---------|
| `New-App.ps1` | Creates the app end to end |
| `Set-AppSecrets.ps1` | Prompts for the values a person has to create |
| `Remove-App.ps1` | Deletes an app |
| `Rename-App.ps1` | Renames `AppTemplate` in file contents and paths; used by `New-App.ps1` |
| `Common.ps1` | Functions and derived names shared by the scripts |
| `create-db-users.cs` | Creates the production database users |
| `ruleset.json` | The branch rules applied to `main` |
| `whatif-role.json` | The custom role for the pull request what-if identity |

## Changing the template

The app in this repository is the template: change it like any app, and CI builds and tests it on every push. The
jobs that need Azure are skipped here by the `SCAFFOLD_TEMPLATE` repository variable; `New-App.ps1` removes
that condition from a new app's workflows.

`New-App.ps1` edits specific lines of the copy (parameter values, the tagline, the README's placeholders). If
one of those lines changes here, the script stops with a message saying which, so update it to match.
