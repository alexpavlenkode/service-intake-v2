<#
    .SYNOPSIS
        Seeds hsv_statustransition with the configuration rows from
        schema/statustransitions.yaml. Idempotent: matches existing rows by
        (entity, fromStatus, toStatus) and skips them.

    .PARAMETER DryRun
        Plan only. No writes.

    .PARAMETER Apply
        Create the rows in SI-DEV.
#>
[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [Parameter(ParameterSetName = 'DryRun')] [switch] $DryRun,
    [Parameter(ParameterSetName = 'Apply')] [switch] $Apply,
    [string] $ConfigPath = "$PSScriptRoot\config.psd1"
)

$ErrorActionPreference = 'Stop'
if (-not $DryRun -and -not $Apply) { throw "Specify either -DryRun or -Apply." }

Import-Module "$PSScriptRoot\lib\Dataverse.psm1" -Force
Import-Module powershell-yaml -Force

$config = Import-PowerShellDataFile $ConfigPath
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

$spec = (Get-Content -Path "$PSScriptRoot\..\schema\statustransitions.yaml" -Raw -Encoding UTF8) | ConvertFrom-Yaml

# hsv_EntityName / hsv_AllowedTrigger local option set values, from
# schema/tables.yaml's localOptionSets block - kept in sync manually since
# this script reads a different yaml file than tables.yaml.
$entityNameValues = @{ Message = 209710731; 'Work Order' = 209710732 }
$triggerValues    = @{ System = 209710741; Disponent = 209710742; Techniker = 209710743; Plattformbetreuer = 209710744 }

# hsv_MessageStatus / hsv_WorkOrderStatus global choice values, from
# schema/choices.yaml - kept in sync manually, same reason as above. This is
# the ONE place a status label gets translated to its numeric Choice value;
# CanTransitionPlugin itself does no such translation (review items 12/13) -
# it reads hsv_FromStatusValue/hsv_ToStatusValue directly.
$messageStatusValues = @{
    Received = 209710001; Parsed = 209710002; Validated = 209710003
    'Needs Clarification' = 209710004; 'Potential Duplicate' = 209710005
    Duplicate = 209710006; 'Not Relevant' = 209710007; Linked = 209710008
    Converted = 209710009; 'Technical Retry' = 209710010; Failed = 209710011
}
$workOrderStatusValues = @{
    Neu = 209710101; Zugewiesen = 209710102; 'In Arbeit' = 209710103
    Abgeschlossen = 209710104; Storniert = 209710105
}
# Sentinel meaning "record does not exist yet" (Create) - not a real Choice
# value in either option set above, both of which start at 209710xxx.
$NoneSentinel = 0

function Get-StatusValue($entityLabel, $statusLabel) {
    if ($statusLabel -eq '(none)') { return $NoneSentinel }
    $table = if ($entityLabel -eq 'Message') { $messageStatusValues } else { $workOrderStatusValues }
    $value = $table[$statusLabel]
    if (-not $value) { throw "Unrecognized status label '$statusLabel' for entity '$entityLabel' - check schema/statustransitions.yaml against schema/choices.yaml." }
    return $value
}

$existing = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_statustransitions?`$select=hsv_statustransitionid,hsv_entityname,hsv_fromstatus,hsv_tostatus,hsv_fromstatusvalue,hsv_tostatusvalue"

function Find-ExistingRow($entityValue, $fromStatus, $toStatus) {
    return $existing.value | Where-Object { $_.hsv_entityname -eq $entityValue -and $_.hsv_fromstatus -eq $fromStatus -and $_.hsv_tostatus -eq $toStatus } | Select-Object -First 1
}

$created  = 0
$skipped  = 0
$backfilled = 0

function Process-Transitions($entityLabel, $transitions) {
    $entityValue = $entityNameValues[$entityLabel]
    foreach ($t in $transitions) {
        $fromValue = Get-StatusValue $entityLabel $t.fromStatus
        $toValue   = Get-StatusValue $entityLabel $t.toStatus
        $row = Find-ExistingRow $entityValue $t.fromStatus $t.toStatus

        if ($row) {
            if ($null -ne $row.hsv_fromstatusvalue -and $null -ne $row.hsv_tostatusvalue) {
                Write-Output "[SKIP] $entityLabel : $($t.fromStatus) -> $($t.toStatus) (already exists)"
                $script:skipped++
                continue
            }
            Write-Output "[BACKFILL] $entityLabel : $($t.fromStatus) -> $($t.toStatus) (adding FromStatusValue=$fromValue, ToStatusValue=$toValue to a row created before review item 13)"
            $script:backfilled++
            if ($Apply) {
                Invoke-DataverseApi -OrgUrl $org -Method PATCH -Path "hsv_statustransitions($($row.hsv_statustransitionid))" -Body @{ hsv_fromstatusvalue = $fromValue; hsv_tostatusvalue = $toValue } | Out-Null
            }
            continue
        }

        $name = "$entityLabel`: $($t.fromStatus) -> $($t.toStatus)"
        Write-Output "[CREATE] $name (trigger=$($t.trigger), FromStatusValue=$fromValue, ToStatusValue=$toValue)"
        $script:created++
        if ($Apply) {
            $body = @{
                hsv_name            = $name
                hsv_entityname      = $entityValue
                hsv_fromstatus      = $t.fromStatus
                hsv_tostatus        = $t.toStatus
                hsv_fromstatusvalue = $fromValue
                hsv_tostatusvalue   = $toValue
                hsv_allowedtrigger  = $triggerValues[$t.trigger]
                hsv_isactive        = $true
            }
            Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'hsv_statustransitions' -Body $body | Out-Null
        }
    }
}

Process-Transitions 'Message' $spec.messageTransitions
Process-Transitions 'Work Order' $spec.workOrderTransitions

Write-Output ""
Write-Output "=== SUMMARY: $created to create, $backfilled to backfill, $skipped already present ==="
