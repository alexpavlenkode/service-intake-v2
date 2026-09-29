<#
    .SYNOPSIS
        Phase A discovery: inventories SI-DEV for anything relevant to
        Service Intake V2 before a single component is created. Read-only —
        issues no write/metadata-changing calls.

    .OUTPUTS
        Writes docs/discovery-report.md and returns a PSCustomObject with the
        raw findings (used by deploy.ps1 -DryRun).
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = "$PSScriptRoot\config.psd1"
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force

$config = Import-PowerShellDataFile $ConfigPath
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

Write-Output "[DISCOVER] Connected. Starting inventory of $($config.EnvironmentName)..."

# --- Publishers -------------------------------------------------------
$publishers = Invoke-DataverseApi -OrgUrl $org -Method GET `
    -Path "publishers?`$select=uniquename,customizationprefix,customizationoptionvalueprefix,friendlyname,publisherid&`$filter=customizationprefix eq '$($config.PublisherPrefix)'"
Write-Output "[DISCOVER] Publishers with prefix '$($config.PublisherPrefix)': $($publishers.value.Count)"

$allPublishers = Invoke-DataverseApi -OrgUrl $org -Method GET `
    -Path "publishers?`$select=uniquename,customizationprefix,customizationoptionvalueprefix,friendlyname&`$filter=isreadonly eq false"

# --- Solutions ----------------------------------------------------------
$solutions = Invoke-DataverseApi -OrgUrl $org -Method GET `
    -Path "solutions?`$select=uniquename,friendlyname,version,ismanaged&`$filter=isvisible eq true"
$targetSolution = $solutions.value | Where-Object { $_.uniquename -eq $config.SolutionUniqueName }
Write-Output "[DISCOVER] Solutions visible: $($solutions.value.Count). Target solution '$($config.SolutionUniqueName)' exists: $([bool]$targetSolution)"

# --- All entity metadata, fetched once and reused below -----------------
# Note: the EntityDefinitions metadata endpoint returns HTTP 501 for
# startswith()/$filter on LogicalName (limited OData support on metadata
# entity sets) - fetch everything and filter client-side instead.
$allEntities = Invoke-DataverseApi -OrgUrl $org -Method GET `
    -Path "EntityDefinitions?`$select=LogicalName,SchemaName,DisplayName,OwnershipType,IsCustomEntity,MetadataId"
$hsvTablesList = @($allEntities.value | Where-Object { $_.LogicalName -like 'hsv_*' })
$hsvTables = [PSCustomObject]@{ value = $hsvTablesList }
Write-Output "[DISCOVER] Existing tables with hsv_ prefix: $($hsvTables.value.Count)"

