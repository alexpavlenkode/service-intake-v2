<#
    .SYNOPSIS
        Establishes (or verifies) the Dataverse connection for SI-DEV and
        prints WhoAmI. Run this once per PowerShell session before
        discover.ps1 / deploy.ps1 / verify.ps1.

    .NOTES
        Auth: Az.Accounts, interactive browser login. Device code flow is
        blocked by this tenant's Conditional Access (AADSTS530035) — do not
        add -UseDeviceAuthentication anywhere in this project.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force

$config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"

Connect-DataverseOrg -TenantId $config.TenantId

$who = Invoke-DataverseApi -OrgUrl $config.OrgUrl -Method GET -Path 'WhoAmI'
Write-Output "[CONNECT] Connected to $($config.EnvironmentName) ($($config.OrgUrl))"
Write-Output "[CONNECT] UserId=$($who.UserId) OrganizationId=$($who.OrganizationId)"
