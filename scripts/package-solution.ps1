<#
    .SYNOPSIS
        Produces a proper deployable package (review item 10) and, unless
        -SkipCheck is given, runs the Solution Checker against it (review
        item 11):
          1. Exports the UNMANAGED solution from SI-DEV and unpacks it into
             solution/unpacked/ - this is the actual source of truth,
             committed to git, and is what DEV imports from (source form,
             not a binary artifact).
          2. Exports a MANAGED solution zip to solution/HSVServiceIntakeV2_managed.zip
             - this is what TEST/PROD import (managed = customizations
             locked down in downstream environments; DEV stays unmanaged so
             this project's own further changes remain editable there).
          3. Runs `pac solution check` against the unmanaged zip and fails
             the script (non-zero exit) if it reports anything at High or
             Critical severity.

        Requires: `pac auth` already pointed at the environment to export
        FROM (this project always packages from SI-DEV, since that's where
        schema/security/plugin changes are made and verified first - see
        docs/architecture.md). Run `pac auth select` yourself beforehand if
        more than one profile is configured; this script does not switch
        profiles for you, since doing so silently could export from the
        wrong environment.

    .PARAMETER SkipCheck
        Skip the Solution Checker step (e.g. for a quick local re-export).
#>
[CmdletBinding()]
param(
    [switch] $SkipCheck
)

$ErrorActionPreference = 'Stop'
$SolutionDir = Join-Path $PSScriptRoot '..\solution'
$SolutionName = 'HSVServiceIntakeV2'
$UnmanagedZip = Join-Path $SolutionDir "$SolutionName.zip"
$ManagedZip   = Join-Path $SolutionDir "${SolutionName}_managed.zip"
$UnpackedDir  = Join-Path $SolutionDir 'unpacked'
$CheckResultsDir = Join-Path $SolutionDir 'check-results'

function Invoke-Pac {
    param([string[]] $PacArgs)
    Write-Output "[PAC] pac $($PacArgs -join ' ')"
    & pac @PacArgs
    if ($LASTEXITCODE -ne 0) {
        throw "pac $($PacArgs -join ' ') exited with code $LASTEXITCODE."
    }
}

Write-Output "=== 1. Export UNMANAGED (DEV/source) ==="
Invoke-Pac @('solution', 'export', '--path', $UnmanagedZip, '--name', $SolutionName, '--managed', 'false', '--overwrite')

Write-Output ""
Write-Output "=== 2. Unpack into solution/unpacked/ (source of truth, committed to git) ==="
if (Test-Path $UnpackedDir) { Remove-Item -Recurse -Force $UnpackedDir }
Invoke-Pac @('solution', 'unpack', '--zipfile', $UnmanagedZip, '--folder', $UnpackedDir, '--packagetype', 'Unmanaged')

Write-Output ""
Write-Output "=== 3. Export MANAGED (TEST/PROD) ==="
Invoke-Pac @('solution', 'export', '--path', $ManagedZip, '--name', $SolutionName, '--managed', 'true', '--overwrite')

if ($SkipCheck) {
    Write-Output ""
    Write-Output "=== Skipping Solution Checker (-SkipCheck) ==="
    Write-Output "=== DONE ==="
    exit 0
}

Write-Output ""
Write-Output "=== 4. Solution Checker (pac solution check) ==="
if (Test-Path $CheckResultsDir) { Remove-Item -Recurse -Force $CheckResultsDir }
Invoke-Pac @('solution', 'check', '--path', $UnmanagedZip, '--outputDirectory', $CheckResultsDir)

# `pac solution check` itself exits 0 even when it finds issues - it only
# prints a severity table. Parse the downloaded report to fail loudly on
# anything that actually matters, rather than requiring a human to notice a
# nonzero count in scrollback.
$reportZip = Get-ChildItem -Path $CheckResultsDir -Filter '*.zip' | Select-Object -First 1
if (-not $reportZip) {
    throw "Solution Checker produced no report file in $CheckResultsDir - check the pac output above."
}
$extractDir = Join-Path $CheckResultsDir 'extracted'
Expand-Archive -Path $reportZip.FullName -DestinationPath $extractDir -Force
$sarif = Get-ChildItem -Path $extractDir -Filter '*.sarif' -Recurse | Select-Object -First 1
if (-not $sarif) {
    Write-Output "[WARNING] No .sarif file found in the Solution Checker report - can't confirm severity counts programmatically. Check $CheckResultsDir manually."
    exit 0
}
$report = Get-Content -Path $sarif.FullName -Raw | ConvertFrom-Json
$allResults = $report.runs.results
$bySeverity = $allResults | Group-Object { $_.properties.severity } | ForEach-Object { [pscustomobject]@{ Severity = $_.Name; Count = $_.Count } }
Write-Output ""
Write-Output "Solution Checker findings by severity:"
if ($bySeverity) { $bySeverity | Format-Table | Out-String | Write-Output } else { Write-Output "  (none)" }

$blocking = $allResults | Where-Object { $_.properties.severity -in @('High', 'Critical') }
if ($blocking.Count -gt 0) {
    Write-Output "=== FAILED: $($blocking.Count) High/Critical Solution Checker finding(s) - fix before packaging TEST/PROD ==="
    exit 1
}

Write-Output ""
Write-Output "=== DONE - no High/Critical Solution Checker findings ==="