# Any solution whose name suggests it's a prior ("V1") Service Intake build,
# so it gets flagged even though it won't match our exact unique name. Its
# actual tables are resolved via solutioncomponents (componenttype 1 =
# Entity), not by guessing a prefix from the publisher - a solution can (and
# here does) span more than one publisher/prefix.
$suspectedV1Solutions = @($solutions.value | Where-Object {
    $_.uniquename -ne $config.SolutionUniqueName -and
    ($_.uniquename -match 'ServiceIntake|Intake' -or $_.friendlyname -match 'Service Intake|Intake')
})
$suspectedV1Details = @()
foreach ($s in $suspectedV1Solutions) {
    $detail = Invoke-DataverseApi -OrgUrl $org -Method GET `
        -Path "solutions?`$select=solutionid,uniquename,friendlyname,version&`$filter=uniquename eq '$($s.uniquename)'&`$expand=publisherid(`$select=customizationprefix,friendlyname,uniquename)"
    $sol = $detail.value[0]

    $comps = Invoke-DataverseApi -OrgUrl $org -Method GET `
        -Path "solutioncomponents?`$filter=_solutionid_value eq $($sol.solutionid)&`$select=componenttype,objectid"
    $entityIds = @(($comps.value | Where-Object { $_.componenttype -eq 1 }).objectid)
    $entityTables = @($allEntities.value | Where-Object { $_.MetadataId -in $entityIds -and $_.IsCustomEntity })

    $sol | Add-Member -NotePropertyName CustomTables -NotePropertyValue $entityTables
    $sol | Add-Member -NotePropertyName ComponentCount -NotePropertyValue $comps.value.Count
    $suspectedV1Details += $sol
}
if ($suspectedV1Details.Count -gt 0) {
    Write-Output "[DISCOVER] Solutions that look like a prior/V1 build: $($suspectedV1Details.Count)"
    foreach ($d in $suspectedV1Details) {
        Write-Output "  - $($d.uniquename) ('$($d.friendlyname)'), $($d.ComponentCount) components, custom tables: $($d.CustomTables.LogicalName -join ', ')"
    }
}

$targetTableStatus = @{}
foreach ($t in $config.TargetTables) {
    $existing = $hsvTables.value | Where-Object { $_.LogicalName -eq $t }
    $targetTableStatus[$t] = $existing
}

# --- Global choices with hsv_ prefix ------------------------------------
$allChoices = Invoke-DataverseApi -OrgUrl $org -Method GET `
    -Path "GlobalOptionSetDefinitions?`$select=Name,DisplayName"
$hsvChoicesList = @($allChoices.value | Where-Object { $_.Name -like 'hsv_*' })
$hsvChoices = [PSCustomObject]@{ value = $hsvChoicesList }
Write-Output "[DISCOVER] Existing global choices with hsv_ prefix: $($hsvChoices.value.Count)"

$targetChoiceStatus = @{}
foreach ($c in $config.TargetGlobalChoices) {
    $existing = $hsvChoices.value | Where-Object { $_.Name -eq $c }
    $targetChoiceStatus[$c] = $existing
}

# --- Relationships / keys on any existing hsv_ tables -------------------
$relationshipsByTable = @{}
$keysByTable = @{}
foreach ($t in $hsvTables.value) {
    $rels = Invoke-DataverseApi -OrgUrl $org -Method GET `
        -Path "EntityDefinitions(LogicalName='$($t.LogicalName)')/OneToManyRelationships?`$select=SchemaName,ReferencedEntity,ReferencingEntity"
    $relationshipsByTable[$t.LogicalName] = $rels.value

    $keys = Invoke-DataverseApi -OrgUrl $org -Method GET `
        -Path "EntityDefinitions(LogicalName='$($t.LogicalName)')/Keys?`$select=SchemaName,KeyAttributes,EntityKeyIndexStatus"
    $keysByTable[$t.LogicalName] = $keys.value
}

# --- Base language code (needed for label metadata in later phases) ----
$baseLangCode = Get-DataverseBaseLanguageCode -OrgUrl $org
Write-Output "[DISCOVER] Base language code: $baseLangCode"

$result = [PSCustomObject]@{
    Publishers            = $allPublishers.value
    PublisherPrefixTaken  = ($publishers.value.Count -gt 0)
    PublisherPrefixOwner  = $publishers.value
    Solutions             = $solutions.value
    TargetSolutionExists  = [bool]$targetSolution
    TargetSolution        = $targetSolution
    HsvTables             = $hsvTables.value
    TargetTableStatus     = $targetTableStatus
    HsvChoices            = $hsvChoices.value
    TargetChoiceStatus    = $targetChoiceStatus
    RelationshipsByTable  = $relationshipsByTable
    KeysByTable           = $keysByTable
    BaseLanguageCode      = $baseLangCode
}

# --- Write docs/discovery-report.md -------------------------------------
$reportFileName = if ($config.EnvironmentName -eq 'SI-DEV') { 'discovery-report.md' } else { "discovery-report.$($config.EnvironmentName).md" }
$reportPath = Join-Path $PSScriptRoot "..\docs\$reportFileName"
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Discovery Report — SI-DEV")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Generated by ``scripts/discover.ps1`` on $(Get-Date -Format 'yyyy-MM-dd HH:mm') (local).")
[void]$sb.AppendLine("Read-only inventory. Nothing was created, changed, or deleted.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("## Environment")
[void]$sb.AppendLine("- Environment: **$($config.EnvironmentName)**")
[void]$sb.AppendLine("- Org URL: $org")
[void]$sb.AppendLine("- Base language code: $baseLangCode")
[void]$sb.AppendLine()

[void]$sb.AppendLine("## EXISTS AND CAN BE REUSED")
[void]$sb.AppendLine()
if ($publishers.value.Count -gt 0) {
    foreach ($p in $publishers.value) {
        [void]$sb.AppendLine("- Publisher **$($p.uniquename)** already uses prefix ``$($config.PublisherPrefix)`` (optionvalueprefix $($p.customizationoptionvalueprefix)). Reuse it; do not create a second publisher with the same prefix.")
    }
} else {
    [void]$sb.AppendLine("- No publisher with prefix ``$($config.PublisherPrefix)`` exists yet. Nothing to reuse here — Phase B creates it.")
}
if ($targetSolution) {
    [void]$sb.AppendLine("- Solution **$($config.SolutionUniqueName)** already exists (version $($targetSolution.version)). Reuse it, do not recreate.")
}
[void]$sb.AppendLine()

[void]$sb.AppendLine("## CONFLICT")
[void]$sb.AppendLine()
$anyConflict = $false
foreach ($t in $config.TargetTables) {
    $existing = $targetTableStatus[$t]
    if ($existing) {
        $anyConflict = $true
        [void]$sb.AppendLine("- Table ``$t`` already exists (SchemaName: $($existing.SchemaName), Ownership: $($existing.OwnershipType)). MUST be reviewed by hand before Phase B touches it — this script will not assume it's compatible.")
    }
}
foreach ($c in $config.TargetGlobalChoices) {
    $existing = $targetChoiceStatus[$c]
    if ($existing) {
        $anyConflict = $true
        [void]$sb.AppendLine("- Global choice ``$c`` already exists. Review its values against ``docs/03-datenmodell.md`` §5 before reuse.")
    }
}
if (-not $anyConflict) {
    [void]$sb.AppendLine("- None found. All five target schema names and all seven target global choices are free.")
}
[void]$sb.AppendLine()

[void]$sb.AppendLine("## OLD V1 COMPONENT")
[void]$sb.AppendLine()
if ($suspectedV1Details.Count -gt 0) {
    foreach ($d in $suspectedV1Details) {
        [void]$sb.AppendLine("- Solution **$($d.uniquename)** ('$($d.friendlyname)', version $($d.version)), publisher **$($d.publisherid.uniquename)** (prefix ``$($d.publisherid.customizationprefix)``), $($d.ComponentCount) solution components total. Presumed V1 - source of information and comparison per the brief, not to be modified or deleted.")
        if ($d.CustomTables -and $d.CustomTables.Count -gt 0) {
            [void]$sb.AppendLine("  - Custom tables referenced by this solution (note: spans more than one prefix - do not assume a single publisher prefix covers all of V1):")
            foreach ($vt in $d.CustomTables) {
                [void]$sb.AppendLine("    - ``$($vt.LogicalName)`` ($($vt.SchemaName))")
            }
        } else {
            [void]$sb.AppendLine("  - No custom tables resolved for this solution.")
        }
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("V1-to-V2 concept mapping (informational, V1 stays untouched):")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| V1 table | Nearest V2 concept |")
    [void]$sb.AppendLine("| --- | --- |")
    [void]$sb.AppendLine("| pa_servicecustomer | Standard Account/Contact + hsv_serviceobject (V2 deliberately uses standard tables here, per docs/03-datenmodell.md §1.4) |")
    [void]$sb.AppendLine("| pa_workorder | hsv_workorder |")
    [void]$sb.AppendLine("| pa_intakemessage | hsv_inboundmessage |")
    [void]$sb.AppendLine("| ap_processingattempt | hsv_processingattempt |")
    [void]$sb.AppendLine("| ap_dispatchrequest | No direct V2 equivalent in the current datamodel - not carried forward; flag if this turns out to matter. |")
    [void]$sb.AppendLine()
}
$otherHsv = $hsvTables.value | Where-Object { $_.LogicalName -notin $config.TargetTables }
if ($otherHsv.Count -gt 0) {
    foreach ($t in $otherHsv) {
        [void]$sb.AppendLine("- ``$($t.LogicalName)`` ($($t.SchemaName)) — not one of the five V2 target tables. Treat as V1 / unrelated. Do not modify or delete.")
    }
} else {
    [void]$sb.AppendLine("- No other ``hsv_``-prefixed tables found. Either V1 didn't use this prefix, or V1 hasn't been built in this environment yet.")
}
[void]$sb.AppendLine()

[void]$sb.AppendLine("## NEW COMPONENT REQUIRED")
[void]$sb.AppendLine()
if (-not $publishers.value.Count) { [void]$sb.AppendLine("- Publisher ``$($config.PublisherUniqueName)`` (prefix ``$($config.PublisherPrefix)``)") }
if (-not $targetSolution) { [void]$sb.AppendLine("- Solution ``$($config.SolutionUniqueName)``") }
foreach ($c in $config.TargetGlobalChoices) { if (-not $targetChoiceStatus[$c]) { [void]$sb.AppendLine("- Global choice ``$c``") } }
foreach ($t in $config.TargetTables) { if (-not $targetTableStatus[$t]) { [void]$sb.AppendLine("- Table ``$t``") } }
[void]$sb.AppendLine()

[void]$sb.AppendLine("## UNKNOWN / NEEDS DECISION")
[void]$sb.AppendLine()
[void]$sb.AppendLine("- ``OptionValuePrefix`` in ``scripts/config.psd1`` ($($config.OptionValuePrefix)) is a placeholder chosen from the general safe custom range, **not verified against tenant-wide publisher registry beyond prefix name**. Dataverse will reject it at publisher-creation time if it collides with another publisher's numeric prefix; the deploy script surfaces that as a CONFLICT if it happens, it is not silently retried.")
[void]$sb.AppendLine("- Solution name mismatch between the prompt (``HSVServiceIntakeV2`` / 'HSV Service Intake V2') and ``docs/03-datenmodell.md`` line 6 ('Reliable Service Intake') was flagged to the user and resolved: **``HSVServiceIntakeV2`` / 'HSV Service Intake V2' is authoritative**, per explicit decision on $(Get-Date -Format 'yyyy-MM-dd'). See ``docs/architecture.md``.")
[void]$sb.AppendLine()

$sb.ToString() | Set-Content -Path $reportPath -Encoding utf8
Write-Output "[DISCOVER] Report written to $reportPath"

return $result
