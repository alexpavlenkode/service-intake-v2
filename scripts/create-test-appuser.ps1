<#
    .SYNOPSIS
        Creates a throwaway Entra App Registration + Dataverse Application
        User ("Test Techniker B") for the row-level-security access test
        (tests/access-test-report.md). SI-DEV is a Developer Plan
        environment with exactly one licensed interactive human user, so a
        second real user account isn't available - this proves the same
        security enforcement via CallerObjectId impersonation instead.

    .DESCRIPTION
        1. Creates an Entra application (Graph API).
        2. Creates its service principal (Graph API) - this is what gives it
           an object ID Dataverse can use as azureactivedirectoryobjectid.
        3. Creates a Dataverse Application User (systemuser, accessmode=4)
           bound to that application.
        4. Assigns it the "HSV Techniker" security role.

        Nothing here is destructive and nothing here touches V1 or any
        existing user. The app registration is named distinctively
        (HSV-Test-Techniker-B) so it's easy to find and delete later if you
        want to clean it up - this script does not delete it automatically
        (deletion of an Entra app is also outside this project's "no
        deletion except test records we created" pattern for *metadata*,
        but an Entra app registration isn't Dataverse metadata; cleanup is
        left to the user, see tests/access-test-report.md).

    .PARAMETER Apply
        Actually create the app registration, service principal, and
        Dataverse application user.
#>
[CmdletBinding()]
param(
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force
Import-Module Az.Accounts -Force

$config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

if (-not $Apply) {
    Write-Output "[DRY RUN] Would create Entra app 'HSV-Test-Techniker-B', its service principal, a Dataverse Application User, and assign role 'HSV Techniker'. Pass -Apply to actually do it."
    return
}

function Get-GraphToken {
    $tok = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com"
    $t = $tok.Token
    if ($t -is [System.Security.SecureString]) {
        $t = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($t))
    }
    return $t
}

$graphHeaders = @{ Authorization = "Bearer $(Get-GraphToken)"; 'Content-Type' = 'application/json' }

$appName = 'HSV-Test-Techniker-B'

# Idempotent: reuse if it already exists (e.g. a prior run got interrupted).
$existingApps = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$appName'" -Headers $graphHeaders -Method Get
if ($existingApps.value.Count -gt 0) {
    $app = $existingApps.value[0]
    Write-Output "[VERIFY] Entra app '$appName' already exists (appId=$($app.appId))."
} else {
    $appBody = @{ displayName = $appName } | ConvertTo-Json
    $app = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications" -Headers $graphHeaders -Method Post -Body $appBody
    Write-Output "[CREATE] Entra app '$appName' created (appId=$($app.appId))."
}

$existingSp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($app.appId)'" -Headers $graphHeaders -Method Get
if ($existingSp.value.Count -gt 0) {
    $sp = $existingSp.value[0]
    Write-Output "[VERIFY] Service principal already exists (objectId=$($sp.id))."
} else {
    $spBody = @{ appId = $app.appId } | ConvertTo-Json
    $sp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Headers $graphHeaders -Method Post -Body $spBody
    Write-Output "[CREATE] Service principal created (objectId=$($sp.id))."
}

# --- Dataverse Application User ------------------------------------------
$existingUser = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "systemusers?`$select=systemuserid,fullname&`$filter=applicationid eq $($app.appId)"
if ($existingUser.value.Count -gt 0) {
    $dvUserId = $existingUser.value[0].systemuserid
    Write-Output "[VERIFY] Dataverse Application User already exists (systemuserid=$dvUserId)."
} else {
    $rootBu = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "businessunits?`$select=businessunitid&`$filter=parentbusinessunitid eq null"
    $userBody = @{
        applicationid = $app.appId
        'businessunitid@odata.bind' = "/businessunits($($rootBu.value[0].businessunitid))"
    }
    Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'systemusers' -Body $userBody | Out-Null
    Start-Sleep -Seconds 3  # Dataverse provisions app users asynchronously
    $lookup = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "systemusers?`$select=systemuserid,fullname&`$filter=applicationid eq $($app.appId)"
    $dvUserId = $lookup.value[0].systemuserid
    Write-Output "[CREATE] Dataverse Application User created (systemuserid=$dvUserId)."
}

# --- Assign HSV Techniker role --------------------------------------------
$role = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "roles?`$select=roleid&`$filter=name eq 'HSV Techniker'"
$roleId = $role.value[0].roleid

$currentRoles = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "systemusers($dvUserId)?`$select=fullname&`$expand=systemuserroles_association(`$select=roleid)"
$alreadyAssigned = [bool]($currentRoles.systemuserroles_association | Where-Object { $_.roleid -eq $roleId })

if ($alreadyAssigned) {
    Write-Output "[VERIFY] Role 'HSV Techniker' already assigned to the Application User."
} else {
    $assocBody = @{ '@odata.id' = "$org/api/data/v9.2/roles($roleId)" }
    Invoke-DataverseApi -OrgUrl $org -Method POST -Path "systemusers($dvUserId)/systemuserroles_association/`$ref" -Body $assocBody | Out-Null
    Write-Output "[CREATE] Role 'HSV Techniker' assigned to the Application User."
}

Write-Output ""
Write-Output "=== DONE ==="
Write-Output "AppId (client id):      $($app.appId)"
Write-Output "Service principal id:   $($sp.id)"
Write-Output "Dataverse systemuserid: $dvUserId"
Write-Output ""
Write-Output "Use this systemuserid as the CallerObjectId's *azureactivedirectoryobjectid* for impersonation - see tests/run-access-test.ps1."
