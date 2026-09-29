<#
    .SYNOPSIS
        Deletes all DATA records (never metadata/schema) from the tables
        that accumulate test/demo data, so you can run a clean test batch
        without old runs skewing duplicate detection or cluttering the log.

    .DESCRIPTION
        Deletes, in this order (matters - see schema/relationships.yaml's
        Restrict cascade rules, which block deleting a referenced parent
        while children still exist):
          1. hsv_processingattempt
          2. hsv_inboundmessage
          3. hsv_workorder
          4. hsv_serviceobject
          5. accounts whose name starts with "DEMO " (created by
             demo-pipeline.ps1 / serve-live-console.ps1 - never touches any
             other Account)

        Deliberately NEVER touches hsv_statustransition - that is
        configuration data the CanTransition plugin depends on, not test
        data, regardless of how this script is invoked.

        This deletes real records via the standard Web API DELETE - allowed
        here (only metadata-endpoint DELETE is hard-blocked project-wide,
        see Invoke-DataverseApi). Still real deletion: -DryRun shows counts
        first, -Apply is a separate, deliberate step.

    .PARAMETER DryRun
        Shows how many records would be deleted per table. No writes.

    .PARAMETER Apply
        Actually deletes them.
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

$config = Import-PowerShellDataFile $ConfigPath
Connect-DataverseOrg -TenantId $config.TenantId
$org = $config.OrgUrl

function Get-AllIds {
    param([string] $EntitySet, [string] $IdField, [string] $Filter)
    $path = "$EntitySet`?`$select=$IdField"
    if ($Filter) { $path += "&`$filter=$Filter" }
    $ids = New-Object System.Collections.Generic.List[string]
    $next = $path
    while ($next) {
        $resp = Invoke-DataverseApi -OrgUrl $org -Method GET -Path $next
        foreach ($r in $resp.value) { $ids.Add($r.$IdField) }
        $next = $null
        if ($resp.'@odata.nextLink') {
            # nextLink is absolute; Invoke-DataverseApi expects a path relative
            # to /api/data/v9.2/ so strip that prefix back off.
            $next = $resp.'@odata.nextLink' -replace '^.*?/api/data/v9\.2/', ''
        }
    }
    return $ids
}

function Remove-AllRecords {
    # Uses Write-Host, not Write-Output, for the progress lines - PowerShell
    # functions return everything written to the success/output stream, so
    # Write-Output here would silently turn the "return $ids.Count" below
    # into an array containing every status line too (hit this empirically:
    # the summary printed "System.Object[]" instead of a number).
    param([string] $Label, [string] $EntitySet, [string] $IdField, [string] $Filter = $null)
    $ids = Get-AllIds -EntitySet $EntitySet -IdField $IdField -Filter $Filter
    Write-Host "[$Label] $($ids.Count) record(s) found."
    if (-not $Apply -or $ids.Count -eq 0) { return $ids.Count }
    $done = 0
    foreach ($id in $ids) {
        Invoke-DataverseApi -OrgUrl $org -Method DELETE -Path "$EntitySet($id)" | Out-Null
        $done++
        if ($done % 25 -eq 0) { Write-Host "  ... $done/$($ids.Count) deleted" }
    }
    Write-Host "[$Label] $done record(s) deleted."
    return $ids.Count
}

Write-Output "=== Test data cleanup ($(if ($Apply) { 'APPLY' } else { 'DRY RUN' })) ==="
Write-Output "hsv_statustransition is never touched by this script."
Write-Output ""

$counts = [ordered]@{
    'hsv_processingattempt' = Remove-AllRecords -Label 'hsv_processingattempt' -EntitySet 'hsv_processingattempts' -IdField 'hsv_processingattemptid'
    'hsv_inboundmessage'    = Remove-AllRecords -Label 'hsv_inboundmessage'    -EntitySet 'hsv_inboundmessages'    -IdField 'hsv_inboundmessageid'
    'hsv_workorder'         = Remove-AllRecords -Label 'hsv_workorder'         -EntitySet 'hsv_workorders'         -IdField 'hsv_workorderid'
    'hsv_serviceobject'     = Remove-AllRecords -Label 'hsv_serviceobject'     -EntitySet 'hsv_serviceobjects'     -IdField 'hsv_serviceobjectid'
    'accounts (DEMO *)'     = Remove-AllRecords -Label 'accounts (DEMO *)'     -EntitySet 'accounts'               -IdField 'accountid' -Filter "startswith(name,'DEMO ')"
}

Write-Output ""
Write-Output "=== SUMMARY ==="
$counts.GetEnumerator() | ForEach-Object { Write-Output ("{0,-22} {1}" -f $_.Key, $_.Value) }
if (-not $Apply) {
    Write-Output ""
    Write-Output "Dry run only - nothing was deleted. Re-run with -Apply to actually delete."
}
