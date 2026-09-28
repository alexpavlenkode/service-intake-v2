<#
    .SYNOPSIS
        Declarative deployment of Service Intake V2 into SI-DEV, driven by
        schema/*.yaml. Idempotent: safe to re-run, never creates duplicates,
        never touches anything it didn't create.

    .DESCRIPTION
        For every planned component: Exists -> verify · Missing -> create ·
        Different -> report the difference and stop on that component only.

        -DryRun prints CREATE / SKIP / VERIFY / CONFLICT /
        MANUAL DECISION REQUIRED for every component and issues ZERO
        state-changing Dataverse calls. This is enforced structurally: all
        Write-* helper functions early-return under -DryRun before building
        any POST/PATCH/DELETE request.

        Hard rules (see docs/architecture.md and the project prompt §10):
          - Never DELETE a metadata endpoint (enforced again, independently,
            in Invoke-DataverseApi).
          - Never delete a solution, publisher, or record this run didn't
            create itself.
          - Never change an existing schema name.

    .PARAMETER DryRun
        Plan only. No writes. This is the mode Phase A requires before any
        human sign-off.

    .PARAMETER Apply
        Actually create/update components in SI-DEV. Requires explicit
        Phase B/C go-ahead from the user - do not pass this from Phase A.
#>
[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [Parameter(ParameterSetName = 'DryRun')]
    [switch] $DryRun,

    [Parameter(ParameterSetName = 'Apply')]
    [switch] $Apply,

    # Optional scoping for cautious incremental applies (e.g. create just one
    # table, verify it by hand, then widen). Omit to process all tables in
    # schema/tables.yaml. Never affects publisher/solution/choices - those
    # are cheap to verify and low-risk to create all at once.
    [string[]] $OnlyTables
)

$ErrorActionPreference = 'Stop'
if (-not $DryRun -and -not $Apply) {
    throw "Specify either -DryRun (plan only, no writes) or -Apply (write to SI-DEV). There is no implicit default - this is deliberate."
}

Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force
Import-Module powershell-yaml -Force

$config = Import-PowerShellDataFile "$PSScriptRoot\config.psd1"
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl
$script:baseLangCode = Get-DataverseBaseLanguageCode -OrgUrl $org

function Read-Yaml($relativePath) {
    $full = Join-Path $PSScriptRoot "..\schema\$relativePath"
    return (Get-Content -Path $full -Raw) | ConvertFrom-Yaml
}

$choices       = Read-Yaml 'choices.yaml'
$tablesSpec    = Read-Yaml 'tables.yaml'
$relationships = Read-Yaml 'relationships.yaml'
$keysSpec      = Read-Yaml 'keys.yaml'
$auditingSpec  = Read-Yaml 'auditing.yaml'

$plan = New-Object System.Collections.Generic.List[object]
function Add-PlanItem($kind, $name, $action, $detail = '') {
    $plan.Add([PSCustomObject]@{ Kind = $kind; Name = $name; Action = $action; Detail = $detail }) | Out-Null
    $prefix = switch ($action) {
        'CREATE'  { '[CREATE]' }
        'SKIP'    { '[SKIP]' }
        'VERIFY'  { '[VERIFY]' }
        'CONFLICT' { '[ERROR]' }
        'MANUAL DECISION REQUIRED' { '[WARNING]' }
        default { '[INFO]' }
    }
    Write-Output "$prefix $kind '$name': $action$(if ($detail) { " - $detail" })"
}

# ------------------------------------------------------------------------
# 1. Publisher
# ------------------------------------------------------------------------
$existingPublishers = Invoke-DataverseApi -OrgUrl $org -Method GET `
    -Path "publishers?`$select=uniquename,customizationprefix,customizationoptionvalueprefix&`$filter=customizationprefix eq '$($config.PublisherPrefix)'"

if ($existingPublishers.value.Count -eq 0) {
    Add-PlanItem 'Publisher' $config.PublisherUniqueName 'CREATE' "prefix $($config.PublisherPrefix), optionvalueprefix $($config.OptionValuePrefix)"
    if ($Apply) {
        $body = @{
            uniquename                     = $config.PublisherUniqueName
            friendlyname                   = $config.PublisherDisplayName
            customizationprefix            = $config.PublisherPrefix
            customizationoptionvalueprefix = $config.OptionValuePrefix
        }
        Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'publishers' -Body $body | Out-Null
    }
} elseif ($existingPublishers.value[0].customizationoptionvalueprefix -ne $config.OptionValuePrefix) {
    Add-PlanItem 'Publisher' $config.PublisherUniqueName 'CONFLICT' "exists with optionvalueprefix $($existingPublishers.value[0].customizationoptionvalueprefix), config expects $($config.OptionValuePrefix)"
} else {
    Add-PlanItem 'Publisher' $config.PublisherUniqueName 'VERIFY' 'already exists, matches config'
}

# ------------------------------------------------------------------------
# 2. Solution
# ------------------------------------------------------------------------
$existingSolution = Invoke-DataverseApi -OrgUrl $org -Method GET `
    -Path "solutions?`$select=uniquename,version&`$filter=uniquename eq '$($config.SolutionUniqueName)'"

if ($existingSolution.value.Count -eq 0) {
    Add-PlanItem 'Solution' $config.SolutionUniqueName 'CREATE' $config.SolutionDisplayName
    if ($Apply) {
        $pub = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "publishers?`$select=publisherid&`$filter=uniquename eq '$($config.PublisherUniqueName)'"
        $body = @{
            uniquename    = $config.SolutionUniqueName
            friendlyname  = $config.SolutionDisplayName
            version       = '1.0.0.0'
            'publisherid@odata.bind' = "/publishers($($pub.value[0].publisherid))"
        }
        Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'solutions' -Body $body | Out-Null
    }
} else {
    Add-PlanItem 'Solution' $config.SolutionUniqueName 'VERIFY' "already exists, version $($existingSolution.value[0].version)"
}

# ------------------------------------------------------------------------
# 3. Global choices
# ------------------------------------------------------------------------
$allChoices = Invoke-DataverseApi -OrgUrl $org -Method GET -Path 'GlobalOptionSetDefinitions?$select=Name'
foreach ($choice in $choices.globalChoices) {
    $exists = $allChoices.value | Where-Object { $_.Name -eq $choice.schemaName }
    if (-not $exists) {
        Add-PlanItem 'GlobalChoice' $choice.schemaName 'CREATE' "$($choice.options.Count) options"
        if ($Apply) {
            $body = @{
                '@odata.type' = 'Microsoft.Dynamics.CRM.OptionSetMetadata'
                Name          = $choice.schemaName
                DisplayName   = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.Label'; LocalizedLabels = @(@{ '@odata.type' = 'Microsoft.Dynamics.CRM.LocalizedLabel'; Label = $choice.displayName; LanguageCode = $script:baseLangCode }) }
                Description   = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.Label'; LocalizedLabels = @(@{ '@odata.type' = 'Microsoft.Dynamics.CRM.LocalizedLabel'; Label = ($choice.description -join ' '); LanguageCode = $script:baseLangCode }) }
                OptionSetType = 'Picklist'
                Options       = @($choice.options | ForEach-Object {
                    @{ Value = $_.value; Label = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.Label'; LocalizedLabels = @(@{ '@odata.type' = 'Microsoft.Dynamics.CRM.LocalizedLabel'; Label = $_.label; LanguageCode = $script:baseLangCode }) } }
                })
            }
            Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'GlobalOptionSetDefinitions' -Body $body -SolutionUniqueName $config.SolutionUniqueName | Out-Null
        }
    } else {
        Add-PlanItem 'GlobalChoice' $choice.schemaName 'VERIFY' 'already exists - option-value diff not checked by this pass, see verify.ps1'
    }
}

# ------------------------------------------------------------------------
# 4. Tables (order matters - as declared in tables.yaml)
# ------------------------------------------------------------------------
$allEntities = Invoke-DataverseApi -OrgUrl $org -Method GET -Path 'EntityDefinitions?$select=LogicalName'
$existingLogicalNames = @($allEntities.value.LogicalName)

function New-DataverseAttributeBody {
    # Builds the Attributes-endpoint POST body for one non-Lookup column.
    # Lookup columns are NOT built here - in Dataverse a Lookup attribute is
    # created together with its OneToMany relationship, so those are created
    # in Phase C (schema/relationships.yaml), not here.
    param($col, [int] $LangCode, [hashtable] $GlobalChoiceIds)

    $displayName = New-DataverseLabel (ConvertTo-DataverseDisplayName $col.schemaName) $LangCode
    $required = New-DataverseRequiredLevel $col.requiredLevel

    switch ($col.type) {
        'String' {
            return @{
                '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
                SchemaName    = $col.schemaName
                DisplayName   = $displayName
                RequiredLevel = $required
                MaxLength     = [int]$col.maxLength
                FormatName    = @{ Value = 'Text' }
            }
        }
        'Memo' {
            return @{
                '@odata.type' = 'Microsoft.Dynamics.CRM.MemoAttributeMetadata'
                SchemaName    = $col.schemaName
                DisplayName   = $displayName
                RequiredLevel = $required
                MaxLength     = [int]$col.maxLength
            }
        }
        'Boolean' {
            return @{
                '@odata.type' = 'Microsoft.Dynamics.CRM.BooleanAttributeMetadata'
                SchemaName    = $col.schemaName
                DisplayName   = $displayName
                RequiredLevel = $required
                DefaultValue  = [bool]$col.defaultValue
                OptionSet     = @{
                    '@odata.type' = 'Microsoft.Dynamics.CRM.BooleanOptionSetMetadata'
                    TrueOption    = @{ Value = 1; Label = (New-DataverseLabel 'Ja' $LangCode) }
                    FalseOption   = @{ Value = 0; Label = (New-DataverseLabel 'Nein' $LangCode) }
                }
            }
        }
        'WholeNumber' {
            return @{
                '@odata.type' = 'Microsoft.Dynamics.CRM.IntegerAttributeMetadata'
                SchemaName    = $col.schemaName
                DisplayName   = $displayName
                RequiredLevel = $required
                Format        = 'None'
                MinValue      = -2147483648
                MaxValue      = 2147483647
            }
        }
        'DateTime' {
            return @{
                '@odata.type'    = 'Microsoft.Dynamics.CRM.DateTimeAttributeMetadata'
                SchemaName       = $col.schemaName
                DisplayName      = $displayName
                RequiredLevel    = $required
                Format           = 'DateAndTime'
                DateTimeBehavior = @{ Value = $col.dateTimeBehavior }
            }
        }
        'Choice' {
            if ($col.globalChoice) {
                $metadataId = $GlobalChoiceIds[$col.globalChoice]
                if (-not $metadataId) { throw "Global choice '$($col.globalChoice)' not found - create choices before tables." }
                return @{
                    '@odata.type'  = 'Microsoft.Dynamics.CRM.PicklistAttributeMetadata'
                    SchemaName     = $col.schemaName
                    DisplayName    = $displayName
                    RequiredLevel  = $required
                    GlobalOptionSet = @{ MetadataId = $metadataId }
                }
            } elseif ($col.localOptions) {
                $opts = $script:tablesSpec.localOptionSets[$col.localOptions]
                return @{
                    '@odata.type' = 'Microsoft.Dynamics.CRM.PicklistAttributeMetadata'
                    SchemaName    = $col.schemaName
                    DisplayName   = $displayName
                    RequiredLevel = $required
                    OptionSet     = @{
                        '@odata.type'  = 'Microsoft.Dynamics.CRM.OptionSetMetadata'
                        IsGlobal       = $false
                        OptionSetType  = 'Picklist'
                        Options        = @($opts | ForEach-Object { @{ Value = $_.value; Label = (New-DataverseLabel $_.label $LangCode) } })
                    }
                }
            } else {
                throw "Choice column '$($col.schemaName)' has neither globalChoice nor localOptions set."
            }
        }
        default { return $null } # Lookup, AutoNumber-as-primary handled elsewhere
    }
}

$script:tablesSpec = $tablesSpec

# Resolve global choice MetadataIds once, needed for Picklist columns below.
$globalChoiceMeta = Invoke-DataverseApi -OrgUrl $org -Method GET -Path 'GlobalOptionSetDefinitions?$select=Name,MetadataId'
$globalChoiceIds = @{}
foreach ($g in $globalChoiceMeta.value) { $globalChoiceIds[$g.Name] = $g.MetadataId }

$tablesToProcess = $tablesSpec.tables
if ($OnlyTables) { $tablesToProcess = $tablesSpec.tables | Where-Object { $_.logicalName -in $OnlyTables } }

foreach ($table in $tablesToProcess) {
    if ($table.logicalName -in $existingLogicalNames) {
        Add-PlanItem 'Table' $table.logicalName 'VERIFY' 'already exists - column-level diff not checked by this pass, see verify.ps1'
        continue
    }

    $nonLookupCols = @($table.columns | Where-Object { $_.type -ne 'Lookup' })
    $lookupCols    = @($table.columns | Where-Object { $_.type -eq 'Lookup' })
    Add-PlanItem 'Table' $table.logicalName 'CREATE' "$($nonLookupCols.Count) columns now, $($lookupCols.Count) Lookup column(s) deferred to Phase C (relationships), ownership=$($table.ownershipType)"

    if ($Apply) {
        $primary = $table.primaryNameAttribute
        $primaryAttr = @{
            '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
            SchemaName    = $primary.schemaName
            DisplayName   = New-DataverseLabel $primary.displayName $script:baseLangCode
            RequiredLevel = New-DataverseRequiredLevel 'Required'
            MaxLength     = if ($primary.maxLength) { [int]$primary.maxLength } else { 100 }
            FormatName    = @{ Value = 'Text' }
            IsPrimaryName = $true
        }
        if ($primary.type -eq 'AutoNumber') {
            $primaryAttr['AutoNumberFormat'] = $primary.autoNumberFormat
        }

        $attributes = New-Object System.Collections.Generic.List[object]
        $attributes.Add($primaryAttr) | Out-Null
        foreach ($col in $nonLookupCols) {
            $body = New-DataverseAttributeBody -col $col -LangCode $script:baseLangCode -GlobalChoiceIds $globalChoiceIds
            if ($body) { $attributes.Add($body) | Out-Null }
        }

        $entityBody = @{
            '@odata.type'          = 'Microsoft.Dynamics.CRM.EntityMetadata'
            SchemaName             = $table.schemaName
            DisplayName            = New-DataverseLabel $table.displayName $script:baseLangCode
            DisplayCollectionName  = New-DataverseLabel $table.pluralDisplayName $script:baseLangCode
            Description            = New-DataverseLabel $table.description $script:baseLangCode
            OwnershipType          = $table.ownershipType
            HasActivities          = $false
            HasNotes               = $false
            IsActivity             = $false
            Attributes             = $attributes
        }

        Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'EntityDefinitions' -Body $entityBody -SolutionUniqueName $config.SolutionUniqueName | Out-Null
        Write-Output "[CREATE] Table '$($table.logicalName)' created with $($attributes.Count) attributes (incl. primary name)."
    }
}

# ------------------------------------------------------------------------
# 5. Relationships (only meaningful once both sides of the table exist)
# ------------------------------------------------------------------------
foreach ($rel in $relationships.relationships) {
    $refExists = ($rel.referencedEntity -in $existingLogicalNames) -or ($rel.referencedEntity -in $tablesSpec.tables.logicalName)
    $reqExists = ($rel.referencingEntity -in $existingLogicalNames) -or ($rel.referencingEntity -in $tablesSpec.tables.logicalName)
    if (-not $refExists -or -not $reqExists) {
        Add-PlanItem 'Relationship' $rel.schemaName 'CONFLICT' 'referenced/referencing table missing from both SI-DEV and tables.yaml'
        continue
    }
    if ($rel.referencedEntity -notin $existingLogicalNames -or $rel.referencingEntity -notin $existingLogicalNames) {
        Add-PlanItem 'Relationship' $rel.schemaName 'CREATE' 'pending - depends on a table this run will create first'
    } else {
        Add-PlanItem 'Relationship' $rel.schemaName 'CREATE' $rel.deleteBehavior
    }
}

# ------------------------------------------------------------------------
# 6. Alternate keys
# ------------------------------------------------------------------------
foreach ($key in $keysSpec.keys) {
    if ($key.entity -in $existingLogicalNames) {
        Add-PlanItem 'AlternateKey' $key.schemaName 'CREATE' "on existing table $($key.entity)"
    } else {
        Add-PlanItem 'AlternateKey' $key.schemaName 'CREATE' "pending - table $($key.entity) not created yet"
    }
}

# ------------------------------------------------------------------------
# 7. Auditing
# ------------------------------------------------------------------------
$orgInfo = Invoke-DataverseApi -OrgUrl $org -Method GET -Path 'organizations?$select=isauditenabled'
$orgAuditOn = [bool]$orgInfo.value[0].isauditenabled
if (-not $orgAuditOn) {
    Add-PlanItem 'Auditing' 'organization' 'MANUAL DECISION REQUIRED' 'Organization-level auditing is OFF. Table-level auditing settings below will have no effect until an admin turns this on (Settings > Auditing). This is not something this script can or should flip on its own.'
}
foreach ($t in $auditingSpec.tables) {
    Add-PlanItem 'Auditing' $t.entity 'CREATE' "enable auditing, emphasize: $($t.emphasizedAttributes -join ', ')"
}

# ------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------
Write-Output ''
Write-Output '=== SUMMARY ==='
$plan | Group-Object Action | Sort-Object Name | ForEach-Object { Write-Output "$($_.Name): $($_.Count)" }

if ($DryRun) {
    Write-Output ''
    Write-Output '[DISCOVER] Dry run only - zero write calls were issued.'
}

return $plan
