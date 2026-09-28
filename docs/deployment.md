# Deployment — Auth & Tooling Notes

## Target environment

- Environment: **SI-DEV**
- Org URL: `https://REDACTEDORGDEV.crm16.dynamics.com`
- Tenant ID: `00000000-0000-0000-0000-000000000000`
- PAC CLI: 2.12.2, already authenticated as `AlexPavlenko@M365Automation.onmicrosoft.com` (profile `SI-DEV-Codex`).

## Auth method for the Dataverse Web API (chosen)

**Az.Accounts, interactive browser login. Not device code.**

```powershell
Import-Module Az.Accounts
Update-AzConfig -EnableLoginByWam $false -Scope Process
Connect-AzAccount -Tenant "00000000-0000-0000-0000-000000000000"
$token = (Get-AzAccessToken -ResourceUrl "https://REDACTEDORGDEV.crm16.dynamics.com").Token
```

Wrapped in `scripts/lib/Dataverse.psm1` (`Connect-DataverseOrg`, `Get-DataverseToken`). `scripts/connect.ps1` is the one-line entry point to establish/verify the session.

The token is never written to disk, `.env`, git, or logs. Only expiry/audience may ever be logged.

## How we got here (for the next person who hits the same wall)

The project prompt's fallback order is: (1) `pac auth token`, (2) Azure CLI, (3) PowerShell 7 + Dataverse ServiceClient, (4) custom App Registration. What actually happened, in order:

1. **`pac auth token`** — confirmed via a live `WhoAmI` call that it issues a token for `https://api.powerplatform.com/`, not the org URL. `GET /api/data/v9.2/WhoAmI` with that token returns `401`. Ruled out — pac CLI has no parameter to change the token audience (`pac auth token --help` takes no arguments).
2. **Azure CLI** — not installed, and installing it plus signing in would have needed the same interactive step as the alternatives below, so we went straight to the PowerShell-native option instead of installing a second CLI.
3. **`Az.Accounts` module, device code flow** (`Connect-AzAccount -UseDeviceAuthentication`) — installed cleanly (`Install-Module Az.Accounts -Scope CurrentUser`), but every attempt failed with **`AADSTS530035`**. Per Microsoft's error code reference this tenant's Conditional Access / Security Defaults blocks the OAuth **device code flow** itself, not just a specific client app.
4. **`MSAL.PS` with the well-known Dataverse-native client ID** (`51f81489-12ee-4a9e-aaae-a2591f45987d`), still via device code — same block. Confirms the block is on the *flow*, not the *client app*.
5. **`Az.Accounts`, ordinary interactive browser login** (`Connect-AzAccount -Tenant <tenantId>`, no `-UseDeviceAuthentication`) — succeeded immediately via silent SSO (the signed-in Windows session already satisfied the login). `Get-AzAccessToken -ResourceUrl <org>` then returns a working org-scoped token, verified with `WhoAmI` (HTTP 200).

**Takeaway:** in this tenant, device code flow is a dead end for any client. Ordinary interactive (browser/WAM) auth works. If SI-DEV's Conditional Access policy changes, re-verify with a fresh `WhoAmI` call before assuming either path still behaves the same way.

## Metadata request headers

Every metadata-creating call must carry:

- `MSCRM.SolutionUniqueName: HSVServiceIntakeV2`
- `MSCRM.MergeLabels: true` (updates only)

Base language code is read at runtime via `Get-DataverseBaseLanguageCode` (`organizations` entity, `languagecode`) — **1031** (de-DE) in SI-DEV as of this discovery run. Never hardcode it.

## Running the scripts

```powershell
# 1. Verify connectivity
powershell -File scripts\connect.ps1

# 2. Read-only inventory, writes docs/discovery-report.md
powershell -File scripts\discover.ps1

# 3. Plan only, zero writes
powershell -File scripts\deploy.ps1 -DryRun

# 4. Actually create components (Phase B/C, after explicit go-ahead)
powershell -File scripts\deploy.ps1 -Apply
```
