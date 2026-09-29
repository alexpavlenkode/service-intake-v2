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

$spec = (Get-Content -Path "$PSScriptRoot\..\schema\statustransitions.yaml" -Raw) | ConvertFrom-Yaml

# hsv_EntityName / hsv_AllowedTrigger local option set values, from
# schema/tables.yaml's localOptionSets block - kept in sync manually since
# this script reads a different yaml file than tables.yaml.
$entityNameValues = @{ Message = 209710731; 'Work Order' = 209710732 }
$triggerValues    = @{ System = 209710741; Disponent = 209710742; Techniker = 209710743; Plattformbetreuer = 209710744 }

$existing = Invoke-DataverseApi -OrgUrl $org -Method GET -Path "hsv_statustransitions?`$select=hsv_statustransitionid,hsv_entityname,hsv_fromstatus,hsv_tostatus"

function Test-ExistingRow($entityValue, $fromStatus, $toStatus) {
    return [bool]($existing.value | Where-Object { $_.hsv_entityname -eq $entityValue -and $_.hsv_fromstatus -eq $fromStatus -and $_.hsv_tostatus -eq $toStatus })
}

$created = 0
$skipped = 0

function Process-Transitions($entityLabel, $transitions) {
    $entityValue = $entityNameValues[$entityLabel]
    foreach ($t in $transitions) {
        if (Test-ExistingRow $entityValue $t.fromStatus $t.toStatus) {
            Write-Output "[SKIP] $entityLabel : $($t.fromStatus) -> $($t.toStatus) (already exists)"
            $script:skipped++
            continue
        }
        $name = "$entityLabel`: $($t.fromStatus) -> $($t.toStatus)"
        Write-Output "[CREATE] $name (trigger=$($t.trigger))"
        $script:created++
        if ($Apply) {
            $body = @{
                hsv_name           = $name
                hsv_entityname     = $entityValue
                hsv_fromstatus     = $t.fromStatus
                hsv_tostatus       = $t.toStatus
                hsv_allowedtrigger = $triggerValues[$t.trigger]
                hsv_isactive       = $true
            }
            Invoke-DataverseApi -OrgUrl $org -Method POST -Path 'hsv_statustransitions' -Body $body | Out-Null
        }
    }
}

Process-Transitions 'Message' $spec.messageTransitions
Process-Transitions 'Work Order' $spec.workOrderTransitions

Write-Output ""
Write-Output "=== SUMMARY: $created to create, $skipped already present ==="
