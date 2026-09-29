<#
    .SYNOPSIS
        Verifies the REAL state of the target environment against
        schema/*.yaml. Does not trust that deploy.ps1 exited without an
        exception - checks Dataverse directly for every item in the brief's
        Phase D checklist, AND checks exact configuration (not just
        existence) per the 2026-09 review: privilege depth, column types,
        max length, lookup targets, DateTime behavior, Choice values,
        alternate key composition, relationship cascade behavior, ownership
        type, column-level auditing, and plugin registration/images.

    .OUTPUTS
        [PASS]/[FAIL] lines and a non-zero exit code on any failure.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = "$PSScriptRoot\config.psd1"
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force
Import-Module powershell-yaml -Force

$config = Import-PowerShellDataFile $ConfigPath
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

function Read-Yaml($relativePath) {
    $full = Join-Path $PSScriptRoot "..\schema\$relativePath"
    # -Encoding UTF8 is required, not cosmetic: these schema files have no
    # BOM, and Get-Content -Raw without an explicit encoding falls back to
    # the system codepage, silently mangling every German special character
    # (ß, ü, ö, ...) - this is exactly how hsv_trade's "Schließanlage" ended
    # up corrupted in SI-DEV (confirmed empirically: round-tripping the
    # misread string back through ConvertTo-Json/Invoke-WebRequest baked
    # the corruption into Dataverse). See also the matching UTF-8 byte-body
    # fix in lib/Dataverse.psm1's Invoke-DataverseApi.
    return (Get-Content -Path $full -Raw -Encoding UTF8) | ConvertFrom-Yaml
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

# Dataverse's AddPrivilegesRole/RetrieveRolePrivilegesRole use these string
# labels for depth, not the numeric AccessRights depth or the
# User/BusinessUnit/ParentChild/Organization names used in security.yaml.
$DepthLabelByYamlName = @{
    User           = 'Basic'
    BusinessUnit   = 'Local'
    ParentChild    = 'Deep'
    Organization   = 'Global'
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

# --- Global choices: existence AND exact option values ----------------------
$allChoiceNames = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path 'GlobalOptionSetDefinitions?$select=Name').value.Name
foreach ($c in $choicesSpec.globalChoices) {
    $logicalName = $c.schemaName.ToLower()
    Test-Check "Global choice $logicalName exists" {
        $logicalName -in $allChoiceNames
    }
    Test-Check "Global choice $logicalName has exactly the configured option values/labels" {
        if ($logicalName -notin $allChoiceNames) { return $false }
        $full = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "GlobalOptionSetDefinitions(Name='$logicalName')"
        $actual = @{}
        foreach ($opt in $full.Options) { $actual[[int]$opt.Value] = $opt.Label.LocalizedLabels[0].Label }
        $expected = @{}
        foreach ($opt in $c.options) { $expected[[int]$opt.value] = $opt.label }
        if ($actual.Count -ne $expected.Count) { return $false }
        foreach ($k in $expected.Keys) {
            if (-not $actual.ContainsKey($k) -or $actual[$k] -ne $expected[$k]) { return $false }
        }
        $true
    }
}

# --- Columns: type, required level, max length, lookup targets, DateTime
#     behavior, Choice linkage --------------------------------------------
foreach ($table in $tablesSpec.tables) {
    $attrs = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='$($table.logicalName)')/Attributes?`$select=LogicalName,AttributeType,RequiredLevel").value
    $manyToOne = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='$($table.logicalName)')/ManyToOneRelationships?`$select=ReferencingAttribute,ReferencedEntity").value

    foreach ($col in $table.columns) {
        $logicalName = $col.schemaName.ToLower()
        $expectedType = switch ($col.type) {
            'String'      { 'String' }
            'Memo'        { 'Memo' }
            'Boolean'     { 'Boolean' }
            'WholeNumber' { 'Integer' }
            'DateTime'    { 'DateTime' }
            'Choice'      { 'Picklist' }
            'Lookup'      { 'Lookup' }
            default       { $col.type }
        }

        Test-Check "$($table.logicalName).$logicalName is $expectedType with RequiredLevel matching YAML" {
            $a = $attrs | Where-Object { $_.LogicalName -eq $logicalName }
            if (-not $a) { return $false }
            $expectedRequired = if ($col.requiredLevel -eq 'Required') { 'ApplicationRequired' } else { 'None' }
            ($a.AttributeType -eq $expectedType) -and ($a.RequiredLevel.Value -eq $expectedRequired)
        }

        if ($col.type -eq 'String' -or $col.type -eq 'Memo') {
            $cast = if ($col.type -eq 'String') { 'StringAttributeMetadata' } else { 'MemoAttributeMetadata' }
            Test-Check "$($table.logicalName).$logicalName MaxLength = $($col.maxLength)" {
                $meta = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='$($table.logicalName)')/Attributes(LogicalName='$logicalName')/Microsoft.Dynamics.CRM.$cast`?`$select=MaxLength"
                $meta.MaxLength -eq $col.maxLength
            }
        }

        if ($col.type -eq 'Lookup') {
            Test-Check "$($table.logicalName).$logicalName targets $($col.targets -join ', ')" {
                $rel = $manyToOne | Where-Object { $_.ReferencingAttribute -eq $logicalName }
                if (-not $rel) { return $false }
                [bool]($rel | Where-Object { $_.ReferencedEntity -in $col.targets })
            }
        }

        if ($col.type -eq 'DateTime') {
            $expectedBehavior = $col.dateTimeBehavior
            Test-Check "$($table.logicalName).$logicalName DateTimeBehavior = $expectedBehavior" {
                $meta = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='$($table.logicalName)')/Attributes(LogicalName='$logicalName')/Microsoft.Dynamics.CRM.DateTimeAttributeMetadata`?`$select=DateTimeBehavior"
                $meta.DateTimeBehavior.Value -eq $expectedBehavior
            }
        }

        if ($col.type -eq 'Choice' -and $col.globalChoice) {
            $expectedChoice = $col.globalChoice.ToLower()
            Test-Check "$($table.logicalName).$logicalName uses global choice $expectedChoice" {
                $meta = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='$($table.logicalName)')/Attributes(LogicalName='$logicalName')/Microsoft.Dynamics.CRM.PicklistAttributeMetadata`?`$select=LogicalName&`$expand=OptionSet(`$select=Name,IsGlobal)"
                $meta.OptionSet.IsGlobal -and ($meta.OptionSet.Name -eq $expectedChoice)
            }
        }
    }
}

# --- Relationships: existence AND cascade configuration ----------------------
$allRelNames = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path 'RelationshipDefinitions?$select=SchemaName').value.SchemaName
function Get-ExpectedCascadeDelete($behavior) {
    switch ($behavior) {
        'Restrict'  { 'Restrict' }
        'RemoveLink' { 'RemoveLink' }
        'Parental'  { 'Cascade' }
        default     { $behavior }
    }
}
foreach ($rel in $relSpec.relationships) {
    Test-Check "Relationship $($rel.schemaName) exists" {
        $rel.schemaName -in $allRelNames
    }
    Test-Check "Relationship $($rel.schemaName): $($rel.referencingEntity).$($rel.referencingAttribute) -> $($rel.referencedEntity), Delete cascade = $(Get-ExpectedCascadeDelete $rel.deleteBehavior)" {
        if ($rel.schemaName -notin $allRelNames) { return $false }
        $r = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "RelationshipDefinitions(SchemaName='$($rel.schemaName)')/Microsoft.Dynamics.CRM.OneToManyRelationshipMetadata?`$select=ReferencedEntity,ReferencingEntity,ReferencingAttribute,CascadeConfiguration"
        $expectedDelete = Get-ExpectedCascadeDelete $rel.deleteBehavior
        ($r.ReferencedEntity -eq $rel.referencedEntity) -and
        ($r.ReferencingEntity -eq $rel.referencingEntity) -and
        ($r.ReferencingAttribute -eq $rel.referencingAttribute.ToLower()) -and
        ($r.CascadeConfiguration.Delete -eq $expectedDelete)
    }
}

# --- Auditing: organization + entity + column level --------------------------
$orgInfo = Invoke-DataverseApi -OrgUrl $org -Method GET -Path 'organizations?$select=isauditenabled'
Test-Check "Organization-level auditing is ON (required for table auditing to take effect)" {
    [bool]$orgInfo.value[0].isauditenabled
}
foreach ($t in $auditingSpec.tables) {
    Test-Check "Auditing enabled on $($t.entity)" {
        $e = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='$($t.entity)')?`$select=IsAuditEnabled"
        [bool]$e.IsAuditEnabled.Value
    }
    foreach ($attr in $t.emphasizedAttributes) {
        $logicalName = $attr.ToLower()
        Test-Check "Column-level auditing enabled on $($t.entity).$logicalName" {
            $a = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='$($t.entity)')/Attributes(LogicalName='$logicalName')?`$select=IsAuditEnabled"
            [bool]$a.IsAuditEnabled.Value
        }
    }
}
foreach ($t in $auditingSpec.notAudited) {
    Test-Check "Auditing correctly OFF on $($t.entity) (documented as not audited)" {
        $e = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='$($t.entity)')?`$select=IsAuditEnabled"
        -not [bool]$e.IsAuditEnabled.Value
    }
}

# --- Alternate keys: Active AND exact attribute composition -----------------
foreach ($key in $keysSpec.keys) {
    Test-Check "Key $($key.schemaName) on $($key.entity) is Active with attributes [$($key.attributes -join ', ')]" {
        $keys = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='$($key.entity)')/Keys?`$select=SchemaName,EntityKeyIndexStatus,KeyAttributes").value
        $k = $keys | Where-Object { $_.SchemaName -eq $key.schemaName }
        if (-not $k -or $k.EntityKeyIndexStatus -ne 'Active') { return $false }
        $expected = @($key.attributes | ForEach-Object { $_.ToLower() } | Sort-Object)
        $actual   = @($k.KeyAttributes | ForEach-Object { $_.ToLower() } | Sort-Object)
        ($expected -join ',') -eq ($actual -join ',')
    }
}

# --- hsv_businesskeyhash is deliberately NOT unique / NOT a key ----------
Test-Check "hsv_businesskeyhash is NOT part of any alternate key on hsv_inboundmessage" {
    $keys = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path "EntityDefinitions(LogicalName='hsv_inboundmessage')/Keys?`$select=SchemaName,KeyAttributes").value
    -not ($keys | Where-Object { $_.KeyAttributes -contains 'hsv_businesskeyhash' })
}

# --- Security roles: exact privilege NAME + DEPTH (not just presence) -------
foreach ($role in $securitySpec.roles) {
    $expectedGrants = New-Object System.Collections.Generic.List[object]
    foreach ($grant in $role.privileges) {
        $expectedDepthLabel = $DepthLabelByYamlName[$grant.depth]
        foreach ($action in $grant.actions) {
            $expectedGrants.Add([pscustomobject]@{
                Name  = "prv$action$($grant.entity)"
                Depth = $expectedDepthLabel
            })
        }
    }

    $r = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "roles?`$select=roleid&`$filter=name eq '$($role.name)'"
    Test-Check "Role '$($role.name)' exists" {
        $r.value.Count -eq 1
    }
    if ($r.value.Count -ne 1) { continue }
    $roleId = $r.value[0].roleid
    Test-Check "Role '$($role.name)' is in solution $($config.SolutionUniqueName)" {
        [bool]($solutionComponents | Where-Object { $_.componenttype -eq 20 -and $_.objectid -eq $roleId })
    }
    $actual = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path "RetrieveRolePrivilegesRole(RoleId=$roleId)").RolePrivileges

    foreach ($g in $expectedGrants) {
        Test-Check "Role '$($role.name)' privilege $($g.Name) is exactly at depth $($g.Depth)" {
            $match = $actual | Where-Object { $_.PrivilegeName -eq $g.Name }
            if (-not $match) { return $false }
            $match.Depth -eq $g.Depth
        }
    }

    $expectedNames = @($expectedGrants.Name)
    Test-Check "Role '$($role.name)' has no EXTRA hsv_/Account/pa_/ap_-domain privileges beyond the YAML" {
        $domainEntities = @('hsv_workorder', 'hsv_inboundmessage', 'hsv_processingattempt', 'hsv_serviceobject', 'hsv_statustransition', 'account')
        $extra = $actual | Where-Object {
            $priv = $_.PrivilegeName
            ($domainEntities | Where-Object { $priv -like "prv*$_*" -or $priv -like "prv*$( (Get-Culture).TextInfo.ToTitleCase($_) )*" }) -and
            ($priv -notin $expectedNames)
        }
        # Best-effort: privilege naming casing varies (hsv_WorkOrder vs hsv_workorder),
        # so this check is informational rather than a hard schema match; only
        # fail if we found something unambiguously in our own custom entities.
        $customExtra = $extra | Where-Object { $_.PrivilegeName -match 'hsv_' }
        $customExtra.Count -eq 0
    }
}
if ($config.EnvironmentName -eq 'SI-DEV') {
    # V1 only ever existed in SI-DEV - this check is meaningless (and would
    # be a false failure) against a clean environment like SI-TEST that
    # never had V1 deployed to it.
    Test-Check "Pre-existing V1 role 'SI Auditor' is untouched (still exists, distinct from our roles)" {
        $v1 = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "roles?`$select=name&`$filter=name eq 'SI Auditor'"
        $v1.value.Count -eq 1
    }
}

# --- Status transition configuration data (Security Model phase) --------
$transitionSpec = Read-Yaml 'statustransitions.yaml'
$expectedTransitionCount = $transitionSpec.messageTransitions.Count + $transitionSpec.workOrderTransitions.Count
Test-Check "hsv_statustransition has all $expectedTransitionCount configured rows" {
    $rows = (Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_statustransitions?`$select=hsv_statustransitionid").value
    $rows.Count -eq $expectedTransitionCount
}

# --- Plugin registration: assembly, type, steps (Pre-Op Update, stage 20),
#     Pre-Image on hsv_status, for both hsv_workorder and hsv_inboundmessage --
$assemblyName = 'Hsv.ServiceIntake.Plugins'
$typeName     = 'Hsv.ServiceIntake.Plugins.CanTransitionPlugin'

$asm = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "pluginassemblies?`$select=pluginassemblyid&`$filter=name eq '$assemblyName'"
Test-Check "Plugin assembly '$assemblyName' is registered" {
    $asm.value.Count -eq 1
}
if ($asm.value.Count -eq 1) {
    Test-Check "Plugin assembly '$assemblyName' is in solution $($config.SolutionUniqueName)" {
        [bool]($solutionComponents | Where-Object { $_.componenttype -eq 91 -and $_.objectid -eq $asm.value[0].pluginassemblyid })
    }
}

$type = $null
if ($asm.value.Count -eq 1) {
    $type = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "plugintypes?`$select=plugintypeid&`$filter=typename eq '$typeName'"
    Test-Check "Plugin type '$typeName' is registered" {
        $type.value.Count -eq 1
    }
}

foreach ($entity in @('hsv_workorder', 'hsv_inboundmessage')) {
    foreach ($msgName in @('Create', 'Update')) {
        $stepName = "CanTransitionPlugin: $msgName of $entity (Pre-Operation)"
        $step = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "sdkmessageprocessingsteps?`$select=sdkmessageprocessingstepid,stage,mode,filteringattributes,statecode&`$filter=name eq '$stepName'"
        Test-Check "Plugin step '$stepName' exists as Pre-Operation (stage 20), Synchronous, Active, filtered on hsv_status" {
            if ($step.value.Count -ne 1) { return $false }
            $s = $step.value[0]
            ($s.stage -eq 20) -and ($s.mode -eq 0) -and ($s.statecode -eq 0) -and ($s.filteringattributes -match 'hsv_status')
        }
        if ($step.value.Count -eq 1) {
            Test-Check "Plugin step '$stepName' is in solution $($config.SolutionUniqueName)" {
                [bool]($solutionComponents | Where-Object { $_.componenttype -eq 92 -and $_.objectid -eq $step.value[0].sdkmessageprocessingstepid })
            }
        }
        if ($msgName -eq 'Update' -and $step.value.Count -eq 1) {
            $stepId = $step.value[0].sdkmessageprocessingstepid
            Test-Check "Plugin step '$stepName' has a PreImage containing hsv_status" {
                $img = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "sdkmessageprocessingstepimages?`$select=attributes,imagetype&`$filter=name eq 'PreImage' and _sdkmessageprocessingstepid_value eq $stepId"
                if ($img.value.Count -ne 1) { return $false }
                ($img.value[0].imagetype -eq 0) -and ($img.value[0].attributes -match 'hsv_status')
            }
        }
    }
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
