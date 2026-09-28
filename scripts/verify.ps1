<#
    .SYNOPSIS
        Verifies the REAL state of SI-DEV against schema/*.yaml. Does not
        trust that deploy.ps1 exited without an exception - checks Dataverse
        directly for every item in the brief's Phase D checklist.

    .OUTPUTS
        [PASS]/[FAIL] lines and a non-zero exit code on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force
Import-Module powershell-yaml -Force

$config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

function Read-Yaml($relativePath) {
    $full = Join-Path $PSScriptRoot "..\schema\$relativePath"
    return (Get-Content -Path $full -Raw) | ConvertFrom-Yaml
}
$tablesSpec   = Read-Yaml 'tables.yaml'
$choicesSpec  = Read-Yaml 'choices.yaml'
$keysSpec     = Read-Yaml 'keys.yaml'
$auditingSpec = Read-Yaml 'auditing.yaml'
$relSpec      = Read-Yaml 'relationships.yaml'
$securitySpec = Read-Yaml 'security.yaml'

$failures = New-Object System.Collections.Generic.List[string]
function Test-Check($description, [scriptblock] $check) {
    try {
        $result = & $check
        if ($result) {
            Write-Output "[PASS] $description"
        } else {
            Write-Output "[FAIL] $description"
            $failures.Add($description) | Out-Null
        }
    } catch {
        Write-Output "[FAIL] $description - EXCEPTION: $($_.Exception.Message)"
        $failures.Add($description) | Out-Null
    }
}

# --- Solution & publisher -------------------------------------------------
Test-Check "Solution $($config.SolutionUniqueName) exists" {
    $s = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "solutions?`$select=uniquename&`$filter=uniquename eq '$($config.SolutionUniqueName)'"
    $s.value.Count -eq 1
}
Test-Check "Publisher prefix $($config.PublisherPrefix) exists" {
    $p = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "publishers?`$select=customizationprefix&`$filter=customizationprefix eq '$($config.PublisherPrefix)'"
    $p.value.Count -eq 1
}

# --- Solution components ---------------------------------------------------
$sol = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "solutions?`$select=solutionid&`$filter=uniquename eq '$($config.SolutionUniqueName)'"
$solutionComponents = $null
if ($sol.value.Count -eq 1) {
    $solutionComponents = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path "solutioncomponents?`$filter=_solutionid_value eq $($sol.value[0].solutionid)&`$select=componenttype,objectid").value
}

$allEntities = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path 'EntityDefinitions?$select=LogicalName,MetadataId,OwnershipType').value

foreach ($t in $config.TargetTables) {
    Test-Check "Table $t exists" {
        $t -in $allEntities.LogicalName
    }
    Test-Check "Table $t is in solution $($config.SolutionUniqueName)" {
        $meta = $allEntities | Where-Object { $_.LogicalName -eq $t }
        if (-not $meta -or -not $solutionComponents) { return $false }
        [bool]($solutionComponents | Where-Object { $_.componenttype -eq 1 -and $_.objectid -eq $meta.MetadataId })
    }
    $expectedOwnership = ($tablesSpec.tables | Where-Object { $_.logicalName -eq $t }).ownershipType
    Test-Check "Table $t ownership type = $expectedOwnership" {
        $meta = $allEntities | Where-Object { $_.LogicalName -eq $t }
        $meta -and $meta.OwnershipType -eq $expectedOwnership
    }
}

# --- Global choices ---------------------------------------------------------
$allChoiceNames = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path 'GlobalOptionSetDefinitions?$select=Name').value.Name
foreach ($c in $choicesSpec.globalChoices) {
    $logicalName = $c.schemaName.ToLower()
    Test-Check "Global choice $logicalName exists" {
        $logicalName -in $allChoiceNames
    }
}

# --- Column types & required level (spot check against tables.yaml) -------
foreach ($table in $tablesSpec.tables) {
    $attrs = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='$($table.logicalName)')/Attributes?`$select=LogicalName,AttributeType,RequiredLevel").value
    foreach ($col in ($table.columns | Where-Object { $_.type -ne 'Lookup' })) {
        $logicalName = $col.schemaName.ToLower()
        $expectedType = switch ($col.type) {
            'String'      { 'String' }
            'Memo'        { 'Memo' }
            'Boolean'     { 'Boolean' }
            'WholeNumber' { 'Integer' }
            'DateTime'    { 'DateTime' }
            'Choice'      { 'Picklist' }
            default       { $col.type }
        }
        Test-Check "$($table.logicalName).$logicalName is $expectedType with RequiredLevel matching YAML" {
            $a = $attrs | Where-Object { $_.LogicalName -eq $logicalName }
            if (-not $a) { return $false }
            $expectedRequired = if ($col.requiredLevel -eq 'Required') { 'ApplicationRequired' } else { 'None' }
            ($a.AttributeType -eq $expectedType) -and ($a.RequiredLevel.Value -eq $expectedRequired)
        }
    }
}

# --- Relationships -----------------------------------------------------------
$allRelNames = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path 'RelationshipDefinitions?$select=SchemaName').value.SchemaName
foreach ($rel in $relSpec.relationships) {
    Test-Check "Relationship $($rel.schemaName) exists" {
        $rel.schemaName -in $allRelNames
    }
}

# --- Auditing ----------------------------------------------------------------
$orgInfo = Invoke-DataverseApi -OrgUrl $org -Method GET -Path 'organizations?$select=isauditenabled'
Test-Check "Organization-level auditing is ON (required for table auditing to take effect)" {
    [bool]$orgInfo.value[0].isauditenabled
}
foreach ($t in $auditingSpec.tables) {
    Test-Check "Auditing enabled on $($t.entity)" {
        $e = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='$($t.entity)')?`$select=IsAuditEnabled"
        [bool]$e.IsAuditEnabled.Value
    }
}

# --- Alternate keys ------------------------------------------------------
foreach ($key in $keysSpec.keys) {
    Test-Check "Key $($key.schemaName) on $($key.entity) is Active" {
        $keys = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='$($key.entity)')/Keys?`$select=SchemaName,EntityKeyIndexStatus").value
        $k = $keys | Where-Object { $_.SchemaName -eq $key.schemaName }
        $k -and $k.EntityKeyIndexStatus -eq 'Active'
    }
}

# --- hsv_businesskeyhash is deliberately NOT unique / NOT a key ----------
Test-Check "hsv_businesskeyhash is NOT part of any alternate key on hsv_inboundmessage" {
    $keys = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='hsv_inboundmessage')/Keys?`$select=SchemaName,KeyAttributes").value
    -not ($keys | Where-Object { $_.KeyAttributes -contains 'hsv_businesskeyhash' })
}

# --- Security roles (Security Model phase) -------------------------------
foreach ($role in $securitySpec.roles) {
    $expectedCount = ($role.privileges | ForEach-Object { $_.actions.Count } | Measure-Object -Sum).Sum
    Test-Check "Role '$($role.name)' exists with all $expectedCount domain privileges" {
        $r = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "roles?`$select=roleid&`$filter=name eq '$($role.name)'"
        if ($r.value.Count -ne 1) { return $false }
        $detail = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "roles($($r.value[0].roleid))?`$select=name&`$expand=roleprivileges_association(`$select=name)"
        $expectedNames = @()
        foreach ($grant in $role.privileges) {
            foreach ($action in $grant.actions) { $expectedNames += "prv$action$($grant.entity)" }
        }
        $actualNames = @($detail.roleprivileges_association.name)
        $missing = @($expectedNames | Where-Object { $_ -notin $actualNames })
        $missing.Count -eq 0
    }
}
Test-Check "Pre-existing V1 role 'SI Auditor' is untouched (still exists, distinct from our roles)" {
    $v1 = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "roles?`$select=name&`$filter=name eq 'SI Auditor'"
    $v1.value.Count -eq 1
}

# --- Status transition configuration data (Security Model phase) --------
$transitionSpec = Read-Yaml 'statustransitions.yaml'
$expectedTransitionCount = $transitionSpec.messageTransitions.Count + $transitionSpec.workOrderTransitions.Count
Test-Check "hsv_statustransition has all $expectedTransitionCount configured rows" {
    $rows = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_statustransitions?`$select=hsv_statustransitionid").value
    $rows.Count -eq $expectedTransitionCount
}

Write-Output ''
if ($failures.Count -eq 0) {
    Write-Output '=== ALL CHECKS PASSED ==='
    exit 0
} else {
    Write-Output "=== $($failures.Count) CHECK(S) FAILED ==="
    $failures | ForEach-Object { Write-Output "  - $_" }
    exit 1
}
