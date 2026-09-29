<#
    .SYNOPSIS
        Creates the 4 Security Roles for Service Intake V2 from
        schema/security.yaml. Same idempotent Exists/Missing/Different
        pattern as deploy.ps1: safe to re-run, never touches the
        pre-existing V1 role "SI Auditor" (different name, never matched).

    .PARAMETER DryRun
        Plan only. No writes.

    .PARAMETER Apply
        Create the roles and assign privileges in SI-DEV.

    .PARAMETER OnlyRoles
        Optional array to scope a run to specific role names.
#>
[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [Parameter(ParameterSetName = 'DryRun')] [switch] $DryRun,
    [Parameter(ParameterSetName = 'Apply')] [switch] $Apply,
    [string[]] $OnlyRoles,
    [string] $ConfigPath = "$PSScriptRoot\config.psd1"
)

$ErrorActionPreference = 'Stop'
if (-not $DryRun -and -not $Apply) {
    throw "Specify either -DryRun or -Apply."
}

Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force
Import-Module powershell-yaml -Force

$config = Import-PowerShellDataFile $ConfigPath
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

$securitySpec = (Get-Content -Path "$PSScriptRoot\..\schema\security.yaml" -Raw -Encoding UTF8) | ConvertFrom-Yaml

# PrivilegeDepth is a string enum in the Web API ("Basic"/"Local"/"Deep"/
# "Global"), not the numeric 1-4 shown in most human-readable docs/UI -
# confirmed empirically (a numeric Depth 400s: "Cannot read the value '1' as
# a quoted JSON string value").
$depthMap = @{ User = 'Basic'; BusinessUnit = 'Local'; ParentChild = 'Deep'; Organization = 'Global' }

function Get-DataversePrivilegeId {
    param([string] $Entity, [string] $Action, [hashtable] $Cache)
    $privName = "prv$Action$Entity"
    if ($Cache.ContainsKey($privName)) { return $Cache[$privName] }
    throw "Privilege '$privName' not found - was it queried into the cache? Check the entity/action spelling in schema/security.yaml."
}

# Preload every privilege this file could need, once.
$entities = $securitySpec.roles.privileges.entity | Select-Object -Unique
$privCache = @{}
foreach ($e in $entities) {
    $p = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "privileges?`$select=name,privilegeid&`$filter=contains(name,'$e')"
    foreach ($item in $p.value) { $privCache[$item.name] = $item.privilegeid }
}

$rootBu = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "businessunits?`$select=businessunitid&`$filter=parentbusinessunitid eq null"
$rootBuId = $rootBu.value[0].businessunitid

$existingRoles = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "roles?`$select=name,roleid"

# Role's solution component type. Roles were originally created via plain
# POST without MSCRM.SolutionUniqueName, so none of the 4 ended up IN the
# solution at all (review item 8) - verify.ps1 never caught it because it
# only checked "does the role exist", not solution membership. Fixed below:
# every role this script touches gets an explicit AddSolutionComponent call,
# which is safe to repeat (Dataverse no-ops if it's already a member).
$RoleComponentType = 20
$sol = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "solutions?`$select=solutionid&`$filter=uniquename eq '$($config.SolutionUniqueName)'"
$solutionId = $sol.value[0].solutionid
function Add-ToSolutionIfMissing {
    param([string] $ComponentId, [int] $ComponentType, [string] $Label)
    $existingComponent = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "solutioncomponents?`$filter=_solutionid_value eq $solutionId and componenttype eq $ComponentType and objectid eq $ComponentId&`$select=solutioncomponentid"
    if ($existingComponent.value.Count -gt 0) {
        Write-Output "[VERIFY] $Label already in solution $($config.SolutionUniqueName)."
        return
    }
    Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'AddSolutionComponent' -Body @{
        ComponentId        = $ComponentId
        ComponentType      = $ComponentType
        SolutionUniqueName = $config.SolutionUniqueName
        AddRequiredComponents = $false
    } | Out-Null
    Write-Output "[CREATE] $Label added to solution $($config.SolutionUniqueName)."
}

$rolesToProcess = $securitySpec.roles
if ($OnlyRoles) { $rolesToProcess = $securitySpec.roles | Where-Object { $_.name -in $OnlyRoles } }

foreach ($role in $rolesToProcess) {
    $existing = $existingRoles.value | Where-Object { $_.name -eq $role.name }
    $totalPrivs = ($role.privileges | ForEach-Object { $_.actions.Count } | Measure-Object -Sum).Sum

    $roleId = $null
    if ($existing) {
        $roleId = $existing.roleid
        # Resumability: a role can exist without OUR privileges assigned yet
        # if a prior run created the role record and then failed on
        # AddPrivilegesRole (happened once during development). Note: every
        # new role gets ~9 baseline privileges from Dataverse itself
        # (SharePoint integration, SDK message read, etc.) regardless of
        # what we ask for - so "privilege count > 0" is not a valid "already
        # done" signal. Check specifically for one of our own target
        # privilege names instead.
        $detail = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "roles($roleId)?`$select=name&`$expand=roleprivileges_association(`$select=name)"
        $currentNames = @($detail.roleprivileges_association.name)
        $ourFirstAction = $role.privileges[0].actions[0]
        $ourFirstEntity = $role.privileges[0].entity
        $ourMarkerPriv = "prv$ourFirstAction$ourFirstEntity"
        if ($ourMarkerPriv -in $currentNames) {
            Write-Output "[VERIFY] Role '$($role.name)': already exists with our privileges assigned ($($currentNames.Count) total incl. Dataverse defaults) - diff not checked by this pass."
            if ($Apply) { Add-ToSolutionIfMissing -ComponentId $roleId -ComponentType $RoleComponentType -Label "Role '$($role.name)'" }
            continue
        }
        Write-Output "[CREATE] Role '$($role.name)': exists but our privileges aren't assigned yet (resuming an interrupted run) - assigning $totalPrivs privilege grants."
    } else {
        Write-Output "[CREATE] Role '$($role.name)': $totalPrivs privilege grants across $($role.privileges.Count) entities."
    }
    if (-not $Apply) { continue }

    if (-not $roleId) {
        $roleBody = @{
            name = $role.name
            'businessunitid@odata.bind' = "/businessunits($rootBuId)"
        }
        Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'roles' -Body $roleBody | Out-Null
        # Dataverse doesn't return the created record body by default for
        # this call in our wrapper (no Prefer header) - look it up by name.
        $lookup = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "roles?`$select=roleid&`$filter=name eq '$($role.name)'"
        $roleId = $lookup.value[0].roleid
        Write-Output "[CREATE] Role '$($role.name)' created (roleid $roleId)."
    }

    Add-ToSolutionIfMissing -ComponentId $roleId -ComponentType $RoleComponentType -Label "Role '$($role.name)'"

    $rolePrivileges = New-Object System.Collections.Generic.List[object]
    foreach ($grant in $role.privileges) {
        $depth = $depthMap[$grant.depth]
        foreach ($action in $grant.actions) {
            $privId = Get-DataversePrivilegeId -Entity $grant.entity -Action $action -Cache $privCache
            $rolePrivileges.Add(@{
                '@odata.type' = 'Microsoft.Dynamics.CRM.RolePrivilege'
                PrivilegeId   = $privId
                Depth         = $depth
            }) | Out-Null
        }
    }

    $addBody = @{ Privileges = $rolePrivileges }
    Invoke-DataverseApi -OrgUrl $org -Method POST -Path "roles($roleId)/Microsoft.Dynamics.CRM.AddPrivilegesRole" -Body $addBody | Out-Null
    Write-Output "[CREATE] Role '$($role.name)': $($rolePrivileges.Count) privileges assigned."
}
